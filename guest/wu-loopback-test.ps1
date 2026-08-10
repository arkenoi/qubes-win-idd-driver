# Test the indicated remedy: a KM-TEST loopback adapter with a static IP + dummy gateway to
# satisfy BITS/DO's IsNetworkAlive gate, while the actual bytes still go through the OVERRIDE
# proxy. Installs the adapter, configures it, re-checks connectivity, retries a direct BITS xfer.
$ErrorActionPreference = 'Continue'
$devcon = 'C:\Users\Public\devcon.exe'
$cab = 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab'
$out = [ordered]@{}

# --- install the loopback adapter if not already present -------------------------------
$lb = Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'KM-TEST Loopback' }
if (-not $lb) {
    & $devcon install C:\Windows\INF\netloop.inf *MSLOOP 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $lb = Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'KM-TEST Loopback' }
}
$out.loopback = if ($lb) { "present: $($lb.Name) status=$($lb.Status)" } else { 'INSTALL FAILED' }

if ($lb) {
    $alias = $lb.Name
    # static IP + a dummy default gateway so Windows treats it as a routed network
    Remove-NetIPAddress -InterfaceAlias $alias -Confirm:$false -EA SilentlyContinue
    Remove-NetRoute -InterfaceAlias $alias -Confirm:$false -EA SilentlyContinue
    New-NetIPAddress -InterfaceAlias $alias -IPAddress 10.200.0.2 -PrefixLength 24 -DefaultGateway 10.200.0.1 -EA SilentlyContinue | Out-Null
    Set-NetConnectionProfile -InterfaceAlias $alias -NetworkCategory Private -EA SilentlyContinue
    Start-Sleep -Seconds 3
    Restart-Service NlaSvc -Force -EA SilentlyContinue; Start-Sleep -Seconds 6
}

$out.conn = @(Get-NetConnectionProfile -EA SilentlyContinue | ForEach-Object {
    "$($_.InterfaceAlias):cat=$($_.NetworkCategory),ipv4=$($_.IPv4Connectivity)" }) -join ' | '
try { $nlm = New-Object -ComObject Microsoft.NetworkListManager
      $out.nlm = "connected=$([bool]$nlm.IsConnected)" } catch { $out.nlm = 'EXC' }

# --- retry the direct BITS transfer via the OVERRIDE proxy -----------------------------
& bitsadmin /cancel wulb 2>&1 | Out-Null
& bitsadmin /create wulb 2>&1 | Out-Null
& bitsadmin /addfile wulb $cab 'C:\Users\Public\wulb.cab' 2>&1 | Out-Null
& bitsadmin /setproxysettings wulb OVERRIDE '127.0.0.1:8082' 'NULL' 2>&1 | Out-Null
& bitsadmin /setpriority wulb FOREGROUND 2>&1 | Out-Null
& bitsadmin /resume wulb 2>&1 | Out-Null
$st=''; $info=@()
for ($i=0;$i -lt 12;$i++){ Start-Sleep -Seconds 2
    $info = & bitsadmin /info wulb /verbose 2>&1
    $st = (($info | Select-String 'STATE:') -join ' ')
    if ($st -match 'TRANSFERRED|ERROR') { break } }
$out.bits_state = (($info | Select-String 'STATE:') -join ' ').Trim()
$out.bits_bytes = (($info | Select-String 'BYTES:') -join ' ').Trim()
$out.bits_error = (($info | Select-String 'ERROR CODE:') -join ' ').Trim()
if (-not $out.bits_error) { $out.bits_error = '(none)' }
$out.file_landed = if (Test-Path 'C:\Users\Public\wulb.cab') { (Get-Item 'C:\Users\Public\wulb.cab').Length } else { 0 }
& bitsadmin /cancel wulb 2>&1 | Out-Null
Remove-Item 'C:\Users\Public\wulb.cab' -EA SilentlyContinue

Write-Output ('=== WULB === ' + ($out | ConvertTo-Json -Compress))
