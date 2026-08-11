# Toastcrop worker diagnostics: every toastcrop-related line in the newest agent log.
$ErrorActionPreference = 'Continue'
$logdir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) ==="
Get-Content $log.FullName | Select-String -Pattern 'TOASTCROP|ToastCrop|TcWorker|TcApply|toast card|no card|ElementFromHandle|CoInitializeEx|worker unavailable|CoCreateInstance' |
    Select-Object -Last 40 | ForEach-Object { $_.Line }
Write-Output '=== END ==='
