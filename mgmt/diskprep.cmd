@echo off
REM ===========================================================================
REM  WinPE disk preparation - partition the LARGEST disk, selected by size.
REM
REM  WRITTEN FROM SCRATCH 2026-10-13. The previous implementations are in git
REM  history; nothing here is carried over from them. Four design rules, each
REM  from a failure measured on this rig today:
REM
REM  1. NEVER EXIT NON-ZERO. This script is called from a windowsPE
REM     RunSynchronousCommand. A RunSynchronousCommand that exits non-zero
REM     aborts the whole pass, and Windows reports it as the opaque modal
REM     "Windows could not apply the Windows PE bootstrap setting specified in
REM     the unattend answer file" - which names nothing, appears minutes in,
REM     and leaves its reason on a ramdisk nobody can reach. That dialog cost
REM     two days. If this script cannot do its job it now FAILS OPEN: it logs
REM     why and exits 0, so Setup continues and stops instead at
REM     "cannot locate the disk and partition specified in <ImageInstall>",
REM     which names the actual problem. A legible failure beats an opaque one.
REM  2. NO LABELS, NO GOTO. This file has LF-only line endings (the repo's
REM     normal state) and cmd.exe mishandles label lookup in LF-only batch
REM     files, which can abort the script mid-run with a non-zero code - see
REM     rule 1 for what that then looks like.
REM  3. ONLY diskpart. No wmic (absent from the WinPE of Win11 26300), no
REM     findstr, no where, no PowerShell (not all WinPE images carry it).
REM     diskpart is in every WinPE this rig installs.
REM  4. POSITION, NEVER WORDS. diskpart's output is localised ("Disk" /
REM     "Datentraeger", and every status word), so a row is recognised by token
REM     position and by its size column being a number - never by matching a
REM     word.
REM
REM  WHY SIZE AND NOT A FIXED DiskID: a Qubes HVM presents THREE disks - root
REM  (80 GiB), private (20 GiB) and volatile (10 GiB) - and WinPE's enumeration
REM  order is NOT guaranteed to match the installed OS's. On 2026-08-07 a fixed
REM  DiskID had Setup pick a small disk and die on "requires at least 20000 MB
REM  of free space". Note the private volume is 20 GiB, which is itself large
REM  enough to satisfy Setup - so "partition everything and let
REM  InstallToAvailablePartition choose" is NOT safe here, and the largest disk
REM  really does have to be identified.
REM
REM  Everything is logged to X:\diskprep.log (WinPE's X: is a ramdisk).
REM ===========================================================================
setlocal EnableDelayedExpansion
set LOG=X:\diskprep.log
echo === diskprep %DATE% %TIME% === > %LOG%

REM --- ask diskpart what disks exist -----------------------------------------
echo list disk > X:\dp-list.txt
diskpart /s X:\dp-list.txt > X:\dp-list.out 2>&1
echo --- list disk --- >> %LOG%
type X:\dp-list.out >> %LOG%

REM --- pick the largest ------------------------------------------------------
REM Columns on a disk row are: Disk <n> <status> <size> <unit> [free] [unit].
REM tokens=2,4,5 therefore give the disk number, the size and its unit.
REM The numeric test is `set /a`: an undefined word ("Size", "Status") evaluates
REM to 0 and a punctuation row ("--------") is a syntax error whose output is
REM discarded - both leave SZ at 0 and are skipped. No findstr needed.
set BEST=
set BESTMB=0
for /f "tokens=2,4,5" %%a in (X:\dp-list.out) do (
    set SZ=0
    set /a SZ=%%b+0 2>nul
    set MB=0
    if !SZ! GTR 0 (
        if /i "%%c"=="TB" set /a MB=!SZ!*1048576
        if /i "%%c"=="GB" set /a MB=!SZ!*1024
        if /i "%%c"=="MB" set /a MB=!SZ!
        if !MB! GTR 0 (
            echo candidate: disk %%a is !MB! MB >> %LOG%
            if !MB! GTR !BESTMB! (
                set BESTMB=!MB!
                set BEST=%%a
            )
        )
    )
)

if "%BEST%"=="" (
    echo GIVING UP: no disk row recognised in the listing above. >> %LOG%
    echo Exiting 0 on purpose so Setup reports a legible ImageInstall error. >> %LOG%
    exit /b 0
)
if %BESTMB% LSS 25000 (
    echo GIVING UP: largest disk is %BEST% at %BESTMB% MB, too small for Windows. >> %LOG%
    echo Exiting 0 on purpose so Setup reports a legible ImageInstall error. >> %LOG%
    exit /b 0
)
echo selected disk %BEST% at %BESTMB% MB >> %LOG%

REM --- partition it ----------------------------------------------------------
REM MBR, one active primary spanning the disk: Qubes HVMs boot BIOS/SeaBIOS.
REM The other disks are deliberately left RAW, so that even if Setup were to
REM fall back to choosing a partition itself, there is only one to choose.
echo select disk %BEST%            > X:\dp-part.txt
echo clean                        >> X:\dp-part.txt
echo convert mbr                  >> X:\dp-part.txt
echo create partition primary     >> X:\dp-part.txt
echo select partition 1           >> X:\dp-part.txt
echo active                       >> X:\dp-part.txt
echo format fs=ntfs quick label="Windows" >> X:\dp-part.txt
echo assign letter=C              >> X:\dp-part.txt
echo exit                         >> X:\dp-part.txt
echo --- partitioning disk %BEST% --- >> %LOG%
diskpart /s X:\dp-part.txt >> %LOG% 2>&1
echo diskpart returned %ERRORLEVEL% >> %LOG%

REM Rule 1: the return code is recorded above, never propagated.
exit /b 0
