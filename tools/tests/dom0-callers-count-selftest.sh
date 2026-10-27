#!/bin/bash
# THE START MENU MUST AGREE ACROSS CELLS OF ONE OS FAMILY, and meet the absolute expectation.
# run: tools/tests/dom0-callers-count-selftest.sh
# pass: exit 0
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

out=$(run 85 win10 win10-clean); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa 'recorded 85 entries'; then
  ok "the FIRST cell of a family records its count as the campaign baseline"
else no "the first cell did not record (rc=$rc)" "$out"; fi

out=$(run 85 win10 win10-reinstall); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa 'agrees with the other win10'; then
  ok "a later cell with the SAME count agrees and passes"
else no "an agreeing cell did not pass (rc=$rc)" "$out"; fi

out=$(run 12 win10 win10-upgrade); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | command grep -qa 'DISAGREES across win10'; then
  ok "a cell whose menu dropped to 12 FAILS, naming both counts - the case the floor of 10 passed"
else no "an amputated menu passed (rc=$rc)" "$out"; fi

out=$(run 78 win11 win11-clean); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa 'recorded 78 entries'; then
  ok "win11 keeps its own baseline - families do not contaminate each other"
else no "the win11 family shared win10's baseline (rc=$rc)" "$out"; fi

out=$(run 12 '' ''); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa 'did not run'; then
  ok "with no campaign dir the comparison says it did not run, rather than passing silently"
else no "a missing campaign dir behaved unexpectedly (rc=$rc)" "$out"; fi

# ---- THE ABSOLUTE EXPECTATION: the case NO cross-cell comparison can see --------------------
# If the GOLDEN is amputated, every clone agrees on the same wrong number, so the cross-cell test
# passes and the floor of 10 passes. 0.83 campaign-stopper, tier re-check 2026-10-21.
rm -f "$T/m"/callers-entries-*.txt       # a fresh campaign dir, so agreement is not what decides
out=$(run 40 win11 win11-clean); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | command grep -qa 'BELOW the measured expectation for win11'; then
  ok "40 entries FAILS against the measured win11 expectation, with no other cell to compare to"
else no "an amputated golden's count passed (rc=$rc)" "$out"; fi

rm -f "$T/m"/callers-entries-*.txt
out=$(run 70 win11 win11-clean); rc=$?
[ "$rc" = 0 ] && ok "70 entries (78-8, the recorded tolerance) still passes - the bound is not a trap" \
             || no "the tolerance boundary failed (rc=$rc)" "$out"

rm -f "$T/m"/callers-entries-*.txt
out=$(run 69 win11 win11-clean); rc=$?
[ "$rc" != 0 ] && ok "and 69, one below the bound, fails - the predicate responds to the number" \
               || no "one entry below the bound still passed (rc=$rc)" "$out"

# A FAMILY WITH NO RECORDED EXPECTATION MUST NOT FAIL. The first cell of a family is floor-only by
# construction; refusing it would fail every campaign's first cell (Jev 0.34 on that).
rm -f "$T/m"/callers-entries-*.txt
out=$(run 40 win11de win11de-clean); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa 'FLOOR-ONLY'; then
  ok "an un-seeded family says FLOOR-ONLY and carries on, rather than failing or passing silently"
else no "an un-seeded family behaved unexpectedly (rc=$rc)" "$out"; fi

# SEEN TO FAIL: with the absolute block removed, the agreeing-amputated count passes again.
noabs=$(printf '%s' "$blk" | sed '/_ce_file=/,/^fi$/d')
if printf '%s' "$noabs" | command grep -qa '_ce_file='; then
  no "the control still contains the absolute block" "the sed range did not cut it"
else
  rm -f "$T/m"/callers-entries-*.txt
  out=$(bash -c '
    rc_all=0; bad(){ printf "BAD %s\n" "$*"; rc_all=1; }; good(){ printf "OK %s\n" "$*"; }
    ents="$1"; CALLERS_COUNT_DIR="$2"; CALLERS_FAMILY="$3"; CALLERS_CELL="$4"
    eval "$5"; exit $rc_all' _ 40 "$T/m" win11 win11-clean "$noabs" 2>&1); rc=$?
  [ "$rc" = 0 ] \
    && ok "SEEN TO FAIL: without the absolute test, 40 entries passes on the floor and agreement" \
    || no "the control still refused 40 entries (rc=$rc)" "$out"
fi

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
