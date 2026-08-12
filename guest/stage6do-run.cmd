@echo off
del /q C:\Users\Public\stage6do-done.txt 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\stage6-do-clean.ps1"
