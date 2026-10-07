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
FX="$OUT/fx"; rm -rf "$FX"; mkdir -p "$FX"/{tools/hooks,mgmt,scratchpad,agent/gui-agent,packaging/setup}
cp "$ROOT/tools/gate-scope.py" "$FX/tools/"
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
NOW="$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)"
printf 'x\n' > agent/gui-agent/main.c
git add -A >/dev/null && git commit -qm base
python3 - "$NOW" "$(git log -1 --format=%H -- mgmt/gate-scope.json)" <<'PY'
import json, sys
json.dump({"releases": [{"version": "1.0", "date": sys.argv[1], "range": "", "required": [],
                         "covered": ["package-verify"], "full": True, "result": "pass",
                         "map_commit": sys.argv[2]}]}, open('mgmt/gate-ledger.json', 'w'), indent=1)
PY
git add -A >/dev/null && git commit -qm ledger && git tag v1.0
printf 'y\n' >> agent/gui-agent/main.c && git add -A >/dev/null && git commit -qm "an agent change"
HEAD12="$(git rev-parse HEAD | cut -c1-12)"

hook() { # $1 command; prints rc, stderr to $OUT/last.err
    printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" |
        CLAUDE_PROJECT_DIR="$FX" bash "$FX/tools/hooks/release-cut-gate.sh" 2>"$OUT/last.err" >/dev/null
    echo $?
}
knob() { printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" |
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

# ---- passive commands are never touched ------------------------------------------------------------
pass_all=1
for c in 'git status' 'git push origin fix/branch' 'gh run watch 123' 'git tag -d v1.0' 'tools/release-acceptance.sh --run 1' 'git log --oneline'; do
    rm -f "scratchpad/gate-coverage-$HEAD12.json"
    r=$(hook "$c"); [ "$r" -eq 0 ] || { pass_all=0; say "      '$c' was blocked (rc=$r)"; }
done
[ $pass_all -eq 1 ] && ok "passive: reads, a branch push, a tag delete and running the acceptance are never blocked" ||
    fail "passive: something harmless was blocked"

say "--- $n check(s), $( [ $bad -eq 0 ] && echo 0 || echo 'at least 1') failed; fixtures in $OUT"
exit $bad
