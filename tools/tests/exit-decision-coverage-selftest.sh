#!/usr/bin/env bash
# exit-decision-coverage-selftest.sh - every agent-exit DECISION must have its own log branch.
#
# WHY. The 2026-10-07 split added QGA_DECIDE_SESSION_END_REAPED - "the system ended it after an
# acknowledged notice and AFTER its orderly exit completed: INFO, no launch into that session" - with
# its table row and its verdict row (IsError FALSE, no relaunch, no death record, no service
# failure). The `case` in watchdog.c's switch was never added, so the decision fell through
# `default:`, which is grouped with QGA_DECIDE_DEATH, and a COMPLETED exit was logged as
# "QGAWDDEATH ... the agent DIED", with text claiming the service was ending for the SCM's recovery
# when FailService is FALSE and it was not.
#
# Measured on win11r-logvol 2026-10-08: the agent logged "QGAENDSESSION orderly exit complete" at
# 20261008.002013.438 and the watchdog logged QGAWDDEATH in the same second - one of the ten error
# lines the new binary wrote. Every action had been right; only the sentence was wrong. The header of
# qga-lifecycle.h says that split exists because "our own log carried one error per shutdown", so the
# half-applied fix left the very symptom it was written for.
#
# A decision added to the table without a log branch is silent by construction, so this is a
# STRUCTURAL check rather than a text one: the two lists must match.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HDR="$ROOT/agent/include/qga-lifecycle.h"
WD="$ROOT/agent/watchdog/watchdog.c"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
for f in "$HDR" "$WD"; do
  [ -f "$f" ] || { echo "FAIL  $f is missing - nothing ran (missing data fails)"; exit 2; }
done
T=$(mktemp -d "${TMPDIR:-/tmp}/exitdec-XXXXXX")

# ---- 1. every decision the table can return has a case in the switch --------------------------
command grep -oE 'QGA_DECIDE_[A-Z_]+' "$HDR" | sort -u > "$T/table"
command grep -oE 'case QGA_DECIDE_[A-Z_]+' "$WD" | sed 's/case //' | sort -u > "$T/switch"
missing=$(comm -23 "$T/table" "$T/switch" | tr '\n' ' ')
n_table=$(wc -l < "$T/table")
if [ -z "${missing// /}" ]; then
  ok "every_decision_has_a_branch: all $n_table decisions have a case in watchdog.c"
else
  bad "every_decision_has_a_branch: no case for:$missing - each falls through default: into QGAWDDEATH"
fi

# ---- 2. every decision has a VERDICT row too, or QgaDecideAgentExit returns the wrong one -----
# Its fallback comment says "unreachable: every decision has a row", which only holds if they do.
nov=""
while read -r d; do
  command grep -qE "\{ *$d," "$HDR" || nov="$nov $d"
done < "$T/table"
if [ -z "${nov// /}" ]; then
  ok "every_decision_has_a_verdict: no decision falls back to the last verdict row"
else
  bad "every_decision_has_a_verdict: no verdict row for:$nov"
fi

# ---- 3. the REAPED row is INFO and takes no action, and its branch agrees ---------------------
# This is the row the measured defect was on: the actions were already right, the sentence was not.
row=$(command grep -E '\{ *QGA_DECIDE_SESSION_END_REAPED,' "$HDR" | head -1)
if printf '%s' "$row" | command grep -qE 'FALSE, *TRUE, *FALSE, *FALSE, *FALSE'; then
  ok "reaped_takes_no_action: no relaunch, no death record, no service failure, not an error"
else
  bad "reaped_takes_no_action: the verdict row changed: $row"
fi
if sed -n '/case QGA_DECIDE_SESSION_END_REAPED:/,/break;/p' "$WD" | command grep -q 'LogInfo('; then
  ok "reaped_is_logged_at_info: its branch logs at INFO, matching IsError FALSE"
else
  bad "reaped_is_logged_at_info: its branch does not log at INFO - the row says it is not an error"
fi

# ---- 4. THE CHECK MUST FAIL WITH THE DEFECT PRESENT ------------------------------------------
# Drive it against a copy with the case removed - the state that shipped.
cp "$WD" "$T/wd-defect.c"
python3 - "$T/wd-defect.c" <<'PY'
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
i = s.index("    case QGA_DECIDE_SESSION_END_REAPED:")
j = s.index("    case QGA_DECIDE_SESSION_END_FORCED:", i)
io.open(p, "w", encoding="utf-8").write(s[:i] + s[j:])
PY
command grep -oE 'case QGA_DECIDE_[A-Z_]+' "$T/wd-defect.c" | sed 's/case //' | sort -u > "$T/switch-defect"
if [ -n "$(comm -23 "$T/table" "$T/switch-defect")" ]; then
  ok "seen_to_fail: with the case removed the check reports it missing ($(comm -23 "$T/table" "$T/switch-defect" | tr '\n' ' '))"
else
  bad "seen_to_fail: removing the case did not break the check - it proves nothing"
fi

echo
echo "exit-decision-coverage-selftest: $pass passed, $fail failed"
rm -rf "$T"
[ "$fail" = 0 ] || exit 1
