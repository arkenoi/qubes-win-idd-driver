@echo off

rem ===============================================================================================
rem  CLEAR THE DATED PASSWORD FUSE, BEFORE ANYTHING ELSE IN THIS JOB NEEDS A LOGON.
rem
rem  Windows' default "Maximum password age" is 42 days and every image inherits it, so each golden
rem  carries an expiry set at build time. MEASURED 2026-10-11: the win10 image's password was set
rem  30/08/2026 and came due 11/10/2026 - that first boot sat on "Your password has expired",
rem  autologon could not proceed, qrexec never came up, and the guest was unreachable. prime-run
rem  CLONES a base and boots it rather than reinstalling, so a blown fuse in the base breaks every
rem  clean-install cell that enters through it.
rem
rem  This hook runs as SYSTEM at boot, before and independently of any interactive logon, so it is
rem  the one place that can clear the fuse in time. No password is needed: "expired" is derived from
rem  pwdLastSet + maxPwdAge unless DONT_EXPIRE_PASSWORD is set, so setting that flag makes the
rem  expired condition false immediately. Both levers, because either alone can be re-imposed.
rem
rem  NOT wmic: deprecated and ABSENT from recent Windows 11 builds (these guests are 26100/
rem  26300), so it would SILENTLY do nothing on exactly the images that matter.
rem  ORDER MATTERS: "must change at next logon" and "password never expires" are MUTUALLY
rem  EXCLUSIVE, so Set-LocalUser THROWS while the latch is set - an account sitting at the
rem  expired wall would keep its fuse. Clear the latch first, then pin. Logs to C:\qubes-pwfix.log.
rem ===============================================================================================
net accounts /maxpwage:unlimited >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$l='C:\qubes-pwfix.log'; function N($s){\"[{0:yyyy-MM-dd HH:mm:ss}] {1}\" -f (Get-Date),$s|Add-Content $l}; N ('BEFORE '+(((net accounts) -match 'Maximum password age') -replace '\s+',' ')); net accounts /maxpwage:unlimited|Out-Null; foreach($u in Get-LocalUser|Where-Object{$_.Enabled}){net user $u.Name /logonpasswordchg:no|Out-Null; try{Set-LocalUser -Name $u.Name -PasswordNeverExpires $true}catch{N ('SET FAILED '+$u.Name)}}; N ('AFTER '+(((net accounts) -match 'Maximum password age') -replace '\s+',' ')); foreach($u in Get-LocalUser|Where-Object{$_.Enabled}){N ('AFTER account '+$u.Name+' expires='+$(if($null -eq $u.PasswordExpires){'NEVER'}else{$u.PasswordExpires}))}" >nul 2>&1
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
