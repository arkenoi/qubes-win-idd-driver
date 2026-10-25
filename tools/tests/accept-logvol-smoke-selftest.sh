#!/bin/bash
# THE BIND IS SMOKE-TESTED BEFORE THE CELLS - and this EXECUTES the code that makes it so.
#
# Campaign 40134888669 aborted 11 minutes into its FIRST cell because the guest could not see the
# log volume, having spent 10 of them installing. mgmt/harness/logvol-smoke.sh answers that question
# in 3 minutes on a clone of the QWT golden, and tools/release-acceptance.sh now runs it before the
# matrix. A gate that is wired but never seen to STOP a campaign is decoration, so every arm of that
# wiring is driven here against a stubbed smoke test: no guest, no clone, no rig call.
#
# THE ORDER IS PART OF THE PROPERTY. The refutation arm (--no-attach, where the bind MUST refuse)
# runs FIRST: if the binder answers ok with nothing attached then its receipt is not about the
# volume and the other arm's PASS means nothing. Asserted, not assumed.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
SRC=tools/release-acceptance.sh
[ -r "$SRC" ] || { echo "FATAL: $SRC missing"; exit 2; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

code=$(awk '/RASMOKE-A/,/RASMOKE-B/' "$SRC" | command grep -v 'RASMOKE-[AB]')
if [ -z "$code" ] || ! printf '%s' "$code" | command grep -qa 'logvol-smoke.sh'; then
  echo "FATAL: could not extract the smoke-cell code from $SRC between its markers"; exit 2
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/rasmoke-XXXXXX")
trap 'rc=$?; [ "$rc" -eq 0 ] && rm -rf "$T" || printf "kept %s\n" "$T" >&2' EXIT

run(){ # <smoke-rc-for-each-arm...> -> rc; $T/arms = the arms in the order they ran; $T/out
  local rcs="$1" skip="${2:-1}"
  rm -rf "$T/c" "$T/arms" "$T/out"; mkdir -p "$T/c/mgmt/harness"
  # the stub smoke test: records the arm it was called with, answers from the rc list in order
  cat > "$T/c/mgmt/harness/logvol-smoke.sh" <<EOF
#!/bin/bash
n=\$(cat "$T/n" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$T/n"
printf '%s\\n' "\${1:-ATTACH}" >> "$T/arms"
mkdir -p "\${LOGVOL_SMOKE_OUT:?the cell must name its own artefact dir}"
printf 'PASS\\tsomething\\tthe stub spoke\\n' > "\$LOGVOL_SMOKE_OUT/verdict.tsv"
exit \$(printf '%s' "$rcs" | cut -d, -f"\$n")
EOF
  chmod +x "$T/c/mgmt/harness/logvol-smoke.sh"
  : > "$T/n"
  ( cd "$T/c" && set +u
    CAMP="$T/c/campaign"; mkdir -p "$CAMP"
    say(){ printf '%s\n' "$*" >> "$T/out"; }
    die(){ printf 'DIE: %s\n' "$*" >> "$T/out"; exit 1; }
    LOGVOL_SMOKE="$skip"
    eval "$code"
    printf 'REACHED-THE-MATRIX\n' >> "$T/out" ) >/dev/null 2>&1
  echo $?
}
arms(){ [ -f "$T/arms" ] && tr '\n' ' ' < "$T/arms" || printf ''; }
outq(){ command grep -qa "$1" "$T/out" 2>/dev/null; }

# ---- 1. the clear case: both arms, refutation FIRST, then the matrix --------------------------
rc=$(run "0,0")
if [ "$rc" = 0 ] && outq 'REACHED-THE-MATRIX'; then ok "both arms PASS -> the campaign continues to the matrix"
else no "a passing smoke lets the campaign continue" "rc=$rc out=$(tr '\n' ' ' < "$T/out")"; fi
case "$(arms)" in "--no-attach ATTACH "*) ok "the REFUTATION arm runs FIRST, then the real one ($(arms))" ;;
  *) no "the refutation arm runs first" "arms='$(arms)' - a bind receipt nobody tried to refute says nothing about the volume" ;; esac

# ---- 2. THE GATE: a failing bind STOPS the campaign before any cell runs ----------------------
rc=$(run "0,1")
if [ "$rc" = 1 ] && ! outq 'REACHED-THE-MATRIX'; then ok "a FAILING bind stops the campaign - the matrix is never reached"
else no "a failing bind stops the campaign" "rc=$rc reached=$(outq 'REACHED-THE-MATRIX' && echo yes || echo no)"; fi
outq 'DIE:.*40134888669' && ok "...and the message names the campaign this prevents, not just a return code" \
  || no "the failure message names the incident" "$(command grep -a DIE: "$T/out" | head -1)"

# ---- 3. the REFUTATION arm failing is just as fatal -------------------------------------------
# If the binder answers ok with nothing attached, every later PASS is void - that is worse than a
# refusal, and it must not be the one arm whose failure is tolerated.
rc=$(run "1,0")
if [ "$rc" = 1 ] && ! outq 'REACHED-THE-MATRIX'; then ok "the REFUTATION arm failing also stops the campaign - a receipt that is not about the volume voids every later PASS"
else no "a failing refutation arm stops the campaign" "rc=$rc arms='$(arms)'"; fi
case "$(arms)" in "--no-attach "*ATTACH*) no "it stops at the first failure" "arms='$(arms)' - the second arm ran after the first had failed" ;;
  *) ok "and it stops at that first failure rather than running the rest" ;; esac

# ---- 4. rc 2 is the RIG, not the bind ---------------------------------------------------------
rc=$(run "2,0")
if [ "$rc" = 1 ] && outq 'DIE:.*INVALID-RIG'; then ok "rc=2 is reported as INVALID-RIG - the rig could not measure, which is a different finding from a bind that refused"
else no "rc=2 is INVALID-RIG" "rc=$rc $(command grep -a DIE: "$T/out" | head -1)"; fi

# ---- 5. the artefacts stay OUT of the *.out glob ----------------------------------------------
# record-acceptance.sh globs $CAMP/*.out and requires a MATRIX footer in each; a footerless .out
# from this cell would make the whole campaign unrecordable.
rc=$(run "0,0")
_bad=$(ls "$T/c/campaign"/*.out 2>/dev/null | head -1)
[ -z "$_bad" ] && ok "the smoke cell writes no *.out into the campaign dir - record-acceptance's glob is untouched" \
                || no "the smoke cell stays out of the *.out glob" "found $_bad, which has no MATRIX footer and would make the campaign unrecordable"
[ -d "$T/c/campaign/logvol-smoke-bind" ] && [ -d "$T/c/campaign/logvol-smoke-refutation" ] \
  && ok "each arm gets its OWN artefact dir - one cannot overwrite the other's receipts" \
  || no "each arm has its own artefact dir" "$(ls "$T/c/campaign" 2>/dev/null | tr '\n' ' ')"

# ---- 6. IT CANNOT BE SWITCHED OFF -------------------------------------------------------------
# The first cut carried a LOGVOL_SMOKE=0 escape. Jev scored that knob 0.50 - no endorsement - and the
# standing rule here is to ask before adding a guard knob at all. The one thing an off switch
# guarantees is that the run which most needed the gate is the run that skipped it, so the property
# is now that setting it changes NOTHING: both arms still run.
rc=$(run "0,0" 0)
if [ "$rc" = 0 ] && [ -n "$(arms)" ] && ! outq 'SKIPPED'; then
  ok "LOGVOL_SMOKE=0 in the environment changes nothing - there is no knob, and both arms still run ($(arms))"
else no "the cell cannot be switched off" "rc=$rc arms='$(arms)' out=$(tr '\n' ' ' < "$T/out")"; fi

echo
echo "accept-logvol-smoke-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
