#!/bin/bash
# SELF-TEST for mgmt/harness/verdict-lib.sh AND for p3a-etw-gate.sh's GATE block - every class
# boundary SEEN TO FIRE before either is trusted (H5 applied to the aggregator, same doctrine as
# tools/tests/lint-selftest.sh and protocol/selftest.sh). Offline: touches no guest.
#
# Why each case exists (the two incidents the lib was written against):
#   * 2026-08-30: a ledger with a FAIL summarised as complete -> BROKEN must win over everything.
#   * 2026-09-05: `grep -cE 'FAIL|INSTRUMENT'` folded ungraded rows into the blocking count ->
#     an INSTRUMENT-only ledger must be EXECUTED-WITH-GAPS (rc 1: not green, not broken), a
#     PASS-DATUM must be a pass, and p3a's GATE must say PICK-ETW (not BLOCKED) over ungraded or
#     PASS-DATUM drills, UNDECIDED over an ungraded MECHANISM row, BLOCKED only on a FAIL.
#
# Section 2 does NOT copy the gate logic: it extracts the live block from p3a-etw-gate.sh
# (between its '# THREE-CLASS AGGREGATION' marker and the final exit) and runs it against
# fixture ledgers, so the test cannot drift from the code it certifies.
#
#   tools/tests/verdict-lib-selftest.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
LIB=mgmt/harness/verdict-lib.sh
P3A=mgmt/harness/p3a-etw-gate.sh
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "  PASS  $*"; pass=$((pass+1)); }
no(){ echo "  FAIL  $*"; fail=$((fail+1)); }

# shellcheck disable=SC1090
source "$LIB"

echo "== 1. verdict_class: every leading token lands in its class =="
expect_class(){ # <text> <class>
  local got; got=$(verdict_class "$1")
  [ "$got" = "$2" ] && ok "class('$1') = $2" || no "class('$1') = $got, wanted $2"
}
expect_class "PASS canonical row classifies" PASS
expect_class "PASS-DATUM id join DEAD on this build" PASS-DATUM
expect_class "FAIL only 1 src=etw-sig rows" FAIL
expect_class "INSTRUMENT blog_len unreadable" INVALID
expect_class "INVALID-INSTRUMENT counter returned no data" INVALID
expect_class "INVALID-PRECONDITION cell claims pristine" INVALID
expect_class "INCONCLUSIVE" INVALID
expect_class "FAIL-MINE probe threw" INVALID
expect_class "ATTENDED-PENDING dom0 render witness captured" ATTENDED
expect_class "primed, build identity proven, gate on, cold-booted" OTHER
expect_class "PICK-ETW - grant + signal flow proven" OTHER

echo "== 2. verdict_aggregate: the three statuses, each seen to fire =="
run_agg(){ # <fixture-name> <ledger-lines...> ; sets AGG_RC and leaves VS_* set
  local f="$TMP/$1.txt"; shift
  printf '%s\n' "$@" > "$f"
  verdict_aggregate "$f" >/dev/null; AGG_RC=$?
}
run_agg clean "T0|primed" "T2|PASS grant" "T3|PASS row" "T3j|PASS-DATUM join dead" "T7w|ATTENDED-PENDING witness captured"
[ "$AGG_RC" = 0 ] && [ "$VS_STATUS" = CLEAN ] && [ "$VS_DATUM" = 1 ] && [ "$VS_ATTENDED" = 1 ] && [ "$VS_FAIL" = 0 ] && [ "$VS_INVALID" = 0 ] \
  && ok "PASS + PASS-DATUM + ATTENDED + untyped -> CLEAN rc=0 (PASS-DATUM counted as a pass, attended row gates nothing)" \
  || no "clean fixture: rc=$AGG_RC status=$VS_STATUS datum=$VS_DATUM attended=$VS_ATTENDED fail=$VS_FAIL invalid=$VS_INVALID"

run_agg gaps "T2|PASS grant" "T8a|INSTRUMENT fire+purge produced no CLASSIFY" "T8c|INSTRUMENT blog_len unreadable"
[ "$AGG_RC" = 1 ] && [ "$VS_STATUS" = EXECUTED-WITH-GAPS ] && [ "$VS_INVALID" = 2 ] && [ "$VS_FAIL" = 0 ] && [ "$VS_INVALID_LABELS" = "T8a T8c" ] \
  && ok "INSTRUMENT rows -> EXECUTED-WITH-GAPS rc=1, never green, never FAIL (labels: $VS_INVALID_LABELS)" \
  || no "gaps fixture: rc=$AGG_RC status=$VS_STATUS invalid=$VS_INVALID fail=$VS_FAIL labels='$VS_INVALID_LABELS'"

run_agg broken "T2|PASS grant" "T8a|INSTRUMENT ungraded" "T6|FAIL src=etw-sig median materially worse" "T8b|PASS-DATUM twins pinned"
[ "$AGG_RC" = 2 ] && [ "$VS_STATUS" = BROKEN ] && [ "$VS_FAIL" = 1 ] && [ "$VS_INVALID" = 1 ] && [ "$VS_FAIL_LABELS" = T6 ] \
  && ok "one FAIL among ungraded + datum rows -> BROKEN rc=2, FAIL and ungraded counted SEPARATELY (fail=$VS_FAIL invalid=$VS_INVALID)" \
  || no "broken fixture: rc=$AGG_RC status=$VS_STATUS fail=$VS_FAIL invalid=$VS_INVALID labels='$VS_FAIL_LABELS'"

: > "$TMP/empty.txt"; verdict_aggregate "$TMP/empty.txt" >/dev/null; rc=$?
[ "$rc" = 3 ] && ok "empty ledger -> UNUSABLE rc=3 (nothing graded is not a pass - V3)" || no "empty ledger rc=$rc"
verdict_aggregate "$TMP/does-not-exist.txt" >/dev/null; rc=$?
[ "$rc" = 3 ] && ok "missing ledger -> UNUSABLE rc=3" || no "missing ledger rc=$rc"

printf '%s\n' "T2|PASS" "GATE|PICK-ETW-BLOCKED - 1 product FAIL" > "$TMP/skip.txt"
verdict_aggregate "$TMP/skip.txt" '^GATE$' >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$VS_TOTAL" = 1 ] && ok "SKIP_RE excludes the GATE row from the count (total=$VS_TOTAL)" || no "skip fixture rc=$rc total=$VS_TOTAL"

# text containing '|' must not split the row (T5 emits '(net localgroup ...) -join "|"')
run_agg pipe 'T5|PASS census clean (plu -join "|" recorded)'
[ "$VS_PASS" = 1 ] && [ "$VS_TOTAL" = 1 ] && ok "a '|' inside TEXT does not split the row" || no "pipe-in-text: pass=$VS_PASS total=$VS_TOTAL"

echo "== 3. the wire-format marker survives (p6-toast-bridge.json keys on it) =="
run_agg marker "P7|INSTRUMENT burst" "P8|FAIL heartbeat present"
line=$(verdict_done_line "x")
printf '%s' "$line" | grep -qE '=== done: 2 FAIL/INSTRUMENT line\(s\)' \
  && ok "done line keeps '=== done: N FAIL/INSTRUMENT line(s)' with N=FAIL+ungraded: $line" \
  || no "done line lost the marker: $line"

echo "== 4. p3a GATE block (extracted LIVE from $P3A) against fixture ledgers =="
start=$(grep -n '^# THREE-CLASS AGGREGATION' "$P3A" | head -1 | cut -d: -f1)
end=$(grep -n '^exit "\$gate_rc"' "$P3A" | tail -1 | cut -d: -f1)
if [ -z "$start" ] || [ -z "$end" ] || [ "$end" -le "$start" ]; then
  no "could not locate the GATE block in $P3A (start=$start end=$end)"
else
  sed -n "${start},${end}p" "$P3A" | sed 's/^exit "\$gate_rc"$/return "$gate_rc"/' > "$TMP/gate-block.sh"
  bash -n "$TMP/gate-block.sh" && ok "extracted GATE block parses (lines $start-$end)" || no "extracted GATE block does not parse"
fi
run_gate(){ # <fixture> <rows...> ; prints the GATE text, sets GATE_RC
  local f="$TMP/gate-$1"; shift
  mkdir -p "$f"; printf '%s\n' "$@" > "$f/verdicts.txt"
  GATE_TEXT=$(
    OUT="$f"; VM=fixture; R="$f/results.log"; : > "$R"
    log(){ :; }
    verdict(){ echo "$1|$2" >> "$OUT/verdicts.txt"; }
    verdict_done_line(){ :; }
    # shellcheck disable=SC1090
    source "$LIB"
    gate_block(){ . "$TMP/gate-block.sh"; }
    gate_block; echo "RC=$?" > "$OUT/rc.txt"
    grep -a '^GATE|' "$OUT/verdicts.txt" | tail -1 | cut -d'|' -f2
  )
  GATE_RC=$(sed -n 's/^RC=//p' "$f/rc.txt" | tail -1)
}
MECH_OK=("T2|PASS grant" "T3|PASS row" "T3j|PASS join" "T4a|PASS guard" "T7a|PASS measure-only" "T7b|PASS forwards" "T7c|PASS control" "T7w|ATTENDED-PENDING witness captured")

run_gate clean "${MECH_OK[@]}" "T6|PASS ETW-first carries its value" "T8a|PASS fail-open" "T8b|PASS twins" "T8c|PASS squatter" "T8r|PASS recovered"
case "$GATE_TEXT" in "PICK-ETW - "*) ok "all clean -> '${GATE_TEXT:0:60}...' rc=$GATE_RC" ;; *) no "all clean -> '$GATE_TEXT'" ;; esac
[ "$GATE_RC" = 0 ] || no "all clean must exit 0, got $GATE_RC"

run_gate datum "${MECH_OK[@]}" "T6|PASS parity" "T8a|PASS-DATUM read beat the purge" "T8b|PASS-DATUM twins pinned" "T8c|PASS-DATUM relaunch beat the squatter"
case "$GATE_TEXT" in "PICK-ETW - "*"PASS-DATUM caveats"*"T8a T8b T8c"*) ok "PASS-DATUM drills -> PICK-ETW with caveats listed, rc=$GATE_RC (the 2026-09-05 fold made this PICK-ETW-BLOCKED)" ;; *) no "PASS-DATUM drills -> '$GATE_TEXT'" ;; esac
[ "$GATE_RC" = 0 ] || no "PASS-DATUM drills must exit 0 (they are passes), got $GATE_RC"

run_gate ungraded-drills "${MECH_OK[@]}" "T6|INSTRUMENT burst never FIRED" "T8a|INSTRUMENT no CLASSIFY" "T8b|PASS-DATUM dead branch" "T8c|PASS squatter" "T8r|PASS recovered"
case "$GATE_TEXT" in "PICK-ETW (2 drill(s) ungraded - re-run: T6 T8a)"*) ok "ungraded drills -> '${GATE_TEXT:0:48}' (still PICK-ETW, not BLOCKED)" ;; *) no "ungraded drills -> '$GATE_TEXT'" ;; esac
[ "$GATE_RC" = 1 ] && ok "ungraded drills -> exit 1 EXECUTED-WITH-GAPS (never green)" || no "ungraded drills exit=$GATE_RC, wanted 1"

run_gate fail "${MECH_OK[@]}" "T6|PASS parity" "T8a|FAIL sig-hit classified src=db under purge" "T8b|INSTRUMENT ungraded"
case "$GATE_TEXT" in "PICK-ETW-BLOCKED - 1 product FAIL(s): T8a"*) ok "a drill FAIL -> '${GATE_TEXT:0:44}' rc=$GATE_RC" ;; *) no "drill FAIL -> '$GATE_TEXT'" ;; esac
[ "$GATE_RC" = 2 ] || no "FAIL must exit 2, got $GATE_RC"

run_gate mech-fail "T2|PASS grant" "T3|PASS row" "T3j|PASS join" "T4a|FAIL SYSTEM launch rc=0 (wanted 9)" "T7a|PASS" "T7b|PASS" "T7c|PASS" "T7w|ATTENDED-PENDING captured" "T8a|PASS-DATUM"
case "$GATE_TEXT" in "PICK-ETW-BLOCKED - 1 product FAIL(s): T4a (mechanism phase(s) among them: T4a)"*) ok "a mechanism FAIL -> BLOCKED naming it" ;; *) no "mechanism FAIL -> '$GATE_TEXT'" ;; esac

run_gate mech-ungraded "T2|PASS grant" "T3|PASS row" "T3j|PASS join" "T4a|PASS guard" "T7a|PASS" "T7b|INSTRUMENT fire path failed" "T7c|PASS" "T7w|INSTRUMENT no forward ack to witness" "T8a|PASS-DATUM"
case "$GATE_TEXT" in "UNDECIDED - mechanism phase(s) ungraded: T7b(INVALID) T7w(INVALID)"*) ok "ungraded MECHANISM rows -> UNDECIDED (not PICK-ETW, not BLOCKED)" ;; *) no "mechanism ungraded -> '$GATE_TEXT'" ;; esac
[ "$GATE_RC" = 1 ] || no "mechanism ungraded must exit 1, got $GATE_RC"

run_gate missing-witness "T2|PASS grant" "T3|PASS row" "T3j|PASS join" "T4a|PASS guard" "T7a|PASS" "T7b|PASS" "T7c|PASS" "T8a|PASS"
case "$GATE_TEXT" in "UNDECIDED - mechanism phase(s) ungraded: T7w(MISSING)"*) ok "a mechanism row ABSENT from the ledger -> UNDECIDED (absence is missing data, never a pass)" ;; *) no "missing mechanism row -> '$GATE_TEXT'" ;; esac

run_gate fall "T2|PASS grant" "T3|FAIL canonical row" "T3j|PASS" "T4a|PASS" "T7a|PASS" "T7b|PASS" "T7c|PASS" "T7w|ATTENDED-PENDING x"
case "$GATE_TEXT" in "FALL-TO-DB - "*) ok "T3 FAIL -> FALL-TO-DB (the §10.16.4 path is intact)" ;; *) no "T3 FAIL -> '$GATE_TEXT'" ;; esac
[ "$GATE_RC" = 2 ] || no "FALL-TO-DB carries a FAIL and must exit 2, got $GATE_RC"

run_gate t3j-datum "T2|PASS grant" "T3|PASS row" "T3j|PASS-DATUM id join DEAD, fallback carries" "T4a|PASS" "T7a|PASS" "T7b|PASS" "T7c|PASS" "T7w|ATTENDED-PENDING x"
case "$GATE_TEXT" in "PICK-ETW - "*) ok "T3j PASS-DATUM (design datum) satisfies the mechanism set" ;; *) no "T3j PASS-DATUM -> '$GATE_TEXT'" ;; esac

echo ""
echo "---- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
