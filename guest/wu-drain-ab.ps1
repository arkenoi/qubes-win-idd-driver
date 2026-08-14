<#
.SYNOPSIS
  Is the plain-HTTP truncation caused by the relay's drain timeout?

.DESCRIPTION
  The same URL returns 30-80 KB at random on BOTH the pre-allowlist and the shipped relay, so the
  truncation is not the allowlist. Prime suspect: QUBES_UPDATES_DRAINMS, cut from 3000 ms to a 250 ms
  default earlier in this project to make downloads snappier. If the relay stops draining 250 ms
  after the last byte and closes, a response that pauses mid-body is truncated - and reported as a
  successful fetch, which is exactly what we see.

  Interleaved A/B at three drain values. The judgement is not "did it succeed" but "is the byte
  count CONSTANT and equal to the true length" - the true length is what
  download.windowsupdate.com serves for the same file: 80043.
#>
param([int]$PerRound = 5, [int]$Rounds = 2)
$ErrorActionPreference = 'Continue'
$exe   = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe'
$wu    = 'C:\ProgramData\Qubes\wu'
$proxy = 'http://127.0.0.1:8082'
$url   = 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab'
$TRUE_LEN = 80043
Write-Output '=== RESULT ==='

$stats = @{}
foreach ($d in 250, 3000, 8000) { $stats[$d] = [ordered]@{ ok=0; fail=0; full=0; sizes=New-Object 'System.Collections.Generic.HashSet[int]' } }

for ($r = 1; $r -le $Rounds; $r++) {
    foreach ($drain in 250, 3000, 8000) {
        Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }
        Start-Sleep -Seconds 2
        $env:QUBES_UPDATES_DRAINMS = "$drain"
        Start-Process -FilePath $exe -ArgumentList '--listen','8082','--target','@default','--log',$wu -WindowStyle Hidden
        Start-Sleep -Seconds 3
        for ($i = 1; $i -le $PerRound; $i++) {
            try {
                $resp = Invoke-WebRequest $url -Proxy $proxy -UseBasicParsing -TimeoutSec 60
                $len = [int]$resp.RawContentLength
                $stats[$drain].ok++
                [void]$stats[$drain].sizes.Add($len)
                if ($len -eq $TRUE_LEN) { $stats[$drain].full++ }
            } catch { $stats[$drain].fail++ }
            Start-Sleep -Milliseconds 500
        }
    }
}
Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }
Remove-Item Env:\QUBES_UPDATES_DRAINMS -EA SilentlyContinue

foreach ($d in 250, 3000, 8000) {
    $s = $stats[$d]
    $sz = if ($s.sizes.Count) { ($s.sizes | Sort-Object) -join ',' } else { 'n/a' }
    Write-Output ("DRAINMS={0,-5} ok={1,-3} fail={2,-3} full-length={3}/{1}  distinct sizes: {4}" -f $d, $s.ok, $s.fail, $s.full, $sz)
}
Write-Output ("true length (as served by download.windowsupdate.com) = {0}" -f $TRUE_LEN)
