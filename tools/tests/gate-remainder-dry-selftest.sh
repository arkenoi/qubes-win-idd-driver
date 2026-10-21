#!/bin/bash
# A DRY RUN MUST NOT PRODUCE A PASS.
#
# MEASURED 2026-10-21, before the fix: `tools/gate-remainder.sh --dry` put all four reachable
# suites in PASSED and exited 0, because run_it's dry branch prints its intent and returns 0 and
# `note $?` read that 0 as a result. acceptance-plan.py:202 makes that dry call the remainder
# cell's FIRST PROBE - so the probe could not fail, whatever the rig's state, and the dry merge
# line named those suites as if they had been seen to pass.
#
# The strongest leg here runs the SHIPPED script, not a model of it. T6 drives the pre-fix
# definition through the same assertion as T4 and requires it to fail - a test that cannot tell
# the two apart is not testing the fix.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
SCRIPT=tools/gate-remainder.sh
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf 'ok   %s\n' "$*"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$*"; }

# ---- the shipped script, run dry on targets that do not exist ---------------------------------
OUT=$(timeout -k 10 300 bash "$SCRIPT" --run 999999 \
        --vm10 dry-nonexistent-10 --vm11 dry-nonexistent-11 --os11 dry-nonexistent --dry 2>&1)
rc=$?
[ "$rc" = 0 ] && ok "T1 the dry run completed (exit 0)" || no "T1 the dry run exited $rc"

pline=$(printf '%s\n' "$OUT" | command grep -aoE 'passed:.*$'   | tail -1 | sed 's/^passed://')
iline=$(printf '%s\n' "$OUT" | command grep -aoE 'intended:.*$' | tail -1 | sed 's/^intended://')
mline=$(printf '%s\n' "$OUT" | command grep -aoE 'INTEND\[dry\] merge into [^:]*:.*$' | tail -1 | sed 's/.*json://')

# THE PROPERTY: nothing is passed by a run that executed nothing.
if [ -z "${pline// /}" ]; then ok "T2 a dry run reports NO passed suite"
else no "T2 a dry run reported passed:$pline"; fi

# AND IT DID NOT PASS BY DOING NOTHING: the suites were reached, and named as intentions.
if [ -n "${iline// /}" ]; then ok "T3 the suites it would run are named: intended:$iline"
else no "T3 no intended set - the dry run reached no suite, so T2 proves nothing"; fi

# THE RECEIPT MERGE NAMES THE INTENTION, NOT A PASS.
if [ "${mline// /}" = "${iline// /}" ] && [ -n "${mline// /}" ]; then
  ok "T4 the dry merge line names the intended set"
else no "T4 dry merge names '$mline' while intended is '$iline'"; fi

# ---- the shipped note(), extracted exactly and executed -----------------------------------------
# No reimplementation: this evals the definition the file ships. A hand-written copy would pass
# with the shipped one reverted (measured twice this week on whole-file greps).
defn=$(sed -n '/^note() {$/,/^}$/p' "$SCRIPT")
if [ -n "$defn" ]; then ok "T5 note() was extracted from $SCRIPT ($(printf '%s' "$defn" | wc -l) lines)"
else no "T5 could not extract note() - the suite below would test nothing"; fi

run_note() {  # run_note <dry> <rc> <label>  -> prints "P=<passed> F=<failed> I=<intended>"
  local d="$1" r="$2" l="$3"
  bash -c '
    set -uo pipefail
    DRY="$1"; PASSED=""; FAILED=""; INTENDED=""
    eval "$4"
    note "$2" "$3"
    printf "P=%s F=%s I=%s\n" "${PASSED// /}" "${FAILED// /}" "${INTENDED// /}"
  ' _ "$d" "$r" "$l" "$defn"
}

got=$(run_note 1 0 suiteX)
[ "$got" = "P= F= I=suiteX" ] && ok "T6 DRY=1 with rc 0 buckets to INTENDED, not PASSED" \
                              || no "T6 DRY=1 rc 0 gave: $got"

got=$(run_note 0 0 suiteX)
[ "$got" = "P=suiteX F= I=" ] && ok "T7 DRY=0 with rc 0 still passes" || no "T7 DRY=0 rc 0 gave: $got"

got=$(run_note 0 1 suiteY)
[ "$got" = "P= F=suiteY I=" ] && ok "T8 DRY=0 with rc 1 still fails" || no "T8 DRY=0 rc 1 gave: $got"

got=$(run_note 1 1 suiteZ)
[ "$got" = "P= F= I=suiteZ" ] && ok "T9 DRY=1 with rc 1 is an intention too, not a failure" \
                             || no "T9 DRY=1 rc 1 gave: $got"

# ---- DISCRIMINATION: the pre-fix definition must FAIL T6's assertion ---------------------------
defn='note() { if [ "$1" = 0 ]; then PASSED="$PASSED $2"; else FAILED="$FAILED $2"; fi; }'
got=$(run_note 1 0 suiteX)
if [ "$got" = "P= F= I=suiteX" ]; then
  no "T10 the pre-fix note() ALSO satisfies T6 - this suite cannot tell the fix from the defect"
else
  ok "T10 the pre-fix note() fails T6 as it must (it gave: $got)"
fi

# ---- run_it's dry contract is unchanged, so no caller's rc handling moved -----------------------
rdefn=$(sed -n '/^run_it() {/,/^}$/p' "$SCRIPT")
got=$(bash -c '
  set -uo pipefail
  DRY=1; LOG=/dev/null
  eval "$1"
  run_it label true; printf "rc=%s\n" "$?"
' _ "$rdefn" 2>/dev/null | tail -1)
[ "$got" = "rc=0" ] && ok "T11 run_it still returns 0 under DRY=1 (contract unchanged)" \
                    || no "T11 run_it under DRY=1 gave: $got"

# ---- the report still prints the intended line, so its removal is caught -----------------------
command grep -qaF 'say "intended:$INTENDED"' "$SCRIPT" \
  && ok "T12 the report prints the intended set" \
  || no "T12 no intended line in the report - a dry run would go unrecorded"

echo "=== gate-remainder-dry: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
