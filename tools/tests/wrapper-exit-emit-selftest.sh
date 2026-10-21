#!/bin/bash
# EXACTLY ONE LOG LINE PER EXIT, AND IT IS COMPILED AND RUN - NOT GREPPED.
#
# THE DEFECT THIS EXISTS FOR, measured in the 4.3.37 acceptance campaign on 2026-10-21, cell
# win10-clean: the wrapper emitted 141 ERROR lines reading "an output pump is still running at exit
# - the child exited and its output was drained" plus 3 for "the peer closed the vchan". Those are
# the two reasons the chain routes to Debug as an ordinary end. 141 of the cell's 145 undeclared
# error lines, against a max of 0, so the cell failed.
# THE CAUSE WAS TWO CHARACTERS: the final `else` had no braces, so it governed only the `if` under
# it and the LogError was a SIBLING of the whole chain - it ran on every pass, including the
# ordinary ends that had just logged Debug, and including the pumpsFinished path.
#
# WHY THE EXISTING SUITE DID NOT SEE IT. tools/tests/wrapper-exit-reason-selftest.sh counted how
# many times `LogError("an output pump` appears in the source text and required 1, and read the
# branch order out of a `grep -oE 'else if|else$|Log...' | tail -2`. The file does contain exactly
# one such call and the last branch IS a bare else; a missing brace changes which lines EXECUTE, not
# how many are written or in what order. Both predicates passed on the shipped defect. They were
# proxies for the property. Owner, on being shown it: "FUCK YOUR GREPS".
#
# SO THIS ONE EXECUTES. It extracts the chain between its markers, compiles it as C89 against stubs
# that record every emitted line, and runs it once per (reason, pumps, loss-reported, status) case.
# The property asserted is the one that matters: ONE line per exit, at the right LEVEL.
#
# AND IT PROVES ITS OWN COVERAGE. The first version of this file drove only `reason` and `pumps`, so
# the EXIT_REASON_DATA_ERROR-with-g_LossReported arm was never executed and a defect in it would
# have passed here exactly the way the brace did next door. Rather than assert coverage in a
# comment, the suite compiles the same chain a second time with --coverage, runs the identical case
# list, and FAILS if gcov reports any line of the extracted chain as never executed.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
SRC=core-agent/src/qrexec-wrapper/qrexec-wrapper.c
[ -r "$SRC" ] || { echo "FATAL: $SRC missing"; exit 2; }
CC=$(command -v cc || command -v gcc) || { echo "FATAL: no C compiler"; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/wrapexit-XXXXXX"); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

chain=$(awk '/WRAPPER-EXIT-CHAIN-BEGIN/,/WRAPPER-EXIT-CHAIN-END/' "$SRC" | sed '1,/\*\//d; $d')
if [ -z "$chain" ] || ! printf '%s' "$chain" | command grep -qa 'LogError("an output pump'; then
  echo "FATAL: could not extract the chain from $SRC between its markers"; exit 2
fi

# THE CASE LIST, used by the assertions AND by the coverage leg, so the coverage proof cannot be
# about a different set of runs than the one that was graded.
#   reason pumps loss status | expected emission ("" = nothing)
# reason ids match the enum: 1 PEER_CLOSED, 2 CHILD_DRAINED, 3 DATA_ERROR, 4 DRAIN_EXPIRED,
# 5 CTRL_STOP, 0 UNSET.
CASES='1 0 0 0|DEBUG|an ordinary end (peer closed) logs ONE Debug line and no ERROR
2 0 0 0|DEBUG|an ordinary end (child drained) logs ONE Debug line and no ERROR
4 0 0 0|DEBUG|the drain backstop expiring logs ONE Debug line - it already said TRUNCATED
3 0 1 0|DEBUG|a data error whose LOSS WAS ALREADY REPORTED logs ONE Debug line, not a second error
3 0 0 0|ERROR|a data error nobody has reported logs ONE ERROR line
3 0 0 5|ERROR|a data error WITH a Win32 status logs ONE ERROR line (and formats the status in)
5 0 0 0|ERROR|a console-control stop logs ONE ERROR line - a loss nobody else reported
0 0 0 0|ERROR|an unrecorded reason logs ONE ERROR line
2 1 0 0||pumps finished: the child is freed and NOTHING is logged'

# The harness: C89, Windows names stubbed to the minimum the chain touches. Every Log call appends
# its LEVEL to a list, so the test can count what the code actually emitted. Only the level and the
# arrival are asserted - the text and its argument types are the Windows build's business, and
# ExitReasonName's real return type is const WCHAR* against a format widened by L##format.
build() {  # $1=chain source, $2=extra cc flags -> compiles $T/t; returns cc's status
  cat > "$T/t.c" <<'HDR'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef int BOOL; typedef unsigned long DWORD; typedef void *HANDLE; typedef char WCHAR;
#define TRUE 1
#define FALSE 0
#define WAIT_OBJECT_0 0
#define ERROR_SUCCESS 0
#define RTL_NUMBER_OF(a) (sizeof(a)/sizeof((a)[0]))
typedef enum { EXIT_REASON_UNSET = 0, EXIT_REASON_PEER_CLOSED, EXIT_REASON_CHILD_DRAINED,
               EXIT_REASON_DATA_ERROR, EXIT_REASON_DRAIN_EXPIRED, EXIT_REASON_CTRL_STOP } EXIT_REASON;
static EXIT_REASON g_exitReason = EXIT_REASON_UNSET;
static BOOL g_LossReported = FALSE;
static DWORD g_DataErrorStatus = ERROR_SUCCESS;
static char g_levels[16][8];
static int g_n = 0;
static void emit(const char *lvl) { if (g_n < 16) { strcpy(g_levels[g_n], lvl); g_n++; } }
/* GNU variadic macros: accepted in gnu89 mode, and the arities in the chain differ per arm */
#define LogDebug(...) emit("DEBUG")
#define LogError(...) emit("ERROR")
#define StringCchPrintf(buf, n, fmt, v) ((void)snprintf((buf), (n), " (%lu)", (unsigned long)(v)))
static const WCHAR *ExitReasonName(EXIT_REASON r) {
    switch (r) {
    case EXIT_REASON_PEER_CLOSED:   return "the peer closed the vchan";
    case EXIT_REASON_CHILD_DRAINED: return "the child exited and its output was drained";
    case EXIT_REASON_DATA_ERROR:    return "a data error";
    case EXIT_REASON_DRAIN_EXPIRED: return "the drain backstop expired";
    case EXIT_REASON_CTRL_STOP:     return "a console control stop";
    default:                        return "not recorded";
    }
}
struct CHILD { HANDLE StdoutThread; HANDLE StderrThread; };
static int WaitForSingleObject(HANDLE h, DWORD ms) { (void)ms; return h ? 1 : WAIT_OBJECT_0; }
static void CloseHandle(HANDLE h) { (void)h; }
int main(int argc, char **argv)
{
    struct CHILD *child;
    BOOL pumpsFinished;   /* driven by argv[2]: the lines that compute it sit ABOVE the marker */
    WCHAR whyBuf[64];
    int pumps;
    if (argc < 5) return 2;
    g_exitReason      = (EXIT_REASON)atoi(argv[1]);
    pumps             = atoi(argv[2]);
    g_LossReported    = atoi(argv[3]) ? TRUE : FALSE;
    g_DataErrorStatus = (DWORD)atoi(argv[4]);
    pumpsFinished     = pumps ? TRUE : FALSE;
    whyBuf[0] = 0;
    child = (struct CHILD *)calloc(1, sizeof(*child));
    /* a non-NULL handle means the stub reports the pump as STILL RUNNING */
    child->StdoutThread = pumps ? NULL : (HANDLE)1;
    child->StderrThread = NULL;
    {
/*CHAINBEGIN*/
HDR
  printf '%s\n' "$1" >> "$T/t.c"
  cat >> "$T/t.c" <<'FTR'
/*CHAINEND*/
    }
    {
        int i;
        for (i = 0; i < g_n; i++) printf("%s\n", g_levels[i]);
    }
    return 0;
}
FTR
  # -std=gnu89: the unit is C89 by the project's rule, but its comments are // style and the chain
  # is extracted VERBATIM - rewriting the comments to compile it would mean testing a text that is
  # not the shipped text. gnu89 keeps C89 semantics and accepts the comments.
  # shellcheck disable=SC2086
  "$CC" -std=gnu89 -w $2 -o "$T/t" "$T/t.c" 2>"$T/cc.err"
}

if build "$chain" ""; then
  ok "the shipped chain compiles as C89 against the stubs ($(printf '%s\n' "$chain" | wc -l) lines extracted)"
else
  no "the extracted chain does not compile" "$(head -3 "$T/cc.err")"
  echo; echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi

# run_cases prints one line per case that does NOT emit what it should, against whatever binary
# $T/t currently is. The clean run reports each case; the controls below re-use it to say exactly
# WHICH cases a given defect breaks.
run_cases() {
  while IFS='|' read -r args want label; do
    [ -n "$args" ] || continue
    # shellcheck disable=SC2086
    local got; got=$("$T/t" $args 2>/dev/null)
    [ "$got" = "$want" ] || printf '%s\n' "$label"
  done <<< "$CASES"
}
# the cases whose expected emission is $1 - derived FROM the case list, so a control's expectation
# cannot drift away from it when a case is added
cases_wanting() { while IFS='|' read -r a w l; do [ -n "$a" ] && [ "$w" = "$1" ] && printf '%s\n' "$l"; done <<< "$CASES"; }

# ---- THE PROPERTY: one line per exit, at the right level ----------------------------------------
while IFS='|' read -r args want label; do
  [ -n "$args" ] || continue
  # shellcheck disable=SC2086
  got=$("$T/t" $args 2>/dev/null)
  if [ "$got" = "$want" ]; then ok "$label"
  else no "$label" "args[$args] got [$(printf '%s' "$got" | tr '\n' ',')] want [$want]"; fi
done <<< "$CASES"

# ---- COVERAGE: no line of the chain may go unexecuted by the list above ------------------------
# This is what caught the first version of this file: it drove reason and pumps only, so the
# already-reported-loss arm never ran. gcov is asked, not trusted to a comment.
if command -v gcov >/dev/null && build "$chain" "--coverage"; then
  while IFS='|' read -r args _ _; do
    [ -n "$args" ] || continue
    # shellcheck disable=SC2086
    "$T/t" $args >/dev/null 2>&1
  done <<< "$CASES"
  if (cd "$T" && gcov -o . t.c >/dev/null 2>&1) && [ -f "$T/t.c.gcov" ]; then
    # gcov lines are "<count>:<lineno>:<source>". Unexecuted executable lines carry #####.
    dead=$(awk -F: '
      /\/\*CHAINBEGIN\*\// { inchain = 1; next }
      /\/\*CHAINEND\*\//   { inchain = 0 }
      inchain && $1 ~ /#####/ { gsub(/^[ \t]+|[ \t]+$/, "", $3); printf "%s:%s ", $2, substr($3, 1, 60) }
    ' "$T/t.c.gcov")
    if [ -z "$dead" ]; then
      ok "COVERAGE: every executable line of the chain was reached by the case list above"
    else
      no "COVERAGE: lines of the chain no case executes" "$dead"
    fi
  else
    no "COVERAGE: gcov produced no report" "$(ls "$T" | tr '\n' ' ')"
  fi
else
  no "COVERAGE: no gcov, or the coverage build failed" "$(head -2 "$T/cc.err")"
fi

# ---- SEEN TO FAIL ------------------------------------------------------------------------------
# A check never seen to fail is decoration. Each control reintroduces ONE defect into the extracted
# chain and nothing else, so the leg below it can only change because of that defect.
seen_to_fail() { # $1=label $2=mutated chain $3=case args $4=expected DEFECTIVE emission
  if ! printf '%s' "$2" | command grep -qa 'LogError("an output pump'; then
    no "$1" "the mutation destroyed the chain instead of changing one thing"; return
  fi
  if ! build "$2" ""; then no "$1" "the mutated chain did not compile: $(head -2 "$T/cc.err")"; return; fi
  # shellcheck disable=SC2086
  local got; got=$("$T/t" $3 2>/dev/null)
  if [ "$got" = "$4" ]; then ok "$1"
  else no "$1" "the control did not reproduce the defect: got [$(printf '%s' "$got" | tr '\n' ',')] want [$(printf '%s' "$4" | tr '\n' ',')]"; fi
}

# Control 1: the shipped defect. Remove exactly the two braces of the final else and nothing else.
# LINE-BASED on purpose: the first version searched for the last occurrence of the word "else",
# which is in a COMMENT in this block, and then looked for a brace that is not there. The matcher
# carried the text it was searching for, again.
nobrace=$(printf '%s' "$chain" | python3 -c '
import sys
lines = sys.stdin.read().split("\n")
ei = max(i for i, l in enumerate(lines) if l.strip() == "else")
oi = next(i for i in range(ei + 1, len(lines)) if lines[i].strip() == "{")
ci = max(i for i, l in enumerate(lines) if l.strip() == "}")
sys.stdout.write("\n".join(l for i, l in enumerate(lines) if i not in (oi, ci)))
')
if [ "$(printf '%s' "$nobrace" | command grep -c '{')" -lt "$(printf '%s' "$chain" | command grep -c '{')" ]; then
  seen_to_fail "SEEN TO FAIL: without the braces an ordinary end logs BOTH Debug and ERROR - the shipped defect, reproduced" \
               "$nobrace" "2 0 0 0" "DEBUG
ERROR"
else
  no "SEEN TO FAIL (braces): could not build the control" "the edit removed no brace pair"
fi

# Control 2: make the already-reported-loss demotion UNCONDITIONAL. It must then swallow a data
# error that nothing else has reported - the exact thing the g_LossReported guard is there for.
# This replaces a grep for the string 'EXIT_REASON_DATA_ERROR && g_LossReported' with a run.
uncond=$(printf '%s' "$chain" | sed 's/EXIT_REASON_DATA_ERROR \&\& g_LossReported/EXIT_REASON_DATA_ERROR/')
if [ "$uncond" != "$chain" ]; then
  seen_to_fail "SEEN TO FAIL: an unconditional loss demotion sends an UNREPORTED data error to Debug" \
               "$uncond" "3 0 0 5" "DEBUG"
else
  no "SEEN TO FAIL (demotion): could not build the control" "the g_LossReported guard is not where it was"
fi

# Controls 3 and 4: EVERY CASE ASSERTION IS SEEN TO FAIL. The two controls above only break two of
# the nine cases, so the other seven had never been watched fail and a wrong expectation in one of
# them would have passed unnoticed - inert, in exactly the way the greps this file replaced were.
# Swapping the chain's levels is the one defect that must break all the cases of one level and none
# of the other, and the expected red set is read out of CASES rather than written down twice.
level_control() { # $1=label $2=sed script on the chain $3=the `want` whose cases must ALL go red
  local mutant got expected
  mutant=$(printf '%s' "$chain" | sed "$2")
  if [ "$mutant" = "$chain" ]; then no "$1" "the level swap matched nothing in the chain"; return; fi
  if ! build "$mutant" ""; then no "$1" "the swapped chain did not compile: $(head -2 "$T/cc.err")"; return; fi
  got=$(run_cases | sort)
  expected=$(cases_wanting "$3" | sort)
  if [ "$got" = "$expected" ]; then
    ok "$1 ($(printf '%s\n' "$expected" | wc -l) case(s) red, and only those)"
  else
    no "$1" "red [$(printf '%s' "$got" | tr '\n' ';')] expected exactly [$(printf '%s' "$expected" | tr '\n' ';')]"
  fi
}
level_control "SEEN TO FAIL: emitting the ordinary ends at ERROR turns every Debug case red, and only those" \
              's/LogDebug(/LogError(/g' DEBUG
level_control "SEEN TO FAIL: emitting the loud cases at Debug turns every ERROR case red, and only those" \
              's/LogError(/LogDebug(/g' ERROR

# The compile check at the top is the one assertion with no control beside it, and it cannot be
# inert: if it fails nothing below it runs, and if it passes the binary the cases ran against
# exists. An extraction that silently returned the wrong region is caught by the COVERAGE leg and
# by the two level controls, which both require the real arms to be present to come out right.

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
