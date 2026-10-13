@echo off
REM logvol-winpe-copy.cmd - copy WinPE's ramdisk logs onto the secondary log volume BEFORE Setup
REM tears the ramdisk down (mgmt/harness/logvol-lib.sh, "THE INSTALL PHASE"). Nice-to-have per the
REM owner (2026-10-13); it falls out of the volume being the second removable USB device WinPE sees.
REM
REM HOW A CALLER USES IT: stage this file on the answer stick next to diskprep.cmd and name it in the
REM answer file as a windowsPE RunSynchronousCommand that runs AFTER diskprep (and after anything
REM else whose log matters). Neither change is made in this pass.
REM
REM TWO RULES, both paid for on 2026-10-13:
REM  1. SYNCHRONOUS, INSIDE THIS COMMAND. A copier launched detached from a RunSynchronousCommand
REM     (start "" /min cmd /c ...) produced NOTHING: Setup reaps the child when the command returns.
REM     Nothing here is started; every copy runs in this process and returns before this file does.
REM  2. NEVER EXIT NON-ZERO (diskprep.cmd rule 1): a non-zero RunSynchronousCommand aborts the pass
REM     with the opaque "could not apply the Windows PE bootstrap setting" dialog. A failed copy is a
REM     lost log, never a lost install.
REM No labels, no goto (LF-only batch files break label lookup), no findstr/wmic/PowerShell.
REM The volume is found BY ITS TAG FILE (logvol_create writes LOGVOL.TAG), never by letter.
set "LOGVOL="
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if not defined LOGVOL if exist "%%d:\LOGVOL.TAG" set "LOGVOL=%%d"
)
if not defined LOGVOL exit /b 0
set "DEST=%LOGVOL%:\winpe"
if not exist "%DEST%" mkdir "%DEST%" >nul 2>&1
echo === logvol-winpe-copy %DATE% %TIME% >> "%DEST%\copy.log" 2>nul
REM X:\*.log is diskprep.log and friends; dp-*.out/.txt are diskpart's scripts and answers;
REM Panther holds Setup's own setupact/setuperr for the WinPE phase.
copy /y X:\*.log "%DEST%\" >> "%DEST%\copy.log" 2>&1
copy /y X:\dp-*.* "%DEST%\" >> "%DEST%\copy.log" 2>&1
if exist X:\Windows\Panther\setupact.log copy /y X:\Windows\Panther\setupact.log "%DEST%\" >> "%DEST%\copy.log" 2>&1
if exist X:\Windows\Panther\setuperr.log copy /y X:\Windows\Panther\setuperr.log "%DEST%\" >> "%DEST%\copy.log" 2>&1
if exist "X:\$WINDOWS.~BT\Sources\Panther\setupact.log" copy /y "X:\$WINDOWS.~BT\Sources\Panther\setupact.log" "%DEST%\setupact-bt.log" >> "%DEST%\copy.log" 2>&1
if exist "X:\$WINDOWS.~BT\Sources\Panther\setuperr.log" copy /y "X:\$WINDOWS.~BT\Sources\Panther\setuperr.log" "%DEST%\setuperr-bt.log" >> "%DEST%\copy.log" 2>&1
echo === done %TIME% >> "%DEST%\copy.log" 2>nul
exit /b 0
