# Emit the newest gui-agent log's QGAPERF records on stdout, between markers.
# Used by tools/bench-agent.sh. Exists as a FILE because passing this as an inline
# -Command through qrexec (cmd -> powershell) mangles the quoting around
# "C:\Program Files\..." and silently returns almost nothing.
$log = Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent-*.log' |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "===PERFSTART=== $($log.Name)"
if ($log) {
    # the agent holds the log open; Get-Content shares read access fine
    Get-Content $log.FullName | Where-Object { $_ -match 'QGAPERF,' }
}
Write-Output '===PERFEND==='
