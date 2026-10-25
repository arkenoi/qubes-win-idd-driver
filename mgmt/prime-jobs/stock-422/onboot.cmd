@echo off
rem ===============================================================================================
rem  PRIME JOB: install GENUINE stock QWT 4.2.2 into a pristine, primed guest.
rem
rem  Called ONCE, as SYSTEM, by the resident primer hook (C:\qubes-prime\qubes-prime.cmd). Replaces
rem  the old route entirely: that one needed a full unattended Windows REINSTALL just to get an
rem  execution channel, because a pristine guest has no QWT and therefore no qrexec.
rem
rem  Stock needs testsigning ACTIVE IN THE CURRENT BOOT, so this is two passes either side of a
rem  reboot. The primer has already unregistered itself, so pass 2 is re-armed here explicitly.
rem ===============================================================================================
set LOG=C:\qubes-prime\stock-install.log

rem DIAG is found by LABEL, not by letter: letters are not stable across the installer's reboot.
set "DIAGDRV="
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if not defined DIAGDRV if exist "%%d:\" for /f "tokens=*" %%v in ('cmd /c vol %%d: 2^>nul ^| findstr /i "DIAG"') do set "DIAGDRV=%%d"
)

echo === stock 4.2.2 prime job %DATE% %TIME% >> %LOG%

reg query "HKLM\SYSTEM\CurrentControlSet\Control" /v SystemStartOptions | find /i "TESTSIGNING" >nul
if not errorlevel 1 goto install

rem --- pass 1: no testsigning yet -------------------------------------------------------------
rem Stage everything on C: first. The stick's drive letter is not stable across boots and the stick
rem may not even be attached next boot - the old route lost stage 2 exactly this way.
echo pass 1: staging to C: and enabling testsigning >> %LOG%
mkdir C:\stockqwt 2>nul
xcopy /e /i /y "%~dp0*" C:\stockqwt\ >> %LOG% 2>&1
bcdedit /set testsigning on >> %LOG% 2>&1
schtasks /create /tn QwtStockPass2 /sc onstart /delay 0000:30 /ru SYSTEM /rl highest /f /tr "cmd /c C:\stockqwt\onboot.cmd" >> %LOG% 2>&1
shutdown /r /t 15
exit /b 0

rem --- pass 2: testsigning active -------------------------------------------------------------
:install
schtasks /delete /tn QwtStockPass2 /f >nul 2>&1
echo pass 2: testsigning active, installing >> %LOG%

rem TRUST THE VENDOR'S OWN CA FIRST. Stock's drivers are signed by a private self-signed "Qubes
rem Windows Tools" CA; without it in TrustedPublisher, PnP raises "Would you like to install this
rem device software?" - which stock's README tells a human to click. This runs as SYSTEM in session
rem 0 where no dialog is visible, so the driver step fails and Burn returns 1603. Measured exactly
rem that on win10-u10, 2026-08-30. Seeding changes WHO CONSENTS, not what is installed.
for %%c in ("%~dp0certs\*.cer") do (
    certutil -addstore -f Root "%%~c" >> %LOG% 2>&1
    certutil -addstore -f TrustedPublisher "%%~c" >> %LOG% 2>&1
)

for %%e in ("%~dp0qubes-tools-*.exe") do set "STOCKEXE=%%~fe"
echo running %STOCKEXE% >> %LOG%
start /wait "" "%STOCKEXE%" /passive /norestart /log C:\qubes-prime\stock-burn.log >> %LOG% 2>&1
set RC=%ERRORLEVEL%
echo stock installer rc=%RC% >> %LOG%

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

if "%RC%"=="0"    goto ok
if "%RC%"=="3010" goto ok

rem A guest with no QWT has no qrexec, so THE SCREEN is the only channel a failure can reach. Show
rem the logs at the next logon (autologon is enforced) and let the screenshot read them.
echo FAILED rc=%RC% >> %LOG%
> "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\qwt-report.cmd" echo @echo off
>> "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\qwt-report.cmd" echo start "" notepad C:\qubes-prime\stock-install.log
>> "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\qwt-report.cmd" echo del "%%~f0"
shutdown /r /t 15
exit /b %RC%

:ok
echo stock QWT installed rc=%RC%, rebooting to bind drivers >> %LOG%
shutdown /r /t 15
exit /b 0
