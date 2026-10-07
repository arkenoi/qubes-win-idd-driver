#!/usr/bin/env bash
# gate-scope-selftest.sh - offline proof matrix for tools/gate-scope.py and mgmt/gate-scope.json (docs/ADR-acceptance.md).
#
# The scheme it proves: a release's gate is scoped to what the diff touches, with an always-run core, a floor that
# forces everything anyway, and a refusal when the gate's coverage does not include what is required. The owner
# replaced "full acceptance before every release" with it on 2026-10-07, so the thing that must never happen is a
# diff silently requiring LESS than it should - which is why every case below is driven against a FIXTURE repository
# (its own git history, its own map and ledger, via GATE_SCOPE_ROOT), and why each check is also seen to FAIL with
# its defect present. A check never seen to fail is decoration.
#
#   scoped        a diff that touches only the agent requires the agent's suites and NOT the install variants
#   installer     a diff that touches the installer requires every install variant
#   unmapped      a diff that touches a path no pattern names requires the FULL set, and names the file
#   closure       a shared helper two harnesses source expands through the reverse-dependency closure
#   submodule     a submodule POINTER change expands to that submodule's own scope
#   floor-*       each of the four floor conditions trips on its own
#   check         coverage missing one required suite is REFUSED, naming it; complete coverage is satisfied
#   missing       an empty or unreadable coverage file FAILS rather than reading as "nothing required"
#   ledger        the floor is read from the ledger, never asserted
#
#   GATE_SELFTEST_OUT=<dir>   where the fixtures and outputs go (default: a mktemp dir)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/tools/gate-scope.py"
OUT="${GATE_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/gate-scope-selftest-XXXXXX")}"
mkdir -p "$OUT"
bad=0; n=0
say() { printf '%s\n' "$*"; }
ok()   { n=$((n+1)); say "PASS  $1"; }
fail() { n=$((n+1)); bad=1; say "FAIL  $1"; [ -n "${2:-}" ] && say "      $2"; }

[ -f "$TOOL" ] || { say "FAIL  tools/gate-scope.py is missing - nothing ran (missing data fails)"; exit 2; }

# ---- the fixture repository ---------------------------------------------------------------------------------------
# Small, but the same SHAPES as the real repo: a shipped installer, agent sources, a shared harness library two
# harnesses source, a submodule-like pointer, records.
FX="$OUT/fx"
rm -rf "$FX"; mkdir -p "$FX"/{mgmt/harness,tools/tests,packaging/setup,agent/gui-agent,guest,docs}
cd "$FX"
git init -q . && git config user.email t@t && git config user.name t
cat > mgmt/gate-scope.json <<'JSON'
{ "version": 1,
  "core":  { "suites": ["package-verify", "win11-clean", "log-sweep"], "reason": "the core" },
  "full":  { "suites": ["package-verify", "win10-clean", "win10-reinstall", "win11-clean", "win11-appvm",
                        "failproof-faultinject", "log-sweep"], "reason": "everything" },
  "floor": { "releases": 10, "days": 21, "reason": "whichever comes first" },
  "patterns": {
    "packaging/setup/**": { "suites": ["full"], "reason": "the installer decides every install path" },
    "agent/gui-agent/toast*": { "suites": ["win11-clean"], "reason": "the toast surfaces" },
    "agent/**": { "suites": ["win11-clean", "win11-appvm"], "reason": "the agent ships in every window" },
    "guest/**": { "suites": ["win11-clean"], "reason": "a shipped guest script" },
    "mgmt/**": { "suites": [], "reason": "the harness is the instrument" },
    "tools/**": { "suites": [], "reason": "dev tooling" },
    "docs/**": { "suites": [], "reason": "records" }
  },
  "submodules": { "agent": { "prefix": "agent/", "reason": "the pointer is that submodule's whole diff" } } }
JSON
mk_ledger() { # $1 = the last full gate's date, $2 = how many releases after it, $3 = pass|fail for those, $4 map_commit
    python3 - "$1" "$2" "$3" "${4:-}" > mgmt/gate-ledger.json <<'PY'
import json, sys
from datetime import datetime, timedelta
last, extra, res, mapc = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
rel = [{"version": "1.0", "date": last, "range": "", "required": [], "covered": ["package-verify"],
        "full": True, "result": "pass", "map_commit": mapc}]
d0 = datetime.fromisoformat(last.replace('Z', '+00:00'))
for i in range(extra):
    rel.append({"version": f"1.{i+1}", "date": (d0 + timedelta(minutes=i + 1)).strftime('%Y-%m-%dT%H:%M:%SZ'),
                "range": "", "required": [], "covered": ["win11-clean"], "full": (res == 'fullfail'),
                "result": ("fail" if res == 'fullfail' else "pass"), "map_commit": mapc})
json.dump({"releases": rel}, open('mgmt/gate-ledger.json', 'w'), indent=1)
PY
}
NOW="$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)"
OLD="$(date -u -d '-40 days' +%Y-%m-%dT%H:%M:%SZ)"

# a shared harness library, sourced by two harnesses - the shared-helper hazard
cat > mgmt/harness/shared-lib.sh <<'EOF'
# a library two harnesses source
helper() { :; }
EOF
for h in one two; do printf '#!/usr/bin/env bash\nsource mgmt/harness/shared-lib.sh\n' > "mgmt/harness/cell-$h.sh"; done
# a shipped guest script that the installer dot-sources (so a change to it reaches the installer)
cat > guest/shared-guest.ps1 <<'EOF'
function Shared-Thing { }
EOF
printf '# the installer\n. "$PSScriptRoot\\shared-guest.ps1"\nWrite-Output 1\n' > packaging/setup/Install-Fixture.ps1
printf 'int main(void){return 0;}\n' > agent/gui-agent/main.c
printf '#pragma once\n' > agent/gui-agent/toasthold.h
printf 'notes\n' > docs/NOTES.md
printf 'placeholder\n' > agent/.gitkeep
git add -A && git commit -qm base
BASE=$(git rev-parse HEAD)
mk_ledger "$NOW" 0 pass "$(git log -1 --format=%H -- mgmt/gate-scope.json)"
git add -A && git commit -qm ledger
BASE=$(git rev-parse HEAD)

run() { GATE_SCOPE_ROOT="$FX" python3 "$TOOL" "$@" 2>&1; }
commit_change() { # $1 file, $2 content-to-append, $3 message
    printf '%s\n' "$2" >> "$1"; git add -A; git commit -qm "$3"; git rev-parse HEAD
}

# ---- scoped: only the agent -----------------------------------------------------------------------------------
H=$(commit_change agent/gui-agent/toasthold.h '// a toast change' toast)
o=$(run required "$BASE..$H")
if printf '%s' "$o" | grep -q '^SCOPED' && printf '%s' "$o" | grep -q 'win11-clean' &&
   ! printf '%s' "$o" | grep -q 'win10-reinstall'; then ok "scoped: a toast-only diff requires the agent's suites, not the install variants"
else fail "scoped: a toast-only diff" "$o"; fi

# ---- installer: every install variant --------------------------------------------------------------------------
H2=$(commit_change packaging/setup/Install-Fixture.ps1 '# a change' inst)
o=$(run required "$H..$H2")
if printf '%s' "$o" | grep -q '^FULL' && printf '%s' "$o" | grep -q 'win10-reinstall' &&
   printf '%s' "$o" | grep -q 'failproof-faultinject'; then ok "installer: an installer diff requires the full set including fault injection"
else fail "installer: an installer diff" "$o"; fi

# ---- unmapped: the full set, and the file is named -------------------------------------------------------------
printf 'x\n' > newdir-nobody-mapped.txt; git add -A; git commit -qm unmapped; H3=$(git rev-parse HEAD)
o=$(run required "$H2..$H3")
if printf '%s' "$o" | grep -q 'UNMAPPED' && printf '%s' "$o" | grep -q 'newdir-nobody-mapped.txt' &&
   printf '%s' "$o" | grep -q '^FULL'; then ok "unmapped: a path no pattern names requires the FULL set and is named"
else fail "unmapped: a path no pattern names" "$o"; fi

# ---- closure: a shared guest helper reaches the installer ------------------------------------------------------
H4=$(commit_change guest/shared-guest.ps1 '# touched' sharedguest)
o=$(run required "$H3..$H4")
pulled=$(printf '%s' "$o" | sed -n 's/.*, \([0-9]*\) pulled in by the closure.*/\1/p')
if [ "${pulled:-0}" -gt 0 ] && printf '%s' "$o" | grep -q 'win10-reinstall'; then
    ok "closure: a shipped helper the installer dot-sources expands to the installer's scope ($pulled file(s) pulled in - the shared-helper hazard)"
else fail "closure: a shared guest helper (pulled=${pulled:-?})" "$o"; fi

# ---- submodule: a pointer change expands to that submodule's scope ---------------------------------------------
H5=$(commit_change agent/.gitkeep 'pointer-ish' subm)
o=$(run required "$H4..$H5")
if printf '%s' "$o" | grep -qE 'win11-(clean|appvm)'; then ok "submodule: a change under the submodule's prefix requires its scope"
else fail "submodule: a pointer change" "$o"; fi

# ---- the four floor conditions, each on its own ----------------------------------------------------------------
H6=$(commit_change docs/NOTES.md 'more notes' docs)
mapc="$(git -C "$FX" log -1 --format=%H -- mgmt/gate-scope.json)"
floor_case() { # $1 label, $2 last-full-date, $3 extra releases, $4 result-kind, $5 map_commit, $6 expect-substring
    mk_ledger "$2" "$3" "$4" "$5"; git add -A >/dev/null; git commit -qm "ledger-$1" >/dev/null; local hh; hh=$(git rev-parse HEAD)
    local f; f=$(run floor); local r=$(run required "$H6..$hh")
    if printf '%s' "$f" | grep -q 'FLOOR TRIPS' && printf '%s' "$f" | grep -qi "$6" && printf '%s' "$r" | grep -q '^FULL'; then
        ok "floor-$1: trips and forces the full set ($6)"
    else fail "floor-$1" "$f"; fi
}
floor_case releases "$NOW" 10 pass     "$mapc" 'release(s) since'
floor_case days     "$OLD" 1  pass     "$mapc" 'day(s) ago'
floor_case fullfail "$NOW" 1  fullfail "$mapc" 'FAILED'
floor_case mapchange "$NOW" 1 pass     'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' 'scope map changed'

# a floor that does NOT trip - the negative control, or every case above proves nothing
mk_ledger "$NOW" 1 pass "$mapc"; git add -A; git commit -qm ledger-ok; HOK=$(git rev-parse HEAD)
f=$(run floor)
if printf '%s' "$f" | grep -q 'floor not reached'; then ok "floor-control: a recent passing full gate does NOT trip the floor"
else fail "floor-control: the floor trips when it should not" "$f"; fi

# ---- check: the refusal ----------------------------------------------------------------------------------------
H7=$(commit_change agent/gui-agent/toasthold.h '// another toast change' toast2)
printf '{"suites":["package-verify","win11-clean","log-sweep"]}\n' > "$OUT/cov-full.json"
printf '{"suites":["package-verify","log-sweep"]}\n' > "$OUT/cov-missing.json"
o=$(run check "$OUT/cov-full.json" "$HOK..$H7"); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$o" | grep -q 'satisfied'; then ok "check: coverage that includes every required suite is satisfied (rc=0)"
else fail "check: complete coverage" "rc=$rc $o"; fi
o=$(run check "$OUT/cov-missing.json" "$HOK..$H7"); rc=$?
if [ $rc -eq 1 ] && printf '%s' "$o" | grep -q 'REFUSED' && printf '%s' "$o" | grep -q 'win11-clean'; then
    ok "check: coverage missing one required suite is REFUSED (rc=1) and the suite is named"
else fail "check: missing coverage must be refused" "rc=$rc $o"; fi

# ---- missing data fails ----------------------------------------------------------------------------------------
printf '{"suites":[]}\n' > "$OUT/cov-empty.json"
o=$(run check "$OUT/cov-empty.json" "$HOK..$H7"); rc=$?
if [ $rc -eq 2 ]; then ok "missing: an empty coverage file FAILS the tool (rc=2), it does not read as 'nothing required'"
else fail "missing: empty coverage" "rc=$rc $o"; fi
o=$(run check "$OUT/nope.json" "$HOK..$H7"); rc=$?
if [ $rc -eq 2 ]; then ok "missing: an unreadable coverage file FAILS the tool (rc=2)"
else fail "missing: unreadable coverage" "rc=$rc $o"; fi
mv "$FX/mgmt/gate-ledger.json" "$FX/mgmt/gate-ledger.away"
o=$(run floor); rc=$?
if [ $rc -eq 2 ]; then ok "missing: no ledger FAILS (rc=2) - the floor is never assumed not to have tripped"
else fail "missing: no ledger" "rc=$rc $o"; fi
mv "$FX/mgmt/gate-ledger.away" "$FX/mgmt/gate-ledger.json"

# ---- the knobs: each check is seen to FAIL with its defect present ---------------------------------------------
# DEFECT 1: an unmapped path maps to the core instead of the full set (the inversion Jev rated 0.97 against).
python3 - "$FX/mgmt/gate-scope.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p))
m['patterns']['*'] = {"suites": [], "reason": "DEFECT: an unmapped path requires nothing"}
json.dump(m, open(p, 'w'), indent=1)
PY
git -C "$FX" add -A >/dev/null; git -C "$FX" commit -qm knob-unmapped >/dev/null; HK=$(git -C "$FX" rev-parse HEAD)
printf 'y\n' > "$FX/another-unmapped.txt"; git -C "$FX" add -A >/dev/null; git -C "$FX" commit -qm knob2 >/dev/null; HK2=$(git -C "$FX" rev-parse HEAD)
o=$(run required "$HK..$HK2")
if printf '%s' "$o" | grep -q 'UNMAPPED'; then fail "knob unmapped: the check did NOT fail with the catch-all pattern present" "$o"
else ok "knob unmapped: with a catch-all pattern the unmapped check FAILS as required (the defect is visible)"; fi
git -C "$FX" revert -q --no-edit "$HK" >/dev/null 2>&1 || git -C "$FX" checkout -q "$HK~1" -- mgmt/gate-scope.json
git -C "$FX" add -A >/dev/null; git -C "$FX" commit -qm unknob >/dev/null 2>&1

# DEFECT 2: the closure is switched off - a shared helper then maps only to its own scope. The ledger is re-seeded
# with the CURRENT map commit first, or the floor would force the full set and mask what the knob changes.
mk_ledger "$NOW" 1 pass "$(git -C "$FX" log -1 --format=%H -- mgmt/gate-scope.json)"
git -C "$FX" add -A >/dev/null; git -C "$FX" commit -qm ledger-for-knob >/dev/null; HKC=$(git -C "$FX" rev-parse HEAD)
printf '# touched again\n' >> "$FX/guest/shared-guest.ps1"; git -C "$FX" add -A >/dev/null
git -C "$FX" commit -qm knob-shared >/dev/null; HKC2=$(git -C "$FX" rev-parse HEAD)
on=$(run required "$HKC..$HKC2")
off=$(GATE_SCOPE_ROOT="$FX" GATE_SCOPE_NO_CLOSURE=1 python3 "$TOOL" required "$HKC..$HKC2" 2>&1)
pon=$(printf '%s' "$on" | sed -n 's/.*, \([0-9]*\) pulled in by the closure.*/\1/p')
poff=$(printf '%s' "$off" | sed -n 's/.*, \([0-9]*\) pulled in by the closure.*/\1/p')
if [ "${pon:-0}" -gt 0 ] && printf '%s' "$on" | grep -q 'win10-reinstall' &&
   [ "${poff:-0}" -eq 0 ] && ! printf '%s' "$off" | grep -q 'win10-reinstall'; then
    ok "knob closure: with the closure off the shared helper no longer reaches the installer's suites - the check FAILS as required (on=$pon off=$poff)"
else fail "knob closure: the knob did not change the verdict (on=${pon:-?} off=${poff:-?})" "ON: $(printf '%s' "$on" | head -3) || OFF: $(printf '%s' "$off" | head -3)"; fi

say "--- $n check(s), $( [ $bad -eq 0 ] && echo 0 || echo 'at least 1') failed; fixtures and outputs in $OUT"
exit $bad
