#!/bin/bash
# matrix-sweep-tally-selftest.sh - one failure, one tally entry; and still printed.
#
# WHY. matrix.sh's no() both increments the campaign tally AND writes the failure into the campaign
# log as "[ERROR] FAIL  <what>". The end-of-campaign error gate then sweeps that same log, so each
# graded verdict came back as an UNACCOUNTED row and added a SECOND entry - classed INVALID, which
# asserts that nothing graded it. One failure, two entries, wrong class on the second.
#
# Jev was asked to choose between dropping those lines from the gate and keeping them, with the
# project's rules as premises, and chose neither: keep_but_reclass (0.63) - still show the line,
# because a declared error that stops being shown is how the original incident happened, but do not
# move the counter for a verdict that was already graded. These checks pin that behaviour.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

T=$(mktemp -d "${TMPDIR:-/tmp}/matrix-sweep-tally-selftest.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: expected '$2', got '$3'"; fi; }

M=$(ls mgmt/harness/matri*.sh | head -1)

# A campaign log with BOTH shapes: our own graded verdict, and a sub-script's ungraded stderr.
# The second has no tally entry anywhere and must still move the counter.
printf '[15:06:07] [ERROR] FAIL  WIN10-reinstall: could not write the run marker\n' >  "$T/matrix.log"
printf '[15:06:54] FAIL: could not clear the previous module table (got no answer)\n' >> "$T/matrix.log"
printf '[15:07:00] [WARN] log-volume bind failed on the upgrade cell\n'              >> "$T/matrix.log"
timeout 100 bash tools/sweep-gate.sh "$T/matrix.log" > "$T/sweep.out" 2>&1

# The gate still SHOWS the graded verdict - that is the half Jev kept.
ck "the graded verdict is still printed by the gate" "1" \
   "$(grep -acE '^  UNACCOUNTED .*\[(ERROR|WARN)\] FAIL +' "$T/sweep.out")"

# matrix.sh's arithmetic, applied to this real gate output.
nun=$(grep -ac '^  UNACCOUNTED' "$T/sweep.out" 2>/dev/null || true); nun=${nun:-0}
ngr=$(grep -acE '^  UNACCOUNTED .*\[(ERROR|WARN)\] FAIL +' "$T/sweep.out" 2>/dev/null || true); ngr=${ngr:-0}
net=$((nun - ngr)); [ "$net" -lt 0 ] && net=0

ck "the graded verdict is discounted from the tally" "1" "$ngr"
ck "the ungraded line still counts"                  "1" "$([ "$net" -ge 1 ] && echo 1 || echo "0 (net=$net of nun=$nun)")"

# A log carrying ONLY graded verdicts must raise nothing, while the gate still exits non-zero.
printf '[15:06:07] [ERROR] FAIL  WIN10-clean: a graded product check\n' > "$T/only-graded.log"
timeout 100 bash tools/sweep-gate.sh "$T/only-graded.log" > "$T/only.out" 2>&1
onun=$(grep -ac '^  UNACCOUNTED' "$T/only.out" 2>/dev/null || true); onun=${onun:-0}
ongr=$(grep -acE '^  UNACCOUNTED .*\[(ERROR|WARN)\] FAIL +' "$T/only.out" 2>/dev/null || true); ongr=${ongr:-0}
onet=$((onun - ongr)); [ "$onet" -lt 0 ] && onet=0
ck "a graded-only log adds no INVALID entry"         "0" "$onet"

# And the shipped file must carry the guard, not just this test.
ck "matrix.sh discounts graded verdicts"            "1" "$(grep -c 'ngr=\$(grep -acE' "$M")"
ck "matrix.sh raises INVALID-SWEEP conditionally"   "1" "$(grep -c 'if \[ \$((nun + nro)) -gt 0 \]; then' "$M")"
# THE PATTERN BROADENED 2026-10-25 and this assertion pinned the old spelling. An UPSTREAM rise is
# printed by sweep-gate.sh:819 with ROSE MID-LINE ("x12 ... <== ROSE from x4"), so the anchored
# '^  (UNACCOUNTED|ROSE)' displayed none of them - measured on cell WIN10-upgrade, where the gate
# failed with risen=5 and the operator was shown zero of the five rows. "Prints every row" is the
# intent; this now checks the spelling that actually does.
ck "matrix.sh still prints every row"               "1" "$(grep -c "grep -aE '\^  (UNACCOUNTED|ROSE)|<== ROSE from'" "$M")"

# A GATE FAILURE THE TALLY CANNOT COUNT MUST NOT PASS SILENTLY. Measured on campaign
# 20261018-153728: the gate exited 1 over a stale declaration, this arithmetic counted zero
# UNACCOUNTED and zero ROSE, and the campaign reported rc=0 with 42 passed, 0 failed. A guard the
# harness cannot hear is decoration, and that one was mine, introduced the same day.
printf '[15:06:07] [INFO] nothing declared here at all\n' > "$T/clean.log"
timeout 100 bash tools/sweep-gate.sh --declare-caused 'NeverAppearsAnywhere' 'a stale always-claim' \
    "$T/clean.log" > "$T/unclassed.out" 2>&1; urc=$?
unun=$(grep -ac '^  UNACCOUNTED' "$T/unclassed.out" 2>/dev/null || true); unun=${unun:-0}
unro=$(grep -ac '^  ROSE' "$T/unclassed.out" 2>/dev/null || true); unro=${unro:-0}
ck "the gate FAILS on a stale always-declaration"        "1" "$([ "$urc" -ne 0 ] && echo 1 || echo 0)"
ck "and it does so with NO row the old tally counts"     "0" "$((unun + unro))"
# SEEN TO FAIL: the old arithmetic alone - rows only - raises nothing for that exit code.
ck "old rule alone: this failure would be SILENT"        "0" "$([ $((unun + unro)) -gt 0 ] && echo 1 || echo 0)"
# The shipped guard is what turns it into a verdict.
ck "matrix.sh captures the gate's exit code"             "1" "$(grep -c '_sg_rc=\$?' "$M")"
ck "matrix.sh raises on a failure it cannot class"       "1" "$(grep -c 'INVALID-SWEEP-UNCLASSED' "$M")"

# AND THE RARE KIND MUST NOT FAIL A RUN. The same mechanism, declared rare: reported, exit 0.
timeout 100 bash tools/sweep-gate.sh --declare-caused-rare 'NeverAppearsAnywhere' 'rare, may not occur' \
    "$T/clean.log" > "$T/rare.out" 2>&1; rrc=$?
ck "a RARE declaration that did not match does not fail" "0" "$([ "$rrc" -ne 0 ] && echo 1 || echo 0)"
ck "and it is still REPORTED, not silent"                "1" "$(grep -ac 'declared-caused (rare) not seen this run' "$T/rare.out")"

# THE TWO INSTRUMENTS MUST CARRY THE SAME CAUSED-DISPOSITIONS. log-sweep grades each cell and
# sweep-gate grades the campaign, over the same logs; matrix.sh passes --tolerate-error to the first
# and --declare-caused* to the second. For a while it passed only SOME of them to the second, so each
# campaign failed on whichever disposition was missing - 20261018-153728 on a shutdown-killed task,
# then 20261018-163605 on "wmain: open agent pipe failed with error 0x2" x2, which the per-cell sweep
# had declared all along. One campaign, two graders, one set.
drift=$(python3 - <<'PYD'
import re
s = open('mgmt/harness/matrix.sh', encoding='utf-8').read()
tol = re.findall(r"--tolerate-error '([^']*)'", s)
dec = " ".join(re.findall(r"--declare-caused(?:-rare)? '([^']*)'", s))
# each per-cell regex must be represented to the gate; compare on its first alternative's head,
# which is stable against the parenthesised grouping the per-cell form uses
missing = [t for t in tol if t.strip('()').split('|')[0][:28] not in dec]
print(len(missing))
PYD
)
ck "every per-cell caused-disposition is also declared to the gate" "0" "$drift"

# AND THE GUARD MUST NOT DOUBLE-REPORT A FAILURE THE TALLY ALREADY HOLDS. Measured on campaign
# 20261018-172640: two cells failed, the gate listed both as UNACCOUNTED, the discount took nun to 0
# because they are already in the cell tally - and the unclassed guard then raised them a second
# time. One failure, two entries, wrong class on the second: the very defect this file exists to
# prevent, reintroduced by the guard meant to stop silences. The fix is that the guard keys on the
# RAW row count, so a gate failure that listed anything is "explained".
printf '[15:06:07] [ERROR] FAIL  WIN10-clean: a graded product check\n' > "$T/graded-only2.log"
timeout 100 bash tools/sweep-gate.sh "$T/graded-only2.log" > "$T/go2.out" 2>&1; g2rc=$?
g2raw=$(grep -ac '^  UNACCOUNTED' "$T/go2.out" 2>/dev/null || true); g2raw=${g2raw:-0}
g2gr=$(grep -acE '^  UNACCOUNTED .*\[(ERROR|WARN)\] FAIL +' "$T/go2.out" 2>/dev/null || true); g2gr=${g2gr:-0}
g2net=$((g2raw - g2gr)); [ "$g2net" -lt 0 ] && g2net=0
ck "a graded-only log: the gate still fails"                 "1" "$([ "$g2rc" -ne 0 ] && echo 1 || echo 0)"
ck "and the discount takes the countable rows to zero"       "0" "$g2net"
# The guard's condition, as shipped: raw rows present => NOT unclassed, so nothing is raised twice.
ck "the unclassed guard stays silent (raw rows explain it)"  "0" "$([ "$g2rc" -ne 0 ] && [ $((g2raw + 0)) -eq 0 ] && echo 1 || echo 0)"
# SEEN TO FAIL: the discounted count would have fired it, which is what happened in that campaign.
ck "SEEN TO FAIL: keyed on the DISCOUNTED count it fires"    "1" "$([ "$g2rc" -ne 0 ] && [ $((g2net + 0)) -eq 0 ] && echo 1 || echo 0)"
ck "matrix.sh keys the guard on the raw count"               "1" "$(grep -c 'nun_raw:-0' "$M")"

echo "matrix-sweep-tally-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
