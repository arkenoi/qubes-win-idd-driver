# a0-kill-relay.ps1 — kill the toast-bridge's --relay child (the qrexec/vchan splice) without
# touching the resident --bridge, to prove the bridge notices the dropped connection, restores
# banners, and auto-reconnects. Run as the user (the relay lives in the user session).
$ErrorActionPreference = 'Continue'
$n = 0
Get-CimInstance Win32_Process -Filter "Name='notifhost.exe'" |
    Where-Object { $_.CommandLine -match '--relay' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue; $n++ }
Write-Output ("KILLED-RELAY=" + $n)
