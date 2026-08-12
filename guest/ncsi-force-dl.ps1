# Hypothesis test: BITS/DO refuse to transfer because NCSI's active probe (direct GET to
# msftconnecttest.com, bypassing the proxy) fails -> NLM reports "no internet" -> background
# transfers are gated off. Force NLM to a connected verdict, then re-run Download() (metadata
# is already cached from the prior scan) and watch whether payload bytes move.
$ErrorActionPreference = 'Continue'
$NLA = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }

# 1) stop the active probe that always fails offline; passive detection then assumes reachable
SetV $NLA 'EnableActiveProbing' 0 'DWord'
# 2) DO: HTTP-only, and tell it not to demand internet-cost signals it can't get
SetV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0 'DWord'
& net stop NlaSvc 2>&1 | Out-Null; & net start NlaSvc 2>&1 | Out-Null
Start-Sleep -Seconds 5

$n = New-Object -ComObject 'Microsoft.NetworkListManager'
$before = "NLM IsConnected=$($n.IsConnected) IsConnectedToInternet=$($n.IsConnectedToInternet)"

$out = [ordered]@{ nlm=$before; search=$null; download=$null; bytes0=$null; bytes1=$null; bits=$null }
try {
    $s = New-Object -ComObject Microsoft.Update.Session
    $se = $s.CreateUpdateSearcher(); $se.ServerSelection=2; $se.Online=$true
    $r = $se.Search("IsInstalled=0 and IsHidden=0")
    $out.search = "count=" + $r.Updates.Count
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach($u in $r.Updates){ try{ if(-not $u.EulaAccepted){$u.AcceptEula()} }catch{}; [void]$coll.Add($u) }
    $out.bytes0 = [math]::Round((Get-ChildItem C:\Windows\SoftwareDistribution\Download -Recurse -File -EA SilentlyContinue|Measure-Object Length -Sum).Sum/1MB,1)
    if ($coll.Count -gt 0) {
        $dl = $s.CreateUpdateDownloader(); $dl.Updates = $coll
        $dr = $dl.Download()
        $out.download = "resultCode=" + $dr.ResultCode + " hresult=0x" + ('{0:X8}' -f ($dr.HResult -band 0xFFFFFFFF))
    }
} catch {
    $hr = if($_.Exception.InnerException){$_.Exception.InnerException.HResult}else{$_.Exception.HResult}
    $out.download = "EXC 0x" + ('{0:X8}' -f ($hr -band 0xFFFFFFFF))
}
$out.bytes1 = [math]::Round((Get-ChildItem C:\Windows\SoftwareDistribution\Download -Recurse -File -EA SilentlyContinue|Measure-Object Length -Sum).Sum/1MB,1)
$out.bits = (Get-BitsTransfer -AllUsers -EA SilentlyContinue | ForEach-Object { "$($_.JobState):$([math]::Round($_.BytesTransferred/1MB,1))MB" }) -join ','
($out | ConvertTo-Json -Compress) | Set-Content -LiteralPath 'C:\Users\Public\ncsi-result.txt'
'DONE' | Set-Content -LiteralPath 'C:\Users\Public\ncsi-done.txt'
