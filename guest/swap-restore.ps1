# Argument-free wrapper: restore the .orig (stock) gui-agent.exe, elevated.
# See swap-in.ps1 for why this exists.
$inc = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $inc 'swap-agent.ps1') -Restore
