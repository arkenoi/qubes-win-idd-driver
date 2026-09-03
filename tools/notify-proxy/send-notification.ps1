# send-notification.ps1 — compile (in-box csc, if needed) and send one dom0 notification
# through the EXISTING qubes.Notifications service. See README.md in this directory.
#
# Run inside the Windows guest, e.g.:
#   powershell -ExecutionPolicy Bypass -File send-notification.ps1 -Summary "hello" -Body "from windows"
#
# Requires a logged-on interactive session (the qrexec local handler is spawned there).
param(
    [Parameter(Mandatory=$true)][string]$Summary,
    [string]$Body = '',
    [string]$BodyFile = '',        # UTF-8 file: first line = summary, rest = body (overrides -Summary/-Body)
    [string]$User = '',            # local account for the handler; default: NotifyClient's own resolution
    [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here 'NotifyClient.cs'
$exe  = Join-Path $here 'NotifyClient.exe'

# Compile with the in-box csc (C# 5), same pattern as guest/deploy-relay-fix.ps1.
if (-not (Test-Path $exe) -or ((Get-Item $src).LastWriteTime -gt (Get-Item $exe).LastWriteTime)) {
    $csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework64\v4.0.*\csc.exe' -EA SilentlyContinue | Select-Object -First 1
    if (-not $csc) { $csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework\v4.0.*\csc.exe' -EA SilentlyContinue | Select-Object -First 1 }
    if (-not $csc) { throw 'no in-box csc.exe found' }
    & $csc.FullName /nologo /o /target:exe "/out:$exe" "$src" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
}

if ($BodyFile) {
    $argv = @('--send-file', $BodyFile)
} else {
    $argv = @('--send', $Summary)
    if ($Body) { $argv += $Body }
}
if ($User) { $argv += @('--user', $User) }
$argv += @('--timeout', "$TimeoutSec")

& $exe @argv
exit $LASTEXITCODE
