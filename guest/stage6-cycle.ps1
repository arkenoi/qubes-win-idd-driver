# Stage 6: full WU cycle - search -> download -> install - through the updates-proxy tunnel.
# Self-contained: re-asserts the planes + SYSTEM proxy, starts the relay and keeps it alive as
# a child for the whole cycle (this script blocks in the COM calls, so the relay lives), then
# reports each phase's HRESULT/ResultCode + the update titles/sizes + relay traffic. COM
# IUpdateDownloader/IUpdateInstaller give concrete result codes (2=OK,3=OK-with-errors,4=Failed).
param([switch]$InstallToo)   # download always; install only with -InstallToo (install may reboot)
$ErrorActionPreference = 'Continue'
$exe = 'C:\Users\Public\relaytest\qubes-updates-relay.exe'
$log = 'C:\Users\Public\relaytest\qubes-updates-relay.log'
$IS  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
$DO  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }

# planes + SYSTEM proxy (idempotent)
& netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
SetV $POL 'ProxySettingsPerUser' 0 'DWord'; SetV $IS 'ProxyEnable' 1 'DWord'; SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'; SetV $DO 'DODownloadMode' 0 'DWord'
& bitsadmin /util /setieproxy LOCALSYSTEM MANUAL_PROXY '127.0.0.1:8082' '<local>' 2>&1 | Out-Null

# relay (kept alive by this script)
Get-NetTCPConnection -LocalPort 8082 -State Listen -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue }
Remove-Item $log -EA SilentlyContinue
$relay = Start-Process -FilePath $exe -ArgumentList '--listen','8082','--target','@default','--log','C:\Users\Public\relaytest' -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 1200

$out = [ordered]@{ search=$null; updates=@(); download=$null; install=$null; reboot_required=$null; relay_conns=$null }
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher(); $searcher.ServerSelection = 2; $searcher.Online = $true
    $sr = $searcher.Search("IsInstalled=0 and IsHidden=0")
    $out.search = "ok count=" + $sr.Updates.Count
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $sr.Updates) {
        $mb = [math]::Round($u.MaxDownloadSize/1MB,1)
        $out.updates += ("" + $u.Title + " | " + $mb + "MB")
        try { if (-not $u.EulaAccepted) { $u.AcceptEula() } } catch {}
        [void]$coll.Add($u)
    }
    if ($coll.Count -gt 0) {
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll
        $dr = $dl.Download()
        $out.download = "resultCode=" + $dr.ResultCode + " hresult=0x" + ('{0:X8}' -f ($dr.HResult -band 0xFFFFFFFF))
        if ($InstallToo -and $dr.ResultCode -eq 2) {
            $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
            $ir = $inst.Install()
            $out.install = "resultCode=" + $ir.ResultCode + " hresult=0x" + ('{0:X8}' -f ($ir.HResult -band 0xFFFFFFFF))
            $out.reboot_required = [bool]$ir.RebootRequired
        }
    }
} catch {
    $hr = if($_.Exception.InnerException){$_.Exception.InnerException.HResult}else{$_.Exception.HResult}
    $out.search = "EXC 0x" + ('{0:X8}' -f ($hr -band 0xFFFFFFFF)) + " " + $_.Exception.Message
}
$conns = @(); if (Test-Path $log) { $conns = @((Get-Content $log | Where-Object { $_ -match 'CONN ' }) | ForEach-Object { [string]$_ }) }
$out.relay_conns = $conns.Count
try { Stop-Process -Id $relay.Id -Force -EA SilentlyContinue } catch {}
Write-Output ("=== RESULT === " + ($out | ConvertTo-Json -Compress -Depth 4))
