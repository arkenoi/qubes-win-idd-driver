# (i) full resolver: KB -> Update Catalog -> standalone .msu URL(s) + size, all through the proxy.
# Search page uses single quotes (goToDetails("<guid>")) and per-row titles; DownloadDialog.aspx
# POST with the update GUID returns the real download URL(s). This is the fetch target for B.
$ErrorActionPreference = 'Continue'
$kb = 'KB5101650'
$proxy = 'http://127.0.0.1:8082'
$rep = [ordered]@{ kb=$kb }
try {
    $r = Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/Search.aspx?q=$kb" -Proxy $proxy -UseBasicParsing -TimeoutSec 40
    $html = $r.Content
    # (guid, title): the row anchor id='<guid>_link' ... >TITLE</a>  (single quotes, tolerant)
    $rx = [regex]"(?is)id='([0-9a-fA-F\-]{36})_link'[^>]*>(.*?)</a>"
    $cands = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($m in $rx.Matches($html)) {
        $guid = $m.Groups[1].Value
        if ($seen.ContainsKey($guid)) { continue }; $seen[$guid] = 1
        $title = ($m.Groups[2].Value -replace '<[^>]+>','' -replace '\s+',' ').Trim()
        [void]$cands.Add([ordered]@{ guid=$guid; title=$title })
    }
    $rep.n_results = $cands.Count

    # pick x64 24H2/26100 client cumulative; avoid Dynamic/ARM64/server
    $pick = $cands | Where-Object {
        $_.title -match 'x64' -and $_.title -match '24H2|26100|Version 24H2' -and
        $_.title -notmatch 'ARM64|Dynamic|Server' } | Select-Object -First 1
    if (-not $pick) { $pick = $cands | Where-Object { $_.title -match 'x64' -and $_.title -notmatch 'ARM64|Dynamic' } | Select-Object -First 1 }
    $rep.picked = if ($pick) { "$($pick.title)" } else { '(none matched)' }
    $rep.picked_guid = if ($pick) { $pick.guid } else { $null }

    if ($pick) {
        $json = '[{"size":0,"languages":"","uidInfo":"' + $pick.guid + '","updateID":"' + $pick.guid + '"}]'
        $dl = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method POST `
              -Body @{ updateIDs = $json } -Proxy $proxy -UseBasicParsing -TimeoutSec 40
        $urls = [regex]::Matches($dl.Content, "url\s*=\s*'(http[^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $urls = @($urls | Where-Object { $_ -match '\.(msu|cab)(\?|$)' })
        $rep.msu_urls = $urls
        if ($urls.Count -gt 0) {
            try {
                $h = Invoke-WebRequest -Uri $urls[0] -Method Head -Proxy $proxy -UseBasicParsing -TimeoutSec 40
                $len = $h.Headers['Content-Length']
                $rep.first_size_mb = if ($len) { [math]::Round(($len -as [long])/1MB,1) } else { 'unknown' }
            } catch { $rep.first_size_mb = "HEAD EXC: $($_.Exception.Message)" }
        }
    }
} catch { $rep.err = "EXC: $($_.Exception.Message)" }
Write-Output ('=== WUCATGET === ' + ($rep | ConvertTo-Json -Compress -Depth 6))
