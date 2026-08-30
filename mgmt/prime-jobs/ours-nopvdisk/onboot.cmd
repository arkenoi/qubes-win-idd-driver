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

call C:\qwtsetup\install.cmd /nodisk /auto >> %LOG% 2>&1
echo installer rc=%ERRORLEVEL% >> %LOG%
exit /b %ERRORLEVEL%
