#!/bin/bash
# RELEASE ACCEPTANCE - one command from a green CI run to a recorded acceptance verdict.
#
# WHY THIS IS A SCRIPT. Every step below has been done by hand at least once, and the hand-run is
# where the mistakes came from: acceptance run against a different package than the one verified;
# a stale setup tree downloaded from the `build` workflow (overlay only) instead of
# `release-package`; a partial check accepted as full acceptance and a release cut on it (4.3.19,
# which the owner flagged). Mechanising it removes the chances to get those wrong.
#
# IT DOES NOT CUT THE RELEASE. It produces the acceptance record that tools/cut-release.sh
# REQUIRES; cutting stays a separate, deliberate act.
#
# Usage:
#   tools/release-acceptance.sh --run <release-package-run-id> [--cells "..."] [--skip-features]
#
# The run id must be a `release-package` workflow run: that is the only workflow that produces a
# full installable setup tree. `build` produces an overlay and is NOT a release package.
. "$(dirname "$0")/../mgmt/harness/shutdown-lib.sh"
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

RUN=""; SKIP_FEATURES=0
# The canonical full campaign, and it must be a SUPERSET of what tools/cut-release.sh requires:
#   win10-clean win10-appvm win11-clean win11-reinstall win11-upgrade win11-appvm
# This default used to omit win11-reinstall and win11-upgrade, so a campaign could report "51 passed,
# 0 failed" and be PARTIAL - which is exactly what happened on 2026-09-10: acceptance came back CLEAN
# and cut-release refused with "PARTIAL MATRIX - these cells did not run: win11-reinstall,
# win11-upgrade". The gate caught it; this default should not have needed catching.
# Not a list anyone should silently shrink (memory: full-acceptance-before-release-is-a-GATE).
CELLS_DEFAULT="win10-clean win10-reinstall win10-upgrade win10-appvm win11-clean win11-reinstall win11-upgrade win11-appvm"
CELLS="$CELLS_DEFAULT"
G10="${G10:?set G10 to the Win10 entry image - there is no default target}"
G11="${G11:?set G11 to the Win11 entry image - there is no default target}"
# The BASE goldens the campaign clones its cells from. matrix.sh requires them - it used to
# default them to win10-base/win11-base and the owner retired every default target ("wrong 99% of
# runs"), so the runner has to name them too rather than silently re-introduce the default one
# level up. Measured 2026-09-25: without this the campaign died in one second with
# "matrix.sh: line 1628: B10: set B10 to the Win10 base golden".
B10="${B10:?set B10 to the Win10 base golden - there is no default target}"
B11="${B11:?set B11 to the Win11 base golden - there is no default target}"
# The feature tests quick-upgrade a sealed golden <F11>-qwt. This was hard-coded OS_FAMILY=win11 and so kept naming win11-qwt after the
# Win11 goldens moved to the retail image (win11r-*): on 2026-10-02 both feature tests died in seconds on "no golden win11-qwt" while
# the campaign had passed 96/96. Named like every other target here - no default.
F11="${F11:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN="${2:-}"; shift 2 ;;
    --cells) CELLS="${2:-}"; shift 2 ;;
    --skip-features) SKIP_FEATURES=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$RUN" ] || { echo "ERROR: --run <release-package-run-id> is required" >&2; exit 2; }

# /tmp IS RAM ON THIS QUBE - a 1 GB tmpfs on a 4 GB machine - and a full one gets the acceptance run
# OOM-killed mid-campaign. That is not hypothetical: this runner was killed twice that way, once
# after the campaign had already passed. So it puts its own temporary files on real disk and refuses
# to start when the RAM-backed /tmp is too full to survive a run, instead of dying an hour in.
export TMPDIR="${TMPDIR:-$HOME/tmp}"
mkdir -p "$TMPDIR"
case "$TMPDIR" in
  /tmp|/tmp/*) echo "ERROR: TMPDIR is under /tmp, which is RAM here. Point it at real disk." >&2; exit 2 ;;
esac
_tmpfree=$(df -Pm /tmp 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$_tmpfree" ] && [ "$_tmpfree" -lt 200 ]; then
  echo "ERROR: only ${_tmpfree} MB free on /tmp (a RAM-backed tmpfs). A run needs headroom there" >&2
  echo "       even with TMPDIR elsewhere; clear it first - this is what OOM-killed earlier runs." >&2
  exit 2
fi

WORK="${WORK:-$HOME/qwt-accept/rel-$RUN}"
mkdir -p "$WORK/dl"
LOG="$WORK/release-acceptance.log"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }
die(){ say "FATAL: $*"; exit 1; }

# REFUSE TO START UNDER A STRAY HARNESS PROCESS. An orphaned prime-run kept driving win10-acc after
# its parents were killed on 2026-09-10 - restarting the guest under a new run, so state readings
# fought a process that was believed gone, and the next cell refused with "these are not Halted".
# run-lib.sh already tears down its descendant tree on SIGTERM; that orphan followed a kill -9, which
# skips traps by definition. So this does not paper over a library defect - it stops the CONSEQUENCE,
# which is a second driver on the rig that nothing else would notice.
_stray=$(pgrep -af "[m]gmt/harness/(matrix|prime-run|quick-upgrade)\.sh" 2>/dev/null | head -5)
if [ -n "$_stray" ]; then
  echo "ERROR: a harness job is already running - refusing to start a second driver on the rig:" >&2
  printf '  %s\n' "$_stray" >&2
  echo "       If it is an orphan, kill it with SIGTERM (not -9, which skips its teardown traps)." >&2
  exit 2
fi

say "=== release acceptance for run $RUN (work: $WORK) ==="

# ---- 1. the run must be a GREEN release-package run -------------------------------------------
# Checked rather than assumed: downloading artifacts from a partially-failed run yields a package
# whose missing half only shows up as a puzzling acceptance failure hours later.
WF=$(gh run view "$RUN" --json workflowName --jq .workflowName 2>/dev/null)
CONCL=$(gh run view "$RUN" --json conclusion --jq .conclusion 2>/dev/null)
HEAD=$(gh run view "$RUN" --json headSha --jq .headSha 2>/dev/null)
say "run $RUN: workflow='$WF' conclusion='$CONCL' head=${HEAD:0:12}"
case "$WF" in
  *release-package*|*Release*) ;;
  *) die "run $RUN is workflow '$WF', not release-package - only that workflow builds a full setup tree ('build' is an overlay)" ;;
esac
[ "$CONCL" = success ] || die "run $RUN concluded '$CONCL' - acceptance runs only against a green release build"

# ---- 2. artifacts ------------------------------------------------------------------------------
if [ ! -d "$WORK/dl/qwt-improved-setup" ]; then
  say "downloading qwt-improved-setup"
  gh run download "$RUN" -n qwt-improved-setup -D "$WORK/dl/qwt-improved-setup" >/dev/null 2>&1 \
    || die "could not download qwt-improved-setup from run $RUN"
fi
if [ ! -f "$WORK/dl/qwt-improved-iso/qwt-improved-setup.iso" ]; then
  say "downloading qwt-improved-iso"
  gh run download "$RUN" -n qwt-improved-iso -D "$WORK/dl/qwt-improved-iso" >/dev/null 2>&1 \
    || die "could not download qwt-improved-iso from run $RUN"
fi
SETUP="$WORK/dl/qwt-improved-setup"
ISO="$WORK/dl/qwt-improved-iso/qwt-improved-setup.iso"
PV=$(python3 -c "import json;print(json.load(open('$SETUP/MANIFEST.json'))['package_version'])" 2>/dev/null) \
  || die "no readable MANIFEST.json in the setup tree"
say "package: $PV"

# ---- 3. the package must verify BEFORE any guest is touched ------------------------------------
# A campaign against a package that fails its own identity check measures nothing, and it costs
# hours to find out the slow way.
say "--- verifying the release package"
if bash tools/verify-release-package.sh --tree "$SETUP" --commit "$HEAD" >>"$LOG" 2>&1; then
  say "PASS  release package verified"
else
  die "verify-release-package.sh FAILED - see $LOG. Nothing below would be meaningful."
fi

# ---- 4. the campaign ---------------------------------------------------------------------------
# ---- 4b. ENTRY FIXTURES EXIST - checked BEFORE the campaign, not discovered by a cell 55 min in.
# 2026-09-17: a pool prune (protocol RED, 92% used) removed win10-iqi/win11-iqi, the previous-ours
# 4.3.17 entry images the upgrade cells reclone from; win10-clean and win10-reinstall then ran for
# 55 min before WIN10-upgrade died with "clone attempt 1 FAILED: KeyError: 'win10-iqi'" and the
# campaign was PARTIAL by construction. A missing fixture is an infrastructure fact knowable at
# minute 0, so it is refused here, with the rebuild command, and nothing is graded on its absence.
for _c in $CELLS; do
  case "$_c" in
    win10-upgrade|win10-seeded) _g="$G10"; _b=win10-base ;;
    win11-upgrade|win11-seeded) _g="$G11"; _b=win11-base ;;
    *) continue ;;
  esac
  if ! qvm-check "$_g" >/dev/null 2>&1; then
    die "cell $_c needs entry fixture '$_g' and it does NOT EXIST on the rig. Rebuild it from the sealed base with the PREVIOUS release's setup tree (4.3.17: gh release download v4.3.17-agent45e788d -p qwt-improved-setup.iso, extract), e.g.: mgmt/harness/prime-run.sh $_b $_g ours --payload <that tree> ; or pass G10=/G11= naming an existing previous-ours fixture. Refusing to start a campaign that is PARTIAL by construction."
  fi
  [ -f "mgmt/fixtures/$_g.json" ] || say "WARNING: $_g exists but has no fixture record mgmt/fixtures/$_g.json - matrix.sh's custody gate may refuse it"
done
if [ "$SKIP_FEATURES" -eq 0 ]; then
  [ -n "$F11" ] || die "set F11 to the Win11 golden family for the feature tests (they quick-upgrade the sealed golden <F11>-qwt) - there is no default target"
  qvm-check "$F11-qwt" >/dev/null 2>&1 || die "the feature tests need the sealed golden '$F11-qwt' and it does NOT EXIST on the rig. Seal it from the PREVIOUS release's setup tree: mgmt/harness/seal-qwt-golden.sh $F11 <N-1 setup tree>; refusing to start a run whose feature tests cannot run."
fi
say "--- matrix campaign: $CELLS"
CAMP="$WORK/campaign"
mkdir -p "$CAMP"
# The campaign's stdout MUST land in a <tag>.out inside $CAMP: record-acceptance.sh globs *.out and
# requires the '=== MATRIX: n passed, n failed ===' footer in each, treating a footerless file as a
# group that did not finish. Writing this to runner.log instead would make the run unrecordable.
# matrix.sh takes its own output dir from MATRIX_OUT, not OUT.
MATRIX_WORK="$WORK" RELEASE_SETUP="$SETUP" RELEASE_ISO="$ISO" RELEASE_COMMIT="$HEAD" \
  CELLS="$CELLS" G10="$G10" G11="$G11" B10="$B10" B11="$B11" MATRIX_OUT="$CAMP/matrix" \
  ./mgmt/harness/matrix.sh 2>&1 | tee -a "$CAMP/full.out" >>"$CAMP/runner.log"
MRC=${PIPESTATUS[0]}
say "matrix rc=$MRC (detail: $CAMP/full.out, artefacts: $CAMP/matrix)"

# ---- 5. the feature tests this release is about ------------------------------------------------
# These are NOT a substitute for the campaign; they are the per-feature evidence a campaign cell
# does not cover. Each drives its own throwaway subject over quick-upgrade.
# NO STALE FEATURE RESULTS: $CAMP is per release-package run, so a re-run of the same run would otherwise find an earlier attempt's
# feature-*.out and record THEM - a skipped or failed feature test inheriting an old pass (Jev review 2026-10-02). Cleared first, always.
rm -f "$CAMP"/feature-*.out
if [ "$SKIP_FEATURES" -eq 0 ]; then
  # SETTLE THE RIG FIRST. The campaign's appvm cells leave their AppVM RUNNING, and quick-upgrade
  # refuses to start while any other Windows guest is up ("REFUSED: these are not Halted") - the
  # serial-rig rule, working correctly. Without this the feature tests died 7 s after a 45-minute
  # campaign, reporting a harness collision as a feature failure. Shut them down and WAIT.
  # ...and BEFORE EACH feature test too: the feature tests leave their own subjects running (notify-errors-guest-test leaves
  # win11-nfy up for crop-before-map, by design), and on rz35 (2026-10-02) template-update's quick-upgrade was refused in 4 s by
  # "these are not Halted: win11-nfy" - a harness collision recorded as a feature failure.
  settle_rig(){ # $1 what the guests are being settled for
    say "settling the rig before $1"
    for vm in $(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$1 ~ /^win1/ && $2!="Halted"{print $1}'); do
      say "  shutting down $vm (left running)"
      qwt_shutdown "$vm" 600 || { say "  $vm did not halt in 600s - killing it; the next clone from its volume may be dirty"; timeout 60 qvm-kill "$vm" >/dev/null 2>&1; }
    done
    for i in $(seq 1 40); do
      busy=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$1 ~ /^win1/ && $2!="Halted"{print $1}' | tr '\n' ' ')
      [ -z "$busy" ] && break
      [ "$i" = 1 ] && say "  waiting for: $busy"
      sleep 15
    done
    busy=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$1 ~ /^win1/ && $2!="Halted"{print $1}' | tr '\n' ' ')
    [ -z "$busy" ] || say "WARNING: still not Halted after 10 min: $busy - $1 will likely be refused"
  }
  settle_rig "the feature tests"

  # the list is shared with tools/acceptance-record-check.py, which requires every one of these in the record
  for t in $(grep -v -e '^#' -e '^[[:space:]]*$' tools/release-feature-tests.txt); do
    say "--- feature test: $t"
    [ "$t" = crop-before-map ] || settle_rig "feature test $t"   # crop-before-map rides the notify test's running subject
    case "$t" in
      notify-errors-guest-test)
        VM=win11-nfy PKG="$SETUP" OS_FAMILY="$F11" LOG="$WORK/$t.log" \
          ./mgmt/harness/notify-errors-guest-test.sh >>"$WORK/$t.out" 2>&1
        rc=$? ;;
      crop-before-map)
        # Rides the guest the notify test just left installed with the release.
        VM=win11-nfy LOG="$WORK/$t.log" ./mgmt/harness/crop-before-map.sh >>"$WORK/$t.out" 2>&1
        rc=$? ;;
      template-update)
        # THE UPDATER ON THE ONE CLASS IT SERVES. The proxied updater runs on TemplateVMs only, and until 2026-10-02 no release had
        # ever run an update pass on one - every update run was on StandaloneVM subjects (phase=skipped-standalone), which is how
        # GWeck's first-contact failure shipped in every release from 4.3.30 on. Owner: "the point of updater test is that it is
        # templateVM!" The subject is upgraded over the reporter's sealed German 25H2 TemplateVM golden and env-asserted as his.
        VM=win11de-tup PKG="$SETUP" FAMILY=win11de REPORTER=gweck LOG="$WORK/$t.log" OUT="$WORK/$t.d" \
          ./mgmt/harness/template-update-test.sh >>"$WORK/$t.out" 2>&1
        rc=$? ;;
      *)
        # A listed test with no arm would otherwise inherit rc from the PREVIOUS test - a stale PASS (tools/check-cell-coverage.sh
        # also refuses such a list at commit time).
        say "no runner arm for feature test '$t' - tools/release-feature-tests.txt names it"; rc=2 ;;
    esac
    if [ $rc -eq 0 ]; then say "PASS  $t"; else say "FAIL  $t (rc=$rc, see $WORK/$t.log)"; MRC=1; fi
    # A FEATURE TEST IS PART OF THE RECORDED VERDICT. record-acceptance.sh derives the record from $CAMP/*.out only, so the
    # feature tests used to be invisible to it (rz30 recorded CLEAN with both never run). Each now leaves a cell-group in the
    # campaign dir with matrix.sh's footer; tools/acceptance-record-check.py requires feature-<test> among the recorded cells.
    { echo "[$(date +%T)]   cells: feature-$t"
      if [ $rc -eq 0 ]; then echo "=== MATRIX: 1 passed, 0 failed ==="; else echo "=== MATRIX: 0 passed, 1 failed ==="; fi
    } > "$CAMP/feature-$t.out"
  done
else
  say "feature tests SKIPPED by --skip-features (say so in any report: this is not a full run)"
fi

# ---- 6. record ----------------------------------------------------------------------------------
# The verdict is DERIVED from the campaign logs by record-acceptance.sh, never passed in.
say "--- recording the acceptance verdict against the ISO"
if bash tools/record-acceptance.sh --iso "$ISO" --campaign "$CAMP" >>"$LOG" 2>&1; then
  say "PASS  acceptance recorded"
else
  say "FAIL  acceptance NOT recorded - tools/cut-release.sh will refuse this ISO, which is correct"
  MRC=1
fi

# ---- 7. the coverage receipt ---------------------------------------------------------------------
# WHAT THIS RUN ACTUALLY COVERED, written where the release-cut gate reads it (docs/ADR-acceptance.md
# section 4). Only suites that RAN are named - a receipt is a record, not an intention - and the gate
# re-runs tools/gate-scope.py check against it, so a receipt that does not satisfy the diff refuses the
# cut exactly as an absent one does.
COVHEAD=$(git rev-parse HEAD 2>/dev/null | cut -c1-12)
if [ -n "$COVHEAD" ]; then
  COVFILE="scratchpad/gate-coverage-$COVHEAD.json"
  mkdir -p scratchpad
  COVRAN="package-verify"
  for _c in $CELLS; do COVRAN="$COVRAN $_c"; done
  if [ "$SKIP_FEATURES" -eq 0 ]; then COVRAN="$COVRAN notify-errors-guest-test crop-before-map template-update"; fi
  python3 - "$COVFILE" "$RUN" "$HEAD" "$MRC" $COVRAN <<'PYCOV'
import json, sys
out, run, head, rc, suites = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
json.dump({"suites": sorted(set(suites)), "package_run": run, "built_from": head,
           "result": "pass" if rc == "0" else "fail",
           "note": "written by tools/release-acceptance.sh; names only the suites this run ran"},
          open(out, "w"), indent=1)
PYCOV
  say "coverage receipt: $COVFILE ($(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['suites']))" "$COVFILE") suite(s))"
  if [ -f tools/gate-scope.py ]; then
    GSBASE=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD^ 2>/dev/null || git rev-list --max-parents=0 HEAD 2>/dev/null)
    if [ -n "$GSBASE" ] && python3 tools/gate-scope.py check "$COVFILE" "$GSBASE..$(git rev-parse HEAD)" >>"$LOG" 2>&1; then
      say "PASS  gate scope: this run covers what the diff requires"
    else
      say "FAIL  gate scope: this run does NOT cover what the diff requires (see $LOG) - the release-cut gate will refuse the cut"
      MRC=1
    fi
  fi
fi

say "=== release acceptance for $PV: $( [ $MRC -eq 0 ] && echo COMPLETE || echo INCOMPLETE/FAILED ) ==="
say "setup: $SETUP"
say "iso:   $ISO"
exit $MRC
