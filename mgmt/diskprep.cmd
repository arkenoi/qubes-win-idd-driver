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
REM diskpart's own "list disk", NOT wmic. WMIC is GONE from the WinPE of Win11 build 26300
REM (retail 26300.9457, measured 2026-10-01: 0 wmic.exe in its boot.wim against 10 in the German
REM 25H2 one), and with it this script found no disk, partitioned nothing, and Setup stopped on its
REM "Select location to install Windows 11" page for good. diskpart is in every WinPE.
REM Its output is LOCALISED ("Disk"/"Datentraeger", the status words), so a row is recognised by
REM POSITION, never by a word: token 2 a disk number, token 4 a size number, token 5 its unit
REM (KB/MB/GB/TB, not localised). Header, separator and banner lines fail the number tests. A
REM two-word status ("No Media") shifts the tokens and its row is skipped - no install target.
REM The number tests use the FOR variables (%%b, %%d): a !delayed! variable is NOT expanded on the
REM left of a pipe, which runs in a child cmd without delayed expansion.
set BEST=
set BESTMB=0
echo list disk > X:\diskprep-ld.txt
diskpart /s X:\diskprep-ld.txt > X:\diskprep-ld.out 2>&1
type X:\diskprep-ld.out >> %LOG%
for /f "tokens=1-5" %%a in (X:\diskprep-ld.out) do (
    set NUM=1
    echo %%b| findstr /r "^[0-9][0-9]*$" >nul || set NUM=0
    echo %%d| findstr /r "^[0-9][0-9]*$" >nul || set NUM=0
    if "!NUM!"=="1" (
        set SZMB=
        if /i "%%e"=="TB" set /a SZMB=%%d*1048576
        if /i "%%e"=="GB" set /a SZMB=%%d*1024
        if /i "%%e"=="MB" set /a SZMB=%%d
        if /i "%%e"=="KB" set SZMB=0
        if defined SZMB (
            echo candidate disk %%b size %%d %%e ~!SZMB! MB >> %LOG%
            if !SZMB! GTR !BESTMB! (
                set BESTMB=!SZMB!
                set BEST=%%b
            )
        )
    )
)

if "%BEST%"=="" (
    echo FATAL: no disk recognised in diskpart list disk - see the listing above >> %LOG%
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
