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
