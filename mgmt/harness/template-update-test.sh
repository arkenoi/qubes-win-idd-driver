#!/usr/bin/env bash
# template-update-test.sh - RELEASE FEATURE TEST (tools/release-feature-tests.txt: template-update): does a dom0-driven Windows
# update work on a TemplateVM upgraded to this package, in the field reporter's environment?
#
# WHY THIS EXISTS (2026-10-02). The proxied updater serves TemplateVMs ONLY - a StandaloneVM's pass is skipped by design
# (phase=skipped-standalone) - and every update run in our acceptance was on StandaloneVM subjects, so no release had ever run an
# update pass on the one class it is for. On GWeck's environment (German 25H2 TemplateVM) the published 4.3.32 and rz30 then ended
# every round FAIL SILENT on 0x8024402C, in the first boot that contacts Windows Update through our proxy, and the remedy for exactly
# that had been dead since 4.3.30 ($st IS $script:St). Owner: "the point of updater test is that it is templateVM!"
#
# WHAT IT RUNS: mgmt/harness/quick-upgrade.sh of PKG over the sealed TemplateVM golden <FAMILY>-qwt (the subject keeps the golden's
# class and default user), mgmt/harness/env-assert.sh against the reporter's recorded environment, a validated first read of the
# pass-liveness probe, then mgmt/harness/wu-e2e.sh: ROUNDS passes driven the Qube Manager way, each judged.
#
# PASS iff ALL of:
#   1. the upgrade verified (installed gui-agent == package reference, DisplayVersion) and env-assert held;
#   2. no round DEAD, STALLED, INVALID or unjudged-by-instrument; reboot accounting equal; no oscillation;
#   3. the LAST round is JUDGE PASS - the update completed and dom0 holds the guest's truth;
#   4. every earlier non-PASS round is the FIRST-CONTACT REMEDY and nothing else: dom0's own transcript of that round carries the
#      measured reason ("did not use the configured proxy") and the restart request ("RESTART CLEARS THIS IMMEDIATELY"), and the
#      restart was performed before the next round. At most ONE such round - a second means the remedy did not clear it;
#   5. excluded items, if any, positively judged (tools/wu-exclusion-audit.py, Jev) against INDEPENDENT evidence: the artefact versions
#      wu-e2e.sh measured on the guest before and after each pass that excluded them (tools/wu-exclusion-evidence.py), replayed
#      through that tool's own gate.
# Exit 0 PASS, 1 FAIL, 2 INSTRUMENT (the test could not produce a verdict - never a pass).
#
# EVAL_ONLY=<wu-e2e out dir> ROUNDS=<n>: judge an EXISTING wu-e2e run by the rules above and touch nothing (no rig) - the offline
# check of this verdict logic: the rz32 run (remedy round, then PASS) must PASS; the rz31 run (bare HRESULT, then a dead round) must FAIL.
declare -F toolstack_accept >/dev/null 2>&1 \
  || . "$(dirname "${BASH_SOURCE[0]}")/primitives.sh" 2>/dev/null || true   # toolstack_accept: the one recorded shutdown request
set -uo pipefail
cd /home/user/qubes-win-idd-driver || exit 2
if [ -n "${EVAL_ONLY:-}" ]; then VM="${VM:-eval-only}"; PKG="${PKG:-none}"; fi
VM="${VM:?set VM to the subject to create - there is no default target}"
PKG="${PKG:?set PKG to the release setup tree or ISO under test}"
FAMILY="${FAMILY:-win11de}"           # the golden is <FAMILY>-qwt; win11de-qwt = GWeck's sealed German 25H2 TemplateVM
REPORTER="${REPORTER:-gweck}"         # mgmt/reporters/<name>.json - the environment the subject must match
ROUNDS="${ROUNDS:-3}"
LOG="${LOG:-/home/user/qwt-accept/template-update-test-$VM.log}"
OUT="${OUT:-${LOG%.log}.d}"
mkdir -p "$OUT"
# DECLARE THE LEVEL - see reporter-env-build.sh say() and wu-e2e.sh log() for why an undeclared
# line makes tools/sweep-gate.sh exit 1 having judged only a fraction of the run.
say(){ _lv="$*"; _lv="${_lv#"${_lv%%[![:space:]]*}"}"
       case "$_lv" in
         "[ERROR]"*|"[WARN]"*|"[WARNING]"*|"[INFO]"*|"[DEBUG]"*) _m="$*" ;;
         *) _m="[INFO] $*" ;;
       esac
       echo "[$(date -u +%H:%M:%S)] $_m" | tee -a "$LOG"; }
state(){ qvm-ls --raw-data --fields state "$1" 2>/dev/null; }
halt(){ local i; [ "$(state "$VM")" = Halted ] && return 0
  qvm-check "$VM" >/dev/null 2>&1 || return 0   # never created (a preflight refusal): nothing to halt - rz35 waited 15 min here
  toolstack_accept "$VM" >/dev/null 2>&1
  for i in $(seq 1 90); do [ "$(state "$VM")" = Halted ] && return 0; sleep 10; done
  say "$VM did not halt in 15 min - left as it is, for examination"; return 1; }
verdict(){ say "$([ "$1" = PASS ] || printf '[ERROR] ')VERDICT $1: $2"; [ -n "${EVAL_ONLY:-}" ] || halt || true; case "$1" in PASS) exit 0 ;; FAIL) exit 1 ;; *) exit 2 ;; esac; }

if [ -n "${EVAL_ONLY:-}" ]; then
  say "template-update-test EVAL_ONLY=$EVAL_ONLY rounds=$ROUNDS (no rig)"
  [ -d "$EVAL_ONLY" ] || verdict INSTRUMENT "no such wu-e2e out dir: $EVAL_ONLY"
  E2E="$EVAL_ONLY"
  # wu-e2e's own exit rule, from its DONE line: any failure -> 3; else unjudged exclusions -> 4; else 0 (fails=0 alone is NOT green)
  dl=$(grep -a 'DONE:' "$E2E/run.log" | tail -1)
  case "$dl" in *'fails=0 '*'unjudged_exclusions=0'*) erc=0 ;; *'fails=0 '*) erc=4 ;; *) erc=3 ;; esac
else
say "template-update-test: PKG=$PKG golden=$FAMILY-qwt reporter=$REPORTER subject=$VM rounds=$ROUNDS"
[ "$(qvm-ls --raw-data --fields class "$FAMILY-qwt" 2>/dev/null)" = TemplateVM ] \
  || verdict INSTRUMENT "golden $FAMILY-qwt is not a TemplateVM - this test exists for the TemplateVM path and measures nothing else"
ss -ltn | grep -q '127.0.0.1:8082' || verdict INSTRUMENT "the updates proxy (127.0.0.1:8082) is down"

# 1. upgrade + environment
QU_OUT="$OUT/qu" mgmt/harness/quick-upgrade.sh "$PKG" "$VM" "$FAMILY" > "$OUT/quick-upgrade.out" 2>&1; qrc=$?
# A PREFLIGHT REFUSAL stops quick-upgrade before it creates anything (exit 3). Most are the RIG (rz35, 2026-10-02: "REFUSED: these are
# not Halted: win11-nfy" was recorded as a feature FAIL): INSTRUMENT - no product verdict for a test that never ran. But some are the
# PACKAGE under test (its disc fails Gate-0, its MANIFEST or reference agent does not hold, it is no release setup tree): those are FAIL.
ref=$(grep -a -m1 'REFUSED:' "$OUT/quick-upgrade.out" | sed 's/.*REFUSED: //')
if [ -n "$ref" ]; then
  case "$ref" in
    *'Gate-0 FAILED'*|*'MANIFEST'*|*'reference/gui-agent.exe'*|*'not a release setup tree'*|*'neither an ISO file nor a setup tree'*|*'make-iso failed'*)
      verdict FAIL "quick-upgrade refused the PACKAGE at its preflight: $ref" ;;
    *) verdict INSTRUMENT "quick-upgrade refused at its preflight - the test never ran: $ref" ;;
  esac
fi
grep -a -q 'PASS  installed gui-agent.exe == package reference' "$OUT/quick-upgrade.out" && grep -a -q 'PASS  DisplayVersion' "$OUT/quick-upgrade.out" \
  || verdict FAIL "the upgrade did not verify (quick-upgrade rc=$qrc, $OUT/quick-upgrade.out)"
grep -a -E '(^|: )FAIL  ' "$OUT/quick-upgrade.out" | sed 's/^/  quick-upgrade check FAILED: /' | cut -c1-240 | tee -a "$LOG" >/dev/null
[ "$(qvm-ls --raw-data --fields class "$VM" 2>/dev/null)" = TemplateVM ] || verdict INSTRUMENT "subject $VM is not a TemplateVM after the upgrade"
halt || verdict INSTRUMENT "$VM will not halt after the upgrade"
qvm-prefs "$VM" guivm '' || verdict INSTRUMENT "could not make $VM headless"
declare -F assert_sole_guest >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/serial-rig.sh"
assert_sole_guest "$VM" || exit 1
timeout 300 qvm-start "$VM" >/dev/null 2>&1; [ "$(state "$VM")" = Running ] || verdict INSTRUMENT "$VM did not start"
# BUILD the reporter's environment on the subject BEFORE asserting it. The subject is cloned from
# the sealed golden, which carries no Open-Shell and no enableWinKey feature, and the golden must
# never be booted - so the two facts gweck.json asserts have to be built here. Without this the
# 4.3.36 gate's template-update exited 2 on "open_shell_installed MISMATCH / service_enablewinkey
# MISSING", and the one script that could fix it lived in gitignored scratchpad.
mgmt/harness/reporter-env-build.sh "$VM" "$REPORTER" > "$OUT/reporter-env-build.txt" 2>&1 \
  || verdict INSTRUMENT "could not build $REPORTER's environment on $VM - see $OUT/reporter-env-build.txt"
say "reporter-env-build: $(tail -1 "$OUT/reporter-env-build.txt")"
# WRITTEN WHERE THE GATES READ IT, which is the whole of this defect. updater-gates-lib.sh's U7
# reads "$d/env-assert.out" and this test grades $d = "$OUT/preflight" (PF, below), while this line
# used to write "$OUT/env-assert.txt": a different extension AND a different directory.
# MEASURED on acceptance run 39880114972: U1-U6 all passed and U7 came back
#   FAIL U7 the subject is the reporter's recorded environment (gweck)
#        -> no env-assert.out in .../template-update.d/preflight - the environment and locale were
#           never asserted
# three lines below a log entry reading "env-assert: ENVASSERT OK: win11de-tup matches every
# asserted fact of GWeck's environment". The feature test returned INSTRUMENT rc=2, no dom0 rounds
# were spent, and the acceptance run failed on a subject whose environment HAD been asserted and had
# passed. Jev, handed that bundle, returned root_cause=never_asserted at conf 1.00 - correctly, on
# the evidence it was given, because the file was not where anything would look for it.
# updater-component-test.sh has always written "$OUT/env-assert.out" and handed the gates that same
# "$OUT", which is why its U7 passes; this is now the same one-path shape rather than a copy.
PF="$OUT/preflight"
mkdir -p "$PF" || verdict INSTRUMENT "could not create the preflight evidence dir $PF"
mgmt/harness/env-assert.sh "$VM" "$REPORTER" > "$PF/env-assert.out" 2>&1 \
  || verdict INSTRUMENT "env-assert $VM $REPORTER failed - not the reporter's environment ($PF/env-assert.out)"
say "env-assert: $(tail -1 "$PF/env-assert.out")"
pl=$(QTEST_VM="$VM" bash -c 'source mgmt/harness/wu-liveness.sh; wu_probe')
case "$pl" in WUPROBE\|task=Ready\|*) say "liveness probe first read: $pl" ;;
  *) verdict INSTRUMENT "the liveness probe did not read an idle task (${pl:-<no answer>}) - a DEAD verdict would rest on a broken read" ;; esac

# 1b. THE QUICK PREFLIGHT, BEFORE THE FULL SEQUENCE SPENDS AN HOUR.
# Owner, 2026-10-22: "BEFORE the full sequence starts, we want quick check if main functionality
# passes without failure." The gates are mgmt/harness/updater-gates-lib.sh - the same single
# implementation mgmt/harness/updater-component-test.sh runs standalone, so the two can never drift.
#
# WHY HERE AND WHY AT ALL. This test asserted NOTHING about the relay: `grep -i relay` over it
# returned nothing before this block. So when fa5b416a (2026-10-19) made the relay compile a
# discarded ScriptBlock, the resulting silence arrived here as an update-OUTCOME symptom and was
# attributed to four different causes in turn - a squatter on 8082, a self-perpetuating refusal, a
# stale staged payload, and a commit that could never have fired - before the cause was found. Two
# minutes of gates in front of three dom0-driven rounds would have named it the first time.
# A preflight failure is a PRODUCT failure, not an instrument one: the package is installed, the
# environment is asserted, and the updater's own logs say it did not build or serve its relay.
say "preflight: the updater's quick gates (updater-gates-lib.sh) before the dom0-driven rounds"
source mgmt/harness/updater-gates-lib.sh
# PF is set at the env-assert step above, because that is where the first thing written into it is.
updater_gates_collect "$VM" "$PF" || verdict INSTRUMENT "the preflight could not collect the updater's evidence from $VM"
updater_gates_grade "$PF" "$REPORTER"; pfrc=$?
printf '%s' "$UG_LINES" | sed 's/^/  /' | tee -a "$LOG" >/dev/null
printf '%s' "$UG_LINES" | sed 's/^/  /'
updater_gates_diagnose "$PF"; printf '%s' "$UG_DIAG" | tee -a "$LOG"
if [ "$pfrc" -ne 0 ]; then
  # SUPPLEMENTARY ONLY. The verdict below is already decided by the deterministic gates; Jev is
  # asked which cause the evidence most supports, because a probability is a classification and
  # classifications belong to the classifier of record. It cannot change the outcome.
  say "asking Jev for supplementary data on the root cause (does not change the verdict)"
  updater_gates_jev "$PF" || true
  printf 'JEV (secondary evaluator, supplementary):\n%s\n' "$UG_JEV" | tee -a "$LOG"
  [ "$pfrc" = 2 ] && verdict INSTRUMENT "the updater preflight could not be graded ($UG_FAIL gate(s) unmeasurable) - no dom0 rounds were spent"
  verdict FAIL "the updater preflight failed $UG_FAIL of 7 gates - the relay was not built or not serving, so the $ROUNDS dom0-driven round(s) were NOT spent; see $PF and the diagnosis above"
fi
say "preflight: all 7 gates passed - proceeding to the $ROUNDS dom0-driven round(s)"

# 2. the passes
E2E="$OUT/wu-e2e"
mgmt/harness/wu-e2e.sh "$VM" "$ROUNDS" "$E2E" > "$OUT/wu-e2e.out" 2>&1; erc=$?
fi
RL="$E2E/run.log"
[ -s "$RL" ] || verdict INSTRUMENT "wu-e2e left no run.log (rc=$erc)"
# A FILE CANNOT SCOPE A RUN. run.log is appended, and on rel-40037710497 this suite inherited a
# previous attempt's artefacts: one file held two attempts, `fails=1` then `fails=0`, and the reads
# below disagreed - `DONE:` was taken with `tail -1` (the retry's) while the failure patterns were
# scanned over the WHOLE file, so a GREEN retry was reported FAIL quoting the superseded attempt's
# 02:55:50 line. The ROOT fix is in tools/release-acceptance.sh, which must not hand an attempt the
# previous one's $WORK/<tag>.d tree. This assertion is the backstop for a standalone re-run into the
# same OUT: a misread is turned into a loud INSTRUMENT verdict rather than a silent false FAIL.
_done=$(grep -ac 'DONE: rounds=' "$RL")
[ "$_done" -le 1 ] || verdict INSTRUMENT "$RL holds $_done wu-e2e attempts, so a verdict read over it would mix them (a green retry was reported FAIL this way on rel-40037710497) - give this suite a clean OUT or let release-acceptance.sh rotate it"
say "wu-e2e rc=$erc: $(grep -a 'DONE:' "$RL" | tail -1 | cut -c1-200)"
grep -a -q 'DONE:' "$RL" || verdict INSTRUMENT "wu-e2e did not finish (rc=$erc) - no verdict"
# wu-e2e's own failure lines, verbatim (mgmt/harness/wu-e2e.sh): a stall, a dead pass, the oscillation and reboot-accounting
# verdicts, the exclusion audit, and every round-level "FAIL - ..." (scan never ran, no power-off, no comeback, unreadable status).
bad=$(grep -a -E 'STALLED|PASS DEAD|FAIL OSCILLATION|FAIL REBOOT ACCOUNTING|FAIL EXCLUSION AUDIT|: FAIL - ' "$RL" | head -3)
[ -z "$bad" ] || verdict FAIL "a round failed for a reason other than the judge: $(printf '%s' "$bad" | tr '\n' ' ' | cut -c1-300)"
grep -a -q 'reboot accounting OK' "$RL" || verdict INSTRUMENT "no reboot-accounting verdict in $RL"

# 3 + 4. per-round judge: the last round must PASS; any earlier FAIL must be the remedy round, at most one
mapfile -t judged < <(grep -a -oE 'round [0-9]+: JUDGE (PASS|FAIL)' "$RL")
[ "${#judged[@]}" -eq "$ROUNDS" ] || verdict INSTRUMENT "wu-e2e judged ${#judged[@]} of $ROUNDS rounds"
last="${judged[$((ROUNDS-1))]}"
[ "${last##* }" = PASS ] || verdict FAIL "the last round did not pass (${last}) - the update never completed on this TemplateVM"
remedy=0
for j in "${judged[@]}"; do
  [ "${j##* }" = FAIL ] || continue
  r=$(printf '%s' "$j" | grep -oE 'round [0-9]+' | grep -oE '[0-9]+')
  rp="$E2E/round$r/replay.out"
  [ -s "$rp" ] || verdict INSTRUMENT "round $r failed and its dom0 transcript $rp is missing"
  # The text is what dom0 SAW; the round's saved status is the structured half - the restart must have been REQUESTED (reboot_needed),
  # not merely mentioned (Jev review 2026-10-02: text alone is fragile evidence; it fails closed, the flag makes it exact).
  rn=$(python3 -c "import json,sys; print(str(json.load(open(sys.argv[1], encoding='utf-8-sig')).get('reboot_needed')).lower())" "$E2E/round$r/update-status.json" 2>/dev/null)
  if grep -a -q 'did not use the configured proxy' "$rp" && grep -a -q 'RESTART CLEARS THIS IMMEDIATELY' "$rp" && [ "$rn" = true ]; then
    remedy=$((remedy+1)); say "round $r: the first-contact remedy - dom0 was given the reason and the restart request"
  else
    verdict FAIL "round $r failed and it was NOT the first-contact remedy (reboot_needed=${rn:-unreadable}; $(grep -a 'update failed' "$rp" | head -1 | cut -c1-200))"
  fi
done
[ "$remedy" -le 1 ] || verdict FAIL "$remedy remedy rounds - the requested restart did not clear the state"

# 5. exclusions: wu-e2e exits 4 when items were excluded and nobody judged them; judge them here (Jev) and replay the tool's gate
if [ "$erc" = 4 ]; then
  # THE AUDIT NEEDS INDEPENDENT EVIDENCE (2026-10-03): run without it, Jev could only judge the updater's own rows and the rz35 gate
  # failed on three Defender items whose versions were never measured. mgmt/harness/wu-e2e.sh measures the artefacts before and after
  # every pass (mgmt/harness/wu-evidence-facts.sh); tools/wu-exclusion-evidence.py turns the excluded rounds' facts into the evidence,
  # and refuses when an excluded round lacks them (INSTRUMENT - missing data fails). EVAL_ONLY reads the same files from the run dir.
  python3 tools/wu-exclusion-evidence.py "$E2E" "$OUT/exclusion-evidence.json" > "$OUT/exclusion-evidence.out" 2>&1 \
    || verdict INSTRUMENT "could not build the exclusion evidence: $(tail -1 "$OUT/exclusion-evidence.out")"
  python3 tools/wu-exclusion-audit.py "$E2E" --evidence "$OUT/exclusion-evidence.json" --out "$OUT/exclusion-verdict.json" > "$OUT/exclusion-audit.out" 2>&1 \
    || verdict FAIL "the exclusion audit did not pass ($OUT/exclusion-audit.out)"
  say "exclusions judged: $(tail -1 "$OUT/exclusion-audit.out" | cut -c1-200)"
elif [ "$erc" != 0 ] && [ "$erc" != 3 ]; then
  verdict INSTRUMENT "wu-e2e exited $erc"
fi
# HARDWIRED ERROR SWEEP, BEFORE ANY PASS (findings/issues.md HARNESSLOGUNSWEPT). Nothing swept this
# suite's own logs, so an error-shaped line was graded by whoever read it - and on 2026-10-14 that
# meant four "cause UNKNOWN" lines and a WARNING waved through by a model. An unexplained line means
# this suite cannot certify the product, which is INSTRUMENT, not FAIL: the run does not pass and the
# product is not implicated. Declared patterns live in mgmt/harness/harness-log-declared.txt WITH a
# reason, and that file ships with no excuses in it.
if [ -z "${EVAL_ONLY:-}" ] && [ -x tools/sweep-gate.sh ]; then
  swlogs=""
  for f in "$OUT/wu-e2e.out" "$E2E/run.log" "$LOG"; do [ -s "$f" ] && swlogs="$swlogs $f"; done
  if [ -n "$swlogs" ]; then
    # shellcheck disable=SC2086  # swlogs is a deliberate list of log paths
    # REPORTS, DOES NOT GATE - yet. Jev: design_sound 0.78, safe_to_gate_a_release 0.30, dominant
    # flaw "a baselined shape hides genuine future instances" (0.85). So a new shape is said out
    # loud and recorded; it does not turn a measured product result into INSTRUMENT until the
    # per-shape counts land and the silencer is closed.
    if bash tools/sweep-gate.sh $swlogs > "$OUT/sweep-gate.out" 2>&1; then
      say "sweep-gate: no new error shape in this suite's logs"
    else
      say "SWEEP-GATE: $(grep -ac '^  ' "$OUT/sweep-gate.out") new error shape(s) in this suite's logs - see $OUT/sweep-gate.out"
      grep -a '^  ' "$OUT/sweep-gate.out" | head -6 | while IFS= read -r l; do say "  $l"; done
    fi
  fi
fi
verdict PASS "the update completed on a TemplateVM in $REPORTER's environment ($remedy remedy round(s), last round PASS)"
