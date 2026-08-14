<#
.SYNOPSIS
  A/B the relay's plain-HTTP reliability: pre-allowlist build vs the shipped one.

.DESCRIPTION
  The plain-HTTP path drops and truncates responses, which breaks Windows' certificate trust list
  refresh and therefore the whole update feature. The allowlist commit (61f0bcc, 2026-08-14 09:43)
  touched this relay, so "pre-existing" cannot be asserted without measuring - and today's
  successful 4.8 GB download proves nothing either way, because it used CONNECT, not plain HTTP.

  Interleaved A/B/A/B rather than all-A-then-all-B, because the upstream is shared and its
  behaviour drifts; a block design would confound the build with the time of day. Same URLs, same
  count, same guest.

  Judged on TWO things, since the failure has two shapes:
    * how many requests completed at all, and
    * whether the byte count is CONSTANT - a short body returned as success is the worse bug.
#>
param(
  [string]$PreExe  = 'C:\ProgramData\Qubes\wu\relay-pre.exe',
  [string]$CurExe  = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe',
  [int]$Rounds     = 2,
  [int]$PerRound   = 4
)
$ErrorActionPreference = 'Continue'
$proxy = 'http://127.0.0.1:8082'
$wu    = 'C:\ProgramData\Qubes\wu'
$urls  = [ordered]@{
    'disallowedcertstl' = 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/disallowedcertstl.cab'
    'authrootstl'       = 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab'
}
Write-Output '=== RESULT ==='
foreach ($e in @($PreExe, $CurExe)) { if (-not (Test-Path $e)) { Write-Output "missing: $e"; exit 1 } }

function Stop-Relays { Get-Process qubes-updates-relay, relay-pre -EA SilentlyContinue | ForEach-Object { $_.Kill() }; Start-Sleep -Seconds 2 }
function Start-Relay($exe) {
    Stop-Relays
    Start-Process -FilePath $exe -ArgumentList '--listen','8082','--target','@default','--log',$wu -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

$stats = @{}
foreach ($b in 'PRE','CUR') { foreach ($u in $urls.Keys) { $stats["$b|$u"] = [ordered]@{ ok=0; fail=0; sizes=New-Object 'System.Collections.Generic.HashSet[int]' } } }

for ($r = 1; $r -le $Rounds; $r++) {
    foreach ($build in 'PRE','CUR') {
        Start-Relay $(if ($build -eq 'PRE') { $PreExe } else { $CurExe })
        foreach ($name in $urls.Keys) {
            for ($i = 1; $i -le $PerRound; $i++) {
                try {
                    $resp = Invoke-WebRequest $urls[$name] -Proxy $proxy -UseBasicParsing -TimeoutSec 40
                    $stats["$build|$name"].ok++
                    [void]$stats["$build|$name"].sizes.Add([int]$resp.RawContentLength)
                } catch { $stats["$build|$name"].fail++ }
                Start-Sleep -Milliseconds 600
            }
        }
    }
}
Stop-Relays

foreach ($build in 'PRE','CUR') {
    foreach ($name in $urls.Keys) {
        $s = $stats["$build|$name"]
        $sz = if ($s.sizes.Count) { ($s.sizes | Sort-Object) -join ',' } else { 'n/a' }
        $stable = if ($s.sizes.Count -le 1) { 'constant' } else { 'VARYING(truncation)' }
        Write-Output ("{0}  {1,-18} ok={2,-3} fail={3,-3} sizes={4}  {5}" -f $build, $name, $s.ok, $s.fail, $sz, $stable)
    }
}
Write-Output 'PRE = build before the allowlist commit; CUR = shipped build'
