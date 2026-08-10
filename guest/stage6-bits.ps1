# Stage 6, force-BITS variant. The tinyproxy introspection showed Delivery Optimization
# opening a connection STORM (2600+ conns, many abandoned) that overwhelms the per-connection
# qrexec relay (R3). Fix: disable DoSvc so WU uses classic BITS (few, sequential, long-lived
# connections) - a good fit for the relay. Reset the confused WU state first, then one clean
# uninterrupted scan+download. Writes a marker when done. Run as a scheduled task (survives).
$ErrorActionPreference = 'Continue'
$exe = 'C:\Users\Public\relaytest\qubes-updates-relay.exe'
$IS  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
$DO  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }

# planes + SYSTEM proxy
& netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
SetV $POL 'ProxySettingsPerUser' 0 'DWord'; SetV $IS 'ProxyEnable' 1 'DWord'; SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'
& bitsadmin /util /setieproxy LOCALSYSTEM MANUAL_PROXY '127.0.0.1:8082' '<local>' 2>&1 | Out-Null

# FORCE BITS: kill Delivery Optimization so WU uses BITS. DODownloadMode=99 (bypass/simple),
# and stop+disable DoSvc so it cannot take the download.
SetV $DO 'DODownloadMode' 99 'DWord'
& sc.exe stop DoSvc 2>&1 | Out-Null
& sc.exe config DoSvc start= disabled 2>&1 | Out-Null

# CLEAN the confused WU state (owner: it is in an undefined state after interrupted runs).
& net stop wuauserv 2>&1 | Out-Null; & net stop bits 2>&1 | Out-Null
Remove-Item 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -EA SilentlyContinue
& net start bits 2>&1 | Out-Null; & net start wuauserv 2>&1 | Out-Null
Start-Sleep -Seconds 6

# relay
Get-NetTCPConnection -LocalPort 8082 -State Listen -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue }
Start-Process -FilePath $exe -ArgumentList '--listen','8082','--target','@default','--log','C:\Users\Public\relaytest' -WindowStyle Hidden
Start-Sleep -Milliseconds 1500

# one clean scan + download (BITS)
$out = [ordered]@{ mode='force-BITS'; search=$null; title=$null; download=$null; downloaded_mb=$null }
try {
    $s = New-Object -ComObject Microsoft.Update.Session
    $se = $s.CreateUpdateSearcher(); $se.ServerSelection=2; $se.Online=$true
    $r = $se.Search("IsInstalled=0 and IsHidden=0")
    $out.search = "count=" + $r.Updates.Count
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach($u in $r.Updates){ $out.title = $u.Title; try{ if(-not $u.EulaAccepted){$u.AcceptEula()} }catch{}; [void]$coll.Add($u) }
    if ($coll.Count -gt 0) {
        $dl = $s.CreateUpdateDownloader(); $dl.Updates = $coll
        $dr = $dl.Download()
        $out.download = "resultCode=" + $dr.ResultCode + " hresult=0x" + ('{0:X8}' -f ($dr.HResult -band 0xFFFFFFFF))
    }
} catch {
    $hr = if($_.Exception.InnerException){$_.Exception.InnerException.HResult}else{$_.Exception.HResult}
    $out.download = "EXC 0x" + ('{0:X8}' -f ($hr -band 0xFFFFFFFF))
}
$out.downloaded_mb = [math]::Round((Get-ChildItem C:\Windows\SoftwareDistribution\Download -Recurse -File -EA SilentlyContinue|Measure-Object Length -Sum).Sum/1MB,1)
($out | ConvertTo-Json -Compress) | Set-Content -LiteralPath 'C:\Users\Public\stage6bits-result.txt'
'DONE' | Set-Content -LiteralPath 'C:\Users\Public\stage6bits-done.txt'
