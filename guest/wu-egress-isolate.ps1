# Split "the tunnel is broken" from "the WU COM searcher is broken".
#
# A full pass just died with 0x80072F8F (ERROR_INTERNET_SECURE_FAILURE) BEFORE writing its first
# log line, which puts the failure in Ensure-Proxy or in Get-Available's COM search - not in our
# Invoke-WebRequest code. The same pristine image downloaded 4.8 GB successfully earlier today, so
# something environmental changed. These two paths use different HTTP stacks:
#   * Invoke-WebRequest / HttpWebRequest -> .NET, uses the WebProxy we pass explicitly
#   * Microsoft.Update.Session          -> WinHTTP, uses the machine proxy set by netsh
# Testing them separately says which one to chase.
$ErrorActionPreference = 'Continue'
$relay = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe'
$proxy = 'http://127.0.0.1:8082'
Write-Output '=== RESULT ==='

# Bring the proxy up exactly as the agent does.
& netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
$IS = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty -Path $IS -Name ProxyEnable -Value 1 -Type DWord
Set-ItemProperty -Path $IS -Name ProxyServer -Value '127.0.0.1:8082'
# RELAY OWNED BY HANDLE (guest/relay-own.ps1 next to this script): the old shape ADOPTED whatever
# was named qubes-updates-relay and started its own only when none was; now a port that is not free
# is a refusal naming its owner - never adopted, never killed (owner 2026-10-07).
$ro = Join-Path $PSScriptRoot 'relay-own.ps1'
if (-not (Test-Path -LiteralPath $ro)) { Write-Output 'relay-own.ps1 not pushed next to this script (tools/qtest push guest/relay-own.ps1)'; exit 3 }
. $ro
# No --log: the relay then logs into the one log directory by its own rule, beside the updater's relay - the place --log
# named before the move, when that was the updater's work directory (docs/ADR-logging.md, Decision 2026-11-01).
try { [void](Start-OwnRelay -Exe $relay -Arguments @('--listen','8082','--target','@default') -SettleSec 3); Write-Output ("relay running = pid {0} (started here)" -f $script:OwnRelayPid) }
catch { Write-Output $_.Exception.Message; exit 2 }

# 1. .NET stack through the explicit proxy - this is our downloader's path.
foreach ($u in 'https://www.catalog.update.microsoft.com/Search.aspx?q=KB5121003',
               'https://windowsupdate.microsoft.com/') {
    try {
        $r = Invoke-WebRequest $u -Proxy $proxy -UseBasicParsing -TimeoutSec 45
        Write-Output ("NET  {0,-62} -> HTTP {1}" -f $u.Substring(0,[Math]::Min(62,$u.Length)), [int]$r.StatusCode)
    } catch {
        Write-Output ("NET  {0,-62} -> {1}" -f $u.Substring(0,[Math]::Min(62,$u.Length)), $_.Exception.Message)
    }
}

# 2. WinHTTP stack via the WU COM searcher - this is Get-Available's path.
try {
    $s  = New-Object -ComObject Microsoft.Update.Session
    $se = $s.CreateUpdateSearcher(); $se.ServerSelection = 2; $se.Online = $true
    $res = $se.Search("IsInstalled=0 and IsHidden=0")
    Write-Output ("COM  WU searcher -> {0} update(s)" -f $res.Updates.Count)
} catch {
    $ex = $_.Exception
    Write-Output ("COM  WU searcher -> FAILED: {0}" -f $ex.Message)
    if ($ex.InnerException) { Write-Output ("     inner: {0}" -f $ex.InnerException.Message) }
    $hr = try { '0x{0:X8}' -f $ex.HResult } catch { 'n/a' }
    Write-Output ("     hresult = {0}" -f $hr)
}

# 3. What the relay itself logged - a 403 from our own allowlist looks nothing like a TLS failure.
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
$rl = @(Get-MovedLogFiles 'qubes-updates-relay' 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log')
if ($rl.Count) {
    Write-Output '--- relay log tail ---'
    @(foreach ($p in $rl) { Get-Content -LiteralPath $p -Tail 12 -EA SilentlyContinue }) | Select-Object -Last 12 | ForEach-Object { Write-Output ("   " + $_) }
}

& netsh winhttp reset proxy | Out-Null
Set-ItemProperty -Path $IS -Name ProxyEnable -Value 0 -Type DWord
Stop-OwnRelay
Write-Output 'proxy torn down'
