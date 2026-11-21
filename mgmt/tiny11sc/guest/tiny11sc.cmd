@echo off
rem tiny11sc - add back what the image removed. Run from an elevated prompt. tiny11sc -List
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore.ps1" %*
exit /b %ERRORLEVEL%
