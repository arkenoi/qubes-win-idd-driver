# a0-dump-center.ps1 — list the CURRENT user's Notification Center toasts via notifhost
# --dump-aumids (run through run-as-user.ps1 -Script). Wraps the exe call so no spaced,
# quoted command line has to survive the qtest->cmd->powershell hops.
$exe = 'C:\Program Files\Qubes Tools\bin\notifhost.exe'
if (-not (Test-Path $exe)) { Write-Output 'DUMP-ERR notifhost.exe missing'; exit 1 }
& $exe --dump-aumids
