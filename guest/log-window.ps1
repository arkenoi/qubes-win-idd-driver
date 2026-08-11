# Dump ALL non-QGAPERF/non-DAMAGE agent log lines within [T0,T1] from the newest log.
param(
    [Parameter(Mandatory=$true)][string]$T0,
    [Parameter(Mandatory=$true)][string]$T1,
    [switch]$IncludeDamage
)
$ErrorActionPreference = 'Continue'
$logdir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) ==="
Get-Content $log.FullName | Where-Object {
    $_ -match '^\[(\d{8}\.\d{6}\.\d{3})' -and $Matches[1] -ge $T0 -and $Matches[1] -le $T1 -and
    $_ -notmatch 'QGAPERF' -and ($IncludeDamage -or $_ -notmatch 'msg=DAMAGE')
} | ForEach-Object { $_ }
Write-Output '=== END ==='
