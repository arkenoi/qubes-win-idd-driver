#!/bin/bash
# campaign-full.sh - FULL acceptance, end to end, as ONE command that owns no judgement of its own.
#
#   mgmt/harness/campaign-full.sh            # resolves everything from HEAD
#   DRY=1 mgmt/harness/campaign-full.sh      # resolve, check and print the chain; touch no guest
#
# WHY THIS EXISTS (owner, 2026-10-22: "run full acceptance when build is green. make sure everything
# is mechanized first"). tools/acceptance-plan.py plans THREE cells and mgmt/harness/campaign-run.sh
# mechanises only the middle one. On 2026-10-22 I therefore ran the other two by hand, and both hand
# steps went wrong in a way that would have read as success:
#
#   * WHICH PACKAGE IS WHICH. A full gate needs TWO release-package runs at the same commit - the
#     ordinary one and a fault_injection one, because failproof-gates and failproof-faultinject
#     cannot run on an ordinary package. Both runs are called "release-package" and their display
#     titles are IDENTICAL, so I reached for dispatch order. Then my first discriminator (a grep for
#     QGAFAULT in reference/gui-agent.exe) returned 0 on BOTH, which reads as "the flag did nothing".
#     The workflow names the real check itself and carries the scar: `inputs.fault_injection == true`
#     was always false because a dispatch input arrives as a STRING, so the build prints
#     QGA_FAULT_INJECTION=0/1 and that is the only thing that settles it. Proven here, never ordered.
#   * REQUIRED CI THAT CANNOT RUN ON THIS BRANCH. campaign-preflight refuses with 14 unless every
#     required workflow is green for the sha. build.yml and test.yml run on push to MAIN only, so on
#     a feature branch they are "DUE for this sha (its paths matched) but branch-filtered" and
#     tools/ci-state.py says in those words to dispatch them. I did that by hand, twice.
#
# IT COMPOSES, IT DOES NOT DECIDE. acceptance-plan.py plans; ci-state.py says what CI owes;
# verify-release-package.sh verifies the tree; campaign-preflight.sh decides whether to start;
# release-acceptance.sh runs the cells and the feature tests; gate-remainder.sh runs the six it does
# not cover and merges the receipt; gate-scope.py check refuses a receipt that misses a required
# suite; campaign-state.py reads the verdict from report.json artifacts, never from log prose.
#
# Exit: 2 usage or a refusal before any guest was touched · the preflight's own code (11/12/13/14)
#       · else the first non-zero of the steps that ran, and the verdict is printed whatever happens.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2

DRY="${DRY:-}"
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
HEAD_SHA="$(git rev-parse HEAD)"
SHORT="${HEAD_SHA:0:12}"
# The remainder's three targets. REQUIRED by gate-remainder (lint L10 - no default targets inside a
# harness), so they are named HERE, in one place, exactly as campaign-run.sh names the entry images.
: "${VM10:=win10-acc}" "${VM11:=win11-acc}" "${OS11:=win11r}"
OUT="${OUT:-$HOME/qwt-accept/campaign-full-$SHORT}"
mkdir -p "$OUT" || exit 2
log(){ printf '%s campaign-full[%s] %s\n' "$(date -u '+%H:%M:%S')" "$SHORT" "$*" | tee -a "$OUT/chain.log"; }
die(){ log "REFUSED: $*"; exit 2; }

log "head $HEAD_SHA on $BRANCH; evidence in $OUT"

# ---- 1. the two packages, PROVEN -----------------------------------------------------------------
# A run is the FI build iff its own log printed QGA_FAULT_INJECTION=1. Nothing else is accepted:
# not dispatch order, not the display title (identical), not a grep of the shipped binary.
# ---- PKGROLES-BEGIN  (driven by tools/tests/campaign-full-selftest.sh)
# PKG/FI may be NAMED by the operator, and are then PROVEN exactly as discovered ones are - a named
# pair is not a trusted pair. This exists because the package's commit and HEAD legitimately differ:
# campaign-preflight.sh's own rule is "built from <sha>, carries every fix under test, NO PRODUCT
# DRIFT since", so a harness-only commit after the build does not invalidate the package, and
# rebuilding twice for it would cost 20 minutes to prove nothing. That judgement belongs to the
# preflight; this script only proves which run is which, and refuses to GUESS a pair from an older
# sha - if HEAD has none it names the newest proven pair for the operator to pass deliberately.
resolve_pkgs(){
  local ids id v
  if [ -n "${PKG:-}" ] && [ -n "${FI:-}" ]; then
    for id in "$PKG" "$FI"; do
      v=$(gh run view "$id" --log 2>/dev/null | grep -aoE 'QGA_FAULT_INJECTION=[01]' | sort -u | tail -1)
      case "$id:$v" in
        "$PKG:QGA_FAULT_INJECTION=0") log "  named run $PKG verified as the ORDINARY package ($v)" ;;
        "$FI:QGA_FAULT_INJECTION=1")  log "  named run $FI verified as the FAULT-INJECTION package ($v)" ;;
        *) die "named run $id does not prove its role: its log says '${v:-nothing about injection}' - PKG must print QGA_FAULT_INJECTION=0 and FI must print =1" ;;
      esac
    done
    return 0
  fi
  ids=$(gh run list --branch "$BRANCH" --workflow=release-package.yml --limit 12 \
        --json databaseId,headSha,status,conclusion \
        --jq ".[] | select(.headSha==\"$HEAD_SHA\" and .status==\"completed\" and .conclusion==\"success\") | .databaseId" 2>/dev/null)
  [ -n "$ids" ] || die "no successful release-package run at $SHORT - dispatch it (gh workflow run release-package.yml --ref $BRANCH), and a second one with -f fault_injection=true"
  PKG=""; FI=""
  for id in $ids; do
    v=$(gh run view "$id" --log 2>/dev/null | grep -aoE 'QGA_FAULT_INJECTION=[01]' | sort -u | tail -1)
    case "$v" in
      QGA_FAULT_INJECTION=0) [ -n "$PKG" ] || PKG="$id"; log "  run $id is the ORDINARY package (its log says $v)" ;;
      QGA_FAULT_INJECTION=1) [ -n "$FI"  ] || FI="$id";  log "  run $id is the FAULT-INJECTION package (its log says $v)" ;;
      *) log "  run $id: its log does not state QGA_FAULT_INJECTION - NOT used for either role" ;;
    esac
  done
  [ -n "$PKG" ] || die "no run at $SHORT proved itself the ordinary package (QGA_FAULT_INJECTION=0)"
  [ -n "$FI" ]  || die "no run at $SHORT proved itself the fault-injection package (QGA_FAULT_INJECTION=1) - failproof-gates and failproof-faultinject cannot run on an ordinary package, so a FULL gate is unreachable without it; dispatch release-package.yml with -f fault_injection=true"
}
# ---- PKGROLES-END
resolve_pkgs
# THE PACKAGE IS VERIFIED AGAINST ITS OWN COMMIT, taken from the RUN - not from HEAD and not from
# the tree's own MANIFEST. Measured in this chain's first dry run: it printed
# `verify-release-package.sh --commit <HEAD>` for a tree built from an earlier commit, which would
# have failed a perfectly good package. HEAD and the package's commit differ legitimately whenever a
# harness-only commit follows the build; campaign-preflight owns "no product drift since". Reading
# the sha from the run rather than from MANIFEST.json keeps the check non-circular: the tree must
# match something stated outside it.
PKG_SHA=$(gh run view "$PKG" --json headSha --jq .headSha 2>/dev/null)
[ -n "$PKG_SHA" ] || die "could not read the head sha of run $PKG - the package cannot be verified against an unknown commit"
log "packages: ordinary=$PKG (built from ${PKG_SHA:0:12}) fault-injection=$FI"
# ---- PKGDRIFT-BEGIN  (driven by tools/tests/campaign-full-selftest.sh)
if [ "$PKG_SHA" != "$HEAD_SHA" ]; then
  drift=$(git diff --name-only "$PKG_SHA..$HEAD_SHA" -- agent guest packaging driver tools/notifhost 2>/dev/null)
  if [ -n "$drift" ]; then
    log "PRODUCT PATHS changed since the package was built:"; printf '    %s\n' $drift | tee -a "$OUT/chain.log"
    die "the package at ${PKG_SHA:0:12} does not carry HEAD's product changes - rebuild release-package (and the fault_injection variant) at $SHORT"
  fi
  log "  HEAD is ${SHORT} but no PRODUCT path changed since ${PKG_SHA:0:12} - the package is still the thing under test (campaign-preflight re-checks this)"
fi
# ---- PKGDRIFT-END

# ---- 2. required CI, green for THIS sha ----------------------------------------------------------
# ci-state.py names any required workflow that is due but branch-filtered, in those words. Dispatch
# exactly those, wait, and re-ask - up to twice, because a third round means something else is wrong.
ci_ok(){ python3 tools/ci-state.py "$SHORT" > "$OUT/ci-state.txt" 2>&1; }
for round in 1 2 3; do
  if ci_ok; then log "CI is green for $SHORT"; break; fi
  [ "$round" = 3 ] && { sed -n '1,12p' "$OUT/ci-state.txt" | sed 's/^/    /' | tee -a "$OUT/chain.log"; die "CI is still not green for $SHORT after dispatching what ci-state named"; }
  # ---- CIDUE-BEGIN  (driven by tools/tests/campaign-full-selftest.sh)
  mapfile -t due < <(grep -aE 'REQUIRED, its paths matched, and it cannot run on this branch' "$OUT/ci-state.txt" \
                     | grep -aoE '^[[:space:]]*MISS[[:space:]]+[a-z0-9.-]+\.yml' | awk '{print $2}')
  # ---- CIDUE-END
  [ "${#due[@]}" -gt 0 ] || { sed -n '1,12p' "$OUT/ci-state.txt" | sed 's/^/    /' | tee -a "$OUT/chain.log"; die "CI is not green for $SHORT and nothing is merely branch-filtered - a required workflow is RED"; }
  for wf in "${due[@]}"; do
    log "required but branch-filtered: $wf - dispatching it for this sha"
    [ -n "$DRY" ] && continue
    gh workflow run "$wf" --ref "$BRANCH" >/dev/null 2>&1 || die "could not dispatch $wf"
  done
  [ -n "$DRY" ] && { log "DRY: not waiting on CI"; break; }
  log "waiting for the dispatched workflow(s) to finish"
  for wf in "${due[@]}"; do
    sleep 10
    rid=$(gh run list --branch "$BRANCH" --workflow="$wf" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
    while :; do
      st=$(gh run view "$rid" --json status,conclusion --jq '"\(.status)|\(.conclusion)"' 2>/dev/null)
      case "$st" in completed*) log "  $wf ($rid): $st"; break ;; *) sleep 45 ;; esac
    done
  done
done

# ---- 3. the plan must say FULL and name these three cells ----------------------------------------
python3 tools/acceptance-plan.py --package-run "$PKG" --g10 win10-iqi --g11 win11-iqi \
        --b10 win10-base --b11 win11r-base --f11 "$OS11" \
        --vm10 "$VM10" --vm11 "$VM11" --os11 "$OS11" --fi-run "$FI" \
        --out "$OUT/plan.json" > "$OUT/plan.txt" 2>&1 || die "acceptance-plan refused to write a plan - see $OUT/plan.txt"
sed -n '1,6p' "$OUT/plan.txt" | sed 's/^/    /' | tee -a "$OUT/chain.log" >/dev/null
ready=$(python3 -c "import json;print(json.load(open('$OUT/plan.json'))['ready'])" 2>/dev/null)
nsuite=$(python3 -c "import json;print(len(json.load(open('$OUT/plan.json'))['gate']['required']))" 2>/dev/null)
log "plan: ready=$ready, $nsuite suite(s) required"
[ "$ready" = True ] || die "the plan is not ready: $(python3 -c "import json;print('; '.join(json.load(open('$OUT/plan.json'))['blocked']))" 2>/dev/null)"

if [ -n "$DRY" ]; then
  log "DRY: the chain would now run, in order:"
  log "  1. tools/verify-release-package.sh --tree <$PKG setup> --commit $PKG_SHA  (the PACKAGE's commit)"
  log "  2. PKG=$PKG mgmt/harness/campaign-full.sh's inner campaign-run.sh (preflight -> release-acceptance -> campaign-state)"
  log "  3. tools/gate-remainder.sh --run $PKG --vm10 $VM10 --vm11 $VM11 --os11 $OS11 --fi-run $FI"
  log "  4. tools/gate-scope.py check <receipt>"
  exit 0
fi

# ---- 4. package-verify (the plan's first cell) ---------------------------------------------------
TREE="$OUT/setup"
if [ ! -s "$TREE/MANIFEST.json" ]; then
  rm -rf "$TREE"; mkdir -p "$TREE"
  gh run download "$PKG" -n qwt-improved-setup -D "$TREE" >/dev/null 2>&1 \
    || die "could not download the setup tree from run $PKG"
fi
log "step 1/4: package-verify"
bash tools/verify-release-package.sh --tree "$TREE" --commit "$PKG_SHA" > "$OUT/package-verify.out" 2>&1; vrc=$?
log "  package-verify rc=$vrc: $(tail -1 "$OUT/package-verify.out" | cut -c1-140)"
[ "$vrc" = 0 ] || { log "STOP: the package does not verify - nothing downstream would be meaningful"; exit "$vrc"; }

# ---- 5. the cells and the feature tests (preflight decides whether to start) ----------------------
log "step 2/4: campaign-run (preflight -> release-acceptance -> verdict)"
PKG="$PKG" mgmt/harness/campaign-run.sh 2>&1 | tee -a "$OUT/campaign-run.out"
crc=${PIPESTATUS[0]}
log "  campaign-run rc=$crc"
case "$crc" in 11|12|13|14) log "STOP: the preflight refused with $crc - no guest was touched"; exit "$crc" ;; esac

# ---- 6. the six suites release-acceptance does not cover ------------------------------------------
log "step 3/4: gate-remainder (--fi-run $FI)"
tools/gate-remainder.sh --run "$PKG" --vm10 "$VM10" --vm11 "$VM11" --os11 "$OS11" --fi-run "$FI" \
  > "$OUT/gate-remainder.out" 2>&1; grc=$?
log "  gate-remainder rc=$grc: $(grep -aE 'PASS|FAIL|merged' "$OUT/gate-remainder.out" | tail -1 | cut -c1-140)"

# ---- 7. the receipt must satisfy its own floor ---------------------------------------------------
log "step 4/4: does the receipt cover what the gate requires?"
RECEIPT=$(ls -t scratchpad/gate-coverage-*.json 2>/dev/null | head -1)
if [ -n "$RECEIPT" ]; then
  python3 tools/gate-scope.py check "$RECEIPT" > "$OUT/gate-check.out" 2>&1; srd=$?
  log "  gate-scope check rc=$srd: $(tail -1 "$OUT/gate-check.out" | cut -c1-150)"
else
  log "  [WARN] no scratchpad/gate-coverage-*.json receipt to check"; srd=2
fi

log "VERDICT, from the artifacts:"
python3 tools/campaign-state.py 2>&1 | tail -20 | tee -a "$OUT/chain.log"
for rc in "$crc" "$grc" "$srd"; do [ "$rc" != 0 ] && exit "$rc"; done
log "FULL ACCEPTANCE COMPLETE: every step passed and the receipt satisfies the gate"
exit 0
