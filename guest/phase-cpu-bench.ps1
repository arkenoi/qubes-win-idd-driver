# Per-phase GUI CPU: runs instrumentation/drag-harness.ps1 (idle/drag/scroll/type
# phases with ### PHASE markers) as a child process while sampling the cumulative CPU seconds of
# the GUI PROCESS FAMILY every 250 ms. The caller joins samples to phase windows and computes %core
# per phase - the metric behind README's performance table (agent 09b643e, 2026-08-10).
# THE FAMILY, NOT THE AGENT ALONE (2026-09-30): since the de-slice, capture runs in wgcbroker.exe
# (and the notification and ETW helpers are ours too), so sampling gui-agent alone understated our
# cost against a stock agent that does all of it in-process. Numbers taken before this change are
# agent-only and are NOT comparable with numbers taken after it; a stock-vs-ours run measures both
# sides with the same sampler, so its verdict is unaffected.
param([string]$Harness = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\drag-harness.ps1')
$ErrorActionPreference = 'Continue'
$out = 'C:\Windows\Temp\phasecpu-harness.txt'
Remove-Item $out -ErrorAction SilentlyContinue
$a = Get-Process gui-agent -ErrorAction SilentlyContinue
if (-not $a) { Write-Output '=== META ==='; Write-Output '{"error":"no agent"}'; exit 1 }
# Chained property access on a cmdlet that can return $null throws on exactly the broken state a
# probe exists to report (lint L6). Resolve the hash defensively so a missing binary is REPORTED,
# not turned into a terminating error in the middle of the META block.
$binPath = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
$binHash = 'unavailable'
$fh = Get-FileHash $binPath -Algorithm SHA256 -ErrorAction SilentlyContinue
if ($fh -and $fh.Hash) { $binHash = $fh.Hash.Substring(0,16) }
# The screen width came from System.Windows.Forms, whose assembly is not loaded in a bare
# -NoProfile session, so this field silently produced nothing. Use the Win32 metric instead.
$screenW = 0
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
      $screenW = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width } catch { }
Write-Output '=== META ==='
@{ agent_pid = $a.Id
   bin_sha256 = $binHash
   screen = $screenW
   sampler = 'family-v2' } | ConvertTo-Json -Compress
# -KeepNotepad: the scene must survive the run so the CALLER can verify by PIXELS that the window
# the numbers came from was actually rendering. A wedged Notepad (client area white, typing
# invisible) survives agent restarts and binary swaps and faked two regressions here on
# 2026-08-12; nothing in the agent's own output can detect it.
$proc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Harness`" -KeepNotepad" `
    -RedirectStandardOutput $out -PassThru -WindowStyle Hidden
$samples = New-Object System.Collections.Generic.List[string]
# Whole-guest busy time (all CPUs, every process and the kernel): GetSystemTimes, busy = kernel - idle
# + user. It carries what no process list can - DWM's software rasteriser composing the broker's relay
# and capture surfaces, grant maps in the kernel - so a verdict can be checked against the whole bill.
# The sampler and the workload scripts are inside it too, identically on both sides.
Add-Type -Namespace PB -Name K -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
'@
# Per-pid running totals: a process seen for the first time adds its whole cumulative CPU, after that
# only positive deltas, so a helper restarting (a new pid) never makes a total step back. First-seen
# amounts of processes already running when sampling starts are a constant, so per-phase deltas are
# unaffected; a process started mid-run is counted from its start - and changes the seen count, which
# the parser uses to refuse a phase that a process start contaminated.
$family = @('gui-agent', 'wgcbroker', 'notifhost', 'etwproxy')
$lastCpu = @{}; $famTotal = 0.0; $dwmTotal = 0.0; $seen = @{}; $unreadable = @{}
while (-not $proc.HasExited) {
    $t = (Get-Date).ToString('yyyyMMdd.HHmmss.fff')
    $agentCpu = $null; $live = 0
    foreach ($p in @(Get-Process -Name ($family + 'dwm') -ErrorAction SilentlyContinue)) {
        $key = '{0}:{1}' -f $p.ProcessName, $p.Id
        # An unreadable counter is MISSING DATA: reported and failed by the parser, never read as 0. A pid
        # that WAS readable and now is not is exiting - the live count carries that, not this.
        if ($null -eq $p.CPU) { if (-not $lastCpu.ContainsKey($key)) { $unreadable[$key] = $true }; continue }
        $c = [double]$p.CPU
        $d = if ($lastCpu.ContainsKey($key)) { [Math]::Max(0.0, $c - $lastCpu[$key]) } else { $c }
        $lastCpu[$key] = $c
        if ($p.ProcessName -eq 'dwm') { $dwmTotal += $d; continue }
        $famTotal += $d; $seen[$key] = $true; $live++
        # The agent's RAW counter, as before: an agent restart inside a phase still reads negative.
        if ($p.ProcessName -eq 'gui-agent') { $agentCpu = [double]$agentCpu + $c }
    }
    $i = 0L; $k = 0L; $u = 0L
    $sys = if ([PB.K]::GetSystemTimes([ref]$i, [ref]$k, [ref]$u)) { ($k - $i + $u) / 1e7 } else { -1 }
    # Columns: stamp family agent seen live dwm system. No agent, no sample - the parser fails the gap.
    # INVARIANT culture: -f formats in the guest's, and a German guest writes "0,1234" - which the
    # parser cannot read, so every sample of such a run was lost.
    if ($null -ne $agentCpu) {
        $samples.Add([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0} {1:F4} {2:F4} {3} {4} {5:F4} {6:F4}',
            $t, $famTotal, $agentCpu, $seen.Count, $live, $dwmTotal, $sys))
    }
    Start-Sleep -Milliseconds 250
}
Write-Output '=== FAMILY ==='
@{ seen = @($seen.Keys | Sort-Object); unreadable = @($unreadable.Keys | Sort-Object) } | ConvertTo-Json -Compress
Write-Output '=== SAMPLES ==='
$samples
Write-Output '=== HARNESS ==='
Get-Content $out | Select-String '### PHASE|cadence|RESULT|error' | ForEach-Object { $_.Line }
Write-Output '=== END ==='
