#!/bin/bash
# PROTOCOL SELFTEST — every gate seen to fire before anything is trusted (H5 applied to the
# runner itself, same doctrine as tools/tests/lint-selftest.sh).
#
# Order matters and is the point:
#   1. The LOADER's falsifiability gate is itself falsified: a planted steps file with an
#      undeclared defect must be REFUSED. A gate never seen to refuse proves nothing.
#   2. All real step files must load.
#   3. Every defect-* scenario is walked (dry, truth-auto-answered) and graded against its
#      ground truth; --harvest records a dry-grade fail-proof for each check OBSERVED to fail
#      on its defect-armed fixture. This is how failproofs.json is EARNED, never hand-written.
#   4. The green scenario runs LAST and must end with every check plain PASS - which can only
#      happen because step 3 put the proofs on record (V1 exercised end to end).
#
# Exit 0 = all green. Non-zero = the protocol machinery cannot be trusted; fix before any use.
set -uo pipefail
cd "$(dirname "$0")/.."
TS=$(date -u +%Y%m%d-%H%M%S)
fail=0

echo "== 1. loader refuses an unfalsifiable check =="
if python3 protocol/run.py validate --steps protocol/tests/bad-steps-no-defect.json --no-scenarios >/dev/null 2>&1; then
  echo "SELFTEST FAIL: the loader ACCEPTED a check with no declared defect/fail-route"
  fail=1
else
  echo "ok: load refused"
fi

echo "== 2. real step files load =="
python3 protocol/run.py validate || fail=1

echo "== 3. defect scenarios: each check seen to fail, proofs harvested =="
for dir in protocol/scenarios/defect-*/; do
  name=$(basename "$dir")
  cid="st-$name-$TS"
  PROTOCOL_SELFTEST=1 python3 protocol/run.py start --campaign "$cid" \
      --mode dry --scenario "$name" --auto-answer-truth >"protocol/state/.$cid.log" 2>&1
  rc=$?
  if [ "$rc" -ge 2 ]; then
    # a HALT is a normal end state; only a runner crash (exit >= 2) is a selftest failure
    echo "SELFTEST FAIL: $name - runner error rc=$rc (see protocol/state/.$cid.log)"
    fail=1
    continue
  fi
  if python3 protocol/grade.py "$cid" --harvest >/tmp/grade.$$ 2>&1; then
    echo "ok: $name matches ground truth ($(grep -o 'harvested.*' /tmp/grade.$$))"
  else
    echo "SELFTEST FAIL: $name deviates from ground truth:"
    sed 's/^/    /' /tmp/grade.$$
    fail=1
  fi
done
rm -f /tmp/grade.$$

echo "== 4. green scenarios (all parts): clean walks; the SPINE additionally reaches COMPLETE =="
for gdir in protocol/scenarios/green*/; do
  gname=$(basename "$gdir")
  cid="st-$gname-$TS"
  PROTOCOL_SELFTEST=1 python3 protocol/run.py start --campaign "$cid" \
    --mode dry --scenario "$gname" --auto-answer-truth >"protocol/state/.$cid.log" 2>&1
  rc=$?
  if [ "$rc" -ge 2 ]; then
    echo "SELFTEST FAIL: $gname - runner error rc=$rc (see protocol/state/.$cid.log)"
    fail=1
    continue
  fi
  if python3 protocol/grade.py "$cid" >/tmp/grade.$$ 2>&1; then
    echo "ok: $gname walk matches ground truth"
  else
    echo "SELFTEST FAIL: $gname deviates:"
    sed 's/^/    /' /tmp/grade.$$
    fail=1
  fi
done
rm -f /tmp/grade.$$
# the spine's green is the strict V1 exerciser: every check plain PASS -> COMPLETE. Part greens
# may carry PASS-UNPROVEN (their truths say so) and declare rows, so only the spine gets this bar.
cid="st-green-$TS"
if python3 protocol/run.py verdicts --campaign "$cid" | grep -q '^VERDICT: COMPLETE'; then
  echo "ok: spine campaign-verdict arithmetic says COMPLETE"
else
  echo "SELFTEST FAIL: spine green did not reach COMPLETE (a PASS is missing its fail-proof?)"
  python3 protocol/run.py verdicts --campaign "$cid" | sed 's/^/    /'
  fail=1
fi

[ "$fail" -eq 0 ] && echo "SELFTEST: ALL GREEN" || echo "SELFTEST: FAILURES (fix before trusting any run)"
exit $fail
