#!/bin/bash
# FAIL-PROOF harness for the ShouldAcceptWindow SAFEGUARD CLAUSES, via FI_GATE_OFF.
#
# WHAT THIS REPLACES. SG2's proof (2026-08-31) removed the Mode-2 gate on a branch and built a
# second binary. That works, but it costs a CI round trip per clause with ~19 clauses left, and it
# leaves a sceptic room to ask whether the red came from the gate removal or from some other
# difference between two builds. `FiGateOff()` makes each clause a registry bit on ONE artifact,
# so both sides of every proof differ by exactly that value.
#
# THE SPECIFICITY CONTROL IS FREE HERE. P5 grades four cells in one pass, and each bit should move
# exactly ONE of them. So an armed run does not merely show "a red appeared" - it shows the red
# appeared in the targeted cell WHILE THE OTHER THREE STAYED GREEN. That is the property that
# makes a red attributable, and it is what convinced me SG2's diag build had not simply broken the
# agent generally. A bit that reddens more than its own cell is reported as NOT PROVEN: it means
# the bypass is broader than the clause it claims to bypass.
#
#   bit                  cell   check earned
#   FI_GATE_MODE1  0x1   SG4    or-fullscreen-never-mapped / no-fullscreen-during-boot
#   FI_GATE_MODE2  0x2   SG2    borderless-fullscreen-gated  (re-proof from one artifact)
#   FI_GATE_START  0x4   SG9    start-not-presented
#
# FI_GATE_SHELLOVERLAY (0x8) is deliberately NOT here: its cell is in rnd-shell-surfaces.sh, not
# P5, and that harness still carries the nested-quote query pattern rule 16 names. Proving a check
# with an unaudited instrument would be the same mistake in a new place.
#
#   mgmt/harness/failproof-gates.sh <vm> [outdir]
set -uo pipefail
cd /home/user/qubes-win-idd-driver
require_scripts(){ local m=""; for s in "$@"; do [ -f "$s" ] || m="$m $s"; done
  [ -z "$m" ] || { echo "FATAL: missing:$m" >&2; exit 2; }; }
require_scripts mgmt/harness/p5-run.sh

VM="${1:?usage: $0 <vm> [outdir]}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"   # one harness per guest; see vmlock.sh
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/FAILPROOF-gates-$VM}"
mkdir -p "$OUT"
q(){ QTEST_VM=$VM timeout -k 8 "${T:-300}" ./tools/qtest "$@" 2>/dev/null; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  r "cmd /c powershell -NoProfile -EncodedCommand $b"; }
log(){ echo "$(date -u +%H:%M:%S) gates[$VM]: $*" | tee -a "$OUT/failproof.log"; }
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT"); rc=0
KEY='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'

# ---------------------------------------------------------------- the running binary must have the bits
# `gateoff=` in the startup banner exists only in a build carrying FiGateOff. An older fault build
# would silently ignore FaultGateOff and every armed run would come back green - which would look
# like "the gates all hold" and would in fact be "the bypass was never in force".
log "=== confirm the RUNNING agent understands FI_GATE_OFF ==="
BAN=$(psrun '$d=(Get-ItemProperty "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\").LogDir
$f=Get-ChildItem $d -Filter gui-agent-*.log | Sort LastWriteTime -Desc | Select -First 1
$l=Get-Content $f.FullName | Select-String -SimpleMatch "QGAFAULT-INIT build" | Select -First 1
$p=Get-Process gui-agent -EA SilentlyContinue
Write-Output ("BANNER " + $l.Line)
Write-Output ("RUNSHA " + (Get-FileHash $p.Path -Algorithm SHA256).Hash.ToLower())')
echo "$BAN" | grep -aE 'BANNER|RUNSHA' | cut -c1-200 | sed 's/^/  /' | tee -a "$OUT/failproof.log"
echo "$BAN" | grep -qa 'gateoff=' || {
  log "REFUSING: the running agent's QGAFAULT-INIT banner has no 'gateoff=' field, so this build"
  log "  predates FiGateOff. Every armed run would come back green for the wrong reason."
  exit 2; }
log "  gate-capable build CONFIRMED running"

set_gate(){  # <hex-or-0>
  psrun "New-Item -Path '$KEY' -Force | Out-Null
Set-ItemProperty -Path '$KEY' -Name FaultGateOff -Value $1 -Type DWord
Stop-Service QubesGuiWatchdog -Force -EA SilentlyContinue; Start-Sleep 3
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force; Start-Sleep 2
Start-Service QubesGuiWatchdog -EA SilentlyContinue; Start-Sleep 25
Write-Output ('GATEOFF ' + (Get-ItemProperty '$KEY').FaultGateOff)" | grep -a GATEOFF | sed 's/^/  /'
}

# P5 takes the same per-VM lock; QWT_VMLOCK_HELD is already exported, so it passes through.
p5(){  # <tag> -> "SG4=<v> SG2=<v> SG3=<v> SG9=<v>"
  rm -rf "$OUT/$1"
  bash mgmt/harness/p5-run.sh "$VM" "$OUT/$1" > "$OUT/$1.out" 2>&1
  local f="$OUT/$1/verdicts.tsv"
  [ -s "$f" ] || { echo "NORESULT"; return; }   # rule 14
  awk -F'\t' '{v[$1]=$3} END{printf "SG4=%s SG2=%s SG3=%s SG9=%s", v["SG4"], v["SG2"], v["SG3"], v["SG9"]}' "$f"
}
green(){ case "$1" in PASS|PASS-UNPROVEN) return 0;; *) return 1;; esac; }
field(){ echo "$1" | grep -ao "$2=[A-Za-z-]*" | cut -d= -f2; }

# ---------------------------------------------------------------- baseline, everything gated
log "=== BASELINE: FaultGateOff=0, all safeguards in force ==="
set_gate 0
BASE=$(p5 baseline)
log "  baseline: $BASE"
for c in SG4 SG2 SG3 SG9; do
  green "$(field "$BASE" $c)" || { log "ABORTING: $c is not green at baseline, so no later red is attributable."
    printf 'GATES\tbaseline\tINVALID-INSTRUMENT\t%s not green at baseline: %s\t%s\n' "$c" "$BASE" "$EV" >> "$V"; exit 1; }
done
log "  all four cells green with every safeguard in force"

# ---------------------------------------------------------------- one bit at a time
prove(){  # <bitname> <hex> <cell> <check> [cells allowed to move too]
  # The 5th argument exists because some properties are defended IN DEPTH and a single bit
  # cannot isolate them. Measured 2026-08-31: FI_GATE_START alone left `start-not-presented`
  # green because the genuine-open gate rejected the surface independently, and FI_GATE_MODE1
  # alone left SG4 green because the Mode-2 gate caught the probe. Clearing two clauses at once
  # is then the only way to falsify the property - but it necessarily moves the companion cell
  # as well, so that cell must be declared here rather than silently tolerated. Cells NOT
  # declared must still stay green: that is what keeps the red attributable.
  local name="$1" bit="$2" cell="$3" chk="$4"; shift 4
  local allowed=" $* "
  log "=== $name ($bit) -> expect $cell to go RED, the other three to stay green ==="
  set_gate "$bit"
  local A; A=$(p5 "armed-$name")
  log "  armed: $A"
  local tgt others_ok=yes o
  tgt=$(field "$A" "$cell")
  for o in SG4 SG2 SG3 SG9; do
    [ "$o" = "$cell" ] && continue
    green "$(field "$A" $o)" && continue
    case "$allowed" in
      *" $o "*) log "  NOTE: $o also moved ($(field "$A" $o)) - DECLARED as a companion of this bit" ;;
      *) others_ok=no; log "  NOTE: $o also moved ($(field "$A" $o)) - UNDECLARED, so the bypass is broader than this clause" ;;
    esac
  done
  set_gate 0
  local B; B=$(p5 "restored-$name")
  log "  restored: $B"
  local back; back=$(field "$B" "$cell")

  if [ "$tgt" = FAIL ] && [ "$others_ok" = yes ] && green "$back"; then
    log "  -> PROOF EARNED: $chk"
    printf 'GATES\t%s\tPASS\tSEEN TO FAIL 2026-08-31 via %s on ONE artifact: %s went FAIL with the bit set and %s again with it cleared, while the other three cells stayed green (armed: %s). Only a registry value changed between the two runs\t%s\n' \
      "$chk" "$name" "$cell" "$back" "$A" "$EV" >> "$V"
  elif [ "$tgt" = FAIL ] && [ "$others_ok" != yes ]; then
    log "  -> NOT PROVEN: $cell went red but so did another cell. A bypass that moves more than its"
    log "     own clause does not show THIS check detects THIS defect."
    printf 'GATES\t%s\tPASS-UNPROVEN\t%s went FAIL but the bypass was not specific (armed: %s)\t%s\n' "$chk" "$cell" "$A" "$EV" >> "$V"; rc=1
  elif ! green "$back"; then
    log "  -> INVALID-INSTRUMENT: $cell did not come back green after clearing the bit. The subject"
    log "     is dirty and the red cannot be attributed to the bypass."
    printf 'GATES\t%s\tINVALID-INSTRUMENT\t%s stayed %s after clearing the bit\t%s\n' "$chk" "$cell" "$back" "$EV" >> "$V"; rc=1
  else
    log "  -> NOT RED: setting $name did not make $cell fail (got '$tgt'). Either the bit is not"
    log "     wired to that clause, or the cell cannot detect the defect - a finding about the CHECK."
    printf 'GATES\t%s\tPASS-UNPROVEN\tsetting %s did not turn %s red (got %s)\t%s\n' "$chk" "$name" "$cell" "${tgt:-NONE}" "$EV" >> "$V"; rc=1
  fi
}

# MODE1 and MODE2 alone are NOT run any more: both were measured 2026-08-31 leaving their cell
# green because a second clause defends the same property. The combinations below are what
# actually falsify each property, with the companion cell declared.
prove FI_GATE_MODE1_2     0x3  SG4 or-fullscreen-never-mapped  SG2
prove FI_GATE_MODE2       0x2  SG2 borderless-fullscreen-gated
prove FI_GATE_START_NOCARD 0x14 SG9 start-not-presented
prove FI_DROP_CAPTIONED   0x20 SG3 windowed-fullscreen-allowed

log "=== clearing FaultGateOff and leaving the subject with every safeguard in force ==="
set_gate 0
log "=== finished rc=$rc ==="
log "REMINDER: the RELEASE binary must be restored before this subject is used for anything else."
exit $rc
