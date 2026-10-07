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
#
# -NewBroker <path>: swap wgcbroker.exe as well (the broker is a separate binary; a broker fix is not in
# gui-agent.exe). Implies -StopHelpers - a running broker holds its exe open. Same before/after/running report.
# -NewNotifhost <path>: the same for notifhost.exe (the notification bridge). The agent relaunches the bridge only once
# the shell is up and its relaunch is throttled, so the RUNNING bridge is waited for longer than the broker.
#
# HELPERS ARE FOUND BY INSTALL PATH, not by name: the agent launches them through 8.3 paths, so Windows names
# them WGCBRO~1 / NOTIFH~1 and a by-name Get-Process misses them (findings/issues.md P3, measured 2026-09-30).
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$NewAgent, [switch]$StopHelpers, [string]$NewBroker = '',
      [string]$NewNotifhost = '')
if ($NewBroker -or $NewNotifhost) { $StopHelpers = $true }
function Get-OurHelpers {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $pp = $null; try { $pp = $_.Path } catch { }
        $pp -and ($pp -like '*\Qubes Tools\bin\*' -or $pp -like '*\QUBEST~1\bin\*') -and
            $_.ProcessName -match '^(wgcbroker|WGCBRO~1|notifhost|NOTIFH~1|etwproxy|ETWPRO~1)$' })
}
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
$brokerTarget = 'C:\Program Files\Qubes Tools\bin\wgcbroker.exe'
if ($NewBroker) {
    if (-not (Test-Path $NewBroker)) { Write-Output "FAIL: $NewBroker not found"; exit 1 }
    Write-Output ("BROKER_HASH_BEFORE=" + (Hash16 $brokerTarget))
    Write-Output ("BROKER_HASH_PUSHED=" + (Hash16 $NewBroker))
}
$notifTarget = 'C:\Program Files\Qubes Tools\bin\notifhost.exe'
if ($NewNotifhost) {
    if (-not (Test-Path $NewNotifhost)) { Write-Output "FAIL: $NewNotifhost not found"; exit 1 }
    Write-Output ("NOTIF_HASH_BEFORE=" + (Hash16 $notifTarget))
    Write-Output ("NOTIF_HASH_PUSHED=" + (Hash16 $NewNotifhost))
}

# The agent is stopped THROUGH THE SERVICE THAT OWNS IT and proven gone by handle (Stop-GuiAgentOwner in
# guest/restart-gui-agent.ps1, pushed next to this script); the swap happens between that and
# Start-GuiAgentOwner, which proves the NEW agent by its log turnover. Owner 2026-10-07: never
# `Get-Process gui-agent | Stop-Process`, which was any process so named and raced the watchdog's relaunch.
$helper = Join-Path $PSScriptRoot 'restart-gui-agent.ps1'
if (-not (Test-Path -LiteralPath $helper)) { Write-Output 'FAIL: restart-gui-agent.ps1 not pushed next to this script (tools/qtest push guest/restart-gui-agent.ps1)'; exit 1 }
. $helper
$svcStop = Stop-GuiAgentOwner
foreach ($ln in @($svcStop.lines)) { Write-Output $ln }
$svc = ($svcStop.service -ne 'absent')
if ($svc) { Write-Output ("WATCHDOG_STOPPED=" + $(if ($svcStop.svc_stopped) { 'Stopped' } else { 'NOT-STOPPED' })) }
if ($StopHelpers) {
    # The helpers are the AGENT's children: its exit path tells them to leave, so after the service stop they
    # are WAITED OUT, bounded, and a survivor is REPORTED - never stopped by this script, which did not start
    # them (owner 2026-10-07). A survivor that still holds its exe makes the copy below fail loudly.
    $deadline = (Get-Date).AddSeconds(15)
    do { $left = @(Get-OurHelpers); if (-not $left.Count) { break }; Start-Sleep -Milliseconds 500 } while ((Get-Date) -lt $deadline)
    Write-Output ("HELPERS_GONE=" + $(if ($left.Count) { 'no' } else { 'yes' }))
    # Loud, not fatal: exiting here would leave the guest with no agent at all. A helper that survived is
    # in the next repetition's FAMILY list, and the summariser voids a stock repetition that counted one.
    if ($left.Count) { Write-Output ("WARN: helpers still running (not ended by this script): " + (($left | ForEach-Object { '{0}:{1}' -f $_.ProcessName, $_.Id }) -join ',')) }
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
if ($NewBroker) {
    if ((Test-Path $brokerTarget) -and -not (Test-Path "$brokerTarget.orig")) {
        Copy-Item $brokerTarget "$brokerTarget.orig" -Force
        Write-Output 'BROKER_BACKUP=created'
    }
    Copy-Item $NewBroker $brokerTarget -Force
    if (-not $?) { Write-Output 'FAIL: broker copy failed (still running?)'; if ($svc) { [void](Start-GuiAgentOwner -Stopped $svcStop) }; exit 1 }
    Write-Output ("BROKER_HASH_AFTER=" + (Hash16 $brokerTarget))
}
if ($NewNotifhost) {
    if ((Test-Path $notifTarget) -and -not (Test-Path "$notifTarget.orig")) {
        Copy-Item $notifTarget "$notifTarget.orig" -Force
        Write-Output 'NOTIF_BACKUP=created'
    }
    Copy-Item $NewNotifhost $notifTarget -Force
    if (-not $?) { Write-Output 'FAIL: notifhost copy failed (still running?)'; if ($svc) { [void](Start-GuiAgentOwner -Stopped $svcStop) }; exit 1 }
    Write-Output ("NOTIF_HASH_AFTER=" + (Hash16 $notifTarget))
}

# Start the service; the NEW agent is proven by its log turnover (bounded), not by a fixed sleep.
$ra = Start-GuiAgentOwner -Stopped $svcStop
foreach ($ln in @($ra.lines)) { Write-Output $ln }
if (-not $ra.ok) { Write-Output ("FAIL: no new gui-agent after the swap - " + $ra.reason); exit 1 }
$now = Get-Process -Id $ra.new_pid -ErrorAction SilentlyContinue
if (-not $now) { Write-Output 'FAIL: gui-agent is NOT running after the swap'; exit 1 }
Write-Output ("RUNNING_PID=" + $now.Id)
Write-Output ("HASH_RUNNING=" + (Hash16 $now.Path))
if ($NewBroker) {
    # The agent starts its broker itself; give it a moment, then report the RUNNING broker's binary.
    $b = $null
    foreach ($i in 1..10) { $b = Get-OurHelpers | Where-Object { $_.ProcessName -match '^(wgcbroker|WGCBRO~1)$' } | Select-Object -First 1; if ($b) { break }; Start-Sleep -Seconds 2 }
    if (-not $b) { Write-Output 'FAIL: no broker running after the swap'; exit 1 }
    Write-Output ("BROKER_RUNNING_PID=" + $b.Id)
    Write-Output ("BROKER_HASH_RUNNING=" + (Hash16 $b.Path))
}
if ($NewNotifhost) {
    # The RESIDENT bridge (--bridge), not a one-shot notifhost the agent may also run: matched by command line.
    $n = $null
    foreach ($i in 1..20) {
        $n = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
             Where-Object { ($_.Name -match '^(notifhost|NOTIFH~1)\.exe$') -and $_.CommandLine -like '*--bridge*' } | Select-Object -First 1
        if ($n) { break }; Start-Sleep -Seconds 2
    }
    if (-not $n) { Write-Output 'FAIL: no notification bridge running after the swap'; exit 1 }
    Write-Output ("NOTIF_RUNNING_PID=" + $n.ProcessId)
    Write-Output ("NOTIF_HASH_RUNNING=" + (Hash16 $n.ExecutablePath))
}
Write-Output 'SWAP_OK'
