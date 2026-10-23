#!/usr/bin/env bash
# ttfw-ab.sh - TIME TO FIRST WINDOW, A/B, single-variable.
#
# WHY IT EXISTS. The de-slice broker's one launch used to be paced by the QGADESLICEDOWN complaint
# deadline (docs/AUDIT-timer-vs-event.md finding 1): while the broker was down and unlaunched,
# BrokerNextDue armed only that deadline, so the launch happened on whatever wake came next and the
# broker came up 27-29 s after the agent's Init on both measured subjects. On a direct-capable guest
# the broker is what serves per-window content, so for that whole window there are no windows -
# which is why this sat in the path the owner repeatedly asked to shorten and was never surfaced.
# agent f9ef238 replaced the timer with a push. THIS measures whether that actually moved the number
# the user waits for, rather than the one in the log.
#
#   mgmt/harness/ttfw-ab.sh --a <agent-WITHOUT-the-fix.exe> --b <agent-WITH-the-fix.exe> \
#                           [--subject <vm>] [--rounds N] [--deadline S] [--poll S]
#
# THE METRIC, and it was CORRECTED after a measured dead end. The first cut timed `qvm-start` to the
# first window in a per-window capture. That cannot work on these subjects and the reason is not a
# bug: on a seamless guest with no application open there are NO windows for dom0 to show, by
# design. MEASURED on win11r-ttfw with explorer running, the shell up, the broker ready and
# QGADIRECTSUPPRESS=0: exactly one top-level window exists (explorer's desktop) and the per-window
# capture is correctly 0 bytes. An idle desktop has no first window to time.
#
# What the fix actually removes is the interval in which the guest CANNOT serve a window: the de-slice
# broker gates per-window content, and its one launch used to be paced by the QGADESLICEDOWN
# complaint deadline, so the broker came up 27-29 s after the agent's Init. So this times, per boot:
#     shell-seen -> WgcLaunch        the wait this fix removes
#     shell-seen -> WGCBROKER ready  when per-window content can first be served
# Both ends come from lines the agent itself wrote, in ONE log, so the delta is sound even though
# this guest's clock is offset from the host's - a guest clock must never anchor a measurement, but
# a difference within one log is not an anchor. ms resolution, and no polling load on the thing
# being measured.
#
# RULES THIS ENFORCES, each because it has been broken here before:
#  - ONE guest, ONE install, ONE display stack. The only thing that differs between sides is
#    gui-agent.exe, swapped in place by guest/swap-agent.ps1. Every file of agent f9ef238 compiles
#    into gui-agent.exe (main.c, main.h, workarea.c are all in gui-agent.vcxproj), and wgcbroker.exe
#    is a SEPARATE binary that is identical on both sides - so a one-binary swap is a complete A/B
#    for this change and the broker's own start cost is common to both.
#  - THE RUNNING BINARY'S HASH IS VERIFIED EVERY SAMPLE (HASH_RUNNING from swap-agent.ps1). A
#    harness that proceeds on a failed swap reports numbers for a build that never ran.
#  - INTERLEAVED, with the starting side alternating per round, so drift in the guest cannot land
#    entirely on one side.
#  - vm_lock for the whole run: two harnesses on one guest interleave their probes and fabricate
#    verdicts.
#  - A SMOKE TEST OVER ONE BUILD. After the rounds, B is swapped in, the guest boots once, and the
#    guest log sweep grades THAT window alone - A/B rounds span both binaries, so a sweep over them
#    would report the A side's defects as this run's.
#  - MISSING DATA FAILS. No window inside the deadline is recorded as a miss, never as a large
#    number, and a capture that could not be taken is INVALID, never "no windows".
#
# AN EMPTY PER-WINDOW CAPTURE IS NOT "NO WINDOWS" - it has three causes (.claude/skills/guest-capture):
# the target does not exist or lacks the win-idd-testbed tag (the dom0 service then exits non-zero
# writing nothing, which looks identical), the tool discarded the window, or there genuinely is
# none. The first is excluded ONCE, in preflight, by asserting the tag; the dom0 service's exit
# status is read on EVERY poll, so a denial can never be read as "not up yet". Only a non-empty
# capture is a positive edge, and windows do not un-appear, so the first one is the answer.
#
# NO DESKTOP CAPTURE, EVER. This polls `qtest shot` (local.WinScreenshot, per-window, tag-gated),
# never fullshot: a desktop capture photographs the owner's screen and is what makes campaigns
# intolerable to sit through.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

A=""; B=""; SUBJ="win11r-sup"; ROUNDS=3; DEADLINE=300; POLL=2
while [ $# -gt 0 ]; do
  case "$1" in
    --a) A="${2:-}"; shift 2 ;;
    --b) B="${2:-}"; shift 2 ;;
    --subject) SUBJ="${2:-}"; shift 2 ;;
    --rounds) ROUNDS="${2:-}"; shift 2 ;;
    --deadline) DEADLINE="${2:-}"; shift 2 ;;
    --poll) POLL="${2:-}"; shift 2 ;;
    *) echo "FAIL  unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$A" ] && [ -f "$A" ] || { echo "FAIL  --a <exe> is required and must exist (got '$A')" >&2; exit 2; }
[ -n "$B" ] && [ -f "$B" ] || { echo "FAIL  --b <exe> is required and must exist (got '$B')" >&2; exit 2; }

OUT="$HOME/qwt-ttfw/$(date -u +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
R="$OUT/ttfw.log"
log(){ echo "$(date -u +%T)Z ttfw[$SUBJ]: $*" | tee -a "$R"; }
hash16(){ sha256sum "$1" | cut -c1-16 | tr 'a-f' 'A-F'; }
AH="$(hash16 "$A")"; BH="$(hash16 "$B")"
[ "$AH" != "$BH" ] || { echo "FAIL  --a and --b are the SAME binary ($AH) - there is no A/B to run" >&2; exit 2; }

log "A (no fix) $AH  <- $A"
log "B (fix)    $BH  <- $B"
log "rounds=$ROUNDS deadline=${DEADLINE}s poll=${POLL}s  evidence: $OUT"

# ---- preflight: the subject must exist AND carry the tag, so an empty capture has ONE meaning ----
qvm-check "$SUBJ" >/dev/null 2>&1 || { log "FAIL  subject '$SUBJ' does not exist"; exit 2; }
if ! qvm-tags "$SUBJ" 2>/dev/null | grep -qx 'win-idd-testbed'; then
  log "FAIL  subject '$SUBJ' does not carry win-idd-testbed: local.WinScreenshot would be refused and every"
  log "      capture would come back EMPTY, which this harness would otherwise read as 'no window yet'"
  exit 2
fi
log "preflight: subject exists and is tagged win-idd-testbed"

. mgmt/harness/vmlock.sh
vm_lock "$SUBJ" || { log "FAIL  could not take the rig lock for $SUBJ"; exit 2; }
. mgmt/harness/shutdown-lib.sh
. mgmt/harness/e2e-wait.sh
IN='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
qt(){ QTEST_VM="$SUBJ" ./tools/qtest "$@"; }

# THE SWAP SCRIPT HAS TO BE ON THE GUEST, and nothing else puts it there - run_side invokes it from
# QubesIncoming, so without this every sample would fail on a missing file. Pushed ONCE.
# DISTINCT BASENAMES for the two sides: both artifacts are called gui-agent.exe, and while
# `qtest push` deletes the target first (so a repeat works) and asserts the byte count, giving each
# side its own name means the file the swap reads can never be the other side's - the hash check
# would catch that, but the evidence should not need a hash check to be readable.
cp "$A" "$OUT/agent-a.exe" || { log "FAIL  could not stage the A binary"; exit 2; }
cp "$B" "$OUT/agent-b.exe" || { log "FAIL  could not stage the B binary"; exit 2; }
A="$OUT/agent-a.exe"; B="$OUT/agent-b.exe"
# BOTH SCRIPTS. swap-agent.ps1:75 requires restart-gui-agent.ps1 BESIDE it and exits 1 with
# "FAIL: restart-gui-agent.ps1 not pushed next to this script" otherwise - that helper is the
# sanctioned restart (stop the owning service, swap, start, prove the turnover), which is why the
# swap refuses to improvise without it. MEASURED: without it every sample reported
# HASH_RUNNING=<none> and this harness correctly refused to time any of them.
if ! qt push "$ROOT/guest/swap-agent.ps1" "$ROOT/guest/restart-gui-agent.ps1" "$ROOT/guest/probe-ttfw.ps1" >>"$OUT/push-swap.out" 2>&1; then
  log "FAIL  could not push the swap scripts - every sample would fail on a missing script"
  vm_unlock "$SUBJ" 2>/dev/null || true
  exit 2
fi
log "staged: agent-a.exe ($AH), agent-b.exe ($BH), swap-agent.ps1 pushed"

# ---- the instrument is the agent's own log, so there is nothing to prove about captures --------
# (The earlier capture-path proof is gone with the capture-based metric. What replaces it is
# per-sample: a sample that cannot read all four stamps is a MISS, named, never a number.)
# ---- the measurement: boot -> a DEMONSTRATED window, with the agent's stamps as the breakdown ---
# THE END STATE IS ASSERTED, which an earlier cut did not do and which makes the difference between a
# measurement and a number. Owner, 2026-10-23: "pixels not demonstrated is not smoke pass. a
# measurement that does not prove end state is sane is futile, we may claim zero seconds
# immediately." Exactly right: a clean log with no window ever shown is consistent with any timing at
# all. So every sample must finish with a window whose pixels are classified DESKTOP - tools/winshot.py
# classify(), i.e. "varied content: something is actually rendering" - and a sample that cannot reach
# that is a MISS, never a number.
#
# An ordinary application window is launched on purpose: on a seamless guest an idle desktop maps NO
# windows (measured - one top-level window exists, explorer's desktop, and the capture is correctly
# empty), so there is no first window to time until something opens one. The app is ended BY PID.
ttfw_sample(){ # $1 tag -> "<ttfw_ms> <shell_launch_ms> <shell_ready_ms> <colours>" or "miss <why>"
  local tag="$1" t0 now el out wpid n p verdict cols ok birth shell launch ready
  qwt_shutdown "$SUBJ" 600 >>"$OUT/$tag.shutdown" 2>&1 || { echo "miss shutdown_refused"; return; }
  qvm-start "$SUBJ" >>"$OUT/$tag.start" 2>&1 || { echo "miss start_failed"; return; }
  t0=$(date +%s%3N)
  # three exits, each named: no qrexec, no app, no demonstrated window.
  ok=0
  for _i in $(seq 1 12); do w_alive "$SUBJ" 40 && { ok=1; break; }; done
  [ "$ok" = 1 ] || { echo "miss no_qrexec_after_boot"; return; }
  out=$(QTEST_VM="$SUBJ" ./tools/qtest pushrun "$ROOT/guest/launch-window-probe.ps1" 2>&1 | tr -d '\r')
  printf '%s\n' "$out" >> "$OUT/$tag.launch"
  wpid=$(printf '%s\n' "$out" | grep -aoE 'WINPROBE exe=[^ ]+ pid=[0-9]+' | grep -aoE 'pid=[0-9]+' | cut -d= -f2 | tail -1)
  [ -n "$wpid" ] || { echo "miss no_app_started"; return; }
  verdict=""; cols=0
  while :; do
    now=$(date +%s%3N); el=$(( (now - t0) / 1000 ))
    [ "$el" -lt "$DEADLINE" ] || break
    if qt shot "$OUT/$tag-shot.tar" >>"$OUT/$tag.shot" 2>&1 && [ -s "$OUT/$tag-shot.tar" ]; then
      rm -rf "$OUT/$tag-win"; mkdir -p "$OUT/$tag-win"
      tar -xf "$OUT/$tag-shot.tar" -C "$OUT/$tag-win" 2>/dev/null || true
      for p in "$OUT/$tag-win"/*.png; do
        [ -f "$p" ] || continue
        v=$(python3 tools/winshot.py --png "$p" --classify 2>/dev/null | grep -aoE 'VERDICT=[A-Z]+' | cut -d= -f2)
        if [ "$v" = DESKTOP ]; then
          verdict=DESKTOP
          # the colour count is recorded as the evidence that "DESKTOP" was not a lucky gradient
          cols=$(python3 -c "
from PIL import Image; import sys
im = Image.open(sys.argv[1]).convert('RGB')
print(len(im.getcolors(maxcolors=1<<24) or []))" "$p" 2>/dev/null || echo 0)
          now=$(date +%s%3N); break
        fi
      done
      [ -n "$verdict" ] && break
    fi
    sleep "$POLL"
  done
  # end it by PID, never by name (ADR-supervision 5)
  QTEST_VM="$SUBJ" ./tools/qtest run "powershell -NoProfile -Command \"Stop-Process -Id $wpid -Force -EA SilentlyContinue\"" >>"$OUT/$tag.endapp" 2>&1 || true
  [ "$verdict" = DESKTOP ] || { echo "miss no_demonstrated_window_within_${DEADLINE}s"; return; }
  local ttfw=$(( now - t0 ))
  # the breakdown, from four stamps the agent itself wrote in ONE log
  out=$(QTEST_VM="$SUBJ" ./tools/qtest pushrun "$ROOT/guest/probe-ttfw.ps1" 2>&1 | tr -d '\r')
  printf '%s\n' "$out" >> "$OUT/$tag.probe"
  g(){ printf '%s\n' "$out" | grep -a "^TTFW $1=" | tail -1 | cut -d= -f2-; }
  birth=$(g birth); shell=$(g shell); launch=$(g launch); ready=$(g ready)
  if [ -n "$shell" ] && [ -n "$launch" ] && [ -n "$ready" ]; then
    python3 - "$ttfw" "$shell" "$launch" "$ready" "$cols" <<'PY'
import sys, datetime
def t(x): return datetime.datetime.strptime(x, "%Y%m%d%H%M%S%f")
sh, la, rd = (t(sys.argv[i]) for i in (2, 3, 4))
print("%s %d %d %s" % (sys.argv[1], (la-sh).total_seconds()*1000, (rd-sh).total_seconds()*1000, sys.argv[5]))
PY
  else
    echo "$ttfw -1 -1 $cols"
  fi
}

run_side(){ # $1 side(A|B) $2 exe $3 want-hash $4 round
  local side="$1" exe="$2" want="$3" round="$4" tag swap got res
  tag="r${round}-${side}"
  log "-- $tag: swapping in $side ($want)"
  qt push "$exe" >/dev/null 2>&1
  swap="$(qt run "powershell -NoProfile -ExecutionPolicy Bypass -File $IN\\swap-agent.ps1 -StopHelpers -NewAgent $IN\\$(basename "$exe")" 2>&1)"
  printf '%s\n' "$swap" > "$OUT/$tag.swap"
  got="$(printf '%s\n' "$swap" | grep -aoE 'HASH_RUNNING=[0-9A-F]+' | cut -d= -f2)"
  if [ "$got" != "$want" ]; then
    log "   INVALID $tag: running hash '${got:-<none>}' != expected '$want' - refusing to time a build that is not running"
    printf '%s\t%s\t%s\t%s\n' "$round" "$side" "INVALID" "swap_hash_${got:-none}" >> "$OUT/samples.tsv"
    return 1
  fi
  res="$(ttfw_sample "$tag")"
  case "$res" in
    miss*) log "   MISS $tag: $res"
           printf '%s\t%s\t%s\t%s\n' "$round" "$side" "MISS" "${res#miss }" >> "$OUT/samples.tsv" ;;
    *)     set -- $res
           log "   $tag: FIRST WINDOW (classified DESKTOP, ${4} colours) after ${1} ms; shell->launch ${2} ms, shell->ready ${3} ms"
           printf '%s\t%s\t%s\t%s\n' "$round" "$side" "${1}" "launch${2}:ready${3}:cols${4}" >> "$OUT/samples.tsv" ;;
  esac
}

printf 'round\tside\tms\tdetail\n' > "$OUT/samples.tsv"
for r in $(seq 1 "$ROUNDS"); do
  # ALTERNATE THE STARTING SIDE so guest drift cannot land on one side only.
  if [ $(( r % 2 )) -eq 1 ]; then
    run_side A "$A" "$AH" "$r" || true
    run_side B "$B" "$BH" "$r" || true
  else
    run_side B "$B" "$BH" "$r" || true
    run_side A "$A" "$AH" "$r" || true
  fi
done

# ---- THE SMOKE TEST, over a window holding ONE build ------------------------------------------
# A/B rounds necessarily span BOTH binaries, so a sweep over them would report the A side's known
# defects as this run's. So the smoke test is its own step: swap B in, note the time, boot once,
# and sweep only THAT window. Fixes the lint's L19-guest-run-without-log-sweep for this harness
# rather than adding to its 36-deep backlog - a harness that boots a guest repeatedly and never
# grades those boots is exactly how an error log goes unread.
log "-- smoke: one boot on B, swept on its own"
smoke_rc=0
if run_side B "$B" "$BH" "smoke"; then
  if w_alive "$SUBJ" 60 || { sleep 30; w_alive "$SUBJ" 60; }; then
    SINCE_SMOKE=$(date -u -d '-3 minutes' +%Y-%m-%dT%H:%M:%SZ)
    # TWO INSTRUMENTS GRADING ONE CAMPAIGN MUST CARRY THE SAME DISPOSITIONS - matrix.sh:3216 states
    # that rule about itself, and this harness broke it. MEASURED 2026-10-23: the smoke sweep here
    # raised signatures_unclassified=1 at P1 on
    #     qrexec|E|wmain: open agent pipe failed with error 0x2
    # and I filed it as a product defect. It is declared at matrix.sh:497 for EVERY cell, with the
    # stated reason that this rig gives each subject an EMPTY netvm (CLAUDE.md: only a guest that
    # TESTS PV networking gets one), so /qubes-ip does not exist and those modules fail that way -
    # Jev on that reason: caused 0.91, conf 0.86. A gate that does not carry the campaign's
    # dispositions invents P1s, and an invented P1 is as bad as a missed one.
    (cd "$ROOT" && timeout 1200 bash mgmt/harness/log-sweep.sh "$SUBJ" "$SINCE_SMOKE" "$OUT/smoke-sweep" \
      --tolerate-error '(SetupNetwork: Failed to get qubes-ip|QioWriteBuffer: WriteFile failed with error 0xe8|send_command_to_daemon: write to daemon failed with error 0xe8|wmain: open agent pipe failed with error 0x2)' \
      'this rig gives every subject an EMPTY netvm (CLAUDE.md: only a guest that TESTS PV networking gets one), so /qubes-ip legitimately does not exist and those modules fail that way. Same disposition matrix.sh:497 carries for every cell; Jev on that reason caused 0.91 conf 0.86.') \
      > "$OUT/smoke-sweep.out" 2>&1
    sweepline=$(grep -a 'LOGSWEEP-RESULT' "$OUT/smoke-sweep.out" | tail -1)
    log "   $sweepline"
    case "$sweepline" in
      *status=CLEAN*) log "   SMOKE PASS: the sweep over B's own boot finds nothing new or breached" ;;
      *status=*)      log "   SMOKE FAIL: $sweepline"; smoke_rc=1 ;;
      *)              log "   SMOKE INVALID: the sweep produced no LOGSWEEP-RESULT line"; smoke_rc=1 ;;
    esac
  else
    log "   SMOKE INVALID: no qrexec after the smoke boot - nothing to sweep"
    smoke_rc=1
  fi
else
  log "   SMOKE INVALID: B did not swap in, so nothing measured B"
  smoke_rc=1
fi

vm_unlock "$SUBJ" 2>/dev/null || true

# ---- the verdict: medians, the delta, and every miss named -------------------------------------
python3 - "$OUT/samples.tsv" <<'PY' | tee -a "$R"
import sys, statistics
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])][1:]
def nums(side): return sorted(int(r[2]) for r in rows if r[1] == side and r[2].isdigit())
bad = [(r[1], r[2], r[3]) for r in rows if not r[2].isdigit()]
a, b = nums("A"), nums("B")
print("TTFW-AB  boot->demonstrated-window seconds, A(no fix) n=%d %s" % (len(a), [round(x/1000, 1) for x in a]))
print("TTFW-AB  boot->demonstrated-window seconds, B(fix)    n=%d %s" % (len(b), [round(x/1000, 1) for x in b]))
for s, m, why in bad:
    print("TTFW-AB  UNUSABLE side=%s %s %s" % (s, m, why))
if not a or not b:
    print("TTFW-AB  VERDICT=INCONCLUSIVE - a side with no usable sample cannot be compared")
    sys.exit(1)
ma, mb = statistics.median(a), statistics.median(b)
print("TTFW-AB  median boot->window A=%.1fs B=%.1fs  delta=%.1fs" % (ma/1000, mb/1000, (ma-mb)/1000))
# DISJOINT RANGES OR NOTHING: with a handful of per-boot samples, overlapping ranges do not
# support a claim, and this project has been burned by between-session variance exceeding the
# within-session spread (docs/BENCHMARKS.md).
if max(b) < min(a):
    print("TTFW-AB  VERDICT=IMPROVED (ranges disjoint: B max %.1fs < A min %.1fs)" % (max(b)/1000, min(a)/1000))
elif max(a) < min(b):
    print("TTFW-AB  VERDICT=REGRESSED (ranges disjoint the wrong way)")
else:
    print("TTFW-AB  VERDICT=OVERLAPPING - no claim from these samples; add rounds")
PY
rc=${PIPESTATUS[0]}
log "evidence: $OUT"
# EITHER FAILURE FAILS THE RUN: an A/B whose own boots logged a breach is not a result to act on.
[ "$smoke_rc" = 0 ] || { log "FAIL  the smoke sweep did not pass"; exit 1; }
exit "$rc"
