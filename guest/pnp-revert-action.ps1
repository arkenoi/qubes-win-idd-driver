# Boot-time PnP revert action (experiment 7 / exp 9 safety net, PLAN-trackb-t2-modes.md §2.4).
# Runs as SYSTEM at every boot via the QubesIddPnpRevert scheduled task. If a revert request
# marker exists, re-ENABLES the PnP device whose instance id is in the marker, records the
# devcon exit code, and clears the request ONLY on verified success.
#
# Deliberately does NOT touch SetDisplayConfig: a SYSTEM task in session 0 cannot repair
# session 1's desktop topology (documented ERROR_ACCESS_DENIED) — only the PnP re-enable is
# load-bearing, so only it is implemented and only it is measured.
$ErrorActionPreference = 'Continue'
$dir = 'C:\qubes-idd'
$req = Join-Path $dir 'revert-request.txt'
$res = Join-Path $dir 'revert-result.txt'
$devcon = Join-Path $dir 'devcon.exe'

if (-not (Test-Path $req)) { exit 0 }
$id = (Get-Content $req -TotalCount 1).Trim()
if (-not $id) {
    "when=$(Get-Date -Format o) status=FAIL reason=empty_request" | Out-File $res -Append
    exit 1
}
if (-not (Test-Path $devcon)) {
    "when=$(Get-Date -Format o) status=FAIL reason=devcon_missing id=$id" | Out-File $res -Append
    exit 1
}

$out = & $devcon enable "@$id" 2>&1
$code = $LASTEXITCODE

# Verify by status readback, not just the exit code: devcon can exit 0 without the device
# actually running. The check must be able to fail.
$status = (& $devcon status "@$id" 2>&1) -join ' | '
$running = $status -match 'Driver is running|started'

"when=$(Get-Date -Format o) id=$id devcon_exit=$code running=$running status=$status" | Out-File $res -Append
if ($code -eq 0 -and $running) { Remove-Item $req -Force }
