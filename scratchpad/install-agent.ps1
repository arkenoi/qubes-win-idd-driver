# Install one side's gui-agent build, ready for a cold boot to pick it up.
#
# The agent MUST be stopped first: Windows locks a running image, so Copy-Item -Force over
# a live gui-agent.exe fails, and without an error check the harness then measures the
# PREVIOUS build believing it is the new one. Stopping the watchdog costs the gui-daemon,
# but the caller reboots straight after, which restores it.
param([string]$Which = 'new')

$ErrorActionPreference = 'Stop'
$bin      = 'C:\Program Files\Qubes Tools\bin'
$incoming = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$target   = Join-Path $bin 'gui-agent.exe'

$src    = if ($Which -eq 'orig') { Join-Path $bin 'gui-agent.exe.orig' } else { Join-Path $incoming 'gui-agent.exe' }
$expect = if ($Which -eq 'orig') { '4B4CE2B1C5441C88' } else { '4DA9FE967A8A1012' }

if (-not (Test-Path $src)) { Write-Output "INSTALL=FAIL reason=missing_source"; exit 1 }

Stop-Service QubesGuiWatchdog -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

try {
    Copy-Item $src $target -Force -ErrorAction Stop
} catch {
    Write-Output ("INSTALL=FAIL reason=copy_failed msg=" + $_.Exception.Message)
    exit 1
}

$h = (Get-FileHash $target).Hash.Substring(0,16)
if ($h -ne $expect) { Write-Output "INSTALL=FAIL reason=hash_mismatch got=$h want=$expect"; exit 1 }
Write-Output "INSTALL=OK which=$Which hash=$h"
