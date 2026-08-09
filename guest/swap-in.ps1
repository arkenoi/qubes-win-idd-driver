# Argument-free wrapper: swap the pushed gui-agent.exe in, elevated.
# Exists because passing -Arguments "-NewAgent '<path>'" through qtest ps -> cmd ->
# powershell collapses the nested quotes and the path binds to -TimeoutSec. A wrapper
# with everything hardcoded has nothing to quote.
$inc = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $inc 'swap-agent.ps1') -NewAgent (Join-Path $inc 'gui-agent.exe')
