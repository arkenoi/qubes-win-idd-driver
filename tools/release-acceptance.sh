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
G10="${G10:-win10-iqi}"; G11="${G11:-win11-iqi}"

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
say "--- matrix campaign: $CELLS"
CAMP="$WORK/campaign"
mkdir -p "$CAMP"
# The campaign's stdout MUST land in a <tag>.out inside $CAMP: record-acceptance.sh globs *.out and
# requires the '=== MATRIX: n passed, n failed ===' footer in each, treating a footerless file as a
# group that did not finish. Writing this to runner.log instead would make the run unrecordable.
# matrix.sh takes its own output dir from MATRIX_OUT, not OUT.
MATRIX_WORK="$WORK" RELEASE_SETUP="$SETUP" RELEASE_ISO="$ISO" RELEASE_COMMIT="$HEAD" \
  CELLS="$CELLS" G10="$G10" G11="$G11" MATRIX_OUT="$CAMP/matrix" \
  ./mgmt/harness/matrix.sh 2>&1 | tee -a "$CAMP/full.out" >>"$CAMP/runner.log"
MRC=${PIPESTATUS[0]}
say "matrix rc=$MRC (detail: $CAMP/full.out, artefacts: $CAMP/matrix)"

# ---- 5. the feature tests this release is about ------------------------------------------------
# These are NOT a substitute for the campaign; they are the per-feature evidence a campaign cell
# does not cover. Each drives its own throwaway subject over quick-upgrade.
if [ "$SKIP_FEATURES" -eq 0 ]; then
  # SETTLE THE RIG FIRST. The campaign's appvm cells leave their AppVM RUNNING, and quick-upgrade
  # refuses to start while any other Windows guest is up ("REFUSED: these are not Halted") - the
  # serial-rig rule, working correctly. Without this the feature tests died 7 s after a 45-minute
  # campaign, reporting a harness collision as a feature failure. Shut them down and WAIT.
  say "settling the rig before the feature tests"
  for vm in $(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$1 ~ /^win1/ && $2!="Halted"{print $1}'); do
    say "  shutting down $vm (left running by the campaign)"
    qvm-shutdown --wait --timeout 180 "$vm" >/dev/null 2>&1 || qvm-kill "$vm" >/dev/null 2>&1
  done
  for i in $(seq 1 40); do
    busy=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$1 ~ /^win1/ && $2!="Halted"{print $1}' | tr '\n' ' ')
    [ -z "$busy" ] && break
    [ "$i" = 1 ] && say "  waiting for: $busy"
    sleep 15
  done
  busy=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$1 ~ /^win1/ && $2!="Halted"{print $1}' | tr '\n' ' ')
  [ -z "$busy" ] || say "WARNING: still not Halted after 10 min: $busy - the feature tests will likely be refused"

  for t in notify-errors-guest-test crop-before-map; do
    say "--- feature test: $t"
    case "$t" in
      notify-errors-guest-test)
        VM=win11-nfy PKG="$SETUP" OS_FAMILY=win11 LOG="$WORK/$t.log" \
          ./mgmt/harness/notify-errors-guest-test.sh >>"$WORK/$t.out" 2>&1
        rc=$? ;;
      crop-before-map)
        # Rides the guest the notify test just left installed with the release.
        VM=win11-nfy LOG="$WORK/$t.log" ./mgmt/harness/crop-before-map.sh >>"$WORK/$t.out" 2>&1
        rc=$? ;;
    esac
    if [ $rc -eq 0 ]; then say "PASS  $t"; else say "FAIL  $t (rc=$rc, see $WORK/$t.log)"; MRC=1; fi
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

say "=== release acceptance for $PV: $( [ $MRC -eq 0 ] && echo COMPLETE || echo INCOMPLETE/FAILED ) ==="
say "setup: $SETUP"
say "iso:   $ISO"
exit $MRC
