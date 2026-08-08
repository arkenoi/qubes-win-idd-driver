# Emit the newest gui-agent log's QGAPERF records on stdout, between markers.
# Used by tools/bench-agent.sh. Exists as a FILE because passing this as an inline
# -Command through qrexec (cmd -> powershell) mangles the quoting around
# "C:\Program Files\..." and silently returns almost nothing.
# Read the CONFIGURED LogDir rather than assuming one. LogDir moved to Q:\Qubes Logs when
# MoveUsers landed (2026-08-07); this hardcoded path then found no log, emitted zero QGAPERF
# records, and EVERY ours-only row in the benchmark came out n/a - on guests whose
# instrumentation was working perfectly. This was the THIRD file carrying the same hardcoded
# path (after guest/health-check.ps1 and scratchpad/bench-probe.ps1); the other two were
# fixed days earlier and this one was missed because nothing asserted on its output.
$logDir = $null
try {
    $cfg = (Get-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools' -Name 'LogDir' -ErrorAction Stop).LogDir
    if ($cfg -and (Test-Path $cfg)) { $logDir = $cfg }
} catch { }
if (-not $logDir) {
    foreach ($cand in @('Q:\Qubes Logs', 'C:\Program Files\Qubes Tools\log')) {
        if (Test-Path $cand) { $logDir = $cand; break }
    }
}
$log = $null
if ($logDir) {
    $log = Get-ChildItem $logDir -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
# Name the directory searched, so "no records" can be told apart from "looked in the wrong
# place" without re-deriving it later.
Write-Output "===PERFSTART=== logdir=$logDir log=$(if ($log) { $log.Name } else { 'NONE' })"
if ($log) {
    # the agent holds the log open; Get-Content shares read access fine
    Get-Content $log.FullName | Where-Object { $_ -match 'QGAPERF,' }
}
Write-Output '===PERFEND==='
