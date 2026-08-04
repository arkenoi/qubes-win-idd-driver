# Install one side's gui-agent build by explicit source file + expected hash, ready for a
# cold boot to pick it up. Generalises install-agent.ps1, which only knew "orig" and "new";
# the 66fc670 A/B needs a THIRD binary (agent aaa8c37, the pre-fix control), because stock
# QWT has no composite synthesis and cannot exhibit that defect at all.
#
# The agent must be stopped before copying: Windows locks a running image, so Copy-Item
# -Force over a live gui-agent.exe fails and, unchecked, leaves the PREVIOUS build in place
# while the harness reports success. Stopping the watchdog costs gui-daemon, but the caller
# reboots straight after, which restores it.
param(
  [Parameter(Mandatory=$true)][string]$SrcName,   # file name in QubesIncoming, or 'ORIG'
  [Parameter(Mandatory=$true)][string]$ExpectHash # first 16 hex chars of SHA256
)

$ErrorActionPreference = 'Stop'
$bin      = 'C:\Program Files\Qubes Tools\bin'
$incoming = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$target   = Join-Path $bin 'gui-agent.exe'
$src      = if ($SrcName -eq 'ORIG') { Join-Path $bin 'gui-agent.exe.orig' } else { Join-Path $incoming $SrcName }

if (-not (Test-Path $src)) { Write-Output "INSTALL=FAIL reason=missing_source src=$SrcName"; exit 1 }

$srcHash = (Get-FileHash $src).Hash.Substring(0,16)
if ($srcHash -ne $ExpectHash) {
  Write-Output "INSTALL=FAIL reason=source_hash_mismatch src=$SrcName got=$srcHash want=$ExpectHash"; exit 1
}

Stop-Service QubesGuiWatchdog -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

try { Copy-Item $src $target -Force -ErrorAction Stop }
catch { Write-Output ("INSTALL=FAIL reason=copy_failed msg=" + $_.Exception.Message); exit 1 }

$h = (Get-FileHash $target).Hash.Substring(0,16)
if ($h -ne $ExpectHash) { Write-Output "INSTALL=FAIL reason=hash_mismatch got=$h want=$ExpectHash"; exit 1 }
Write-Output "INSTALL=OK src=$SrcName hash=$h"
