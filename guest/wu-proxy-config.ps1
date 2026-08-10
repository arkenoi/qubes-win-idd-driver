# Set/revert ALL THREE Windows-Update proxy planes at 127.0.0.1:8082 (PLAN-updates-proxy.md).
# Reused verbatim from Stage 1 through the shipped feature. MUST run elevated.
#
#   Plane 1  WinHTTP system proxy         netsh winhttp set proxy (scan/detection path)
#   Plane 2  device-wide WinINET proxy    ProxySettingsPerUser=0 + HKLM Internet Settings
#                                         (wuauserv download/reporting + DO with a user token)
#   Plane 3  Delivery Optimization        DODownloadMode=0 (no P2P; unreachable anyway)
#
# A dead device-wide 127.0.0.1 proxy bricks ALL guest HTTP, so -Enable writes a JSON sidecar
# of prior state and -Disable restores exactly that. Refuses to run if UseWUServer or
# DoNotConnectToWindowsUpdateInternetLocations are set (WSUS/dual-scan would confound WU).
param(
    [ValidateSet('Enable','Disable','Status')] [string]$Action = 'Status',
    [string]$Proxy = '127.0.0.1:8082',
    [string]$Sidecar = 'C:\Users\Public\wu-proxy-prev.json',
    [switch]$DevToolsEnv   # also set machine HTTP(S)_PROXY for git/pip/npm (Stage 8)
)
$ErrorActionPreference = 'Stop'
$IS   = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
$DO   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
$WU   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$AU   = "$WU\AU"
$ENV  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

function Get-Val($path, $name) {
    try { return (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop).$name } catch { return $null }
}
function Set-Val($path, $name, $value, $type) {
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -LiteralPath $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
}

if ($Action -eq 'Status') {
    $s = [ordered]@{
        winhttp     = (& netsh winhttp show proxy) -join ' '
        wininet_enable = Get-Val $IS 'ProxyEnable'
        wininet_server = Get-Val $IS 'ProxyServer'
        per_user    = Get-Val $POL 'ProxySettingsPerUser'
        do_mode     = Get-Val $DO 'DODownloadMode'
        use_wu_server = Get-Val $AU 'UseWUServer'
        do_not_connect = Get-Val $WU 'DoNotConnectToWindowsUpdateInternetLocations'
    }
    Write-Output ("=== RESULT === " + ($s | ConvertTo-Json -Compress)); return
}

if ($Action -eq 'Enable') {
    # Guard: WSUS/dual-scan must be OFF or the WU path is not what we think it is.
    $uws = Get-Val $AU 'UseWUServer'; $dnc = Get-Val $WU 'DoNotConnectToWindowsUpdateInternetLocations'
    if ($uws -eq 1 -or $dnc -eq 1) {
        Write-Output "=== RESULT === {`"ok`":false,`"error`":`"UseWUServer=$uws DoNotConnect=$dnc must be unset`"}"; exit 1
    }
    # Snapshot prior state for a faithful revert.
    $prev = [ordered]@{
        winhttp_reset = $true   # -Disable resets winhttp regardless
        wininet_enable = Get-Val $IS 'ProxyEnable'
        wininet_server = Get-Val $IS 'ProxyServer'
        per_user       = Get-Val $POL 'ProxySettingsPerUser'
        do_mode        = Get-Val $DO 'DODownloadMode'
        env_http       = Get-Val $ENV 'HTTP_PROXY'
        env_https      = Get-Val $ENV 'HTTPS_PROXY'
    }
    $prev | ConvertTo-Json | Set-Content -LiteralPath $Sidecar -Encoding ASCII

    & netsh winhttp set proxy $Proxy "<local>" | Out-Null           # plane 1
    Set-Val $POL 'ProxySettingsPerUser' 0 'DWord'                    # plane 2: machine-wide
    Set-Val $IS  'ProxyEnable' 1 'DWord'
    Set-Val $IS  'ProxyServer' $Proxy 'String'
    Set-Val $IS  'ProxyOverride' '<local>' 'String'
    Set-Val $DO  'DODownloadMode' 0 'DWord'                          # plane 3
    if ($DevToolsEnv) {
        Set-Val $ENV 'HTTP_PROXY'  "http://$Proxy" 'String'
        Set-Val $ENV 'HTTPS_PROXY' "http://$Proxy" 'String'
    }
    Write-Output "=== RESULT === {`"ok`":true,`"action`":`"Enable`",`"proxy`":`"$Proxy`"}"; return
}

if ($Action -eq 'Disable') {
    $prev = if (Test-Path -LiteralPath $Sidecar) { Get-Content -LiteralPath $Sidecar -Raw | ConvertFrom-Json } else { $null }
    & netsh winhttp reset proxy | Out-Null
    if ($prev) {
        if ($null -ne $prev.wininet_enable) { Set-Val $IS 'ProxyEnable' ([int]$prev.wininet_enable) 'DWord' } else { Remove-ItemProperty -LiteralPath $IS -Name 'ProxyEnable' -ErrorAction SilentlyContinue }
        if ($null -ne $prev.wininet_server) { Set-Val $IS 'ProxyServer' $prev.wininet_server 'String' } else { Remove-ItemProperty -LiteralPath $IS -Name 'ProxyServer' -ErrorAction SilentlyContinue }
        Remove-ItemProperty -LiteralPath $IS -Name 'ProxyOverride' -ErrorAction SilentlyContinue
        if ($null -ne $prev.per_user) { Set-Val $POL 'ProxySettingsPerUser' ([int]$prev.per_user) 'DWord' } else { Remove-ItemProperty -LiteralPath $POL -Name 'ProxySettingsPerUser' -ErrorAction SilentlyContinue }
        if ($null -ne $prev.do_mode)  { Set-Val $DO 'DODownloadMode' ([int]$prev.do_mode) 'DWord' } else { Remove-ItemProperty -LiteralPath $DO -Name 'DODownloadMode' -ErrorAction SilentlyContinue }
        Remove-ItemProperty -LiteralPath $ENV -Name 'HTTP_PROXY'  -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $ENV -Name 'HTTPS_PROXY' -ErrorAction SilentlyContinue
    } else {
        # No sidecar: clear to a sane direct-access default.
        Remove-ItemProperty -LiteralPath $IS 'ProxyEnable' -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $IS 'ProxyServer' -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $POL 'ProxySettingsPerUser' -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $DO 'DODownloadMode' -ErrorAction SilentlyContinue
    }
    Write-Output "=== RESULT === {`"ok`":true,`"action`":`"Disable`"}"; return
}
