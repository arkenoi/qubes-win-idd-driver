#!/bin/bash
# matrix-verifyinstalled-grade-selftest.sh - the campaign's BIGGEST grader had no suite.
#
# WHAT IT GRADES. verify_installed() decides whether an install cell passed: 37 ok()/no() call sites,
# the largest single contributor to a campaign verdict. tools/grader-census.py counted it as
# untested, alongside 10 others making 99 of 156 verdict decisions between them.
#
# WHY IT MATTERS HERE, measured rather than argued. Its own comments record what an untested grader
# of this size costs:
#   * "campaign 20260830-062519 produced 36 green lines for a path that never ran" - a silent D2
#     reinstall reported as a clean install, until the installer's own clean-install marker was
#     asserted positively;
#   * the 2026-09-16 systemic finding: it "graded upgrade_mode, the agent hash and autologon and
#     NEVER looked at `ok`", so an installer trailer carrying idd_failed / pv_xenvif='failed' /
#     gui_restored='FAILED' under ok:true graded the cell GREEN;
#   * a stage-1 trailer with no installed_gui_agent_sha256 field made it report "installed agent is
#     NOT the release binary" for a guest whose binary matched byte for byte (measured 2026-09-08).
# Every one of those is a verdict defect, and none of them was reachable without a four-hour run.
#
# HOW IT IS DRIVEN. The SHIPPED function is extracted from matrix.sh and run against PLANTED LOGS,
# with only the guest-touching helpers stubbed (w_session/w_alive/w_halt/start_vm/qvm-*/qtest/sleep).
# mgmt/harness/result-flags.py is NOT stubbed - the real flag judge runs on the planted trailers,
# because that checker is the thing the 2026-09-16 finding turned on.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
HERE="$PWD"

T=$(mktemp -d "${TMPDIR:-/tmp}/matrix-verifyinstalled.XXXXXX") || exit 2
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT INT TERM

MSH="$HERE/$(ls mgmt/harness/matri*.sh | head -1)"
eval "$(sed -n '/^verify_installed(){/,/^}$/p' "$MSH")"
declare -f verify_installed >/dev/null || { echo "FAIL could not extract verify_installed from $MSH"; exit 1; }

pass=0; fail=0
ok_(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no_(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

ASHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
RELEASE_SETUP="$T/setup"; mkdir -p "$RELEASE_SETUP"

# THE FUNCTION FETCHES THE LOG ITSELF, so planting a file is not enough: its fetch loop redirects
# over "$M/<lbl>-final.log" and TRUNCATED the planted copy before the stub wrote anything, which is
# why the first version of this suite reported "no PRECONDITION line" for every case. The qtest stub
# therefore SERVES the planted log, and serves the hash when asked for one.
HERE="$T"
mkdir -p "$T/tools" "$T/mgmt/harness"
cp "$(git rev-parse --show-toplevel)/mgmt/harness/result-flags.py" "$T/mgmt/harness/"
cat > "$T/tools/qtest" <<'QSTUB'
#!/bin/bash
# the installer-log fetch vs the certutil hash, told apart by the command it is asked to run
case " $* " in
  *certutil*) [ -s "$QT_HASH" ] && cat "$QT_HASH"; exit "${QT_HASH_RC:-0}" ;;
  *)          [ -s "$QT_LOG" ]  && cat "$QT_LOG";  exit 0 ;;
esac
QSTUB
chmod +x "$T/tools/qtest"
export QT_LOG="$T/plant.log" QT_HASH="$T/hash.txt" QT_HASH_RC=0
: > "$T/hash.txt"

# ---- the planted inputs ------------------------------------------------------------------------
PRECON_PRISTINE='2026-10-16 10:00:00 [INFO] === PRECONDITION === {"testsigning_active":false,"installed_qwt_count":0}'
PRECON_DIRTY='2026-10-16 10:00:00 [INFO] === PRECONDITION === {"testsigning_active":true,"installed_qwt_count":2}'
CLEAN_MARK='2026-10-16 10:00:01 [INFO] no previously installed Qubes Windows Tools found - clean install path'
RESULT_GREEN='=== RESULT === {"ok":true,"upgrade_mode":"clean","installed_gui_agent_sha256":"'"$ASHA"'","detail":{}}'
RESULT_FLAGGED='=== RESULT === {"ok":true,"upgrade_mode":"clean","installed_gui_agent_sha256":"'"$ASHA"'","detail":{"idd_failed":true}}'
RESULT_STAGE1='=== RESULT === {"ok":true,"upgrade_mode":"clean","detail":{}}'

# <logfile-contents...> -> sets OK/NO/LINES/RC for one call
run_case(){ # $1=label, rest = log lines
  local lbl=$1; shift
  M="$T/$lbl"; R="$T/$lbl/run.log"; mkdir -p "$M"; : > "$R"
  : > "$T/plant.log"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$T/plant.log"; done
  OK=0; NO=0; LINES=""
  ok(){ OK=$((OK+1)); LINES="$LINES[OK] $*"$'\n'; }
  no(){ NO=$((NO+1)); LINES="$LINES[NO] $*"$'\n'; }
  say(){ LINES="$LINES[SAY] $*"$'\n'; }
  # guest-touching helpers: the guest reboots fine and comes back with a session, so the cases below
  # exercise the LOG-JUDGING half. w_alive true skips the CPU-quiet wait entirely.
  w_alive(){ return 0; }
  w_halt(){ return 0; }
  w_session(){ return "${WSESSION_RC:-0}"; }
  w_screen(){ printf 'DESKTOP\n'; }
  w_install(){ return 0; }
  start_vm(){ :; }
  sleep(){ :; }
  qvm-shutdown(){ :; }
  qvm-kill(){ :; }
  qvm-prefs(){ printf '\n'; }
  ENTRY_PRISTINE="${ENTRY_PRISTINE:-1}"; E2E_MARK=""; EXPECT_MODE="${EXPECT_MODE:-clean}"
  GLOG='C:\qwt-improved-install.log'
  # IT CALLS ./tools/qtest BY A RELATIVE PATH, so the stub is only reached with cwd in the stub
  # tree. Not a subshell: ok()/no() increment counters read after the call.
  local _cwd="$PWD"
  cd "$T" || { no_ "could not enter the stub tree"; return; }
  verify_installed testvm "$lbl" >/dev/null 2>&1
  RC=$?
  cd "$_cwd" || return
}

has(){ printf '%s' "$LINES" | grep -qa "$1"; }

# ---- 1. NOTHING MEASURED IS NOT A PASS --------------------------------------------------------
run_case noprecon "$RESULT_GREEN"
if [ "$RC" != 0 ] && has 'no PRECONDITION line at all'; then ok_ "no PRECONDITION line: INVALID-INSTRUMENT and it RETURNS non-zero"
else no_ "no PRECONDITION line is graded" "rc=$RC $LINES"; fi

# ---- 2. a cell that CLAIMS a pristine entry must have had one ---------------------------------
run_case dirty "$PRECON_DIRTY" "$CLEAN_MARK" "$RESULT_GREEN"
if [ "$RC" != 0 ] && has 'INVALID-PRECONDITION' && has 'claims a pristine entry'; then ok_ "a dirty entry under a pristine claim is INVALID-PRECONDITION, not a product FAIL"
else no_ "a dirty entry is INVALID-PRECONDITION" "rc=$RC $LINES"; fi

# ---- 3. THE 36-GREEN-LINES DEFECT: the clean-install marker is asserted POSITIVELY -------------
run_case nomark "$PRECON_PRISTINE" "$RESULT_GREEN"
if has 'no .clean install path. marker'; then ok_ "a pristine entry with NO clean-install marker is graded (the 36-green-lines defect)"
else no_ "a missing clean-install marker is graded" "$LINES"; fi
run_case withmark "$PRECON_PRISTINE" "$CLEAN_MARK" "$RESULT_GREEN"
if has 'entry was genuinely PRISTINE' && has 'CLEAN INSTALL path'; then ok_ "a genuine clean install gets BOTH positive markers"
else no_ "a genuine clean install is recognised" "$LINES"; fi

# ---- 4. no RESULT trailer -> nothing was measured ---------------------------------------------
run_case noresult "$PRECON_PRISTINE" "$CLEAN_MARK"
if [ "$RC" != 0 ] && has 'no installer RESULT trailer'; then ok_ "no RESULT trailer: INVALID-INSTRUMENT and it RETURNS non-zero"
else no_ "no RESULT trailer is graded" "rc=$RC $LINES"; fi

# ---- 5. THE 2026-09-16 SYSTEMIC FINDING: ok:true with an error-class flag is NOT green ---------
# Driven through the REAL mgmt/harness/result-flags.py, because that checker is the finding's fix.
run_case flagged "$PRECON_PRISTINE" "$CLEAN_MARK" "$RESULT_FLAGGED"
if has 'RESULT is NOT green'; then ok_ "ok:true carrying idd_failed is NOT green (the 2026-09-16 systemic finding)"
else no_ "ok:true with an error-class flag is caught" "$LINES"; fi
run_case green "$PRECON_PRISTINE" "$CLEAN_MARK" "$RESULT_GREEN"
if has 'RESULT ok:true and no error-class detail flags'; then ok_ "a genuinely clean trailer passes - so the check above is not refusing everything"
else no_ "a clean trailer passes" "$LINES"; fi

# ---- 6. the hash: the trailer that CARRIES the field, else the guest, then a verdict -----------
if has 'installed agent == release binary (installer RESULT)'; then ok_ "a trailer carrying the matching hash passes on the trailer"
else no_ "the trailer hash is used when present" "$LINES"; fi

# A STAGE-1 TRAILER HAS NO HASH FIELD. The measured 2026-09-08 defect reported "NOT the release
# binary" for a guest whose file matched; it must fall through to the guest instead.
printf '%s\r\n' "$ASHA" > "$T/hash.txt"
run_case stage1match "$PRECON_PRISTINE" "$CLEAN_MARK" "$RESULT_STAGE1"
if has 'hashed on the guest'; then ok_ "a stage-1 trailer falls through to the GUEST hash (the 2026-09-08 defect)"
else no_ "a stage-1 trailer falls through to the guest hash" "$LINES"; fi

printf '%s\r\n' "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" > "$T/hash.txt"
run_case stage1bad "$PRECON_PRISTINE" "$CLEAN_MARK" "$RESULT_STAGE1"
if has 'is NOT the release binary'; then ok_ "a guest whose binary really differs IS failed"
else no_ "a differing guest binary is failed" "$LINES"; fi

: > "$T/hash.txt"; QT_HASH_RC=1
run_case stage1unread "$PRECON_PRISTINE" "$CLEAN_MARK" "$RESULT_STAGE1"
if has 'could not hash the installed agent'; then ok_ "an unhashable guest is INVALID-INSTRUMENT, never a product failure"
else no_ "an unhashable guest is INVALID-INSTRUMENT" "$LINES"; fi
QT_HASH_RC=0; printf '%s\r\n' "$ASHA" > "$T/hash.txt"

# ---- 7. the reboot verdicts name WHICH terminal state -----------------------------------------
printf '%s\n' "brick-back: TERMINAL - the guest sat at the recovery screen" > "$T/r.log"
run_case_session(){ WSESSION_RC=$1; run_case "$2" "$PRECON_PRISTINE" "$CLEAN_MARK" "$RESULT_GREEN"; WSESSION_RC=0; }
run_case_session 1 brick
if [ "$RC" != 0 ] && has 'BRICKED'; then ok_ "w_session rc=1 is reported as BRICKED and stops the cell"
else no_ "w_session rc=1 is BRICKED" "rc=$RC $LINES"; fi
run_case_session 2 nosess
if [ "$RC" != 0 ] && has 'no session within 900s'; then ok_ "w_session rc=2 is reported as no-session-after-reboot, a different verdict"
else no_ "w_session rc=2 is its own verdict" "rc=$RC $LINES"; fi

# ---- 8. SEEN TO FAIL: the grader must not give one answer regardless of input ------------------
run_case green  "$PRECON_PRISTINE" "$CLEAN_MARK" "$RESULT_GREEN";   a="$OK/$NO"
run_case dirty2 "$PRECON_DIRTY"    "$CLEAN_MARK" "$RESULT_FLAGGED"; b="$OK/$NO"
if [ "$a" != "$b" ]; then ok_ "SEEN TO FAIL: the verdict tracks the planted log ($a vs $b)"
else no_ "SEEN TO FAIL: the verdict tracks the log" "both gave $a - the grader is inert"; fi

printf 'matrix-verifyinstalled-grade-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
