# QWT-NG replacement for the stock qubes.VMExec handler. Stock behaviour, plus two fixes:
#
#  1. EXIT CODE PROPAGATION. The stock handler ends on `& cmd.exe /c $cmd` and never exits with
#     the child's status, so every qubes.VMExec call returns 0 to dom0 - measured: a command
#     exiting 100 arrived as 0, while the same command over qubes.VMShell correctly returned 100.
#     dom0 tooling decides success from that status (qubesadmin raises CalledProcessError on it),
#     so on Windows every failure currently reads as success. This is a genuine QWT defect and
#     is worth reporting upstream once the QWT-NG work is submitted.
#
#  2. dom0's `qubes-vm-update` sequence. Its commands are POSIX-shaped (`mkdir -p /run/...`,
#     `/usr/bin/python3 .../entrypoint.py`) and cmd.exe cannot run them - `mkdir -p /run/...`
#     fails outright. Commands naming the updater workdir or entrypoint go to vmupdate-shim.ps1;
#     EVERYTHING ELSE is passed to cmd.exe exactly as before, so generic qvm-run is untouched.
. $env:QUBES_TOOLS\qubes-rpc-services\VMExec-Decode.ps1

try {
    $parts = ($args[0]).split("+")
    $decoded = @($parts.foreach({VMExec-Decode $_}))
} catch [DecodeError] {
    Write-Error $_.Exception.Message
    exit 1
}

$cmd = $decoded -join " "

$shim = Join-Path $env:QUBES_TOOLS 'qubes-rpc-services\vmupdate-shim.ps1'
if ((Test-Path $shim) -and ($cmd -match '/run/qubes-update|\\run\\qubes-update|entrypoint\.py')) {
    & $shim @decoded
    $rc = $LASTEXITCODE
    if ($null -eq $rc) { $rc = 0 }
    exit $rc
}

& cmd.exe /c $cmd
$rc = $LASTEXITCODE
if ($null -eq $rc) { $rc = 0 }
exit $rc
