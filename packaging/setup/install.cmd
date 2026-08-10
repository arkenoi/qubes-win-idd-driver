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
REM      it becomes the display, the emulated VGA adapter is disabled; there is
REM      no switch to skip it. /idd is accepted but redundant.)
REM     install.cmd /iddonly     add/activate the IddCx driver on a guest that ALREADY has
REM                              QWT installed, WITHOUT re-running the MSI - no version gate,
REM                              no PV-disk 0x7B gate. Use this to add IDD to an install that
REM                              predates IDD-by-default. Reboots when done.
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
if /i "%~1"=="/nonet"  ( set "PSARGS=!PSARGS! -NoPvNetwork"      & shift & goto parse )
if /i "%~1"=="/nodisk" ( set "PSARGS=!PSARGS! -NoPvDisk"         & shift & goto parse )
if /i "%~1"=="/acceptpvdiskupgrade" ( set "PSARGS=!PSARGS! -AcceptPvDiskUpgrade" & shift & goto parse )
if /i "%~1"=="/noapptweaks" ( set "PSARGS=!PSARGS! -NoAppTweaks" & shift & goto parse )
if /i "%~1"=="/iddonly" ( set "IDDONLY=1" & shift & goto parse )
echo Unknown option: %~1
echo Valid options: /auto /idd /iddonly /nonet /nodisk /acceptpvdiskupgrade /noapptweaks
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
if defined IDDONLY (
  REM Add/activate the IddCx driver on a guest that ALREADY has QWT - no MSI, no version gate,
  REM no PV-disk 0x7B gate. For an existing install that predates IDD-by-default (GWeck's case).
  powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%activate-idd.ps1" -Root "%HERE%"
) else (
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
