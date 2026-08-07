# Report the installed gui-agent hash and whether it is running.
# A pushed SCRIPT, not a quoted one-liner: qtest wraps commands in
# powershell -Command "..." via cmd, so inner double quotes (needed for
# "C:\Program Files\...") are mangled and the command silently returns nothing.
$p = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
if (Test-Path -LiteralPath $p) {
    Write-Output ("AGENTHASH=" + (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.Substring(0,16))
} else {
    Write-Output "AGENTHASH=ABSENT"
}
if (Get-Process gui-agent -ErrorAction SilentlyContinue) {
    Write-Output "AGENTPROC=ALIVE"
} else {
    Write-Output "AGENTPROC=DEAD"
}
