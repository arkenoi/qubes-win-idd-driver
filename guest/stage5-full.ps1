# Stage 5 self-contained: all three pieces in ONE process so nothing races or dies mid-scan.
#   1. verify the loopback adapter (NLM connectivity for wuauserv's precheck)
#   2. clear the offline WU block + set the 3 proxy planes fresh
#   3. start the relay as a CHILD and keep it alive across the whole scan (this script blocks
#      in the COM scan, so the child lives until we stop it)
#   4. restart wuauserv, settle, then WU COM scan
#   5. report everything incl. the RELAY LOG - whether wuauserv actually dialed 8082 is the
#      decisive signal (CONN lines = WU reached the relay; empty = plane/NLM problem, not proxy)
$ErrorActionPreference = 'Continue'
$exe = 'C:\Users\Public\relaytest\qubes-updates-relay.exe'
$log = 'C:\Users\Public\relaytest\qubes-updates-relay.log'
$IS  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
$DO  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }

# 1. adapter / NLM
$ad = @(Get-NetAdapter -EA SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
$nlm = $null
try { $m=[Activator]::CreateInstance([Type]::GetTypeFromCLSID([Guid]'DCB00C01-570F-4A9B-8D69-199FDBA5723B')); $nlm=[bool]$m.IsConnected } catch {}

# 2. clear WU block + planes
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name DoNotConnectToWindowsUpdateInternetLocations -EA SilentlyContinue
& netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
SetV $POL 'ProxySettingsPerUser' 0 'DWord'
SetV $IS 'ProxyEnable' 1 'DWord'; SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'
SetV $DO 'DODownloadMode' 0 'DWord'

# 3. relay child, kept alive by this script
Get-NetTCPConnection -LocalPort 8082 -State Listen -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue }
Remove-Item $log -EA SilentlyContinue
$relay = Start-Process -FilePath $exe -ArgumentList '--listen','8082','--target','@default','--log','C:\Users\Public\relaytest' -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 1200
$bound = @(Get-NetTCPConnection -LocalPort 8082 -State Listen -EA SilentlyContinue).Count -gt 0

# 4. WU proxy adoption: the machine WinHTTP proxy is not always honored by wuauserv's
# detection path - set the SYSTEM-account WU/BITS proxy explicitly, and clear the
# SoftwareDistribution cache so a backoff-cached failure does not fast-return.
& bitsadmin /util /setieproxy LOCALSYSTEM MANUAL_PROXY '127.0.0.1:8082' '<local>' 2>&1 | Out-Null
& net stop wuauserv 2>&1 | Out-Null
& net stop bits 2>&1 | Out-Null
Rename-Item 'C:\Windows\SoftwareDistribution' ('SoftwareDistribution.old.' + (Get-Random)) -EA SilentlyContinue
& net start bits 2>&1 | Out-Null
& net start wuauserv 2>&1 | Out-Null
Start-Sleep -Seconds 8

# 5. WU COM scan (blocks here; relay child stays alive throughout)
$scan = [ordered]@{ ok=$false; hresult_hex=$null; count=$null; seconds=$null }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $s = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $s.ServerSelection = 2; $s.Online = $true
    $r = $s.Search("IsInstalled=0 and IsHidden=0")
    $scan.ok=$true; $scan.hresult_hex='0x00000000'; $scan.count=$r.Updates.Count
} catch {
    $hr = if($_.Exception.InnerException){$_.Exception.InnerException.HResult}else{$_.Exception.HResult}
    $scan.hresult_hex = ('0x{0:X8}' -f ($hr -band 0xFFFFFFFF))
}
$scan.seconds = [math]::Round($sw.Elapsed.TotalSeconds,1)

# relay log = did WU dial 8082?
$connLines = @(); if (Test-Path $log) { $connLines = @((Get-Content $log | Where-Object { $_ -match 'CONN ' }) | ForEach-Object { [string]$_ }) }
try { Stop-Process -Id $relay.Id -Force -EA SilentlyContinue } catch {}

$out = [ordered]@{
    adapter_up = $ad.Count; nlm_connected = $nlm; relay_bound = $bound
    scan = $scan
    relay_conns = $connLines.Count
    relay_tail = @($connLines | Select-Object -Last 4)
}
Write-Output ("=== RESULT === " + ($out | ConvertTo-Json -Compress -Depth 4))
