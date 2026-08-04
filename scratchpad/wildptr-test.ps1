# T1: regression test for the wild-pointer loop in the post-recovery repaint sweep.
#
# The loop only misbehaves when a SYNTHESIZED window is in g_WatchedWindowsList at the moment
# seamless mode recovers a duplication. Both halves must be established or the test is vacuous:
#   1. synthesis actually happened  -> require msg=SYNTH / SYNTHPAINT in the log BEFORE going on
#   2. a duplication recovery actually happened -> require the recovery marker AFTER the trigger
# If either is missing this reports VOID, not PASS: on the unfixed build a run where the sweep
# never executed proves nothing.
#
# Trigger: a desktop switch (lock) makes DXGI return ACCESS_LOST, which is the in-place
# recovery path that ends in the repaint sweep.
#
# Symptom on the unfixed build: the sweep walks a pointer backwards through the heap while
# holding g_csWatchedWindows on the main event-loop thread -> the agent stops logging / stops
# serving windows, or dies. So the verdict is "did the agent keep working AFTER the recovery".
param([string]$Which = 'fix', [string]$ExpectHash = '', [int]$LockSeconds = 30)

$ErrorActionPreference = 'Continue'
$bin      = 'C:\Program Files\Qubes Tools\bin'
$incoming = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$logdir   = 'C:\Program Files\Qubes Tools\log'

$h = (Get-FileHash (Join-Path $bin 'gui-agent.exe')).Hash.Substring(0,16)
if ($ExpectHash -and $h -ne $ExpectHash) { Write-Output "RESULT which=$Which status=FAIL reason=wrong_binary installed=$h"; exit 1 }
$pwc = (Get-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools').PerWindowCapture
if ($pwc -ne 1) { Write-Output "RESULT which=$Which status=VOID reason=per_window_capture_off"; exit 1 }

function AgentPid { $p = Get-Process gui-agent -ErrorAction SilentlyContinue; if ($p) { $p.Id } else { 0 } }
function LatestLog { Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }

# --- scene: an owned popup contained by its tracked owner => synthesizes -------------
Get-Process chromerepro -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-Process (Join-Path $incoming 'chromerepro.exe') -ArgumentList '--popup'
Start-Sleep -Seconds 10

$log = LatestLog
$pid0 = AgentPid
if ($pid0 -eq 0) { Write-Output "RESULT which=$Which status=VOID reason=no_agent"; exit 1 }

$synthBefore = @(Select-String -Path $log.FullName -Pattern 'msg=SYNTH,').Count
$paintBefore = @(Select-String -Path $log.FullName -Pattern 'msg=SYNTHPAINT').Count
Write-Output ("STEP0 pid=$pid0 synth=$synthBefore synthpaint=$paintBefore log=" + $log.Name)
if ($synthBefore -eq 0) {
  Write-Output "RESULT which=$Which status=VOID reason=nothing_synthesized (no synthesized window => sweep cannot hit the bug)"
  exit 1
}

$linesBefore = (Get-Content $log.FullName | Measure-Object -Line).Lines

# --- trigger a desktop switch => DXGI ACCESS_LOST => in-place recovery => repaint sweep
$me = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $me) { Write-Output "RESULT which=$Which status=VOID reason=no_interactive_session"; exit 1 }
schtasks /delete /tn QubesLockProbe /f *> $null
$null = schtasks /create /tn QubesLockProbe /tr 'rundll32.exe user32.dll,LockWorkStation' /sc once /st 23:59 /ru $me /it /f 2>&1
$null = schtasks /run /tn QubesLockProbe 2>&1
Start-Sleep -Seconds $LockSeconds
schtasks /delete /tn QubesLockProbe /f *> $null

$after = Get-Content $log.FullName
$win   = if ($after.Count -gt $linesBefore) { $after[$linesBefore..($after.Count-1)] } else { @() }
$recovered = @($win | Select-String -Pattern 'RecreateDuplication|ACCESS_LOST|recovered|Recreat').Count
$pidNow = AgentPid

# is the agent still doing work AFTER the recovery? sample the log twice.
$n1 = (Get-Content $log.FullName | Measure-Object -Line).Lines
Start-Sleep -Seconds 12
$n2 = (Get-Content $log.FullName | Measure-Object -Line).Lines

Write-Output ("STEP1 recovery_markers=$recovered lines_added_during=" + $win.Count)
Write-Output ("STEP2 pid_now=$pidNow (was $pid0) log_growth_after=" + ($n2 - $n1))
if ($recovered -eq 0) {
  Write-Output "RESULT which=$Which status=VOID reason=no_recovery_observed (trigger did not produce a duplication recovery)"
  exit 1
}
$alive = ($pidNow -eq $pid0) -and ($n2 -gt $n1)
Write-Output ("RESULT which=$Which status=OK installed=$h agent_survived=$alive same_pid=" + ($pidNow -eq $pid0) + " still_logging=" + ($n2 -gt $n1))
Write-Output "NOTE: the guest is LOCKED. Recover by rebooting the qube (autologon), not by password."
