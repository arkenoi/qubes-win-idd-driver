#!/bin/bash
# pvnic-xbm-verify-selftest.sh - prove the per-boot xenbus_monitor enforcement VERIFIES AFTER the stop, and that it
# touches only the process the SCM names for the service.
#
# WHY. guest/pvnic-selfprime.ps1's payload (pvnic-boot.ps1, run by the QubesPvNic task at every boot) stops and
# disables xenbus_monitor. Audit 2026-09-16 #20: it slept 500 ms, read the status once, killed without waiting and
# logged 'enforced off' from the PRE-state - a monitor that survived was logged as enforced off. The verdict now
# comes from a re-enumeration AFTER the stop (Enforce-XenbusMonitorOff, between XBM-ENFORCE-BEGIN/END).
# Owner's rule 2026-10-03 (docs/ADR-updater.md 12.4): nothing is killed by process NAME. Until then the function
# Stop-Process'ed every process named xenbus_monitor*; now it waits on - and, if it must, terminates - ONLY the pid
# the SCM reported for the service before the stop (Win32_Service.ProcessId), by handle. A monitor process the SCM
# does not own (the orphan the installer measured on 2026-08-28; a stray under an absent service) is counted,
# read as SURVIVED (the caller Faults, loudly) and left alive.
# Windows is mocked: Get-Service, sc.exe, Get-CimInstance, Get-Process (-Name and -Id), Stop-Process,
# Get-ItemProperty and reg are functions over one 'world' table, so every shape the function must tell apart can
# be built offline, including the ones a live guest only shows once in a while (the mid-prompt STOP_PENDING wedge,
# the orphan, an unkillable survivor, a same-named stray beside the service's own process).
#
# EXTRACTION IS BY MARKER, NOT BY sed-to-closing-brace (see private-disk-gate-selftest.sh for why).
#
# Per this project's rule a check counts only once it has been seen to FAIL with the defect re-introduced:
#   XBM_DEFECT=NOVERIFY - the verdict line becomes '$survived = $false': 'enforced off' asserted without consulting
#                         the post-state (the original bug) -> SURVIVOR / ORPHAN / AUTOREBOOT / CONFIG read ok=true
#                         -> this test must FAIL.
#   XBM_DEFECT=BYNAME   - the pre-2026-10-03 by-name kill is put back at its GUARD line -> the orphan and the stray
#                         are killed (procs=0, ok=true where SURVIVED is required; the stray beside the service dies)
#                         -> this test must FAIL.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

PWSH=${PWSH:-/home/user/bin/pwsh7/pwsh}
[ -x "$PWSH" ] || PWSH=$(command -v pwsh) || { echo "FATAL: no pwsh"; exit 2; }
SRC=guest/pvnic-selfprime.ps1
T=$(mktemp -d "${TMPDIR:-/tmp}/xbmtest.XXXXXX"); trap 'rm -rf "$T"' EXIT

grep -q 'XBM-ENFORCE-BEGIN' "$SRC" && grep -q 'XBM-ENFORCE-END' "$SRC" \
  || { echo "FATAL: XBM-ENFORCE-BEGIN/END markers missing from $SRC - cannot extract the function"; exit 2; }
awk '/XBM-ENFORCE-BEGIN/{f=1;next} /XBM-ENFORCE-END/{f=0} f' "$SRC" > "$T/fn.ps1"
grep -q '^function Enforce-XenbusMonitorOff' "$T/fn.ps1" \
  || { echo "FATAL: extracted block does not start with Enforce-XenbusMonitorOff"; exit 2; }
grep -q '^\s*# GUARD:xbmpayloadbyname$' "$T/fn.ps1" \
  || { echo "FATAL: the '# GUARD:xbmpayloadbyname' line is missing from the extracted function - the BYNAME knob has no anchor"; exit 2; }

case "${XBM_DEFECT:-}" in
  NOVERIFY)
    sed -i 's/^\(\s*\)\$survived = .*$/\1$survived = $false/' "$T/fn.ps1"
    # A knob that silently fails to apply would make the 'defect' run pass for the wrong reason.
    grep -q '^\s*\$survived = \$false$' "$T/fn.ps1" || { echo "FATAL: XBM_DEFECT=NOVERIFY did not apply - verdict line not found"; exit 2; }
    ;;
  BYNAME)
    sed -i "s/^\(\s*\)# GUARD:xbmpayloadbyname\$/\1foreach (\$p in @(Get-Process -Name 'xenbus_monitor*' -EA SilentlyContinue)) { try { \$p | Stop-Process -Force -EA Stop } catch { }; try { [void]\$p.WaitForExit(5000) } catch { } }   # DEFECT: kill by name (pre-2026-10-03)/" "$T/fn.ps1"
    grep -q 'DEFECT: kill by name' "$T/fn.ps1" || { echo "FATAL: XBM_DEFECT=BYNAME did not apply - GUARD line not replaced"; exit 2; }
    ;;
  '') ;;
  *) echo "FATAL: unknown XBM_DEFECT '$XBM_DEFECT'"; exit 2 ;;
esac

cat > "$T/run.ps1" <<'PS'
param([string]$Fn)
# The payload runs under SilentlyContinue; the function must decide correctly under it too.
$ErrorActionPreference = 'SilentlyContinue'
$script:world = $null
function New-World([hashtable]$o) {
    # procs: pid -> @{ alive; killable }. svcpid: the pid the SCM reports for the service while it is not Stopped.
    $w = @{ present = $true; status = 'Running'; start = 'Automatic'; svcpid = 4321; procs = @{ 4321 = @{ alive = $true; killable = $true } }
            autoreboot = $null; stopWorks = $true; stopEndsProc = $true; regWorks = $true; configWorks = $true
            kills = [System.Collections.Generic.List[string]]::new() }
    foreach ($k in $o.Keys) { $w[$k] = $o[$k] }
    # Clone every process entry: a case's kill must never leak into the next case through a shared literal
    # (the first version reused one $orphan table and the BYNAME knob 'passed' a later case on a corpse).
    $fresh = @{}
    foreach ($id in $w.procs.Keys) { $fresh[$id] = @{} + $w.procs[$id] }
    $w.procs = $fresh
    $script:world = $w
}
function Alive { @($script:world.procs.Keys | Where-Object { $script:world.procs[$_].alive } | Sort-Object) }
# ---- mocks: the Windows the function talks to, over $script:world ----
function reg { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    if ($script:world.regWorks) { $script:world.autoreboot = [uint32]0 } }
function sc.exe { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    $w = $script:world
    if ($a[0] -eq 'config' -and $w.configWorks) { $w.start = 'Disabled' }
    if ($a[0] -eq 'stop') {
        if ($w.stopWorks) { $w.status = 'Stopped'; if ($w.stopEndsProc -and $w.svcpid -and $w.procs[$w.svcpid]) { $w.procs[$w.svcpid].alive = $false } }
        else { $w.status = 'StopPending' }
    }
}
function Get-Service { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name)
    $w = $script:world
    if (-not $w.present) { return $null }
    # A ServiceController is a SNAPSHOT (status cached until Refresh), exactly what made the
    # pre-state log line wrong; the mock snapshots too, and WaitForStatus watches the live world.
    $o = [pscustomobject]@{ Name = 'xenbus_monitor'; Status = $w.status; StartType = $w.start }
    $o | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
        param($s, $t) if ($script:world.status -ne $s) { throw "timeout waiting for $s" } } -PassThru
}
function Get-CimInstance { [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    $w = $script:world
    if (-not $w.present) { return $null }
    # Win32_Service.ProcessId is the service's pid while it runs (or is stopping) and 0 once it is Stopped.
    $p = 0; if ($w.status -ne 'Stopped') { $p = $w.svcpid }
    [pscustomobject]@{ Name = 'xenbus_monitor'; ProcessId = [uint32]$p; State = $w.status }
}
function New-Proc([int]$id) {
    $o = [pscustomobject]@{ Name = 'xenbus_monitor_9_1_0_0'; ProcessName = 'xenbus_monitor_9_1_0_0'; Id = $id }
    $o | Add-Member -MemberType ScriptProperty -Name HasExited -Value { -not $script:world.procs[$this.Id].alive }
    $o | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) return (-not $script:world.procs[$this.Id].alive) }
    $o | Add-Member -MemberType ScriptMethod -Name Kill -Value {
        $w = $script:world
        $w.kills.Add("handle:$($this.Id)")
        if (-not $w.procs[$this.Id].killable) { throw 'Access is denied' }
        $w.procs[$this.Id].alive = $false
        if ($this.Id -eq $w.svcpid -and $w.status -ne 'Stopped') { $w.status = 'Stopped' }   # the SCM notices its process's death
    }
    $o
}
# NOTE the loop variable: PowerShell variables are case-insensitive, so a loop over `$id` inside a function whose
# parameter is `[int[]]$Id` writes the typed parameter - every pid became an int[] and New-Proc's [int] binding
# failed silently under SilentlyContinue (the first version of this mock enumerated nothing by name).
function Get-Process { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [int[]]$Id)
    if ($Id) { foreach ($wanted in $Id) { if ($script:world.procs[$wanted] -and $script:world.procs[$wanted].alive) { New-Proc $wanted } }; return }
    foreach ($livePid in (Alive)) { New-Proc $livePid }
}
function Stop-Process { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force)
    process {
        $w = $script:world
        $w.kills.Add("Stop-Process:$($InputObject.Id)")
        if ($w.procs[$InputObject.Id].killable) {
            $w.procs[$InputObject.Id].alive = $false
            if ((Alive).Count -eq 0 -and $w.status -ne 'Stopped') { $w.status = 'Stopped' }   # SCM notices the death
        }
    }
}
function Get-ItemProperty { [CmdletBinding()] param([Parameter(Position = 0)][string]$Path)
    [pscustomobject]@{ AutoReboot = $script:world.autoreboot } }

. $Fn
$pass = 0; $fail = 0
function Expect([string]$label, [hashtable]$w, [bool]$wantOk, [string]$postMust, [string]$aliveAfter = '', [string]$killsMust = '') {
    New-World $w
    $r = Enforce-XenbusMonitorOff
    $alive = ((Alive) -join ',')
    $kills = ($script:world.kills -join ',')
    $good = ($r.ok -eq $wantOk) -and ($r.post -like "*$postMust*") -and ($alive -eq $aliveAfter) -and ($kills -eq $killsMust)
    if ($good) { $script:pass++; Write-Host "PASS  $label -> ok=$($r.ok) post=[$($r.post)] alive=[$alive] kills=[$kills]" }
    else { $script:fail++; Write-Host "FAIL  $label -> ok=$($r.ok) wanted $wantOk; post=[$($r.post)] must contain '$postMust'; alive=[$alive] wanted [$aliveAfter]; kills=[$kills] wanted [$killsMust]" }
}
$orphan = @{ 4321 = @{ alive = $true; killable = $true } }
$unkillable = @{ 4321 = @{ alive = $true; killable = $false } }
# ---- states that must read ENFORCED (a false red here is a marker + event on every boot) ----
Expect 'clean: Running/Automatic, sc stop ends it and its process'                 @{} $true 'service=Disabled/Stopped procs=0 AutoReboot=0'
Expect 'absent: no service, no process'                                            @{ present = $false; procs = @{} } $true 'service=not present procs=0'
Expect 'wedged mid-prompt: sc stop leaves StopPending - the SCM pid is terminated by handle, nothing else' @{ stopWorks = $false } $true 'Disabled/Stopped procs=0' '' 'handle:4321'
Expect 'lingering: Stopped reported while the process is still exiting - waited on by handle, then terminated' @{ stopEndsProc = $false } $true 'Disabled/Stopped procs=0' '' 'handle:4321'
# ---- the owner's rule: only the SCM's pid is ever touched; everything else is counted and left alive ----
Expect 'stray beside the service: a same-named process (pid 9999) that is not the SCM pid stays ALIVE and reads SURVIVED' `
       @{ stopEndsProc = $false; procs = @{ 4321 = @{ alive = $true; killable = $true }; 9999 = @{ alive = $true; killable = $true } } } $false 'procs=1(xenbus_monitor_9_1_0_0:9999)' '9999' 'handle:4321'
Expect 'ORPHAN (installer 2026-08-28): Disabled/Stopped service, a process the SCM does not own - NOT killed, reads SURVIVED' `
       @{ status = 'Stopped'; start = 'Disabled'; procs = $orphan } $false 'Disabled/Stopped procs=1(xenbus_monitor_9_1_0_0:4321)' '4321' ''
Expect 'absent service, a stray process - NOT killed, reads SURVIVED'              @{ present = $false; procs = $orphan } $false 'service=not present procs=1' '4321' ''
# ---- states that must read SURVIVED (the original code logged all of these as enforced off) ----
Expect 'SURVIVOR: sc stop fails and the SCM pid cannot be terminated'               @{ stopWorks = $false; procs = $unkillable } $false 'procs=1(xenbus_monitor_9_1_0_0:4321)' '4321' 'handle:4321'
Expect 'AUTOREBOOT: reg add failed, service otherwise enforced'                    @{ regWorks = $false } $false 'AutoReboot=unset'
Expect 'CONFIG: sc config refused, service stays Automatic'                        @{ configWorks = $false } $false 'service=Automatic/Stopped'
Write-Host "=== pvnic xbm verify selftest: $pass passed, $fail failed ==="
exit $(if ($fail -eq 0) { 0 } else { 1 })
PS
"$PWSH" -NoProfile -File "$T/run.ps1" -Fn "$T/fn.ps1"
