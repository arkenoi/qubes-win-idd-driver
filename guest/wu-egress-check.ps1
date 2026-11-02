# Prove the guest has NO route out except our relay, and show what the relay is now refusing.
# A qube with netvm=none must fail a DIRECT request; if this ever succeeds, the isolation premise
# of the whole updates design is broken and nothing else in the measurements matters.
$ErrorActionPreference = 'Continue'
Write-Output '=== RESULT ==='

# 1. DIRECT (no proxy) - must FAIL
$direct = 'unexpected-success'
try {
    $r = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 12
    $direct = "SUCCEEDED http=$($r.StatusCode) - GUEST HAS GENERAL NETWORKING"
} catch { $direct = "failed as expected: " + ($_.Exception.Message -replace '\s+', ' ').Substring(0, [Math]::Min(90, $_.Exception.Message.Length)) }
Write-Output ("direct_no_proxy : " + $direct)

# 2. Through our relay to a NON-update host - must be refused by the allowlist
$blocked = 'no-relay'
try {
    $r = Invoke-WebRequest 'http://ecs.office.com/' -Proxy 'http://127.0.0.1:8082' -UseBasicParsing -TimeoutSec 15
    $blocked = "ALLOWED http=$($r.StatusCode) - ALLOWLIST NOT WORKING"
} catch {
    $m = $_.Exception.Message
    $blocked = if ($m -match '403') { 'refused with 403 (allowlist works)' } else { 'error: ' + ($m -replace '\s+', ' ') }
}
Write-Output ("relay_to_office : " + $blocked)

# 3. Through our relay to an UPDATE host - must be allowed
$allowed = 'no-relay'
try {
    $r = Invoke-WebRequest 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab' -Proxy 'http://127.0.0.1:8082' -UseBasicParsing -TimeoutSec 25
    $allowed = "allowed http=$($r.StatusCode) bytes=$($r.RawContentLength)"
} catch { $allowed = 'error: ' + ($_.Exception.Message -replace '\s+', ' ') }
Write-Output ("relay_to_update : " + $allowed)

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
$deny = @(); if ($log.Count) { $deny = @(Get-Content -LiteralPath $log -EA SilentlyContinue | Where-Object { $_ -match ' DENY ' }) }
Write-Output ("deny_lines      : " + $deny.Count)
foreach ($d in ($deny | Select-Object -Last 6)) { Write-Output ("  " + $d) }
