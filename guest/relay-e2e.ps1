# Stage 4 end-to-end: start the compiled relay listening on 127.0.0.1:8082, then drive
# ARBITRARY TCP through it with curl -x (a real HTTP-proxy stream, not a canned request).
# All in ONE process so the relay survives (detached start /b dies with the qrexec session).
# Emits === RESULT === JSON with the curl status + a hash of the fetched body.
param([string]$Target = '@default', [int]$Port = 8082)
$ErrorActionPreference = 'Continue'
$exe = 'C:\Users\Public\relaytest\qubes-updates-relay.exe'
if (-not (Test-Path $exe)) { Write-Output '=== RESULT === {"ok":false,"error":"relay exe missing - compile first"}'; exit 1 }
# free the port if a prior run left a listener
Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue }
Start-Sleep -Milliseconds 300

$relay = Start-Process -FilePath $exe -ArgumentList '--listen',"$Port",'--target',$Target,'--log','C:\Users\Public\relaytest' -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 900
$bound = @(Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue).Count -gt 0

# Arbitrary TCP through the relay: a real forward-proxy fetch of a plain-HTTP WU CDN object.
$url = 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab'
$body = 'C:\Users\Public\relaytest\fetched.bin'
Remove-Item $body -EA SilentlyContinue
$code = & curl.exe -s --max-time 120 -x "http://127.0.0.1:$Port" $url -o $body -w "%{http_code}" 2>$null
Start-Sleep -Milliseconds 300
Stop-Process -Id $relay.Id -Force -EA SilentlyContinue

$bytes = if (Test-Path $body) { (Get-Item $body).Length } else { 0 }
$sha = if ($bytes -gt 0) { (Get-FileHash $body -Algorithm SHA256).Hash.Substring(0,16) } else { $null }
# is it a real CAB (MSCF magic) not a proxy error page?
$magic = $null
if ($bytes -ge 4) { $b = [IO.File]::ReadAllBytes($body); $magic = [Text.Encoding]::ASCII.GetString($b[0..3]) }
$out = [ordered]@{
    ok = ($bound -and $code -eq 200 -and $bytes -gt 0)
    listener_bound = $bound; http_code = $code; body_bytes = $bytes; sha16 = $sha; magic = $magic
}
Write-Output ("=== RESULT === " + ($out | ConvertTo-Json -Compress))
