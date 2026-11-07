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
# THE ONE THING IT DOES BETWEEN THEM IS SETTLE THE RIG. release-acceptance.sh settles the rig before
# each feature test and after none, and gate-remainder's first suite refuses a second running guest by
# design (serial-rig.sh: "stopping the other guest is a decision, not a default"). MEASURED 2026-10-31
# 20:27:21Z, remainder-32dc22690186: supervision-e2e left win11r-sup Running, gate-remainder said
# "REFUSING: another Windows guest is up - win11r-sup(Running)" and the chain ended six suites short -
# the same way it had on 2026-10-30. So the decision is taken HERE, once, by the only script that
# knows both steps: the running guests come from the primitive the refusal itself reads (admin.vm.List,
# one call - never qvm-ls, 2026-10-09) and each is asked down through qwt_shutdown's bounded wait, the
# helper release-acceptance's own settle uses. A guest that does not halt is NOT killed: it is the
# specimen of whatever stopped it, and the chain stops and says so.
#
# Exit: 2 usage or a refusal before any guest was touched · the preflight's own code (11/12/13/14)
#       · else the first non-zero of the steps that ran, and the verdict is printed whatever happens.
set -uo pipefail
# TEARDOWN FIRST, $0-RELATIVE, ABOVE THE cd. Without job_init this script had NO trap at all - the
# exact ACCEPTCANCELORPHAN defect tools/release-acceptance.sh root-caused on 2026-10-21 and fixed,
# and I shipped it again one level up. MEASURED 2026-10-22: TERMing this leader killed it and left
# release-acceptance.sh, updater-component-test.sh and quick-upgrade.sh running on a live guest, so
# the abort had to be finished by walking /proc from the recorded pid. _rl_teardown kills the
# descendant tree by explicit pid - never a pattern, never a process-group sweep.
. "$(dirname "${BASH_SOURCE[0]}")/run-lib.sh" || {
  echo "FATAL: cannot load run-lib.sh - without it a cancel leaves the campaign running" >&2; exit 2; }
job_init "campaign-full"
# shutdown-lib: the bounded settle between step 2 and step 3. serial-rig: the rig read gate-remainder's
# own refusal uses, so this script sees exactly what the remainder would refuse on.
. "$(dirname "${BASH_SOURCE[0]}")/shutdown-lib.sh" || {
  echo "FATAL: cannot load shutdown-lib.sh - nothing bounded can settle the rig between step 2 and step 3" >&2; exit 2; }
. "$(dirname "${BASH_SOURCE[0]}")/serial-rig.sh" || {
  echo "FATAL: cannot load serial-rig.sh - the rig cannot be read the way gate-remainder reads it" >&2; exit 2; }
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2

DRY="${DRY:-}"
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
HEAD_SHA="$(git rev-parse HEAD)"
SHORT="${HEAD_SHA:0:12}"
# The remainder's three targets. REQUIRED by gate-remainder (lint L10 - no default targets inside a
# harness), so they are named HERE, in one place, exactly as campaign-run.sh names the entry images.
: "${VM10:=win10-acc}" "${VM11:=win11-acc}" "${OS11:=win11r}"
OUT="${OUT:-$HOME/qwt-accept/campaign-full-$SHORT}"
# A contaminated subject is refused BEFORE any work: this script's default output dir carries no
# run-id, so a second attempt would otherwise append to the first attempt's artefacts and be read
# back as one run. Pass a fresh outdir to run again.
declare -F attempt_dir >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/primitives.sh"
attempt_dir "$OUT" || exit 1

mkdir -p "$OUT" || exit 2
log(){ printf '%s campaign-full[%s] %s\n' "$(date -u '+%H:%M:%S')" "$SHORT" "$*" | tee -a "$OUT/chain.log"; }
die(){ log "REFUSED: $*"; exit 2; }

# ---- THE RIG SETTLE, ONE DEFINITION, CALLED AT BOTH STEP BOUNDARIES -----------------------------
# This used to be inline at step 2b only - before step 3, because step 2 leaves its last feature
# test's guest up and gate-remainder refuses ANY running guest. MEASURED 2026-11-06T21:58:11Z,
# campaign-full-bb29d23b: it refused 15 SECONDS into step 2 instead, because step 2's OWN first
# suite takes the rig too. win11r-up had been left Running on purpose as the short cycle's specimen;
# campaign-preflight passed it (its check is "no SUBJECT guest is running", and win11r-up is not a
# subject of this campaign), and then the logvol smoke's vm_lock hit assert_sole_guest and the chain
# ended with no cell spent. The header above already says this decision is taken HERE, once, by the
# only script that knows both steps - it knew about step 3's boundary and not about step 2's.
# release-acceptance.sh does own a settle_rig(), but it is defined INSIDE its `if SKIP_FEATURES`
# block, after the smoke and after the matrix, and its body needs wedge-gates-lib.sh which is sourced
# later still - so the fix belongs here, at the boundary, not in a hoist of that function.
# Jev settle_placement=orchestrator_before_step_2 0.94.
# NOTHING HERE KILLS: a guest that will not halt within 600 s is the specimen of whatever stopped
# it, and the chain ends saying so. Returns 1 so the caller owns the exit code.
settle_the_rig(){
  local when="${1:?settle_the_rig <when> <who-refuses>}" refuser="${2:?}" left lrc unsettled="" g vm src
  log "settle the rig before $when"
  left=$(_sr_running_guests ""); lrc=$?   # not through a pipe - the status is the rig-read signal (serial-rig.sh)
  if [ "$lrc" = 2 ]; then
    log "STOP: the rig could not be read (admin.vm.List returned nothing) - whether a guest is up is UNKNOWN, and $refuser refuses on no information too"
    return 1
  fi
  for g in $left; do                      # entries: name(State) or name(State,tag-lookup-TIMED-OUT), space-separated
    vm="${g%%(*}"
    log "  $g is up before $when - qwt_shutdown $vm 600"
    qwt_shutdown "$vm" 600 >>"$OUT/settle.out" 2>&1; src=$?
    log "  qwt_shutdown $vm rc=$src (0 halted; anything else: see $OUT/settle.out - the guest is left UP, nothing here kills)"
    [ "$src" = 0 ] || unsettled="$unsettled $vm"
  done
  if [ -n "$unsettled" ]; then
    log "STOP: not halted within 600 s:$unsettled - the specimen of whatever stopped it; $refuser would refuse it, so the chain ends here"
    return 1
  fi
  [ -n "${left// /}" ] || log "  no testbed guest is up"
  return 0
}

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
# A RUN THAT HAS NOT FINISHED IS NOT A RED. ci-state.py's own contract is "rc 2 one is still
# running, or gh could not be read: no verdict yet, never a pass", and it prints every unfinished
# required run with its id. This loop read only the TRUTHINESS of that exit and then asserted "a
# required workflow is RED" - a false statement about an inconclusive instrument, on the one gate
# that decides whether four hours of rig time start. MEASURED 2026-11-07T00:18:47+02:00: the commit
# that fixed the step-2 settle touches mgmt/, which is a trigger path of test.yml, so pushing it
# started test.yml and build.yml for the new sha; the campaign was launched two minutes later and
# refused in 15 seconds naming a RED that did not exist. Waiting is already what this loop does for
# a workflow it dispatches, so it waits here too - on exactly the runs ci-state names, and ONLY
# when it can name them: rc 2 also covers "gh could not be read", and with no id to wait on this
# falls through to the refusal below rather than block on nothing.
_wait_run(){ # <label> <run-id>: block until that run is completed, then log its final status
  local what="$1" rid="$2" st
  while :; do
    st=$(gh run view "$rid" --json status,conclusion --jq '"\(.status)|\(.conclusion)"' 2>/dev/null)
    case "$st" in completed*) log "  $what ($rid): $st"; return 0 ;; *) sleep 45 ;; esac
  done
}
ci_ok(){ python3 tools/ci-state.py "$SHORT" > "$OUT/ci-state.txt" 2>&1; }
for round in 1 2 3; do
  ci_ok; circ=$?
  if [ "$circ" = 0 ]; then log "CI is green for $SHORT"; break; fi
  [ "$round" = 3 ] && { sed -n '1,12p' "$OUT/ci-state.txt" | sed 's/^/    /' | tee -a "$OUT/chain.log"; die "CI is still not green for $SHORT after dispatching and waiting for what ci-state named"; }
  # ---- CIINFLIGHT-BEGIN
  if [ "$circ" = 2 ]; then
    # the required rows ci-state marked "run " (queued/in_progress/waiting), by run id
    mapfile -t inflight < <(grep -aE '^[[:space:]]*run[[:space:]]' "$OUT/ci-state.txt" \
                            | grep -a '(required)' | grep -aoE '[0-9]{8,}')
    if [ "${#inflight[@]}" -gt 0 ]; then
      log "CI for $SHORT has ${#inflight[@]} required run(s) still IN FLIGHT - ci-state says 'no verdict yet', which is not a red; waiting for them"
      [ -n "$DRY" ] && { log "DRY: not waiting on CI"; break; }
      for rid in "${inflight[@]}"; do _wait_run "in-flight required run" "$rid"; done
      continue
    fi
    log "ci-state exited 2 but named no in-flight required run - treating it as unreadable, not as waiting"
  fi
  # ---- CIINFLIGHT-END
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
    _wait_run "$wf" "$rid"
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
  log "  2a. settle the rig: qwt_shutdown <each running testbed guest> 600 - step 2's own first suite takes the rig"
  log "  2. PKG=$PKG mgmt/harness/campaign-full.sh's inner campaign-run.sh (preflight -> release-acceptance -> campaign-state)"
  log "  2b. settle the rig again: step 2 leaves its last feature test's guest up - the guests read as serial-rig.sh reads them (admin.vm.List)"
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

# ---- 4b. settle the rig BEFORE step 2 - its first suite takes the rig too ------------------------
# Placed after package-verify on purpose: a package that does not verify must not cost the operator
# a running guest. The preflight inside step 2 will NOT catch this - it asks whether a SUBJECT guest
# is running, and the guest that refused us was not a subject.
log "step 2a/4: settle the rig before the cells"
settle_the_rig "step 2 (its logvol smoke clones and boots a golden)" "the logvol smoke" || exit 1

# ---- 5. the cells and the feature tests (preflight decides whether to start) ----------------------
log "step 2/4: campaign-run (preflight -> release-acceptance -> verdict)"
PKG="$PKG" mgmt/harness/campaign-run.sh 2>&1 | tee -a "$OUT/campaign-run.out"
crc=${PIPESTATUS[0]}
log "  campaign-run rc=$crc"
case "$crc" in 11|12|13|14) log "STOP: the preflight refused with $crc - no guest was touched"; exit "$crc" ;; esac
# ---- MATRIXABORT-BEGIN  (driven by tools/tests/campaign-full-selftest.sh)
# AN ABORTED OR INCOMPLETE MATRIX STOPS THE CHAIN. MEASURED 2026-10-22: the matrix printed
# "=== MATRIX: 75 passed, 6 failed - ABORTED on a log path that broke mid-cell ===" at 13:38, having
# wedged a guest in WIN11-upgrade - and this chain walked straight into the feature tests on a rig
# whose subject had just been hard-killed, then would have spent gate-remainder on it. The operator
# had to stop it. Two mechanical reasons to halt, neither a judgement:
#   * the matrix said ABORTED - whatever follows is running on a rig it did not finish with;
#   * a cell in acceptance-record-check.py's REQUIRED set produced no report.json, so the record is
#     already unsatisfiable and gate-remainder cannot rescue it.
if grep -aqE '=== MATRIX: .* ABORTED' "$OUT/campaign-run.out" 2>/dev/null; then
  log "STOP: the matrix ABORTED - $(grep -aoE '=== MATRIX:[^=]*' "$OUT/campaign-run.out" | tail -1)"
  log "      the remainder suites and the receipt check are NOT run on an unfinished matrix"
  python3 tools/campaign-state.py 2>&1 | tail -20 | tee -a "$OUT/chain.log"
  exit "${crc:-1}"
fi
missing=$(python3 - <<'PYMISS' 2>/dev/null
import glob, json, os, re, sys
here = os.path.join(os.getcwd(), "tools")
feats = [l.strip() for l in open(os.path.join(here, "release-feature-tests.txt")) if l.strip() and not l.startswith("#")]
required = {"win11-clean","win10-clean","win11-upgrade","win11-reinstall","win11-appvm","win10-appvm"}
camps = sorted(glob.glob(os.path.expanduser("~/qwt-accept/*/campaign")), key=os.path.getmtime)
got = set()
if camps:
    for d in glob.glob(os.path.join(camps[-1], "matrix", "*-guestlogs")):
        if os.path.exists(os.path.join(d, "report.json")):
            got.add(os.path.basename(d)[:-len("-guestlogs")])
print(" ".join(sorted(required - got)))
PYMISS
)
if [ -n "$missing" ]; then
  log "STOP: these REQUIRED cells produced no report: $missing"
  log "      the acceptance record cannot be satisfied, so gate-remainder would spend rig time on an unusable receipt"
  python3 tools/campaign-state.py 2>&1 | tail -20 | tee -a "$OUT/chain.log"
  exit "${crc:-1}"
fi
# ---- MATRIXABORT-END

# ---- 5b. settle the rig: step 2 leaves its last feature test's guest up, step 3 refuses ANY guest ----
log "step 2b/4: settle the rig before the remainder"
settle_the_rig "step 3 (gate-remainder refuses ANY running guest)" "gate-remainder" || exit 1

# ---- 6. the six suites release-acceptance does not cover ------------------------------------------
log "step 3/4: gate-remainder (--fi-run $FI)"
tools/gate-remainder.sh --run "$PKG" --vm10 "$VM10" --vm11 "$VM11" --os11 "$OS11" --fi-run "$FI" \
  > "$OUT/gate-remainder.out" 2>&1; grc=$?
# QUOTE THE SET, NOT THE LAST LINE. MEASURED 2026-11-07 at a3dfdd79a00a: FOUR suites did not pass
# - the remainder's own log says `failed: toast-hold-test log-sweep failproof-gates
# failproof-faultinject` - and this line reported ONE of them, because it took `tail -1` of every
# line matching PASS|FAIL|merged and the last such line is simply the last suite to fail. An
# operator reading the chain log saw a quarter of the result. The remainder prints its own
# authoritative roll-up as `passed:`/`failed:`/`uncovered:`/`skipped:`, lower-case, which that
# pattern never matched; quote those, because they are the summary the gate itself computed.
log "  gate-remainder rc=$grc: $(grep -aE '\] (passed|failed|uncovered|skipped):' "$OUT/gate-remainder.out" 2>/dev/null \
      | sed 's/^\[[0-9:]*\] //' | tr '\n' ' ' | cut -c1-300)"

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
