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
$wu    = 'C:\ProgramData\Qubes\wu'
$proxy = 'http://127.0.0.1:8082'
Write-Output '=== RESULT ==='

# Bring the proxy up exactly as the agent does.
& netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
$IS = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty -Path $IS -Name ProxyEnable -Value 1 -Type DWord
Set-ItemProperty -Path $IS -Name ProxyServer -Value '127.0.0.1:8082'
if (-not (Get-Process qubes-updates-relay -EA SilentlyContinue)) {
    Start-Process -FilePath $relay -ArgumentList '--listen','8082','--target','@default','--log',$wu -WindowStyle Hidden
    Start-Sleep -Seconds 3
}
Write-Output ("relay running = {0}" -f @(Get-Process qubes-updates-relay -EA SilentlyContinue).Count)

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
$rl = Join-Path $wu 'qubes-updates-relay.log'
if (Test-Path $rl) {
    Write-Output '--- relay log tail ---'
    Get-Content $rl -Tail 12 -EA SilentlyContinue | ForEach-Object { Write-Output ("   " + $_) }
}

& netsh winhttp reset proxy | Out-Null
Set-ItemProperty -Path $IS -Name ProxyEnable -Value 0 -Type DWord
Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }
Write-Output 'proxy torn down'
