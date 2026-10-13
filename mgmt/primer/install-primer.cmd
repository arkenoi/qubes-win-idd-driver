@echo off
rem Staged as \payload\setup.cmd when the answer stick is built with PRIMER=1. Runs once, at the
rem first logon of the pristine golden being provisioned, and does exactly one thing: install the
rem resident primer hook so that CLONES of this golden can be driven later without a reinstall.
rem
rem Deliberately does NOT touch testsigning and does NOT reboot:
rem  - testsigning must stay OFF, because that is what makes an ST0 golden a valid precondition for
rem    the two-stage (E1) clean-install cell;
rem  - no reboot, so provisioning ends at a settled desktop where PRISTINE mode's visual
rem    confirmation still applies.
echo === answer-stick payload (PRIMER only - no QWT) === >> C:\qubes-win-idd-setup.log
mkdir C:\qubes-prime 2>nul
copy /y "%~dp0prime\qubes-prime.cmd" C:\qubes-prime\ >> C:\qubes-win-idd-setup.log 2>&1
schtasks /create /tn QubesPrime /sc onstart /ru SYSTEM /rl highest /f /tr "cmd /c C:\qubes-prime\qubes-prime.cmd" >> C:\qubes-win-idd-setup.log 2>&1
echo primer installed, testsigning left OFF, no reboot >> C:\qubes-win-idd-setup.log

rem COMPLETION MARKER. This file is the LAST thing that runs on a pristine base build, so its
rem finishing IS the build finishing. The host cannot ask the guest anything - a base has no QWT and
rem therefore no qrexec - so the guest states it instead, on a writable FAT volume the host reads
rem with mtools. That replaces the CPU-quiescence guess entirely: Win11 26300 idles at a steady
rem 44-48%% against a 15%% threshold, so that gate can never fire there and the build used to poll
rem until its 90-minute budget expired with the guest finished the whole time (measured 2026-10-13,
rem twice, ~40 wasted minutes each). A real marker ends the wait within one poll of being true.
rem No nested quotes here on purpose: cmd has no backslash escape and lint rule L3 refuses them.
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @vol %%d: 2>nul | find /i "DIAG" >nul && echo PRIMED-OK %DATE% %TIME% > %%d:\PRIMED-OK.TXT
echo completion marker written to the DIAG volume >> C:\qubes-win-idd-setup.log
