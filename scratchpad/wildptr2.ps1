# T1: regression test for the wild-pointer loop in the post-recovery repaint sweep.
#
# THE BUG (agent main.c, sweep under `case 1: new frame available`, gated on
# capture->grants_changed): the loop advanced its cursor at the BOTTOM of the body while
# 0a334c1 added `if (repaint->Synthesized) continue;` above it. continue skips the advance, so
# CONTAINING_RECORD is re-applied to an already-converted pointer and it walks backwards ~1 KB
# per pass through unrelated heap - on the main event-loop thread, holding g_csWatchedWindows.
#
# ALL THREE preconditions must hold or the sweep never touches the bug, and the run is VOID:
#   1. PerWindowCapture=1                      (no synthesis otherwise)
#   2. a SYNTHESIZED window exists             (the `continue` is what breaks; no synth, no bug)
#   3. an IN-PLACE duplication recovery happened, then a frame  (that is what runs the sweep)
#
# Trigger: a desktop SWITCH raises DXGI_ERROR_ACCESS_LOST, which is the in-place recovery path
# ("duplication recreated in place ... windows kept"). Deliberately NOT LockWorkStation: that
# strands the guest on the secure desktop where no frames flow, so the sweep would never run
# and recovery would need a reboot. A scratch desktop switched to and back restores frames
# within seconds and needs no password.
param([string]$Which = 'fix', [string]$ExpectHash = '')

$ErrorActionPreference = 'Continue'
$bin      = 'C:\Program Files\Qubes Tools\bin'
$incoming = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$logdir   = 'C:\Program Files\Qubes Tools\log'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class D {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateDesktop(string name, IntPtr dev, IntPtr dm, int flags, uint access, IntPtr sa);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool SwitchDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr h);
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr OpenDesktop(string name, uint flags, bool inherit, uint access);
}
'@

function AgentPid { $p = Get-Process gui-agent -ErrorAction SilentlyContinue; if ($p) { $p.Id } else { 0 } }
function LatestLog { Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }

$h = (Get-FileHash (Join-Path $bin 'gui-agent.exe')).Hash.Substring(0,16)
if ($ExpectHash -and $h -ne $ExpectHash) { Write-Output "RESULT which=$Which status=VOID reason=wrong_binary installed=$h"; exit 1 }
if ((Get-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools').PerWindowCapture -ne 1) {
  Write-Output "RESULT which=$Which status=VOID reason=per_window_capture_off"; exit 1 }

# --- precondition 2: a synthesized window --------------------------------------------
Get-Process chromerepro -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-Process (Join-Path $incoming 'chromerepro.exe') -ArgumentList '--popup'
Start-Sleep -Seconds 12

$log  = LatestLog
$pid0 = AgentPid
if ($pid0 -eq 0) { Write-Output "RESULT which=$Which status=VOID reason=no_agent"; exit 1 }
$synth = @(Select-String -Path $log.FullName -Pattern 'msg=SYNTH,').Count
Write-Output ("STEP0 pid=$pid0 synth=$synth log=" + $log.Name)
if ($synth -eq 0) { Write-Output "RESULT which=$Which status=VOID reason=nothing_synthesized"; exit 1 }

$linesBefore = (Get-Content $log.FullName | Measure-Object -Line).Lines
$recBefore   = @(Select-String -Path $log.FullName -Pattern 'recreated in place').Count

# --- precondition 3: force an in-place duplication recovery ---------------------------
# GENERIC_ALL = 0x10000000, DESKTOP_SWITCHDESKTOP = 0x0100
$scratch = [D]::CreateDesktop('QubesWpTest', [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x10000000, [IntPtr]::Zero)
if ($scratch -eq [IntPtr]::Zero) {
  Write-Output ("RESULT which=$Which status=VOID reason=CreateDesktop_failed err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()); exit 1 }
$defaultDesk = [D]::OpenDesktop('Default', 0, $false, 0x10000000)
if ($defaultDesk -eq [IntPtr]::Zero) {
  [void][D]::CloseDesktop($scratch)
  Write-Output ("RESULT which=$Which status=VOID reason=OpenDesktop_Default_failed err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()); exit 1 }

$sw1 = [D]::SwitchDesktop($scratch)
Start-Sleep -Seconds 4
$sw2 = [D]::SwitchDesktop($defaultDesk)
Start-Sleep -Seconds 2
[void][D]::CloseDesktop($scratch)
Write-Output "STEP1 switched_away=$sw1 switched_back=$sw2"
if (-not $sw1) { Write-Output "RESULT which=$Which status=VOID reason=SwitchDesktop_failed"; exit 1 }

# give the agent time to recover and produce frames
Start-Sleep -Seconds 20

$recAfter = @(Select-String -Path $log.FullName -Pattern 'recreated in place').Count
$pidNow   = AgentPid
Write-Output ("STEP2 recovered_in_place=" + ($recAfter - $recBefore) + " pid_now=$pidNow (was $pid0)")
if ($recAfter -le $recBefore) {
  Write-Output "RESULT which=$Which status=VOID reason=no_in_place_recovery (sweep never ran; nothing was tested)"
  exit 1
}

# --- verdict: is the agent still alive and DOING WORK after the sweep? -----------------
$n1 = (Get-Content $log.FullName | Measure-Object -Line).Lines
Start-Sleep -Seconds 15
$n2 = (Get-Content $log.FullName | Measure-Object -Line).Lines
$responsive = $false
try { $responsive = [bool](Get-Process gui-agent -ErrorAction Stop) } catch { $responsive = $false }

Write-Output ("STEP3 log_growth_after_sweep=" + ($n2 - $n1) + " same_pid=" + ($pidNow -eq $pid0))
$survived = ($pidNow -eq $pid0) -and ($n2 -gt $n1)
Write-Output ("RESULT which=$Which status=OK installed=$h survived=$survived same_pid=" + ($pidNow -eq $pid0) + " still_logging=" + ($n2 -gt $n1) + " recoveries=" + ($recAfter - $recBefore))
