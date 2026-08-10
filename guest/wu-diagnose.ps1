# WU-through-proxy layered diagnostic. Isolates: (A) relay reachable from the guest,
# (B) Windows' own connectivity verdict, (C) a DIRECT BITS transfer (no WU COM), (D) DO state.
# Prints one === WUDIAG === JSON line. Non-destructive except it (re)starts the relay and
# creates+cancels a throwaway BITS job.
$ErrorActionPreference = 'Continue'
$exe = 'C:\Users\Public\relaytest\qubes-updates-relay.exe'
$IS  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
$DO  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }

$out = [ordered]@{}

# --- planes + relay --------------------------------------------------------------------
& netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
SetV $POL 'ProxySettingsPerUser' 0 'DWord'; SetV $IS 'ProxyEnable' 1 'DWord'
SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'
SetV $DO 'DODownloadMode' 0 'DWord'
& bitsadmin /util /setieproxy LOCALSYSTEM MANUAL_PROXY '127.0.0.1:8082' '<local>' 2>&1 | Out-Null

$env:QUBES_UPDATES_MAXCONN = '256'
Get-Process qubes-updates-relay -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 500
Start-Process -FilePath $exe -ArgumentList '--listen','8082','--target','@default','--log','C:\Users\Public\relaytest' -WindowStyle Hidden
Start-Sleep -Seconds 2
$out.relay_running = [bool](Get-Process qubes-updates-relay -EA SilentlyContinue)

# --- LAYER A: relay reachable from the guest? ------------------------------------------
$cab = 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab'
try {
    $r = Invoke-WebRequest -Uri $cab -Proxy 'http://127.0.0.1:8082' -UseBasicParsing -TimeoutSec 30
    $out.A_relay_http = "status=$($r.StatusCode) bytes=$($r.RawContentLength)"
} catch { $out.A_relay_http = "EXC: $($_.Exception.Message)" }

# --- LAYER B: Windows connectivity verdict (what BITS/DO gate on) -----------------------
$out.B_profiles = @(Get-NetConnectionProfile -EA SilentlyContinue | ForEach-Object {
    "$($_.InterfaceAlias):cat=$($_.NetworkCategory),ipv4=$($_.IPv4Connectivity),ipv6=$($_.IPv6Connectivity)" }) -join ' | '
try { $nlm = New-Object -ComObject Microsoft.NetworkListManager
      $out.B_nlm = "connected=$([bool]$nlm.IsConnected) internet=$([bool]$nlm.IsConnectedToInternet)" } catch { $out.B_nlm = "EXC" }

# --- LAYER C: DIRECT BITS transfer via the proxy (no WU COM) ----------------------------
& bitsadmin /cancel wudiag 2>&1 | Out-Null
& bitsadmin /create wudiag 2>&1 | Out-Null
& bitsadmin /addfile wudiag $cab 'C:\Users\Public\wudiag.cab' 2>&1 | Out-Null
& bitsadmin /setproxysettings wudiag OVERRIDE '127.0.0.1:8082' 'NULL' 2>&1 | Out-Null
& bitsadmin /setpriority wudiag FOREGROUND 2>&1 | Out-Null
& bitsadmin /resume wudiag 2>&1 | Out-Null
$state=''; $err=''; $bytes=''
for ($i=0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 2
    $info = & bitsadmin /info wudiag /verbose 2>&1
    $state = ($info | Select-String 'STATE:').ToString().Trim()
    $bytes = ($info | Select-String 'BYTES:').ToString().Trim()
    if ($state -match 'TRANSFERRED|ERROR') { break }
}
$errln = (& bitsadmin /info wudiag /verbose 2>&1 | Select-String 'ERROR')
$out.C_bits_state = "$state"
$out.C_bits_bytes = "$bytes"
$out.C_bits_error = if($errln){ ($errln -join '; ') } else { '(none)' }
Remove-Item 'C:\Users\Public\wudiag.cab' -EA SilentlyContinue
& bitsadmin /cancel wudiag 2>&1 | Out-Null

# --- LAYER D: Delivery Optimization state ----------------------------------------------
$out.D_do = @(Get-DeliveryOptimizationStatus -EA SilentlyContinue | ForEach-Object {
    "$($_.Status) $([math]::Round($_.BytesDownloaded/1MB,1))/$([math]::Round($_.TotalBytesToDownload/1MB,1))MB err=$($_.ErrorCode)" }) -join ' | '
if (-not $out.D_do) { $out.D_do = '(no DO jobs)' }

Write-Output ('=== WUDIAG === ' + ($out | ConvertTo-Json -Compress))
