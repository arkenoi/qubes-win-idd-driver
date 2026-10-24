#!/usr/bin/env bash
# acceptance-plan-selftest.sh - offline proof matrix for tools/acceptance-plan.py (PLAN-acceptance-optimization
# section 1: the single entry point that turns gate-scope's requirement into exact invocations).
#
# Driven against a FIXTURE repository (its own history, map and ledger, through GATE_SCOPE_ROOT - the same device
# tools/tests/gate-scope-selftest.sh uses), so the real tools/gate-scope.py computes the requirement. Each check is
# also seen to FAIL on a copy of the tool with ONE `# GUARD:<knob>` line replaced by its defect.
#
#   scoped      an agent-only diff plans the core + the agent's suites: ONE release-acceptance invocation over exactly
#               the required win11 cells (no win10 cell), the remainder driver for log-sweep, package-verify first
#   full        with the floor tripped (an old last full gate) every suite is planned, the FI suites need --fi-run,
#               and the plan is NOT ready without it (knob: fiblock)
#   targets     nothing is defaulted: missing subjects/goldens/run id are named in `blocked`, ready=false; with every
#               target given the commands carry them verbatim and ready=true
#   logvol      a plan with a guest-driving cell says the secondary volume is required - and that no harness attaches
#               one yet; a map whose core is package-verify alone, with a docs-only diff, says not required (knob: logvol)
#   exit2       gate-scope.py failing (a bad range) -> rc 2, no plan (knob: gatescope2)
#
#   PLAN_SELFTEST_OUT=<dir>  keep fixtures and outputs (default: a mktemp dir, removed on exit)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tools/acceptance-plan.py"
T="${PLAN_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/plan-selftest-XXXXXX")}"
[ -n "${PLAN_SELFTEST_OUT:-}" ] || trap 'rm -rf "$T"' EXIT
mkdir -p "$T"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$SRC" ] && [ -f "$ROOT/tools/gate-scope.py" ] || { echo "FAIL  the tool or gate-scope.py is missing - nothing ran"; exit 2; }

# ---- the fixture repository: the REAL map and ledger shapes, a small history ----------------------------------------
FX="$T/fx"; rm -rf "$FX"; mkdir -p "$FX"/{mgmt,agent/gui-agent,docs,packaging/setup}
cd "$FX" && git init -q . && git config user.email t@t && git config user.name t
cp "$ROOT/mgmt/gate-scope.json" mgmt/gate-scope.json
printf 'int main(void){return 0;}\n' > agent/gui-agent/main.c; printf '#pragma once\n' > agent/gui-agent/toasthold.h
printf 'notes\n' > docs/NOTES.md; printf '# installer\n' > packaging/setup/Install-Fixture.ps1
git add -A >/dev/null && git commit -qm base
mk_ledger(){ # $1 = last full gate's date
  python3 - "$1" "$(git log -1 --format=%H -- mgmt/gate-scope.json)" > mgmt/gate-ledger.json <<'PY'
import json, sys
json.dump({"releases": [{"version": "4.3.35", "date": sys.argv[1], "range": "", "required": [], "covered": ["package-verify"],
                         "full": True, "result": "pass", "map_commit": sys.argv[2]}]}, sys.stdout, indent=1)
PY
}
NOW="$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)"; OLD="$(date -u -d '-40 days' +%Y-%m-%dT%H:%M:%SZ)"
mk_ledger "$NOW"; git add -A >/dev/null && git commit -qm ledger && git tag v4.3.35
BASE=$(git rev-parse HEAD)
printf '// a toast change\n' >> agent/gui-agent/toasthold.h; git add -A >/dev/null && git commit -qm toast
H1=$(git rev-parse HEAD)

# the copy lives in a tools/ dir of its own with gate-scope.py beside it, as the real one has -
# and with release-feature-tests.txt, for the same reason: acceptance-plan.py READS that list
# instead of carrying its own copy (2026-10-22, after the plan silently planned three feature tests
# while release-acceptance.sh ran four), so the knob copies need it beside them or the tool dies
# before writing a plan. A fixture that lacks an input the tool reads tests nothing.
mkdir -p "$T/tools"; ln -sf "$ROOT/tools/gate-scope.py" "$T/tools/gate-scope.py"
ln -sf "$ROOT/tools/release-feature-tests.txt" "$T/tools/release-feature-tests.txt"
knob(){ local n="$1" out="$T/tools/plan-$1.py" hits
  hits=$(grep -c "# GUARD:$n DEFECT: " "$SRC")
  [ "$hits" = 1 ] || { echo "FATAL: GUARD:$n appears $hits times in $SRC (want exactly 1)" >&2; return 2; }
  sed -E "s|^( *)[^#]*# GUARD:$n DEFECT: (.*)$|\1\2|" "$SRC" > "$out"
  [ "$(diff "$SRC" "$out" | grep -c '^>')" = 1 ] || { echo "FATAL: knob $n changed $(diff "$SRC" "$out" | grep -c '^>') lines" >&2; return 2; }
  python3 -m py_compile "$out" || { echo "FATAL: knob $n does not compile" >&2; return 2; }
  printf '%s' "$out"; }
plan(){ local tool="$1" l="$2"; shift 2; GATE_SCOPE_ROOT="$FX" python3 "$tool" --out "$T/$l.json" "$@" > "$T/$l.out" 2>&1; echo $?; }
pf(){ python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$T/$1.json" "$2" 2>/dev/null; }

# ---- scoped ------------------------------------------------------------------------------------------------------------
rc=$(plan "$SRC" scoped --range "$BASE..$H1" --package-run 111 --g11 win11r-iqi --b11 win11r-base --f11 win11r --vm11 win11-acc --vm10 win10-acc --os11 win11r)
[ "$rc" = 0 ] && [ "$(pf scoped "r['gate']['full']")" = False ] && ok "scoped: a toast-only diff plans a SCOPED gate (rc 0)" || bad "scoped: rc=$rc $(tail -2 "$T/scoped.out")"
req=$(pf scoped "sorted(r['gate']['required'])")
[ "$req" = "['log-sweep', 'notify-errors-guest-test', 'package-verify', 'toast-hold-test', 'win11-clean', 'win11-upgrade']" ] && ok "scoped: required = the core + the toast suite: $req" || bad "scoped: required=$req"
ids=$(pf scoped "[c['id'] for c in r['cells']]")
[ "$ids" = "['package-verify', 'install-and-feature-cells', 'remainder-suites']" ] && ok "scoped: three cells in order - package-verify, then the install/feature driver, then the remainder driver" || bad "scoped: cells=$ids"
cmd=$(pf scoped "[c['command'] for c in r['cells'] if c['id']=='install-and-feature-cells'][0]")
printf '%s' "$cmd" | grep -q -- '--cells "win11-clean win11-upgrade"' && ! printf '%s' "$cmd" | grep -q 'win10' && ! printf '%s' "$cmd" | grep -q -- '--skip-features' \
  && printf '%s' "$cmd" | grep -q 'G11=win11r-iqi B11=win11r-base F11=win11r' && printf '%s' "$cmd" | grep -q -- '--run 111' \
  && ok "scoped: ONE release-acceptance invocation over exactly the required win11 cells, no win10 cell, feature tests on, targets verbatim" || bad "scoped: command: $cmd"
rcmd=$(pf scoped "[c['command'] for c in r['cells'] if c['id']=='remainder-suites'][0]")
[ "$rcmd" = "tools/gate-remainder.sh --run 111 --vm10 win10-acc --vm11 win11-acc --os11 win11r" ] && ok "scoped: the remainder driver carries the named subjects, no --fi-run (no FI suite required)" || bad "scoped: remainder: $rcmd"
pf scoped "[c['suites'] for c in r['cells'] if c['id']=='remainder-suites'][0]" | grep -q "log-sweep" && ok "scoped: the remainder cell covers log-sweep and toast-hold-test" || bad "scoped: remainder suites"
[ "$(pf scoped "r['ready']")" = True ] && [ "$(pf scoped "r['blocked']")" = "[]" ] && ok "scoped: with every target given the plan is READY" || bad "scoped: ready=$(pf scoped "r['ready']") blocked=$(pf scoped "r['blocked']")"
pf scoped "[c['expected_exits'] for c in r['cells']]" | grep -q 'INVALID-\* line is instrument-fail' && ok "scoped: expected exits explain how to read a 1 (instrument vs product)" || bad "scoped: expected exits"
pf scoped "[c['cheapest_probes'] for c in r['cells'] if c['id']=='install-and-feature-cells'][0]" | grep -q 'qvm-check win11r-iqi' && pf scoped "r['cells'][0]['cheapest_probes']" | grep -q 'MANIFEST.json' \
  && ok "scoped: cheapest probes name the fixture checks and the package manifest" || bad "scoped: probes"
pf scoped "r['cells'][1]['on_non_pass']" | grep -q 'collect-failure.sh' && pf scoped "r['cells'][1]['on_non_pass']" | grep -q 'verdict-jev.py' && ok "scoped: every cell says what to do on a non-PASS exit (collector, then verdict)" || bad "scoped: on_non_pass"
[ "$(pf scoped "r['logvol']['required']")" = True ] && pf scoped "r['logvol']['harness_support']" | grep -q 'NOT YET' && ok "logvol: required for a guest-driving plan, and the plan says no harness attaches one yet" || bad "logvol: $(pf scoped "r['logvol']")"
[ "$(pf scoped "r['gate']['ledger']['last_full_gate']['version']")" = 4.3.35 ] && ok "scoped: the ledger's last full gate is read, never asserted" || bad "scoped: ledger: $(pf scoped "r['gate']['ledger']")"

# ---- targets: nothing defaulted -------------------------------------------------------------------------------------------
rc=$(plan "$SRC" bare --range "$BASE..$H1")
[ "$rc" = 0 ] && [ "$(pf bare "r['ready']")" = False ] && pf bare "r['blocked']" | grep -q -- '--package-run' && pf bare "r['blocked']" | grep -q -- '--g11/--b11' && pf bare "r['blocked']" | grep -q -- '--vm11' \
  && ok "targets: with nothing given the plan is written but NOT ready, naming every missing target" || bad "targets: rc=$rc ready=$(pf bare "r['ready']") blocked=$(pf bare "r['blocked']")"
pf bare "[c['command'] for c in r['cells']]" | grep -q '<release-package-run-id>' && ! pf bare "[c['command'] for c in r['cells']]" | grep -qE 'win1[01]-(acc|base|iqi)' \
  && ok "targets: no subject or golden is invented into a command" || bad "targets: a default target appeared: $(pf bare "[c['command'] for c in r['cells']]")"

# ---- full: the floor --------------------------------------------------------------------------------------------------------
mk_ledger "$OLD"; git add -A >/dev/null && git commit -qm old-ledger; H2=$(git rev-parse HEAD)
rc=$(plan "$SRC" full --range "$H1..$H2" --package-run 111 --g10 a --g11 b --b10 c --b11 d --f11 e --vm10 f --vm11 g --os11 h)
# THE EXPECTED COUNT COMES FROM THE MAP, NOT A LITERAL. This read `= 18 ]`, so the day a 19th suite
# was added to mgmt/gate-scope.json (updater-component, 2026-10-22) this leg failed on a correct
# plan - and because this suite is NOT in tools/tests/offline-suites.txt, the estate stayed green
# while it rotted. Deriving from the map under test is legitimate here: the map is the INPUT and the
# plan's required set is the OUTPUT, so this still asserts a real property (the floor requires the
# FULL set) rather than reading the plan's own bookkeeping back to itself.
FULLN=$(python3 -c "import json,sys;print(len(json.load(open('$SRC/mgmt/gate-scope.json'))['full']['suites']))")
[ "$(pf full "r['gate']['full']")" = True ] && pf full "r['gate']['floor']" | grep -q 'day(s) ago' && [ "$(pf full "len(r['gate']['required'])")" = "$FULLN" ] \
  && ok "full: the floor trips (an old last full gate) and all $FULLN suites are required" || bad "full: full=$(pf full "r['gate']['full']") floor=$(pf full "r['gate']['floor']") n=$(pf full "len(r['gate']['required'])")"
cmd=$(pf full "[c['command'] for c in r['cells'] if c['id']=='install-and-feature-cells'][0]")
printf '%s' "$cmd" | grep -q -- '--cells "win10-clean win10-reinstall win10-upgrade win10-appvm win11-clean win11-reinstall win11-upgrade win11-appvm"' && ok "full: all eight install cells in one invocation" || bad "full: command: $cmd"
[ "$(pf full "r['ready']")" = False ] && pf full "r['blocked']" | grep -q -- '--fi-run' && ok "full: NOT ready without --fi-run - the FI suites cannot run on an ordinary package" || bad "full: ready=$(pf full "r['ready']") blocked=$(pf full "r['blocked']")"
rc=$(plan "$SRC" fullfi --range "$H1..$H2" --package-run 111 --fi-run 222 --g10 a --g11 b --b10 c --b11 d --f11 e --vm10 f --vm11 g --os11 h)
[ "$(pf fullfi "r['ready']")" = True ] && pf fullfi "[c['command'] for c in r['cells'] if c['id']=='remainder-suites'][0]" | grep -q -- '--fi-run 222' && ok "full: with --fi-run the plan is ready and the remainder driver carries it" || bad "fullfi: $(pf fullfi "r['blocked']")"
K=$(knob fiblock) || exit 2; rc=$(plan "$K" k-full --range "$H1..$H2" --package-run 111 --g10 a --g11 b --b10 c --b11 d --f11 e --vm10 f --vm11 g --os11 h)
[ "$(pf k-full "r['ready']")" = True ] && ok "knob 'fiblock': a full plan without --fi-run reads as ready - the check is SEEN TO FAIL" || bad "knob fiblock: ready=$(pf k-full "r['ready']") blocked=$(pf k-full "r['blocked']")"

# ---- logvol not required: a map whose core is package-verify only, docs-only diff --------------------------------------------
mk_ledger "$NOW"
python3 - mgmt/gate-scope.json <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["core"]["suites"] = ["package-verify"]; json.dump(m, open(p, "w"), indent=1)
PY
git add -A >/dev/null && git commit -qm core-pkg-only; mk_ledger "$NOW"; git add -A >/dev/null && git commit -qm ledger2; H3=$(git rev-parse HEAD)
printf 'more\n' >> docs/NOTES.md; git add -A >/dev/null && git commit -qm docs; H4=$(git rev-parse HEAD)
rc=$(plan "$SRC" docs --range "$H3..$H4" --setup "$T/setup")
[ "$rc" = 0 ] && [ "$(pf docs "r['gate']['required']")" = "['package-verify']" ] && [ "$(pf docs "r['logvol']['required']")" = False ] && [ "$(pf docs "len(r['cells'])")" = 1 ] \
  && ok "logvol: a docs-only diff on a package-only core plans package-verify alone and says no volume is required" || bad "docs: rc=$rc required=$(pf docs "r['gate']['required']") logvol=$(pf docs "r['logvol']")"
K=$(knob logvol) || exit 2; rc=$(plan "$K" k-logvol --range "$BASE..$H1" --package-run 111 --g11 b --b11 d --f11 e --vm10 f --vm11 g --os11 h)
[ "$(pf k-logvol "r['logvol']['required']")" = False ] && ok "knob 'logvol': a guest-driving plan says no volume required - the check is SEEN TO FAIL" || bad "knob logvol did not flip the flag"

# ---- exit2: the requirement could not be computed -----------------------------------------------------------------------------
rc=$(plan "$SRC" bad --range "not-a-range")
[ "$rc" = 2 ] && [ ! -e "$T/bad.json" ] && ok "exit2: a bad range -> rc 2 and NO plan (never 'nothing required')" || bad "exit2: rc=$rc plan exists=$([ -e "$T/bad.json" ] && echo yes || echo no)"
K=$(knob gatescope2) || exit 2; rc=$(plan "$K" k-bad --range "not-a-range")
[ "$rc" != 2 ] && ok "knob 'gatescope2': gate-scope's failure is swallowed (rc=$rc) - the check is SEEN TO FAIL" || bad "knob gatescope2: rc still 2"

echo
# ---- the release commit comes from the PACKAGE, not from HEAD ----------------------------------
# verify-release-package.sh --commit is compared against MANIFEST.source.driver_repo_commit, so a
# plan that names HEAD makes cell 1 fail on provenance the moment HEAD moves - and HEAD moves for a
# harness commit, a suite or a findings edit, none of which change a shipped byte. Measured
# 2026-10-25: four package rebuilds in one night and only ONE was real (exactly one commit in
# 7e3d1f47..df506bae touched a product path). The provenance is given by campaign-preflight's
# ancestor and drift gates, not by a string equal to HEAD. Owner: "why not just from cell 1?"
# gh is stubbed, so this needs no network and no real run id.
_apt=$(mktemp -d "${TMPDIR:-/tmp}/aplan-pkgsha-XXXXXX")
mkdir -p "$_apt/bin"
cat > "$_apt/bin/gh" <<'EOF'
#!/bin/bash
# answers `run view <id> --json headSha -q .headSha` with a sha that is NOT HEAD
echo 1111111111111111111111111111111111111111
EOF
chmod +x "$_apt/bin/gh"
if ( cd "$ROOT" && PATH="$_apt/bin:$PATH" python3 tools/acceptance-plan.py --range HEAD~1..HEAD --package-run 999      --vm10 v10 --vm11 v11 --os11 o11 --g10 g10 --g11 g11 --b10 b10 --b11 b11 --f11 f11      --out "$_apt/plan.json" >/dev/null 2>&1 ); then
  _c=$(python3 -c "
import json,sys
p=json.load(open('$_apt/plan.json'))
for c in p.get('cells',[]):
    if c.get('order')==1: print(c['command'])
" 2>/dev/null)
  case "$_c" in
    *1111111111111111111111111111111111111111*) ok "cell 1 names the PACKAGE's build commit, not HEAD" ;;
    *) bad "cell 1 names the package's build commit" "got: $(printf '%s' "$_c" | tail -c 120)" ;;
  esac
else
  bad "the plan runs with a stubbed gh" "it exited non-zero"
fi
rm -rf "$_apt"

echo "RESULT: $pass passed, $fail failed  (fixtures: $T)"
[ "$fail" -eq 0 ]
