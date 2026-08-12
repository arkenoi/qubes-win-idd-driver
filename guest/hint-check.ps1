# Confirm the size-lock hint (PMinSize|PMaxSize) is being sent for the WM-managed shell
# surfaces, and dump their MAP lines (ovr should be 0 = draggable).
$ErrorActionPreference = 'Continue'
$logdir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$c = Get-Content $log.FullName
Write-Output "=== LOG $($log.Name) ==="
Write-Output "--- sizelock hints sent:"
$c | Select-String -SimpleMatch 'sizelock' | Select-Object -Last 6 | ForEach-Object { $_.Line }
Write-Output "--- MSG_WINDOW_HINTS (all):"
$c | Select-String 'MSG_WINDOW_HINTS' | Select-Object -Last 6 | ForEach-Object { $_.Line }
Write-Output "--- shell-surface MAP lines (ovr should be 0):"
$c | Select-String 'msg=MAP.*ovr=0' | Select-Object -Last 6 | ForEach-Object { $_.Line }
Write-Output '=== END ==='
