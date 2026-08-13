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
$samples = Get-Counter -Counter $paths -SampleInterval 1 -MaxSamples 12 -ErrorAction SilentlyContinue
if (-not $samples) { Write-Output 'counters unavailable'; exit 1 }

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
