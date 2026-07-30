# Run a PowerShell script ELEVATED inside the guest and stream its output back.
#
# Why this exists: qrexec (qubes.VMShell / tools/qtest) lands in the interactive console
# session as 'user'. That account is in Administrators, but UAC token filtering hands the
# process a FILTERED token, so anything needing real admin fails - e.g.
#   pnputil /add-driver ... -> "Failed to add driver package: Access is denied."
# There is no way to elevate in-place non-interactively (no consent UI is reachable), and
# from an AppVM qrexec cannot request a non-default user (qvm-run --user is refused, and the
# Windows qrexec-agent ignores a "+SYSTEM" service arg), so we hand the work to a one-shot
# scheduled task that runs AS THE CURRENT USER at HIGHEST run level. A member of
# Administrators may create such a task for himself with no UAC prompt, and Task Scheduler
# runs it with the user's FULL (unfiltered) token. /ru SYSTEM would need admin just to
# create the task -> "Access is denied" -> do NOT use it from the filtered token.
#
# Usage (from the dev qube):
#   tools/qtest push script.ps1 guest/run-elevated.ps1
#   tools/qtest ps "& '<incoming>\run-elevated.ps1' -Script '<incoming>\script.ps1' -Arguments '-Foo bar'"
#
# Output: the child's stdout+stderr, verbatim, followed by "=== ELEVATED EXIT <code> ===".
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [string]$Arguments = '',
    [int]$TimeoutSec = 600,
    [string]$TaskName = 'QubesWinIddElevated'
)
$ErrorActionPreference = 'Continue'

if (-not (Test-Path $Script)) { Write-Output "ERROR: no such script: $Script"; exit 2 }

$stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$log   = "C:\Windows\Temp\elevated-$stamp.log"
$rc    = "C:\Windows\Temp\elevated-$stamp.rc"
$wrap  = "C:\Windows\Temp\elevated-$stamp.ps1"

# The wrapper goes in a FILE, not -EncodedCommand: schtasks caps /tr at 261 characters and
# a base64 payload blows straight past it ("Value for '/tr' option cannot be more than 261
# character(s)"). -File with a short temp path keeps /tr around 100 chars.
$inner = @"
`$ErrorActionPreference = 'Continue'
try {
    & '$Script' $Arguments *>&1 | Out-File -FilePath '$log' -Encoding utf8
    `$code = if (`$LASTEXITCODE -ne `$null) { `$LASTEXITCODE } else { 0 }
} catch {
    `$_ | Out-File -FilePath '$log' -Encoding utf8 -Append
    `$code = 99
}
Set-Content -Path '$rc' -Value `$code
"@
Set-Content -Path $wrap -Value $inner -Encoding UTF8

schtasks /delete /tn $TaskName /f 2>&1 | Out-Null
$tr = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $wrap"
# Runs as the current user at HIGHEST (elevated, unfiltered token); no /ru so no admin
# needed to create. /st is a valid future time only to silence the "earlier than current
# time" warning - schtasks /run fires it immediately regardless.
$st = (Get-Date).AddMinutes(2).ToString('HH:mm')
$create = schtasks /create /tn $TaskName /tr $tr /sc once /st $st /rl HIGHEST /f 2>&1
if ($LASTEXITCODE -ne 0) { Write-Output "ERROR: schtasks create failed: $create"; exit 3 }

schtasks /run /tn $TaskName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output 'ERROR: schtasks run failed'; schtasks /delete /tn $TaskName /f | Out-Null; exit 4 }

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while (-not (Test-Path $rc) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }

if (Test-Path $log) { Get-Content $log }
$code = if (Test-Path $rc) { (Get-Content $rc -Raw).Trim() } else { 'TIMEOUT' }

schtasks /delete /tn $TaskName /f 2>&1 | Out-Null
Remove-Item $log, $rc, $wrap -ErrorAction SilentlyContinue
Write-Output "=== ELEVATED EXIT $code ==="
