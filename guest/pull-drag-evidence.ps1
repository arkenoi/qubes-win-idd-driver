# Pull everything relevant to a drag from the newest agent log: outbound CONFIGURE trace,
# inbound HandleConfigure, buttons, motion, rate-limit flushes. Full lines, large tail.
param([int]$Tail = 3000)
$ErrorActionPreference = 'Continue'
$log = Get-ChildItem 'Q:\Qubes Logs' -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) size=$($log.Length) ==="
Get-Content $log.FullName | Select-String 'msg=CONFIGURE|HandleConfigure|HandleButton|HandleMotion|PendingMove|Flush|drag|MOTION' |
    Select-Object -Last $Tail | ForEach-Object { $_.Line }
Write-Output '=== END ==='
