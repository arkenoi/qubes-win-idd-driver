#!/bin/bash
# private-disk-gate-selftest.sh - prove Classify-PrivateDiskState BEFORE it gates a real install.
#
# WHY. The private-disk gate (Install-QwtImproved.ps1, Wait-PrivateDiskReady) is the first fix for the
# missing-Q: defect and it refuses to run msiexec on several disk-table shapes. A gate that refuses
# wrongly is a false RED on every install; a gate that proceeds wrongly re-creates the silent skip it
# exists to stop - or, worse, lets stock format the VOLATILE disk as Q:. So the classifier is
# exercised here, offline, against disk tables built from the REAL DISKPROBE captures on record
# (emulated: QM00001/2/3 + the 0.1 GB prime sticks; PV: sn 0000/0001/0002) and every defect shape
# the root-cause pass named (wf_8af058f7): stick at #1, volatile at #1, private absent, private
# non-RAW, wrong name, unknown serial scheme, mis-numbered on the PV path.
#
# EXTRACTION IS BY MARKER, NOT BY sed-to-closing-brace. Twice on 2026-09-14 a function pulled out of a
# harness by `sed '/^fn()/,/^}/p'` was truncated at a `}` inside its body and the test ran against a
# stub. The classifier sits between QWT-GATE-BEGIN and QWT-GATE-END in the installer for exactly
# this reason, and this script refuses to run if either marker is missing.
#
# Per this project's rule, a check counts only once it has been seen to FAIL on a build with the
# defect deliberately re-introduced. Two knobs:
#   GATE_DEFECT=NOVOLATILE  - blank the volatile-serial check  -> VOLATILE-AT-1 must be missed -> FAIL
#   GATE_DEFECT=NORAW       - drop the RAW requirement          -> NONRAW-AT-1 must be missed   -> FAIL
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

PWSH=${PWSH:-/home/user/bin/pwsh7/pwsh}
[ -x "$PWSH" ] || PWSH=$(command -v pwsh) || { echo "FATAL: no pwsh"; exit 2; }
SRC=packaging/setup/Install-QwtImproved.ps1
T=$(mktemp -d "${TMPDIR:-/tmp}/gatetest.XXXXXX"); trap 'rm -rf "$T"' EXIT

grep -q 'QWT-GATE-BEGIN' "$SRC" && grep -q 'QWT-GATE-END' "$SRC" \
  || { echo "FATAL: QWT-GATE-BEGIN/END markers missing from $SRC - cannot extract the classifier"; exit 2; }
awk '/QWT-GATE-BEGIN/{f=1;next} /QWT-GATE-END/{f=0} f' "$SRC" > "$T/classify.ps1"
grep -q '^function Classify-PrivateDiskState' "$T/classify.ps1" \
  || { echo "FATAL: extracted block does not start with the classifier"; exit 2; }

case "${GATE_DEFECT:-}" in
  NOVOLATILE) sed -i 's/if (\$VolatileSerials -contains \$sn) {/if ($false) {/' "$T/classify.ps1" ;;
  NORAW)      sed -i "s/\$raw    = (\"\$(\$d1.PartitionStyle)\" -eq 'RAW')/\$raw    = \$true/" "$T/classify.ps1" ;;
  '') ;;
  *) echo "FATAL: unknown GATE_DEFECT '$GATE_DEFECT'"; exit 2 ;;
esac

cat > "$T/run.ps1" <<'PS'
param([string]$Classifier)
. $Classifier
$pass = 0; $fail = 0
function D([int]$n, [string]$name, [double]$gb, [string]$style, [string]$sn) {
    [pscustomobject]@{ Number = $n; FriendlyName = $name; Size = [int64]($gb * 1GB); PartitionStyle = $style; SerialNumber = $sn; BusType = 'x'; Location = 'x' }
}
# Real shapes, from DISKPROBE (sizes/serials/names verbatim).
$EMU = @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'QEMU HARDDISK' 20 'RAW' 'QM00002'), (D 2 'QEMU HARDDISK' 10 'RAW' 'QM00003'),
          (D 3 'QEMU QEMU HARDDISK' 0.1 'MBR' '1-0000:00:05.0-1'), (D 4 'QEMU QEMU HARDDISK' 0.1 'MBR' '1-0000:00:05.0-2'),
          (D 5 'XENSRC PVDISK' 0.1 'MBR' '0008'), (D 6 'XENSRC PVDISK' 0.1 'MBR' '0009') )
$PV  = @( (D 0 'XENSRC PVDISK' 80 'MBR' '0000'), (D 1 'XENSRC PVDISK' 20 'RAW' '0001'), (D 2 'XENSRC PVDISK' 10 'RAW' '0002') )
function Expect([string]$label, $disks, [bool]$q, [string]$want) {
    $r = Classify-PrivateDiskState -Disks $disks -QPresent $q
    if ($r.state -eq $want) { $script:pass++; Write-Host "PASS  $label -> $($r.state)" }
    else { $script:fail++; Write-Host "FAIL  $label -> got $($r.state), wanted $want  ($($r.why))" }
}
# ---- the states a wait can or cannot fix, from the real shapes ----
Expect 'emulated path, clean, private RAW at #1'                          $EMU  $false 'READY'
Expect 'PV path, clean, private RAW at #1'                                $PV   $false 'READY'
Expect 'Q: already present (upgrade/reinstall) - stock no-ops'            @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'QEMU HARDDISK' 20 'GPT' 'QM00002') ) $true 'READY-Q-PRESENT'
Expect 'prime STICK holds #1, private RAW at #3 (wrong-named device)'     @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'QEMU QEMU HARDDISK' 0.1 'MBR' '1-0000:00:05.0-1'), (D 3 'QEMU HARDDISK' 20 'RAW' 'QM00002') ) $false 'MISNUMBERED'
Expect 'prime STICK holds #1, private NOT enumerated (wait can fix)'      @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'QEMU QEMU HARDDISK' 0.1 'MBR' '1-0000:00:05.0-1') ) $false 'NOT-READY'
Expect 'no disk #1 at all, private absent (wait can fix)'                 @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 2 'QEMU HARDDISK' 10 'RAW' 'QM00003') ) $false 'NOT-READY'
Expect 'no disk #1, but private RAW at #2 (mis-numbered)'                 @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 2 'QEMU HARDDISK' 20 'RAW' 'QM00002') ) $false 'MISNUMBERED'
Expect 'VOLATILE holds #1 - the latent data-loss hazard'                  @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'QEMU HARDDISK' 10 'RAW' 'QM00003'), (D 2 'QEMU HARDDISK' 20 'RAW' 'QM00002') ) $false 'VOLATILE-AT-1'
Expect 'private at #1 but GPT and no Q: (non-RAW facet)'                 @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'QEMU HARDDISK' 20 'GPT' 'QM00002') ) $false 'NONRAW-AT-1'
Expect 'private at #1, RAW, but a name stock does not match'             @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'Virtio HARDDISK' 20 'RAW' 'QM00002') ) $false 'WRONGNAME-AT-1'
Expect '#1 RAW + stock name but an unknown serial scheme (proceed+log)'  @( (D 0 'QEMU HARDDISK' 80 'MBR' 'S1'), (D 1 'QEMU HARDDISK' 20 'RAW' 'S2'), (D 2 'QEMU HARDDISK' 10 'RAW' 'S3') ) $false 'READY-SERIAL-UNKNOWN'
Expect 'PV path, ROOT holds #1, private RAW at #0 (mis-numbered)'         @( (D 0 'XENSRC PVDISK' 20 'RAW' '0001'), (D 1 'XENSRC PVDISK' 80 'MBR' '0000'), (D 2 'XENSRC PVDISK' 10 'RAW' '0002') ) $false 'MISNUMBERED'
Expect 'PV path, VOLATILE holds #1'                                       @( (D 0 'XENSRC PVDISK' 80 'MBR' '0000'), (D 1 'XENSRC PVDISK' 10 'RAW' '0002'), (D 2 'XENSRC PVDISK' 20 'RAW' '0001') ) $false 'VOLATILE-AT-1'
Expect 'empty table (Get-Disk returned nothing)'                          @()   $false 'NOT-READY'
Expect 'serial with surrounding whitespace still matches'                 @( (D 1 'QEMU HARDDISK' 20 'RAW' ' QM00002 ') ) $false 'READY'
# Review 2026-09-16 (A2): an UNLISTED-serial RAW stock-named disk at #1 while a SIBLING carries the known
# scheme is an interloper, not an unknown scheme - must WAIT, never proceed (stock would format it as Q:).
Expect 'interloper at #1 (unlisted serial) with root QM00001 at #0 -> NOT-READY'   @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'QEMU HARDDISK' 20 'RAW' 'QM00004') ) $false 'NOT-READY'
# Review (B2): a disk whose Number is not assigned yet is not-yet-enumerated - wait, do not call it misnumbered.
$nullNum = [pscustomobject]@{ Number = $null; FriendlyName = 'QEMU HARDDISK'; Size = [int64](20 * 1GB); PartitionStyle = 'RAW'; SerialNumber = 'QM00002'; BusType = 'x'; Location = 'x' }
Expect 'private disk with Number=$null (not yet numbered) -> NOT-READY'     @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), $nullNum ) $false 'NOT-READY'
# ---- the disk the WRAPPER prepares ('priv'): must name the private disk wherever it is, and nothing else ----
function ExpectPriv([string]$label, $disks, [string]$wantState, $wantNum) {
    $r = Classify-PrivateDiskState -Disks $disks -QPresent $false
    $got = if ($r.priv) { [int]$r.priv.Number } else { $null }
    if ($r.state -eq $wantState -and $got -eq $wantNum) { $script:pass++; Write-Host "PASS  $label -> $($r.state) priv=#$got" }
    else { $script:fail++; Write-Host "FAIL  $label -> got $($r.state) priv=#$got, wanted $wantState priv=#$wantNum" }
}
ExpectPriv 'READY: prepare disk #1 itself'                                 $EMU 'READY' 1
ExpectPriv 'MISNUMBERED (stick at #1, private RAW at #3): prepare #3'      @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'QEMU QEMU HARDDISK' 0.1 'MBR' 'x'), (D 3 'QEMU HARDDISK' 20 'RAW' 'QM00002') ) 'MISNUMBERED' 3
ExpectPriv 'VOLATILE at #1, private RAW at #2: prepare #2, never #1'       @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'QEMU HARDDISK' 10 'RAW' 'QM00003'), (D 2 'QEMU HARDDISK' 20 'RAW' 'QM00002') ) 'VOLATILE-AT-1' 2
ExpectPriv 'VOLATILE at #1, private ABSENT: nothing to prepare (priv null)' @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'QEMU HARDDISK' 10 'RAW' 'QM00003') ) 'VOLATILE-AT-1' $null
ExpectPriv 'WRONGNAME at #1 (private serial, odd name): prepare #1'         @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'Virtio HARDDISK' 20 'RAW' 'QM00002') ) 'WRONGNAME-AT-1' 1
ExpectPriv 'NONRAW at #1: priv must be null (refuse, never format data)'   @( (D 0 'QEMU HARDDISK' 80 'MBR' 'QM00001'), (D 1 'QEMU HARDDISK' 20 'GPT' 'QM00002') ) 'NONRAW-AT-1' $null
# The stock action is dropped from the MSI build, so on an unknown scheme the wrapper prepares #1 exactly as stock did.
ExpectPriv 'SERIAL-UNKNOWN: prepare #1 as stock would have (stock action is dropped)' @( (D 0 'QEMU HARDDISK' 80 'MBR' 'S1'), (D 1 'QEMU HARDDISK' 20 'RAW' 'S2') ) 'READY-SERIAL-UNKNOWN' 1
Write-Host "=== private-disk gate selftest: $pass passed, $fail failed ==="
exit $(if ($fail -eq 0) { 0 } else { 1 })
PS
"$PWSH" -NoProfile -File "$T/run.ps1" -Classifier "$T/classify.ps1"
