# restwatch.ps1 - how often do OUR processes wake up while the desktop is at rest? (docs/DESIGN-rest-zero-capture.md M1)
#
# Samples the RAW cumulative context-switch counter of every thread of gui-agent, wgcbroker, notifhost and etwproxy
# (Win32_PerfRawData_PerfProc_Thread.ContextSwitchesPersec - a running count, not a rate) twice, -Seconds apart, and
# prints the per-thread and per-process deltas. A thread that switched 0 times did not wake. Owner rule (2026-09-30):
# zero wakeups at rest, so the target is 0 on every thread; the candidate this was written against wakes ~6/s by
# construction (1 s duplication timeout, 250 ms engine sweep, 1 s main loop cap, 250 ms broker loop).
#
# Output (one line each; missing data is explicit, never a 0):
#   RESTWATCH|secs=<n>|proc=<name>|pid=<pid>|threads=<n>|cs=<total>|busiest_tid=<tid>|busiest_cs=<n>
#   RESTWATCH|secs=<n>|proc=<name>|found=0
#   RESTWATCH-T|proc=<name>|tid=<tid>|cs=<n>          (every thread with cs > 0)
#   RESTWATCH-END|secs=<n>|total_cs=<n>|procs_found=<n>
# -Windows N: N consecutive windows of -Seconds each, back to back (one snapshot ends a window and starts the next); every
# line above then carries |win=<k> (k from 1). A periodic timer wakes at the same rate in every window; activity that
# happened before the sample decays - that is how a residual is told apart from a poll.
param([int]$Seconds = 60, [string[]]$Names = @('gui-agent', 'wgcbroker', 'notifhost', 'etwproxy'), [int]$Windows = 1)

function Snap([int[]]$pids) {
    $h = @{}
    foreach ($t in (Get-CimInstance -ClassName Win32_PerfRawData_PerfProc_Thread -ErrorAction SilentlyContinue)) {
        if ($pids -contains [int]$t.IDProcess) { $h["$($t.IDProcess):$($t.IDThread)"] = [uint64]$t.ContextSwitchesPersec }
    }
    return $h
}

# By image name OR its 8.3 short form: the broker is launched through a short path and runs as WGCBRO~1, which a
# plain Get-Process -Name wgcbroker does not find (seen on w11-ds 2026-10-01: the first version reported it missing).
$procs = @{}
$all = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue
foreach ($n in $Names) {
    $short = if ($n.Length -gt 6) { $n.Substring(0, 6) + '~*' } else { $n + '~*' }
    $p = $all | Where-Object { $_.Name -ieq "$n.exe" -or $_.Name -like $short } | Select-Object -First 1
    if ($p) { $procs[$n] = [int]$p.ProcessId; "RESTWATCH-P|proc=$n|pid=$($p.ProcessId)|image=$($p.Name)|path=$($p.ExecutablePath)" }
}
$pids = @($procs.Values | ForEach-Object { [int]$_ })
$b = Snap $pids
for ($w = 1; $w -le $Windows; $w++) {
    $a = $b
    Start-Sleep -Seconds $Seconds
    $b = Snap $pids
    $wt = if ($Windows -gt 1) { "|win=$w" } else { '' }

    $total = [uint64]0
    foreach ($n in $Names) {
        if (-not $procs.ContainsKey($n)) { "RESTWATCH|secs=$Seconds|proc=$n|found=0$wt"; continue }
        $procId = $procs[$n]
        $sum = [uint64]0; $threads = 0; $busy = 0; $busyCs = [uint64]0
        $lines = @()
        foreach ($k in $b.Keys) {
            $parts = $k.Split(':')
            if ([int]$parts[0] -ne $procId) { continue }
            $threads++
            $d = if ($a.ContainsKey($k)) { $b[$k] - $a[$k] } else { $b[$k] }   # a thread born mid-window counts from 0
            $sum += $d
            if ($d -gt $busyCs) { $busyCs = $d; $busy = [int]$parts[1] }
            if ($d -gt 0) { $lines += "RESTWATCH-T|proc=$n|tid=$($parts[1])|cs=$d$wt" }
        }
        $total += $sum
        "RESTWATCH|secs=$Seconds|proc=$n|pid=$procId|threads=$threads|cs=$sum|busiest_tid=$busy|busiest_cs=$busyCs$wt"
        $lines
    }
    "RESTWATCH-END|secs=$Seconds|total_cs=$total|procs_found=$($procs.Count)$wt"
}
