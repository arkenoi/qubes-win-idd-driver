# Is the plain-HTTP path through the relay RELIABLE, or does it drop requests at random?
#
# The relay log says ctldl.windowsupdate.com came back ok x2 and zero-bytes x5 - the same host, both
# outcomes. If a repeat of the SAME url both succeeds and fails, the tunnel drops requests
# intermittently, which is a reliability defect in our own egress path and would explain why the WU
# scan fails on one boot and works on another. If one url always works and another always fails,
# it is about the request, not the tunnel.
# -Target names the qube that will serve qubes.UpdatesProxy. Default @default lets dom0 policy
# decide, which is precisely the hop we cannot see; naming a qube we control (win-idd-mgmt, running
# our own instrumented tinyproxy) turns the invisible half of the path into an observed one.
param([int]$Repeats = 6, [string]$Target = '@default')
$ErrorActionPreference = 'Continue'
$proxy = 'http://127.0.0.1:8082'
$relay = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe'
$wu    = 'C:\ProgramData\Qubes\wu'
Write-Output '=== RESULT ==='
Write-Output ("proxy target = {0}" -f $Target)
Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep -Seconds 2
Start-Process -FilePath $relay -ArgumentList '--listen','8082','--target',$Target,'--log',$wu -WindowStyle Hidden
Start-Sleep -Seconds 3
$urls = [ordered]@{
    'disallowedcertstl.cab' = 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/disallowedcertstl.cab'
    'authrootstl.cab'       = 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab'
}
foreach ($name in $urls.Keys) {
    $ok = 0; $fail = 0; $bytes = @()
    for ($i = 1; $i -le $Repeats; $i++) {
        try {
            $r = Invoke-WebRequest $urls[$name] -Proxy $proxy -UseBasicParsing -TimeoutSec 40
            $ok++; $bytes += $r.RawContentLength
        } catch { $fail++ }
        Start-Sleep -Milliseconds 800
    }
    $b = if ($bytes.Count) { ($bytes | Sort-Object -Unique) -join ',' } else { 'n/a' }
    Write-Output ("{0,-24} ok={1}/{2}  failed={3}  bytes={4}" -f $name, $ok, $Repeats, $fail, $b)
}
Write-Output 'verdict: mixed ok/failed for the SAME url => the tunnel drops plain-HTTP requests intermittently'
