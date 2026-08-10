# Stage 6 clean DO test with the IMPROVED relay (read-first + concurrency cap). Keeps DO on
# its default path (DoSvc enabled) - the fix is in the relay, not in fighting DO. Resets the
# confused WU state, one clean uninterrupted download, writes a result + done marker.
$ErrorActionPreference = 'Continue'
$exe = 'C:\Users\Public\relaytest\qubes-updates-relay.exe'
$log = 'C:\Users\Public\relaytest\qubes-updates-relay.log'
$IS  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
$DO  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }

# planes + SYSTEM proxy; DODownloadMode=0 (HTTP only, no peering) but DO stays in charge
& netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
SetV $POL 'ProxySettingsPerUser' 0 'DWord'; SetV $IS 'ProxyEnable' 1 'DWord'; SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'; SetV $DO 'DODownloadMode' 0 'DWord'
& bitsadmin /util /setieproxy LOCALSYSTEM MANUAL_PROXY '127.0.0.1:8082' '<local>' 2>&1 | Out-Null

# reset the confused WU state
& net stop wuauserv 2>&1 | Out-Null; & net stop bits 2>&1 | Out-Null; & net stop dosvc 2>&1 | Out-Null
Remove-Item 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -EA SilentlyContinue
& net start bits 2>&1 | Out-Null; & net start dosvc 2>&1 | Out-Null; & net start wuauserv 2>&1 | Out-Null
Start-Sleep -Seconds 6

# fresh relay (the improved build) + fresh log
Get-NetTCPConnection -LocalPort 8082 -State Listen -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue }
Get-Process qubes-updates-relay -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Remove-Item $log -EA SilentlyContinue
Start-Process -FilePath $exe -ArgumentList '--listen','8082','--target','@default','--log','C:\Users\Public\relaytest' -WindowStyle Hidden
Start-Sleep -Milliseconds 1500

$out = [ordered]@{ mode='DO+improved-relay'; search=$null; title=$null; download=$null; downloaded_mb=$null; relay_spawned=$null }
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
$out.relay_spawned = (@(Get-Content $log -EA SilentlyContinue | Where-Object { $_ -match 'CONN token=' }).Count)
($out | ConvertTo-Json -Compress) | Set-Content -LiteralPath 'C:\Users\Public\stage6do-result.txt'
'DONE' | Set-Content -LiteralPath 'C:\Users\Public\stage6do-done.txt'
