# (i) de-risk: can we reach the Microsoft Update Catalog THROUGH the proxy (HTTPS CONNECT), and
# parse the update GUIDs+titles for a KB out of the search page? If yes, the DownloadDialog POST
# then yields the standalone .msu URL (next step). Reports status + candidate (guid,title,x64?).
$ErrorActionPreference = 'Continue'
$kb = 'KB5101650'
$proxy = 'http://127.0.0.1:8082'
$rep = [ordered]@{ kb=$kb }
try {
    $u = "https://www.catalog.update.microsoft.com/Search.aspx?q=$kb"
    $r = Invoke-WebRequest -Uri $u -Proxy $proxy -UseBasicParsing -TimeoutSec 40
    $rep.http = "status=$($r.StatusCode) len=$($r.Content.Length)"
    $html = $r.Content
    # Each result row exposes the update GUID as id="<guid>" on a link/input, and a title cell.
    # Tolerant parse: pull "<guid>_link">Title</a> pairs (the catalog's per-row title anchor).
    $rx = [regex]'(?is)<a[^>]*id="([0-9a-fA-F\-]{36})_link"[^>]*>\s*(.*?)\s*</a>'
    $cands = New-Object System.Collections.ArrayList
    foreach ($m in $rx.Matches($html)) {
        $guid = $m.Groups[1].Value
        $title = ($m.Groups[2].Value -replace '<[^>]+>','' -replace '\s+',' ').Trim()
        [void]$cands.Add([ordered]@{ guid=$guid; title=$title; x64=[bool]($title -match 'x64'); build=[bool]($title -match '24H2|26100') })
    }
    $rep.n_results = $cands.Count
    $rep.candidates = @($cands | Select-Object -First 12)
    if ($cands.Count -eq 0) {
        # fall back: show whether any GUIDs are present at all + a snippet to guide the parser
        $rep.any_guids = ([regex]'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Matches($html).Count
        $i = $html.IndexOf('_link'); if ($i -lt 0) { $i = 0 }
        $rep.snippet = $html.Substring([math]::Max(0,$i-160), [math]::Min(320,$html.Length-[math]::Max(0,$i-160)))
    }
} catch {
    $rep.err = "EXC: $($_.Exception.Message)"
}
Write-Output ('=== WUCAT === ' + ($rep | ConvertTo-Json -Compress -Depth 6))
