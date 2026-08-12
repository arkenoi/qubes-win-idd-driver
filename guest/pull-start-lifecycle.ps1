# Everything about shell surfaces / managed Start in the newest log: crop, WM-managed flip,
# capture path (Pw attach / slice-fed), CREATE/CONFIGURE/DESTROY, and any console-window
# CREATEs (powershell/conhost). Also dumps the last N generic CREATE lines to spot the
# "two terminal windows".
param([int]$Tail = 120)
$ErrorActionPreference = 'Continue'
$log = Get-ChildItem 'Q:\Qubes Logs' -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) ==="
Write-Output '--- shell/start/capture ---'
Get-Content $log.FullName | Select-String 'WM-managed|kind=|cropped|PwAttach|PwDetach|slice|Slice|StartMenu|HINTS|toastcrop|TcFindCard|no card' |
    Select-Object -Last $Tail | ForEach-Object { $_.Line }
Write-Output '--- recent CREATE/DESTROY ---'
Get-Content $log.FullName | Select-String 'msg=CREATE|msg=DESTROY|Unmapping' |
    Select-Object -Last 40 | ForEach-Object { $_.Line }
Write-Output '=== END ==='
