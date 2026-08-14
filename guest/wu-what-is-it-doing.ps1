# What is the guest ACTUALLY doing right now? Judge work by the processes doing it and by CBS's
# own running commentary, not by the absence of a result line - a servicing pass that has gone
# nowhere and one that is halfway through a WIM look identical from outside.
$ErrorActionPreference = 'Continue'
Write-Output '=== RESULT ==='
Write-Output ("uptime_min = {0:N0}" -f ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMinutes)

# Top CPU consumers, with the servicing suspects called out by name.
Write-Output '--- top 12 by CPU seconds ---'
Get-Process | Sort-Object CPU -Descending | Select-Object -First 12 |
  ForEach-Object { Write-Output ("{0,-24} pid={1,-7} cpu_s={2,8:N1} ws_mb={3,7:N0}" -f $_.ProcessName, $_.Id, $_.CPU, ($_.WorkingSet64/1MB)) }

Write-Output '--- servicing processes ---'
foreach ($n in 'TiWorker','TrustedInstaller','Dism','DismHost','wuauclt','MoUsoCoreWorker','msiexec','poqexec','CompatTelRunner') {
    $p = @(Get-Process $n -EA SilentlyContinue)
    if ($p.Count) { foreach ($q in $p) { Write-Output ("{0,-18} pid={1,-7} cpu_s={2,8:N1} ws_mb={3,7:N0}" -f $q.ProcessName, $q.Id, $q.CPU, ($q.WorkingSet64/1MB)) } }
    else { Write-Output ("{0,-18} not running" -f $n) }
}

# Disk pressure: servicing is I/O bound, so bytes moved is the honest progress signal.
$os = Get-CimInstance Win32_OperatingSystem
Write-Output ("free_mb = {0:N0} of {1:N0}" -f ($os.FreePhysicalMemory/1KB), ($os.TotalVisibleMemorySize/1KB))
$d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
Write-Output ("disk_free_gb = {0:N1} of {1:N1}" -f ($d.FreeSpace/1GB), ($d.Size/1GB))

# CBS's live narration - the authoritative answer to "what phase is it in".
$cbslog = 'C:\Windows\Logs\CBS\CBS.log'
if (Test-Path $cbslog) {
    $f = Get-Item $cbslog
    Write-Output ("--- CBS.log (last written {0}, {1:N1} MB) ---" -f $f.LastWriteTime.ToString('HH:mm:ss'), ($f.Length/1MB))
    Get-Content $cbslog -Tail 12 -EA SilentlyContinue | ForEach-Object { Write-Output ("   " + $_.Trim()) }
}
$dismlog = 'C:\ProgramData\Qubes\wu\dism-KB5121003.log'
foreach ($cand in @($dismlog, 'C:\Windows\Logs\DISM\dism.log')) {
    if (Test-Path $cand) {
        $f = Get-Item $cand
        Write-Output ("--- {0} (last written {1}) ---" -f $f.Name, $f.LastWriteTime.ToString('HH:mm:ss'))
        Get-Content $cand -Tail 5 -EA SilentlyContinue | ForEach-Object { Write-Output ("   " + $_.Trim()) }
        break
    }
}
