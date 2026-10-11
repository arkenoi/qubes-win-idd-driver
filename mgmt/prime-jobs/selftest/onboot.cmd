@echo off
rem ===============================================================================================
rem  PRIME JOB: selftest - the smallest possible payload that PROVES the primer channel works.
rem
rem  Run this FIRST, before trusting any real job (stock-422, ours-nopvdisk). If the channel is
rem  broken, a real job fails in a way that looks like an installer problem and costs a day chasing
rem  the wrong thing - which is exactly how the 1603 hunt started.
rem
rem  THE PROOF HAS TO BE ON SCREEN. A primed guest is pristine Windows: no QWT, therefore no qrexec,
rem  therefore no way to read a file out of it. So this writes its evidence, then arranges for
rem  Notepad to display it at the next logon (autologon is enforced), and reboots. `qtest shot` then
rem  reads the result as pixels. A marker file nobody can read would prove nothing.
rem ===============================================================================================
set OUT=C:\qubes-prime\SELFTEST-OK.txt
mkdir C:\qubes-prime 2>nul

echo PRIMER SELFTEST PASSED > %OUT%
echo. >> %OUT%
echo The primer hook ran this job as: >> %OUT%
whoami >> %OUT% 2>&1
echo. >> %OUT%
echo Date: %DATE% %TIME% >> %OUT%
echo Job media was: %~dp0 >> %OUT%
echo. >> %OUT%
echo Windows build: >> %OUT%
ver >> %OUT% 2>&1
echo. >> %OUT%
echo Testsigning state (MUST be OFF on a base golden): >> %OUT%
reg query "HKLM\SYSTEM\CurrentControlSet\Control" /v SystemStartOptions >> %OUT% 2>&1
echo. >> %OUT%
echo QubesPrime task (MUST be gone - the hook unregisters itself before running a job): >> %OUT%
schtasks /query /tn QubesPrime >> %OUT% 2>&1

rem Show it at the next logon, once, then remove the shower.
> "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\prime-selftest.cmd" echo @echo off
>> "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\prime-selftest.cmd" echo start "" notepad C:\qubes-prime\SELFTEST-OK.txt
>> "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\prime-selftest.cmd" echo del "%%~f0"

shutdown /r /t 10
exit /b 0
