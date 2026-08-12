# Pull the last N MSG_CONFIGURE + DAMAGE-wobble lines from the newest agent log, to see the
# post-drag position echo. Non-DAMAGE proto lines only (CONFIGURE/MAP/CREATE), most recent.
param([int]$Tail = 120)
$ErrorActionPreference = 'Continue'
$log = Get-ChildItem 'Q:\Qubes Logs' -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) ==="
Get-Content $log.FullName | Select-String 'msg=CONFIGURE|HandleConfigure|Updating position|cropped.*applied' |
    Select-Object -Last $Tail | ForEach-Object { $_.Line }
Write-Output '=== END ==='
