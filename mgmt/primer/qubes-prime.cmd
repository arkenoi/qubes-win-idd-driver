@echo off
rem ===============================================================================================
rem  QUBES TEST-RIG PRIMER - resident hook, runs as SYSTEM at every boot.
rem
rem  WHY IT EXISTS. A pristine Windows guest (our ST0 goldens) has no QWT, therefore no qrexec,
rem  therefore NO WAY to run anything in it. FirstLogonCommands fire only at the first logon of a
rem  fresh install and never again, so cloning a pristine golden does not get you a second shot at
rem  them. That is why every "install stock QWT into a clean guest" job kept degrading into a full
rem  20-minute Windows reinstall: the reinstall was not needed for Windows, it was needed for the
rem  one execution channel a pristine guest has.
rem
rem  This is that channel, and nothing more: attach a stick carrying \qubes-prime\onboot.cmd and it
rem  runs, once.
rem
rem  IT MUST NOT CONTAMINATE ANY TEST RESULT. Every guest cloned from a primed golden carries this
rem  file, including guests under test, so its design rules are:
rem
rem   1. INERT BY DEFAULT. With no primer media attached this script performs `if exist` tests and
rem      exits. It writes NOTHING - no log, no marker, no registry, no file. A boot with no stick is
rem      byte-for-byte the same as a boot without the primer.
rem   2. ONE SHOT. It unregisters its own task BEFORE running the job, so a job that reboots (they
rem      all do) cannot re-trigger it, and a guest that has been primed is no longer primed.
rem   3. AUDITABLE. Having fired leaves C:\qubes-prime\fired.mark. The harness asserts that mark is
rem      ABSENT on any guest whose result is being graded, so a primed guest can never be silently
rem      mistaken for a clean one.
rem   4. NON-COLLIDING. It looks for \qubes-prime\onboot.cmd. Every other stick this rig builds uses
rem      \payload\setup.cmd, so no existing or future answer stick can trigger this by accident.
rem   5. TEST-RIG ONLY. This is baked into golden IMAGES at provisioning time. It is not part of the
rem      QWT package and must never ship in one.
rem ===============================================================================================
set "PRIMEDRV="
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if not defined PRIMEDRV if exist "%%d:\qubes-prime\onboot.cmd" set "PRIMEDRV=%%d"
)
rem No primer media: leave without touching a thing. This is the path taken on every boot of every
rem guest under test, and it is deliberately write-free.
if not defined PRIMEDRV exit /b 0

rem Unregister FIRST. The job is expected to reboot; if the task still existed it would fire again
rem on the next boot and re-run a half-finished install.
schtasks /delete /tn QubesPrime /f >nul 2>&1
mkdir C:\qubes-prime 2>nul
echo fired from %PRIMEDRV%: at %DATE% %TIME% > C:\qubes-prime\fired.mark
call "%PRIMEDRV%:\qubes-prime\onboot.cmd" >> C:\qubes-prime\onboot.log 2>&1
exit /b 0
