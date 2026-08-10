# (ii) check: does the update's DownloadContents include the FULL (non-delta) package alongside
# the 13421 express deltas? Each IUpdateDownloadContent2 exposes IsDeltaCompressedContent - full
# files are False. If a small set of full files exists, B fetches THOSE over the proxy and skips
# express entirely, no config change. If everything is delta, we fall to the Update Catalog (i).
$ErrorActionPreference = 'Continue'
$rep = [ordered]@{}
try {
    $s = New-Object -ComObject Microsoft.Update.Session
    $se = $s.CreateUpdateSearcher(); $se.ServerSelection = 2; $se.Online = $true
    $r = $se.Search("IsInstalled=0 and IsHidden=0")
    $u = $r.Updates.Item(0)
    $rep.title = "$($u.Title)"

    $items = @($u); try { if ($u.BundledUpdates.Count -gt 0) { $items = @($u.BundledUpdates) } } catch {}
    $full = New-Object System.Collections.ArrayList
    $delta = 0; $unknown = 0; $total = 0
    foreach ($it in $items) {
        try { foreach ($dc in $it.DownloadContents) {
            $total++
            $isDelta = $null
            try { $isDelta = $dc.IsDeltaCompressedContent } catch { $unknown++ ; continue }
            if ($isDelta) { $delta++ }
            else { if ($dc.DownloadUrl) { [void]$full.Add("$($dc.DownloadUrl)") } }
        } } catch {}
    }
    $rep.total       = $total
    $rep.delta       = $delta
    $rep.unknown     = $unknown
    $rep.full_count  = $full.Count
    $rep.full_urls   = @($full | Select-Object -First 8)
} catch {
    $hr = if($_.Exception.InnerException){$_.Exception.InnerException.HResult}else{$_.Exception.HResult}
    $rep.err = "EXC 0x" + ('{0:X8}' -f ($hr -band 0xFFFFFFFF))
}
Write-Output ('=== WUFULL === ' + ($rep | ConvertTo-Json -Compress -Depth 5))
