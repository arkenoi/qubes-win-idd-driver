#!/bin/bash
# pvnic-xbm-verify-selftest.sh - prove the per-boot xenbus_monitor enforcement VERIFIES AFTER the kill.
#
# WHY. guest/pvnic-selfprime.ps1's payload (pvnic-boot.ps1, run by the QubesPvNic task at every boot)
# stops, disables and kills xenbus_monitor. Audit 2026-09-16 #20: it slept 500 ms, read the status
# once, killed without waiting and logged 'enforced off' from the PRE-state - a monitor that survived
# was logged as enforced off. The verdict now comes from a re-enumeration AFTER the kill
# (Enforce-XenbusMonitorOff, between XBM-ENFORCE-BEGIN/END). Windows is mocked here: Get-Service,
# sc.exe, Get-Process, Stop-Process, Get-ItemProperty and reg are functions over one 'world' table,
# so every shape the function must tell apart can be built offline, including the ones a live guest
# only shows once in a while (the mid-prompt STOP_PENDING wedge, the orphan process from an earlier
# boot the installer measured on 2026-08-28, an unkillable survivor).
#
# EXTRACTION IS BY MARKER, NOT BY sed-to-closing-brace (see private-disk-gate-selftest.sh for why).
#
# Per this project's rule a check counts only once it has been seen to FAIL with the defect
# re-introduced:
#   XBM_DEFECT=NOVERIFY - the verdict line becomes '$survived = $false': 'enforced off' asserted
#                         without consulting the post-state, which is the original bug -> the
#                         SURVIVOR / ORPHAN-UNKILLABLE / AUTOREBOOT / CONFIG cases must read ok=true
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

case "${XBM_DEFECT:-}" in
  NOVERIFY)
    sed -i 's/^\(\s*\)\$survived = .*$/\1$survived = $false/' "$T/fn.ps1"
    # A knob that silently fails to apply would make the 'defect' run pass for the wrong reason.
    grep -q '^\s*\$survived = \$false$' "$T/fn.ps1" || { echo "FATAL: XBM_DEFECT=NOVERIFY did not apply - verdict line not found"; exit 2; }
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
    $w = @{ present = $true; status = 'Running'; start = 'Automatic'; procs = @(4321); autoreboot = $null
            stopWorks = $true; stopEndsProc = $true; killWorks = $true; regWorks = $true; configWorks = $true }
    foreach ($k in $o.Keys) { $w[$k] = $o[$k] }
    $script:world = $w
}
# ---- mocks: the Windows the function talks to, over $script:world ----
function reg { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    if ($script:world.regWorks) { $script:world.autoreboot = [uint32]0 } }
function sc.exe { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    $w = $script:world
    if ($a[0] -eq 'config' -and $w.configWorks) { $w.start = 'Disabled' }
    if ($a[0] -eq 'stop') {
        if ($w.stopWorks) { $w.status = 'Stopped'; if ($w.stopEndsProc) { $w.procs = @() } }
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
function Get-Process { [CmdletBinding()] param([string]$Name)
    foreach ($id in @($script:world.procs)) {
        $o = [pscustomobject]@{ Name = 'xenbus_monitor_9_1_0_0'; Id = $id }
        $o | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) return $true } -PassThru
    }
}
function Stop-Process { [CmdletBinding()] param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force)
    process {
        $w = $script:world
        if ($w.killWorks) {
            $w.procs = @($w.procs | Where-Object { $_ -ne $InputObject.Id })
            if ($w.procs.Count -eq 0 -and $w.status -ne 'Stopped') { $w.status = 'Stopped' }   # SCM notices the death
        }
    }
}
function Get-ItemProperty { [CmdletBinding()] param([Parameter(Position = 0)][string]$Path)
    [pscustomobject]@{ AutoReboot = $script:world.autoreboot } }

. $Fn
$pass = 0; $fail = 0
function Expect([string]$label, [hashtable]$w, [bool]$wantOk, [string]$postMust) {
    New-World $w
    $r = Enforce-XenbusMonitorOff
    $good = ($r.ok -eq $wantOk) -and ($r.post -like "*$postMust*")
    if ($good) { $script:pass++; Write-Host "PASS  $label -> ok=$($r.ok) post=[$($r.post)]" }
    else { $script:fail++; Write-Host "FAIL  $label -> ok=$($r.ok) wanted $wantOk; post=[$($r.post)] must contain '$postMust'" }
}
# ---- states that must read ENFORCED (a false red here is a marker + event on every boot) ----
Expect 'clean: Running/Automatic, sc stop ends it and its process'                 @{} $true 'service=Disabled/Stopped procs=0 AutoReboot=0'
Expect 'absent: no service, no process'                                            @{ present = $false; procs = @() } $true 'service=not present procs=0'
Expect 'wedged mid-prompt: sc stop leaves StopPending, the kill works'             @{ stopWorks = $false } $true 'Disabled/Stopped procs=0'
Expect 'orphan (installer 2026-08-28): Disabled/Stopped, process from an earlier boot, kill works' @{ status = 'Stopped'; start = 'Disabled' } $true 'procs=0'
Expect 'absent service, a stray process, kill works'                               @{ present = $false } $true 'service=not present procs=0'
# ---- states that must read SURVIVED (the original code logged all of these as enforced off) ----
Expect 'SURVIVOR: sc stop fails and the kill fails'                                @{ stopWorks = $false; killWorks = $false } $false 'procs=1(xenbus_monitor_9_1_0_0:4321)'
Expect 'ORPHAN-UNKILLABLE: Disabled/Stopped service, unkillable process'           @{ status = 'Stopped'; start = 'Disabled'; killWorks = $false } $false 'Disabled/Stopped procs=1'
Expect 'AUTOREBOOT: reg add failed, service otherwise enforced'                    @{ regWorks = $false } $false 'AutoReboot=unset'
Expect 'CONFIG: sc config refused, service stays Automatic'                        @{ configWorks = $false } $false 'service=Automatic/Stopped'
Expect 'absent service, a stray UNKILLABLE process'                                @{ present = $false; killWorks = $false } $false 'procs=1'
Write-Host "=== pvnic xbm verify selftest: $pass passed, $fail failed ==="
exit $(if ($fail -eq 0) { 0 } else { 1 })
PS
"$PWSH" -NoProfile -File "$T/run.ps1" -Fn "$T/fn.ps1"
