#!/bin/bash
# grade-receipt.sh <receipt-out-dir> <since-utc> <vm> - the FULL verdict for a noise receipt.
#
# WHY IT IS NOT JUST grade-noise.py. That tool greps five patterns I chose. The owner's standing rule
# is the opposite: "RUN THE SWEEP; never grep one emitter" - four wrong-tag false negatives in one
# morning on 2026-10-10, and the sweep over the full history then found 13 breaches the greps had
# missed. A hand-picked pattern list in a nicer wrapper is the same mistake, so the sweep runs too and
# its verdict counts.
#
#   1. grade-noise.py   the four named conditions: no QGADIRECTSUPPRESS, no send by either route,
#                       BOTH hold tags present and INFO, the window delivered and never mapped black,
#                       plus the LEDGER - what dom0-sends actually pulled off the guest
#   2. log-sweep.sh     everything I did not think to grep, bounded to this run by --since
#
# rc 0 only if both agree. Either one failing is a failing receipt; the sweep reporting itself
# INCOMPLETE is not a pass either (missing data fails).
#
# SWEEP_BIN and LEDGER are overridable ONLY so both arms are provable without the rig, the same
# reason GH_BIN and QTEST_BIN are elsewhere here. A real run sets neither.
# tools/tests/grade-receipt-selftest.sh drives all four combinations.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
OUT="${1:?usage: grade-receipt.sh <receipt-out-dir> <since-utc> <vm>}"
SINCE="${2:?a since-utc like 2026-10-11T08:00:00Z - the sweep and the ledger are both bounded by it}"
# NAMED, never defaulted (lint L10): a defaulted guest is how a receipt gets graded against the
# wrong one, and the ledger arm filters by this exact name.
VM="${3:?name the guest explicitly - a defaulted target grades the wrong one}"
[ -d "$OUT" ] || { echo "GRADE 2 $OUT is not a directory"; exit 2; }
L="$OUT/grade.log"; : > "$L"
say(){ echo "$*" | tee -a "$L"; }

say "=== 1. the four named conditions, plus the ledger ==="
python3 tools/grade-noise.py "$OUT/agent-excerpt.txt" \
  --pixels "$OUT/pixel-lines.txt" \
  --ledger "${LEDGER:-scratchpad/dom0-notifications.jsonl}" --vm "$VM" --since "$SINCE" 2>&1 | tee -a "$L"
g=${PIPESTATUS[0]}

say ""
say "=== 2. the sweep: everything I did not think to grep (since $SINCE) ==="
# A STALE SWEEP IS NOT THIS SWEEP. Re-grading a receipt dir would otherwise read the PREVIOUS
# sweep's summary.txt and report its verdict as this one's - found by this tool's own selftest,
# where one arm silently graded the arm before it. The old one is kept, never deleted: it is
# evidence. (rig-cycle: a stale artefact from a previous run is not this run's evidence.)
if [ -e "$OUT/sweep" ]; then
  mv "$OUT/sweep" "$OUT/sweep-prev-$(date -u +%H%M%SZ)" || { say "GRADE 2 could not move the previous sweep aside"; exit 2; }
  say "  (a previous sweep/ was moved aside, not read)"
fi
# SWEEP_BIN is overridable ONLY so both arms are provable without the rig, the same reason
# GH_BIN and QTEST_BIN are. A real run never sets it.
if bash "${SWEEP_BIN:-mgmt/harness/log-sweep.sh}" "$VM" "$SINCE" "$OUT/sweep" 2>&1 | tail -25 | tee -a "$L"; then
  s=0
else
  s=$?
fi
# the sweep's own summary is the record; INCOMPLETE is not a pass
if [ -s "$OUT/sweep/summary.txt" ]; then
  say "--- sweep summary head ---"
  head -20 "$OUT/sweep/summary.txt" | tee -a "$L"
  if command grep -aqiE "INCOMPLETE" "$OUT/sweep/summary.txt"; then
    say "SWEEP INCOMPLETE - it could not grade part of what it collected; that is not a pass"
    s=1
  fi
else
  say "SWEEP produced no summary - missing data fails"
  s=1
fi

say ""
case "$g$s" in
  00) say "RECEIPT 0 PASS: the named conditions hold AND the sweep found nothing" ;;
  *)  say "RECEIPT 1 FAIL: grade-noise rc=$g, sweep rc=$s - see $L" ;;
esac
[ "$g" = 0 ] && [ "$s" = 0 ]
