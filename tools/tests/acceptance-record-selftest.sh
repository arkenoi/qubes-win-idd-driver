#!/usr/bin/env bash
# acceptance-record-selftest.sh - offline proof that a release can no longer be cut on a record whose feature tests did not run.
#
# WHY: 2026-10-02, rz30 (release-package run 36997345095): the campaign passed 96/96, both feature tests died in seconds on a retired
# golden, and tools/record-acceptance.sh still recorded the ISO CLEAN - it reads only campaign/*.out, and cut-release required only the
# six matrix cells. Now each feature test leaves a footer'd cell-group in the campaign dir (tools/release-acceptance.sh) and
# tools/acceptance-record-check.py (cut-release's check, moved out to be testable) requires feature-<test> among the recorded cells.
#
# No rig, no gh: synthetic campaign dirs -> the real record-acceptance.sh (ACCEPT_RECORD_DIR points it at a temp dir) -> the real check.
#   no env                 every case must come out as stated AND ACCEPT_CHECK_DEFECT=1 (the old six-cell set) must make the
#                          "feature tests skipped" case FAIL to be refused.
#   ACCEPT_CHECK_DEFECT=1  run the cases with the defect and exit with their result - i.e. this test FAILS, by design.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/accrec-XXXXXX")
trap 'rm -rf "$T"' EXIT
export ACCEPT_RECORD_DIR="$T/records"
VER=9.9.9
MATRIX_CELLS="win10-clean win10-reinstall win10-upgrade win10-appvm win11-clean win11-reinstall win11-upgrade win11-appvm"

# The feature tests come from the SAME list the runner and the check read - never a third copy here.
FEATS=$(grep -v -e '^#' -e '^[[:space:]]*$' tools/release-feature-tests.txt)
FIRST=$(printf '%s\n' $FEATS | head -1)
REST_SORTED=$(printf '%s\n' $FEATS | tail -n +2 | sed 's/^/feature-/' | sort | paste -sd, - | sed 's/,/, /g')
ALL_SORTED=$(printf '%s\n' $FEATS | sed 's/^/feature-/' | sort | paste -sd, - | sed 's/,/, /g')
camp(){ # $1 dir  $2 result of the FIRST listed feature test (pass|fail|none)  $3 result of every OTHER one (pass|fail|none)
  local d=$1; mkdir -p "$d"
  { echo "[12:00:00]   cells: $MATRIX_CELLS"; echo "=== MATRIX: 96 passed, 0 failed ==="; } > "$d/full.out"
  local t r
  for t in $FEATS; do
    r=$3; [ "$t" = "$FIRST" ] && r=$2
    case "$r" in
      pass) { echo "  cells: feature-$t"; echo "=== MATRIX: 1 passed, 0 failed ==="; } > "$d/feature-$t.out" ;;
      fail) { echo "  cells: feature-$t"; echo "=== MATRIX: 0 passed, 1 failed ==="; } > "$d/feature-$t.out" ;;
      none) : ;;
    esac
  done
}
fails=0
ok(){ echo "ok    $*"; }
bad(){ echo "FAIL  $*"; fails=$((fails+1)); }
case_run(){ # $1 name $2 first feature $3 the other features $4 expected (publish|refuse) $5 expected-reason-regex
  local d="$T/$1" iso="$T/$1.iso" sha rc out
  camp "$d" "$2" "$3"
  printf 'iso-%s' "$1" > "$iso"; sha=$(sha256sum "$iso" | cut -d' ' -f1)
  bash tools/record-acceptance.sh --iso "$iso" --campaign "$d" --release "$VER" > "$T/$1.rec" 2>&1
  out=$(python3 tools/acceptance-record-check.py "$ACCEPT_RECORD_DIR/$sha.json" "$sha" "$VER" 2>&1); rc=$?
  if [ "$4" = publish ]; then
    [ "$rc" = 0 ] && ok "$1: publishable" || bad "$1: refused but should publish: $out"
  else
    if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q -E "$5"; then ok "$1: refused ($out)"; else bad "$1: rc=$rc out='$out' (expected a refusal matching /$5/)"; fi
  fi
}
run_cases(){
  case_run all-pass        pass pass publish ''
  case_run first-failed    fail pass refuse  'verdict is .FAILED.|cell-group\(s\) had failures'
  case_run others-failed   pass fail refuse  'verdict is .FAILED.|cell-group\(s\) had failures'
  case_run features-skipped none none refuse "PARTIAL - these did not run: $ALL_SORTED"
  case_run others-skipped  pass none refuse  "PARTIAL - these did not run: $REST_SORTED"
  # the record itself is keyed by the ISO and refuses a different one
  out=$(python3 tools/acceptance-record-check.py "$(ls "$ACCEPT_RECORD_DIR"/*.json | head -1)" deadbeef "$VER" 2>&1); rc=$?
  [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'different ISO' && ok "a record for another ISO is refused" || bad "other-ISO: rc=$rc $out"
  echo "cases failed: $fails"
  [ "$fails" = 0 ]
}
if [ -n "${ACCEPT_CHECK_DEFECT:-}" ]; then run_cases; exit $?; fi
echo "== clean"
run_cases; clean=$?
echo "== ACCEPT_CHECK_DEFECT=1 (the old six-cell set - skipped feature tests must slip through, so this leg must FAIL)"
dout=$(fails=0; export ACCEPT_CHECK_DEFECT=1; run_cases); drc=$?
printf '%s\n' "$dout" | grep -E '^FAIL|cases failed'
if [ "$clean" = 0 ] && [ "$drc" != 0 ] && printf '%s\n' "$dout" | grep -q '^FAIL  features-skipped:'; then
  echo "PASS  clean leg passes, the defect knob lets skipped feature tests through and the test catches it"; exit 0
fi
echo "FAIL  clean=$clean defect_rc=$drc"; exit 1
