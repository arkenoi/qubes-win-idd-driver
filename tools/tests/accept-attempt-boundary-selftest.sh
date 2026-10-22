#!/bin/bash
# THE CAMPAIGN LOG MUST SCOPE ONE ATTEMPT - and this EXECUTES the code that makes it so.
#
# THE DEFECT, measured 2026-10-22. tools/release-acceptance.sh appends the matrix's stdout to
# $CAMP/full.out with `tee -a`, and $WORK is derived from the release-package run id, so two attempts
# against one package write into the same file. It ended that night holding BOTH
#   === MATRIX: 1 passed, 1 failed - ABORTED on a log-device failure ===      (the 21:50 attempt)
#   === MATRIX: 44 passed, 2 failed - ABORTED on a log path that broke mid-cell ===   (the 22:12 one)
# with nothing between them. That file is what `matrix rc=` points a reader at, so it is the one
# opened first - and matrix.sh's own fix (the MATTEMPT markers) covers only $CAMP/matrix.
#
# WHY full.out IS ROTATED AND NOT STAMPED. record-acceptance.sh globs $CAMP/*.out and requires ONE
# '=== MATRIX ... ===' footer per file, treating a footerless file as a group that did not finish.
# Two footers in one file breaks that contract and a separator inside it would not repair it. So the
# property asserted here is: after a new attempt starts, $CAMP holds exactly ONE *.out carrying a
# footer, the previous attempt's output still EXISTS, and the kept copy is OUT of the *.out glob.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
SRC=tools/release-acceptance.sh
[ -r "$SRC" ] || { echo "FATAL: $SRC missing"; exit 2; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

code=$(awk '/RAATTEMPT-A/,/RAATTEMPT-B/' "$SRC" | command grep -v 'RAATTEMPT-[AB]')
if [ -z "$code" ] || ! printf '%s' "$code" | command grep -qa '_ra_rotate_inherited()'; then
  echo "FATAL: could not extract the attempt code from $SRC between its markers"; exit 2
fi

setup_first_attempt() { # a finished-and-aborted first attempt, as the real one left it
  T=$(mktemp -d "${TMPDIR:-/tmp}/raattempt-XXXXXX")
  WORK="$T/rel-39678937221"; CAMP="$WORK/campaign"; LOG="$WORK/release-acceptance.log"
  mkdir -p "$CAMP"
  printf 'cells: win10-clean\n=== MATRIX: 1 passed, 1 failed - ABORTED on a log-device failure ===\n' > "$CAMP/full.out"
  printf 'runner line from attempt one\n' > "$CAMP/runner.log"
  printf 'driver line from attempt one\n' > "$LOG"
  printf 'feature raw output from attempt one\n' > "$WORK/template-update.out"
}
# count the *.out files in $CAMP that carry a matrix footer - the builder's own predicate
footer_outs() { local n=0 f; for f in "$CAMP"/*.out; do [ -f "$f" ] || continue
  command grep -qa '^=== MATRIX: ' "$f" && n=$((n+1)); done; printf '%s\n' "$n"; }

run_second_attempt() { # <extracted code>
  ( set +u; eval "$1" ) >/dev/null 2>&1
  # the second attempt then writes its own matrix output, as tee -a does
  printf 'cells: win11-clean\n=== MATRIX: 3 passed, 0 failed ===\n' >> "$CAMP/full.out"
}

# ---- THE PROPERTY -------------------------------------------------------------------------------
setup_first_attempt
run_second_attempt "$code"
n=$(footer_outs)
if [ "$n" = 1 ]; then
  ok "after a second attempt, exactly ONE *.out in the campaign dir carries a matrix footer"
else
  no "the builder's one-footer-per-.out contract is broken" "files with a footer: $n (want 1)"
fi
if [ "$(command grep -ca '^=== MATRIX: ' "$CAMP/full.out")" = 1 ]; then
  ok "this attempt's full.out holds its OWN footer and only that"
else
  no "full.out still mixes attempts" "$(command grep -ca '^=== MATRIX: ' "$CAMP/full.out") footer(s)"
fi
kept=$(ls "$CAMP"/full.out.attempt-* 2>/dev/null | head -1)
if [ -n "$kept" ] && command grep -qa 'ABORTED on a log-device failure' "$kept"; then
  ok "the aborted attempt's output is KEPT - for an aborted attempt it is the only record"
else
  no "the previous attempt's output was lost" "nothing matching full.out.attempt-* carries it"
fi
case "$kept" in
  *.out) no "the kept copy still ends in .out" "it would stay in the builder's glob" ;;
  *)     ok "the kept copy is OUT of the *.out glob the record builder depends on" ;;
esac
# the append-only logs are boundary-stamped so a reader can still attribute them
if command grep -qa '=== ATTEMPT BOUNDARY' "$LOG" && command grep -qa '=== ATTEMPT BOUNDARY' "$CAMP/runner.log"; then
  ok "the append-only driver log and runner log carry an attempt boundary"
else
  no "an append-only log has no boundary" "a reader cannot tell where this attempt starts"
fi
if command grep -qa '=== ATTEMPT BOUNDARY' "$WORK/template-update.out"; then
  ok "a feature test's inherited raw output carries the boundary too"
else
  no "the feature raw output has no boundary" "it is appended to across attempts"
fi
rm -rf "$T"

# ---- SEEN TO FAIL: without the rotate, the two attempts share one file ---------------------------
norotate=$(printf '%s' "$code" | sed 's/^\( *\)mv -f "\$f".*$/\1return 0/')
if [ "$norotate" = "$code" ]; then
  no "SEEN TO FAIL: could not build the control" "the rotate line was not found to remove"
else
  setup_first_attempt
  run_second_attempt "$norotate"
  n=$(command grep -ca '^=== MATRIX: ' "$CAMP/full.out")
  if [ "$n" = 2 ]; then
    ok "SEEN TO FAIL: with the rotate removed full.out carries BOTH footers - the shipped defect, reproduced"
  else
    no "the control did not reproduce the defect" "footers in full.out: $n (want 2)"
  fi
  rm -rf "$T"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
