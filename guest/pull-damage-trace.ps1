# Pull msg=DAMAGE trace lines (wobble probe: announced ax/ay vs live lx/ly) from the newest log.
param([int]$Tail = 2500)
$ErrorActionPreference = 'Continue'
$log = Get-ChildItem 'Q:\Qubes Logs' -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) ==="
Get-Content $log.FullName | Select-String 'msg=DAMAGE' | Select-Object -Last $Tail | ForEach-Object { $_.Line }
Write-Output '=== END ==='
