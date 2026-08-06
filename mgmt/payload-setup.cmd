@echo off
rem STAGE 1 first-logon payload for win-idd-test (runs from C:\payload, staged by $OEM$).
rem The QWT 4.2.2 MSI carries a launch condition requiring TESTSIGNING in the CURRENT
rem boot's SystemStartOptions, so QWT install must wait for the next boot -> two stages:
rem   stage 1 (this): testsigning on + trust certs + schedule stage 2 + reboot
rem   stage 2 (setup2.cmd, SYSTEM boot task): vc_redist + msiexec ADDLOCAL + reboot
rem Logs to C:\qubes-win-idd-setup.log. NOTE: each reboot HALTS the qube (Qubes
rem on_reboot=destroy) - the orchestrator restarts it.
set SRC=%~dp0
echo === stage1 start %DATE% %TIME% === > C:\qubes-win-idd-setup.log

rem ANSWER-DISC route support: on the repack route $OEM$ already staged us at
rem C:\payload, but when this script runs straight off the second CD the QWTStage2
rem task below would point at a C:\payload that never exists (the disc's letter is
rem also not stable across boots). COPY, don't retarget: the task must survive the
rem disc being unassigned. Found 2026-08-07 - stage 2 silently never fired on the
rem answer-disc route.
if /i not "%SRC%"=="C:\payload\" (
    echo staging payload %SRC% to C:\payload >> C:\qubes-win-idd-setup.log
    xcopy /e /i /y "%SRC%*" C:\payload\ >> C:\qubes-win-idd-setup.log 2>&1
)

rem firstboot-setup.ps1 finds the cert under USERPROFILE - put it there first
if exist "%SRC%qubesidd-test.cer" copy /y "%SRC%qubesidd-test.cer" "%USERPROFILE%\" >> C:\qubes-win-idd-setup.log 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%firstboot-setup.ps1" >> C:\qubes-win-idd-setup.log 2>&1

rem Stage 2 as a SYSTEM boot task: immune to UAC token filtering and autologon timing.
schtasks /create /tn QWTStage2 /tr "cmd /c C:\payload\setup2.cmd" /sc onstart /ru SYSTEM /rl HIGHEST /f >> C:\qubes-win-idd-setup.log 2>&1

echo === stage1 done, rebooting for testsigning === >> C:\qubes-win-idd-setup.log
shutdown /r /t 15
