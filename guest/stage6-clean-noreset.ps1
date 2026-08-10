# Stage 6 CLEAN test: no WU reset (the guest is a pristine golden - resetting was what raced
# WU startup and caused 0x80240022). Just: planes + SYSTEM proxy + improved relay (high
# concurrency; read-first prevents the DO fork-bomb), then ONE scan+download, uninterrupted.
# Writes result + done marker. Run as a scheduled task so it survives to completion.
$ErrorActionPreference = 'Continue'
$exe = 'C:\Users\Public\relaytest\qubes-updates-relay.exe'
$log = 'C:\Users\Public\relaytest\qubes-updates-relay.log'
$IS  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
$DO  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }

Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name DoNotConnectToWindowsUpdateInternetLocations -EA SilentlyContinue
& netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
SetV $POL 'ProxySettingsPerUser' 0 'DWord'; SetV $IS 'ProxyEnable' 1 'DWord'; SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'; SetV $DO 'DODownloadMode' 0 'DWord'
& bitsadmin /util /setieproxy LOCALSYSTEM MANUAL_PROXY '127.0.0.1:8082' '<local>' 2>&1 | Out-Null

# improved relay, high concurrency (read-first keeps DO's fan-out from fork-bombing)
$env:QUBES_UPDATES_MAXCONN = '256'
Get-NetTCPConnection -LocalPort 8082 -State Listen -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue }
Get-Process qubes-updates-relay -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Remove-Item $log -EA SilentlyContinue
Start-Process -FilePath $exe -ArgumentList '--listen','8082','--target','@default','--log','C:\Users\Public\relaytest' -WindowStyle Hidden
Start-Sleep -Milliseconds 1500

$out = [ordered]@{ mode='clean-noreset'; search=$null; title=$null; download=$null; install=$null; downloaded_mb=$null; reboot=$null; relay_conns=$null }
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
        if ($dr.ResultCode -eq 2) {
            $inst = $s.CreateUpdateInstaller(); $inst.Updates = $coll
            $ir = $inst.Install()
            $out.install = "resultCode=" + $ir.ResultCode + " hresult=0x" + ('{0:X8}' -f ($ir.HResult -band 0xFFFFFFFF))
            $out.reboot = [bool]$ir.RebootRequired
        }
    }
} catch {
    $hr = if($_.Exception.InnerException){$_.Exception.InnerException.HResult}else{$_.Exception.HResult}
    $out.download = "EXC 0x" + ('{0:X8}' -f ($hr -band 0xFFFFFFFF))
}
$out.downloaded_mb = [math]::Round((Get-ChildItem C:\Windows\SoftwareDistribution\Download -Recurse -File -EA SilentlyContinue|Measure-Object Length -Sum).Sum/1MB,1)
$out.relay_conns = (@(Get-Content $log -EA SilentlyContinue | Where-Object { $_ -match 'CONN token=' }).Count)
($out | ConvertTo-Json -Compress) | Set-Content -LiteralPath 'C:\Users\Public\stage6clean-result.txt'
'DONE' | Set-Content -LiteralPath 'C:\Users\Public\stage6clean-done.txt'
