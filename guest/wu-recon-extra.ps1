# Recon supplement: explicit KB5121003 check, agent.log tail, relay log size/line count.
$ErrorActionPreference = 'Continue'
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
Write-Output '=== agent.log tail ==='
$al = 'C:\ProgramData\Qubes\wu\agent.log'
if (Test-Path $al) {
    $fi = Get-Item $al
    Write-Output ("size=" + $fi.Length + " mtime=" + $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    Get-Content -LiteralPath $al -Tail 40
} else { Write-Output 'NO agent.log' }
Write-Output '=== relay log status ==='
$rl = 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log'
if (Test-Path $rl) {
    $fi = Get-Item $rl
    $lines = (Get-Content -LiteralPath $rl | Measure-Object -Line).Lines
    Write-Output ("size=" + $fi.Length + " lines=" + $lines + " mtime=" + $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Output '--- last 5 lines ---'
    Get-Content -LiteralPath $rl -Tail 5
} else { Write-Output 'NO relay log' }
Write-Output '=== relay process ==='
Get-Process | Where-Object { $_.ProcessName -match 'qubes-updates-relay' } |
    ForEach-Object { Write-Output ("PROC " + $_.ProcessName + " pid=" + $_.Id + " start=" + $_.StartTime.ToString('yyyy-MM-dd HH:mm:ss')) }
Write-Output '=== guest clock ==='
Write-Output ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'))
Write-Output '=== DONE ==='
