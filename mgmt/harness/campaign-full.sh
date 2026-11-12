#!/bin/bash
# campaign-full.sh - FULL acceptance, end to end, as ONE command that owns no judgement of its own.
#
#   BUILD=build-4.3.41.1266 FI=<fi-run> mgmt/harness/campaign-full.sh   # the build tag names the package
#   PKG=<release-package run> FI=<fi-run> mgmt/harness/campaign-full.sh  # the run; its build tag is created first
#   DRY=1 BUILD=... FI=... mgmt/harness/campaign-full.sh                 # resolve, check and print the chain; touch no guest
#
# THE BUILD IS NAMED, NEVER DISCOVERED FROM HEAD. Owner, 2026-11-11: «we are not accepting "head", we
# accept a precise build»; «i asked you to use fucking tags, you made tags and now you do not use it!».
# Until this date this script "resolved everything from HEAD": it listed the successful release-package
# runs whose head was HEAD and refused when there were none, so a documentation commit after the build
# demanded a 20-minute rebuild to prove nothing, and the receipt it checked at the end was the newest
# gate-coverage-*.json by mtime. tools/build-tag.sh creates build-<version>.<run number> for the named
# run BEFORE ANY SUITE (verified: release-package, success, QGA_FAULT_INJECTION=0 in the run's own log,
# head on origin/main), every receipt is named by that tag, and the harness commit appears only as the
# provenance of each verdict (docs/ADR-acceptance.md section 7).
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
#     QGA_FAULT_INJECTION=0/1 and that is the only thing that settles it. Proven, never ordered - by
#     tools/build-tag.sh (create proves =0 for the package; fi-flag proves =1 for FI), one copy.
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
BRANCH="${BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"   # where a branch-filtered CI workflow is dispatched; never an identity
# ---- THE BUILD, NAMED (see the header) ------------------------------------------------------------
# BUILD=<tag> names the build; PKG=<run> names the run and is turned into its tag. tools/build-tag.sh
# create is idempotent: for a tag that exists it re-verifies that it points at the run's head and names
# that run, and refuses otherwise. Both routes end in the same tag, the same build commit, and the same
# receipt. These refusals print to stderr: OUT and log() do not exist until the build is known.
if [ -n "${BUILD:-}" ]; then
  PKG=$(tools/build-tag.sh run "$BUILD") || { echo "REFUSED: $BUILD is not a build tag this repo holds" >&2; exit 2; }
fi
[ -n "${PKG:-}" ] || { echo "REFUSED: name the build - BUILD=<build tag> or PKG=<release-package run id>, with FI=<fault-injection run id>" >&2; exit 2; }
BUILDTAG=$(tools/build-tag.sh create "$PKG") || { echo "REFUSED: run $PKG has no build tag - tools/build-tag.sh refused, above" >&2; exit 2; }
[ -z "${BUILD:-}" ] || [ "$BUILD" = "$BUILDTAG" ] || { echo "REFUSED: BUILD=$BUILD, but run $PKG's build tag is $BUILDTAG" >&2; exit 2; }
PKG_SHA=$(git rev-parse --verify --quiet "refs/tags/${BUILDTAG}^{commit}") || exit 2
SHORT="${PKG_SHA:0:12}"   # the BUILD commit, short - every "for $SHORT" below is about the build
# The remainder's three targets. REQUIRED by gate-remainder (lint L10 - no default targets inside a
# harness), so they are named HERE, in one place, exactly as campaign-run.sh names the entry images.
: "${VM10:=win10-acc}" "${VM11:=win11-acc}" "${OS11:=win11r}"
# A DRY run writes its plan and chain.log and marks its directory like any attempt, so in the real run's
# default it made the real run refuse itself: 2026-11-12, build-4.3.42.1278, the DRY at 20:59:47Z and the
# real run after it refused as a contaminated subject before any work. A DRY's default is its own.
[ -z "$DRY" ] || OUT="${OUT:-$HOME/qwt-accept/campaign-full-$BUILDTAG.dry-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT="${OUT:-$HOME/qwt-accept/campaign-full-$BUILDTAG}"
# A contaminated subject is refused BEFORE any work: this script's default output dir carries no
# run-id, so a second attempt would otherwise append to the first attempt's artefacts and be read
# back as one run. Pass a fresh outdir to run again.
declare -F attempt_dir >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/primitives.sh"
attempt_dir "$OUT" || exit 1

mkdir -p "$OUT" || exit 2
log(){ printf '%s campaign-full[%s] %s\n' "$(date -u '+%H:%M:%S')" "$BUILDTAG" "$*" | tee -a "$OUT/chain.log"; }
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

log "build $BUILDTAG (commit $PKG_SHA, run $PKG) on branch $BRANCH; harness $(git rev-parse HEAD 2>/dev/null | cut -c1-12); evidence in $OUT"

# ---- 1. the FI package, PROVEN -------------------------------------------------------------------
# A run is the FI build iff its own log printed QGA_FAULT_INJECTION=1. Nothing else is accepted: not
# dispatch order, not the display title (identical), not a grep of the shipped binary. The ordinary
# package was proven =0 by tools/build-tag.sh create above; the same tool reads the FI run's log here
# (ONE implementation of the proof: tools/build-tag.sh fi-flag). The FI run must have been built from
# the SAME commit as the build: failproof-gates and failproof-faultinject grade the injector build as
# a stand-in for the package, which holds only when both came from one commit.
[ -n "${FI:-}" ] || die "FI=<run id> is required: failproof-gates and failproof-faultinject cannot run on an ordinary package, so a FULL gate is unreachable without it - dispatch release-package.yml at $SHORT with -f fault_injection=true"
fiflag=$(tools/build-tag.sh fi-flag "$FI") || die "run $FI does not prove its role: its log does not state exactly one QGA_FAULT_INJECTION value - FI must print =1"
[ "$fiflag" = 1 ] || die "run $FI is not the FAULT-INJECTION package: its log reads QGA_FAULT_INJECTION=$fiflag, FI must print =1"
FI_SHA=$(gh run view "$FI" --json headSha --jq .headSha 2>/dev/null)
[ "$FI_SHA" = "$PKG_SHA" ] || die "the FI run $FI was built from ${FI_SHA:-<unreadable>}, not from the build's commit $PKG_SHA - its injector would stand in for a different package"
log "  run $FI verified as the FAULT-INJECTION package (QGA_FAULT_INJECTION=1) at ${FI_SHA:0:12}"
log "packages: ordinary=$PKG ($BUILDTAG, built from $SHORT) fault-injection=$FI"
# THE PACKAGE IS VERIFIED AGAINST ITS OWN COMMIT - the one the build tag points at - never HEAD.
# Measured in this chain's first dry run: it printed `verify-release-package.sh --commit <HEAD>` for a
# tree built from an earlier commit, which would have failed a perfectly good package.
# PRODUCT DRIFT between the build and this checkout is the PREFLIGHT's check (mgmt/harness/campaign-
# preflight.sh, PRODUCT_PATHS derived from release-package.yml's own trigger paths, refusal 13): it
# COMPARES, it does not identify. The hand-typed five-path list this script carried here until
# 2026-11-11 disagreed with the derived one (it lacked tools/wgcbroker and tools/qubesdb-read) and is gone.

# ---- 1b. THE INNER TREE MUST BE CLEAN, BEFORE THE CI WAIT ----------------------------------------
# MEASURED 2026-11-06/07: attempt 1 (21:58) died mid-smoke and left
# ~/qwt-accept/rel-42297190009/campaign/logvol-smoke-refutation/ATTEMPT-20261106T215811Z-803214 on
# disk. Attempt 3 was launched at 22:24 with a FRESH operator-chosen OUT, waited 42 MINUTES for two
# required CI runs (22:25:15 -> 23:07:24), verified the package, settled the rig, and was then refused
# 24 seconds into its first real step:
#     FATAL: logvol smoke (refutation arm) could not measure (INVALID-RIG, rc=2): contaminated
#            subject: .../campaign/logvol-smoke-refutation holds attempt 20261106T215811Z-803214
# on a file that had been sitting there since 21:58. A fresh OUT does not help: OUT is the
# ORCHESTRATOR's directory, while the tree the cells write into is keyed to the PACKAGE RUN
# (release-acceptance.sh: WORK="${WORK:-$HOME/qwt-accept/rel-$RUN}", CAMP="$WORK/campaign"), so every
# attempt against the same package shares it. The refusal is RIGHT and nothing here changes it; what
# was wrong is only the ORDER - the condition was already true, and one readdir away, before the wait.
#
# THE OWNER ORDERED THIS WIRED (2026-11-07, "wire that precondition too"), WHICH OVERRIDES A JEV
# VERDICT I had taken the other way: contaminated_tree=leave_it 0.77, precondition_in_the_chain 0.17,
# on the grounds that attempt_dir already refuses at the first point it owns and a second site knowing
# the same fact costs more than the 42 minutes. Recorded because the next reader deserves to know the
# verdict exists and was overruled deliberately, not missed.
#
# THIS NEVER DELETES. The archive move is printed for the operator to run, because attempt 1's
# logvol-smoke.log and smoke.log are the evidence of why it died - exactly what I preserved by hand
# with `mv campaign campaign-refused-<id>` rather than rm.
CAMPTREE="${WORK:-$HOME/qwt-accept/rel-$PKG}/campaign"
if [ -d "$CAMPTREE" ]; then
  # Any ATTEMPT-* under the tree belongs to a PREVIOUS attempt by construction: this run has not
  # reached a cell yet, so it has written none. Depth-agnostic on purpose - attempt_dir marks whatever
  # directory its caller owns (the smoke's arm today, another cell tomorrow).
  stale=$(find "$CAMPTREE" -name 'ATTEMPT-*' -printf '%P\n' 2>/dev/null | head -5)
  if [ -n "$stale" ]; then
    log "the inner campaign tree already holds a previous attempt's marker(s):"
    printf '    %s\n' $stale | tee -a "$OUT/chain.log"
    log "  this tree is keyed to the PACKAGE RUN ($PKG), not to OUT, so a fresh outdir does not clear it"
    log "  archive it (never delete - it holds why that attempt died), then re-run:"
    log "    mv $CAMPTREE $CAMPTREE-refused-\$(date -u +%Y%m%dT%H%M%SZ)"
    die "contaminated inner tree at $CAMPTREE - refused in a second rather than after the CI wait"
  fi
fi

# ---- 2. required CI, green for the BUILD commit --------------------------------------------------
# ci-state.py is asked about $SHORT, the build commit - not the checkout's HEAD. It names any required
# workflow that is due but branch-filtered, in those words. Dispatch exactly those, wait, and re-ask -
# up to twice, because a third round means something else is wrong. A dispatch runs at the BRANCH tip:
# that produces a run for the build commit only while the build is that tip, which is the case this
# loop exists for (a feature branch, built at its head). On main the push itself ran build.yml and
# test.yml for the build commit, and nothing is dispatched.
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
  mapfile -t due < <(grep -aE 'REQUIRED, its paths matched, and it cannot run on this branch' "$OUT/ci-state.txt" \
                     | grep -aoE '^[[:space:]]*MISS[[:space:]]+[a-z0-9.-]+\.yml' | awk '{print $2}')
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
  log "  4. tools/gate-scope.py check scratchpad/gate-coverage-$BUILDTAG.json <previous release>..$SHORT"
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
# INTERRUPTIBLY, OR A STOP NEVER ARRIVES. MEASURED 2026-11-11, build-4.3.41.1266: `kill -TERM` to this
# script at 14:51:58Z left it and its whole tree running - bash holds a trapped signal until the
# foreground command returns, this step was a foreground pipeline hours long, and so job_init's
# teardown was queued behind the very step it had to end; each level below had to be signalled by hand.
# rl_fg (run-lib.sh) waits on a background child instead, which a signal interrupts, so the trap tears
# the tree down at once. The tee stays INSIDE the background job, in this function: the trap runs with
# the redirections of the command it interrupted, so a tee on the rl_fg call itself is one the teardown
# kills and then writes its TORE DOWN line into - measured on that shape, the job died of SIGPIPE (141)
# with no TORE DOWN line. The function returns campaign-run.sh's own status, not tee's.
campaign_run_step(){ env PKG="$PKG" mgmt/harness/campaign-run.sh 2>&1 | tee -a "$OUT/campaign-run.out"; return "${PIPESTATUS[0]}"; }
rl_fg campaign_run_step
crc=$?
log "  campaign-run rc=$crc"
case "$crc" in 11|12|13|14) log "STOP: the preflight refused with $crc - no guest was touched"; exit "$crc" ;; esac
# AN INCOMPLETE MATRIX STOPS THE CHAIN: whatever follows would run on a rig the matrix did not finish
# with (a wedged or hard-killed subject), and gate-remainder would be spent on it. Two mechanical
# reasons to halt, neither a judgement:
#   * the matrix's own result does not say complete. tools/acceptance_json.py matrix-complete reads
#     $CAMPTREE/matrix/matrix-result.json, which the matrix writes from its exit trap: exit 0
#     complete, 1 not complete, 2 no readable result. Any non-zero stops - an abort, an exit before
#     the footer, a result still saying "running", and no file at all. A result found here is this
#     attempt's: step 1b refuses a tree that holds an earlier attempt's marker, and the inner run
#     moves an inherited result aside before its matrix;
#   * a cell in acceptance-record-check.py's REQUIRED set produced no report.json, so the record is
#     already unsatisfiable and gate-remainder cannot rescue it.
_mx_desc=$(python3 tools/acceptance_json.py matrix-complete "$CAMPTREE" 2>&1); _mx_rc=$?
if [ "$_mx_rc" -ne 0 ]; then
  log "STOP: the matrix did not complete (matrix-complete rc=$_mx_rc: 1 = its result says so, 2 = no readable result) - $_mx_desc"
  log "      the remainder suites and the receipt check are NOT run on an unfinished matrix"
  python3 tools/campaign-state.py "$CAMPTREE" 2>&1 | tail -30 | tee -a "$OUT/chain.log"
  # a STOP never exits 0: the inner run's own code when it has one, else 1
  [ "${crc:-0}" != 0 ] && exit "$crc"
  exit 1
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

# ---- 5b. settle the rig: step 2 leaves its last feature test's guest up, step 3 refuses ANY guest ----
log "step 2b/4: settle the rig before the remainder"
settle_the_rig "step 3 (gate-remainder refuses ANY running guest)" "gate-remainder" || exit 1

# ---- 6. the six suites release-acceptance does not cover ------------------------------------------
log "step 3/4: gate-remainder (--fi-run $FI)"
# Interruptibly too, for both reasons at step 2: this step runs for hours, and its redirection stays
# inside the background job, so the trap's own lines reach the chain's output rather than this file.
gate_remainder_step(){ tools/gate-remainder.sh --run "$PKG" --vm10 "$VM10" --vm11 "$VM11" --os11 "$OS11" --fi-run "$FI" > "$OUT/gate-remainder.out" 2>&1; }
rl_fg gate_remainder_step; grc=$?
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
# THE RECEIPT FOR THIS BUILD, BY NAME - not the newest gate-coverage-*.json by mtime, which until
# 2026-11-11 stood here and could be another build's. The range is the PACKAGE's (the newest release
# tag before the build commit, to it - what tools/cut-release.sh computes), passed explicitly so
# gate-scope never falls back to a range recorded inside the file.
log "step 4/4: does the receipt for $BUILDTAG cover what the gate requires?"
RECEIPT="scratchpad/gate-coverage-$BUILDTAG.json"
RBASE=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "${PKG_SHA}^" 2>/dev/null || git rev-list --max-parents=0 "$PKG_SHA" 2>/dev/null)
if [ -s "$RECEIPT" ] && [ -n "$RBASE" ]; then
  python3 tools/gate-scope.py check "$RECEIPT" "${RBASE}..${PKG_SHA}" > "$OUT/gate-check.out" 2>&1; srd=$?
  log "  gate-scope check rc=$srd: $(tail -1 "$OUT/gate-check.out" | cut -c1-150)"
else
  log "  [WARN] no receipt at $RECEIPT (or no release tag before $SHORT) - nothing to check"; srd=2
fi

log "VERDICT, from the artifacts:"
python3 tools/campaign-state.py 2>&1 | tail -20 | tee -a "$OUT/chain.log"
for rc in "$crc" "$grc" "$srd"; do [ "$rc" != 0 ] && exit "$rc"; done
log "FULL ACCEPTANCE COMPLETE: every step passed and the receipt satisfies the gate"
exit 0
