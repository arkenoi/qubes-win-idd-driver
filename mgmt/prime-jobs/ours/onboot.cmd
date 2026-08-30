@echo off
rem ===============================================================================================
rem  PRIME JOB: CLEAN INSTALL of the release under test into a PRISTINE base golden.
rem
rem  WHY THIS JOB EXISTS. matrix.sh's cell_fresh_1stage / cell_fresh_2stage both begin with
rem  w_session + push_payload, i.e. they need qrexec - which means they can only run on a golden
rem  that ALREADY carries QWT. That is why every "fresh install" cell in campaign 20260830-062519
rem  was really a same-version reinstall: the only clonable goldens had our package on them. A
rem  genuine clean install (protocol D0) must enter from a pristine base, and a pristine base has
rem  no qrexec, so the primer channel is the only way in (protocol 0.7c).
rem
rem  WHAT IT EXERCISES. win10-base / win11-base carry testsigning OFF, so the installer takes its
rem  TWO-STAGE (E1) path: stage 1 enables testsigning and reboots, stage 2 installs. That is cell
rem  C1 - E1 x D0 - and it is the one path the previous campaign could not reach.
rem
rem  C12 IS FOLDED IN (protocol 5: "+5 min inside C1"). Drop a file named `c12.flag` beside this
rem  script and stage 1 is run BARE twice before the real /auto run. The point is the installer's
rem  own documented property: "The stage is DETECTED, not remembered: if testsigning is not active
rem  in the current boot, this is stage 1." Testsigning only becomes active after a reboot, so a
rem  second pre-reboot run must re-detect stage 1 and succeed again rather than falling through to
rem  stage 2 or refusing. Bare runs are used for the repeats precisely because bare exits 10 and
rem  does NOT reboot; only the final /auto run arms the resume task, so the reboot still happens
rem  exactly once and stage 2 still resumes exactly once.
rem
rem  /autologon:qubes IS NOT OPTIONAL. Without an autologon switch the installer PROMPTS, and this
rem  job runs as SYSTEM in session 0 where no one can answer; the documented fallback is an EMPTY
rem  password, which is wrong for these images - the account's password is `qubes`
rem  (mgmt/autounattend.xml). matrix.sh's run_install has always passed `/auto /autologon:qubes`;
rem  this job uses the identical invocation rather than inventing a second one (protocol 0.8:
rem  "never write a second route to a result the rig already reaches").
rem
rem  STAGING: the caller must place the release setup tree at <jobdir>\setup\ before building the
rem  stick, e.g.  cp -r ~/qwt-matrix-work/dl/qwt-improved-setup mgmt/prime-jobs/ours/setup
rem  Deliberately NOT committed: release-specific and ~30 MB.
rem
rem  Called ONCE, as SYSTEM, by the resident primer hook, which unregisters itself BEFORE running
rem  this - so the installer's own reboot cannot re-trigger the primer.
rem ===============================================================================================
set LOG=C:\qubes-prime\ours.log
echo === ours (clean install) prime job %DATE% %TIME% >> %LOG%

rem Stage to C: first. The stick's drive letter is not stable across the installer's own reboot,
rem and the stick may not be attached at all by stage 2 - the old stock route lost its stage 2
rem exactly this way.
mkdir C:\qwtsetup 2>nul
xcopy /e /i /y "%~dp0setup\*" C:\qwtsetup\ >> %LOG% 2>&1
if not exist C:\qwtsetup\install.cmd (
    echo FATAL: no install.cmd staged - the job dir had no setup\ tree >> %LOG%
    exit /b 2
)

rem `<nul` IS LOAD-BEARING ON THE BARE RUNS - do not remove it.
rem install.cmd ends with `if not defined AUTO pause` (install.cmd:201), deliberately: it keeps the
rem window open so a double-click user can read the outcome, and it is skipped under /auto because
rem the machine is already rebooting on a timer. This job is neither - it runs as SYSTEM in session
rem 0, where nothing can ever press a key. Measured 2026-08-30: the first C12 pass completed stage 1
rem and then sat at that prompt indefinitely - guest idle at 0-3% CPU, desktop up, no dialog visible
rem anywhere (the prompt is on session 0's invisible console), which reads exactly like "the primer
rem never fired". Redirecting stdin from NUL makes pause return immediately and changes nothing else
rem about the route.
rem GOTO, NOT A PARENTHESISED BLOCK. Inside `if exist (...)` cmd expands %ERRORLEVEL% when it PARSES
rem the whole block, not as each line runs - so both passes logged the value from before the block.
rem Measured on the Win10 C1 run: `C12 pass 1 rc=0` and `C12 pass 2 rc=0`, when a bare stage 1
rem returns 10. The installs were fine and the graded evidence comes from the installer's own RESULT
rem trailers, but the job log was quietly reporting a number it had not measured, which is the kind
rem of thing that gets believed later. Outside a block, %ERRORLEVEL% expands per line at execution.
if not exist "%~dp0c12.flag" goto :noc12
echo --- C12: stage 1 run BARE, pass 1 of 2 [expect exit 10, no reboot] >> %LOG%
call C:\qwtsetup\install.cmd /autologon:qubes <nul >> %LOG% 2>&1
echo C12 pass 1 rc=%ERRORLEVEL% >> %LOG%
echo --- C12: stage 1 run BARE, pass 2 of 2 [must RE-DETECT stage 1, not fall into stage 2] >> %LOG%
call C:\qwtsetup\install.cmd /autologon:qubes <nul >> %LOG% 2>&1
echo C12 pass 2 rc=%ERRORLEVEL% >> %LOG%
:noc12

echo --- stage 1 /auto [arms the resume task, reboots, stage 2 follows] >> %LOG%
call C:\qwtsetup\install.cmd /auto /autologon:qubes >> %LOG% 2>&1
echo installer rc=%ERRORLEVEL% >> %LOG%
exit /b %ERRORLEVEL%
