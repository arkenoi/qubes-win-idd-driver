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
rem AND IT MUST SAY WHICH. The line below used to announce "completion marker written to the DIAG
rem volume" UNCONDITIONALLY, after a for/&& that writes nothing when no volume matches - so the
rem setup log claimed success on every build while the marker was never produced. MEASURED
rem 2026-10-15: across every pristine build on record the host attached the marker volume 6 times
rem and logged "PRIMED-OK marker present" ZERO times, and the budget-expiry this marker was added
rem to cure (the 2026-10-13 measurement in the comment above) happened a third time, on win11r-base,
rem wasting 86 minutes. A success message that cannot fail hides the one fact worth having.
set PRIMEDOK=
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @vol %%d: 2>nul | find /i "DIAG" >nul && (echo PRIMED-OK %DATE% %TIME% > %%d:\PRIMED-OK.TXT) && set PRIMEDOK=%%d
if defined PRIMEDOK echo completion marker written to %PRIMEDOK%: >> C:\qubes-win-idd-setup.log
if not defined PRIMEDOK echo COMPLETION MARKER NOT WRITTEN - no volume labelled DIAG was visible to the guest >> C:\qubes-win-idd-setup.log
