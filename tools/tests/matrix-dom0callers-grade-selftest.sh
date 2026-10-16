#!/bin/bash
# matrix-dom0callers-grade-selftest.sh - the grader for the goal's SECOND clause had no suite.
#
# WHAT IT GRADES. grade_dom0_callers() is where the campaign measures "qrexec behavior is aligned
# with dom0 callers: updaters and start menu" - the updater channel (dom0 takes stdout as the agent's
# log and parses bare floats on stderr for the Update GUI's progress bar) and the start-menu stream
# (receive.py ignores what it cannot parse IN SILENCE).
#
# WHY THIS EXISTS. Its sibling grade_cell_logsweep() was deliberately made a function "so it can be
# exercised" and has had a suite for days. This one - the grader of the clause the release goal names
# - had NONE, so whether the campaign can measure its own goal was itself unmeasured. A four-hour run
# whose clause-2 grader mis-grades produces a worthless verdict, and that is discoverable offline in
# seconds. matrix.sh's own notes record the channel going unmeasured for eight runs
# (CALLERCHECKATENDONLY), which is what a grader nobody tests looks like from the outside.
#
# HOW IT IS DRIVEN. The SHIPPED function is extracted from matrix.sh and run with the two checker
# scripts stubbed on a temporary PATH-like override, plus w_state/w_alive/ok/no. A transcription
# here would pass while the file rotted.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

T=$(mktemp -d "${TMPDIR:-/tmp}/matrix-dom0callers.XXXXXX") || exit 2
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT INT TERM

# $M IS THE FUNCTION'S OWN VARIABLE (it writes evidence to "$M/<label>-vmexec.out"), so the path to
# matrix.sh gets a different name. Sharing it made the call-site greps below read a DIRECTORY.
MSH=$(cd "$(dirname "$(ls mgmt/harness/matri*.sh | head -1)")" && pwd)/$(basename "$(ls mgmt/harness/matri*.sh | head -1)")
eval "$(sed -n '/^grade_dom0_callers(){/,/^}$/p' "$MSH")"
declare -f grade_dom0_callers >/dev/null || { echo "FAIL could not extract grade_dom0_callers from $MSH"; exit 1; }

pass=0; fail=0
ok_(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no_(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# THE STUBS LIVE IN A THROWAWAY TREE, NOT IN THE REPO. The function calls its checkers by
# repo-relative path (./mgmt/harness/...), so an earlier version of this suite OVERWROTE the two
# tracked scripts and restored them from a trap. That is a contamination risk with no upside: a
# SIGKILL - and batteries do get killed - would leave stubs in tracked files. Instead the case runs
# with cwd set to a temp tree holding only the stubs, so the repo is never written to at all.
VMEXEC_REL=mgmt/harness/vmexec-channel-check.sh
CALLERS_REL=mgmt/harness/dom0-callers-check.sh
for f in "$VMEXEC_REL" "$CALLERS_REL"; do
    [ -f "$f" ] || { echo "FAIL $f does not exist - grade_dom0_callers calls it"; exit 1; }
done
mkdir -p "$T/tree/mgmt/harness"
stub(){ printf '#!/bin/bash\nexit %s\n' "$2" > "$1"; chmod +x "$1"; }

M_DIR="$T/m"; mkdir -p "$M_DIR"

run_case(){ # $1=state $2=alive(0/1) $3=vmexec rc $4=callers rc
  stub "$T/tree/$VMEXEC_REL"  "$3"
  stub "$T/tree/$CALLERS_REL" "$4"
  OK=0; NO=0; LINES=""
  # shellcheck disable=SC2317
  ok(){ OK=$((OK+1)); LINES="$LINES[OK] $*"$'\n'; }
  no(){ NO=$((NO+1)); LINES="$LINES[NO] $*"$'\n'; }
  w_state(){ printf '%s\n' "$1x" >/dev/null; printf '%s\n' "$STATE"; }
  w_alive(){ return "$ALIVE"; }
  STATE="$1"; ALIVE="$2"; M="$M_DIR"
  # cwd is the throwaway tree, so ./mgmt/harness/... resolves to the stubs and never to the repo.
  # NOT A SUBSHELL: ok()/no() increment counters this function reads afterwards, and in a subshell
  # every count came back 0 - the suite then reported the grader "inert" when it was the harness.
  local _cwd="$PWD"
  cd "$T/tree" || { no_ "could not enter the stub tree"; return; }
  grade_dom0_callers testvm cellA
  cd "$_cwd" || return
}

# ---- 1. a guest that is not answering is GRADED, never silently skipped ------------------------
run_case Halted 1 0 0
if [ "$NO" = 1 ] && [ "$OK" = 0 ]; then ok_ "a Halted guest is graded as not-measurable, not passed over"
else no_ "a Halted guest is graded" "OK=$OK NO=$NO $LINES"; fi
if printf '%s' "$LINES" | grep -qa 'could not be measured'; then ok_ "and the message says the channel could not be measured"
else no_ "the message says why" "$LINES"; fi
run_case Running 1 0 0
if [ "$NO" = 1 ] && [ "$OK" = 0 ]; then ok_ "Running but not alive is graded too - state alone is not liveness"
else no_ "Running but not alive is graded" "OK=$OK NO=$NO $LINES"; fi

# ---- 2. both channels aligned -> two passes, no failures ---------------------------------------
# Without this the checks above would pass by grading everything as broken.
run_case Running 0 0 0
if [ "$OK" = 2 ] && [ "$NO" = 0 ]; then ok_ "both channels aligned: TWO passes, nothing graded"
else no_ "both channels aligned" "OK=$OK NO=$NO $LINES"; fi

# ---- 3. EACH channel fails on its own, and one failure never masks the other -------------------
run_case Running 0 1 0
if [ "$NO" = 1 ] && [ "$OK" = 1 ] && printf '%s' "$LINES" | grep -qa 'dom0 caller channel is NOT aligned'; then
  ok_ "the UPDATER channel failing is named, and the start-menu check still runs"
else no_ "the updater channel failing is named and start-menu still runs" "OK=$OK NO=$NO $LINES"; fi

run_case Running 0 0 1
if [ "$NO" = 1 ] && [ "$OK" = 1 ] && printf '%s' "$LINES" | grep -qa 'start-menu caller is NOT aligned'; then
  ok_ "the START-MENU channel failing is named, and the updater check still counted"
else no_ "the start-menu channel failing is named" "OK=$OK NO=$NO $LINES"; fi

run_case Running 0 1 1
if [ "$NO" = 2 ] && [ "$OK" = 0 ]; then ok_ "both channels failing yields TWO failures, not one"
else no_ "both channels failing yields two failures" "OK=$OK NO=$NO $LINES"; fi

# ---- 4. the measured historical defect: it must be called PER CELL, while the guest is up ------
# Run 8 logged ZERO lines matching VMEXEC because both checks sat in the end-of-campaign loop, and
# every cell halts, parks or removes its subject as its last act. The fix was the CALL SITE.
if grep -qa 'grade_dom0_callers "\$vm" "\$lbl"' "$MSH"; then ok_ "it is called from the per-cell grade, where the guest is up"
else no_ "it is called from the per-cell grade" "no per-cell call site found - the run-8 defect is back"; fi
if sed -n '/^accept_grade(){/,/^}$/p' "$MSH" | grep -qa 'grade_dom0_callers'; then ok_ "and that call site is accept_grade, beside every other per-cell assertion"
else no_ "the call site is accept_grade" "it has moved out of the per-cell battery"; fi

# ---- 5. SEEN TO FAIL: a grader that cannot fail ------------------------------------------------
# If the function ever stops calling the checkers' exit status, every case above collapses to the
# same answer. Driven by making the checkers disagree and requiring the verdicts to differ.
run_case Running 0 0 0; a="$OK/$NO"
run_case Running 0 1 1; b="$OK/$NO"
if [ "$a" != "$b" ]; then ok_ "SEEN TO FAIL: the verdict tracks the checkers' exit status ($a vs $b)"
else no_ "SEEN TO FAIL: the verdict tracks the checkers" "both cases gave $a - the grader is inert"; fi

printf 'matrix-dom0callers-grade-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
