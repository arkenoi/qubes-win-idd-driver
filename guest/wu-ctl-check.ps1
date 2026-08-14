# Can the certificate trust list be fetched through our tunnel at all?
#
# WU fails with 0x80072F8F (secure failure) and the relay log shows why: the plain-HTTP GET of
# http://ctldl.windowsupdate.com/.../disallowedcertstl.cab returns down=0 three times in a row,
# while the TLS connection to tas02.sls.update.microsoft.com receives ~4 KB (a certificate chain)
# and is then aborted BY US. That is the signature of a client that cannot validate a chain because
# its trust-list refresh failed.
#
# ctldl is ALLOWED by the relay's allowlist (it logs CONN, not DENY), so the zero bytes come from
# further out. This isolates which hop drops it: the .NET stack through the same relay, versus
# WinHTTP. Also fetches over plain HTTP, which is what the CTL uses - the rest of our traffic is
# CONNECT/TLS, so plain-HTTP proxying may simply never have been exercised.
$ErrorActionPreference = 'Continue'
$relay = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe'
$wu    = 'C:\ProgramData\Qubes\wu'
$proxy = 'http://127.0.0.1:8082'
Write-Output '=== RESULT ==='
if (-not (Get-Process qubes-updates-relay -EA SilentlyContinue)) {
    Start-Process -FilePath $relay -ArgumentList '--listen','8082','--target','@default','--log',$wu -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

$urls = @(
    'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/disallowedcertstl.cab',
    'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab',
    'http://download.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab'
)
foreach ($u in $urls) {
    $short = ($u -split '/')[2] + '/...' + (($u -split '/')[-1])
    try {
        $r = Invoke-WebRequest $u -Proxy $proxy -UseBasicParsing -TimeoutSec 45
        Write-Output ("PLAIN-HTTP {0,-52} HTTP {1}  bytes={2}" -f $short, [int]$r.StatusCode, $r.RawContentLength)
    } catch {
        Write-Output ("PLAIN-HTTP {0,-52} FAILED: {1}" -f $short, $_.Exception.Message)
    }
}

# Same host over HTTPS, i.e. via CONNECT rather than a plain GET - separates "host unreachable"
# from "plain-HTTP proxying is broken".
try {
    $r = Invoke-WebRequest 'https://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab' -Proxy $proxy -UseBasicParsing -TimeoutSec 45
    Write-Output ("HTTPS/CONNECT ctldl authrootstl.cab                       HTTP {0}  bytes={1}" -f [int]$r.StatusCode, $r.RawContentLength)
} catch {
    Write-Output ("HTTPS/CONNECT ctldl authrootstl.cab                       FAILED: {0}" -f $_.Exception.Message)
}

# A control: a plain-HTTP GET to a host we KNOW works over CONNECT.
try {
    $r = Invoke-WebRequest 'http://www.catalog.update.microsoft.com/' -Proxy $proxy -UseBasicParsing -TimeoutSec 45 -MaximumRedirection 0
    Write-Output ("CONTROL plain-http catalog                                HTTP {0}  bytes={1}" -f [int]$r.StatusCode, $r.RawContentLength)
} catch {
    Write-Output ("CONTROL plain-http catalog                                {0}" -f $_.Exception.Message)
}
