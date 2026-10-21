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

# EVERY CALL SITE, NOT THE FILE. This assertion used to grep the whole of matrix.sh for the two
# variable names and passed because the WARM site carries them - while the COLD site, the one the
# check's header says nothing else covers, did not. The comparison was therefore inert on the cold
# path for the whole day, with a green suite over it. Found by the re-grade, 2026-10-21.
# Line continuations are joined first: the warm site spells its env assignments across two lines,
# so a per-line grep would call that site variable-less and report the inverse error.
joined=$(sed -e :a -e '/\\$/N; s/\\\n//; ta' mgmt/harness/matrix.sh)
mapfile -t sites < <(printf '%s\n' "$joined" \
                     | command grep -a 'dom0-callers-check\.sh' \
                     | command grep -av '^[[:space:]]*#')
if [ "${#sites[@]}" -ge 2 ]; then
  ok "found ${#sites[@]} live dom0-callers-check call site(s) in matrix.sh (warm and cold)"
else
  no "found only ${#sites[@]} call site(s)" "the cold path invocation is how this leg stops being vacuous"
fi
bare=0
for s in "${sites[@]}"; do
  case "$s" in
    *CALLERS_COUNT_DIR*) case "$s" in *CALLERS_FAMILY*) continue ;; esac ;;
  esac
  bare=$((bare+1)); printf '       bare call site: %s\n' "$(printf '%s' "$s" | cut -c1-110)"
done
[ "$bare" = 0 ] \
  && ok "every call site passes CALLERS_COUNT_DIR and CALLERS_FAMILY, so no path is graded on the floor alone" \
  || no "$bare call site(s) pass neither" "a site without them falls to the floor of 10 - the amputation this check exists for"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
