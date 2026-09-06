# mgmt/harness/verdict-lib.sh — the THREE-CLASS verdict aggregator for `LABEL|TEXT` ledgers
# (the verdicts.txt that verdict(){ echo "$1|$2"; } writes in a0-toast-bridge.sh,
# a0-p3-toast-split.sh and p3a-etw-gate.sh).
#
# WHY THIS EXISTS. Two incidents, opposite directions, same root cause - a verdict ledger
# summed by a single grep:
#   * 2026-08-30 (tools/campaign-verdict.sh header): a campaign with a product FAIL, INVALID
#     cells and INCONCLUSIVEs was reported "complete" because the summary was prose and prose
#     lets you average. The fix there was an ARITHMETIC verdict with INVALID-* and FAIL as
#     SEPARATE blocker classes (invariants V2 "INVALID-* is never folded into FAIL" and V3
#     "missing data is INVALID-INSTRUMENT, never FAIL, never a default" in protocol/run.py).
#   * 2026-09-05 (a0-toast-bridge.sh 72f1903): the old `grep -c FAIL` exit gate let an
#     UNEXERCISED phase read green, so the gate was widened to `grep -cE 'FAIL|INSTRUMENT'` -
#     which closed that hole by re-opening the 08-30 one: every ungraded drill now counted as
#     "the product is broken", and p3a-etw-gate.sh copied the line verbatim, so a degradation
#     drill that could not be staged BECAUSE the primary path is reliable flipped PICK-ETW to
#     PICK-ETW-BLOCKED. Three genuinely different outcomes were one blocking integer.
#
# THE THREE CLASSES (the leading token of TEXT decides; the wire format is unchanged):
#   FAIL            the product misbehaved. Gates. Nothing else does.
#   INVALID         INSTRUMENT / INVALID-* / INCONCLUSIVE / BLOCKED / SKIPPED / FAIL-MINE: the
#                   datum needed to grade was not captured, a probe or stimulus broke, a
#                   precondition the HARNESS owns did not land. Never reads green (the run is
#                   EXECUTED-WITH-GAPS, exit 1) and is surfaced on its OWN channel as "N ungraded -
#                   re-run"; never reported as a product defect.
#   PASS-DATUM      an adversarial drill tried to manufacture a failure condition and COULD NOT,
#                   because the primary path is reliable by design (the id-join read out-ran an
#                   injected purge; twins cannot look ambiguous while every method joins by a
#                   unique id; the supervisor relaunch beat an in-process pipe squatter). That is
#                   POSITIVE evidence about the product - a measured property - and counts as a
#                   pass. It is listed by name so a reader can see which drills graded this way.
#   (PASS, and untyped informational rows such as "primed, ..." are counted and printed but gate
#   nothing; ATTENDED-PENDING rows - a captured witness whose grading needs an operator - are
#   printed on every branch so they can never be quietly omitted, campaign-verdict.sh style.)
#
# THE DISCRIMINATOR the phase code must apply BEFORE emitting a row (this file only aggregates):
#   - the drill's precondition failed BECAUSE the product under test is reliable  -> PASS-DATUM
#   - the precondition failed for a harness/timing/environment reason INDEPENDENT of the product
#     (offset unreadable, no user session, the fire path never confirmed FIRED)   -> INSTRUMENT
#   - the product did the wrong thing                                              -> FAIL
#   A phase that SHOULD have exercised the product but whose product-side stimulus genuinely
#   failed is INSTRUMENT (or FAIL when the stimulus path IS the thing under test) - never
#   PASS-DATUM. "Could not stage because reliable" needs the evidence that the product acted
#   (the row was read, the id joined, the relaunch landed); without that evidence it is
#   ungraded.
#
# API (bash, sourced; needs no other lib - uses log() when the caller defines it, else echo):
#   verdict_class TEXT                 -> prints PASS | PASS-DATUM | FAIL | INVALID | ATTENDED | OTHER
#   verdict_label_class FILE LABEL     -> class of the LAST row carrying LABEL, or MISSING
#   verdict_aggregate FILE [SKIP_RE]   -> logs the breakdown, sets VS_* (below), returns
#                                          0 CLEAN | 1 EXECUTED-WITH-GAPS | 2 BROKEN | 3 UNUSABLE
#        VS_TOTAL VS_PASS VS_DATUM VS_FAIL VS_INVALID VS_ATTENDED VS_OTHER   counts
#        VS_FAIL_LABELS VS_INVALID_LABELS VS_DATUM_LABELS VS_ATTENDED_LABELS  space-joined labels
#        VS_STATUS   CLEAN | EXECUTED-WITH-GAPS | BROKEN | UNUSABLE
#        SKIP_RE (optional, extended regex on the LABEL) excludes rows such as the GATE line
#        a harness appends AFTER aggregating.
#   verdict_done_line FILE-DESC        -> the "=== done: N FAIL/INSTRUMENT line(s) ..." wrap line.
#        N stays FAIL+INVALID because protocol/steps/p6-toast-bridge.json's terminal-line regex
#        keys on exactly '=== done: [0-9]+ FAIL/INSTRUMENT line(s)'; the class breakdown follows
#        on the same line. The wrapper grades N's composition itself (p6-a0-instrument-clean
#        routes '|INSTRUMENT' rows to INVALID-INSTRUMENT), which is why the INSTRUMENT spelling of
#        an ungraded row is part of the wire format and stays.
#
# Exit-code contract for a harness that ends with `exit $VS_RC` (or `verdict_aggregate ...; exit $?`):
#   0 = CLEAN: zero FAIL, zero ungraded. The only green.
#   1 = EXECUTED-WITH-GAPS: zero FAIL but >=1 ungraded row - the product decision (if the harness
#       makes one) stands, the RUN is incomplete: re-run to close the gaps. Never green.
#   2 = BROKEN: >=1 FAIL.
#   3 = UNUSABLE: no ledger / empty ledger (nothing was graded at all - V3).
# A caller that only tests `|| fail` sees every non-clean run as non-green, which is the
# conservative reading; a caller that wants the three-way split reads the code.

verdict_class(){ # $1 = verdict TEXT
  local tok="${1%%[[:space:]]*}"
  case "$tok" in
    PASS-DATUM*)                       echo PASS-DATUM ;;
    PASS*)                             echo PASS ;;
    ATTENDED-PENDING*)                 echo ATTENDED ;;
    FAIL-MINE*)                        echo INVALID ;;   # campaign-verdict's "instrumentation" FAIL class
    FAIL*)                             echo FAIL ;;
    INSTRUMENT*|INVALID*|INCONCLUSIVE*|UNGRADED*|BLOCKED*|SKIPPED*) echo INVALID ;;
    *)                                 echo OTHER ;;
  esac
}

verdict_label_class(){ # $1 = ledger file, $2 = LABEL -> class of its LAST row, or MISSING
  local line
  line=$(grep -a -- "^$2|" "$1" 2>/dev/null | tail -1)
  [ -n "$line" ] || { echo MISSING; return 1; }
  verdict_class "${line#*|}"
}

_vs_log(){ if declare -F log >/dev/null 2>&1; then log "$*"; else echo "$*"; fi; }

verdict_aggregate(){ # $1 = ledger file, $2 = optional extended regex of LABELs to skip
  local f="$1" skip="${2:-}" line label text cls
  VS_TOTAL=0; VS_PASS=0; VS_DATUM=0; VS_FAIL=0; VS_INVALID=0; VS_ATTENDED=0; VS_OTHER=0
  VS_FAIL_LABELS=""; VS_INVALID_LABELS=""; VS_DATUM_LABELS=""; VS_ATTENDED_LABELS=""
  VS_STATUS=UNUSABLE; VS_RC=3
  if [ ! -s "$f" ]; then
    _vs_log "VERDICTS: UNUSABLE - no ledger at '$f' (nothing was graded; V3: that is missing data, not a pass)"
    return 3
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in *'|'*) ;; *) continue ;; esac
    label="${line%%|*}"; text="${line#*|}"
    if [ -n "$skip" ] && printf '%s' "$label" | grep -qaE -- "$skip"; then continue; fi
    VS_TOTAL=$((VS_TOTAL+1))
    cls=$(verdict_class "$text")
    case "$cls" in
      PASS)       VS_PASS=$((VS_PASS+1)) ;;
      PASS-DATUM) VS_DATUM=$((VS_DATUM+1)); VS_DATUM_LABELS="$VS_DATUM_LABELS $label" ;;
      FAIL)       VS_FAIL=$((VS_FAIL+1)); VS_FAIL_LABELS="$VS_FAIL_LABELS $label" ;;
      INVALID)    VS_INVALID=$((VS_INVALID+1)); VS_INVALID_LABELS="$VS_INVALID_LABELS $label" ;;
      ATTENDED)   VS_ATTENDED=$((VS_ATTENDED+1)); VS_ATTENDED_LABELS="$VS_ATTENDED_LABELS $label" ;;
      *)          VS_OTHER=$((VS_OTHER+1)) ;;
    esac
  done < "$f"
  VS_FAIL_LABELS="${VS_FAIL_LABELS# }"; VS_INVALID_LABELS="${VS_INVALID_LABELS# }"
  VS_DATUM_LABELS="${VS_DATUM_LABELS# }"; VS_ATTENDED_LABELS="${VS_ATTENDED_LABELS# }"
  if [ "$VS_TOTAL" -eq 0 ]; then
    _vs_log "VERDICTS: UNUSABLE - '$f' has no LABEL|TEXT rows"
    return 3
  fi
  if   [ "$VS_FAIL" -gt 0 ];    then VS_STATUS=BROKEN;              VS_RC=2
  elif [ "$VS_INVALID" -gt 0 ]; then VS_STATUS=EXECUTED-WITH-GAPS;  VS_RC=1
  else                               VS_STATUS=CLEAN;               VS_RC=0
  fi
  _vs_log "VERDICTS: $VS_TOTAL rows = $VS_PASS PASS + $VS_DATUM PASS-DATUM + $VS_FAIL FAIL + $VS_INVALID ungraded (INSTRUMENT/INVALID) + $VS_ATTENDED attended-pending + $VS_OTHER untyped"
  # Two channels, printed separately on purpose - a FAIL is a defect report, an ungraded row is a
  # re-run request; one number for both is the disease this file exists to cure.
  [ "$VS_FAIL" -gt 0 ]     && _vs_log "VERDICTS: PRODUCT GATE: $VS_FAIL FAIL -> $VS_FAIL_LABELS"
  [ "$VS_INVALID" -gt 0 ]  && _vs_log "VERDICTS: UNGRADED (re-run to close; NOT a product verdict): $VS_INVALID -> $VS_INVALID_LABELS"
  [ "$VS_DATUM" -gt 0 ]    && _vs_log "VERDICTS: PASS-DATUM (drill un-stageable because the product is reliable - measured, passes): $VS_DATUM -> $VS_DATUM_LABELS"
  [ "$VS_ATTENDED" -gt 0 ] && _vs_log "VERDICTS: ATTENDED-PENDING (captured, operator must read it): $VS_ATTENDED -> $VS_ATTENDED_LABELS"
  _vs_log "VERDICTS: STATUS=$VS_STATUS (0 CLEAN / 1 EXECUTED-WITH-GAPS / 2 BROKEN -> rc=$VS_RC)"
  return "$VS_RC"
}

verdict_done_line(){ # $1 = trailing description (evidence dir, subject); needs verdict_aggregate first
  # '=== done: N FAIL/INSTRUMENT line(s)' is a machine-read terminal marker (p6-toast-bridge.json) -
  # keep that prefix byte-for-byte; the three-class breakdown rides behind it.
  echo "=== done: $((${VS_FAIL:-0}+${VS_INVALID:-0})) FAIL/INSTRUMENT line(s) [product FAIL=${VS_FAIL:-0} ungraded=${VS_INVALID:-0} pass-datum=${VS_DATUM:-0} status=${VS_STATUS:-UNUSABLE}]; $1 ==="
}
