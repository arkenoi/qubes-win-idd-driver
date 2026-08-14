# Who is actually using the updates proxy? The relay carries whatever the guest sends at it, and
# the proxy is only up during a pass - so every Windows background client discovers a working
# route at exactly the moment we need the bandwidth. This counts connections and held-time per
# destination host, which is what decides whether update traffic is competing with telemetry.
$ErrorActionPreference = 'Continue'
$log = 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log'
$lines = @(Get-Content -LiteralPath $log -EA SilentlyContinue | Where-Object { $_ -match ' CONN ' })
Write-Output "=== RESULT ==="
Write-Output ("total_conns=" + $lines.Count)
$stats = @{}
foreach ($l in $lines) {
    $host_ = '(unparsed)'
    if ($l -match 'req=\[\w+ (?:http://)?([^/ :\]]+)') { $host_ = $Matches[1] }
    $ms = 0;   if ($l -match ' ms=(\d+)')   { $ms = [int]$Matches[1] }
    $down = 0; if ($l -match ' down=(\d+)') { $down = [long]$Matches[1] }
    if (-not $stats.ContainsKey($host_)) { $stats[$host_] = @{ n = 0; ms = 0; down = [long]0 } }
    $stats[$host_].n++
    $stats[$host_].ms += $ms
    $stats[$host_].down += $down
}
Write-Output ("{0,-42} {1,5} {2,10} {3,12}" -f 'HOST', 'CONNS', 'HELD_SEC', 'BYTES')
foreach ($k in ($stats.Keys | Sort-Object { -$stats[$_].ms })) {
    Write-Output ("{0,-42} {1,5} {2,10:N1} {3,12}" -f $k, $stats[$k].n, ($stats[$k].ms / 1000), $stats[$k].down)
}
