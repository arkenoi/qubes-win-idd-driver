# Path B, step 1: prove the WU search result exposes usable per-file download URLs (the make-or-
# break). Search over the proxy, then for every pending update enumerate DownloadContents URLs -
# recursing BundledUpdates, where a cumulative's actual .cab/.psf payload files live. Reports a
# compact list so we can pick a SMALL update to fetch+install as the end-to-end proof next.
$ErrorActionPreference = 'Continue'
$exe = 'C:\Users\Public\relaytest\qubes-updates-relay.exe'
$IS  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }

# planes + ensure relay is up (search rides WinHTTP/WinINET through it)
& netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
SetV $POL 'ProxySettingsPerUser' 0 'DWord'; SetV $IS 'ProxyEnable' 1 'DWord'
SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'
if (-not (Get-Process qubes-updates-relay -EA SilentlyContinue)) {
    $env:QUBES_UPDATES_MAXCONN = '256'
    Start-Process -FilePath $exe -ArgumentList '--listen','8082','--target','@default','--log','C:\Users\Public\relaytest' -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

$rep = [ordered]@{ search=$null; updates=@() }
try {
    $s = New-Object -ComObject Microsoft.Update.Session
    $se = $s.CreateUpdateSearcher(); $se.ServerSelection = 2; $se.Online = $true
    $r = $se.Search("IsInstalled=0 and IsHidden=0")
    $rep.search = "count=$($r.Updates.Count)"
    foreach ($u in $r.Updates) {
        $urls = New-Object System.Collections.ArrayList
        $items = @($u)
        try { if ($u.BundledUpdates.Count -gt 0) { $items = @($u.BundledUpdates) } } catch {}
        foreach ($it in $items) {
            try { foreach ($dc in $it.DownloadContents) { if ($dc.DownloadUrl) { [void]$urls.Add($dc.DownloadUrl) } } } catch {}
        }
        $sz = 0; try { $sz = [math]::Round($u.MaxDownloadSize/1MB,1) } catch {}
        $rep.updates += [ordered]@{
            title      = "$($u.Title)"
            size_mb    = $sz
            downloaded = [bool]$u.IsDownloaded
            n_files    = $urls.Count
            sample_url = if ($urls.Count -gt 0) { "$($urls[0])" } else { '(none exposed)' }
        }
    }
} catch {
    $hr = if($_.Exception.InnerException){$_.Exception.InnerException.HResult}else{$_.Exception.HResult}
    $rep.search = "EXC 0x" + ('{0:X8}' -f ($hr -band 0xFFFFFFFF))
}
Write-Output ('=== WUENUM === ' + ($rep | ConvertTo-Json -Compress -Depth 5))
