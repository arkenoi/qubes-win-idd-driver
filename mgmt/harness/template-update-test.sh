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
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }
state(){ qvm-ls --raw-data --fields state "$1" 2>/dev/null; }
halt(){ local i; [ "$(state "$VM")" = Halted ] && return 0
  qvm-check "$VM" >/dev/null 2>&1 || return 0   # never created (a preflight refusal): nothing to halt - rz35 waited 15 min here
  timeout 120 qvm-shutdown "$VM" >/dev/null 2>&1
  for i in $(seq 1 90); do [ "$(state "$VM")" = Halted ] && return 0; sleep 10; done
  say "$VM did not halt in 15 min - left as it is, for examination"; return 1; }
verdict(){ say "VERDICT $1: $2"; [ -n "${EVAL_ONLY:-}" ] || halt || true; case "$1" in PASS) exit 0 ;; FAIL) exit 1 ;; *) exit 2 ;; esac; }

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
timeout 300 qvm-start "$VM" >/dev/null 2>&1; [ "$(state "$VM")" = Running ] || verdict INSTRUMENT "$VM did not start"
# BUILD the reporter's environment on the subject BEFORE asserting it. The subject is cloned from
# the sealed golden, which carries no Open-Shell and no enableWinKey feature, and the golden must
# never be booted - so the two facts gweck.json asserts have to be built here. Without this the
# 4.3.36 gate's template-update exited 2 on "open_shell_installed MISMATCH / service_enablewinkey
# MISSING", and the one script that could fix it lived in gitignored scratchpad.
mgmt/harness/reporter-env-build.sh "$VM" "$REPORTER" > "$OUT/reporter-env-build.txt" 2>&1 \
  || verdict INSTRUMENT "could not build $REPORTER's environment on $VM - see $OUT/reporter-env-build.txt"
say "reporter-env-build: $(tail -1 "$OUT/reporter-env-build.txt")"
mgmt/harness/env-assert.sh "$VM" "$REPORTER" > "$OUT/env-assert.txt" 2>&1 \
  || verdict INSTRUMENT "env-assert $VM $REPORTER failed - not the reporter's environment ($OUT/env-assert.txt)"
say "env-assert: $(tail -1 "$OUT/env-assert.txt")"
pl=$(QTEST_VM="$VM" bash -c 'source mgmt/harness/wu-liveness.sh; wu_probe')
case "$pl" in WUPROBE\|task=Ready\|*) say "liveness probe first read: $pl" ;;
  *) verdict INSTRUMENT "the liveness probe did not read an idle task (${pl:-<no answer>}) - a DEAD verdict would rest on a broken read" ;; esac

# 2. the passes
E2E="$OUT/wu-e2e"
mgmt/harness/wu-e2e.sh "$VM" "$ROUNDS" "$E2E" > "$OUT/wu-e2e.out" 2>&1; erc=$?
fi
RL="$E2E/run.log"
[ -s "$RL" ] || verdict INSTRUMENT "wu-e2e left no run.log (rc=$erc)"
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
verdict PASS "the update completed on a TemplateVM in $REPORTER's environment ($remedy remedy round(s), last round PASS)"
