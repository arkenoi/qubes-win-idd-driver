# Clarify the 13421-file result: are they distinct FILES (distinct GUIDs) or express byte-range
# variants of a few? tlu URLs look like .../files/<GUID>?P1=...&P2=... - the GUID is the file,
# the P* params are express ranges. Count distinct GUIDs and show a few full URLs, and check
# whether a non-express "full" download is selectable.
$ErrorActionPreference = 'Continue'
$rep = [ordered]@{}
try {
    $s = New-Object -ComObject Microsoft.Update.Session
    $se = $s.CreateUpdateSearcher(); $se.ServerSelection = 2; $se.Online = $true
    $r = $se.Search("IsInstalled=0 and IsHidden=0")
    $u = $r.Updates.Item(0)
    $rep.title = "$($u.Title)"
    # try to force NON-express (full-file) selection if the API allows it
    try { $rep.express_supported = [bool]$u.IsPresent } catch {}
    $guids = @{}
    $exts  = @{}
    $items = @($u); try { if ($u.BundledUpdates.Count -gt 0) { $items = @($u.BundledUpdates) } } catch {}
    $total = 0
    foreach ($it in $items) {
        try { foreach ($dc in $it.DownloadContents) {
            $url = "$($dc.DownloadUrl)"; if (-not $url) { continue }
            $total++
            $g = $url -replace '\?.*$',''         # strip query -> file identity
            $g = $g -replace '.*/',''             # last path segment (GUID or filename)
            $guids[$g] = 1
            if ($url -match '\.([a-zA-Z0-9]{2,4})(\?|$)') { $exts[$Matches[1]] = 1 }
        } } catch {}
    }
    $rep.total_entries   = $total
    $rep.distinct_files  = $guids.Count
    $rep.extensions      = ($exts.Keys -join ',')
    $rep.sample_distinct = @($guids.Keys | Select-Object -First 5)
    # does any bundled update expose a single full package (heuristic: a .cab/.msu/.psf)?
    $rep.bundled_count   = @($items).Count
} catch {
    $hr = if($_.Exception.InnerException){$_.Exception.InnerException.HResult}else{$_.Exception.HResult}
    $rep.err = "EXC 0x" + ('{0:X8}' -f ($hr -band 0xFFFFFFFF))
}
Write-Output ('=== WUDIST === ' + ($rep | ConvertTo-Json -Compress -Depth 5))
