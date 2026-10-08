#!/usr/bin/env bash
# console-window-check-selftest.sh - the console-window check's DECISION, exercised offline.
#
# WHY. On 2026-10-08 the check failed WIN11-upgrade and the template-update quick-upgrade on the
# HARNESS's own installer console: the over-existing cells run <CD>\install.cmd in the guest's
# session, install.cmd is a batch file, and on Windows 11 25H2 cmd.exe is hosted by Windows Terminal
# (CASCADIA_HOSTING_WINDOW_CLASS). Jev: whose_defect = harness 0.94, product 0.00;
# agent_should_filter_consoles 0.15; how_to_fix = the check excludes the cell's own installer,
# IDENTIFIED rather than assumed, 0.59. So --allow-installer-console was added, and it must be
# NARROW: exactly one tolerated, always reported, and everything the check caught before must still
# fail - the four-week helper console it was written for most of all.
#
# The check talks to a guest through <repo>/tools/qtest and derives its own repo root from its own
# path, so this builds a throwaway tree with a FAKE qtest that prints canned agent-log answers. No
# guest is touched.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$HERE/mgmt/harness/console-window-check.sh"
[ -f "$CHECK" ] || { echo "FAIL  $CHECK missing - nothing ran (missing data fails)"; exit 2; }
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tools" "$TMP/mgmt/harness"
cp "$CHECK" "$TMP/mgmt/harness/console-window-check.sh"
# a vmlock that always grants, so the decision is what is under test
cat > "$TMP/mgmt/harness/vmlock.sh" <<'EOF'
vm_lock(){ return 0; }
EOF
HIT='[20261008.230913.847-5504-I] AddWindow: QGAHELDDEFER hwnd=0x40086 class=CASCADIA_HOSTING_WINDOW_CLASS w=1115 h=628 t=67265 slicefed=1 brokerslot=0'
HIT2='[20261008.231020.001-5504-I] AddWindow: QGAHELDDEFER hwnd=0x40099 class=ConsoleWindowClass w=800 h=400 t=72000 slicefed=1 brokerslot=1'

# The fake qtest prints whatever CWC- lines the case put in $TMP/answer.
cat > "$TMP/tools/qtest" <<'EOF'
#!/usr/bin/env bash
cat "$(dirname "$0")/../answer"
EOF
chmod +x "$TMP/tools/qtest"

run_case(){   # run_case <label> <answer-file-content> <expect-rc> [flag]
  local label="$1" body="$2" want="$3" flag="${4:-}"
  printf '%s\n' "$body" > "$TMP/answer"
  local out rc
  out=$(bash "$TMP/mgmt/harness/console-window-check.sh" somevm $flag 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$rc, expected $want | $out"; fi
  printf '%s' "$out" > "$TMP/last.out"
}

BASE="CWC-DIR=Q:\\Qubes Logs
CWC-LOGS=1
CWC-INIT|gui-agent-20261008.log
CWC-END"

# ---- 1. a clean boot: no console window at all -------------------------------------------------
run_case "no console window mapped -> pass" "$BASE" 0
command grep -q "^NONE:" "$TMP/last.out" \
  && ok "and it says NONE, naming the logs it read" \
  || bad "the clean verdict does not say NONE: $(cat "$TMP/last.out")"

# ---- 2. THE DEFECT THIS CHECK EXISTS FOR: a console window with NO declaration -----------------
run_case "one console window, cell declared NOTHING -> FAIL (the four-week helper defect)" \
         "CWC-DIR=x
CWC-LOGS=1
CWC-INIT|a.log
CWC-HIT|a.log|$HIT
CWC-END" 1
command grep -q "^FOUND 1 console/Terminal window" "$TMP/last.out" \
  && ok "and it names the offending AddWindow line" \
  || bad "the failure does not name the window: $(cat "$TMP/last.out")"

# ---- 3. the declared installer console: tolerated, but REPORTED --------------------------------
run_case "one console window, cell DECLARED its installer console -> pass" \
         "CWC-DIR=x
CWC-LOGS=1
CWC-INIT|a.log
CWC-HIT|a.log|$HIT
CWC-END" 0 --allow-installer-console
command grep -q "tolerated, reported" "$TMP/last.out" \
  && ok "and the tolerated window is still REPORTED, so it can never go unseen" \
  || bad "a tolerated window was not reported: $(cat "$TMP/last.out")"
command grep -q "CASCADIA_HOSTING_WINDOW_CLASS" "$TMP/last.out" \
  && ok "and the report carries the class, so which window it was stays on the record" \
  || bad "the report does not name the class: $(cat "$TMP/last.out")"

# ---- 4. THE EXCLUSION IS NARROW: a SECOND console window still fails ---------------------------
run_case "TWO console windows with the declaration -> still FAIL (only one can be the installer's)" \
         "CWC-DIR=x
CWC-LOGS=1
CWC-INIT|a.log
CWC-HIT|a.log|$HIT
CWC-HIT|a.log|$HIT2
CWC-END" 1 --allow-installer-console
command grep -q "declared ONE installer console" "$TMP/last.out" \
  && ok "and it says why: the cell declared one, more than one was mapped" \
  || bad "the two-window failure does not explain itself: $(cat "$TMP/last.out")"

# ---- 5. MISSING DATA FAILS, with or without the flag -------------------------------------------
run_case "no complete answer -> INVALID-INSTRUMENT, not a pass" "CWC-LOGS=1" 2 --allow-installer-console
run_case "no agent log found -> INVALID-INSTRUMENT, not a pass" \
         "CWC-DIR=x
CWC-LOGS=0
CWC-END" 2 --allow-installer-console
run_case "logs read but no Init line -> INVALID-INSTRUMENT, not a pass" \
         "CWC-DIR=x
CWC-LOGS=1
CWC-END" 2 --allow-installer-console
run_case "an unreadable agent log -> INVALID-INSTRUMENT, not a pass" \
         "CWC-DIR=x
CWC-LOGS=1
CWC-INIT|a.log
CWC-UNREADABLE|b.log
CWC-END" 2 --allow-installer-console

# ---- 6. the flag must not be mistaken for the vm name ------------------------------------------
out=$(bash "$TMP/mgmt/harness/console-window-check.sh" --allow-installer-console 2>&1); rc=$?
[ "$rc" = 1 ] || [ "$rc" = 2 ] && [ -n "$out" ] \
  && ok "the flag alone is not taken as a vm name" \
  || bad "the flag alone was accepted as a vm: rc=$rc out=$out"

echo
echo "console-window-check-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
