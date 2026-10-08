#!/usr/bin/env bash
# log-policy-selftest.sh - ROUTINE PER-WINDOW DETAIL MUST NOT BE AT INFO.
#
# Owner, 2026-10-08: "are you fucking crazy to log every open window when its normal? ok for debug
# but not for regular operation."
#
# The MSI ships LogLevel 3, which is INFO, so every LogInfo is in regular operation. Opening a
# window wrote several of them - the broker slot it was given (QGABROKERREG), that slot being kept
# (QGABROKERKEEP), its slice-fed map (QGASLICEMAP), a deferred map (QGAHELDDEFER) and a caption
# helper - so an ordinary desktop session logged per window per event. They are at DEBUG now.
#
# WHAT THIS CHECKS, and why it is a grep and not a run: a per-window LogInfo is either an ANOMALY
# (which keeps its level - a fallback firing is logged loudly and diagnosed) or it is routine, in
# which case it belongs at DEBUG or behind a trace gate. The protocol stream (QGAPROTO msg=MOTION,
# BUTTON, DAMAGE, CONFIGURE ...) is already gated behind g_ProtoTrace / ProtoDragOn(), which is how
# it should be, and this check confirms that stays true.
#
# NOTHING HERE IS ABOUT ERRORS. LogError and LogWarning are untouched and out of scope: the goal is
# no NOISE in normal operation, never a quieter failure.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/agent/gui-agent"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -d "$SRC" ] || { echo "FAIL  $SRC is missing - nothing ran (missing data fails)"; exit 2; }

# THE DISCRIMINATOR, so this list cannot just grow until the check passes: a line may keep INFO if
# it fires once per CONDITION, and must go to DEBUG if it fires once per window OPEN or CLOSE. The
# second kind happens for every window in every session and is what the owner objected to; the first
# kind is an event worth exactly one line.
#
#   broker death / hang / reap / back, BROKERDIMS feed-loss  - a failure or a recovery
#   QGAZERORECT, QGATOASTGAP, ZORDERINVALID                  - something was rejected or repaired
#   QGAHELPERSDISARM/REARM, QGAHELPERTASK, QGACAPSTRIP       - a one-shot state change
#   QGAFSFLASH, QGASTARTDISMISS, QGAUAC, QGADESKSTUCK        - a mode or policy event, not a window
#   QGADIRECTSUPPRESS, QGARAISE, QGAPLACEKEEP                - dom0 and the guest disagreeing
#   QGATOASTHOLD / QGATOASTIDENT / QGATOASTPREEMPT           - per TOAST, a few an hour, and the
#                                                              evidence for the no-double/no-lost
#                                                              notification P1; losing it in the
#                                                              field would cost more than it saves
#   QGADRAGSLICE / QGADRAGFREEZE ev=settle                   - one line per drag, user-initiated
#   QGADDAMOVE                                               - DDA ownership changing hands on a
#                                                              move, which is a transition, not a
#                                                              window appearing
#   popup damage                                             - already once per popup by construction
#   QGADRAGSIM                                               - a simulation facility, off unless asked
#   QGAERRBOX                                                - an error DIALOG was detected
#   QGASLICEBLACK                                            - the black-window case, and already
#                                                              once per window (PwSliceBlackLogged)
#   QGAPWECHO                                                - rate-limited in code (n<=4 || n%256)
#   QGAPROTO                                                 - gated behind g_ProtoTrace anyway
ALLOW='QGABROKERDIED|QGABROKERHUNG|QGABROKERREAP|QGABROKERBACK|BROKERDIMS|QGAZERORECT|QGATOASTGAP|ZORDERINVALID|QGAHELPERSDISARM|QGAHELPERSREARM|QGAHELPERTASK|QGADIRECTSUPPRESS|QGACAPSTRIP|QGAFSFLASH|QGASTARTDISMISS|QGAUAC|QGALOGPOLICY|QGARAISE|QGADESKSTUCK|QGAPROTO|QGATOASTHOLD|QGATOASTIDENT|QGATOASTPREEMPT|QGAPLACEKEEP|QGADRAGSLICE|QGADRAGFREEZE|QGADDAMOVE|popup damage|QGADRAGSIM|QGAERRBOX|QGASLICEBLACK|QGAPWECHO'

python3 - "$SRC" "$ALLOW" <<'PY' > /tmp/logpolicy.$$ 2>&1
import re, sys, pathlib
src, allow = pathlib.Path(sys.argv[1]), re.compile(sys.argv[2])
GATE = re.compile(r'\b(g_ProtoTrace|ProtoDragOn\(\)|g_ProtoTraceWobble|g_ProtoTraceDrag)\b')
WINDOWY = re.compile(r'hwnd[ =]0x%x|hwnd=0x%x|window 0x%x')
offenders = []
for f in sorted(src.glob('*.c')):
    lines = f.read_text(encoding='utf-8', errors='replace').splitlines()
    for i, ln in enumerate(lines):
        if 'LogInfo(' not in ln or not WINDOWY.search(ln):
            continue
        if allow.search(ln):
            continue
        # a gate within the preceding 8 code lines makes it diagnostic, not routine
        window = [x for x in lines[max(0, i - 8):i] if x.strip() and not x.strip().startswith('//')]
        if any(GATE.search(x) for x in window):
            continue
        offenders.append("%s:%d %s" % (f.name, i + 1, ln.strip()[:88]))
print("OFFENDERS %d" % len(offenders))
for o in offenders:
    print("   " + o)
PY
r=$(cat /tmp/logpolicy.$$); rm -f /tmp/logpolicy.$$
n=$(printf '%s' "$r" | head -1 | awk '{print $2}')
if [ "${n:-1}" = 0 ]; then
  ok "no_routine_per_window_info: every per-window LogInfo is a named anomaly or behind a trace gate"
else
  bad "no_routine_per_window_info: $n per-window LogInfo line(s) are routine and at INFO:"
  printf '%s\n' "$r" | tail -n +2
fi

# ---- the five that were demoted must stay demoted ----------------------------------------------
miss=""
# THE DELIMITER IS PART OF THE TOKEN. "QGALEDGER" alone also matches QGALEDGERSUM, which is an
# aggregate logged at most once a minute and rightly stays at INFO - without the delimiter this
# check reported the summary line as a per-window line that had crept back.
for t in 'QGABROKERREG hwnd=' 'QGABROKERKEEP hwnd=' 'QGASLICEMAP hwnd=' 'QGAHELDDEFER hwnd=' \
         'QGADIRECTWAIT hwnd' 'QGAHELDMAP hwnd=' 'QGASLICECONTENT hwnd=' 'QGALEDGER\t'; do
  command grep -qF "LogDebug(\"$t" "$SRC/main.c" || miss="$miss [$t]"
  command grep -qF "LogInfo(\"$t"  "$SRC/main.c" && miss="$miss [$t back at INFO]"
done
command grep -qF 'LogDebug("0x%x: caption %s helper launched' "$SRC/main.c" || miss="$miss [caption helper]"
[ -z "$miss" ] && ok "demoted_stay_demoted: every routine per-window line is at DEBUG" \
               || bad "demoted_stay_demoted:$miss"

# ---- the policy is ANNOUNCED once, so the detail is not just missing ---------------------------
command grep -qF 'QGALOGPOLICY routine per-window detail is at DEBUG' "$SRC/main.c" \
  && ok "policy_announced: one INFO line says where the per-window detail went" \
  || bad "policy_announced: the detail is gone with nothing saying so"

# ---- NO ERROR OR WARNING WAS TOUCHED ----------------------------------------------------------
# The goal is no noise in normal operation, never a quieter failure. This is the guard against
# this very check being used to justify demoting a failure.
# COUNTED AGAINST THE REVISION BEFORE THE DEMOTION, not against a number chosen here. My first
# version of this check used >= 100 / >= 40, which I had invented: the real counts are 52 and 79, so
# it failed the change for code it had not touched. A bar you pick is not a measurement.
base=$(cd "$ROOT/agent" && git log --format=%H -1 --skip=1 -- gui-agent/main.c 2>/dev/null)
for f in main.c send.c toasthold.c vchan-handlers.c; do
  now_e=$(command grep -c 'LogError(' "$SRC/$f" 2>/dev/null || echo 0)
  now_w=$(command grep -c 'LogWarning(' "$SRC/$f" 2>/dev/null || echo 0)
  was_e=$(cd "$ROOT/agent" && git show "$base:gui-agent/$f" 2>/dev/null | command grep -c 'LogError(')
  was_w=$(cd "$ROOT/agent" && git show "$base:gui-agent/$f" 2>/dev/null | command grep -c 'LogWarning(')
  if [ -z "$base" ]; then
    bad "failures_untouched_$f: no earlier revision to compare against (missing data fails)"
  elif [ "$now_e" -ge "$was_e" ] && [ "$now_w" -ge "$was_w" ]; then
    ok "failures_untouched_$f: LogError $was_e->$now_e, LogWarning $was_w->$now_w - none removed"
  else
    bad "failures_untouched_$f: LogError $was_e->$now_e, LogWarning $was_w->$now_w - a failure path was demoted or deleted"
  fi
done

# ---- the harnesses that grade on the demoted lines must say they need the level ---------------
for h in toast-hold-test.sh crop-before-map.sh; do
  f="$ROOT/mgmt/harness/$h"
  if [ ! -f "$f" ]; then bad "dependent_declares_$h: missing"; continue; fi
  if command grep -q 'NEEDS LogLevel' "$f"; then
    ok "dependent_declares_$h: it states that it needs LogLevel >= 4, so a run at 3 is not read as clean"
  else
    bad "dependent_declares_$h: it grades on a DEBUG line without saying it needs the level raised"
  fi
done

echo
echo "log-policy-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
