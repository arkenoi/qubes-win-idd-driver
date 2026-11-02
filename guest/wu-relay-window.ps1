# Dump the relay log around a given time window, plus a summary of what WU actually reached.
# Passing time patterns through qtest/cmd directly fails on the colons - hence a script.
param([string]$From = '15:35', [int]$Tail = 40)
$ErrorActionPreference = 'Continue'
# THE ONE LOG DIRECTORY (docs/ADR-logging.md, Decision 2026-11-01), by log.ps1's rule, inlined because this probe runs
# without it: the registry LogDir, else <SystemDrive>\Qubes Logs. A moved log is its per-day files there,
# <module>-<yyyyMMdd>.log, newest last; only a guest with none of them reads the file at its old path.
function Get-MovedLogFiles([string]$Module, [string]$Old) {
    $d = $null
    try { $d = Get-ItemPropertyValue 'HKLM:\Software\Invisible Things Lab\Qubes Tools' LogDir -ErrorAction Stop } catch { }
    if (-not $d) { $d = Join-Path $env:SystemDrive 'Qubes Logs' }
    $rx = '^' + [regex]::Escape($Module) + '-\d{8}\.log$'
    $f = @(Get-ChildItem -LiteralPath $d -Filter "$Module-*.log" -File -EA SilentlyContinue | Where-Object { $_.Name -match $rx } | Sort-Object Name | ForEach-Object { $_.FullName })
    if ($f.Count -eq 0 -and $Old -and (Test-Path -LiteralPath $Old)) { $f = @($Old) }
    $f
}
$log = @(Get-MovedLogFiles 'qubes-updates-relay' 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log')
Write-Output '=== RESULT ==='
if ($log.Count -eq 0) { Write-Output 'no relay log'; exit 1 }
$all = @(Get-Content -LiteralPath $log -EA SilentlyContinue)
Write-Output ("total lines = {0}" -f $all.Count)
$idx = 0
# -From is a clock time (HH:mm...): an old line starts with it, a new one carries it as HHmmss in its prefix
# [yyyyMMdd.HHmmss.fff-pid:tid-L], so that is rewritten to HH:mm:ss.fff before the comparison.
for ($i = 0; $i -lt $all.Count; $i++) {
    $lt = $all[$i]
    if ($lt -match '^\[\d{8}\.(\d\d)(\d\d)(\d\d)\.(\d{3})-') { $lt = $Matches[1] + ':' + $Matches[2] + ':' + $Matches[3] + '.' + $Matches[4] }
    if ($lt.StartsWith($From)) { $idx = $i; break }
}
Write-Output ("--- from '{0}' (line {1}) ---" -f $From, $idx)
foreach ($l in ($all[$idx..([Math]::Min($idx + $Tail, $all.Count - 1))])) { Write-Output ("  " + $l) }

Write-Output '--- every host the relay saw, with outcome ---'
$hosts = @{}
foreach ($l in $all) {
    if ($l -match 'host=([^\s:]+)') { $h = $Matches[1] } elseif ($l -match '(?:CONNECT|GET)\s+(?:http://)?([^/\s:]+)') { $h = $Matches[1] } else { continue }
    $verdict = if ($l -match 'DENY') { 'DENY' } elseif ($l -match 'down=0\b') { 'zero-bytes' } elseif ($l -match 'CONN') { 'ok' } else { continue }
    $k = "$h|$verdict"
    $hosts[$k] = 1 + [int]$hosts[$k]
}
foreach ($k in ($hosts.Keys | Sort-Object)) {
    $p = $k -split '\|'
    Write-Output ("  {0,-46} {1,-11} x{2}" -f $p[0], $p[1], $hosts[$k])
}
