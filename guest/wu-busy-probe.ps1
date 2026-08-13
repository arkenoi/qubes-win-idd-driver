# Who burns CPU while the update downloads? Distinguishes "the network is slow" from "the guest
# is busy between requests" - the two remaining explanations for the ~4 s pause between bursts.
$ErrorActionPreference = 'Continue'
$before = @{}
foreach ($p in Get-Process) { if ($p.CPU) { $before[$p.Id] = $p.CPU } }
$diskBefore = (Get-Counter '\PhysicalDisk(_Total)\Disk Bytes/sec' -EA SilentlyContinue).CounterSamples[0].CookedValue
Start-Sleep -Seconds 8
$rows = @()
foreach ($p in Get-Process) {
    if ($p.CPU -and $before.ContainsKey($p.Id)) {
        $d = $p.CPU - $before[$p.Id]
        if ($d -gt 0.2) { $rows += [pscustomobject]@{ Name = $p.Name; CpuSec = [math]::Round($d, 1) } }
    }
}
Write-Output '=== RESULT ==='
Write-Output ("window_sec=8  cores=" + $env:NUMBER_OF_PROCESSORS)
foreach ($r in ($rows | Sort-Object CpuSec -Descending | Select-Object -First 8)) {
    Write-Output ("  " + $r.Name + "  cpu_sec=" + $r.CpuSec)
}
if (-not $rows) { Write-Output '  (no process used more than 0.2 s of CPU - the guest is IDLE while downloading)' }
$diskAfter = (Get-Counter '\PhysicalDisk(_Total)\Disk Bytes/sec' -EA SilentlyContinue).CounterSamples[0].CookedValue
Write-Output ("disk_bytes_per_sec_sample=" + [math]::Round($diskAfter))
