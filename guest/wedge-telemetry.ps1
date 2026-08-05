# Freeze forensics: sample CPU attribution every 2 s to a file that survives the wedge.
# Run BEFORE a deliberate reproduction; read the tail after recovery. The question it
# answers: when the guest livelocks, is it a KERNEL storm (DPC/interrupt time) or a
# PROCESS (which one) — that decides where the fix lives.
param([string]$Out = 'C:\qubes-idd\wedge-telemetry.log')
$ErrorActionPreference = 'Continue'
"=== telemetry start $(Get-Date -Format o) ===" | Out-File $Out -Append -Encoding ascii
$prev = @{}
while ($true) {
    try {
        $c = Get-Counter '\Processor(_Total)\% DPC Time','\Processor(_Total)\% Interrupt Time','\Processor(_Total)\% Processor Time' -ErrorAction Stop
        $v = $c.CounterSamples | ForEach-Object { '{0:N1}' -f $_.CookedValue }
        $procs = Get-Process | Where-Object { $_.CPU -gt 0 }
        $top = @()
        foreach ($p in $procs) {
            $key = "$($p.Id)"
            $d = if ($prev.ContainsKey($key)) { $p.CPU - $prev[$key] } else { 0 }
            $prev[$key] = $p.CPU
            if ($d -gt 0.1) { $top += "$($p.ProcessName):$('{0:N1}' -f $d)" }
        }
        $topStr = ($top | Sort-Object { [double]($_ -split ':')[1] } -Descending | Select-Object -First 5) -join ' '
        ("{0} cpu={1} dpc={2} intr={3} top: {4}" -f (Get-Date -Format 'HH:mm:ss'), $v[2], $v[0], $v[1], $topStr) |
            Out-File $Out -Append -Encoding ascii
    } catch {
        ("{0} sample-error {1}" -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) | Out-File $Out -Append -Encoding ascii
    }
    Start-Sleep -Seconds 2
}
