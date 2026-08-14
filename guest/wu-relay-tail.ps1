# Emit the last N lines of the relay log (default 600) for host-side gap analysis.
param([int]$Tail = 600)
$ErrorActionPreference = 'Continue'
$rl = 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log'
if (-not (Test-Path $rl)) { Write-Output 'NO relay log'; exit 1 }
$fi = Get-Item $rl
Write-Output ("=== RELAYLOG size=" + $fi.Length + " mtime=" + $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + " now=" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') + " ===")
Get-Content -LiteralPath $rl -Tail $Tail
Write-Output '=== END RELAYLOG ==='
