#!/usr/bin/env bash
# release-cut-gate-selftest.sh - offline proof matrix for tools/hooks/release-cut-gate.sh
# (docs/ADR-acceptance.md section 4). The hook refuses a release CUT whose gate coverage does not
# include what the diff requires. Every case is driven against a FIXTURE repository, and each check is
# also seen to FAIL with the defect present (RELEASE_CUT_GATE_DEFECT=1 - nothing refuses, the state
# before this gate existed).
#
#   cut-no-receipt    a tag/release with no coverage receipt for this HEAD is BLOCKED, and the message
#                     says how to see what is required
#   cut-short         a receipt that misses a required suite is BLOCKED, naming it
#   cut-satisfied     a receipt that covers everything required ALLOWS the cut
#   passive           reads, builds, branch pushes and a tag DELETE are never touched
#   defect            with the knob set, every blocking case is allowed - so the checks can fail
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/tools/hooks/release-cut-gate.sh"
OUT="${RELEASE_CUT_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/release-cut-selftest-XXXXXX")}"
mkdir -p "$OUT"
bad=0; n=0
say() { printf '%s\n' "$*"; }
ok()   { n=$((n+1)); say "PASS  $1"; }
fail() { n=$((n+1)); bad=1; say "FAIL  $1"; [ -n "${2:-}" ] && say "      $2"; }
[ -f "$HOOK" ] || { say "FAIL  the hook is missing - nothing ran (missing data fails)"; exit 2; }

# ---- a fixture repository with the tool, a map, a ledger and a v-tag ----------------------------------
# TRIPWIRE ON THE REAL LEDGER. During this suite's development the tracked mgmt/gate-ledger.json in
# the working tree was found overwritten with this fixture's row - the gate's own record, replaced by
# a test's. It is not reproducible now that FX is exported and every fixture write is absolute, so
# the writer is NOT identified; this asserts the property instead of trusting the explanation. A
# suite that mutates tracked data must fail, not pass quietly.
REAL_LEDGER="$ROOT/mgmt/gate-ledger.json"
REAL_LEDGER_SUM=$(md5sum "$REAL_LEDGER" 2>/dev/null | cut -d' ' -f1)
export FX="$OUT/fx"; rm -rf "$FX"; mkdir -p "$FX"/{tools/hooks,mgmt,scratchpad,agent/gui-agent,packaging/setup}
cp "$ROOT/tools/gate-scope.py" "$ROOT/tools/ci-state.py" "$FX/tools/"
# the CI arm needs workflows to enumerate and a gh to answer for them. build.yml has no path
# filter (so it is DUE for every sha); test.yml is filtered, which exercises the inherit path.
mkdir -p "$FX/.github/workflows"
printf 'name: build\non:\n  push:\n    branches: [main]\n' > "$FX/.github/workflows/build.yml"
printf 'name: test\non:\n  push:\n    branches: [main]\n    paths:\n      - \x27guest/**\x27\n' > "$FX/.github/workflows/test.yml"
cat > "$OUT/gh" <<'STUB'
#!/bin/bash
# answers every workflow with $CI_STUB ("completed success" by default), headSha = the fixture HEAD
read -r st cn <<< "${CI_STUB:-completed success}"
printf '[{"headSha":"%s","status":"%s","conclusion":"%s","databaseId":7,"createdAt":"x"}]' "$CI_STUB_SHA" "$st" "$cn"
STUB
chmod +x "$OUT/gh"
cp "$HOOK" "$FX/tools/hooks/"
cd "$FX" && git init -q . && git config user.email t@t && git config user.name t
cat > mgmt/gate-scope.json <<'JSON'
{ "version": 1,
  "core":  { "suites": ["package-verify", "win11-clean"], "reason": "the core" },
  "full":  { "suites": ["package-verify", "win10-clean", "win11-clean", "failproof-faultinject"], "reason": "all" },
  "floor": { "releases": 10, "days": 21, "reason": "whichever first" },
  "patterns": { "agent/**": { "suites": ["win11-clean"], "reason": "the agent" },
                "packaging/setup/**": { "suites": ["full"], "reason": "the installer" },
                "mgmt/**": { "suites": [], "reason": "the harness" },
                "scratchpad/**": { "suites": [], "reason": "gitignored working material" },
                "tools/**": { "suites": [], "reason": "dev tooling" } } }
JSON
# THE LEDGER'S FULL ROW HAS TO BE HONESTLY FULL. It claimed full=true over ONE of the four
# suites, which was fine while gate-scope's floor READ that flag - and the day the floor started
# DERIVING fullness from `covered`, this fixture's floor tripped, gate-scope demanded the FULL
# set for a one-file agent diff, and three checks here failed with "required 4, covered 2". The
# fixture exercises coverage satisfaction, so its baseline row covers the full set; a short row
# is exercised deliberately in its own check at the end.
NOW="$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)"
printf 'x\n' > agent/gui-agent/main.c
git add -A >/dev/null && git commit -qm base
python3 - "$NOW" "$(git log -1 --format=%H -- mgmt/gate-scope.json)" <<'PY'
import json, sys
json.dump({"releases": [{"version": "1.0", "date": sys.argv[1], "range": "", "required": [],
                         "covered": ["package-verify", "win10-clean", "win11-clean",
                                     "failproof-faultinject"],
                         "full": True, "result": "pass",
                         "map_commit": sys.argv[2]}]}, open('mgmt/gate-ledger.json', 'w'), indent=1)
PY
git add -A >/dev/null && git commit -qm ledger && git tag v1.0
printf 'y\n' >> agent/gui-agent/main.c && git add -A >/dev/null && git commit -qm "an agent change"
HEAD12="$(git rev-parse HEAD | cut -c1-12)"

hook() { # $1 command; prints rc, stderr to $OUT/last.err
    printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" |
        GH_BIN="$OUT/gh" CI_STUB_SHA="$(git -C "$FX" rev-parse HEAD)" CI_STUB="${CI_STUB:-completed success}" \
        CLAUDE_PROJECT_DIR="$FX" bash "$FX/tools/hooks/release-cut-gate.sh" 2>"$OUT/last.err" >/dev/null
    echo $?
}
knob() { printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" |
        GH_BIN="$OUT/gh" CI_STUB_SHA="$(git -C "$FX" rev-parse HEAD)" \
        RELEASE_CUT_GATE_DEFECT=1 CLAUDE_PROJECT_DIR="$FX" bash "$FX/tools/hooks/release-cut-gate.sh" 2>/dev/null >/dev/null
    echo $?; }

CUT='git tag -a v1.1-agentdeadbee -m release'

# ---- no receipt ------------------------------------------------------------------------------------
rc=$(hook "$CUT")
if [ "$rc" -eq 2 ] && grep -q 'no gate-coverage receipt' "$OUT/last.err" && grep -q 'gate-scope.py required' "$OUT/last.err"; then
    ok "cut-no-receipt: a tag with no receipt for this HEAD is BLOCKED and the message says how to see what is required"
else fail "cut-no-receipt (rc=$rc)" "$(head -2 "$OUT/last.err")"; fi
[ "$(knob "$CUT")" -eq 0 ] && ok "knob cut-no-receipt: with RELEASE_CUT_GATE_DEFECT=1 it is allowed (the check is seen to fail)" ||
    fail "knob cut-no-receipt: the knob did not disable the gate"

# ---- a receipt that is short ------------------------------------------------------------------------
printf '{"suites":["package-verify"]}\n' > "scratchpad/gate-coverage-$HEAD12.json"
rc=$(hook "$CUT")
if [ "$rc" -eq 2 ] && grep -q 'REFUSED' "$OUT/last.err" && grep -q 'win11-clean' "$OUT/last.err"; then
    ok "cut-short: a receipt missing a required suite is BLOCKED, naming the suite"
else fail "cut-short (rc=$rc)" "$(head -3 "$OUT/last.err")"; fi
[ "$(knob "$CUT")" -eq 0 ] && ok "knob cut-short: allowed with the knob set (the check is seen to fail)" ||
    fail "knob cut-short: the knob did not disable the gate"

# ---- a receipt that covers it -----------------------------------------------------------------------
printf '{"suites":["package-verify","win11-clean"]}\n' > "scratchpad/gate-coverage-$HEAD12.json"
rc=$(hook "$CUT")
if [ "$rc" -eq 0 ]; then ok "cut-satisfied: a receipt covering every required suite allows the cut"
else fail "cut-satisfied (rc=$rc)" "$(head -3 "$OUT/last.err")"; fi

# ---- COVERAGE SATISFIED BUT CI RED: still blocked --------------------------------------------------
# The receipt says the right suites ran on a guest; it says nothing about whether the code compiles.
# On 2026-10-11 build.yml was red for 14 runs while release-package was green and nothing in the cut
# path asked (CIREDUNREAD). The receipt below is the SAME one that just allowed the cut.
rc=$(CI_STUB="completed failure" hook "$CUT")
if [ "$rc" -eq 2 ] && grep -q 'CI is not green' "$OUT/last.err" && grep -q 'RED  build.yml' "$OUT/last.err"; then
    ok "cut-ci-red: full coverage plus a RED required workflow is BLOCKED, naming the workflow"
else fail "cut-ci-red (rc=$rc)" "$(head -3 "$OUT/last.err")"; fi
[ "$(CI_STUB='completed failure' knob "$CUT")" -eq 0 ] && ok "knob cut-ci-red: allowed with the knob set (the check is seen to fail)" ||
    fail "knob cut-ci-red: the knob did not disable the gate"

# an UNFINISHED required workflow is 'no verdict', never a pass
rc=$(CI_STUB="in_progress -" hook "$CUT")
if [ "$rc" -eq 2 ] && grep -q 'CI is not green' "$OUT/last.err"; then
    ok "cut-ci-running: an unfinished required workflow blocks the cut (no verdict is not a pass)"
else fail "cut-ci-running (rc=$rc)" "$(head -3 "$OUT/last.err")"; fi

# ---- passive commands are never touched ------------------------------------------------------------
pass_all=1
for c in 'git status' 'git push origin fix/branch' 'gh run watch 123' 'git tag -d v1.0' 'tools/release-acceptance.sh --run 1' 'git log --oneline'; do
    rm -f "scratchpad/gate-coverage-$HEAD12.json"
    r=$(hook "$c"); [ "$r" -eq 0 ] || { pass_all=0; say "      '$c' was blocked (rc=$r)"; }
done
[ $pass_all -eq 1 ] && ok "passive: reads, a branch push, a tag delete and running the acceptance are never blocked" ||
    fail "passive: something harmless was blocked"

# ---- THE FLOOR IS DERIVED, NOT DECLARED ------------------------------------------------------------
# mgmt/gate-ledger.json's only full=true row covered 13 of 18 suites with an empty map_commit, and
# the floor READ the flag - so for two weeks the debt was recorded as paid and a mapped-only receipt
# satisfied the gate. The floor now derives fullness from `covered`. With a row that CLAIMS full but
# covers one suite of four, a receipt covering just the mapped suites must be REFUSED and the full
# set required. INSERTED ABOVE THE SUMMARY ON PURPOSE: a leg added after it would never be counted.
python3 - "$NOW" "$(git -C "$FX" log -1 --format=%H -- mgmt/gate-scope.json)" <<'PYSHORT'
import json, sys, os
json.dump({"releases": [{"version": "1.0", "date": sys.argv[1], "range": "", "required": [],
                         "covered": ["package-verify"], "full": True, "result": "pass",
                         "map_commit": sys.argv[2]}]},
          open(os.path.join(os.environ["FX"], 'mgmt/gate-ledger.json'), 'w'), indent=1)
PYSHORT
printf '{"suites":["package-verify","win11-clean"]}\n' > "$FX/scratchpad/gate-coverage-$HEAD12.json"
rc=$(hook "$CUT")
if [ "$rc" -eq 2 ] && command grep -qa 'REFUSED' "$OUT/last.err" \
   && command grep -qaE 'win10-clean|failproof-faultinject' "$OUT/last.err"; then
    ok "floor-derived: a full=true row covering 1 of 4 forces the FULL set, and a mapped-only receipt is refused"
else fail "floor-derived (rc=$rc)" "$(head -3 "$OUT/last.err")"; fi
# restore the honest row so nothing after this inherits the short one
python3 - "$NOW" "$(git -C "$FX" log -1 --format=%H -- mgmt/gate-scope.json)" <<'PYFULL'
import json, sys, os
json.dump({"releases": [{"version": "1.0", "date": sys.argv[1], "range": "", "required": [],
                         "covered": ["package-verify", "win10-clean", "win11-clean",
                                     "failproof-faultinject"],
                         "full": True, "result": "pass", "map_commit": sys.argv[2]}]},
          open(os.path.join(os.environ["FX"], 'mgmt/gate-ledger.json'), 'w'), indent=1)
PYFULL

now_sum=$(md5sum "$REAL_LEDGER" 2>/dev/null | cut -d' ' -f1)
if [ "$now_sum" = "$REAL_LEDGER_SUM" ]; then
    ok "the tracked mgmt/gate-ledger.json is untouched by this suite"
else
    fail "THIS SUITE MODIFIED THE TRACKED LEDGER" "$REAL_LEDGER changed ($REAL_LEDGER_SUM -> $now_sum); restore it with: git checkout -- mgmt/gate-ledger.json"
fi

say "--- $n check(s), $( [ $bad -eq 0 ] && echo 0 || echo 'at least 1') failed; fixtures in $OUT"
exit $bad
