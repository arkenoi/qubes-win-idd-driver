<#
.SYNOPSIS
  Is the warm channel pool responsible for the plain-HTTP drops and truncation?

.DESCRIPTION
  Every failing request logged warm=1. A warm channel is a qrexec connection to the updates proxy
  opened seconds-to-minutes BEFORE the request that uses it, and an upstream that closes or half-
  closes an idle connection would produce exactly what we see: down=0 (the response never arrives)
  and short bodies reported as success.

  QUBES_UPDATES_POOL=0 disables pre-opening, so every request gets a channel created for it. If the
  byte count becomes constant at the true length, the pool is the mechanism and the fix is ours. If
  truncation persists with a fresh channel per request, the fault is upstream of the relay
  (tinyproxy's plain-HTTP handling or the qrexec transport) and this is NOT ours to fix - which is
  worth knowing before writing any code.

  Interleaved, because the upstream is shared and drifts.
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
foreach ($p in 0, 8) { $stats[$p] = [ordered]@{ ok=0; fail=0; full=0; sizes=New-Object 'System.Collections.Generic.HashSet[int]' } }

for ($r = 1; $r -le $Rounds; $r++) {
    foreach ($pool in 0, 8) {
        Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }
        Start-Sleep -Seconds 2
        $env:QUBES_UPDATES_POOL = "$pool"
        Start-Process -FilePath $exe -ArgumentList '--listen','8082','--target','@default','--log',$wu -WindowStyle Hidden
        Start-Sleep -Seconds 4
        for ($i = 1; $i -le $PerRound; $i++) {
            try {
                $resp = Invoke-WebRequest $url -Proxy $proxy -UseBasicParsing -TimeoutSec 60
                $len = [int]$resp.RawContentLength
                $stats[$pool].ok++
                [void]$stats[$pool].sizes.Add($len)
                if ($len -eq $TRUE_LEN) { $stats[$pool].full++ }
            } catch { $stats[$pool].fail++ }
            Start-Sleep -Milliseconds 500
        }
    }
}
Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }
Remove-Item Env:\QUBES_UPDATES_POOL -EA SilentlyContinue

foreach ($p in 0, 8) {
    $s = $stats[$p]
    $sz = if ($s.sizes.Count) { ($s.sizes | Sort-Object) -join ',' } else { 'n/a' }
    Write-Output ("POOL={0,-2} ok={1,-3} fail={2,-3} full-length={3}/{1}  distinct sizes: {4}" -f $p, $s.ok, $s.fail, $s.full, $sz)
}
Write-Output ("true length = {0}   POOL=0 means a FRESH channel per request" -f $TRUE_LEN)
