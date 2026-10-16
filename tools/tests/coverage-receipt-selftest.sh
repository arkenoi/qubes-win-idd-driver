#!/usr/bin/env bash
# coverage-receipt-selftest.sh - offline proof matrix for tools/coverage-receipt.py (PLAN-acceptance-optimization
# section 6: the coverage receipt tells product-fail from instrument-fail, and instrument-fail is UNCOVERED).
#
# A fixture campaign directory in matrix.sh's output shape drives every class; the receipt is then fed to the REAL
# tools/gate-scope.py check against a fixture map to prove the gate refuses an instrument-failed suite. The check is
# also seen to FAIL on a copy with ONE `# GUARD:<knob>` line replaced by its defect (instrumentcovered: the old
# behaviour, where an INVALID-* cell counted as covered).
#
#   classes    PASS only -> pass; a product FAIL line -> product-fail (covered, result fail); FAIL lines that are all
#              INVALID-* -> instrument-fail (NOT covered); no lines -> not-run; a group without the footer -> noted
#   features   rc 0 pass, 2 instrument-fail, 1 product-fail; package-verify by rc
#   gate       the receipt with an instrument-failed required suite is REFUSED by gate-scope.py check
#   refusals   no campaign dir -> rc 2, no receipt; a malformed --feature -> rc 2
#
#   RECEIPT_SELFTEST_OUT=<dir>  keep fixtures and outputs (default: a mktemp dir, removed on exit)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${COVERAGE_RECEIPT_SRC:-$ROOT/tools/coverage-receipt.py}"
T="${RECEIPT_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/receipt-selftest-XXXXXX")}"
[ -n "${RECEIPT_SELFTEST_OUT:-}" ] || trap 'rm -rf "$T"' EXIT
mkdir -p "$T/camp"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$SRC" ] || { echo "FAIL  $SRC is missing - nothing ran"; exit 2; }

# THE FIXTURE IS THE CAPTURED SHAPE, LEVEL TOKENS AND ALL. It used to carry `[HH:MM:SS] PASS  <cell>:`
# with no level, which is what matrix.sh emitted BEFORE its verdict lines were tagged with the
# writer's level - so this suite stayed green against text nothing emits any more, and the parser's
# blindness to `[11:13:08] [ERROR] FAIL  win10-clean: ...` went unnoticed until it cost a release:
# the 4.3.36 campaign ran all eight cells and the receipt reported covered=3, not_run=[all eight].
# Lines below are copied from that campaign's own full.out (ERROR on a product FAIL, WARN on an
# INVALID one, INFO on a PASS). One line is deliberately left UNTAGGED so the legacy form, which
# older captures and some callers still produce, stays parsed too.
cat > "$T/camp/full.out" <<'EOF'
[16:56:51] === MATRIX for 4.3.36+agent.5c483cd956c1 (agent 4aa66e251841) ===
[16:56:51]   cells: win10-clean win11-clean win11-reinstall win11-upgrade win11-appvm
[11:16:13] [INFO] PASS  WIN11-clean: prime-run delivered a qrexec-answering installed guest
[11:20:13] [INFO] PASS  WIN11-clean: installer RESULT ok:true and no error-class detail flags (2 trailer(s) judged)
[15:21:34] [ERROR] FAIL  WIN10-clean: accept-clean battery FAILED (see /x/WIN10-clean-accept.out)
[15:21:35] PASS  WIN10-clean: autologon armed
[15:37:19] [ERROR] FAIL  WIN11-reinstall: console-window check could not judge - INVALID-INSTRUMENT: INSTRUMENT: no complete answer from win11-acc
[15:37:23] [INFO] PASS  WIN11-reinstall: PV console bound (CONS:err=0 svc=xencons)
[16:30:00] [INFO] PASS  WIN11-appvm boot 1: notepad window captured
[16:31:00] [WARN] FAIL  WIN11-appvm boot 2: INVALID-PRECONDITION - cell claims a pristine entry but the installer saw: x
=== MATRIX: 5 passed, 3 failed ===
EOF
printf '[17:00:00]   cells: win10-appvm\n[17:00:01] PASS  WIN10-appvm: started\n' > "$T/camp/unfinished.out"   # no footer: did not finish

knob(){ local n="$1" out="$T/receipt-$1.py" hits
  hits=$(grep -c "# GUARD:$n DEFECT: " "$SRC")
  [ "$hits" = 1 ] || { echo "FATAL: GUARD:$n appears $hits times in $SRC (want exactly 1)" >&2; return 2; }
  sed -E "s|^( *)[^#]*# GUARD:$n DEFECT: (.*)$|\1\2|" "$SRC" > "$out"
  [ "$(diff "$SRC" "$out" | grep -c '^>')" = 1 ] || { echo "FATAL: knob $n changed $(diff "$SRC" "$out" | grep -c '^>') lines" >&2; return 2; }
  python3 -m py_compile "$out" || { echo "FATAL: knob $n does not compile" >&2; return 2; }
  printf '%s' "$out"; }
rf(){ python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$T/$1.json" "$2" 2>/dev/null; }
CELLS="win10-clean win11-clean win11-reinstall win11-upgrade win11-appvm win10-appvm"
ARGS=(--campaign "$T/camp" --cells "$CELLS" --feature notify-errors-guest-test=0 --feature crop-before-map=2 --feature template-update=1 --package-verify-rc 0 --package-run 111 --built-from deadbeefcafe --range v1..v2)

python3 "$SRC" --out "$T/r.json" "${ARGS[@]}" > "$T/r.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -s "$T/r.json" ] && ok "receipt written (rc 0): $(tail -1 "$T/r.out")" || bad "receipt: rc=$rc $(cat "$T/r.out")"
[ "$(rf r "r['classes']['win11-clean']['class']")" = pass ] && ok "class: only PASS lines -> pass" || bad "class win11-clean: $(rf r "r['classes']['win11-clean']")"
[ "$(rf r "r['classes']['win10-clean']['class']")" = product-fail ] && ok "class: a FAIL line naming the product -> product-fail (even beside a PASS line)" || bad "class win10-clean: $(rf r "r['classes']['win10-clean']")"
[ "$(rf r "r['classes']['win11-reinstall']['class']")" = instrument-fail ] && ok "class: FAIL lines that are all INVALID-* -> instrument-fail" || bad "class win11-reinstall: $(rf r "r['classes']['win11-reinstall']")"
[ "$(rf r "r['classes']['win11-appvm']['class']")" = instrument-fail ] && ok "class: ' boot N' labels are joined to their cell; INVALID-PRECONDITION is instrument-class" || bad "class win11-appvm: $(rf r "r['classes']['win11-appvm']")"
[ "$(rf r "r['classes']['win11-upgrade']['class']")" = not-run ] && ok "class: a cell with no verdict line -> not-run" || bad "class win11-upgrade: $(rf r "r['classes']['win11-upgrade']")"
[ "$(rf r "r['classes']['win10-appvm']['class']")" = pass ] && rf r "r['notes']" | grep -q 'unfinished.out has no MATRIX footer' && ok "class: an unfinished group is NOTED (its lines still count for what they say)" || bad "unfinished: $(rf r "r['classes']['win10-appvm']") notes=$(rf r "r['notes']")"
[ "$(rf r "r['suites']")" = "['notify-errors-guest-test', 'package-verify', 'template-update', 'win10-appvm', 'win10-clean', 'win11-clean']" ] \
  && ok "suites (covered) = pass + product-fail, and NOT the instrument-failed or not-run ones" || bad "suites: $(rf r "r['suites']")"
[ "$(rf r "r['product_fail']")" = "['template-update', 'win10-clean']" ] && [ "$(rf r "r['instrument_fail']")" = "['crop-before-map', 'win11-appvm', 'win11-reinstall']" ] && [ "$(rf r "r['not_run']")" = "['win11-upgrade']" ] \
  && ok "lists: product_fail / instrument_fail / not_run are each right, feature tests classed by rc (0/2/1)" || bad "lists: pf=$(rf r "r['product_fail']") if=$(rf r "r['instrument_fail']") nr=$(rf r "r['not_run']")"
[ "$(rf r "r['result']")" = fail ] && [ "$(rf r "r['package_run']")" = 111 ] && [ "$(rf r "r['built_from']")" = deadbeefcafe ] && ok "result=fail; package_run and built_from carried" || bad "result/meta: $(rf r "r['result']") $(rf r "r['package_run']")"

# all green -> result pass
printf '[10:00:00]   cells: win11-clean\n[10:00:01] PASS  WIN11-clean: fine\n=== MATRIX: 1 passed, 0 failed ===\n' > "$T/camp2.out.d"; mkdir -p "$T/camp2"; mv "$T/camp2.out.d" "$T/camp2/full.out"
python3 "$SRC" --out "$T/g.json" --campaign "$T/camp2" --cells "win11-clean" --feature notify-errors-guest-test=0 --package-verify-rc 0 > "$T/g.out" 2>&1
[ "$(rf g "r['result']")" = pass ] && [ "$(rf g "r['suites']")" = "['notify-errors-guest-test', 'package-verify', 'win11-clean']" ] && ok "all green: result=pass with every suite covered" || bad "green: $(cat "$T/g.json")"

# the gate refuses the instrument-failed suite (REAL gate-scope.py check over a fixture map)
FX="$T/fx"; mkdir -p "$FX/mgmt" "$FX/agent"; (cd "$FX" && git init -q . && git config user.email t@t && git config user.name t
cat > mgmt/gate-scope.json <<'JSON'
{ "version": 1, "core": { "suites": ["package-verify", "win11-reinstall"], "reason": "c" },
  "full": { "suites": ["package-verify", "win11-reinstall", "win11-clean"], "reason": "f" }, "floor": { "releases": 10, "days": 21, "reason": "x" },
  "patterns": { "agent/**": { "suites": ["win11-clean"], "reason": "a" }, "mgmt/**": { "suites": [], "reason": "m" } } }
JSON
printf 'x\n' > agent/a.c; git add -A >/dev/null; git commit -qm base
python3 - "$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)" "$(git log -1 --format=%H -- mgmt/gate-scope.json)" > mgmt/gate-ledger.json <<'PY'
import json, sys
json.dump({"releases": [{"version": "1.0", "date": sys.argv[1], "range": "", "required": [], "covered": [], "full": True, "result": "pass", "map_commit": sys.argv[2]}]}, sys.stdout)
PY
git add -A >/dev/null; git commit -qm ledger; printf 'y\n' >> agent/a.c; git add -A >/dev/null; git commit -qm change) >/dev/null 2>&1
B=$(git -C "$FX" rev-parse HEAD~1); H=$(git -C "$FX" rev-parse HEAD)
GATE_SCOPE_ROOT="$FX" python3 "$ROOT/tools/gate-scope.py" check "$T/r.json" "$B..$H" > "$T/check.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'win11-reinstall' "$T/check.out" && ok "gate: gate-scope.py check REFUSES the receipt, naming the instrument-failed required suite (win11-reinstall)" || bad "gate: rc=$rc $(cat "$T/check.out")"
K=$(knob instrumentcovered) || exit 2
python3 "$K" --out "$T/k.json" "${ARGS[@]}" > "$T/k.out" 2>&1
GATE_SCOPE_ROOT="$FX" python3 "$ROOT/tools/gate-scope.py" check "$T/k.json" "$B..$H" > "$T/kcheck.out" 2>&1; rc=$?
[ "$rc" = 0 ] && rf k "r['suites']" | grep -q 'win11-reinstall' && ok "knob 'instrumentcovered': the INVALID cell counts as covered and the gate ACCEPTS the cut - the check is SEEN TO FAIL" || bad "knob instrumentcovered: rc=$rc suites=$(rf k "r['suites']")"

# the driver is WIRED to this tool: step 7 calls it with the campaign dir and every feature test's exit
grep -q 'tools/coverage-receipt.py --out "$COVFILE" --campaign "$CAMP" --cells "$CELLS" ${FEATRCS:-}' "$ROOT/tools/release-acceptance.sh" \
  && grep -q 'FEATRCS="${FEATRCS:-} --feature $t=$rc"' "$ROOT/tools/release-acceptance.sh" \
  && ok "wiring: tools/release-acceptance.sh step 7 derives the receipt through this tool, with each feature test's rc" || bad "wiring: release-acceptance.sh does not call coverage-receipt.py as expected"

# refusals
python3 "$SRC" --out "$T/n.json" --campaign "$T/nope" --cells "x" > "$T/n.out" 2>&1; rc=$?
[ "$rc" = 2 ] && [ ! -e "$T/n.json" ] && ok "refusal: no campaign dir -> rc 2, no receipt" || bad "refusal campaign: rc=$rc"
python3 "$SRC" --out "$T/m.json" --campaign "$T/camp" --cells "x" --feature "broken" > "$T/m.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "refusal: a malformed --feature -> rc 2" || bad "refusal feature: rc=$rc"

echo
echo "RESULT: $pass passed, $fail failed  (fixtures: $T)"
[ "$fail" -eq 0 ]
