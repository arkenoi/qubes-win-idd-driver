# Emit the newest gui-agent log's QGAPERF records on stdout, between markers.
# Used by tools/bench-agent.sh. Exists as a FILE because passing this as an inline
# -Command through qrexec (cmd -> powershell) mangles the quoting around
# "C:\Program Files\..." and silently returns almost nothing.
# WINDOWING (-Since / -Until). Emitting the WHOLE log makes any cross-guest comparison
# silently invalid: two guests have different histories, so a rate computed over the file
# measures workload mix, not the platform. Not hypothetical - it produced a reported
# 32.5%-vs-1.6% enumeration difference that INVERTED to 2.3%-vs-4.6% once restricted to the
# actual phase, because one log also contained three prior benchmark reps.
# Timestamps use the agent log's own format: yyyyMMdd.HHmmss.fff
param(
    [string]$Since = '',
    [string]$Until = ''
)
$script:emitted = 0
$script:skipped = 0

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
Write-Output ("===PERFSTART=== logdir=$logDir log=$(if ($log) { $log.Name } else { 'NONE' })" +
               " since=$(if ($Since) { $Since } else { 'BEGIN' }) until=$(if ($Until) { $Until } else { 'END' })")
if ($log) {
    # the agent holds the log open; Get-Content shares read access fine
    foreach ($line in Get-Content $log.FullName) {
        if ($line -notmatch 'QGAPERF,') { continue }
        if ($Since -or $Until) {
            # Log lines start "[yyyyMMdd.HHmmss.fff-pid-L]". String comparison is valid here
            # because the format is fixed-width and lexically ordered.
            if ($line -match '^\[(\d{8}\.\d{6}\.\d{3})-') {
                $t = $Matches[1]
                if ($Since -and $t -lt $Since) { $script:skipped++; continue }
                if ($Until -and $t -gt $Until) { $script:skipped++; continue }
            } else {
                # A record that cannot be timestamped must NOT be kept when a window was
                # requested: that is exactly how unrelated activity leaks into a comparison.
                $script:skipped++; continue
            }
        }
        $script:emitted++
        Write-Output $line
    }
}
Write-Output "===PERFCOUNT=== emitted=$script:emitted skipped_outside_window=$script:skipped"
Write-Output '===PERFEND==='
