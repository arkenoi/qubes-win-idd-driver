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
# ACCEPTCANCELORPHAN, root-caused 2026-10-21: this script NEVER sourced run-lib.sh and never called
# job_init, so it had NO teardown trap at all - while its own comment above asserted that
# "run-lib.sh already tears down its descendant tree on SIGTERM". A SIGTERM to this leader therefore
# exited the driver and left matrix.sh running, holding the rig; observed on three separate cancels,
# the surviving pid read from /proc each time. vmlock.sh's documented contract is to cancel a job by
# TERMing the leader, which only works if the leader tears down.
# job_init installs the TERM/INT/HUP/EXIT traps and takes no lock; _rl_teardown kills the descendant
# tree by explicit pid (never a pattern, never a process-group sweep - both have cost this project a
# live cell), and vm_unlock is a no-op unless this process is the recorded lock owner.
# RA-TEARDOWN-A  (to the B marker: extracted and driven by tools/tests/accept-cancel-selftest.sh;
# neither marker names the other)
# $0-RELATIVE, not cwd-relative: this block sits ABOVE the `cd` to the repo root, so a bare
# `source mgmt/harness/run-lib.sh` would resolve against whatever directory the caller happened to
# be in - the same defect as prime-run.sh's evidence guard, fixed earlier today. A failure to load
# is fatal: a driver with no teardown is what ACCEPTCANCELORPHAN is.
. "$(dirname "$0")/../mgmt/harness/run-lib.sh" || {
  echo "FATAL: cannot load run-lib.sh - without it a cancel leaves the campaign running" >&2; exit 2; }
job_init "release-acceptance"
# RA-TEARDOWN-B
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
# EVERY LINE DECLARES A LEVEL. This logger emitted none, so sweep-gate could not judge a single line
# of the run's top-level narration - including its own FAIL verdicts. The level follows the prefix
# this script already writes, so the words it has used for years keep their meaning:
#   FATAL:/FAIL      -> E   the run failed, and that is the verdict line a reader looks for
#   INSTRUMENT/WARNING -> W  the suite could not measure the product, or the rig is not settled
#   everything else  -> I
# A blanket [INFO] would have marked its own FAIL lines informational; on this instrument that is a
# silencer (Jev 0.74 on the same shape in arm-module-bases.sh).
#
# matrix.sh:2568 already excludes "[ERROR]/[WARN] FAIL " lines from the unaccounted tally as "this
# campaign's own graded verdicts, already in the tally above", so declaring them does not make a
# failing run fail twice - which on this project is a P1.
say(){ case "$*" in
         "[ERROR]"*|"[WARN]"*|"[WARNING]"*|"[INFO]"*|"[DEBUG]"*) _m="$*" ;;
         FATAL:*|FAIL*)            _m="[ERROR] $*" ;;
         INSTRUMENT*|WARNING:*)    _m="[WARN] $*" ;;
         *)                        _m="[INFO] $*" ;;
       esac
       echo "[$(date -u +%H:%M:%S)] $_m" | tee -a "$LOG"; }
# THE ZONE, ONCE, FIRST - see matrix.sh's say(). This driver's log and the matrix's were measured
# three hours apart for events seconds apart (CAMPAIGNLOGTZSPLIT); the line says which clock.
_clk_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ); _clk_loc=$(date +%:z)
say "clock: stamps here are UTC ($_clk_utc; host local is UTC$_clk_loc); guest log stamps and file names are guest-local - convert before comparing"
die(){ say "FATAL: $*"; exit 1; }

# REFUSE TO START UNDER A STRAY HARNESS PROCESS. An orphaned prime-run kept driving win10-acc after
# its parents were killed on 2026-09-10 - restarting the guest under a new run, so state readings
# fought a process that was believed gone, and the next cell refused with "these are not Halted".
# run-lib.sh tears down its descendant tree on SIGTERM - THIS SCRIPT NOW USES IT (see job_init below;
# until 2026-10-21 it did not, which is ACCEPTCANCELORPHAN); that orphan followed a kill -9, which
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
    win11-upgrade|win11-seeded) _g="$G11"; _b=win11r-base ;;
    *) continue ;;
  esac
  if ! qvm-check "$_g" >/dev/null 2>&1; then
    die "cell $_c needs entry fixture '$_g' and it does NOT EXIST on the rig. Rebuild it from the sealed base with the PREVIOUS release's setup tree (4.3.17: gh release download v4.3.17-agent45e788d -p qwt-improved-setup.iso, extract), e.g.: mgmt/harness/prime-run.sh $_b $_g ours --payload <that tree> ; or pass G10=/G11= naming an existing previous-ours fixture. Refusing to start a campaign that is PARTIAL by construction."
  fi
  [ -f "mgmt/fixtures/$_g.json" ] || say "WARNING: $_g exists but has no fixture record mgmt/fixtures/$_g.json - matrix.sh's custody gate may refuse it"
done

# ---- 4c. THE APPVM CELLS' TEMPLATES EXIST, same rule, found the same way.
# An appvm cell derives an AppVM from a TEMPLATE and restores the campaign's 'installed' park into
# it; it cannot create the template. Neither win10-tpl nor win11-tpl has ever existed on this rig,
# and the cell's halt guard read an absent VM's EMPTY state as "not Halted": run 9's two appvm cells
# each waited 420 s and failed as "template would not halt", four of that campaign's eleven
# failures, for a fixture that was simply never built. Refused here, in one call per cell, with the
# command that builds it.
for _c in $CELLS; do
  case "$_c" in
    win10-appvm) _t=win10-tpl; _s=tpl10 ;;
    win11-appvm) _t=win11-tpl; _s=tpl11 ;;
    *) continue ;;
  esac
  qvm-check "$_t" >/dev/null 2>&1 || \
    die "cell $_c needs TEMPLATE '$_t' and it does NOT EXIST on the rig. Build it: mgmt/harness/rebuild-rig.sh --only $_s (that step is build_template from the matching -iqi fixture, which must exist first). The cell derives an AppVM from this template and cannot create it; refusing to start a campaign that is PARTIAL by construction."
done

if [ "$SKIP_FEATURES" -eq 0 ]; then
  [ -n "$F11" ] || die "set F11 to the Win11 golden family for the feature tests (they quick-upgrade the sealed golden <F11>-qwt) - there is no default target"
  qvm-check "$F11-qwt" >/dev/null 2>&1 || die "the feature tests need the sealed golden '$F11-qwt' and it does NOT EXIST on the rig. Seal it from the PREVIOUS release's setup tree: mgmt/harness/seal-qwt-golden.sh $F11 <N-1 setup tree>; refusing to start a run whose feature tests cannot run."
fi
say "--- matrix campaign: $CELLS"
CAMP="$WORK/campaign"
mkdir -p "$CAMP"
# RAATTEMPT-A  (to the B marker: extracted and executed by
# tools/tests/accept-attempt-boundary-selftest.sh; neither marker names the other)
# THE OTHER HALF OF A DEFECT WHOSE FIRST HALF I SHIPPED AND CALLED DONE. matrix.sh stamps the
# artefacts an attempt inherits under $CAMP/matrix; the files THIS script appends to are one level
# up and were left out. MEASURED 2026-10-22: $CAMP/full.out ended the night carrying BOTH
# `=== MATRIX: 1 passed, 1 failed - ABORTED on a log-device failure ===` from the attempt that died
# at 21:50 AND `=== MATRIX: 44 passed, 2 failed - ABORTED on a log path that broke mid-cell ===`
# from the 22:12 one, with nothing between them - and full.out is the file `matrix rc=` points a
# reader at, so it is the one opened FIRST.
# full.out is ROTATED, not stamped, and the comment below says why: record-acceptance.sh globs
# $CAMP/*.out and requires ONE '=== MATRIX ... ===' footer per file, treating a footerless file as a
# group that did not finish. Two footers in one file breaks that contract, and a separator line
# inside it would not repair it. Rotating gives this attempt a file with exactly one footer while
# KEEPING the previous attempt's - for an aborted attempt that output is its only record - and the
# rotated name does not end in .out, so it leaves the glob the builder depends on.
# The append-only logs beside it just take a boundary: they are read, not parsed.
_ra_rotate_inherited(){ # <attempt-id> <file> -> moves it aside so this attempt starts clean
  local id="${1:?_ra_rotate_inherited <id> <file>}" f="${2:?}"
  [ -f "$f" ] || return 0
  mv -f "$f" "$f.attempt-$id" && printf 'rotated %s -> %s.attempt-%s\n' "$f" "$f" "$id"
}
_ra_stamp_inherited(){ # <attempt-id> <path>... -> boundary into each existing path
  local id="${1:?_ra_stamp_inherited <id> <path>...}"; shift
  local f n=0
  for f in "$@"; do
    [ -f "$f" ] || continue
    printf '=== ATTEMPT BOUNDARY: every line below belongs to attempt %s ===\n' "$id" >> "$f" || continue
    n=$((n+1))
  done
  printf 'inherited-files-stamped=%d attempt=%s\n' "$n" "$id"
}
# AND THE FEATURE TESTS' OWN ARTEFACT TREES, which is the THIRD instance of this defect. The two
# above cover the files THIS script writes; a feature test's $WORK/<tag>.d is written by the suite
# and was never rotated or stamped, so an attempt inherited the previous one's artefacts whole.
# MEASURED on rel-40037710497: template-update.d/wu-e2e/run.log held TWO attempts - the first ended
# `DONE: rounds=3 fails=1`, the retry `rounds=3 fails=0` - and template-update-test.sh reads `DONE:`
# with `tail -1` (the retry's) while scanning wu-e2e's failure patterns over the WHOLE file, so it
# quoted a 02:55:50 line from the superseded attempt and returned
#   VERDICT FAIL: a round failed for a reason other than the judge
# for a run whose every round had passed. That FAIL is in the 09:25:14 record of this very script,
# and it would have blocked the cut on a green feature test.
# ROTATED, not stamped, and for the same reason full.out is: these trees are PARSED by their suites
# (DONE lines, JUDGE verdicts, round counters), and a separator inside a parsed file does not help a
# consumer that greps the whole of it. Rotating gives this attempt an empty tree while KEEPING the
# previous attempt's as its only record. Fixing it HERE fixes every feature test at once - no suite
# needs its own marker, and `rm -f "$CAMP"/feature-*.out` below already applies this principle to
# the result files.
_ra_rotate_inherited_dir(){ # <attempt-id> <dir> -> moves it aside so this attempt starts empty
  local id="${1:?_ra_rotate_inherited_dir <id> <dir>}" d="${2:?}"
  [ -d "$d" ] || return 0
  mv -f "$d" "$d.attempt-$id" && printf 'rotated %s -> %s.attempt-%s\n' "$d" "$d" "$id"
}
ACCEPT_ATTEMPT="${ACCEPT_ATTEMPT:-$(date -u +%Y%m%dT%H%M%SZ)}"
_ra_rotate_inherited "$ACCEPT_ATTEMPT" "$CAMP/full.out" >/dev/null
for _d in "$WORK"/*.d; do _ra_rotate_inherited_dir "$ACCEPT_ATTEMPT" "$_d" >/dev/null; done
# shellcheck disable=SC2086
_ra_stamp_inherited "$ACCEPT_ATTEMPT" "$LOG" "$CAMP/runner.log" $WORK/*.out >/dev/null
# ONE attempt id across both layers, so a reader joining a campaign log to a cell artefact is
# matching the same string rather than two clocks.
export MATRIX_ATTEMPT="$ACCEPT_ATTEMPT"
# RAATTEMPT-B

# ---- 3c. THE BIND IS SMOKE-TESTED BEFORE THE EIGHT CELLS THAT COST HOURS ------------------------
# Campaign 40134888669 aborted 11 minutes in, on its first cell, because the guest could not see the
# log volume - after spending 10 of those minutes installing. The preparation gates written
# afterwards (campaign-preflight.sh 2b) check everything AROUND that bind and not one of them checks
# the bind. Owner: "and why we did not smoke test the bind". So it runs here, on a clone of the QWT
# golden, and it costs ~6 minutes against a campaign of hours.
#
# BOTH ARMS, EVERY RUN, and the refutation arm goes FIRST. With nothing attached the bind MUST
# refuse; if it answers ok there, then its receipt is not about the volume and a PASS of the other
# arm means nothing - a gate whose instrument is not checked each time is the decoration this
# project keeps paying for. 3 minutes buys that, and it is also the cheaper arm to fail on.
# A non-PASS STOPS THE CAMPAIGN HERE: the artefacts go to $CAMP/logvol-smoke-*/ and deliberately NOT
# to a *.out (record-acceptance.sh globs those and requires a MATRIX footer in each).
# RASMOKE-A  (to the B marker: extracted and EXECUTED by
# tools/tests/accept-logvol-smoke-selftest.sh; neither marker names the other)
# AND THERE IS NO KNOB. Asked whether a LOGVOL_SMOKE=0 escape was acceptable, Jev answered 0.50 -
# no endorsement either way - and this project's rule is to ask before adding a guard knob at all.
# Six minutes against a campaign of hours does not need an off switch, and the one thing an off
# switch guarantees is that the run which most needed the gate is the run that skipped it.
for _arm in --no-attach ""; do
  _tag=$([ -n "$_arm" ] && echo refutation || echo bind)
  say "logvol smoke ($_tag arm): can a guest SEE the log volume, and does evidence reach the image?"
  # shellcheck disable=SC2086
  LOGVOL_SMOKE_OUT="$CAMP/logvol-smoke-$_tag" \
    ./mgmt/harness/logvol-smoke.sh $_arm >>"$CAMP/logvol-smoke.log" 2>&1
  _src=$?
  case "$_src" in
    0) say "logvol smoke ($_tag arm) PASS - $(tail -2 "$CAMP/logvol-smoke-$_tag/verdict.tsv" 2>/dev/null | tr '\t\n' '  ')" ;;
    2) die "logvol smoke ($_tag arm) could not measure (INVALID-RIG, rc=2): $(tail -1 "$CAMP/logvol-smoke.log"). The rig, not the bind - and a campaign is not started on a rig that cannot clone and boot a golden." ;;
    *) die "logvol smoke ($_tag arm) FAILED (rc=$_src): $(tail -1 "$CAMP/logvol-smoke.log"). This is campaign 40134888669 caught in minutes instead of after an install - fix the volume path before spending the cells." ;;
  esac
done
# RASMOKE-B

# The campaign's stdout MUST land in a <tag>.out inside $CAMP: record-acceptance.sh globs *.out and
# requires the '=== MATRIX: n passed, n failed ===' footer in each, treating a footerless file as a
# group that did not finish. Writing this to runner.log instead would make the run unrecordable.
# matrix.sh takes its own output dir from MATRIX_OUT, not OUT.
MATRIX_WORK="$WORK" RELEASE_SETUP="$SETUP" RELEASE_ISO="$ISO" RELEASE_COMMIT="$HEAD" \
  CELLS="$CELLS" G10="$G10" G11="$G11" B10="$B10" B11="$B11" MATRIX_OUT="$CAMP/matrix" \
  POOL_SPACE_RUN="$ACCEPT_ATTEMPT" \
  ./mgmt/harness/matrix.sh 2>&1 | tee -a "$CAMP/full.out" >>"$CAMP/runner.log"
MRC=${PIPESTATUS[0]}
say "matrix rc=$MRC (detail: $CAMP/full.out, artefacts: $CAMP/matrix)"

# ---- 4b. ABORT ON A FATAL, which this script did not do ----------------------------------------
# MEASURED 2026-10-22: mgmt/harness/matrix.sh FATALed and printed
#   "=== MATRIX: 75 passed, 6 failed - ABORTED on a log path that broke mid-cell ==="
# after a guest wedged in WIN11-upgrade, and the next statement here was the feature tests. They
# ran on a rig whose subject had just been hard-killed, win11-appvm never ran at all, and the
# operator had to stop the run by hand. MRC was read and then never consulted.
# An ABORTED matrix is FATAL and stops everything above it. A merely FAILING cell is NOT: product
# failures still let the feature tests produce their independent evidence, which is the deliberate
# scope split and the reason this keys on the tally rather than on MRC alone.
. "$(dirname "$0")/../mgmt/harness/wedge-gates-lib.sh" || {
  say "FAIL  cannot load wedge-gates-lib.sh - the fatal gate is the thing that stops a wedged run"; exit 2; }
# A HELD SPECIMEN STOPS THE CAMPAIGN BEFORE ANYTHING ELSE IS ATTEMPTED. Checked here as well as
# in settle_rig, because the rig is occupied from that moment and nothing downstream can run.
if [ -s "$CAMP/specimen-held" ]; then
  _sv=$(tr -d '\r\n' < "$CAMP/specimen-held")
  say "[ERROR] STOP: $_sv is HELD (class=$(tr -d '\r\n' < "$CAMP/specimen-class" 2>/dev/null)) - its antecedent was not captured"
  say "         The hold ENDS deliberately, not by timeout: read the stick, then release it with"
  say "           source mgmt/harness/wedge-gates-lib.sh; wedge_release $_sv $(tr -d '\r\n' < "$CAMP/specimen-record" 2>/dev/null) '<why it is safe to end>'"
  say "         Until then this guest holds the rig, which is the intended trade: the specimen is the"
  say "         only copy of the state, and the campaign can be re-run."
  say "[ERROR] it holds the rig deliberately: a destroyed specimen cannot be retried, so the campaign"
  say "[ERROR] stops here rather than letting every later cell be refused with 'these are not Halted'."
  say "[ERROR] record: $(tr -d '\r\n' < "$CAMP/specimen-record" 2>/dev/null)"
  say "[ERROR] to resume the rig once it has been examined: qvm-remove -f $_sv (it is contaminated and"
  say "[ERROR] must be redeployed from its golden in any case)."
  exit 1
fi
if grep -qaE '=== MATRIX: .* ABORTED' "$CAMP/full.out" 2>/dev/null; then
  say "[ERROR] STOP: $(grep -aoE '=== MATRIX:[^=]*' "$CAMP/full.out" | tail -1)"
  say "[ERROR] the matrix did not finish, so the feature tests, the remainder suites and the receipt"
  say "[ERROR] are NOT run: they would execute against a rig the matrix did not finish with."
  for _wgc in "$CAMP"/matrix/wedge-*/class.txt; do
    [ -s "$_wgc" ] || continue
    say "[ERROR]   wedge record present: $(dirname "$_wgc") class=$(tr -d '\r\n' < "$_wgc")"
  done
  python3 tools/campaign-state.py 2>&1 | tail -20 | tee -a "$LOG" >/dev/null
  exit 1
fi

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
      # A KILL IS THE LAST THING THAT EVER SEES THE LIVE STATE, so it is gated on a record.
      # MEASURED 2026-10-22: this line killed win11-acc at 600s having captured NOTHING - no screen,
      # no vcpu samples, no VMCS - and the resulting specimen has no resolvable RIP. It also could
      # not tell a wedge from a look-alike: win11-acc's qrexec answered rc=0 minutes later and it
      # halted cleanly, while win11-upgrade's guest in the same campaign never answered again.
      # So: classify first (host-side, deterministic), record, and only then kill - and if the
      # record is incomplete, leave the guest UP as the specimen rather than destroy it.
      # THE ACPI RETURN CODE IS THE STRONGEST INDICATOR WE HAVE, and this line used to throw it
      # away. `if ! qwt_shutdown` collapses four measured meanings - halted / no effect on the same
      # session / the guest rebooted / could not tell - into one boolean, on every guest, on the
      # exact path where a wedge is decided. Owner 2026-10-22: "can we RELIABLY detect 'ACPI is not
      # responding'? it is the main one". So: sample the host-side session identity first, keep the
      # rc, and hand both to the one mapping in wedge-gates-lib.sh.
      _x0=$(_wg_xid "$vm")
      qwt_shutdown "$vm" 600; _src=$?
      if [ "$_src" -ne 0 ]; then
        _wgd="$CAMP/matrix/wedge-$vm-$(date -u +%H%M%S)"
        say "[WARN]   $vm did not halt in 600s (qwt_shutdown rc=$_src) - classifying before anything kills it -> $_wgd"
        if wedge_collect "$vm" "$_wgd" >>"$LOG" 2>&1; then
          wedge_stage1 "$_wgd"
          # THE EXPENSIVE DUMP, ONLY WHEN IT WOULD MEAN SOMETHING. Two 300s-bounded hypervisor
          # captures per guest would otherwise be paid in this loop for every guest that did not
          # halt, to produce data that is now best-effort and labels the shape only. So: take it
          # when the cheap half says this is a wedge candidate, then re-run the pure stage 1 over
          # the richer record to pick the shape up.
          if [ "$(wedge_disposition "$WG_CLASS")" = undecided ]; then
            say "[WARN]   $vm is a wedge candidate - taking the hypervisor dump for the shape"
            wedge_collect_dump "$vm" "$_wgd" >>"$LOG" 2>&1 || true
            wedge_stage1 "$_wgd"
          fi
          # The ask ALREADY HAPPENED above, so stage 2 records that observation rather than asking
          # again - one ACPI ask per guest, and the one the rig was going to make anyway.
          # 600 is the deadline THIS path asked with, above - not WG_ACPI_BOUND. The record cites
          # what was measured (Jev 2026-10-22: the two bounds disagreeing was the one unhandled
          # confound in the whole predicate).
          wedge_acpi_record "$_wgd" "$_src" "$_x0" "$vm" 600 >>"$LOG" 2>&1
          if [ "$(wedge_disposition "$WG_CLASS")" = undecided ]; then
            wedge_stage2 "$_wgd"
            say "[WARN]   $vm ACPI=$(tr -d '\r\n' < "$_wgd/acpi-result" 2>/dev/null) -> $WG_CLASS"
          fi
          printf '%s\n' "$WG_CLASS" > "$_wgd/class.txt"; printf '%s\n' "$WG_WHY" > "$_wgd/why.txt"
          say "[WARN]   $vm classified $WG_CLASS - $WG_WHY"
          # SECONDARY EVALUATOR, REFERENCE ONLY. The class above is the verdict and is already
          # recorded; this asks Jev which KNOWN MECHANISM the record supports, and what single
          # capture would separate the rest. It cannot change the class, and a missing network
          # leaves a note rather than a gap.
          wedge_gates_jev "$_wgd" "$WG_CLASS" >>"$LOG" 2>&1 || true
          printf 'JEV (secondary evaluator, supplementary - the class above is the verdict):\n%s\n' "$WG_JEV" >> "$_wgd/jev.txt"
          say "[INFO]   Jev (reference only): $(printf '%s' "$WG_JEV" | tr '\n' ' ' | cut -c1-200)"
        else
          say "[WARN]   could not collect a record for $vm - killing it anyway would destroy the only state there is"
        fi
        # ONE SHOT, AND THE CAMPAIGN STOPS. A preserved specimen OCCUPIES THE RIG: every later cell
        # and every feature test would be refused with "these are not Halted", one after another,
        # which is a confusing cascade rather than a verdict - the same shape of defect as letting
        # the feature tests run after an aborted matrix. So the runner records WHICH guest is held
        # and stops deliberately at the next check, instead of continuing into refusals.
        if ! wedge_may_kill "$_wgd" "${WG_CLASS:-}" >>"$LOG" 2>&1; then
          say "[ERROR]  HOLDING $vm (class=${WG_CLASS:-unclassified}) - the ANTECEDENT was not captured"
          say "           A guest is held for exactly one reason now: another chance to read the stick,"
          say "           which answers what it did right before. The register dump does not hold it."
          printf '%s' "$WG_LINES" | sed 's/^/           /' | tee -a "$LOG" >/dev/null
          printf '%s\n' "$vm" > "$CAMP/specimen-held"
          printf '%s\n' "${WG_CLASS:-unclassified}" > "$CAMP/specimen-class"
          printf '%s\n' "$_wgd" > "$CAMP/specimen-record"
          MRC=1
          continue
        fi
        # Reached ONLY through wedge_may_kill above, which is a positive allowlist: the class is
        # one there is nothing left to preserve about (it answered ACPI, or it is already gone).
        say "[WARN]   kill permitted for $vm (class=${WG_CLASS:-unclassified}); the next clone from its volume may be dirty"
        timeout 60 qvm-kill "$vm" >/dev/null 2>&1
      fi
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
      updater-component)
        # THE UPDATER'S QUICK GATES, over GWeck's sealed German 25H2 TemplateVM. Minutes, guest-side,
        # no dom0 photography. It asserts what template-update never did - that the relay was BUILT,
        # vouched, listening on 8082 with parent=, served by the pass, and that a COUNT reached dom0
        # - so a relay that was never compiled is named here instead of surfacing an hour later as
        # an update-outcome symptom (fa5b416a, 2026-10-19: a bare `{ }` made the compile dead code,
        # and the silence was attributed to four other causes in turn). Same gates run again as
        # template-update's own preflight; one implementation in mgmt/harness/updater-gates-lib.sh.
        VM=win11de-uc PKG="$SETUP" FAMILY=win11de REPORTER=gweck LOG="$WORK/$t.log" OUT="$WORK/$t.d" \
          ./mgmt/harness/updater-component-test.sh >>"$WORK/$t.out" 2>&1
        rc=$? ;;
      template-update)
        # THE UPDATER ON THE ONE CLASS IT SERVES. The proxied updater runs on TemplateVMs only, and until 2026-10-02 no release had
        # ever run an update pass on one - every update run was on StandaloneVM subjects (phase=skipped-standalone), which is how
        # GWeck's first-contact failure shipped in every release from 4.3.30 on. Owner: "the point of updater test is that it is
        # templateVM!" The subject is upgraded over the reporter's sealed German 25H2 TemplateVM golden and env-asserted as his.
        VM=win11de-tup PKG="$SETUP" FAMILY=win11de REPORTER=gweck LOG="$WORK/$t.log" OUT="$WORK/$t.d" \
          ./mgmt/harness/template-update-test.sh >>"$WORK/$t.out" 2>&1
        rc=$? ;;
      supervision-gate)
        # THE ADR'S OWN RELEASE GATE, which until 2026-10-23 nothing ran.
        # docs/ADR-supervision.md has a section headed "Still owed on a guest (the release gate, win11
        # cell)" listing five items. mgmt/harness/supervision-e2e.sh existed, had a 17/0 offline
        # selftest, and was in NO list - not here, not in matrix.sh - so none of those five had ever
        # been measured in a campaign, and three of them had no runner anywhere (audited by content:
        # that harness mentioned no death-1, DEATH #1, 7023, 7031, 1460, wevtutil, QwtDeathReporter,
        # QwtEventSource, WaitForQdb or 4001). L9 was added for items 1 and 5.
        # ONLY THE COVERING CELLS RUN HERE: L1 deploy, L9 the install's supervision receipts (items 1
        # and 5), L2 the clean boot/shutdown negative control (item 4), L8 a death during a shutdown
        # reported EXACTLY once (item 2). Not the whole 10-cell routine - L3/L6/L7/L7C answer other
        # questions, and L4 restarts the agent on purpose, which must never run inside a release
        # campaign (it takes the toast bridge down with it).
        # L8 IS BACK IN THIS LIST, AND MY REASON FOR REMOVING IT WAS WRONG. RETRACTED 2026-10-23.
        # I took L8 out claiming its clause conflicted with 95cd3faa (the catch-up not reading the
        # previous boot's backlog), on the strength of a FAIL that said "a death WAS recorded and
        # nobody was told". That FAIL came from MY counter being blind: the cell globbed
        # `qwt-report-death*.log` while the reporter writes `qwt-deaths.log`, so deaths_before and
        # deaths_after were always 0. The guest's own log says the opposite -
        #     18:01:00 DEATH #1 NEW Application/4002#339 ... wgcbroker.exe exited without being asked to
        #     18:01:01 DEATH #1 notified to dom0 as wgcbroker.death-1
        # - the death WAS reported. There is no conflict with 95cd3faa to resolve, and no product P1
        # was filed on it. The glob is fixed in all four consumers.
        # WHAT L8 NOW ALSO ASSERTS, because this is where the real defects were: that ONE broker
        # death produces exactly ONE dom0 row. It produced two (wgcbroker.death-1 AND
        # gui-agent.deslice-down), which is the double the owner saw, and the cell now counts both
        # from the writers' own logs. Its window is swept too (cell L8W) - it never was, and
        # "if the sweep was not run, it is same as no sweep".
        # STILL NOT COVERED, and recorded in the ADR rather than implied: item 3 (a forced WaitForQdb
        # timeout and the SCM restart) and item 2's forced-crash-while-up death-1/death-2 numbering.
        # --build: the sweep inside this gate upgrades a golden in L1, so without the package
        # version the analyzer bills the GOLDEN's errors to the candidate and leaves
        # candidate_build_absent unevaluated. matrix.sh has passed it since 2026-10-23; this gate
        # grades the same product and must carry the same dispositions.
        ./mgmt/harness/supervision-e2e.sh --iso "$ISO" --subject "$F11-sup" --golden "$F11-qwt" \
          ${PV:+--build "$PV"} --cells "L1 L9 L2 L8" >>"$WORK/$t.out" 2>&1
        rc=$? ;;
      *)
        # A listed test with no arm would otherwise inherit rc from the PREVIOUS test - a stale PASS (tools/check-cell-coverage.sh
        # also refuses such a list at commit time).
        say "no runner arm for feature test '$t' - tools/release-feature-tests.txt names it"; rc=2 ;;
    esac
    # AN INSTRUMENT FAILURE IS NOT A PRODUCT FAILURE, AND MUST NOT BE READ AS ONE. Every feature
    # test here exits 2 when it could not measure the product at all; this loop used to print FAIL
    # for any nonzero rc, so the 4.3.36 gate recorded crop-before-map (a suite that could not pass
    # at the shipped LogLevel) and template-update (env-assert on a subject nothing could build)
    # as DEFECTS OF THE PRODUCT. Jev, asked what would most change a verdict on the fix for the
    # first of those: gate-classifies-instrument-as-product 0.99.
    # WHAT DOES NOT CHANGE: the run still fails and the acceptance is still NOT recorded, so
    # nothing ships on an instrument failure. A suite that measured nothing has not cleared the
    # product, and treating "could not measure" as a pass is the one outcome worse than either.
    # Each feature test's exit travels into the coverage receipt (step 7), where 2 is INSTRUMENT (uncovered)
    # and any other non-zero is a product failure (covered, result fail) - tools/coverage-receipt.py.
    FEATRCS="${FEATRCS:-} --feature $t=$rc"
    if [ $rc -eq 0 ]; then say "PASS  $t"
    elif [ $rc -eq 2 ]; then say "INSTRUMENT  $t (rc=2 - the suite could not measure the product; this is NOT a product defect, and the run still fails: see $WORK/$t.log)"; MRC=1
    else say "FAIL  $t (rc=$rc, see $WORK/$t.log)"; MRC=1; fi
    # A FEATURE TEST IS PART OF THE RECORDED VERDICT. record-acceptance.sh derives the record from $CAMP/*.out only, so the
    # feature tests used to be invisible to it (rz30 recorded CLEAN with both never run). Each now leaves a cell-group in the
    # campaign dir with matrix.sh's footer; tools/acceptance-record-check.py requires feature-<test> among the recorded cells.
    # The footer stays "0 passed, 1 failed" for BOTH kinds of failure - that is what makes the gate
    # refuse the ISO - and the INSTRUMENT line beside it is what stops a reader attributing it to
    # the product.
    { echo "[$(date -u +%T)]   cells: feature-$t"
      [ $rc -eq 2 ] && echo "[$(date -u +%T)]   INSTRUMENT: feature-$t could not measure the product (rc=2); the run fails, the product is not implicated"
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
# section 4). DERIVED from the campaign's own verdict lines by tools/coverage-receipt.py, never from the
# intended cell list (this block used to name every cell in $CELLS whatever happened - a receipt is a
# record, not an intention). PRODUCT-FAIL and INSTRUMENT-FAIL are told apart (PLAN-acceptance-optimization
# section 6): a cell whose FAIL lines are all INVALID-* and a feature test exiting 2 could not MEASURE the
# product - they are listed under instrument_fail and left OUT of `suites`, so the gate below (and the
# release-cut hook, which re-runs the same check) refuses the cut until they are re-run; a FAIL line that
# names the product is covered (it ran and measured) with result=fail, and the acceptance RECORD refuses
# the cut (Jev 2026-10-13: covered-with-fail-flag 0.94).
COVHEAD=$(git rev-parse HEAD 2>/dev/null | cut -c1-12)
if [ -n "$COVHEAD" ]; then
  COVFILE="scratchpad/gate-coverage-$COVHEAD.json"
  mkdir -p scratchpad
  GSBASE=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD^ 2>/dev/null || git rev-list --max-parents=0 HEAD 2>/dev/null)
  # package-verify is rc 0 here by construction: step 3 dies on any other outcome before a guest is touched.
  # shellcheck disable=SC2086  # FEATRCS is a list of --feature name=rc words
  if python3 tools/coverage-receipt.py --out "$COVFILE" --campaign "$CAMP" --cells "$CELLS" ${FEATRCS:-} \
       --package-verify-rc 0 --package-run "$RUN" --built-from "$HEAD" --range "${GSBASE:-?}..$(git rev-parse HEAD)" >>"$LOG" 2>&1; then
    say "coverage receipt: $COVFILE - $(python3 -c "import json,sys;r=json.load(open(sys.argv[1]));print('covered %d, product_fail %s, instrument_fail %s, not_run %s' % (len(r['suites']), r['product_fail'] or '-', r['instrument_fail'] or '-', r['not_run'] or '-'))" "$COVFILE")"
  else
    say "FAIL  coverage receipt could not be written (see $LOG) - no receipt, no cut"; MRC=1
  fi
  if [ -f tools/gate-scope.py ] && [ -s "$COVFILE" ]; then
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
