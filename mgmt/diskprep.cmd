@echo off
REM ===========================================================================
REM  WinPE disk preparation: partition the LARGEST disk, by size, not by ID.
REM
REM  WHY THIS EXISTS (measured 2026-08-07): the answer file used to hardcode
REM  <DiskID>0</DiskID>. A Qubes HVM presents THREE disks - root (80 GiB),
REM  private (2 GiB) and volatile (10 GiB) - and WinPE's enumeration order is
REM  NOT guaranteed to match the installed OS's (which shows root as Disk 0).
REM  On one clean-path run Setup selected a small disk and died with "Windows
REM  cannot be installed to the selected partition. Installation requires at
REM  least 20000 MB of free space", wasting a whole install cycle. Selecting by
REM  size removes the ambiguity permanently: only the root volume is ever large
REM  enough, and the other two are left RAW so Setup cannot pick them.
REM
REM  Runs from the media root in the windowsPE pass, BEFORE image apply.
REM  Everything is logged to X:\diskprep.log (visible in a Shift+F10 shell and
REM  copied nowhere - WinPE's X: is a ramdisk).
REM ===========================================================================
setlocal EnableDelayedExpansion
set LOG=X:\diskprep.log
echo === diskprep %DATE% %TIME% === > %LOG%

REM --- find the largest disk -------------------------------------------------
REM 'wmic diskdrive' reports Size in BYTES. Compare in MB to stay inside cmd's
REM 32-bit signed arithmetic (80 GiB in bytes overflows it).
set BEST=
set BESTMB=0
for /f "skip=1 tokens=1,2" %%a in ('wmic diskdrive get Index^,Size 2^>nul') do (
    if not "%%b"=="" (
        set IDX=%%a
        set SZ=%%b
        REM strip to MB by chopping the last 6 digits (bytes -> ~MB, close enough
        REM to rank disks; exactness is irrelevant, only the ordering matters)
        set SZMB=!SZ:~0,-6!
        if "!SZMB!"=="" set SZMB=0
        echo candidate disk !IDX! size !SZ! bytes ~!SZMB! MB >> %LOG%
        if !SZMB! GTR !BESTMB! (
            set BESTMB=!SZMB!
            set BEST=!IDX!
        )
    )
)

if "%BEST%"=="" (
    echo FATAL: no disks reported by wmic >> %LOG%
    exit /b 1
)
REM A Windows 10/11 install needs ~20 GB. Refusing here produces a clear log line
REM instead of Setup's generic partition error further down the line.
if %BESTMB% LSS 25000 (
    echo FATAL: largest disk is %BEST% at ~%BESTMB% MB - too small to install Windows >> %LOG%
    exit /b 1
)
echo selected disk %BEST% (~%BESTMB% MB) >> %LOG%

REM --- partition it ----------------------------------------------------------
REM MBR + one active primary spanning the disk: Qubes HVMs boot BIOS/SeaBIOS.
(
    echo select disk %BEST%
    echo clean
    echo convert mbr
    echo create partition primary
    echo select partition 1
    echo active
    echo format fs=ntfs quick label="Windows"
    echo assign letter=C
    echo exit
) > X:\diskprep-dp.txt
diskpart /s X:\diskprep-dp.txt >> %LOG% 2>&1
set DPRC=%ERRORLEVEL%
echo diskpart rc=%DPRC% >> %LOG%
if not "%DPRC%"=="0" exit /b %DPRC%

REM Leave the other disks RAW on purpose: with no installable partition on them,
REM InstallToAvailablePartition in the answer file can only land on C:.
exit /b 0
