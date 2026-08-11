# Report whether THIS process holds a full (unfiltered) admin token. Output is marker-
# delimited so the caller parses only after === RESULT === and is never fooled by the
# qrexec command echo (which contains any literal we might grep for).
$ErrorActionPreference = 'Continue'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
$elevated = $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
Write-Output '=== RESULT ==='
Write-Output ("TOKEN=" + $(if ($elevated) { 'ELEVATED' } else { 'FILTERED' }))
