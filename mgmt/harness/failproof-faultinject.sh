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
# THE EVIDENCE IS THE CONDITION ITSELF, READ FROM THE OS - NOT A LOG LINE, AND NOT THE PIXELS. The
# checks go red on the agent's QGAPERF frame counter first (rnd8-resolution.sh, since 47b3be25): a
# count of produced frames, which the injector's own announcement cannot satisfy. The independent
# witness that the CONDITION held is the agent process's thread list: the
# capture thread the running agent announced (`QGATHREAD role=capture tid=N`) is GONE from that
# process after the armed pass and PRESENT after both unarmed ones. Until 2026-11-12 the witness was
# dom0's pixels, on the premise that a dead duplication worker freezes dom0's view. It does not.
# MEASURED 2026-11-12 on win11-acc at FIXED geometry, after "QGAFAULT FI_CAPTURE_EXIT firing": QGAPERF
# stayed 3 -> 3 while a WM_SETTEXT into notepad reached dom0 ("RND8 848019726" -> "RND8 853676904"),
# because the main thread kept sending DAMAGE from window events and dom0 refreshes from the display
# framebuffer, which needs no capture thread (docs/ADR-capture.md: nothing per-window goes through the
# duplication). The pixels moved armed in every run, so the proof could never be earned (Jev
# witness=thread_witness 1.00). They are still logged, as information.
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
# A contaminated subject is refused BEFORE any work: this script's default output dir carries no
# run-id, so a second attempt would otherwise append to the first attempt's artefacts and be read
# back as one run. Pass a fresh outdir to run again.
declare -F attempt_dir >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/primitives.sh"
attempt_dir "$OUT" || exit 1

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
# THE PIXEL HALF IS READ FROM RND-8'S VERDICT ROWS, NOT ITS PROSE. rnd8-resolution.sh writes one
#   RND-8 <TAB> pixels-change-after-resize-<mode> <TAB> PASS-UNPROVEN|FAIL|INVALID-INSTRUMENT <TAB> <detail>
# row per mode into verdicts.tsv - the same artifact pass_verdict already reads for the keyed-mutex row.
# Until 2026-11-01 this grepped the LOG for 'pixels (changed|did not change)' and the verdict below
# demanded 'did not change', a phrase RND-8 has never written (its FAIL line says "identical pixels ...
# capture is FROZEN", since db453097 of 2026-08-31 - the day this file was written, 1ac9c1dc): the
# independent half could never be seen, so this suite could never earn its proof, only PASS-UNPROVEN
# rc=1. The row is the contract; the prose may change. Since 2026-11-12 the rows are information only
# (the header says why); the witness is capture_thread below.
pixrows(){ awk -F'\t' '$2 ~ /^pixels-change-after-resize-/ { sub(/^pixels-change-after-resize-/, "", $2); printf "%s=%s;", $2, $3 }' "$OUT/$1/verdicts.tsv" 2>/dev/null; }
pixels(){ pixrows "$1"; }
# THE WITNESS: the capture thread the RUNNING agent announced, looked up in that process's thread list,
# read right after a pass and before the next restart replaces the agent. "CAPTHREAD alive|gone tid= pid="
# or "CAPTHREAD none" (no capture thread announced) / "noagent" (the process is gone) / nothing (no
# answer). A recycled thread id can only read alive - the direction that withholds the proof.
capture_thread(){ psrun "$(agent_lines_ps)"$'\n''$t=""; foreach($l in $agentlines){ if($l -match "QGATHREAD role=capture tid=(\d+)"){ $t=$Matches[1] } }
if(-not $t){ Write-Output "CAPTHREAD none"; return }
$p=Get-Process -Id ([int]$agentpid) -EA SilentlyContinue
if(-not $p){ Write-Output "CAPTHREAD noagent"; return }
$n=@($p.Threads | Where-Object { $_.Id -eq [int]$t }).Count
Write-Output ("CAPTHREAD " + $(if($n){"alive"}else{"gone"}) + " tid=" + $t + " pid=" + $agentpid)' \
  | grep -aoE 'CAPTHREAD [a-z]+( tid=[0-9]+ pid=[0-9]+)?' | head -1; }

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
# killed, nothing is found by name. RND-8's own pixel rows (shot_hash; NOCAP/NOWIN graded there) are
# logged as information; the witness is capture_thread, read before each restart replaces the agent.
source mgmt/harness/lifecycle-lib.sh
# RND-8 GRADES PIXELS, so every restart here waits for the agent to be SERVING, not merely alive
# (lifecycle-lib.sh -> restart-gui-agent.ps1 -WaitServing; 0 is the default everywhere else).
# MEASURED 2026-10-16 on win11-nfy: the unarmed baseline ran straight after a DISARMED restart
# and came back INVALID-INSTRUMENT with 'keyed mutex: 3 abandonment(s), 22 RecreateDuplication,
# 5 thread death(s)' and an EMPTY pixels field - the capture pipeline thrashing because dom0's
# gui-daemon had not attached yet. The suite then aborted: 'the fault build is not green with
# nothing armed ... either the build differs from the release in more than the injector, or the
# subject is dirty'. Neither was true; the agent was simply not serving yet.
export AGENT_RESTART_WAIT_SERVING="${AGENT_RESTART_WAIT_SERVING:-120}"
agent_restart_push || { log "FATAL: guest/restart-gui-agent.ps1 could not be pushed and proven on $VM - no agent restart is possible without it"; exit 2; }
restart_agent(){  # <ps-preamble> <marker-echo-line>
  psrun "$(agent_restart_ps "$1" "$2")" | grep -aE 'SVCSTOP|OLDLOG|WDSTART|AGENTPID|OLDALIVE|NEWLOG|SERVINGWAIT|RESTART|ARMED|DISARMED'
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
  # AND IT MUST BE SERVING. An agent dom0 has not attached to maps nothing, so RND-8's pixels are
  # empty and the capture pipeline churns (RecreateDuplication) - which reads as a dirty subject or
  # a wrong build, the two things this suite's abort message blames. Named, not guessed.
  local _sv
  _sv=$(echo "$out" | grep -aoE 'serving=[a-z-]+' | tail -1 | cut -d= -f2)
  [ "${_sv:-none}" = connected ] || \
    toggle_invalid "$4" "the restarted agent never reached serving=connected (serving=${_sv:-none}); RND-8 grades pixels and would see none"
}

# ---------------------------------------------------------------- QGAPERF needs the debug feature
# RND-8's keyed-mutex row grades FRAME LIVENESS from the agent's QGAPERF seq lines, and the agent
# emits them only when dom0 sets service.gui-agent-debug (perf.c: g_PerfEnabled is read at Init, so
# the value takes at the next agent start; the feature also raises the log level to Debug). Nothing
# in the chain set it, so every pass that reached the row came back INVALID-INSTRUMENT "no QGAPERF
# seq available" (2026-10-30 and 2026-10-31; the suite is in none of the 46 receipts).
# THE HOLD NOW LIVES IN lifecycle-lib.sh (agent_debug_hold / agent_debug_restore). failproof-gates.sh
# needs exactly the same precondition for a different reason - its SG4/SG2 discriminators are the
# agent's two LogDebug fullscreen deny lines - and had NO hold at all, so both cells graded
# INVALID-VACUOUS there while this file quietly had the answer. One implementation, inherited by
# both; the proven restart below is still what makes the value take, and the helper restores the
# subject's previous value at EXIT exactly as this block did. Called at top level, never inside
# $( ) or a pipeline: it keeps the EXIT trap and the previous value in shell state, and a subshell
# would discard both while the qvm-features write still landed.
# DE-DUPLICATION ONLY, and the plan's "assert" half is SATISFIED HERE BY PROPAGATION rather than by
# a new check. The chain, end to end: if the hold fails the feature is off, so rnd8-resolution.sh
# takes its blind arm (`alive = unknown`, QGAPERF produced no seq) at :277 - ordered BEFORE the
# `alive = no` arm at :282 and before the only PASS arm at :287 - and writes keyed-mutex-recovered
# INVALID-INSTRUMENT at :281. pass_verdict echoes that row verbatim into G1 (:214), and the guard at
# :217 is a WHITELIST (`!= PASS-UNPROVEN && != PASS`), so ANY non-green value aborts and THIS suite
# writes its OWN `FI capture-failproof INVALID-INSTRUMENT` row at :221 with rc=1. So a vacuous pass
# is unreachable in BOTH row families - by branch ORDER in the child, by a whitelist here - and
# because it is a whitelist and not a blacklist, a blind verdict value added to RND-8 later still
# aborts instead of slipping through. That is why no `exit 2` is added: it would trade a graded row
# that names WHICH half went blind for a bare log line. Reading only the child's half of this chain
# is how the earlier version of this comment came to claim less than the code guarantees.
# rnd8-resolution.sh never sets the feature itself (:278 only ASKS whether it is on), so this hold is
# what establishes it for all three child runs, and it sits before the first restart_agent_checked
# (:212) because perf.c reads the feature once at Init.
agent_debug_hold "$VM" || log "WARN could not hold service.gui-agent-debug on $VM - no QGAPERF seq: RND-8 and this suite both grade INVALID-INSTRUMENT"
log "  service.gui-agent-debug: was '${_LC_DEBUG_WAS:-unset}', now '$(qvm-features "$VM" service.gui-agent-debug 2>/dev/null)'"

# ---------------------------------------------------------------- D-5: the paired GREEN, unarmed
log "=== D-5: GREEN pass - fault build, NOTHING armed (this is the control) ==="
# A PROVEN RESTART, NOT A BARE REGISTRY WRITE. Until 2026-11-01 this block sat ABOVE
# restart_agent_checked's definition and restarted nothing: the baseline graded whichever agent
# happened to be running - one that had read neither the fault keys' absence nor the debug feature,
# so QGAPERF was off and the row could only come back INVALID-INSTRUMENT. Same helper, same proof,
# same serving wait as D-6.
restart_agent_checked "New-Item -Path '$KEY' -Force | Out-Null
$DISARM_PS" "Write-Output 'DISARMED'" DISARMED "disarming for the unarmed baseline"
G1=$(pass_verdict green-before)
log "  unarmed verdict: ${G1:-NONE}   $(detail green-before)"
log "  pixels: $(pixels green-before)"
TW1=$(capture_thread)
log "  capture thread: ${TW1:-no answer}"
if [ "$G1" != PASS-UNPROVEN ] && [ "$G1" != PASS ]; then
  log "ABORTING: the fault build is not green with nothing armed (got '${G1:-NONE}'). Either the"
  log "  build differs from the release in more than the injector, or the subject is dirty. A red"
  log "  in D-6 could not be attributed to the fault, so there is nothing to prove here."
  printf 'FI\tcapture-failproof\tINVALID-INSTRUMENT\tunarmed fault build did not go green (got %s)\t%s\n' "${G1:-NONE}" "$EV" >> "$V"
  exit 1
fi

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
TW2=$(capture_thread)
log "  capture thread: ${TW2:-no answer}"

# ---------------------------------------------------------------- D-9: disarm and prove green again
log "=== D-9: disarm, restart, and re-run - the paired green must come back ==="
restart_agent_checked "$DISARM_PS" "Write-Output 'DISARMED'" DISARMED "disarming after the armed run"
G2=$(pass_verdict green-after)
log "  disarmed verdict: ${G2:-NONE}   $(detail green-after)"
log "  pixels: $(pixels green-after)"
TW3=$(capture_thread)
log "  capture thread: ${TW3:-no answer}"

# ---------------------------------------------------------------- verdict
# THE WITNESS IS A CONTRAST, NOT A RED ALONE. "The capture thread is gone under the fault" means
# nothing unless it is ALIVE with nothing armed, on each side of it: a control that reads anything but
# alive (gone, none, noagent, no answer) is blind for a reason that has nothing to do with the fault.
# The same contrast guarded the pixel witness, and caught it: remainder-bafe660fa326 (2026-11-01) read
# FROZEN on all nine pixel rows of all three passes while QGAPERF discriminated (133->145 green, 15->15
# red, 97->110 green-again), and a reader keyed on the red pass alone would have called that PROOF
# EARNED. So: independent evidence = gone after the armed pass AND alive after BOTH unarmed ones; a
# control that is not alive is the witness's own INVALID-INSTRUMENT, graded before anything else.
indep=no
case "$TW1|$TW3" in
  "CAPTHREAD alive "*"|CAPTHREAD alive "*) case "$TW2" in "CAPTHREAD gone "*) indep=yes ;; esac ;;
  *) indep=blind ;;
esac

log "=== RESULT: green=${G1} armed=${R1} green-again=${G2} independent-thread-evidence=$indep ==="
if [ "$R1" = FAIL ] && [ "$G2" != FAIL ] && [ "$indep" = yes ]; then
  for chk in keyed-mutex-recovered capture-thread-survives-resize; do
    log "  -> PROOF EARNED: $chk"
    printf 'FI\t%s\tPASS\tSEEN TO FAIL via FI_CAPTURE_EXIT on the fault build: unarmed=%s, armed=FAIL, disarmed=%s. Same binary throughout - only the registry value changed. INDEPENDENT evidence: the capture thread the agent announced was gone from its process after the armed pass (%s) and alive after both unarmed ones (%s / %s), so the red is the condition itself\t%s\n' \
      "$chk" "$G1" "$G2" "$TW2" "$TW1" "$TW3" "$EV" >> "$V"
  done
elif [ "$indep" = blind ]; then
  log "  -> INVALID-INSTRUMENT: the thread witness did not read alive with NOTHING armed (green-before: ${TW1:-no answer}"
  log "     green-after: ${TW3:-no answer}). A control whose capture thread is not alive, or could not be read, says"
  log "     nothing about the fault, so no red here is attributable."
  printf 'FI\tcapture-failproof\tINVALID-INSTRUMENT\tthread witness did not read alive in an unarmed control (before: %s after: %s) - blind, nothing attributable\t%s\n' "${TW1:-no answer}" "${TW3:-no answer}" "$EV" >> "$V"; rc=1
elif [ "$R1" = FAIL ] && [ "$indep" != yes ]; then
  log "  -> NOT PROVEN: the checks went red (the QGAPERF frame counter stopped), but the thread witness"
  log "     did not read the capture thread gone after the armed pass (${TW2:-no answer}), so this red is"
  log "     not shown to be the CONDITION the checks exist for."
  printf 'FI\tcapture-failproof\tPASS-UNPROVEN\tred from the frame counter, but the armed thread witness read %s, not gone\t%s\n' "${TW2:-no answer}" "$EV" >> "$V"; rc=1
elif [ "$G2" = FAIL ]; then
  log "  -> INVALID-INSTRUMENT: still red after disarming. The subject is dirty; the D-6 red"
  log "     cannot be attributed to the fault. Rebuild before grading anything else on it."
  printf 'FI\tcapture-failproof\tINVALID-INSTRUMENT\tstill FAIL after disarm - subject dirty\t%s\n' "$EV" >> "$V"; rc=1
else
  log "  -> NOT RED: arming FI_CAPTURE_EXIT did not make the checks fail. Either the fault did not"
  log "     fire (look for 'QGAFAULT FI_CAPTURE_EXIT firing' in the agent log) or the checks cannot"
  log "     detect a dead capture thread - which would be a finding about the CHECKS. The armed thread"
  log "     witness tells the two apart: ${TW2:-no answer} (gone = the fault fired and the checks missed it)."
  printf 'FI\tcapture-failproof\tPASS-UNPROVEN\tarming the fault did not turn the checks red (armed verdict=%s, armed thread witness=%s)\t%s\n' "${R1:-NONE}" "${TW2:-no answer}" "$EV" >> "$V"; rc=1
fi

log "=== finished rc=$rc ==="
log "REMINDER: the RELEASE binary must be restored before this subject is used for anything else."
exit $rc
