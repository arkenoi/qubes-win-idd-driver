# Pull incoming input events (HandleMotion/HandleButton) from the newest log, to see whether
# the drag-motion trajectory is being REPLAYED on the wire (daemon re-sending) vs applied once.
param([int]$Tail = 80)
$ErrorActionPreference = 'Continue'
$log = Get-ChildItem 'Q:\Qubes Logs' -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) ==="
Get-Content $log.FullName | Select-String 'HandleMotion|HandleButton|window 0x.*flags 0x|InjectInput|SendInput' |
    Select-Object -Last $Tail | ForEach-Object { $_.Line }
Write-Output '=== END ==='
