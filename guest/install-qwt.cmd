@echo off
REM ============================================================================
REM  Qubes Windows Tools 4.2.2 - unattended install for win-idd-test
REM  Run ELEVATED, AFTER "bcdedit /set testsigning on" + a reboot.
REM  Files required next to this script:
REM     vc_redist.x64.exe   (sha256 1ad7988c17663cc742b01bef1a6df2ed1741173009579ad50a94434e54f56073)
REM     installer.msi       (sha256 7049322128d1cf7d9dc2a48f69ef91a5893a8f779d3b2ad7d25fdfc8eee3baf4)
REM  Both were extracted from qubes-tools-4.2.2.exe (WiX v4 Burn bundle); the
REM  bundle CANNOT take ADDLOCAL, so the MSI is driven directly.
REM ============================================================================
setlocal
set QWT=%~dp0
set LOG=C:\qwt-install

REM --- 0. sanity: testsigning must be active in the CURRENT boot -------------
reg query "HKLM\SYSTEM\CurrentControlSet\Control" /v SystemStartOptions | find /i "TESTSIGNING" >nul
if errorlevel 1 (
  echo FATAL: testsigning not active. Run "bcdedit /set testsigning on" and reboot.
  exit /b 101
)

REM --- 1. pre-seed gui-agent config so the MSI does NOT overwrite it ---------
REM     The MSI seeds SeamlessMode=0 / DisableCursor=1 only when its AppSearch
REM     does not already find the value (conditions NOT GUI_SEAMLESS_SET /
REM     NOT GUI_CURSOR_SET). Writing them first makes ours win. /reg:64 because
REM     the MSI's RegLocator is 64-bit; a WOW-redirected write would be ignored.
reg add "HKLM\Software\Invisible Things Lab\Qubes Tools" /v SeamlessMode  /t REG_DWORD /d 1 /f /reg:64 >nul
reg add "HKLM\Software\Invisible Things Lab\Qubes Tools" /v DisableCursor /t REG_DWORD /d 0 /f /reg:64 >nul
REM     LogDir MUST be pre-seeded: the MSI has two components racing to write it
REM     ([INSTALL_DIR]log vs "Q:\Qubes Logs", identical NOT LOG_DIR_SET condition);
REM     if Q:\ wins and does not exist, gui-agent logs vanish (breaks Phase 1A).
reg add "HKLM\Software\Invisible Things Lab\Qubes Tools" /v LogDir /t REG_SZ /d "C:\Program Files\Qubes Tools\log" /f /reg:64 >nul
REM     optional: verbose agent logging for Phase 1A instrumentation
REM reg add "HKLM\Software\Invisible Things Lab\Qubes Tools\gui-agent" /v LogLevel /t REG_DWORD /d 4 /f /reg:64 >nul

REM --- 1b. trust the six QWT self-signed certs in Root AND TrustedPublisher --
REM     The MSI only installs them to LocalMachine\Root; without TrustedPublisher
REM     the PnP driver-store operations under /qn can stall or fail on the
REM     "install this device software?" trust prompt (iso-README tells humans to
REM     click it - nobody is clicking here).
for %%c in ("%QWT%SigningCert*.cer") do (
  certutil -addstore -f Root "%%~c" >nul
  certutil -addstore -f TrustedPublisher "%%~c" >nul
)

REM --- 2. VC++ 2015-2022 x64 runtime (Burn's prereq package) -----------------
"%QWT%vc_redist.x64.exe" /quiet /norestart
if %errorlevel% neq 0 if %errorlevel% neq 3010 if %errorlevel% neq 1638 (
  echo FATAL: vc_redist failed with %errorlevel%
  exit /b %errorlevel%
)

REM --- 3. Qubes Windows Tools, explicit feature set --------------------------
REM   INCLUDED : PvDriversCore (xenbus+xeniface -> gnttab/vchan, REQUIRED)
REM              Core          (qubesdb, qrexec agent, file/clipboard handlers)
REM              Gui           (gui-agent.exe + QubesGuiWatchdog service)
REM              PvDriversNetwork (xenvif/xennet - harmless offline; drop if unwanted)
REM   OMITTED  : PvDriversDisk (xenvbd/xencrsh - documented BSOD risk)
REM              MoveUsers     (BootExecute relocate-dir.exe C:\Users Q:\Users)
REM              Autologon     (randomises the local password; unattend.xml owns autologon)
REM   There is NO video/WDDM driver in QWT 4.2.2 - nothing to exclude.
msiexec /i "%QWT%installer.msi" /qn /norestart ^
  ADDLOCAL=PvDriversCore,Core,Gui,PvDriversNetwork ^
  REBOOT=ReallySuppress ^
  MSIFASTINSTALL=7 ^
  /l*v "%LOG%.log"
set RC=%errorlevel%

if %RC%==0    goto ok
if %RC%==3010 goto ok
echo FATAL: msiexec failed with %RC% - see %LOG%.log
exit /b %RC%

:ok
echo QWT_INSTALL_OK rc=%RC%
REM Drivers + services need a reboot to bind. Caller decides; uncomment to self-reboot:
REM shutdown /r /t 5 /c "QWT installed"
exit /b 0
