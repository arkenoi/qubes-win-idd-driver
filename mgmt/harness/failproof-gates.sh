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
#   bits                     cell  check earned
#   MODE1|MODE2      0x3     SG4   or-fullscreen-never-mapped   (companion: SG2)
#   MODE2            0x2     SG2   borderless-fullscreen-gated  - ALREADY EARNED, not re-run
#   START|NOCARD     0x14    SG9   start-not-presented          (defended in depth)
#   FI_DROP_CAPTIONED 0x20   SG3   windowed-fullscreen-allowed
#
# Combinations, not single bits, because two of these properties are defended IN DEPTH - see the
# comment on prove(). FI_GATE_SHELLOVERLAY (0x8) and FI_DROP_SHELLSURFACE (0x40) are not here:
# their cells live in rnd-shell-surfaces.sh, which must be audited for the rule-16 query pattern
# before its verdicts are trusted.
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
QTEST_BIN="${QTEST_BIN:-./tools/qtest}"       # overridable ONLY so the degraded-guest paths are provable off-rig
P5_RUNNER="${P5_RUNNER:-mgmt/harness/p5-run.sh}"
q(){ QTEST_VM=$VM timeout -k 8 "${T:-300}" "$QTEST_BIN" "$@" 2>/dev/null; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  r "cmd /c powershell -NoProfile -EncodedCommand $b"; }
log(){ echo "$(date -u +%H:%M:%S) gates[$VM]: $*" | tee -a "$OUT/failproof.log"; }
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT"); rc=0
KEY='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'

# LIVENESS BOUND (2026-09-04). The prove cycles repeat arm + agent-restart, and that cycling can
# degrade the guest's qrexec/session (measured in the P5 preflight at 0x3 -> 0x14 -> 0x20: by
# 0x20 the guest stopped answering and the sequence stalled >12 min with no verdict until an
# external watchdog killed it). A guest that stops answering mid-sequence is a GRADED outcome -
# INVALID-INSTRUMENT, the failproof is not takeable this run - never a condition to out-wait:
# without this bound three 28-minute cycles would grind against a dead guest until the step
# timeout killed the run with NO verdicts.tsv at all (rule 14's worst shape). Nothing here
# weakens the responsive path: an ALIVE guest still runs every armed->RED->cleared->green flip.
alive(){ T=30 q run 'cmd /c echo LIVE' | grep -qa LIVE; }

guest_gone(){  # <context> <check-column> - one bounded clear attempt, the verdict row, and OUT (exit 3)
  log "guest gone - one bounded FaultGateOff=0 clear attempt, then the verdict"
  T=120 set_gate 0 >/dev/null 2>&1 || true   # 120: set_gate may now poll up to 45 s for the agent PID
  log "-> INVALID-INSTRUMENT: guest unresponsive during the fault-toggle sequence ($1)."
  log "   The repeated arm+agent-restart cycle degraded the session; a dead guest is a graded"
  log "   outcome, never a wait state. Failproof not takeable this run - the affected checks'"
  log "   PASS rows stay PASS-UNPROVEN (P5-7). The subject may be left with FaultGateOff armed"
  log "   and MUST be restored before it re-enters service."
  printf 'GATES\t%s\tINVALID-INSTRUMENT\tguest unresponsive during the fault-toggle sequence (arm+agent-restart degraded the session; %s); failproof not takeable this run\t%s\n' \
    "${2:-sequence}" "$1" "$EV" >> "$V"
  exit 3
}

require_alive(){  # <context> <check-column> - 3 bounded probes, then the graded exit
  local i; for i in 1 2 3; do
    alive && return 0
    log "  liveness probe $i/3: guest did not answer ($1)"
    sleep 5
  done
  guest_gone "$1" "${2:-sequence}"
}

# ---------------------------------------------------------------- the running binary must have the bits
# `gateoff=` in the startup banner exists only in a build carrying FiGateOff. An older fault build
# would silently ignore FaultGateOff and every armed run would come back green - which would look
# like "the gates all hold" and would in fact be "the bypass was never in force".
require_alive "at sequence entry, before the banner check" gates-entry
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

# AGENT RESTART WAITS ON A FACT, NOT A TIMER (audit 2026-09-08; same shape as gate-preflight.sh's
# set_bits - do not let the two drift). This used to be `Start-Service; Start-Sleep 25`.
# Start-Service returning says nothing about the agent: the watchdog reports RUNNING at once and
# spawns gui-agent from its own 1 s loop, so a slow session had no agent yet at 25 s and p5 graded
# a stale state, while a fast guest idled ~20 s per toggle (x7 toggles per run). Worse, -EA
# SilentlyContinue hid a watchdog that never started, and any gui-agent left over from before the
# kill then stood in for the "restarted" one. Now: the pre-kill PIDs are recorded and only a
# gui-agent NOT among them counts (bounded 45 s poll), the service status is echoed for the caller
# to grade, and the window-map witness is p5-run.sh's own control poll.
set_gate(){  # <hex-or-0>
  psrun "New-Item -Path '$KEY' -Force | Out-Null
Set-ItemProperty -Path '$KEY' -Name FaultGateOff -Value $1 -Type DWord
\$old = @(Get-Process gui-agent -EA SilentlyContinue | ForEach-Object Id)
Stop-Service QubesGuiWatchdog -Force -EA SilentlyContinue; Start-Sleep 3
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force; Start-Sleep 2
\$wdErr = ''
try { Start-Service QubesGuiWatchdog -EA Stop } catch { \$wdErr = \$_.Exception.Message }
\$wd = (Get-Service QubesGuiWatchdog -EA SilentlyContinue).Status
Write-Output ('WDSTART ' + \$wd + ' ' + \$wdErr)
\$new = 0; \$sw = [Diagnostics.Stopwatch]::StartNew()
while (\$sw.Elapsed.TotalSeconds -lt 45) {
  \$p = @(Get-Process gui-agent -EA SilentlyContinue | Where-Object { \$old -notcontains \$_.Id })
  if (\$p.Count -gt 0) { \$new = \$p[0].Id; break }
  Start-Sleep -Milliseconds 500
}
Write-Output ('AGENTPID ' + \$new + ' after ' + [int]\$sw.Elapsed.TotalSeconds + 's')
\$stillOld = @(Get-Process gui-agent -EA SilentlyContinue | Where-Object { \$old -contains \$_.Id })
Write-Output ('OLDALIVE ' + \$stillOld.Count)
Write-Output ('GATEOFF ' + (Get-ItemProperty '$KEY').FaultGateOff)" | grep -aE 'GATEOFF|WDSTART|AGENTPID|OLDALIVE'
}

watchdog_failed(){  # <context> <check-column> - the watchdog is not Running after Start-Service:
                    # the toggle never restarted the agent, so p5 would grade a leftover state.
                    # INVALID-INSTRUMENT (exit 3), never a silent proceed.
  log "watchdog did not start - one bounded FaultGateOff=0 clear attempt, then the verdict"
  T=120 set_gate 0 >/dev/null 2>&1 || true
  log "-> INVALID-INSTRUMENT: QubesGuiWatchdog not Running after Start-Service ($1)."
  log "   The agent was never restarted under the requested bits, so any cell would grade a"
  log "   leftover state, not the bit. Failproof not takeable this run."
  printf 'GATES\t%s\tINVALID-INSTRUMENT\tQubesGuiWatchdog not Running after Start-Service (%s); failproof not takeable this run\t%s\n' \
    "${2:-sequence}" "$1" "$EV" >> "$V"
  exit 3
}

# The GATEOFF echo must ROUND-TRIP or the toggle is graded, never assumed. Called only at top
# level (never in a pipe/substitution) so guest_gone's exit actually terminates the script.
set_gate_checked(){  # <hex-or-0> <context> <check-column>
  local out; out=$(set_gate "$1")
  if ! echo "$out" | grep -qa GATEOFF; then
    log "  no GATEOFF echo from the guest ($2)"
    require_alive "$2" "$3"
    out=$(set_gate "$1")   # answered liveness - one bounded retry, then grade
    echo "$out" | grep -qa GATEOFF || \
      guest_gone "$2: guest answers liveness but the FaultGateOff write never round-trips" "$3"
  fi
  echo "$out" | sed 's/^/  /'
  echo "$out" | grep -qa 'WDSTART Running' || \
    watchdog_failed "$2: $(echo "$out" | grep -a WDSTART | head -1)" "$3"
  # NO NEW AGENT + THE OLD ONE STILL ALIVE IS AN INVALID INSTRUMENT, NOT AN ANOMALY.
  # Stop-Process is best-effort (-Force, no wait); if the old gui-agent survived it, the
  # restarted watchdog ADOPTS it (watchdog.c) and the guest keeps running under the PREVIOUS
  # gate bits. p5 would then grade cells the toggle never reached and this script would report
  # "armed went red / did not go red" for a measurement of the old state. Only "no new agent
  # AND no old agent" is the benign still-starting case worth a mere log line.
  if echo "$out" | grep -qa 'AGENTPID 0 '; then
    if echo "$out" | grep -qaE 'OLDALIVE [1-9]'; then
      log "-> INVALID-INSTRUMENT: no NEW gui-agent within 45 s and the OLD one is STILL RUNNING ($2)."
      log "   The watchdog adopted the surviving agent, so FaultGateOff=$1 was never applied to a"
      log "   fresh process. Anything graded from here would describe the previous state."
      T=120 set_gate 0 >/dev/null 2>&1 || true   # bounded clear so the subject is not left armed
      printf 'GATES\t%s\tINVALID-INSTRUMENT\tno new gui-agent and the old one survived Stop-Process (%s); the toggle never took\t%s\n' \
        "${3:-sequence}" "$2" "$EV" >> "$V"
      exit 3
    fi
    log "  ANOMALY: watchdog Running, no NEW gui-agent within 45 s, and the old one IS gone ($2) - grading p5's control poll, not a guess"
  fi
}

# P5 takes the same per-VM lock; QWT_VMLOCK_HELD is already exported, so it passes through.
p5(){  # <tag> -> "SG4=<v> SG2=<v> SG3=<v> SG9=<v>"
  rm -rf "$OUT/$1"
  bash "$P5_RUNNER" "$VM" "$OUT/$1" > "$OUT/$1.out" 2>&1
  local f="$OUT/$1/verdicts.tsv"
  [ -s "$f" ] || { echo "NORESULT"; return; }   # rule 14
  awk -F'\t' '{v[$1]=$3} END{printf "SG4=%s SG2=%s SG3=%s SG9=%s", v["SG4"], v["SG2"], v["SG3"], v["SG9"]}' "$f"
}

# rule 14 refined: an empty suite is DATA only while the guest still answers. NORESULT from a
# guest that no longer answers liveness is the degraded-session case - grade it and stop.
noresult_check(){  # <suite-result> <context> <check-column>
  [ "$1" = NORESULT ] || return 0
  alive && return 0
  guest_gone "$2: the p5 suite produced no verdicts and the guest no longer answers" "$3"
}
green(){ case "$1" in PASS|PASS-UNPROVEN) return 0;; *) return 1;; esac; }
field(){ echo "$1" | grep -ao "$2=[A-Za-z-]*" | cut -d= -f2; }

# ---------------------------------------------------------------- baseline, everything gated
log "=== BASELINE: FaultGateOff=0, all safeguards in force ==="
set_gate_checked 0 "clearing the gate for baseline" baseline
BASE=$(p5 baseline)
log "  baseline: $BASE"
noresult_check "$BASE" "baseline" baseline
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
  set_gate_checked "$bit" "arming $name" "$chk"
  local A; A=$(p5 "armed-$name")
  log "  armed: $A"
  noresult_check "$A" "armed run of $name ($bit)" "$chk"
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
  set_gate_checked 0 "clearing $name after the armed run" "$chk"
  local B; B=$(p5 "restored-$name")
  log "  restored: $B"
  noresult_check "$B" "restored run of $name" "$chk"
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
prove FI_GATE_START_NOCARD 0x14 SG9 start-not-presented
prove FI_DROP_CAPTIONED   0x20 SG3 windowed-fullscreen-allowed

log "=== clearing FaultGateOff and leaving the subject with every safeguard in force ==="
set_gate_checked 0 "final clear - the subject must not leave this script armed" gates-final-clear
log "=== finished rc=$rc ==="
log "REMINDER: the RELEASE binary must be restored before this subject is used for anything else."
exit $rc
