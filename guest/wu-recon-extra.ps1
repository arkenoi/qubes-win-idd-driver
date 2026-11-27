# Recon supplement: explicit KB5121003 check, updater log tail, relay log size/line count.
$ErrorActionPreference = 'Continue'
# THE ONE LOG DIRECTORY (docs/ADR-logging.md, Decision 2026-11-01), asked of the installed log.ps1's Get-QwtLogDir
# (the one rule: the registry LogDir, else Q:\Qubes Logs, else <SystemDrive>\Qubes Logs). A moved log is its per-day files there,
# <module>-<yyyyMMdd>.log, newest last; only a guest with none of them reads the file at its old path.
function Get-MovedLogFiles([string]$Module, [string]$Old) {
    # the log directory by the one rule (docs/ADR-logging.md 1), asked of the installed log.ps1
    $d = & { . 'C:\Program Files\Qubes Tools\bin\log.ps1'; Get-QwtLogDir }
    $rx = '^' + [regex]::Escape($Module) + '-\d{8}\.log$'
    $f = @(Get-ChildItem -LiteralPath $d -Filter "$Module-*.log" -File -EA SilentlyContinue | Where-Object { $_.Name -match $rx } | Sort-Object Name | ForEach-Object { $_.FullName })
    if ($f.Count -eq 0 -and $Old -and (Test-Path -LiteralPath $Old)) { $f = @($Old) }
    $f
}
Write-Output '=== KB5121003 ==='
$hf = Get-HotFix -Id KB5121003 -EA SilentlyContinue
if ($hf) { Write-Output ("INSTALLED " + $hf.InstalledOn) } else { Write-Output 'NOT-IN-GET-HOTFIX' }
# also check WU history for it (Get-HotFix misses some servicing entries)
try {
    $s = New-Object -ComObject Microsoft.Update.Session
    $searcher = $s.CreateUpdateSearcher()
    $n = $searcher.GetTotalHistoryCount()
    $hist = $searcher.QueryHistory(0, [Math]::Min($n, 25))
    foreach ($h in $hist) {
        Write-Output ("HIST rc=" + $h.ResultCode + " op=" + $h.Operation + " date=" + $h.Date + " title=[" + $h.Title + "]")
    }
} catch { Write-Output ("HIST-ERR " + $_.Exception.Message) }
# Both logs are per-day files now: size and lines over every file, mtime of the newest, tails across them.
Write-Output '=== updater log tail ==='
$al = @(Get-MovedLogFiles 'qubes-windows-update.ps1' 'C:\ProgramData\Qubes\wu\agent.log')
if ($al.Count) {
    $fis = @($al | ForEach-Object { Get-Item -LiteralPath $_ })
    Write-Output ("files=" + $fis.Count + " size=" + ($fis | Measure-Object -Property Length -Sum).Sum + " mtime=" + $fis[-1].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    @(foreach ($p in $al) { Get-Content -LiteralPath $p -Tail 40 }) | Select-Object -Last 40
} else { Write-Output 'NO updater log' }
Write-Output '=== relay log status ==='
$rl = @(Get-MovedLogFiles 'qubes-updates-relay' 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log')
if ($rl.Count) {
    $fis = @($rl | ForEach-Object { Get-Item -LiteralPath $_ })
    $lines = (Get-Content -LiteralPath $rl | Measure-Object -Line).Lines
    Write-Output ("files=" + $fis.Count + " size=" + ($fis | Measure-Object -Property Length -Sum).Sum + " lines=" + $lines + " mtime=" + $fis[-1].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Output '--- last 5 lines ---'
    @(foreach ($p in $rl) { Get-Content -LiteralPath $p -Tail 5 }) | Select-Object -Last 5
} else { Write-Output 'NO relay log' }
Write-Output '=== relay process ==='
Get-Process | Where-Object { $_.ProcessName -match 'qubes-updates-relay' } |
    ForEach-Object { Write-Output ("PROC " + $_.ProcessName + " pid=" + $_.Id + " start=" + $_.StartTime.ToString('yyyy-MM-dd HH:mm:ss')) }
Write-Output '=== guest clock ==='
Write-Output ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'))
Write-Output '=== DONE ==='
