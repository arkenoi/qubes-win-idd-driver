#!/bin/bash
# FAIL-PROOF harness for the CAPTURE checks, using the compiled-in fault injector.
#
# WHY A DIAG BUILD IS UNAVOIDABLE HERE. `capture-thread-survives-resize` and
# `keyed-mutex-recovered` assert that the capture thread survives an abandoned keyed mutex. The
# natural reproducer does not produce the defect: measured 2026-08-31, 0x887a0026 occurred 12
# times across three mode changes and the thread never died once. So the checks have never been
# seen red, and under H5 every row citing them could only say PASS-UNPROVEN. `agent/gui-agent/
# faultinject.c` exists precisely to supply the missing red, and FI_CAPTURE_EXIT is a
# bug-for-bug reproduction of the condition: the capture thread returns WITHOUT signalling its
# error event, which is the exact shape of the CLAUDE.md prerequisite bug.
#
# WHY THIS PAIRING IS STRONGER THAN SG2's. SG2 needed two different binaries, so a sceptic could
# ask whether the red came from the gate removal or from some other difference between the
# builds. Here BOTH sides come from ONE artifact: the fault build with nothing armed is
# behaviourally identical to the release (every fault defaults off and needs an explicit registry
# value), so green->red->green is attributable to the registry value alone.
#
# THE EVIDENCE IS THE PIXELS, NOT THE LOG LINE. RND-8 counts thread deaths by grepping the agent
# log for /capture thread|thread exiting|giving up/, and FI_CAPTURE_EXIT's own trigger message
# ("the capture thread returns WITHOUT ...") CONTAINS "capture thread". So the log half of the
# red is partly self-referential - the check would be detecting the injector announcing itself.
# That is why this harness records the PIXEL half as the primary evidence: with the capture
# thread gone and no error signalled, dom0's view of the guest stops updating, and that is an
# output-side symptom the injector cannot fake (CLAUDE.md: "Judge output, not logs"). A red whose
# ONLY evidence is the fault's own log line is reported here as NOT PROVEN.
#
# RND-8 IS THE INSTRUMENT, called unchanged. Reimplementing its measurements here would create a
# second instrument needing its own validation; running the validated one three times does not.
#
#   mgmt/harness/failproof-faultinject.sh <vm> [outdir]
set -uo pipefail
cd /home/user/qubes-win-idd-driver
require_scripts(){ local m=""; for s in "$@"; do [ -f "$s" ] || m="$m $s"; done
  [ -z "$m" ] || { echo "FATAL: missing:$m" >&2; exit 2; }; }
require_scripts mgmt/harness/rnd8-resolution.sh

VM="${1:?usage: $0 <vm> [outdir]}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"   # one harness per guest; see vmlock.sh
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/FAILPROOF-fi-$VM}"
mkdir -p "$OUT"
q(){ QTEST_VM=$VM timeout -k 8 "${T:-300}" ./tools/qtest "$@" 2>/dev/null; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  r "cmd /c powershell -NoProfile -EncodedCommand $b"; }
log(){ echo "$(date -u +%H:%M:%S) fi[$VM]: $*" | tee -a "$OUT/failproof.log"; }
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT"); rc=0
KEY='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'

# ---------------------------------------------------------------- D-3: which binary is running?
# Rule 12: a swap can silently fail (the watchdog re-locks the file) and rule 13: state can be
# lost after a swap. Refuse to grade anything until the RUNNING image is the fault build. The
# marker is structural, not cosmetic: QGAFAULT-INIT is emitted by code that only exists when
# QGA_FAULT_INJECTION=1, so its presence cannot be faked by a release binary.
log "=== D-3: confirm the RUNNING agent is the fault-injection build ==="
MARK=$(psrun '$d=(Get-ItemProperty "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\").LogDir
$f=Get-ChildItem $d -Filter gui-agent-*.log | Sort LastWriteTime -Desc | Select -First 1
$n=@(Get-Content $f.FullName | Select-String -SimpleMatch "QGAFAULT-INIT").Count
$p=Get-Process gui-agent -EA SilentlyContinue
Write-Output ("FIMARK " + $n + " SHA " + (Get-FileHash $p.Path -Algorithm SHA256).Hash.ToLower())' \
  | grep -ao 'FIMARK [0-9]* SHA [0-9a-f]*' | head -1)
log "  $MARK"
n=$(echo "$MARK" | grep -ao 'FIMARK [0-9]*' | awk '{print $2}')
[ "${n:-0}" -gt 0 ] || {
  log "REFUSING: no QGAFAULT-INIT in the current agent log, so the running agent was NOT built"
  log "  with the injector. Every red below would be unattributable. Install the diag package first."
  exit 2; }
log "  fault build CONFIRMED running"

# ---------------------------------------------------------------- helper: one RND-8 pass
pass_verdict(){  # <tag> -> writes $OUT/<tag>/, echoes "died=N km=N rec=N pix=yes/no <verdict>"
  local tag="$1"
  rm -rf "$OUT/$tag"
  bash mgmt/harness/rnd8-resolution.sh "$VM" "$OUT/$tag" > "$OUT/$tag.out" 2>&1
  local vf="$OUT/$tag/verdicts.tsv"
  [ -s "$vf" ] || { echo "NORESULT"; return; }   # rule 14: absent verdicts = a killed run
  awk -F'\t' '$2=="keyed-mutex-recovered"{print $3}' "$vf" | head -1
}
detail(){ grep -aoE 'keyed mutex: [0-9]+ abandonment.*' "$OUT/$1/rnd8.log" 2>/dev/null | head -1; }
pixels(){ grep -aoiE 'pixels (changed|did not change)[^,]*' "$OUT/$1/rnd8.log" 2>/dev/null | head -3 | tr '\n' ';'; }

# ---------------------------------------------------------------- D-5: the paired GREEN, unarmed
log "=== D-5: GREEN pass - fault build, NOTHING armed (this is the control) ==="
psrun "New-Item -Path '$KEY' -Force | Out-Null
Remove-ItemProperty -Path '$KEY' -Name FaultCaptureExit -EA SilentlyContinue
Write-Output 'DISARMED'" | grep -a DISARMED | sed 's/^/  /'
G1=$(pass_verdict green-before)
log "  unarmed verdict: ${G1:-NONE}   $(detail green-before)"
log "  pixels: $(pixels green-before)"
if [ "$G1" != PASS-UNPROVEN ] && [ "$G1" != PASS ]; then
  log "ABORTING: the fault build is not green with nothing armed (got '${G1:-NONE}'). Either the"
  log "  build differs from the release in more than the injector, or the subject is dirty. A red"
  log "  in D-6 could not be attributed to the fault, so there is nothing to prove here."
  printf 'FI\tcapture-failproof\tINVALID-INSTRUMENT\tunarmed fault build did not go green (got %s)\t%s\n' "${G1:-NONE}" "$EV" >> "$V"
  exit 1
fi

# ---------------------------------------------------------------- agent restart, graded
# THE AGENT IS RESTARTED THROUGH THE SERVICE THAT OWNS IT, AND THE TURNOVER IS PROVEN (owner
# 2026-10-07; same shape as gate-preflight.sh's set_bits and failproof-gates.sh's set_gate - all
# three call guest/restart-gui-agent.ps1 through mgmt/harness/lifecycle-lib.sh, do not let them
# drift). History: D-6/D-9 used to be `Start-Service; Start-Sleep 25` (audit 2026-09-08: a timer,
# not a fact), then `Stop-Service; Get-Process gui-agent | Stop-Process -Force; Start-Service` with
# a poll for a pid not seen before. That kill BY NAME raced the watchdog's own relaunch of the
# agent it owns, the survivor was adopted, and RND-8 graded the PREVIOUS fault values - which this
# file then excused with an "old one survived Stop-Process" INVALID branch instead of fixing. Now
# the helper stops the QubesGuiWatchdog service (since 2026-10-03 its stop ends the agent IT
# started, by handle), starts it, and proves a NEW gui-agent-<ts>-<pid>.log with a live pid; a
# missing proof is RESTART INVALID-INSTRUMENT and restart_agent_checked grades it. Nothing is
# killed, nothing is found by name. The pixel witness is RND-8's own shot_hash (NOCAP/NOWIN are
# graded there).
source mgmt/harness/lifecycle-lib.sh
agent_restart_push || { log "FATAL: guest/restart-gui-agent.ps1 could not be pushed and proven on $VM - no agent restart is possible without it"; exit 2; }
restart_agent(){  # <ps-preamble> <marker-echo-line>
  psrun "$(agent_restart_ps "$1" "$2")" | grep -aE 'SVCSTOP|OLDLOG|WDSTART|AGENTPID|OLDALIVE|NEWLOG|RESTART|ARMED|DISARMED'
}

DISARM_PS="Remove-ItemProperty -Path '$KEY' -Name FaultCaptureExit -EA SilentlyContinue
Remove-ItemProperty -Path '$KEY' -Name FaultArmDelaySec -EA SilentlyContinue"

toggle_invalid(){  # <context> <reason> - one bounded disarm+restart so the subject is not left
                   # armed, the verdict row, and OUT (exit 3). Never a silent proceed: a toggle
                   # that did not take means every RND-8 pass after it measures the old state.
  log "-> INVALID-INSTRUMENT: $2 ($1)."
  log "   The agent was not restarted under the requested fault values, so RND-8 would grade a"
  log "   leftover state. One bounded disarm attempt, then the verdict; failproof not takeable."
  T=120 restart_agent "$DISARM_PS" "Write-Output 'DISARMED'" >/dev/null 2>&1 || true
  printf 'FI\tcapture-failproof\tINVALID-INSTRUMENT\t%s (%s); failproof not takeable this run\t%s\n' \
    "$2" "$1" "$EV" >> "$V"
  exit 3
}

# The marker echo must ROUND-TRIP or the toggle is graded, never assumed. Called only at top
# level (never in a pipe/substitution) so toggle_invalid's exit actually terminates the script.
restart_agent_checked(){  # <ps-preamble> <marker-echo-line> <marker> <context>
  local out; out=$(T=120 restart_agent "$1" "$2")
  if ! echo "$out" | grep -qa "$3"; then
    log "  no $3 echo from the guest ($4) - one bounded retry"
    out=$(T=120 restart_agent "$1" "$2")
    echo "$out" | grep -qa "$3" || toggle_invalid "$4" "the fault-value write never round-tripped (no $3 echo)"
  fi
  echo "$out" | sed 's/^/  /' | tee -a "$OUT/failproof.log"
  echo "$out" | grep -qa 'WDSTART Running' || \
    toggle_invalid "$4" "QubesGuiWatchdog not Running after Start-Service ($(echo "$out" | grep -a WDSTART | head -1))"
  # THE SERVICE RESTART MUST HAVE PRODUCED A NEW AGENT - a newer gui-agent-<ts>-<pid>.log with a
  # live pid, the old agent gone (guest/restart-gui-agent.ps1). Anything less (no new log, the old
  # agent surviving the service stop, the service not stopping) means the fault values were never
  # read by a fresh process, and RND-8 would grade the old state: INVALID-INSTRUMENT, never a guess.
  local why
  if ! why=$(agent_restart_grade "$out"); then
    toggle_invalid "$4" "the service restart did not produce a new agent: $why; the toggle never took"
  fi
}

# ---------------------------------------------------------------- D-6: arm the fault, expect RED
# ArmDelaySec is lowered so the one-shot is live by the time RND-8 drives its first mode change;
# the default 60 s exists to keep faults out of the daemon handshake, and RND-8 takes longer than
# that to reach a resize, but relying on that timing coincidence would make the proof flaky.
log "=== D-6: arm FaultCaptureExit=1 and re-run the SAME instrument ==="
restart_agent_checked "Set-ItemProperty -Path '$KEY' -Name FaultCaptureExit -Value 1 -Type DWord
Set-ItemProperty -Path '$KEY' -Name FaultArmDelaySec -Value 20 -Type DWord" \
  "Write-Output ('ARMED ' + (Get-ItemProperty '$KEY').FaultCaptureExit)" ARMED "arming FaultCaptureExit"
R1=$(pass_verdict red)
log "  ARMED verdict: ${R1:-NONE}   $(detail red)"
log "  pixels: $(pixels red)"

# ---------------------------------------------------------------- D-9: disarm and prove green again
log "=== D-9: disarm, restart, and re-run - the paired green must come back ==="
restart_agent_checked "$DISARM_PS" "Write-Output 'DISARMED'" DISARMED "disarming after the armed run"
G2=$(pass_verdict green-after)
log "  disarmed verdict: ${G2:-NONE}   $(detail green-after)"

# ---------------------------------------------------------------- verdict
pixred=$(pixels red)
indep=no
echo "$pixred" | grep -qi 'did not change' && indep=yes

log "=== RESULT: green=${G1} armed=${R1} green-again=${G2} independent-pixel-evidence=$indep ==="
if [ "$R1" = FAIL ] && [ "$G2" != FAIL ] && [ "$indep" = yes ]; then
  for chk in keyed-mutex-recovered capture-thread-survives-resize; do
    log "  -> PROOF EARNED: $chk"
    printf 'FI\t%s\tPASS\tSEEN TO FAIL via FI_CAPTURE_EXIT on the fault build: unarmed=%s, armed=FAIL, disarmed=%s. Same binary throughout - only the registry value changed. INDEPENDENT evidence: dom0 pixels stopped changing (%s), so the red is not merely the injector logging its own name\t%s\n' \
      "$chk" "$G1" "$G2" "$pixred" "$EV" >> "$V"
  done
elif [ "$R1" = FAIL ] && [ "$indep" != yes ]; then
  log "  -> NOT PROVEN: the checks went red, but the only evidence was the log grep, which"
  log "     FI_CAPTURE_EXIT's own message satisfies by containing 'capture thread'. Without the"
  log "     pixels stopping, this red does not demonstrate the check detects the CONDITION."
  printf 'FI\tcapture-failproof\tPASS-UNPROVEN\tred was log-only (self-referential); pixels kept changing\t%s\n' "$EV" >> "$V"; rc=1
elif [ "$G2" = FAIL ]; then
  log "  -> INVALID-INSTRUMENT: still red after disarming. The subject is dirty; the D-6 red"
  log "     cannot be attributed to the fault. Rebuild before grading anything else on it."
  printf 'FI\tcapture-failproof\tINVALID-INSTRUMENT\tstill FAIL after disarm - subject dirty\t%s\n' "$EV" >> "$V"; rc=1
else
  log "  -> NOT RED: arming FI_CAPTURE_EXIT did not make the checks fail. Either the fault did not"
  log "     fire (look for 'QGAFAULT FI_CAPTURE_EXIT firing' in the agent log) or the checks cannot"
  log "     detect a dead capture thread - which would be a finding about the CHECKS."
  printf 'FI\tcapture-failproof\tPASS-UNPROVEN\tarming the fault did not turn the checks red (armed verdict=%s)\t%s\n' "${R1:-NONE}" "$EV" >> "$V"; rc=1
fi

log "=== finished rc=$rc ==="
log "REMINDER: the RELEASE binary must be restored before this subject is used for anything else."
exit $rc
