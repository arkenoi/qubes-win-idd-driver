@echo off
rem ===============================================================================================
rem  PRIME JOB: install OUR release with PvDriversDisk OMITTED - the "half-broken" upgrade target.
rem
rem  WHY THIS PRECONDITION (owner, 2026-08-30: "this half-broken install makes better target to test
rem  upgrade paths"). Our own releases in the regression window (FINDINGS:5578) shipped without
rem  PvDriversDisk, so a REAL installed base is in this state: QWT working, every disk on emulated
rem  ATA (FINDINGS:5350). Upgrading one forces the boot disk from emulated to PV - the dangerous
rem  direction - which the in-place path survives only because the first boot stays on the emulated
rem  stack while xenvbd re-binds on the second (FINDINGS:6253). That is a path WE own and our users
rem  will actually take, unlike stock->ours.
rem
rem  NOT A SECOND INSTALLER. `install.cmd /nodisk` maps to -NoPvDisk, which the installer already
rem  supports and already carries across its own stage boundary (CarriedFlags). This job changes ONE
rem  FLAG on the proven route; it does not reimplement the install. Reaching the same state by
rem  installing normally and then REMOVING the feature would NOT be equivalent - an uninstall of the
rem  PV disk driver leaves demoted inbox ATA drivers and a disabled xenvbd (FINDINGS:10179), which is
rem  a different, worse state than never having installed it.
rem
rem  STAGING: the caller must place the release setup tree at <jobdir>\setup\ before building the
rem  stick, e.g.  cp -r ~/qwt-matrix-work/dl/qwt-improved-setup mgmt/prime-jobs/ours-nopvdisk/setup
rem  It is deliberately NOT committed: it is release-specific and ~30 MB.
rem
rem  Called ONCE, as SYSTEM, by the resident primer hook. A pristine base has testsigning OFF, so our
rem  own installer takes its two-stage (E1) path here: stage 1 enables testsigning and reboots,
rem  stage 2 installs. That is the intended behaviour, not a problem to work around.
rem ===============================================================================================
set LOG=C:\qubes-prime\ours-nopvdisk.log

rem DIAG is found by LABEL, not by letter: letters are not stable across the installer's reboot.
set "DIAGDRV="
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if not defined DIAGDRV if exist "%%d:\" for /f "tokens=*" %%v in ('cmd /c vol %%d: 2^>nul ^| findstr /i "DIAG"') do set "DIAGDRV=%%d"
)

echo === ours-nopvdisk prime job %DATE% %TIME% >> %LOG%

rem Stage to C: first. The stick's drive letter is not stable across the installer's own reboots,
rem and the stick may not be attached at all by stage 2 - the old stock route lost its stage 2
rem exactly this way.
mkdir C:\qwtsetup 2>nul
xcopy /e /i /y "%~dp0setup\*" C:\qwtsetup\ >> %LOG% 2>&1
if not exist C:\qwtsetup\install.cmd (
    echo FATAL: no install.cmd staged - the job dir had no setup\ tree >> %LOG%
    exit /b 2
)

rem --- CLOCK FIRST (2026-10-25) -----------------------------------------------------------------
rem A base sealed in SUMMER boots EXACTLY ONE HOUR BEHIND: with timezone=localtime Windows converts
rem the RTC using the ActiveTimeBias ALREADY STORED in its registry and only then refreshes that
rem bias, without moving the clock it just set (ETWCLOCKDST in findings/issues.md). Measured on
rem campaign 40225365779 cell WIN10-clean: guest UTC 18:39:33Z against signer NotBefore 19:10:04Z,
rem 31 min in the guest's future, so the installer REFUSED and nothing installed. The refusal is
rem CORRECT - the driver install would otherwise HANG on 0x800B0101 rather than fail - so the clock
rem has to be fixed BEFORE the installer runs. This guest has no qrexec and no netvm, so the host
rem stamp staged on this stick is the only time source that exists here.
rem NEVER FATAL: the helper logs loudly and returns 0; the installer still owns the verdict.
set "CLOCKDIAG="
if defined DIAGDRV set "CLOCKDIAG=-DiagLog %DIAGDRV%:\prime-progress.log"
if exist "%~dp0fix-guest-clock.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-guest-clock.ps1" -Stamp "%~dp0hoststamp.txt" %CLOCKDIAG% >> %LOG% 2>&1
) else (
    echo [%DATE% %TIME%] CLOCKSTAMP helper ABSENT on the stick - the clock is UNCHECKED >> %LOG%
)

rem /autologon:qubes added 2026-08-30. Without an autologon switch the installer PROMPTS for the
rem password, and this job runs as SYSTEM in session 0 where nothing can answer; the documented
rem fallback is an EMPTY password, which is wrong for these images (the account's password is
rem `qubes` - mgmt/autounattend.xml), and a guest that cannot log itself in has no qrexec session,
rem which would look like an install failure. matrix.sh's run_install has always passed
rem `/auto /autologon:qubes`; this job was the odd one out.
rem /reboot: same reason as the `ours` job - on a fresh PV install qrexec cannot answer until the
rem next boot, so stage 2 must reboot itself or the guest is stranded until prime-run's rescue.
call C:\qwtsetup\install.cmd /nodisk /auto /reboot /autologon:qubes >> %LOG% 2>&1
rem RC IS CAPTURED HERE, NOT READ AT THE EXIT. The copies below are commands and `copy` SETS
rem ERRORLEVEL, so `exit /b %ERRORLEVEL%` after them would report the COPY's result and hand
rem prime-run a 0 for every failed install - the exact class this file's own C12 comment warns
rem about ("outside a block, %ERRORLEVEL% expands per line at execution").
set RC=%ERRORLEVEL%
echo installer rc=%RC% >> %LOG%
rem THE REASON MUST LEAVE THE GUEST (2026-10-25). %LOG% is on C:, reachable only over qrexec - and
rem when the installer fails there IS no qrexec, so the one file that says WHY cannot be read. That
rem is not hypothetical: acceptance 40210151847 aborted at cell 1 holding `installer rc=1` on the
rem DIAG marker and nothing else. The specimen could not be asked afterwards either - qubes-prime.cmd
rem deletes its own task BEFORE running the job, so the primer never fires twice - and two full
rem string passes over an 8 GB memory image found no trace of the log in the file cache. The marker
rem recorded the rc and withheld the reason, which is the one thing it existed to prevent.
rem DIAG is FAT and the HOST reads it with mtools, needing nothing from the guest.
rem STAGE 2 IS NOT COVERED: it runs later from the resume task and appends to %LOG% after this
rem script has exited. This captures stage 1, which is where the rc above is raised.
if defined DIAGDRV copy /y "%LOG%" "%DIAGDRV%:\prime-installer.log" >nul 2>&1
if defined DIAGDRV copy /y "C:\qubes-win-idd-setup.log" "%DIAGDRV%:\primer.log" >nul 2>&1

exit /b %RC%
