#!/bin/bash
# reporter-env-gate-selftest.sh - prove tools/hooks/reporter-env-gate.sh blocks what it must and
# passes what it must, offline, on synthetic hook input.
#
# Per this project's rule a check counts only once it has been seen to FAIL on the defect:
#   REPORTER_GATE_DEFECT=1  - the hook enforces nothing (= the state before 2026-09-16)
#                             -> the must-block cases pass through -> THIS TEST MUST FAIL (exit 1)
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
HOOK=tools/hooks/reporter-env-gate.sh
[ -f mgmt/reporters/gweck.json ] || { echo "FATAL: mgmt/reporters/gweck.json missing - the gate has nothing to enforce"; exit 2; }
grep -q 'GUARD:reporter-gate' "$HOOK" || { echo "FATAL: defect-knob guard line missing from $HOOK"; exit 2; }
pass=0; fail=0
run(){ # $1=label $2=expected-exit $3=tool_name $4=json-of-tool_input
  local out rc
  out=$(printf '{"tool_name":"%s","tool_input":%s}' "$3" "$4" | bash "$HOOK" 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then pass=$((pass+1)); echo "ok    $1 (exit $rc)"
  else fail=$((fail+1)); echo "FAIL  $1: expected exit $2, got $rc"; [ -n "$out" ] && echo "      $out" | head -3; fi
}
j(){ python3 -c 'import json,sys; print(json.dumps({sys.argv[1]: sys.argv[2]}))' "$1" "$2"; }

run "Agent names GWeck + drives the rig, no env-assert -> BLOCK" 2 Agent \
  "$(j prompt "Reproduce GWeck's update failure: qvm-create win11-x, qtest run the scan, capture the logs")"
run "Workflow script names gweck + rig, no env-assert -> BLOCK" 2 Workflow \
  "$(j script "const r = await agent('match gweck: mgmt/harness/quick-upgrade.sh then prime-run ...')")"
run "same launch WITH env-assert for gweck -> allow" 0 Workflow \
  "$(j script "await agent('qvm-start win11de-gwt; mgmt/harness/env-assert.sh win11de-gwt gweck || exit 3; then GWeck test')")"
run "env-assert for a DIFFERENT reporter key does not satisfy -> BLOCK" 2 Agent \
  "$(j prompt "GWeck repro on the rig: qtest run ...; mgmt/harness/env-assert.sh win11de-gwt someoneelse")"
run "read-only launch naming GWeck (no rig tokens) -> allow" 0 Agent \
  "$(j prompt "Fetch and summarise GWeck's latest forum posts about updates; no rig work")"
run "rig launch naming nobody -> allow" 0 Agent \
  "$(j prompt "quick-upgrade.sh win11-up with the latest release package; qtest shot")"
run "alias 'Gerhard Weck' counts as the reporter -> BLOCK" 2 Agent \
  "$(j prompt "Dr. Gerhard Weck's setup: qvm-prefs win11-x netvm ''; run the updater")"
run "substring inside a word is not the reporter (e.g. 'GWeckx') -> allow" 0 Agent \
  "$(j prompt "matrix.sh cell for GWeckx fixture")"
run "malformed hook input never blocks" 0 Agent 'not-json'

echo "summary: $pass passed, $fail failed"
if [ "${REPORTER_GATE_DEFECT:-}" = "1" ]; then
  [ "$fail" -gt 0 ] && { echo "DEFECT KNOB: the gate let a must-block launch through, and this test FAILED on it - the check is proven able to fail"; exit 1; }
  echo "DEFECT KNOB: the test did NOT fail with enforcement disabled - the check is worthless"; exit 1
fi
[ "$fail" -eq 0 ]
