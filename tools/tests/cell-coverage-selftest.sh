#!/usr/bin/env bash
# cell-coverage-selftest.sh - tools/check-cell-coverage.sh must PASS on the repo as it is and FAIL on each drift it exists to catch:
#   1. a matrix cell the gate requires dropped from the runner's CELLS_DEFAULT;
#   2. a feature test the gate requires (tools/release-feature-tests.txt) with no arm in the runner's case;
#   3. the runner no longer reading the shared feature list.
# Each defect is applied to a throwaway copy of the three files in a temp git repo - the real files are never touched.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/ccc-selftest.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
fails=0
run_case(){ # $1 label, $2 expected rc class (pass|fail), $3 sed expression applied to the runner copy ('' = none)
  local d="$T/$1"
  mkdir -p "$d/tools" && git -C "$d" init -q
  cp "$ROOT/tools/check-cell-coverage.sh" "$ROOT/tools/acceptance-record-check.py" "$ROOT/tools/release-feature-tests.txt" "$d/tools/"
  if [ -n "$3" ]; then sed -E "$3" "$ROOT/tools/release-acceptance.sh" > "$d/tools/release-acceptance.sh"
  else cp "$ROOT/tools/release-acceptance.sh" "$d/tools/"; fi
  out=$(cd "$d" && bash tools/check-cell-coverage.sh 2>&1); rc=$?
  if { [ "$2" = pass ] && [ $rc -eq 0 ]; } || { [ "$2" = fail ] && [ $rc -ne 0 ]; }; then
    echo "  ok   $1 (rc=$rc): $(printf '%s' "$out" | head -1 | cut -c1-150)"
  else
    echo "  FAIL $1 expected $2, got rc=$rc: $(printf '%s' "$out" | head -1 | cut -c1-150)"; fails=$((fails+1))
  fi
}
run_case clean pass ''
run_case matrix-cell-dropped fail 's/^(CELLS_DEFAULT="[^"]*)win11-reinstall ?/\1/'
first=$(grep -v -e '^#' -e '^[[:space:]]*$' "$ROOT/tools/release-feature-tests.txt" | head -1)
run_case feature-arm-missing fail "s/^([[:space:]]+)$first\\)/\\1${first}-renamed)/"
run_case shared-list-not-read fail 's/release-feature-tests\.txt/feature-list-elsewhere.txt/g'
if [ $fails -eq 0 ]; then echo "PASS  check-cell-coverage passes clean and catches all 3 drifts"; exit 0; fi
echo "FAIL  $fails case(s)"; exit 1
