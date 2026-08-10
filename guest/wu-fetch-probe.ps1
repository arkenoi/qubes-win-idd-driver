# Prove the LAST unproven link of B: a SUSTAINED multi-GB HTTP fetch of the real .msu through the
# proxy (no BITS, no DO, no connectivity gate). Re-resolve the URL, stream it for ~40s, report
# bytes + rate. Steady climb = B's download works where BITS died at the connectivity gate.
$ErrorActionPreference = 'Continue'
$proxy = 'http://127.0.0.1:8082'
$rep = [ordered]@{}
# resolve first .msu URL from the catalog (same as wu-catalog-get)
$r = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/Search.aspx?q=KB5101650' -Proxy $proxy -UseBasicParsing -TimeoutSec 40
$rx = [regex]"(?is)id='([0-9a-fA-F\-]{36})_link'[^>]*>(.*?)</a>"
$guid = $null
foreach ($m in $rx.Matches($r.Content)) {
    $t = ($m.Groups[2].Value -replace '<[^>]+>','' -replace '\s+',' ')
    if ($t -match 'x64' -and $t -match '24H2|26100' -and $t -notmatch 'ARM64|Dynamic|Server') { $guid = $m.Groups[1].Value; break }
}
$json = '[{"size":0,"languages":"","uidInfo":"' + $guid + '","updateID":"' + $guid + '"}]'
$dl = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method POST -Body @{ updateIDs = $json } -Proxy $proxy -UseBasicParsing -TimeoutSec 40
$url = ([regex]::Matches($dl.Content, "url\s*=\s*'(http[^']+)'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match '\.msu(\?|$)' } | Select-Object -First 1)
$rep.url = "$url"

New-Item -ItemType Directory -Force -Path 'C:\Users\Public\wu' | Out-Null
$dst = 'C:\Users\Public\wu\lcu.msu'
Remove-Item $dst -EA SilentlyContinue
try {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Proxy = New-Object System.Net.WebProxy($proxy)
    $req.Timeout = 40000; $req.ReadWriteTimeout = 40000
    $resp = $req.GetResponse()
    $rep.http_status = [int]$resp.StatusCode
    $rep.content_len_mb = [math]::Round($resp.ContentLength/1MB,1)
    $in = $resp.GetResponseStream()
    $out = [System.IO.File]::Create($dst)
    $buf = New-Object byte[] (1MB)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $total = 0L
    while ($sw.Elapsed.TotalSeconds -lt 40) {
        $n = $in.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $out.Write($buf, 0, $n); $total += $n
    }
    $out.Close(); $in.Close(); $resp.Close()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds,1)
    $rep.downloaded_mb = [math]::Round($total/1MB,1)
    $rep.seconds = $secs
    $rep.rate_mbps = if ($secs -gt 0) { [math]::Round(($total/1MB)/$secs,2) } else { 0 }
} catch { $rep.fetch_err = "EXC: $($_.Exception.Message)" }
Write-Output ('=== WUFETCH === ' + ($rep | ConvertTo-Json -Compress -Depth 5))
