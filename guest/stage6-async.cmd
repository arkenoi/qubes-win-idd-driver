@echo off
del /q C:\Users\Public\stage6-done.txt 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\stage6-cycle.ps1" -InstallToo > C:\Users\Public\stage6-result.txt 2>&1
echo DONE >> C:\Users\Public\stage6-done.txt
