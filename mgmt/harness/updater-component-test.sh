#!/usr/bin/env bash
# updater-component-test.sh - THE UPDATER AS ONE COMPONENT, GRADED FAST, ON THE REPORTER'S LOCALE.
#
# WHY THIS EXISTS (owner, 2026-10-22): "we would need to split clean the acceptance matrix to do
# quick per-component grading. code the standalone updater testing now. using gwecks golden as a
# base makes sense to make sure locales are handled." And: "it is mostly what you do now by hand but
# systemic, verified and repeatable."
#
# What it replaces is a sequence I ran BY HAND that morning to prove the relay fix: push the deploy,
# read three log lines, probe the installed exe's bytes, start a scan, catch the listener, read
# agent.log for the reported count. Every step was a judgement made in the moment, and two of those
# steps were WRONG in a way that read as a pass (an anchor matching nothing in install.log; a
# receipt that moved two variables at once). A hand sequence cannot be re-run, cannot be graded and
# cannot be seen to fail. This is all three.
#
# IT IS THE QUICK HALF OF A TWO-PHASE DESIGN (owner: "BEFORE the full sequence starts, we want quick
# check if main functionality passes without failure"). The same gates run here standalone, in
# minutes, AND as the preflight inside mgmt/harness/template-update-test.sh, which then goes on to
# the full dom0-driven sequence with its progress and exit codes. One implementation of the gates,
# in mgmt/harness/updater-gates-lib.sh, used by both - a copied grader drifts, and the copy that
# drifts is the one that stops catching the defect.
#
# THE BASE IS GWeck's SEALED GERMAN 25H2 TEMPLATE (win11de-qwt), for two non-interchangeable reasons:
#   * the proxied updater serves TemplateVMs ONLY - a StandaloneVM answers "the qubes proxy updater
#     is template-only and never runs here" and does nothing (measured on win11r-relayval
#     2026-10-22 11:36:23), so a StandaloneVM subject can never grade this component;
#   * LOCALE. Windows speaks German there ("ERFOLGREICH:", "NT-AUTORITÄT\SYSTEM"), so a predicate
#     matching an English Windows string passes nothing. Every gate reads OUR OWN log lines, which
#     we emit in English, or a number - never Windows' prose. env-assert.sh holds the environment
#     itself to the reporter's record.
#
# THE GATES (U1..U7) and their discriminator-based DIAGNOSIS live in the library; see its header.
# The main flow is deterministic and self-contained. On a failure it additionally asks Jev for
# supplementary data - which cause the evidence most supports, and how strongly - because a
# probability is a classification and classifications belong to the classifier of record. That call
# never changes the gate verdict (owner: "the main flow should stay determenistic and self
# contained, but we SHOULD ask jev for supplementary data").
#
# Exit 0 PASS, 1 FAIL (the product), 2 INSTRUMENT (no verdict was produced - never a pass).
#
# EVAL_ONLY=<dir> grades a captured evidence dir and TOUCHES NO RIG AND NO NETWORK, which is how
# tools/tests/updater-component-selftest.sh drives all seven gates against the REAL pre-fix and
# post-fix captures of 2026-10-22 - the pre-fix pair must FAIL and each gate must fail alone.
set -uo pipefail
cd /home/user/qubes-win-idd-driver || exit 2
source mgmt/harness/updater-gates-lib.sh

FAMILY="${FAMILY:-win11de}"              # the golden is <FAMILY>-qwt: GWeck's sealed German 25H2 TemplateVM
REPORTER="${REPORTER:-gweck}"            # mgmt/reporters/<name>.json
GOLDEN="$FAMILY-qwt"

if [ -n "${EVAL_ONLY:-}" ]; then
  VM="${VM:-eval-only}"; PKG="${PKG:-none}"; OUT="$EVAL_ONLY"
  LOG="${LOG:-$OUT/verdict.log}"
else
  VM="${VM:?set VM to the subject to create - there is no default target}"
  PKG="${PKG:?set PKG to the release setup tree or ISO under test}"
  LOG="${LOG:-/home/user/qwt-accept/updater-component-$VM.log}"
  OUT="${OUT:-${LOG%.log}.d}"
fi
mkdir -p "$OUT" 2>/dev/null || { echo "FATAL: cannot create $OUT"; exit 2; }
say(){ echo "[$(date -u +%H:%M:%S)] updater-component[$VM]: $*" | tee -a "$LOG"; }

report(){ # the deterministic verdict, then the diagnosis, then (live only) Jev's supplement
  printf '%s' "$UG_LINES" | tee -a "$LOG"
  say "gates: $UG_PASS passed, $UG_FAIL failed"
  updater_gates_diagnose "$OUT"
  printf '%s' "$UG_DIAG" | tee -a "$LOG"
  if [ "$UG_FAIL" -gt 0 ] && [ -z "${EVAL_ONLY:-}" ]; then
    say "asking Jev for supplementary data on the root cause (this does not change the verdict)"
    updater_gates_jev "$OUT"
    printf 'JEV (secondary evaluator, supplementary):\n%s\n' "$UG_JEV" | tee -a "$LOG"
  fi
}

if [ -n "${EVAL_ONLY:-}" ]; then
  say "EVAL_ONLY: grading $OUT - no rig, no network"
  updater_gates_grade "$OUT" "$REPORTER"; rc=$?
  report
  case $rc in 0) say "VERDICT: PASS" ;; 1) say "VERDICT: FAIL" ;; *) say "VERDICT: INSTRUMENT" ;; esac
  exit $rc
fi

# ---------------------------------------------------------------------------------------------
# LIVE. Serial, locked, and over a CLONE of the sealed golden - a golden is never started.
# ---------------------------------------------------------------------------------------------
source mgmt/harness/vmlock.sh
vm_lock "$VM" || exit 2
say "component test of the updater, package $PKG, over golden $GOLDEN (reporter $REPORTER)"

# 1. install the package over the golden. quick-upgrade.sh is the sanctioned short cycle: it wraps
#    the tree as CI does, runs Gate-0 on the disc, verifies the golden's seal, clones it, installs
#    and verifies the install. Never invent a procedure.
say "step 1/4: quick-upgrade over $GOLDEN"
# STRICT, BY THE OWNER'S CALL: a non-zero quick-upgrade is an INSTRUMENT failure and this test
# stops. There was a version of this that proceeded whenever the install's own two verification
# checks had passed, reasoning that quick-upgrade's rc=3 on 2026-10-22 came from a benign transient.
# That was the wrong instinct - it accommodated a false line instead of closing the gap. The line
# ("the log volume could not be read ... mtools found nothing") was a DEFECT in quick-upgrade's own
# predicate: it read the single newest *.log and gave up when that file was a log the MSI had just
# created and not yet written, while the same pull had recovered 120 files. That predicate is fixed
# at its source; nothing here needs to tolerate it. Owner: "keep it strict, close the gap properly".
# TRUNCATED, NOT APPENDED. This was `>>`, and on 2026-10-22 a re-run inherited the PREVIOUS run's
# "PASS  installed gui-agent.exe == package reference" lines from the same file - so a grep over it
# reported an install that had verified when THIS run's install had been killed at rc=143. A file
# cannot scope a run; the evidence a verdict reads must be this run's bytes only.
: > "$OUT/upgrade.out"
if ! QU_OUT="$OUT/qu" ./mgmt/harness/quick-upgrade.sh "$PKG" "$VM" "$FAMILY" >"$OUT/upgrade.out" 2>&1; then
  say "INSTRUMENT: the package install over $GOLDEN did not pass - the updater was never reached"
  grep -aE '\[ERROR\]|UNACCOUNTED|REFUSED' "$OUT/upgrade.out" | tail -5 | sed 's/^/    /' | tee -a "$LOG"
  exit 2
fi
say "  install: $(grep -aE 'summary:' "$OUT/upgrade.out" | tail -1)"

# 2. the environment, by measurement, before anything is graded on it.
#    BUILD THEN ASSERT, in that order. A bare clone of the golden is NOT the reporter's environment:
#    the golden deliberately carries no Open-Shell, so env-assert alone fails on open_shell_installed
#    and service_enablewinkey - which is exactly how the 4.3.36 release gate exited INSTRUMENT on
#    2026-10-09. reporter-env-build.sh brings the subject up to his record; env-assert must then pass
#    on its own.
say "step 2/4: reporter-env-build then env-assert against reporter $REPORTER"
./mgmt/harness/reporter-env-build.sh "$VM" "$REPORTER" >"$OUT/reporter-env-build.out" 2>&1 \
  || say "  [WARN] reporter-env-build did not complete - see $OUT/reporter-env-build.out"
./mgmt/harness/env-assert.sh "$VM" "$REPORTER" >"$OUT/env-assert.out" 2>&1 \
  || say "  [WARN] env-assert did not pass - U7 will fail and say so"

# 3. one scan pass, and collect the component's own evidence
say "step 3/4: one scan pass, guest-side"
state(){ qvm-ls --raw-data --fields state "$1" 2>/dev/null; }
if [ "$(state "$VM")" != Running ]; then
  qvm-start "$VM" >>"$OUT/collect.out" 2>&1 || { say "INSTRUMENT: could not start $VM"; exit 2; }
fi
updater_gates_collect "$VM" "$OUT" || { say "INSTRUMENT: could not collect the component's evidence"; exit 2; }

# 4. grade
say "step 4/4: grading"
updater_gates_grade "$OUT" "$REPORTER"; rc=$?
report
case $rc in
  0) say "VERDICT: PASS - the updater component is healthy on $REPORTER's locale" ;;
  1) say "VERDICT: FAIL - the product" ;;
  *) say "VERDICT: INSTRUMENT - no verdict; the product is not implicated" ;;
esac
say "evidence in $OUT"
exit $rc
