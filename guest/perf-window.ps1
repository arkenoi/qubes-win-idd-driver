# Extract QGAPERF lines from the newest agent log within [T0,T1] (yyyyMMdd.HHmmss.fff,
# matching the log's own timestamp prefix) and print them raw for dev-side stats.
param(
    [Parameter(Mandatory=$true)][string]$T0,
    [Parameter(Mandatory=$true)][string]$T1
)
$ErrorActionPreference = 'Continue'
$logdir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) ==="
Get-Content $log.FullName | Where-Object {
    $_ -match '^\[(\d{8}\.\d{6}\.\d{3})' -and $Matches[1] -ge $T0 -and $Matches[1] -le $T1 -and $_ -match 'QGAPERF'
} | ForEach-Object { $_ }
Write-Output '=== END ==='
