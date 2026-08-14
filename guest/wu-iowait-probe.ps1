# Is the guest WAITING on disk, or on a timer? The CPU probe showed ~28% utilisation with no
# thread pegged, so the ~4 s pauses between download bursts are not compute. These counters
# separate the two remaining explanations:
#   - high Avg. Disk sec/Write or a standing queue  -> storage is the limiter
#   - idle disk AND idle CPU during the pause       -> a scheduler/timer inside BITS/DO, which
#                                                      no transport tuning of ours will move
$ErrorActionPreference = 'Continue'
$paths = @(
    '\PhysicalDisk(_Total)\Avg. Disk sec/Write',
    '\PhysicalDisk(_Total)\Avg. Disk sec/Read',
    '\PhysicalDisk(_Total)\Current Disk Queue Length',
    '\PhysicalDisk(_Total)\Disk Bytes/sec',
    '\Processor(_Total)\% Processor Time',
    '\Processor(_Total)\% Idle Time'
)
# WITNESS. Without this the probe cannot fail: sampling an IDLE guest yields "disk idle AND CPU
# idle", which reads exactly like the timer/scheduler verdict while actually meaning "no download
# was running". Record proof that bytes moved DURING the sampling window, or refuse to conclude.
$relayLog = 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log'
$dlDir    = 'C:\Windows\SoftwareDistribution\Download'
function Witness {
  $rl = 0; if (Test-Path -LiteralPath $relayLog) { $rl = (Get-Item -LiteralPath $relayLog).Length }
  $dl = 0
  try { $dl = (Get-ChildItem -LiteralPath $dlDir -Recurse -File -ErrorAction SilentlyContinue |
               Measure-Object -Property Length -Sum).Sum } catch { $dl = -1 }
  if (-not $dl) { $dl = 0 }
  return @{ relay = [long]$rl; down = [long]$dl }
}
$w0 = Witness

$samples = Get-Counter -Counter $paths -SampleInterval 1 -MaxSamples 12 -ErrorAction SilentlyContinue
if (-not $samples) { Write-Output 'counters unavailable'; exit 1 }

$w1 = Witness
$relayGrew = $w1.relay - $w0.relay
$downGrew  = $w1.down  - $w0.down
Write-Output '=== WITNESS (was a download actually in flight while we sampled?) ==='
Write-Output ("relay_log_growth_bytes = {0}" -f $relayGrew)
Write-Output ("download_dir_growth_bytes = {0}   (before={1} after={2})" -f $downGrew, $w0.down, $w1.down)
$active = ($relayGrew -gt 0) -or ($downGrew -gt 0)
Write-Output ("download_active_during_sample = {0}" -f $active)
if (-not $active) {
  Write-Output 'VERDICT UNAVAILABLE: nothing was downloading during the 12 s window.'
  Write-Output 'Idle counters here mean IDLE GUEST, not "BITS/DO timer". Re-run during an active pass.'
}

$agg = @{}
foreach ($s in $samples) {
    foreach ($c in $s.CounterSamples) {
        $k = ($c.Path -split '\\')[-1]
        if (-not $agg.ContainsKey($k)) { $agg[$k] = @() }
        $agg[$k] += $c.CookedValue
    }
}
Write-Output '=== RESULT ==='
foreach ($k in $agg.Keys | Sort-Object) {
    $v = $agg[$k] | Sort-Object
    $avg = ($agg[$k] | Measure-Object -Average).Average
    Write-Output ("{0,-30} avg={1,10:N3}  max={2,10:N3}" -f $k, $avg, $v[-1])
}
