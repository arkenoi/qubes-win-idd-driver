# Is the RUNNING process actually the binary we deployed? A file hash proves only what is on
# disk; a stale process keeps executing the OLD image. Compares the running process's own
# image path + hash + start time against the file, and lists every gui-agent instance.
$ErrorActionPreference = 'Continue'
$bin = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
$r = [ordered]@{}
$r.file_path = $bin
$r.file_sha256 = (Get-FileHash $bin -Algorithm SHA256).Hash.Substring(0,16)
$r.file_written = (Get-Item $bin).LastWriteTime.ToString('HH:mm:ss')
$procs = @(Get-Process gui-agent -ErrorAction SilentlyContinue)
$r.instances = $procs.Count
$r.procs = @($procs | ForEach-Object {
    $p = $_
    $path = try { $p.Path } catch { 'ACCESS_DENIED' }
    $imgHash = if ($path -and $path -ne 'ACCESS_DENIED' -and (Test-Path $path)) {
        (Get-FileHash $path -Algorithm SHA256).Hash.Substring(0,16) } else { 'n/a' }
    [ordered]@{
        pid = $p.Id
        start = $p.StartTime.ToString('HH:mm:ss')
        path = $path
        image_sha256 = $imgHash
        started_after_file_write = ($p.StartTime -gt (Get-Item $bin).LastWriteTime)
    }
})
# the watchdog service that respawns it, and any leftover .orig
$r.watchdog = (Get-Service QubesGuiWatchdog -ErrorAction SilentlyContinue).Status.ToString()
$r.orig_present = Test-Path "$bin.orig"
$r.newest_log = (Get-ChildItem 'Q:\Qubes Logs' -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).Name
# does the running agent's log show the NEW code paths?
$log = Get-ChildItem 'Q:\Qubes Logs' -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$r.log_has_blockwin = [bool](Get-Content $log.FullName | Select-String 'QGABLOCKWIN' -Quiet)
$r.log_has_shellpolicy = [bool](Get-Content $log.FullName | Select-String 'QGASHELLMANAGED policy=' -Quiet)
Write-Output '=== RESULT ==='
$r | ConvertTo-Json -Depth 4
