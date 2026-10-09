#!/bin/bash
# Can tools/report-gate-review.py actually FLAG anything?
#
# WHY THIS EXISTS. That reviewer reported "0 flagged" twice on files that contain the very defect it
# was written for, and both times the cause was in the reviewer, not the code under review:
#   1. its CLOCK pattern required a time term inside the comparison, so the canonical shape - the
#      deadline computed earlier and compared against a plain variable, `now >= s_SecureNextWarn`
#      (desktop-stuck) and `now >= g_BrokerNextWarn` (deslice-down) - was never extracted as a site;
#   2. it read each answer as ans[q]['p'], but jev.py writes {"answers": {q: {"type": "noul",
#      "noul": 0.4}}} - there is no "p" key - so every probability read as 0 and nothing could ever
#      cross the threshold. Jev had scored the known-bad block false_report_plausible 0.67,
#      observable_available in-block 0.70 and load_bearing 0.87, and the tool still printed 0.
# A reviewer that cannot flag is worse than no reviewer: it answers the question with a clean bill.
#
# This test uses FIXTURES, not Jev - it checks the reviewer's own arithmetic and extraction, which
# is what broke. It makes no network calls and needs no guest.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then printf '  ok    %-56s %s\n' "$1" "$2"; pass=$((pass+1))
       else printf '  FAIL  %-56s got %s, wanted %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }

# ---- 1. prob() reads jev.py's REAL answer shape -------------------------------------------------
cat > "$TMP/shape.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('rgr', 'tools/report-gate-review.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
noul   = {'q': {'type': 'noul', 'noul': 0.67}}
choice = {'q': {'type': 'choice', 'choice': 'in-block', 'confidence': 0.7}}
empty  = {}
print('noul',   m.prob(noul, 'q'))
print('choice', m.prob(choice, 'q'))
print('absent', m.prob(empty, 'q'))
PY
out=$(python3 "$TMP/shape.py" 2>&1)
chk "prob() reads a noul's value"            "$(echo "$out" | awk '/^noul/{print $2}')"   "0.67"
chk "prob() reads a choice's confidence"     "$(echo "$out" | awk '/^choice/{print $2}')" "0.7"
chk "prob() returns 0 for an absent question" "$(echo "$out" | awk '/^absent/{print $2}')" "0.0"

# ---- 2. the CLOCK pattern catches the canonical shape -------------------------------------------
cat > "$TMP/clock.py" <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location('rgr', 'tools/report-gate-review.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cases = {
    'deadline-variable': 'else if (now >= s_SecureNextWarn)',      # desktop-stuck / deslice-down
    'elapsed-term':      'if (now - s_SecureSince >= SOME_MS)',
    'threshold-compare': 'if (elapsed >= SECURE_DESKTOP_FIRST_WARN_MS)',
    'shell-seconds':     'while [ $((SECONDS-t0)) -lt 3000 ]; do',
}
for name, line in cases.items():
    print(name, bool(m.CLOCK_RE.search(line)))
# a bounded wait is NOT the defect and must not be matched on its own
for name, line in {'bare-timeout': 'timeout 90 tools/qtest push "$p"',
                   'bare-sleep':   'Start-Sleep -Seconds 5'}.items():
    print(name, bool(m.CLOCK_RE.search(line)))
PY
out=$(python3 "$TMP/clock.py" 2>&1)
for c in deadline-variable elapsed-term threshold-compare shell-seconds; do
  chk "CLOCK matches $c" "$(echo "$out" | awk -v c="$c" '$1==c{print $2}')" "True"
done
for c in bare-timeout bare-sleep; do
  chk "CLOCK ignores $c (a bound is not a verdict)" "$(echo "$out" | awk -v c="$c" '$1==c{print $2}')" "False"
done

# ---- 3. the flagging arithmetic, on a fixture that MUST flag and one that must not --------------
cat > "$TMP/flag.py" <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location('rgr', 'tools/report-gate-review.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# the real scores Jev gave the known-bad block in agent/gui-agent/main.c ProcessNewFrame
bad  = {'clock_decides_alone': {'noul': 0.40}, 'false_report_plausible': {'noul': 0.67}}
good = {'clock_decides_alone': {'noul': 0.10}, 'false_report_plausible': {'noul': 0.20}}
for name, ans in (('known-bad', bad), ('known-good', good)):
    print(name, len([q for q in m.DEFECT_Q if m.prob(ans, q) >= 0.5]))
PY
out=$(python3 "$TMP/flag.py" 2>&1)
chk "the known-bad block FLAGS (this is the arm that failed)" "$(echo "$out" | awk '/^known-bad/{print $2}')"  "1"
chk "a clean block does not flag"                             "$(echo "$out" | awk '/^known-good/{print $2}')" "0"

# ---- 4. --list runs and finds sites in our own tree --------------------------------------------
n=$(timeout 300 python3 tools/report-gate-review.py --list agent/gui-agent 2>/dev/null | head -1 | awk '{print $1}')
if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
  printf '  ok    %-56s %s\n' "--list finds sites in agent/gui-agent" "$n"; pass=$((pass+1))
else
  printf '  FAIL  %-56s got %s\n' "--list finds sites in agent/gui-agent" "${n:-none}"; fail=$((fail+1))
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
