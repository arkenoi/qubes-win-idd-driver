#!/bin/bash
# GATE REMAINDER - the six suites tools/release-acceptance.sh does not cover, and the receipt merge
# that makes a FULL gate reachable at all.
#
# WHY THIS EXISTS, MEASURED 2026-10-08. `tools/release-acceptance.sh` writes
# scratchpad/gate-coverage-<build tag>.json naming package-verify, its cells, and the three feature
# tests - twelve suites. `tools/gate-scope.py required` asks for EIGHTEEN whenever the diff touches an
# unmapped path, which is most releases. A twelve-suite receipt was fed to `gate-scope.py check` and
# refused, correctly, naming the six with no producer:
#     failproof-gates  failproof-faultinject  gate-preflight  p3a-etw-gate  toast-hold-test  log-sweep
# So the sanctioned path could not produce a receipt that satisfies its own floor. This runs those
# six and MERGES the ones that PASSED into the same receipt.
#
# IT DOES NOT CUT THE RELEASE and it never writes a suite it did not see pass: a receipt is a record,
# not an intention (docs/ADR-acceptance.md section 4).
#
# Usage:
#   tools/gate-remainder.sh --run <release-package-run-id> --vm10 <win10 subject>
#                           --vm11 <win11 subject> --os11 <label, golden is <label>-qwt>
#                           [--fi-run <qwt-full-fault-injection-run>] [--dry]
#
# The three targets are REQUIRED - there are no default targets here (lint L10).
#
# --dry resolves every variable and prints every command without touching a guest. Run it first.
. "$(dirname "$0")/../mgmt/harness/shutdown-lib.sh" 2>/dev/null || true
# settle() shuts guests down between suites, so it needs the per-guest lock (lint L2).
. "$(dirname "$0")/../mgmt/harness/vmlock.sh" 2>/dev/null || true
. "$(dirname "$0")/../mgmt/harness/primitives.sh" 2>/dev/null || true   # clock_correct and the other five
# verdict_class is this project's classifier for a verdict TEXT, and the only code that knows
# FAIL-MINE is an INSTRUMENT class rather than a product FAIL. suite_class below reads a ledger
# THROUGH it instead of re-deciding here which spellings mean what.
. "$(dirname "$0")/../mgmt/harness/verdict-lib.sh" 2>/dev/null || true
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

RUN=""; FIRUN=""; DRY=0
# NO DEFAULT TARGETS (tools/lint-harness.py L10, and the rule that made matrix.sh refuse an unset
# B10): a default target is wrong in almost every run, and a harness that guesses one churns a
# guest the caller did not mean. Name them with --vm10/--vm11/--os11 or be refused below.
VM10=""; VM11=""; OS11=""
# --only <suite>: run ONE of the six and merge only that one. The receipt stays honest because the
# merge below never writes a suite it did not see pass, so a narrowed run produces a narrowed
# record, not a fuller one. It exists because this gate reserves the rig for every REQUIRED suite -
# four of them on a typical range - and "re-exercise the one suite I just changed" was otherwise
# only reachable by hand-driving the cell outside its orchestrator.
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run)    RUN="${2:-}"; shift 2 ;;
    --fi-run) FIRUN="${2:-}"; shift 2 ;;
    --vm10)   VM10="${2:-}"; shift 2 ;;
    --vm11)   VM11="${2:-}"; shift 2 ;;
    --os11)   OS11="${2:-}"; shift 2 ;;
    --only)   ONLY="${2:-}"; shift 2 ;;
    --dry)    DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$RUN" ]  || { echo "ERROR: --run <release-package-run-id> is required" >&2; exit 2; }
[ -n "$VM10" ] || { echo "ERROR: --vm10 <win10 subject> is required - there is no default target" >&2; exit 2; }
[ -n "$VM11" ] || { echo "ERROR: --vm11 <win11 subject> is required - there is no default target" >&2; exit 2; }
[ -n "$OS11" ] || { echo "ERROR: --os11 <label, the golden is <label>-qwt> is required - there is no default target" >&2; exit 2; }

# THE IDENTITY IS THE BUILD TAG OF --run, NEVER HEAD (docs/ADR-acceptance.md section 7; owner
# 2026-11-11: «we are not accepting "head", we accept a precise build»). Until this date COVFILE and
# OUTDIR were named by `git rev-parse HEAD` - the harness checkout - so a harness commit between the
# campaign and this gate put the two halves of one build's coverage in two files, and the merge below
# wrote the harness sha as `built_from`. The tag is resolved offline when it exists and created
# (verified, idempotent, local) when it does not - the same tool the acceptance uses first. A DRY run
# creates nothing: without a tag every variable below (range, receipt, outdir) is underived, so it
# says so and stops rather than print a chain about a build it cannot name.
BUILDTAG=$(tools/build-tag.sh resolve "$RUN" 2>/dev/null) || {
  if [ "$DRY" = 1 ]; then
    echo "ERROR: no local build tag names run $RUN and a dry run creates none - run 'tools/build-tag.sh create $RUN' first" >&2; exit 2
  fi
  BUILDTAG=$(tools/build-tag.sh create "$RUN") || exit 2
}
BUILDSHA=$(git rev-parse --verify --quiet "refs/tags/${BUILDTAG}^{commit}") || exit 2
HARNESS=$(git rev-parse HEAD) || exit 2   # the provenance of this run's verdicts, recorded per module - never a name
COVFILE="scratchpad/gate-coverage-$BUILDTAG.json"
OUTDIR="$HOME/qwt-accept/remainder-$BUILDTAG"
WORK="$OUTDIR/work"
DL="$OUTDIR/dl"
SETUP="$DL/qwt-improved-setup"
LOG="$OUTDIR/remainder.log"
# /tmp IS RAM ON THIS QUBE (1 GB tmpfs) - a full one gets a long run OOM-killed mid-suite.
export TMPDIR="${TMPDIR:-$HOME/tmp}"

say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
# WHY THE CLASS COMES FROM THE LEDGER AND NOT FROM $?. MEASURED 2026-11-07, one complete chain run
# at a3dfdd79a00a: failproof-faultinject wrote `INVALID-INSTRUMENT: the pixel witness read FROZEN
# with NOTHING armed ... so no red here is attributable` and exited 1, and failproof-gates wrote
# `INVALID-INSTRUMENT` with `ABORTING: SG4 is not green at baseline, so no later red is
# attributable` and exited 1. Both were reported here as `FAIL <suite>` - as the PRODUCT failing,
# which is the one thing a blind instrument cannot tell you.
# AN EXIT CODE CANNOT CARRY THIS DISTINCTION HERE, because two conventions exist in this apparatus
# and they are INVERTED: mgmt/harness/verdict-lib.sh:65-69 reads 1 as EXECUTED-WITH-GAPS and 2 as
# BROKEN, while tools/release-acceptance.sh's logvol arm reads 2 as INVALID-RIG and every other
# non-zero as a product FAIL. Renumbering the suites would move the ambiguity, not remove it
# (Jev classifier_source=verdict_ledger 0.99, renumber_exits 0.00), and the suites ALREADY declare
# the class per row, in column 3 of their verdict ledger. Read that.
# ITS REACH IS EXACTLY THE SUITES WHOSE OUTDIR IS $WORK/<label>, which today is the two failproof
# suites - the two that exhibited this. Every other suite has no ledger at that path, gets NONE,
# and is classified exactly as before. A ledger that is missing, empty or unclassifiable is a FAIL
# too: "no row" must never read as "not a failure".
suite_class() {      # suite_class <label> -> FAIL (product) | INVALID (could not measure) | NONE
  local f="$WORK/$1/verdicts.tsv" v worst=NONE
  declare -F verdict_class >/dev/null 2>&1 || { echo NONE; return; }
  [ -s "$f" ] || { echo NONE; return; }
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$(verdict_class "$v")" in
      FAIL)    worst=FAIL ;;                        # one product FAIL outranks every gap
      INVALID) [ "$worst" = FAIL ] || worst=INVALID ;;
    esac
  done < <(awk -F'\t' 'NF>=3 {print $3}' "$f")
  echo "$worst"
}

run_it() {           # run_it <label> <cmd...>  - never `cmd | tee`, which reports TEE's status
  local label="$1"; shift
  if [ "$DRY" = 1 ]; then echo "INTEND[dry] $label: $*" | tee -a "$LOG"; return 0; fi
  say "--- $label"
  "$@" >>"$WORK/$label.out" 2>&1
  local rc=$?
  if [ "$rc" = 0 ]; then say "PASS  $label"
  elif [ "$(suite_class "$label")" = INVALID ]; then
    say "UNCOVERED  $label (exit $rc) - its ledger declares INVALID-* and no product FAIL: it could"
    say "           not measure, so nothing here is a verdict about the product. See $WORK/$label.out"
  else say "FAIL  $label (exit $rc) - see $WORK/$label.out"; fi
  return $rc
}

mkdir -p "$OUTDIR" "$WORK" "$DL" || exit 2
say "=== gate remainder for $BUILDTAG (run $RUN, built from ${BUILDSHA:0:12}; harness ${HARNESS:0:12}; dry=$DRY) ==="

# ---- what the PACKAGE's diff requires, and which of it is still missing --------------------------
# The range is the newest release tag before the BUILD commit, to the build commit - the same one
# tools/cut-release.sh and tools/hooks/release-cut-gate.sh compute. It was <newest v4.3 tag at HEAD>..HEAD.
BASE=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "${BUILDSHA}^" 2>/dev/null || git rev-list --max-parents=0 "$BUILDSHA" 2>/dev/null)
[ -n "$BASE" ] || { say "ERROR: no release tag before ${BUILDSHA:0:12} to diff against"; exit 2; }
RANGE="${BASE}..${BUILDSHA}"
say "range: $BASE..${BUILDSHA:0:12} (the package's diff)"
REQ=$(python3 tools/gate-scope.py required "$RANGE" 2>/dev/null \
        | sed -n 's/^    \([a-z0-9][a-z0-9-]*\) .*/\1/p' | sort -u)
[ -n "$REQ" ] || { say "ERROR: gate-scope named no suites - refusing to guess"; exit 2; }
say "gate-scope requires: $(echo $REQ | tr '\n' ' ')"
if [ -n "$ONLY" ]; then
  if echo "$REQ" | tr ' ' '\n' | grep -qx "$ONLY"; then
    say "--only $ONLY: running that suite alone; every other required suite is left UNRUN and this"
    say "          receipt therefore cannot satisfy the full gate floor"
  else
    echo "ERROR: --only $ONLY is not in the required scope for $RANGE, so running it could not" >&2
    echo "       contribute to this receipt. Required: $(echo $REQ | tr '\n' ' ')" >&2
    exit 2
  fi
fi

# ---- the artifacts the suites consume ----------------------------------------------------------
if [ "$DRY" = 1 ]; then
  say "INTEND[dry] download: gh run download $RUN -n qwt-improved-setup -D $SETUP"
else
  if [ ! -s "$SETUP/install.cmd" ]; then
    rm -rf "$SETUP"
    say "downloading qwt-improved-setup from run $RUN"
    gh run download "$RUN" -n qwt-improved-setup -D "$SETUP" >>"$LOG" 2>&1 \
      || { say "ERROR: could not download the setup tree"; exit 2; }
  fi
  [ -s "$SETUP/install.cmd" ] || { say "ERROR: $SETUP/install.cmd missing"; exit 2; }
fi

# ---- the suites, each named exactly as gate-scope names it --------------------------------------
# Only a suite that RAN and PASSED is recorded. A suite gate-scope does not require is skipped and
# is never recorded either.
PASSED=""; FAILED=""; SKIPPED=""; INTENDED=""; UNCOVERED=""
REPAIRED=""   # subjects make_candidate has already re-upgraded in THIS run (repair once, then refuse)

# SETTLE THE RIG BETWEEN SUITES. Measured 2026-10-09, first non-dry run: toast-hold-test was
# REFUSED because win11-acc was still Running from the suites before it ("REFUSED: these are not
# Halted: win11-acc") - quick-upgrade refuses while any win1* guest is up, by design, and nothing
# here put the previous subject down. tools/release-acceptance.sh already settles before each
# feature test for exactly this reason; the remainder did not.
settle() {            # settle <vm-to-leave-alone>
  local keep="${1:-}" v st
  [ "$DRY" = 1 ] && { echo "INTEND[dry] settle: halt other win1* subjects (keeping ${keep:-none})" | tee -a "$LOG"; return 0; }
  for v in "$VM10" "$VM11" "${OS11}-p3a" "${OS11}-thold"; do
    [ -n "$v" ] || continue
    [ "$v" = "$keep" ] && continue
    st=$(QTEST_VM="$v" tools/qtest state 2>/dev/null | command grep -ao 'power_state=[A-Za-z]*' | head -1)
    [ "$st" = "power_state=Halted" ] && continue
    [ -n "$st" ] || continue                      # no such qube: nothing to settle
    say "    settling: $v is ${st#power_state=} - requesting shutdown"
    # UNDER THE PER-GUEST LOCK (lint L2). This runs BETWEEN suites, so no lock is held and nothing
    # is nested; taking it means a shutdown here can never land underneath another job's boot.
    if vm_lock "$v"; then
      qwt_shutdown "$v" 600 >>"$LOG" 2>&1 || say "    WARN $v did not halt cleanly"
      vm_unlock
    else
      say "    WARN could not lock $v to settle it - leaving it alone"
    fi
  done
}
need() {
  # --only still has to be REQUIRED: running a suite the scope does not ask for cannot contribute to
  # this receipt, and silently accepting the name would read as "it ran and counted".
  if [ -n "$ONLY" ]; then [ "$1" = "$ONLY" ] || return 1; fi
  echo "$REQ" | tr ' ' '\n' | grep -qx "$1"
}

# THE ARTEFACT UNDER TEST MUST BE THE ONE INSTALLED (the evidence rule: running binary hash vs the
# manifest). MEASURED 2026-10-09, and it invalidated a whole gate run: gate-preflight and log-sweep
# grade $VM11 AS IT IS - neither installs anything - and at HEAD fe4337174ba8 that guest was still
# carrying agent 4.3.32.612 while the candidate package was 4.3.36+agent.eb24cb5115ba. The proof is
# in the sweep's own archived logs: every "LogInit: Module version" line reads 4.3.32.612, in a file
# named gui-agent-20261009-190318-3824.log (the pre-4.3.33 name format), and the two keyed-mutex
# ACCESS_LOST error lines the sweep reported as KNOWN-DEFECT PRESENT were written by THAT agent -
# a build predating the fix for them, whose guard (status != DXGI_ERROR_ACCESS_LOST && ...) is
# present in eb24cb5115ba and therefore could not have written them. So the gate spent a full run
# grading a binary that was never the candidate, and reported a fixed defect as present.
# REFUSE rather than install: the subject is prepared by the campaign, and silently upgrading it
# here would hide which step failed to prepare it.
assert_candidate() {  # assert_candidate <vm> - rc 0 = the guest runs the candidate agent
  local v="$1" ref want got
  [ "$DRY" = 1 ] && { echo "INTEND[dry] assert_candidate: $v runs the package's reference gui-agent" | tee -a "$LOG"; return 0; }
  ref=$(find "$SETUP" -iname 'gui-agent.exe' 2>/dev/null | head -1)
  [ -n "$ref" ] || { say "    REFUSING: no reference gui-agent.exe in $SETUP - cannot say what the candidate is"; return 2; }
  want=$(sha256sum "$ref" | cut -d' ' -f1)
  # -EncodedCommand, not -Command with escaped quotes: that form FAILS SILENTLY here (lint L5),
  # and a silent failure in this probe would read as "no gui-agent running" and refuse a good guest.
  local b64
  b64=$(printf '%s' '$p=@(Get-Process -Name gui-agent -ErrorAction SilentlyContinue)
if ($p.Count -gt 0) { Write-Output ("RUNSHA " + (Get-FileHash -LiteralPath $p[0].Path -Algorithm SHA256).Hash) }
else { Write-Output "RUNSHA none" }' | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  # QTEST_BIN is overridable ONLY so both arms of this check are provable off-rig, the same reason
  # mgmt/harness/gate-preflight.sh exposes it. A check whose accept path has never been seen to
  # accept is half a check.
  got=$(QTEST_VM="$v" timeout 240 "${QTEST_BIN:-tools/qtest}" run "cmd /c powershell -NoProfile -EncodedCommand $b64" \
          2>/dev/null | tr -d '\r' | command grep -aoE 'RUNSHA [0-9A-Za-z]+' | head -1 | awk '{print tolower($2)}')
  if [ -z "$got" ] || [ "$got" = none ]; then
    say "    REFUSING: no gui-agent is running on $v, so nothing can be graded on it"
    return 2
  fi
  if [ "$got" != "$want" ]; then
    say "    REFUSING: $v runs gui-agent ${got:0:16} but the candidate is ${want:0:16}"
    say "              ($ref). The subject was never upgraded to the package under test, so any"
    say "              verdict from it would be about another build - which is how a run at"
    say "              fe4337174ba8 reported a FIXED keyed-mutex defect as present."
    return 2
  fi
  say "    $v runs the candidate agent ${got:0:16}"
  return 0
}
# THE SUBJECT THIS SCRIPT CONSUMES, THIS SCRIPT RE-MAKES. The LAST step below installs the injector
# build over $VM11 - deliberately, which is why everything that grades the RELEASE runs before it -
# so after any complete run the subject no longer runs the candidate. The next invocation then
# refused on this gate's OWN leftovers. MEASURED 2026-10-27, run e323a7000a9d: gate-preflight AND
# log-sweep both died with "win11-acc runs gui-agent 5df949d5388e535b but the candidate is
# 911bdd8f2e046516" - 5df949d5 being the injector build this gate had installed at 05:42 of the
# preceding run - and failproof-faultinject aborted with "the subject is dirty". Four of that run's
# six failures were that one fact, and none of them was about the product.
# THE DEFECT WAS NOT A FORGOTTEN STEP, IT WAS A SCRIPT THAT DID NOT SELF-CONTAIN ITS CRITERIA: it
# knew it had overwritten the subject and it knew the next run needs a candidate, and reconciled
# neither - it printed a refusal and left the preparation to whoever ran it. So a mismatch is
# REPAIRED here instead of refused, once per subject per run, with the SAME committed short cycle
# the injector step uses (quick-upgrade over the golden - .claude/skills/rig-cycle; no procedure is
# invented here). Only a repair that fails, or a subject that is still not the candidate after one,
# refuses - and that refusal is now about the guest, not about this script's own last step.
make_candidate() {    # make_candidate <vm> - rc 0 = the guest runs the candidate agent NOW
  local v="$1"
  assert_candidate "$v" && return 0
  if [ "$DRY" = 1 ]; then
    echo "INTEND[dry] make_candidate: quick-upgrade $v to the package under test over $OS11" | tee -a "$LOG"
    return 0
  fi
  case " $REPAIRED " in
    *" $v "*)
      say "    REFUSING: $v was brought to the candidate once already in this run and still is not it"
      return 2 ;;
  esac
  # REPAIR ONLY WHAT THIS GATE ITSELF BROKE. A mismatch has two causes and they are not the same
  # fact: the subject carries the INJECTOR build this script installed (ours, and the next run's
  # problem is our own last step), or it carries some OTHER build - which is the fe4337174ba8 case
  # the header above is about, a caller handing over the wrong guest, and that must still refuse
  # loudly instead of being silently overwritten. The discriminator is the injector's own banner:
  # only a fault-injection build can write `QGAFAULT-INIT build=QGA-FAULT-INJECTION:on`
  # (agent/gui-agent/faultinject.c; mgmt/harness/failproof-faultinject.sh verifies the build from
  # that same line, and mgmt/harness/error-ledger.txt accounts for it on the same grounds).
  # CAPTURED, NOT PIPED INTO grep -q (lint L23, and my own note from 2026-10-14): grep's early exit
  # SIGPIPEs the qrexec client mid-connect, the guest logs QGAVCHANFAIL request dropped, and under
  # pipefail the status is 141 - which here would read as "not the injector build" and refuse a
  # subject this gate could have repaired.
  local fimark
  fimark=$(QTEST_VM="$v" timeout 240 "${QTEST_BIN:-tools/qtest}" run \
             'cmd /c findstr /s /c:"QGAFAULT-INIT build=QGA-FAULT-INJECTION:on" "Q:\Qubes Logs\gui-agent*.log"' \
             2>/dev/null | tr -d '\r')
  if ! printf '%s' "$fimark" | command grep -aoF 'QGA-FAULT-INJECTION:on' >/dev/null; then
    say "    REFUSING: $v runs neither the candidate nor this gate's injector build, so it is not a"
    say "              subject this gate consumed - it is the wrong guest, and overwriting it would"
    say "              hide exactly what the fe4337174ba8 run revealed. Name the right --vm11, or"
    say "              upgrade it: mgmt/harness/quick-upgrade.sh $SETUP $v $OS11"
    return 2
  fi
  say "    $v carries the INJECTOR build this gate installed on its last run - that is ours to undo"
  REPAIRED="$REPAIRED $v"
  say "    $v does not run the candidate - upgrading it to the package under test (quick-upgrade over $OS11)"
  local qurc
  QU_OUT="$WORK/make-candidate-$v" bash mgmt/harness/quick-upgrade.sh "$SETUP" "$v" "$OS11" \
       >>"$WORK/make-candidate-$v.out" 2>&1; qurc=$?
  # rc=4 IS AN INSTALLED PACKAGE, not a failed upgrade: quick-upgrade.sh's finish() exits 4 when
  # every check passed and the error sweep then found something in THIS run's log. `if !` read that
  # as "could not upgrade" and refused a subject already carrying the candidate - the same misread
  # updater-component-test.sh:134 records, at a caller that fix did not name.
  if [ "$qurc" != 0 ] && [ "$qurc" != 4 ]; then
    say "    REFUSING: could not upgrade $v to the package under test (rc=$qurc) - see $WORK/make-candidate-$v.out"
    return 2
  fi
  [ "$qurc" = 4 ] && say "    the upgrade passed every check and the error sweep was not clean (rc=4) - $v carries the candidate, so this gate continues; the findings are in $WORK/make-candidate-$v.out"
  say "    $v upgraded to the package under test"
  ready "$v" || return 2
  assert_candidate "$v"
}
# A DRY RUN HAS NO RESULT TO BUCKET. run_it's dry branch prints its intent and returns 0, so
# `note $?` used to read that 0 as a pass: `--dry` put EVERY suite in PASSED and exited 0 -
# measured over six suites whose command was bash /nonexistent/suite-that-cannot-exist.sh, all
# six PASSED. acceptance-plan.py:202 makes that dry call the remainder cell's first probe, so
# the probe could not fail. Dry results go to INTENDED and nowhere near PASSED.
# A SUITE THAT COULD NOT MEASURE IS NOT IN FAILED. It is not in PASSED either, so the merge below
# still records nothing for it and gate-scope still refuses the cut on coverage - which is the
# correct outcome and the one this run already produced. What changes is only the CLASS the
# operator is told, which is the whole defect.
note() {
  if [ "$DRY" = 1 ]; then INTENDED="$INTENDED $2"
  elif [ "$1" = 0 ]; then PASSED="$PASSED $2"
  elif [ "$(suite_class "$2")" = INVALID ]; then UNCOVERED="$UNCOVERED $2"
  else FAILED="$FAILED $2"; fi
}

# THE SWEEP'S WINDOW IS THIS RUN, NOT TWELVE HOURS OF HISTORY. This said '12 hours ago', which on a
# rig whose guests are reinstalled all day means a window covering OTHER RUNS, OLDER BUILDS and the
# install-era boots - and the sweep would report their lines as this run's findings. Measured
# 2026-10-09: an install-era boot writes early-boot vchan transients (XcStoreRead 0x5,
# libxenvchan_client_init ... ring-ref 0x5, at ~21 s uptime, upstream code, resolved on retry) that a
# normal boot of a provisioned guest does NOT write - zero error lines on two swept guests - so a
# window that reaches back into an install carries them and a window over this run does not. The
# suites below all run after this point, and log-sweep runs last on purpose, so this is the right
# start for it.
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# THE SUBJECT MUST BE UP AND ANSWERING BEFORE A SUITE JUDGES IT. Measured 2026-10-09:
# gate-preflight ran first, right after the campaign, and its own log says "liveness probe 1/3:
# guest did not answer" and then printed NO WDSTART line at all - so the watchdog check had nothing
# to read and the suite graded INVALID-INSTRUMENT. The guest was still settling from the campaign.
# settle() halts the OTHER guests; this makes the named one ready, which is the other half.
ready() {             # ready <vm>
  local v="$1" st i
  [ -n "$v" ] || return 0
  [ "$DRY" = 1 ] && { echo "INTEND[dry] ready: $v up and answering qrexec" | tee -a "$LOG"; return 0; }
  st=$(QTEST_VM="$v" tools/qtest state 2>/dev/null | command grep -ao 'power_state=[A-Za-z]*' | head -1)
  [ -n "$st" ] || { say "    ready: no qube named $v"; return 1; }
  if [ "$st" != "power_state=Running" ]; then
    say "    ready: $v is ${st#power_state=} - starting it"
    if vm_lock "$v"; then timeout 300 qvm-start "$v" >>"$LOG" 2>&1 || true; vm_unlock; fi
  fi
  # qrexec IS NOT THE PRECONDITION THESE SUITES NEED. Measured 2026-10-09 in this script's own log:
  # "ready: win11-acc answers qrexec" at 16:03:19, and gate-preflight FATALed 14 s later because it
  # could not push its restart helper (guest sha256 'none'). The same push by hand a moment later
  # landed with an exact sha match. qrexec answers as SYSTEM early in a boot; a FILE COPY needs the
  # receiver in a logged-on session, which comes later - so proving qrexec and then handing the
  # guest to a suite whose first act is a push proves the wrong thing, and the suite grades the gap
  # as INVALID-INSTRUMENT. Prove the copy itself.
  # `qtest push` already deletes the name on the guest before copying (tools/qtest:152), so a
  # repeated probe does not need a delete of its own - measured here, three pushes of the same
  # name in a row all returned 0. Do not add one back on the theory that the receiver refuses to
  # overwrite: it does refuse, and qtest is where that is handled.
  local pushed=0 probe
  probe="$WORK/ready-probe-$v.txt"
  printf 'READYPROBE %s\n' "$v" > "$probe" 2>/dev/null
  for i in $(seq 1 42); do
    if command grep -qa '^QREADY' <<< "$(QTEST_VM="$v" timeout 40 tools/qtest run 'cmd /c echo QREADY' 2>/dev/null)"; then
      [ "$pushed" = 0 ] && { say "    ready: $v answers qrexec - now proving a file copy"; pushed=1; }
      if QTEST_VM="$v" timeout 90 tools/qtest push "$probe" >>"$LOG" 2>&1; then
        say "    ready: $v takes a file push (the receiver session is up)"; rm -f "$probe"
        # AND ITS CLOCK, BEFORE ANY SUITE READS IT. No in-guest time setting survives a reboot (the
        # domain is destroyed), so these guests come up ~3 h ahead. log-sweep REFUSES a collection
        # whose guest clock is skewed from the host's - measured in this gate's own run, rc=3
        # "clockskew ... the guest's clock is +10837 s from the host's at collection time" - so the
        # sweep produced NO verdict and the receipt stayed empty. qtest synctime pushes this qube's
        # clock in to ~0.3 s and is documented as the call to make after every VM start.
        clock_correct "$v" 120 >>"$LOG" 2>&1 \
          || say "    WARN the clock in $v is not verified - a sweep may refuse on skew"
        return 0
      fi
    fi
    sleep 10
  done
  rm -f "$probe"
  # SAY WHICH EXIT FIRED. These are different failures and lead to different work: no qrexec at all
  # is a dead/unbooted guest, while qrexec-without-a-push is the session gap this probe exists for.
  if [ "$pushed" = 1 ]; then
    say "    WARN $v answers qrexec but never took a file push in 7 min - the suite will grade that"
  else
    say "    WARN $v never answered qrexec in 7 min - the suite will grade that itself"
  fi
  return 1
}

if need gate-preflight; then
  settle "$VM11"; ready "$VM11"
  # NOT A PRODUCT VERDICT: a subject that could not be made the candidate measured nothing, so the
  # suite is UNCOVERED (instrument-fail in the receipt) - a product-fail here would be a MEASURED
  # verdict that the merge rule keeps against a later pass from the same harness.
  if ! make_candidate "$VM11"; then
    say "UNCOVERED  gate-preflight (subject is not the candidate - nothing measured)"; UNCOVERED="$UNCOVERED gate-preflight"
  else
  # <vm> <hex-bits>: the preflight bit-mask the suite documents; 0 exercises the no-fault path.
  run_it gate-preflight bash mgmt/harness/gate-preflight.sh "$VM11" 0; note $? gate-preflight
  fi
else SKIPPED="$SKIPPED gate-preflight"; fi

if need p3a-etw-gate; then
  # toastfire.exe comes from the `build` workflow, NOT from release-package: it is a TEST helper
  # that fires toasts and has no business shipping inside the product. p3a-etw-gate looks for it in
  # the setup tree and then accepts a TOASTFIRE= override; on the first non-dry run it found neither
  # and died "FATAL toastfire.exe not in <setup>". So the gate fetches it from the build run at the
  # BUILD commit - the package's own commit, not the harness checkout's - and passes it explicitly.
  TF="${TOASTFIRE:-}"
  if [ -z "$TF" ]; then
    TFDIR="$DL/toastfire"
    if [ "$DRY" = 1 ]; then
      say "INTEND[dry] download toastfire from the build run at the build commit ${BUILDSHA:0:12}"
    else
      BRUN=$(gh run list -w build -L 20 --json databaseId,headSha,conclusion \
               -q "[.[]|select(.conclusion==\"success\" and (.headSha|startswith(\"${BUILDSHA:0:12}\")))][0].databaseId" 2>/dev/null)
      if [ -n "$BRUN" ] && [ "$BRUN" != "null" ]; then
        # ARTIFACT `gui-agent-package`, NOT `toastfire`. This asked for -n toastfire, which is not an
        # artifact that run publishes (it has idd-driver-package, gui-agent-package and
        # qwt-improved-package), so the download failed, `|| true` swallowed it and the find came
        # back empty - reported as "no toastfire.exe for HEAD", i.e. a missing helper rather than a
        # wrong name. mgmt/harness/toast-hold-test.sh already had it right and fetched the same exe
        # from gui-agent-package in the same run, which is how the two disagreed in one log.
        [ -d "$TFDIR" ] || gh run download "$BRUN" -n gui-agent-package -D "$TFDIR" >>"$LOG" 2>&1 || true
        TF=$(find "$TFDIR" -iname 'toastfire.exe' 2>/dev/null | head -1)
      fi
      [ -n "$TF" ] && say "    toastfire from build run $BRUN: $TF" \
                   || say "    WARN no toastfire.exe for the build commit ${BUILDSHA:0:12} - p3a-etw-gate will refuse, as it should"
    fi
  fi
  settle "${OS11}-p3a"
  # THE BASE IS A -base GOLDEN, NOT -qwt. This suite primes a FRESH guest and then asserts rule 1,
  # "the artefact under test is what is actually installed" - and a -qwt golden ALREADY carries QWT,
  # so prime-run's `ours` job installs nothing, qrexec answers, prime-run says "the job is genuinely
  # finished" and the subject runs the GOLDEN's build. MEASURED 2026-10-27 on 56bfc6b8: win11r-p3a
  # came up with notifhost.exe ee7dea7e against the package's 153d421f, the guest's captured
  # qwt-improved-install.log was dated 2026-10-15 reporting package_version 4.3.35, and the hash was
  # STILL ee7dea7e an hour later on a fresh boot - so it was not a race, nothing was installed.
  # The suite's own header says base default win10-base, and .claude/skills/rig-cycle puts the
  # clean-install path on prime-run FROM A BASE. gate-scope has never recorded this suite as
  # covered (the best receipt, 4.3.35, is also missing it), which is what a suite that cannot
  # reach its own precondition looks like from the outside.
  TOASTFIRE="$TF" run_it p3a-etw-gate bash mgmt/harness/p3a-etw-gate.sh "$SETUP" "${OS11}-p3a" "${OS11}-base"
  note $? p3a-etw-gate
else SKIPPED="$SKIPPED p3a-etw-gate"; fi

if need toast-hold-test; then
  settle "${OS11}-thold"
  # S5 (the dom0 qubes.SetGuiMode round trip) is OPT-IN in that suite and this gate does not ask for
  # it: it maps the whole guest desktop as one dom0 window, and this gate runs unattended (owner
  # 2026-10-06, "why i see near-fullscreen windows again"). Say so here, so the gate's own log
  # carries the coverage this run does not have rather than leaving it to the suite's verdict file.
  say "    note: toast-hold S5 (whole-desktop SetGuiMode round trip) is NOT exercised by this gate -"
  say "          it takes over the screen. Run the suite with --nonseamless deliberately for S5a/S5c."
  # THE LEDGER suite_class READS. toast-hold writes an INVALID-INSTRUMENT row there when a GitHub
  # artifact download fails (2026-11-11: an HTTP 502 was graded `FAIL toast-hold-test`). Emptied before
  # EVERY attempt: a row left by the first attempt would grade a product FAIL of the retry as UNCOVERED.
  THL="$WORK/toast-hold-test/verdicts.tsv"; mkdir -p "${THL%/*}"
  rm -f "$THL"; run_it toast-hold-test env TH_LEDGER="$THL" bash mgmt/harness/toast-hold-test.sh --run "$RUN" --os "$OS11"; thrc=$?
  # ONE RETRY, DRIVEN BY THE REFUSAL'S OWN TEXT. quick-upgrade refuses while ANY win1* guest is up,
  # and settle() above only knows the guests THIS gate names. Measured 2026-10-09: it refused with
  # "REFUSED: these are not Halted: win11r-up" - a leftover from other work on the rig, which no
  # static list here could have predicted. Rather than enumerate every qube (forbidden: that fires
  # an admin call at each one, dom0 and this qube included), take the names out of the refusal,
  # settle those, and retry once. A refusal naming nothing, or a second failure, is graded as before.
  # The rc is captured in thrc: `note $?` after an `if` would read the BLOCK's status, not the suite's.
  if [ "$DRY" = 0 ] && [ "$thrc" != 0 ]; then
    stuck=$(command grep -aoE 'these are not Halted:[^"]*' "$WORK/toast-hold-test.out" 2>/dev/null \
              | head -1 | sed 's/these are not Halted://')
    if [ -n "${stuck// /}" ]; then
      say "    toast-hold-test was refused over guests it does not own:${stuck} - settling them by name"
      for v in $stuck; do
        if vm_lock "$v"; then qwt_shutdown "$v" 600 >>"$LOG" 2>&1 || say "    WARN $v did not halt cleanly"; vm_unlock
        else say "    WARN could not lock $v to settle it"; fi
      done
      rm -f "$THL"; run_it toast-hold-test env TH_LEDGER="$THL" bash mgmt/harness/toast-hold-test.sh --run "$RUN" --os "$OS11"; thrc=$?
    fi
  fi
  note "$thrc" toast-hold-test
else SKIPPED="$SKIPPED toast-hold-test"; fi

if need log-sweep; then
  settle "$VM11"; ready "$VM11"
  if ! make_candidate "$VM11"; then
    say "UNCOVERED  log-sweep (subject is not the candidate - nothing measured)"; UNCOVERED="$UNCOVERED log-sweep"
  else
  # LAST, deliberately: it reads what every suite above wrote into the guest's logs.
  # DECLARE THE NOTIFICATIONS THE ACCEPTANCE SUITES FIRE ON PURPOSE, or this sweep counts them as
  # user-visible failures of the product. MEASURED 2026-10-16 on win11-nfy: dom0_loud_failures
  # breached at 6 (P1) and ALL SIX were toasts a suite had fired deliberately - that guest had just
  # been through notify-errors-guest-test, which exists to put user-visible error notifications on
  # the dom0 desktop and ends on a photograph of one. Zero were the product reporting its own
  # failure. The summaries are literals in mgmt/harness/notify-errors-guest-test.sh (its gate check,
  # its ACTION/once-per-boot probes, the render witness trigger, and check 8's deferral probe).
  # A DECLARATION IS NOT AN EXCUSE: anything NOT matching still counts, which is what keeps a real
  # product toast P1.
  # TOLERATED, NOT CAUSED, AND THAT IS THE WHOLE CORRECTION. The discriminator is GUARANTEE, not who
  # caused the line (mgmt/harness/log-sweep.sh, Jev 0.90): a caused declaration claims a stimulus was
  # applied, so matching nothing is a breach. THIS GATE DOES NOT RUN notify-errors-guest-test - its
  # suites are the six at the top of this file - so it applies no such stimulus and cannot guarantee
  # one line of it. Whether $VM11 carries any depends on what ran on that subject before, which is a
  # property of the caller's fixture, not of this run. MEASURED, run 40407378739 on win11-acc
  # 2026-10-27: declared_errors_unmatched=1 with `matched: 0` failed log-sweep on the declaration
  # alone, on a subject whose product wrote error_lines=0 - the same mistake matrix.sh records at its
  # own three declarations ("as --declare-error it failed win10-appvm, a cell whose product wrote
  # ZERO error lines"). The caused form belongs to whoever FIRES these, beside the suite that does.
  run_it log-sweep bash mgmt/harness/log-sweep.sh "$VM11" "$SINCE" "$WORK/log-sweep" \
    --tolerate-error 'summary=(gate default check|acceptance probe|Render witness|deferproof-)' \
                     'notifications the acceptance suites fire on purpose (notify-errors-guest-test and its deferral probe) - not the product reporting a failure. TOLERATED: this gate does not run that suite, so their absence proves nothing about the product'
  note $? log-sweep
  fi
else SKIPPED="$SKIPPED log-sweep"; fi

# --------------------------------------------------------------- the fault-injection suites, LAST
# ORDER IS DELIBERATE. These two need an INSTALLED injector build, and installing it replaces the
# release binaries on the subject - so everything that grades the RELEASE runs first and these run
# at the end. Before 2026-10-09 they ran third and refused outright, because nothing installed
# anything: the qwt-full artifact is not an installable tree. release-package.yml now accepts
# fault_injection, so --fi-run names a run whose qwt-improved-setup carries the injector and goes
# in through the ordinary install path. cut-release.sh refuses to publish such a package.
fi_installed=0
if need failproof-gates || need failproof-faultinject; then
  if [ -z "$FIRUN" ]; then
    say "SKIP  failproof-gates/failproof-faultinject: no --fi-run. Dispatch release-package with"
    say "      -f fault_injection=true and pass its run id; an ordinary package cannot inject a"
    say "      fault and recording a pass from one would be vacuous."
  else
    FISETUP="$DL/fi-setup/qwt-improved-setup"
    if [ "$DRY" = 1 ]; then
      say "INTEND[dry] download: gh run download $FIRUN -n qwt-improved-setup -D $FISETUP"
      say "INTEND[dry] install the injector tree on $VM11 via quick-upgrade"
      fi_installed=1
    else
      # THE DOWNLOAD'S OWN ANSWER IS SAID. This was `|| true` followed by a guess, and on 2026-11-11 the
      # guess ("was it dispatched with fault_injection=true?") was wrong: the run carried the artifact,
      # and api.github.com had answered `HTTP 502: Server Error`.
      fidl_out=""
      [ -s "$FISETUP/install.cmd" ] || fidl_out=$(gh run download "$FIRUN" -n qwt-improved-setup -D "$FISETUP" 2>&1)
      [ -n "$fidl_out" ] && printf '%s\n' "$fidl_out" >> "$LOG"
      if [ ! -s "$FISETUP/install.cmd" ] && [ -n "$fidl_out" ]; then
        say "ERROR: could not download qwt-improved-setup from run $FIRUN: $(printf '%s' "$fidl_out" | tail -1)"
      elif [ ! -s "$FISETUP/install.cmd" ]; then
        say "ERROR: run $FIRUN has no installable qwt-improved-setup - was it dispatched on"
        say "       release-package with -f fault_injection=true? (qwt-full alone is not installable)"
      elif ! python3 - "$FISETUP/reference/gui-agent.exe" <<'FIMARK'
import sys
b=open(sys.argv[1],'rb').read(); m=b'QGA-FAULT-INJECTION:on'
sys.exit(0 if (b.count(m)+b.count(m.decode().encode('utf-16-le'))) else 1)
FIMARK
      then
        say "ERROR: run $FIRUN's agent does NOT carry the injector marker - it is an ordinary"
        say "       package, so both suites would come back green for the wrong reason."
      else
        settle "$VM11"
        say "--- installing the injector tree on $VM11 (its agent carries QGA-FAULT-INJECTION:on)"
        QU_OUT="$WORK/fi-install" bash mgmt/harness/quick-upgrade.sh "$FISETUP" "$VM11" "$OS11" \
             >>"$WORK/fi-install.out" 2>&1; firc=$?
        # rc=4 IS AN INSTALLED INJECTOR (see make_candidate above). Read as a failure it left
        # fi_installed=0, and the two branches below then SKIPPED BOTH failproof suites over a guest
        # that was carrying the injector build - which is how campaign 42400226595 produced no
        # failproof-faultinject row at all, the only instrument for the agent fix under test.
        if [ "$firc" = 0 ] || [ "$firc" = 4 ]; then
          say "    injector build installed"; fi_installed=1
          [ "$firc" = 4 ] && say "    the install passed every check and the error sweep was not clean (rc=4) - the findings are in $WORK/fi-install.out"
          # SAID OUT LOUD because it is the state the next run inherits: from here on $VM11 is
          # NOT the release build, and make_candidate above is what puts it back.
          say "    NOTE: $VM11 now carries the INJECTOR build, not the release - the next run of"
          say "          this gate re-makes it (make_candidate), it is not a guest to grade a release on"
        else
          say "    FAIL could not install the injector tree (rc=$firc) - see $WORK/fi-install.out"
        fi
      fi
    fi
  fi
fi

if need failproof-gates && [ "$fi_installed" = 1 ]; then
  run_it failproof-gates bash mgmt/harness/failproof-gates.sh "$VM11" "$WORK/failproof-gates"
  note $? failproof-gates
else SKIPPED="$SKIPPED failproof-gates"; fi

if need failproof-faultinject && [ "$fi_installed" = 1 ]; then
  # No download here: this suite reads nothing from a directory (it has zero references to FI_DIR).
  # Its prerequisite is the INSTALLED injector build, which the step above put on the subject, and
  # it verifies that itself from the running agent's QGAFAULT-INIT banner before grading anything.
  run_it failproof-faultinject bash mgmt/harness/failproof-faultinject.sh "$VM11" "$WORK/failproof-faultinject"
  note $? failproof-faultinject
else SKIPPED="$SKIPPED failproof-faultinject"; fi


say "passed:$PASSED"
say "intended:$INTENDED"
say "failed:$FAILED"
say "uncovered:$UNCOVERED"
say "skipped:$SKIPPED"

# ---- merge into the receipt the release-cut gate reads -----------------------------------------
# THROUGH tools/coverage-receipt.py AND ITS ONE MERGE RULE (docs/ADR-acceptance.md section 7). Until
# 2026-11-11 this block was an inline python of its own: it unioned `suites`, wrote the HARNESS sha as
# `built_from`, and recorded nothing for a suite that failed. Every suite that RAN is now recorded
# with its class - PASSED -> pass, FAILED -> product-fail (measured: the product failed), UNCOVERED ->
# instrument-fail (nothing measured) - and the rule decides what the receipt keeps: a measured verdict
# stands against an instrument-fail or a not-run; a measured verdict replaces an unmeasured one; a
# measured verdict replaces an earlier measured one ONLY from a different harness commit, so an
# instrument fix takes effect and a no-change re-run cannot turn a product-fail green. A suite this
# run SKIPPED is not named, and the receipt keeps whatever it held for it. ONLY is passed so a receipt
# ASSEMBLED PIECEMEAL says so under narrowed_runs (measured 2026-10-27: without it the receipt could
# not tell one campaign from four one-suite runs settled differently).
if [ "$DRY" = 1 ]; then
  say "INTEND[dry] merge into $COVFILE:$INTENDED"
else
  MODS=""
  for s in $PASSED;    do MODS="$MODS --module $s=pass"; done
  for s in $FAILED;    do MODS="$MODS --module $s=product-fail"; done
  for s in $UNCOVERED; do MODS="$MODS --module $s=instrument-fail"; done
  if [ -z "$MODS" ]; then
    say "nothing ran, so nothing is merged into $COVFILE"
  else
    # shellcheck disable=SC2086  # MODS is a list of --module words
    python3 tools/coverage-receipt.py --out "$COVFILE" --build "$BUILDTAG" --package-run "$RUN" ${FIRUN:+--fi-run "$FIRUN"} \
        --fi-module failproof-gates --fi-module failproof-faultinject --range "$RANGE" --harness "$HARNESS" --run "$WORK" \
        ${ONLY:+--narrowed "$ONLY"} $MODS 2>&1 | tee -a "$LOG"
    [ "${PIPESTATUS[0]}" = 0 ] || say "ERROR: the receipt was not written (tools/coverage-receipt.py refused, above) - the cut cannot read this run"
  fi
  say "--- does the receipt now satisfy the gate?"
  python3 tools/gate-scope.py check "$COVFILE" "$RANGE" 2>&1 | tee -a "$LOG"
  CHK=${PIPESTATUS[0]}
  if [ "$CHK" = 0 ]; then say "GATE SATISFIED for $BUILDTAG"; else say "GATE NOT YET SATISFIED for $BUILDTAG (exit $CHK)"; fi
fi

# THE EXIT CONTRACT IS DELIBERATELY UNCHANGED: every input that exited 1 before still exits 1,
# because an uncovered suite was in FAILED until this commit. Whether an instrument-only run
# should get its own code is NOT settled - Jev instrument_only_exit came back 0.53, and 0.21 with
# the leading option flipped once the chain's own exit composition was in the state - so it was
# not taken on a verdict. It was taken on "no unrequested behaviour changes": the defect measured
# here is the class this gate REPORTS, not the code it returns.
[ -z "$FAILED$UNCOVERED" ] || exit 1
exit 0
