# Dump the relay log around a given time window, plus a summary of what WU actually reached.
# Passing time patterns through qtest/cmd directly fails on the colons - hence a script.
param([string]$From = '15:35', [int]$Tail = 40)
$ErrorActionPreference = 'Continue'
$log = 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log'
Write-Output '=== RESULT ==='
if (-not (Test-Path $log)) { Write-Output 'no relay log'; exit 1 }
$all = @(Get-Content $log -EA SilentlyContinue)
Write-Output ("total lines = {0}" -f $all.Count)
$idx = 0
for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i].StartsWith($From)) { $idx = $i; break } }
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
