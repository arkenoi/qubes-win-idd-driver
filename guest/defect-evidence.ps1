# Evidence probe for the 2026-08-11 live defects (drag regression, overlap/re-announce).
# Read-only: agent PID/uptime, binary hash, log inventory, and grep of the newest log for
# send errors, sanitizer drops, re-announce triggers, and QGAPERF lines.
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}

$p = Get-Process gui-agent -ErrorAction SilentlyContinue
$r.agent_pid = if ($p) { $p.Id } else { $null }
$r.agent_start = if ($p) { $p.StartTime.ToString('o') } else { $null }
$r.now = (Get-Date).ToString('o')

$bin = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
$r.bin_sha256 = (Get-FileHash $bin -Algorithm SHA256).Hash
$r.bin_mtime = (Get-Item $bin).LastWriteTime.ToString('o')

$logdir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$r.logdir = $logdir
$logs = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime
$r.log_count = $logs.Count
$r.newest_log = $logs[-1].Name
$r.newest_log_size = $logs[-1].Length

$tail = Get-Content $logs[-1].FullName -Tail 4000
$r.tail_lines = $tail.Count

# Patterns of interest
$pats = [ordered]@{
    send_err   = 'VchanSend.*(fail|error|timeout)|send.*timeout|ring.*(full|stall)'
    sanitizer  = 'saniti|clamp|drop.*(configure|geometry)|WireSan'
    reannounce = 'WINDOW_DUMP|re-?announce|ResetWatch|full.*re-?enum|RecreateDuplication|keyed mutex|887a0026'
    destroyall = 'DestroyAll|destroy.*all|reconnect'
    qgaperf    = 'QGAPERF'
    toastcrop  = 'TOASTCROP|TcFind|crop'
    errors     = 'ERROR|failed|0x8|c0000005'
}
foreach ($k in $pats.Keys) {
    $m = $tail | Select-String -Pattern $pats[$k]
    $r["${k}_count"] = ($m | Measure-Object).Count
    $r["${k}_last"] = @($m | Select-Object -Last 8 | ForEach-Object { $_.Line })
}

# Last 10 QGAPERF lines verbatim for the perf picture
$r.qgaperf_tail = @($tail | Select-String 'QGAPERF' | Select-Object -Last 10 | ForEach-Object { $_.Line })

Write-Output '=== RESULT ==='
$r | ConvertTo-Json -Depth 4
