@echo off
rem STAGE 2 - runs as SYSTEM at boot (QWTStage2 scheduled task), testsigning now active.
rem Installs QWT 4.2.2 with explicit feature selection via install-qwt.cmd
rem (PvDriversCore,Core,Gui,PvDriversNetwork - NO PvDriversDisk/MoveUsers/Autologon).
schtasks /delete /tn QWTStage2 /f >nul 2>&1
echo === stage2 start %DATE% %TIME% === >> C:\qubes-win-idd-setup.log

call C:\payload\install-qwt.cmd >> C:\qubes-win-idd-setup.log 2>&1
set RC=%errorlevel%
echo install-qwt.cmd rc=%RC% >> C:\qubes-win-idd-setup.log

if %RC% neq 0 (
    echo === stage2 FAILED rc=%RC% - see C:\qwt-install.log === >> C:\qubes-win-idd-setup.log
    exit /b %RC%
)
echo === stage2 done, rebooting into QWT === >> C:\qubes-win-idd-setup.log
shutdown /r /t 15
