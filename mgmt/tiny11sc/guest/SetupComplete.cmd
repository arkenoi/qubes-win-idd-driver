@echo off
rem tiny11sc: Windows Setup runs %WINDIR%\Setup\Scripts\SetupComplete.cmd once, as SYSTEM, after the
rem image is applied and before OOBE and the first logon. Everything that must go through the
rem servicing stack (capabilities, optional features, provisioned apps) is removed HERE, by DISM on
rem the running OS - never by deleting files offline - so the component store stays consistent and
rem the result stays updatable and every removal stays reversible (restore.ps1).
rem Windows does not run this file when the install used an OEM product key on a non-Enterprise
rem edition; the generic retail key and "I don't have a product key" both run it.
if not exist "%WINDIR%\tiny11sc" mkdir "%WINDIR%\tiny11sc"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%WINDIR%\tiny11sc\strip.ps1" >> "%WINDIR%\tiny11sc\setupcomplete.log" 2>&1
echo strip.ps1 exit %ERRORLEVEL% >> "%WINDIR%\tiny11sc\setupcomplete.log"
exit /b 0
