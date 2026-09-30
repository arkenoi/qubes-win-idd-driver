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
#
# -StopHelpers (the benchmark's swap): also stop the helper processes OUR agent launches (wgcbroker,
# notifhost, etwproxy) while no agent runs, so neither side of a stock-vs-ours comparison inherits the
# other's helpers - a helper of ours left running through a stock repetition would compete for CPU
# and be charged to stock by the family sampler. Our agent relaunches its helpers when it starts.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$NewAgent, [switch]$StopHelpers)
$ErrorActionPreference = 'Continue'

Write-Output '=== RESULT ==='
if (-not (Test-Path $NewAgent)) { Write-Output "FAIL: $NewAgent not found"; exit 1 }

# A hash that cannot be read is REPORTED as UNREADABLE - a caller comparing it against the expected
# hash then fails the swap - never turned into a terminating error mid-report (lint L6).
function Hash16([string]$Path) {
    $h = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction SilentlyContinue
    if ($h -and $h.Hash) { return $h.Hash.Substring(0, 16) }
    return 'UNREADABLE'
}

$proc = Get-Process gui-agent -ErrorAction SilentlyContinue | Select-Object -First 1
$target = if ($proc) { $proc.Path } else { 'C:\Program Files\Qubes Tools\bin\gui-agent.exe' }
Write-Output ("TARGET=" + $target)
if (Test-Path $target) {
    Write-Output ("HASH_BEFORE=" + (Hash16 $target))
}
Write-Output ("HASH_PUSHED=" + (Hash16 $NewAgent))

$svc = Get-Service QubesGuiWatchdog -ErrorAction SilentlyContinue
if ($svc) {
    Stop-Service QubesGuiWatchdog -Force -ErrorAction SilentlyContinue
    Write-Output ("WATCHDOG_STOPPED=" + (Get-Service QubesGuiWatchdog).Status)
}
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
if ($StopHelpers) {
    $h = @(Get-Process -Name wgcbroker, notifhost, etwproxy -ErrorAction SilentlyContinue)
    $h | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $left = @(Get-Process -Name wgcbroker, notifhost, etwproxy -ErrorAction SilentlyContinue)
    Write-Output ("HELPERS_STOPPED=" + (($h | ForEach-Object { '{0}:{1}' -f $_.ProcessName, $_.Id }) -join ','))
    # Loud, not fatal: exiting here would leave the guest with no agent at all. A helper that survived is
    # in the next repetition's FAMILY list, and the summariser voids a stock repetition that counted one.
    if ($left.Count) { Write-Output ("WARN: helpers still running: " + (($left | ForEach-Object { '{0}:{1}' -f $_.ProcessName, $_.Id }) -join ',')) }
}

# Keep exactly one .orig backup - the FIRST one, which is the shipped binary. Overwriting it on a
# second swap would lose the only copy of what the package actually installed.
if ((Test-Path $target) -and -not (Test-Path "$target.orig")) {
    Copy-Item $target "$target.orig" -Force
    Write-Output 'BACKUP=created'
}
Copy-Item $NewAgent $target -Force
if (-not $?) { Write-Output 'FAIL: copy failed (file still locked?)'; exit 1 }
Write-Output ("HASH_AFTER=" + (Hash16 $target))

if ($svc) { Start-Service QubesGuiWatchdog -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 12

$now = Get-Process gui-agent -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $now) { Write-Output 'FAIL: gui-agent is NOT running after the swap'; exit 1 }
Write-Output ("RUNNING_PID=" + $now.Id)
Write-Output ("HASH_RUNNING=" + (Hash16 $now.Path))
Write-Output 'SWAP_OK'
