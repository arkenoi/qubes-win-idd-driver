#!/bin/bash
# stall-repro-gate.sh - refuse a reproduction pass that is not the same situation as the failure.
#
# OWNER, 2026-09-22: "make jev judgement before every pass: if it is deemed 'not similar', abort and
# correct." Every reproduction attempt so far deviated from the run it was meant to reproduce and
# nobody noticed until the pass had been spent - 16 A/B runs and 33 aging cycles that could not have
# reproduced anything, because they differed from the reference in ways no one checked.
#
#   mgmt/harness/stall-repro-gate.sh <vm> <run-out-dir> [reference.json]
#
# Exit 0  = Jev judges this pass 1:1 with the reference; run it.
# Exit 1  = NOT the same situation. The caller must abort and correct, not proceed and hope.
# Exit 2  = the gate itself could not run (Jev absent, reference missing). NEVER read as a pass.
#
# It compares what CAN be compared and says loudly what cannot: the reference run predates the
# guest-config snapshot and the module-base recorder, so those fields are unknown for it. A gate
# that hid that would license "1:1" claims that are false.
set -u
VM="${1:?usage: stall-repro-gate.sh <vm> <run-out-dir> [reference.json]}"
OUT="${2:?usage: stall-repro-gate.sh <vm> <run-out-dir> [reference.json]}"
REF="${3:-mgmt/reference/stall-20260922.json}"
cd "$(dirname "$0")/.." 2>/dev/null; cd "$(git rev-parse --show-toplevel)" || exit 2
mkdir -p "$OUT" || exit 2
say(){ echo "$(date -u +%H:%M:%SZ) stall-gate: $*"; }

[ -f "$REF" ] || { say "GATE COULD NOT RUN: no reference profile at $REF"; exit 2; }

# The candidate's own state, measured now, by the same instrument every run uses.
CAND="$OUT/guest-config-pregate.txt"
if ./tools/guest-config-snapshot.sh "$VM" "$OUT" pregate >/dev/null 2>&1; then
  CAND="$OUT/guest-config-pregate.txt"
else
  say "GATE COULD NOT RUN: the candidate snapshot failed - that is missing data, not similarity"
  exit 2
fi

STATE="$OUT/jev-stallgate-state.txt"
RUBRIC="$OUT/jev-stallgate-rubric.json"
{
  echo "QUESTION: is the pass about to run the SAME SITUATION as the reference failure, closely"
  echo "enough that a null result would mean anything?"
  echo
  echo "THE REFERENCE FAILURE (machine-extracted from its own artefacts, tools/stall-reference.py):"
  cat "$REF"
  echo
  echo "HOW THIS CANDIDATE PASS IS BEING INVOKED: ${STALL_REPRO_INVOKED_BY:-a bare quick-upgrade, NOT through any feature test}"
  echo "(The reference failure's own invoked_by field says which harness called quick-upgrade there."
  echo " A pass invoked differently has already deviated, however similar the guest is.)"
  echo
  echo "THE CANDIDATE PASS, measured now on $VM (tools/guest-config-snapshot.sh):"
  sed -n '1,120p' "$CAND"
  echo
  echo "FACTS THAT CUT AGAINST CLAIMING A MATCH:"
  echo "- The reference run predates the guest-config snapshot and the module-base recorder, so for"
  echo "  those fields the reference is UNKNOWN and no comparison is possible - see"
  echo "  unrecorded_at_reference_time in the profile above."
  echo "- The reference failure produced ZERO installer output and its launch call timed out: the"
  echo "  failure window is 60 s between two qrexec calls, so any factor that only exists later in"
  echo "  an install cannot be what a reproduction needs to recreate."
  echo "- 49 deliberate attempts (16 A/B runs, 33 aging cycles) produced no stall; none of them was"
  echo "  ever checked against this reference before being spent."
} > "$STATE"

cat > "$RUBRIC" <<'JSON'
{"questions":{
 "matches_recorded":{"type":"noul",
  "instructions":{"judge":"On every dimension the reference ACTUALLY RECORDED, does the candidate match it? Judge only those dimensions; the reference's unrecorded fields are handled by the next question and must not lower this one."},
  "criteria":{"true":"every recorded dimension of the reference is matched","false":"at least one recorded dimension differs"}},
 "is_one_to_one":{"type":"noul",
  "instructions":{"judge":"Separately: would a null result from this pass be informative about the reference failure - i.e. is this a FAITHFUL 1:1 reproduction? Unknown-on-the-reference-side is not a match; it is an unknown, and it belongs in this answer."},
  "criteria":{"true":"faithful enough that a null result would mean something","false":"too much of the reference is unknown, so a null result would prove nothing"}},
 "worst_mismatch":{"type":"choice",
  "instructions":{"judge":"Which difference or unknown most undermines this as a reproduction?"},
  "criteria":{
   "entry-build-differs":"The guest does not carry the reference's entry QWT build.",
   "delivery-differs":"The payload does not reach the guest the way it did in the reference.",
   "invoked-differently":"The pass is invoked by a different caller than the reference run was.",
   "reference-unknowns":"Too much of the reference was never recorded to establish a match.",
   "nothing-material":"No difference or unknown materially undermines it."}}}}
JSON

OUTJ="$OUT/jev-stallgate-answers.json"
if ! timeout 300 python3 tools/jev.py "$RUBRIC" "$STATE" --out "$OUTJ" > "$OUT/jev-stallgate.out" 2>&1; then
  say "GATE COULD NOT RUN: jev.py did not answer (exit 2 means the instrument did not run, never a pass)"
  sed -n '1,5p' "$OUT/jev-stallgate.out"
  exit 2
fi
cat "$OUT/jev-stallgate.out"

read -r SAME ONE1 <<< "$(python3 - "$OUTJ" <<'PYEOF'
import json, sys
# jev.py --out writes {"model":..,"answers":{"<q>":{"type":"noul","noul":0.03}},..} - read THAT
# shape. The first version guessed at the keys, found nothing, and reported "gate could not run"
# while Jev had in fact answered 0.03: a parser that cannot read its own instrument turns a
# correct REFUSAL into an inconclusive one.
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit
a = d.get("answers") or {}
m = (a.get("matches_recorded") or {}).get("noul")
o = (a.get("is_one_to_one") or {}).get("noul")
# Both numbers or nothing: a half-read verdict is missing data, not a partial pass.
print("" if not isinstance(m, (int, float)) else m, "" if not isinstance(o, (int, float)) else o)
PYEOF
)"
[ -n "$SAME" ] || { say "GATE COULD NOT RUN: no matches_recorded value in $OUTJ"; exit 2; }
say "jev matches_recorded=$SAME is_one_to_one=${ONE1:-?}"
echo "matches_recorded=$SAME is_one_to_one=${ONE1:-?}" > "$OUT/REPRO-FIDELITY.txt"
awk -v v="${ONE1:-0}" 'BEGIN{exit !(v+0 < 0.70)}' && say "NOTE: this pass is NOT a faithful 1:1 reproduction (is_one_to_one=${ONE1:-?}) - a null result from it proves nothing about the reference; recorded in $OUT/REPRO-FIDELITY.txt"
awk -v v="$SAME" 'BEGIN{exit !(v+0 >= 0.70)}' && { say "PASS MAY RUN: judged the same situation"; exit 0; }
say "ABORT: the candidate differs from the reference on a RECORDED dimension (matches_recorded=$SAME) - correct it rather than spending the run"
exit 1
