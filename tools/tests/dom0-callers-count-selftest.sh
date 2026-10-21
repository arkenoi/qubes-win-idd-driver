#!/bin/bash
# THE START MENU MUST AGREE ACROSS CELLS OF ONE OS FAMILY.
#
# MEASURED 2026-10-21 by the harness audit: dom0-callers-check.sh's only entry-count test was
# `[ "$ents" -ge 10 ]`, a floor, against a clean Windows that reports ~37. A release shipping a menu
# amputated to anywhere from 10 to 36 entries - up to 27 real apps missing - read as "aligned".
# Raising the floor to 37 swaps one invented number for another, because a guest's menu depends on
# what is installed on it. Every cell of one family in a campaign is a clone of the SAME sealed
# golden, so their menus must agree, and a disagreement needs no magic number at all.
#
# The block is extracted from the shipped script between its two markers and driven over fixtures.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
A=mgmt/harness/dom0-callers-check.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/dccount-XXXXXX"); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

blk=$(awk '/# DOM0-CALLERS-COUNT-A/,/# DOM0-CALLERS-COUNT-B/' "$A")
if [ -n "$blk" ] && printf '%s' "$blk" | command grep -qa 'DISAGREES'; then
  ok "the count block was extracted from $A ($(printf '%s' "$blk" | wc -l) lines)"
else
  echo "FATAL: could not extract the count block from $A"; exit 2
fi

run(){ # $1=entries $2=family $3=cell -> the block's output
  bad(){ :; }; good(){ :; }
  bash -c '
    rc_all=0
    bad(){ printf "BAD %s\n" "$*"; rc_all=1; }
    good(){ printf "OK %s\n" "$*"; }
    ents="$1"; CALLERS_COUNT_DIR="$2"; CALLERS_FAMILY="$3"; CALLERS_CELL="$4"
    eval "$5"
    exit $rc_all
  ' _ "$1" "$T/m" "$2" "$3" "$blk" 2>&1
}
mkdir -p "$T/m"

out=$(run 37 win10 win10-clean); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa 'recorded 37 entries'; then
  ok "the FIRST cell of a family records its count as the campaign baseline"
else no "the first cell did not record (rc=$rc)" "$out"; fi

out=$(run 37 win10 win10-reinstall); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa 'agrees with the other win10'; then
  ok "a later cell with the SAME count agrees and passes"
else no "an agreeing cell did not pass (rc=$rc)" "$out"; fi

out=$(run 12 win10 win10-upgrade); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | command grep -qa 'DISAGREES across win10'; then
  ok "a cell whose menu dropped to 12 FAILS, naming both counts - the case the floor of 10 passed"
else no "an amputated menu passed (rc=$rc)" "$out"; fi

out=$(run 37 win11 win11-clean); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa 'recorded 37 entries'; then
  ok "win11 keeps its own baseline - families do not contaminate each other"
else no "the win11 family shared win10's baseline (rc=$rc)" "$out"; fi

out=$(run 12 '' ''); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa 'did not run'; then
  ok "with no campaign dir the comparison says it did not run, rather than passing silently"
else no "a missing campaign dir behaved unexpectedly (rc=$rc)" "$out"; fi

# SEEN TO FAIL: with the comparison deleted, the amputated menu passes again on the floor alone
nocmp=$(printf '%s' "$blk" | sed '/_cc_dir=/,$d')
out=$(bash -c '
  rc_all=0; bad(){ printf "BAD %s\n" "$*"; rc_all=1; }; good(){ printf "OK %s\n" "$*"; }
  ents="$1"; eval "$2"; exit $rc_all' _ 12 "$nocmp" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "SEEN TO FAIL: on the floor alone a 12-entry menu passes again" \
              || no "the floor-only copy still failed a 12-entry menu (rc=$rc)" "$out"

# and the campaign must actually pass the two variables, or the block never runs
if command grep -qa 'CALLERS_COUNT_DIR="$M"' mgmt/harness/matrix.sh \
   && command grep -qa 'CALLERS_FAMILY=' mgmt/harness/matrix.sh; then
  ok "matrix.sh passes the campaign dir and the OS family, so the comparison has inputs"
else
  no "matrix.sh does not pass CALLERS_COUNT_DIR/CALLERS_FAMILY" "the comparison would never run - decoration"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
