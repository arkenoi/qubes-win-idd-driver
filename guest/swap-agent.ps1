# Swap the installed gui-agent.exe for a pushed one, so a single agent fix can be verified
# without a full package reinstall.
#
# SCOPE, stated so this is never mistaken for acceptance: this is a DIAGNOSTIC swap for verifying
# one binary. It is NOT an acceptance path - acceptance installs the published package end to end
# from one ISO, per the standing rule. Use this to answer "does the fix work", then prove it again
# through a real install.
#
# The watchdog service respawns the agent, so it must be stopped first or the swap races a restart
# and the old binary comes straight back.
#
# Reports the hash BEFORE and AFTER and of the RUNNING process, because a swap that silently did
# not land would otherwise be graded as a working fix - the exact failure the project rule
# "verify the artefact under test is actually installed" exists to prevent.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$NewAgent)
$ErrorActionPreference = 'Continue'

Write-Output '=== RESULT ==='
if (-not (Test-Path $NewAgent)) { Write-Output "FAIL: $NewAgent not found"; exit 1 }

$proc = Get-Process gui-agent -ErrorAction SilentlyContinue
$target = if ($proc) { $proc.Path } else { 'C:\Program Files\Qubes Tools\bin\gui-agent.exe' }
Write-Output ("TARGET=" + $target)
if (Test-Path $target) {
    Write-Output ("HASH_BEFORE=" + (Get-FileHash $target -Algorithm SHA256).Hash.Substring(0, 16))
}
Write-Output ("HASH_PUSHED=" + (Get-FileHash $NewAgent -Algorithm SHA256).Hash.Substring(0, 16))

$svc = Get-Service QubesGuiWatchdog -ErrorAction SilentlyContinue
if ($svc) {
    Stop-Service QubesGuiWatchdog -Force -ErrorAction SilentlyContinue
    Write-Output ("WATCHDOG_STOPPED=" + (Get-Service QubesGuiWatchdog).Status)
}
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# Keep exactly one .orig backup - the FIRST one, which is the shipped binary. Overwriting it on a
# second swap would lose the only copy of what the package actually installed.
if ((Test-Path $target) -and -not (Test-Path "$target.orig")) {
    Copy-Item $target "$target.orig" -Force
    Write-Output 'BACKUP=created'
}
Copy-Item $NewAgent $target -Force
if (-not $?) { Write-Output 'FAIL: copy failed (file still locked?)'; exit 1 }
Write-Output ("HASH_AFTER=" + (Get-FileHash $target -Algorithm SHA256).Hash.Substring(0, 16))

if ($svc) { Start-Service QubesGuiWatchdog -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 12

$now = Get-Process gui-agent -ErrorAction SilentlyContinue
if (-not $now) { Write-Output 'FAIL: gui-agent is NOT running after the swap'; exit 1 }
Write-Output ("RUNNING_PID=" + $now.Id)
Write-Output ("HASH_RUNNING=" + (Get-FileHash $now.Path -Algorithm SHA256).Hash.Substring(0, 16))
Write-Output 'SWAP_OK'
