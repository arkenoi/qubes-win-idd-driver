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
 "same_situation":{"type":"noul",
  "instructions":{"judge":"Is the candidate pass the SAME SITUATION as the reference failure on every dimension the reference actually recorded - so that a null result from it would be informative? Judge only from `state`. Unknown-on-the-reference-side is NOT a match; it is an unknown."},
  "criteria":{"true":"every recorded dimension of the reference is matched by the candidate","false":"at least one recorded dimension differs, or too much of the reference is unknown for the comparison to mean anything"}},
 "worst_mismatch":{"type":"choice",
  "instructions":{"judge":"Which difference or unknown most undermines this as a reproduction?"},
  "criteria":{
   "entry-build-differs":"The guest does not carry the reference's entry QWT build.",
   "delivery-differs":"The payload does not reach the guest the way it did in the reference.",
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

SAME=$(python3 - "$OUTJ" <<'PYEOF'
import json, sys
# jev.py --out writes {"model":..,"answers":{"<q>":{"type":"noul","noul":0.03}},..} - read THAT
# shape. The first version guessed at the keys, found nothing, and reported "gate could not run"
# while Jev had in fact answered 0.03: a parser that cannot read its own instrument turns a
# correct REFUSAL into an inconclusive one.
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit
q = (d.get("answers") or {}).get("same_situation") or {}
v = q.get("noul")
print("" if not isinstance(v, (int, float)) else v)
PYEOF
)
[ -n "$SAME" ] || { say "GATE COULD NOT RUN: no same_situation value in $OUTJ"; exit 2; }
say "jev same_situation=$SAME"
awk -v v="$SAME" 'BEGIN{exit !(v+0 >= 0.70)}' && { say "PASS MAY RUN: judged the same situation"; exit 0; }
say "ABORT: this pass is NOT the reference situation (same_situation=$SAME) - correct it rather than spending the run"
exit 1
