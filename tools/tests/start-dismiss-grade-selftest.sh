#!/usr/bin/env bash
# start-dismiss-grade-selftest.sh - the Start-dismissal grader must read the capture, and must
# REFUSE when its own anchors have gone stale.
#
# WHY. The dedicated Start test's grader lived untracked in scratchpad/ and anchored success on the
# literal "closed it with Escape", added in 9186c17 and REMOVED in 0429a93. From that commit on it
# could not recognise a successful dismissal at all: the test reported no Start verdict while the
# capture it had just taken carried two WARNINGs saying the menu opened and our dismissal failed -
# a P1, sitting in a file nobody's grader could read. The instrument for a P1 was broken AND
# unreviewable.
#
# So this pins three things: the grader reads every generation of the wording (a capture from an
# older build is still evidence); it reports INSTRUMENT rather than a verdict when a current stem
# has vanished from the emitter; and an opening with NO terminal line is not graded as a success,
# because before ac45cd9 that was the shape of every success AND of every dismissal that never ran.
#
# The gen3 fixture lines are DERIVED from the stems the grader asserts exist in the emitter - not
# written out by hand here - so a wording change in main.c fails this test instead of sliding past
# it. The gen2 fixture is a REAL capture when one is present on this qube.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
G="${START_GRADER:-$HERE/tools/start-dismiss-grade.py}"
SRC="$HERE/agent/gui-agent/main.c"
[ -f "$G" ] || { echo "FAIL  $G missing - nothing ran (missing data fails)"; exit 2; }
[ -f "$SRC" ] || { echo "FAIL  $SRC missing - nothing ran"; exit 2; }
D=$(mktemp -d); trap 'rm -rf -- "$D"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

# Render one capture line per case, filling the grader's OWN asserted stems.
python3 - "$G" "$D" <<'PY'
import sys, importlib.util, re
spec = importlib.util.spec_from_file_location("g", sys.argv[1])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
D = sys.argv[2]
def fill(stem, **kw):
    s = stem.replace("%llu", str(kw.get("ms", 42))).replace("%x", kw.get("hwnd", "1017a"))
    return s.replace("%s", kw.get("why", "surface cloaked"))
def line(ts, lvl, func, msg):
    return "[20261017.%s.000-6600:6604-%s] %s: QGASTARTDISMISS 0x1017a: %s" % (ts, lvl, func, msg)
S = {k: s for k, s in zip(
    ["closed", "returned", "stuck", "refused", "notarget"], g.CURRENT_STEMS)}
# the four gen3 outcomes, each as its own capture
open(D + "/g3-closed.log", "w").write("\n".join([
    line("130000", "I", "StartOpeningExamine", fill(S["returned"]) + " (dom0 focus, plain), foreground pid 6116"),
    line("130000", "I", "StartOpeningExamine", fill(S["closed"], ms=120, why="surface cloaked")),
]) + "\n")
open(D + "/g3-stuck.log", "w").write("\n".join([
    line("130100", "I", "StartOpeningExamine", fill(S["returned"]) + " (dom0 focus, plain), foreground pid 6116"),
    line("130101", "E", "StartOpeningExamine", fill(S["stuck"], ms=1031) + " (foreground pid 6116) - clicks go to a menu the user cannot see"),
]) + "\n")
open(D + "/g3-refused.log", "w").write(
    line("130200", "E", "StartOpeningExamine", fill(S["refused"]) + " - foreground held by pid 6116; the hidden menu may take clicks") + "\n")
open(D + "/g3-notarget.log", "w").write(
    line("130300", "E", "StartOpeningExamine", S["notarget"] + " - the hidden menu may take clicks") + "\n")
# gen2: an opening with an attempt and NO terminal line - the old success shape, which is also the
# shape of a dismissal that never ran. Absence is not evidence either way.
open(D + "/g2-unrecorded.log", "w").write(
    line("130400", "I", "DismissHiddenStartSurface", "the Windows Start menu opened in seamless mode, where it is never shown (SeamlessStart=0) - posted Escape to 0x1018a (focus=0x1018a) so no invisible window takes input (foreground pid 6116)") + "\n")
print("fixtures rendered from %d emitter stems" % len(g.CURRENT_STEMS))
PY

run(){ python3 "$G" --agent-log "$1" --source "$SRC" 2>&1; }
rc(){ python3 "$G" --agent-log "$1" --source "$SRC" >/dev/null 2>&1; echo $?; }

r=$(run "$D/g3-closed.log")
if [ "$(rc "$D/g3-closed.log")" = 0 ] && printf '%s' "$r" | grep -q 'closed=1' && printf '%s' "$r" | grep -q 'verdict: PASS'; then
    ok "gen3: an observed closure is a PASS"
else bad "gen3 closed: $(printf '%s' "$r" | head -1)"; fi

r=$(run "$D/g3-stuck.log")
if [ "$(rc "$D/g3-stuck.log")" = 3 ] && printf '%s' "$r" | grep -q 'STILL OPEN 1031 ms'; then
    ok "gen3: a menu past the bound FAILS and names the elapsed time"
else bad "gen3 stuck: $(printf '%s' "$r" | head -1)"; fi

for case in refused notarget; do
    r=$(run "$D/g3-$case.log")
    if [ "$(rc "$D/g3-$case.log")" = 3 ]; then ok "gen3: $case is a FAIL - the menu was left open"
    else bad "gen3 $case graded $(printf '%s' "$r" | grep -m1 verdict)"; fi
done

# AN ABSENT TERMINAL LINE IS NOT A PASS. This is the one that would have hidden the P1: on gen2 a
# successful dismissal and one that never happened both ended in silence.
r=$(run "$D/g2-unrecorded.log")
if [ "$(rc "$D/g2-unrecorded.log")" = 3 ] && printf '%s' "$r" | grep -q 'unrecorded=1'; then
    ok "gen2: an opening with no terminal line is NOT graded a success"
else bad "gen2 unrecorded: an absent line was read as a closure - $(printf '%s' "$r" | grep -m1 verdict)"; fi

# THE ANCHOR SELF-CHECK, seen to fire. A grader whose pattern has gone stale must say so instead of
# reporting "no evidence" - which is exactly what happened for days.
grep -v 'still open %llu ms after activation returned' "$SRC" > "$D/main-stale.c"
out=$(python3 "$G" --agent-log "$D/g3-stuck.log" --source "$D/main-stale.c" 2>&1)
python3 "$G" --agent-log "$D/g3-stuck.log" --source "$D/main-stale.c" >/dev/null 2>&1; src_rc=$?
if [ "$src_rc" = 2 ] && printf '%s' "$out" | grep -q 'stem no longer in the emitter'; then
    ok "anchors: a retired stem makes it report INSTRUMENT, not a verdict"
else bad "anchors: a stale grader still reported a verdict (rc=$src_rc)"; fi

if [ "$(rc "$D/g3-stuck.log")" = 3 ]; then ok "anchors: the real emitter does not trip the check"
else bad "anchors: the real emitter trips its own check"; fi

# THE REAL CAPTURE, when it is still on this qube. gen2 wording, and the answer in it is the P1 that
# the old grader could not see: two openings, both still open 1031 ms after the dismissal.
REAL=$(ls "$HERE"/scratchpad/start-repro/dt-*/agent.log 2>/dev/null | head -1)
if [ -n "$REAL" ] && command grep -aq QGASTARTDISMISS "$REAL" 2>/dev/null; then
    r=$(run "$REAL")
    if printf '%s' "$r" | grep -q 'stuck=2' && [ "$(rc "$REAL")" = 3 ]; then
        ok "real capture: $(basename "$(dirname "$REAL")") grades 2 stuck openings (the P1 the old grader missed)"
    else bad "real capture: graded $(printf '%s' "$r" | head -1)"; fi
else echo "SKIP  no real Start capture on this qube (fixtures are rendered from the emitter's stems)"; fi

echo "start-dismiss-grade: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
