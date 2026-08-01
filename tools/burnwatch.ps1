# Per-interval CPU/service/PnP recorder for the live netvm-attach experiment.
# Started BEFORE the attach (survives qrexec death; writes+flushes to C:\burnwatch.log).
# Stop: create C:\burnwatch.stop or let -MaxMinutes elapse.
param([int]$IntervalSec = 5, [int]$MaxMinutes = 30)
$log = 'C:\burnwatch.log'
$prev = @{}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Add-Content $log "=== BURNWATCH start $(Get-Date -Format o) interval=${IntervalSec}s ==="
while ($sw.Elapsed.TotalMinutes -lt $MaxMinutes -and -not (Test-Path 'C:\burnwatch.stop')) {
    $t = Get-Date -Format 'HH:mm:ss'
    $lines = @()
    # per-process CPU deltas over the interval (catches the burner by name)
    $procs = Get-Process | Where-Object { $_.Id -ne 0 }
    $cur = @{}
    foreach ($p in $procs) { try { $cur[$p.Id] = @($p.ProcessName, $p.TotalProcessorTime.TotalSeconds) } catch {} }
    $deltas = foreach ($id in $cur.Keys) {
        if ($prev.ContainsKey($id)) {
            $d = $cur[$id][1] - $prev[$id][1]
            if ($d -gt 0.2) { [pscustomobject]@{n=$cur[$id][0]; id=$id; d=[math]::Round($d,2)} }
        }
    }
    $top = ($deltas | Sort-Object d -Descending | Select-Object -First 6 |
        ForEach-Object { "$($_.n):$($_.id)=$($_.d)s" }) -join ' '
    $prev = $cur
    # DPC/interrupt time — a burner PnP can hide in the kernel, not a process
    try {
        $k = Get-Counter '\Processor(_Total)\% Interrupt Time','\Processor(_Total)\% DPC Time','\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
        $kv = ($k.CounterSamples | ForEach-Object { "$($_.Path -replace '.*\\','')=$([math]::Round($_.CookedValue,1))" }) -join ' '
    } catch { $kv = 'counters-unavailable' }
    $svc = (Get-Service xenvif,xennet -ErrorAction SilentlyContinue |
        ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ' '
    $vif = if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Enum\XENVIF') { 'ENUMVIF=yes' } else { 'ENUMVIF=no' }
    $nics = try { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\XEN\Unplug' -ErrorAction Stop).NICS } catch { 'absent' }
    Add-Content $log "T $t cpu[$top] kern[$kv] $svc $vif NICS=$nics"
    Start-Sleep -Seconds $IntervalSec
}
Add-Content $log "=== BURNWATCH end $(Get-Date -Format o) ==="
