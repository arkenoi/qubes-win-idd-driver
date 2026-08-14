@echo off
REM ===========================================================================
REM  Qubes Windows Tools (improved GUI agent) - installer entry point.
REM  Run this ELEVATED on a clean Windows guest. It self-elevates if you
REM  double-click it.
REM
REM  Usage:
REM     install.cmd              two stages, you reboot between them
REM     install.cmd /auto        reboots and resumes by itself (unattended)
REM     (the Qubes IddCx display driver is installed AND ACTIVATED BY DEFAULT -
REM      it becomes the display, the emulated VGA adapter is disabled.
REM      /idd is accepted but redundant; /noidd opts out.)
REM     install.cmd /noidd       do NOT activate the IddCx driver: leave the guest on the
REM                              emulated Basic Display Adapter. The driver files still ship,
REM                              nothing touches the driver store, the VGA adapter is left
REM                              enabled. Use this if the IDD misbehaves on your hardware -
REM                              you lose arbitrary/dom0-following resolutions, everything
REM                              else works. See the IddCx section of README.txt.
REM     install.cmd /iddonly     add/activate the IddCx driver on a guest that ALREADY has
REM                              QWT installed, WITHOUT re-running the MSI - no version gate,
REM                              no PV-disk 0x7B gate. Use this to add IDD to an install that
REM                              predates IDD-by-default. Reboots when done.
REM     install.cmd /iddoff      the reverse of /iddonly, and the RECOVERY path: re-enable the
REM                              emulated VGA adapter and remove the IDD device on a guest that
REM                              already has it, without touching QWT. Reboots when done.
REM     install.cmd /updatesonly deploy the Windows Update agent on a guest that ALREADY has
REM                              QWT: compiles the relay, places the agent, and registers the
REM                              scheduled scan that reports update availability to dom0. No MSI.
REM                              (A NORMAL install already does this - /updatesonly is for
REM                               retrofitting a guest installed before it was default.)
REM     install.cmd /noupdates   skip the Windows Update agent. Updates are dom0-owned in this
REM                              model - without the agent the qube reports no updates and the
REM                              Qubes Update GUI cannot update it. See README.txt.
REM     install.cmd /nonet       omit the PV network drivers (see README.txt)
REM     install.cmd /nodisk      omit the PV disk drivers (diagnostic only)
REM     install.cmd /noapptweaks skip the app HW-accel pre-tweak (registry
REM                              policies making Office/browsers/Slack render
REM                              in software - see README.txt)
REM     install.cmd /acceptpvdiskupgrade
REM                              remove an existing QWT even when the boot disk
REM                              is on the PV disk path - can bugcheck 0x7B at
REM                              the intermediate reboot; read the UPGRADING
REM                              FROM STOCK QWT section of README.txt FIRST
REM  Flags combine:  install.cmd /auto /nonet
REM
REM  Read README.txt first - in particular the NETWORKING and TEST-SIGNING
REM  sections. Everything is logged to C:\qwt-improved-install.log.
REM ===========================================================================
setlocal EnableDelayedExpansion

set "HERE=%~dp0"
REM %~dp0 ends with a backslash, and PowerShell's argument parser reads the resulting
REM  -Root "C:\path\"  as an ESCAPED QUOTE: the script receives  C:\path"  and dies with
REM "Illegal characters in path". That is why /iddonly failed in the field with a raw
REM PowerShell error (forum 42717 post 35: the guest log shows -Root as  C:\qwtc" ).
REM HEREQ is the same directory WITHOUT the trailing backslash - use it for every value
REM passed INTO a script; -File "%HERE%name.ps1" is unaffected because a name follows.
set "HEREQ=%HERE:~0,-1%"
REM Capture the ORIGINAL argument line before parsing consumes it: the UAC relaunch
REM below has to hand the same flags to the elevated copy of this script.
set "RAWARGS=%*"
set "PSARGS="
set "AUTO="
set "IDDONLY="

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="/auto"   ( set "PSARGS=!PSARGS! -Auto"            & set "AUTO=1" & shift & goto parse )
if /i "%~1"=="/idd"    ( set "PSARGS=!PSARGS! -InstallIddDriver" & shift & goto parse )
if /i "%~1"=="/noidd"  ( set "PSARGS=!PSARGS! -NoIddDriver"      & shift & goto parse )
if /i "%~1"=="/nonet"  ( set "PSARGS=!PSARGS! -NoPvNetwork"      & shift & goto parse )
if /i "%~1"=="/nodisk" ( set "PSARGS=!PSARGS! -NoPvDisk"         & shift & goto parse )
if /i "%~1"=="/acceptpvdiskupgrade" ( set "PSARGS=!PSARGS! -AcceptPvDiskUpgrade" & shift & goto parse )
if /i "%~1"=="/noapptweaks" ( set "PSARGS=!PSARGS! -NoAppTweaks" & shift & goto parse )
if /i "%~1"=="/noupdates" ( set "PSARGS=!PSARGS! -NoUpdaterAgent" & shift & goto parse )
if /i "%~1"=="/iddonly" ( set "IDDONLY=1" & shift & goto parse )
if /i "%~1"=="/iddoff" ( set "IDDOFF=1" & shift & goto parse )
if /i "%~1"=="/updatesonly" ( set "UPDATESONLY=1" & shift & goto parse )
echo Unknown option: %~1
echo Valid options: /auto /idd /noidd /iddonly /iddoff /updatesonly /noupdates /nonet /nodisk /acceptpvdiskupgrade /noapptweaks
exit /b 87
:parsed

REM --- elevation check; relaunch through UAC if needed -----------------------
net session >nul 2>&1
if not errorlevel 1 goto elevated
echo Not elevated - requesting administrator rights...
if defined RAWARGS (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%RAWARGS%' -Verb RunAs"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
)
exit /b 0

:elevated
REM Every branch below runs a script that must be PRESENT on this medium. A missing one used
REM to surface as a raw PowerShell "file not found" / InvalidOperationException with no hint
REM about which file or why (field report, forum 42717 post 35) - so each is checked here and
REM named. An OLD medium genuinely does not carry activate-idd.ps1; say so.
if defined IDDONLY (
  REM Add/activate the IddCx driver on a guest that ALREADY has QWT - no MSI, no version gate,
  REM no PV-disk 0x7B gate. For an existing install that predates IDD-by-default (GWeck's case).
  call :needfile "%HERE%activate-idd.ps1" /iddonly || exit /b 66
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%activate-idd.ps1" -Root "%HEREQ%"
) else if defined IDDOFF (
  REM Recovery: put the guest back on the emulated VGA and remove the IDD device. Runs on a
  REM guest whose display is already unusable, so it must not depend on the IDD working.
  call :needfile "%HERE%deactivate-idd.ps1" /iddoff || exit /b 66
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%deactivate-idd.ps1" -Root "%HEREQ%"
) else if defined UPDATESONLY (
  REM Deploy the Windows Update agent on a guest that ALREADY has QWT: compile the relay, place
  REM the agent, register the scheduled scan that reports update availability to dom0. No MSI.
  call :needfile "%HERE%install-updater-agent.ps1" /updatesonly || exit /b 66
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%install-updater-agent.ps1" -SetupRoot "%HEREQ%" -BinDir "C:\Program Files\Qubes Tools\bin"
) else (
  call :needfile "%HERE%Install-QwtImproved.ps1" "the installer" || exit /b 66
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%Install-QwtImproved.ps1"%PSARGS%
)
set RC=%errorlevel%
echo.
if %RC%==0  echo Done. Reboot if the script asked you to.
if %RC%==10 echo Stage complete - REBOOT NOW, then run install.cmd again.
if %RC% GTR 10 echo FAILED with %RC% - see C:\qwt-improved-install.log
REM Keep the window open so a double-click user can read the outcome. With /auto the
REM machine is rebooting on a timer, so pausing there would be actively unhelpful.
if not defined AUTO pause
exit /b %RC%

REM --- helpers ---------------------------------------------------------------
REM :needfile <path> <what-needs-it>  -> 0 if present, 1 (after an explanation) if not.
:needfile
if exist "%~1" exit /b 0
echo.
echo ERROR: %~nx1 is not on this medium, so %~2 cannot run.
echo   looked in: %HERE%
echo   This usually means the download predates the option you asked for. Get a newer
echo   release, or run install.cmd with no options for a normal install.
echo.
if not defined AUTO pause
exit /b 1
