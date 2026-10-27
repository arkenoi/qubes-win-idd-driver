#!/usr/bin/env bash
# a diff must never silently require LESS than its scope demands; short coverage is REFUSED
# run: tools/tests/gate-scope-selftest.sh
# pass: exit 0
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
mk_ledger() { # $1 last-full date, $2 releases after it, $3 pass|fail, $4 map_commit, $5 suites to DROP from full (0=genuine)
    python3 - "$1" "$2" "$3" "${4:-}" "${5:-0}" > mgmt/gate-ledger.json <<'PY'
import json, sys
from datetime import datetime, timedelta
last, extra, res, mapc = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
# THE FIRST RECORD MUST ACTUALLY COVER THE FULL SCOPE, not merely claim it. This fixture used to
# seed covered=["package-verify"] with full=True, so every floor case below - and the negative
# control - ran on an ASSERTED FLAG while this suite's own header says "the floor is read from the
# ledger, never asserted". floor() now DERIVES fullness from covered, which is what made that
# fixture visible. Read the scope from the map so the fixture cannot drift from it.
full_suites = sorted((json.load(open('mgmt/gate-scope.json')).get('full') or {}).get('suites') or [])
if not full_suites:
    raise SystemExit('mk_ledger: mgmt/gate-scope.json has no full scope - the fixture would assert nothing')
drop = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else 0
covered_first = full_suites[:len(full_suites) - drop] if drop else full_suites
rel = [{"version": "1.0", "date": last, "range": "", "required": [], "covered": covered_first,
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

# ---- THE DERIVED-FULLNESS CONTROL. The two arms above and below differ by ONE suite in `covered`,
# nothing else - same date, same release count, same map_commit, same full=true flag. If both say
# the same thing, floor() is reading the flag again and every floor case in this file is decorative.
# This is the arm that had to be seen to fail: on the pre-change floor() BOTH say "floor not
# reached", because the flag says full and nobody counts the suites.
nfull=$(python3 -c "import json;print(len((json.load(open('mgmt/gate-scope.json')).get('full') or {}).get('suites') or []))")
mk_ledger "$NOW" 1 pass "$mapc" 0; git add -A >/dev/null; git commit -qm ledger-derived-full >/dev/null
f_full=$(run floor)
mk_ledger "$NOW" 1 pass "$mapc" 1; git add -A >/dev/null; git commit -qm ledger-derived-short >/dev/null
f_short=$(run floor)
if printf '%s' "$f_full" | grep -q 'floor not reached'; then
    ok "floor-derived: all $nfull suites covered -> the floor does NOT trip"
else fail "floor-derived: a genuinely full record tripped the floor" "$f_full"; fi
if printf '%s' "$f_short" | grep -q 'FLOOR TRIPS' && printf '%s' "$f_short" | grep -q 'of '"$nfull"; then
    ok "floor-derived: ONE suite short of $nfull -> FLOOR TRIPS, and it says how many of how many"
else fail "floor-derived: one suite short did not trip - fullness is being read from the flag, not derived" "$f_short"; fi
if [ "$f_full" = "$f_short" ]; then
    fail "floor-derived: the two arms are IDENTICAL - the predicate is a constant" "$f_full"
else ok "floor-derived: the two arms differ, so the predicate responds to coverage"; fi

# ---- AND THE EMPTY map_commit CLAUSE. The live 4.3.35 row carried map_commit='', which made the
# map-change clause (`last.get('map_commit') and ...`) unreachable, so neither clause could fire.
mk_ledger "$NOW" 1 pass "" 0; git add -A >/dev/null; git commit -qm ledger-nomap >/dev/null
f_nomap=$(run floor)
if printf '%s' "$f_nomap" | grep -q 'FLOOR TRIPS' && printf '%s' "$f_nomap" | grep -q 'map_commit is empty'; then
    ok "floor-nomap: a full record with an empty map_commit trips - the map cannot be proven unchanged"
else fail "floor-nomap: an empty map_commit was accepted as a floor" "$f_nomap"; fi
# RESTORE THE SHARED FIXTURE. These floor arms mutate mgmt/gate-ledger.json, which every `check`
# arm below reads; leaving it at map_commit='' left the floor in force and failed
# "check: complete coverage" - a downstream test failing for an upstream test's leftovers.
mk_ledger "$NOW" 1 pass "$mapc" 0; git add -A >/dev/null; git commit -qm ledger-restored >/dev/null
HOK=$(git rev-parse HEAD)

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

# --- ledger-full: `full` IS A SUPERSET TEST, and nothing drove ledger-add until 2026-10-16 -------
# `full` is what floor_state() reads to find the last FULL gate, and the floor is the only thing
# that forces a full gate back. It was computed as
#     sorted(set(covered)) >= sorted(set(full))  or  set(full) <= set(covered)
# and the first clause compares two LISTS element-wise as strings - "is this alphabetically later",
# not "does it contain everything". MEASURED recording 4.3.36 with 12 of 18 suites: the broken
# clause returned True, so a partial release was written as a full gate and reset the 21-day clock.
# No suite drove ledger-add at all, which is why a load-bearing field went unchecked.
FULLSET=$(python3 -c "import json;print(','.join(json.load(open('$FX/mgmt/gate-scope.json'))['full']['suites']))" 2>/dev/null)
PARTIAL=$(python3 -c "
import json
s=json.load(open('$FX/mgmt/gate-scope.json'))['full']['suites']
print(','.join(sorted(s)[:max(1,len(s)-3)]))" 2>/dev/null)
ledger_full_flag() {   # $1 = covered list -> the `full` value ledger-add wrote
  run ledger-add --version "9.9.$2" --tag "v9.9.$2" --run 1 \
      --range "$HKC..$HKC2" --covered "$1" --result selftest >/dev/null 2>&1
  python3 -c "
import json
r=[x for x in json.load(open('$FX/mgmt/gate-ledger.json'))['releases'] if x.get('version')=='9.9.$2']
print(str(bool(r and r[-1].get('full'))).lower() if r else 'norecord')"
}
n=$((n+1)); gf_partial=$(ledger_full_flag "$PARTIAL" 1)
if [ "$gf_partial" = false ]; then
  ok "ledger-full: coverage missing required suites is recorded full=false, so the floor still counts the debt"
else fail "ledger-full: a PARTIAL coverage list was recorded full=$gf_partial - the floor would treat it as a full gate" "covered=$PARTIAL"; fi
n=$((n+1)); gf_all=$(ledger_full_flag "$FULLSET" 2)
if [ "$gf_all" = true ]; then
  ok "ledger-full: complete coverage IS recorded full=true - the test is a superset check, not a refusal"
else fail "ledger-full: complete coverage was recorded full=$gf_all" "covered=$FULLSET"; fi
n=$((n+1))
if [ "$gf_partial" != "$gf_all" ]; then
  ok "SEEN TO FAIL: the flag tracks coverage (partial=$gf_partial vs complete=$gf_all); the lexicographic compare gave true for both"
else fail "SEEN TO FAIL: partial and complete coverage recorded the SAME flag ($gf_partial)" "the superset test is inert"; fi

say "--- $n check(s), $( [ $bad -eq 0 ] && echo 0 || echo 'at least 1') failed; fixtures and outputs in $OUT"
exit $bad
