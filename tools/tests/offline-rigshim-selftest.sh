#!/bin/bash
# AN OFFLINE SUITE THAT TOUCHES THE RIG MUST BE RED, WHATEVER ITS OWN ASSERTIONS SAY
# run: tools/tests/offline-rigshim-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
R=tools/tests/run-offline-suites.sh
[ -r "$R" ] || { echo "FATAL: $R missing"; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/rigshim-XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

# ---- the fixture suites ------------------------------------------------------------------------
# clean: asserts, exits 0, never calls out.
cat > "$T/clean-selftest.sh" <<'EOF'
#!/bin/bash
echo "ok   a clean suite asserts something"
echo "RESULT: 1 passed, 0 failed"
exit 0
EOF
# direct: reaches the rig by a BARE command name and still exits 0 with assertions.
cat > "$T/direct-selftest.sh" <<'EOF'
#!/bin/bash
qvm-ls --raw-data --fields STATE some-guest-that-does-not-exist >/dev/null 2>&1
echo "ok   this suite is green on its own terms"
echo "RESULT: 1 passed, 0 failed"
exit 0
EOF
# exec'd: reaches the rig THROUGH timeout, which is the case a shell function cannot stub. My first
# fix for the somevm leak was `qrexec-client-vm(){ return 1; }` and the call count did not move.
cat > "$T/viatimeout-selftest.sh" <<'EOF'
#!/bin/bash
qrexec-client-vm(){ return 1; }          # deliberately present, and deliberately not enough
timeout 5 qrexec-client-vm somevm admin.vm.Stats >/dev/null 2>&1
echo "ok   this suite is green on its own terms"
echo "RESULT: 1 passed, 0 failed"
exit 0
EOF
chmod +x "$T"/*-selftest.sh

# HERMETIC PATH, BECAUSE THIS SUITE RUNS UNDER THE GUARD IT TESTS. Standalone it passed 19/19; in
# the estate it failed 2 legs, because the runner puts its shim dir FIRST on PATH before invoking
# each suite - so inside the estate every one of the 23 rig commands DOES exist, as the outer stub.
# That broke both controls: the leg asserting the probe command is absent found the outer stub, and
# control 2 (which removes the inner shim) still resolved the probe to the outer stub and recorded
# the call. Passing standalone is not passing in the estate.
# So the controls run against a PATH built from scratch. /usr/bin:/bin carries everything the runner
# needs (bash, awk, sed, grep, timeout, wc, sort, mktemp) and carries the REAL qvm-* tools, which is
# what makes control 2's choice of probe load-bearing: qrexec-client is dom0-side and absent there,
# so removing the shim reaches nothing.
SAFEPATH=/usr/bin:/bin
run(){ # <list-contents> [runner-path] -> rc, output in $T/out
  local list="$1" runner="${2:-$R}"
  printf '%s\n' "$list" > "$T/list.txt"
  env -u OFFLINE_RIG_CALLS PATH="$SAFEPATH" \
      OFFLINE_SUITES_DEPTH=0 OFFLINE_SUITES_LIST="$T/list.txt" OFFLINE_SUITES_DIR="$T" \
      OFFLINE_SUITES_FLOOR=1 TMPDIR_OVERRIDE="$T/tmp" bash "$runner" >"$T/out" 2>&1; echo $?
}

# ---- 1. the positive control: a clean suite is still green --------------------------------------
rc=$(run 'clean-selftest.sh')
if [ "$rc" = 0 ] && command grep -qa 'RESULT: PASS' "$T/out"; then
  ok "a suite that makes no rig call is still green (the guard does not refuse everything)"
else no "a clean suite was refused (rc=$rc)" "$(tail -3 "$T/out" | tr '\n' ' ')"; fi
command grep -qa 'TOUCHED-RIG' "$T/out" \
  && no "a clean suite was reported TOUCHED-RIG" "$(command grep -a TOUCHED-RIG "$T/out")" \
  || ok "and it is not reported as touching the rig"

# ---- 2. a bare rig call is caught, and the suite is RED despite exiting 0 -----------------------
rc=$(run 'direct-selftest.sh')
if [ "$rc" != 0 ] && command grep -qa '^TOUCHED-RIG .*direct-selftest' "$T/out"; then
  ok "a suite calling qvm-ls is TOUCHED-RIG and the run is red, though the suite exited 0"
else no "a rig-calling suite passed (rc=$rc)" "$(tail -3 "$T/out" | tr '\n' ' ')"; fi
command grep -qa 'qvm-ls --raw-data' "$T/out" \
  && ok "and the report names the call it made, not just that it made one" \
  || no "the report does not name the call" "$(command grep -a -A2 TOUCHED-RIG "$T/out" | tr '\n' ' ')"
command grep -qaE '^ok +direct-selftest' "$T/out" \
  && no "it was ALSO counted green" "a suite cannot be both" \
  || ok "and it is not also counted green"

# ---- 3. THE CASE A FUNCTION CANNOT STUB: the call goes through timeout --------------------------
rc=$(run 'viatimeout-selftest.sh')
if [ "$rc" != 0 ] && command grep -qa '^TOUCHED-RIG .*viatimeout-selftest' "$T/out"; then
  ok "a call made through timeout is caught - the shim is on PATH, not a shell function"
else no "the timeout-exec'd call was missed (rc=$rc)" "$(tail -3 "$T/out" | tr '\n' ' ')"; fi

# ---- 4. the shim must cover the two commands that actually bit us -------------------------------
shim=$(awk '/# OFFLINE-RIGSHIM-A/,/# OFFLINE-RIGSHIM-B/' "$R")
[ -n "$shim" ] || { echo "FATAL: could not extract the shim block from $R"; exit 2; }
for c in qrexec-client-vm qvm-ls qvm-prefs; do
  printf '%s' "$shim" | command grep -qa -- "$c" \
    && ok "the shim covers $c" \
    || no "the shim does not cover $c" "that is one of the commands the two leaks used"
done

# ---- 5. SEEN TO FAIL: with only the VERDICT disabled, the rig-calling suite reads green ---------
# The control disables ONE THING - the branch that turns a recorded call into a red - and leaves the
# shim, the recording and the rest of the runner intact. An earlier version of this leg deleted the
# whole marker block and patched the two variables back in by sed; a Jev review put it at 0.40
# because it could then pass for a reason unrelated to the guard (the stripped copy failing to run
# at all, or the deletion taking something the assertion needed with it). So: the copy must be
# demonstrably WORKING, which the clean suite in the same run proves, and the substitution must be
# asserted rather than assumed.
sed 's/if \[ -s "\$RIGCALLS" \]; then/if false; then   # NEGATIVE CONTROL/' "$R" > "$T/noverdict.sh"
command grep -qa 'if false; then   # NEGATIVE CONTROL' "$T/noverdict.sh" \
  && ok "the control disables exactly the verdict branch (substitution asserted, not assumed)" \
  || no "the control's substitution did not apply" "the leg below would pass or fail for the wrong reason"
rc=$(run 'direct-selftest.sh
clean-selftest.sh' "$T/noverdict.sh")
if [ "$rc" = 0 ] && command grep -qaE '^ok +direct-selftest' "$T/out"; then
  ok "SEEN TO FAIL: with the verdict disabled the rig-calling suite is reported green again"
else no "the negative control did not reproduce the old behaviour (rc=$rc)" "$(tail -3 "$T/out" | tr '\n' ' ')"; fi
command grep -qaE '^ok +clean-selftest' "$T/out" \
  && ok "and the control copy is demonstrably working - it graded the clean suite in the same run" \
  || no "the control copy did not grade the clean suite" "so its green on the rig-caller proves nothing"

# ---- 5a. THE SECOND CONTROL: the PATH prepend is what SEES the call ----------------------------
# Disabling the verdict shows which branch refuses. It does not show that the shim is what records.
# This one removes the per-suite PATH prepend and asserts nothing is recorded at all - so the two
# controls together cover both halves of the guard (a Jev review put the single control at 0.40,
# then 0.59).
# IT USES A COMMAND THAT IS NOT INSTALLED ON THIS QUBE (qrexec-client is dom0-side; checked here,
# not assumed), because the fixture must not reach a REAL rig tool when the shim is removed - that
# would fire the exact denied admin call this whole change exists to stop.
# CHECKED UNDER THE SAME PATH THE CONTROL USES, not the ambient one: inside the estate the ambient
# PATH starts with the outer guard's shim dir, where every rig command exists as a stub, and this
# leg then failed on a stub rather than on a real tool.
if env PATH="$SAFEPATH" sh -c 'command -v qrexec-client' >/dev/null 2>&1; then
  no "the control's probe command exists under the control's PATH" "pick one that does not, or this leg can fire a real call"
else
  ok "the control's probe command is absent under the control's PATH, so removing the shim reaches nothing"
fi
cat > "$T/absent-selftest.sh" <<'EOF'
#!/bin/bash
qrexec-client -d somevm DEVNULL >/dev/null 2>&1
echo "ok   this suite is green on its own terms"
echo "RESULT: 1 passed, 0 failed"
exit 0
EOF
chmod +x "$T/absent-selftest.sh"
rc=$(run 'absent-selftest.sh')
if [ "$rc" != 0 ] && command grep -qa '^TOUCHED-RIG .*absent-selftest' "$T/out"; then
  ok "with the shim in place the call is recorded even though the command is not installed"
else no "the shimmed call was not recorded (rc=$rc)" "$(tail -3 "$T/out" | tr '\n' ' ')"; fi
# NO TRAILING COMMENT INSIDE THE COMMAND. The first spelling of this appended
# `# NEGATIVE CONTROL` after `timeout 300`, inside a $( ) assignment, which commented out the rest
# of the command and left the copy with a syntax error - so the leg failed for the fixture's reason
# and not the guard's. The substitution is asserted by the ABSENCE of what it removed instead.
n_before=$(command grep -ca 'RIGSHIM:\$PATH' "$R")
sed 's|PATH="\$RIGSHIM:\$PATH" ||' "$R" > "$T/nopath.sh"
if [ "$n_before" = 1 ] && ! command grep -qa 'RIGSHIM:\$PATH' "$T/nopath.sh" && bash -n "$T/nopath.sh"; then
  ok "the second control removes exactly the PATH prepend, once, and the copy still parses"
else
  no "the second control's substitution did not apply cleanly" "occurrences before=$n_before; the leg below would prove nothing"
fi
rc=$(run 'absent-selftest.sh
clean-selftest.sh' "$T/nopath.sh")
if [ "$rc" = 0 ] && ! command grep -qa 'TOUCHED-RIG' "$T/out"; then
  ok "SEEN TO FAIL: without the PATH prepend the same call is recorded nowhere and the suite is green"
else no "removing the PATH prepend still caught the call (rc=$rc)" "$(tail -3 "$T/out" | tr '\n' ' ')"; fi
command grep -qaE '^ok +clean-selftest' "$T/out" \
  && ok "and that control copy is working too - it graded the clean suite in the same run" \
  || no "the second control copy did not grade the clean suite" "its green proves nothing"

# ---- 5b. THE GUARD'S BLIND SPOT, MEASURED RATHER THAN CLAIMED ----------------------------------
# A PATH shim cannot see a rig tool invoked by absolute path, or the python admin API used directly.
# That bound is real, so it is measured over the shipped list instead of being asserted away.
SELF="$(basename "${BASH_SOURCE[0]}")"
blind=$(while read -r s; do
          case "$s" in ''|\#*) continue ;; esac
          # THIS FILE IS THE SCANNER, AND IT CARRIES THE PATTERN IT SEARCHES FOR. Without this
          # line the leg reported itself as reaching the rig past the shim - the same mistake the
          # kill-by-pattern gate exists for ("the matcher carries the text it searches for"), made
          # again here on first run. A pattern held as data is not a call.
          [ "$s" = "$SELF" ] && continue
          f="tools/tests/$s"; [ -f "$f" ] || continue
          command grep -qaE '/usr/bin/(qvm|qrexec)|import qubesadmin|from qubesadmin|qubesadmin\.' "$f" \
            && printf '%s ' "$s"
        done < <(cat tools/tests/product-suites.txt tools/tests/harness-suites.txt))
[ -z "${blind// /}" ] \
  && ok "no suite in the shipped list reaches the rig by a route the shim cannot see" \
  || no "suites reach the rig past the shim: $blind" "an absolute path or the python API is not on PATH"

# ---- 6. and the two suites that were leaking are clean now, through the SHIPPED guard ----------
# Driven through the runner rather than with a hand-rolled shim, so this leg tests the thing that
# will actually be guarding them.
printf 'specimen-mark-reachable-selftest.sh\ndom0-callers-selftest.sh\n' > "$T/live.txt"
env OFFLINE_SUITES_DEPTH=0 OFFLINE_SUITES_LIST="$T/live.txt" OFFLINE_SUITES_DIR=tools/tests \
    OFFLINE_SUITES_FLOOR=2 TMPDIR_OVERRIDE="$T/tmp" bash "$R" >"$T/live.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && ! command grep -qa 'TOUCHED-RIG' "$T/live.out"; then
  ok "the two suites that were leaking make no rig call under the shipped guard"
else
  no "a known leaker still reaches the rig (rc=$rc)" "$(command grep -a -A2 TOUCHED-RIG "$T/live.out" | head -4 | tr '\n' ' ')"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
