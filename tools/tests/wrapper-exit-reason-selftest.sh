#!/usr/bin/env bash
# UNRELIABLE - DROPPED FROM PREFLIGHT 2026-10-25, owner's directive: never write a test for a
# test, and never fault-inject a harness fix as part of the harness. This file mutates another
# TEST or HARNESS file and runs the mutants, so a defect in it corrupts both arms. It is not in
# tools/tests/offline-suites.txt, nothing runs it, and it is NOT to be fixed or re-registered
# without the owner saying so. See TESTFORATESTRECURSION in findings/issues.md.
# wrapper-exit-reason-selftest.sh - the qrexec-wrapper exit-reason classification, OFFLINE.
# No guest, no CI, no Windows compiler: this is a structural check on the source.
#
# WHAT IT GUARDS. The cleanup printed one warning for a pump still running at exit - "the peer hung
# up first, a data error or a stop" - asserting three causes without knowing which. On a
# guest-initiated call the ordinary end is the peer closing the vchan, a path that never reaches the
# post-exit drain, so the pumps ARE still running and EVERY SUCCESSFUL CALL logged it: 229 lines in
# one boot, 226 of them inside two minutes, 227 of the 229 per-call logs carrying nothing else.
# Jev on the RCA: root_cause_established 0.74, fix_is_real 0.86, verdict holds-with-citation-errors 1.00.
#
# The fix names the reason at each exit and reports accordingly - expected ends at Debug, the drain
# backstop at Debug because it already logged a TRUNCATED transfer, and a data error, a stop or an
# UNRECORDED reason at ERROR, because output may not have reached the peer. The property that makes
# that trustworthy is every_exit_records_a_reason: every exit path must record one, so a path
# someone adds later falls to the loud branch rather than being silently classified as fine.
#
# It also clears the stale status on the ordinary path: ERROR_INVALID_FUNCTION was set at the top of
# every loop pass and never reassigned when the peer closed, so a fully successful guest-initiated
# call returned 1 from wmain as its process exit code.
#
# THE EMISSION ITSELF IS NOT CHECKED HERE - see tools/tests/wrapper-exit-emit-selftest.sh, which
# compiles the chain and runs it. Two checks that used to live here counted the chain's LogError and
# LogDebug calls in the source ("error=1, debug=3") and read its branch order out of a
# `grep -oE 'else if|else$|Log(Debug|Error)\("an output pump' | tail -2`. Both PASSED on the
# revision that shipped the brace defect: one call is still written once and the last branch is
# still a bare else, because a missing brace changes which lines EXECUTE and nothing countable in
# the text moves. Cost: 141 undeclared ERROR lines on cell win10-clean of the 4.3.37 campaign,
# 2026-10-21, against a max of 0. Owner: "FUCK YOUR GREPS".
#
# SO WHAT REMAINS HERE IS TEXT ABOUT TEXT - a string the log must contain, a bound that must not
# move, a flag that must be maintained - and each such assertion is ONE check with ONE id and ONE
# mutation that has been seen to turn it red. The ids are per PROPERTY, not per block: the earlier
# version had `if A && B && C` under a single id with a single mutation, so two thirds of its
# conjuncts had never failed in front of anyone while the accounting called the id covered.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# WRAPPER_SRC is how the mutation harness at the bottom re-runs these same checks against a copy of
# the unit with ONE defect reintroduced. Unset, it is the shipped source.
SRC="${WRAPPER_SRC:-$ROOT/core-agent/src/qrexec-wrapper/qrexec-wrapper.c}"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$SRC" ] || { echo "FAIL  $SRC is missing - nothing ran (missing data fails)"; exit 2; }

# COMMENTS STRIPPED, ALWAYS. Every assertion below is about what the CODE says, and this file's own
# comments quote the strings it checks for on purpose. drain_expiry_says_truncated was written as a
# plain grep and was satisfied by the comment at :763 that quotes the log line - the mutation that
# removed the real LogError at :1863 left it GREEN. The mutation harness at the bottom is what
# surfaced that; a check a comment can satisfy is a check the code can lose.
code_of(){ python3 -c "
import re,sys
s=open(sys.argv[1],encoding='utf-8').read()
s=re.sub(r'/\*.*?\*/','',s,flags=re.S); s=re.sub(r'//[^\n]*','',s)
sys.stdout.write(s)" "$1"; }
CODE=$(code_of "$SRC")
# one id, one property: the CODE must contain this exact text, and $3 says why it has to
need(){ # $1=id  $2=exact text  $3=meaning
  if printf '%s' "$CODE" | command grep -qF "$2"; then ok "$1: $3"; else bad "$1: $3" "absent from the code: $2"; fi
}
# and the inverse, for text that must have GONE
gone(){ # $1=id  $2=extended regex  $3=meaning
  if printf '%s' "$CODE" | command grep -qE "$2"; then bad "$1: $3" "still present: $2"; else ok "$1: $3"; fi
}
# THE ONE EXEMPTION, and it is narrow: the extraction markers ARE comments by design, because the
# compiled suite has to delimit a region of code without being part of it. Everything else goes
# through need/gone above.
need_raw(){ # $1=id  $2=exact text that is deliberately a comment  $3=meaning
  if command grep -qF "$2" "$SRC"; then ok "$1: $3"; else bad "$1: $3" "absent from the unit: $2"; fi
}

# ---- 1. the reason exists, is an enum, and every member is reported by name --------------------
miss=""
for m in EXIT_REASON_UNSET EXIT_REASON_PEER_CLOSED EXIT_REASON_CHILD_DRAINED \
         EXIT_REASON_DATA_ERROR EXIT_REASON_DRAIN_EXPIRED EXIT_REASON_CTRL_STOP; do
  printf '%s' "$CODE" | command grep -qF "$m" || miss="$miss [$m]"
done
[ -z "$miss" ] && ok "reason_enum_complete: all six exit reasons are declared" \
               || bad "reason_enum_complete: missing$miss"
# WCHAR, not char: the log format is widened by L##format, so a narrow name prints as garbage
need reason_name_is_wide 'static const WCHAR *ExitReasonName' \
     'ExitReasonName returns a wide string, which is what the widened format can print'
# every declared member must appear in the name switch, or a log line reads "not recorded"
nm_block=$(sed -n '/ExitReasonName(EXIT_REASON r)/,/^}/p' "$SRC")
unnamed=""
for m in EXIT_REASON_PEER_CLOSED EXIT_REASON_CHILD_DRAINED EXIT_REASON_DATA_ERROR \
         EXIT_REASON_DRAIN_EXPIRED EXIT_REASON_CTRL_STOP; do
  printf '%s' "$nm_block" | command grep -qF "$m" || unnamed="$unnamed [$m]"
done
[ -z "$unnamed" ] && ok "every_reason_has_a_name: the name switch covers every member" \
                  || bad "every_reason_has_a_name: not in the switch:$unnamed"

# ---- 2. EVERY EXIT PATH RECORDS A REASON -------------------------------------------------------
# This is the check the classification rests on. Each `run = FALSE` in the event loop must have a
# g_exitReason assignment within a few lines of it; the ones inside the drain's inner wait are
# `break`s out of that wait, not loop exits, and are excluded by looking only at run = FALSE.
r=$(python3 - "$SRC" <<'PY' 2>&1
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.splitlines()
# the event loop only: from `while (run)` to the comment that follows it
try:
    start = next(i for i, l in enumerate(lines) if l.strip() == "while (run)")
except StopIteration:
    print("BAD could not find the event loop"); raise SystemExit
end = next((i for i in range(start, len(lines)) if "The pump thread handles stay open" in lines[i]), len(lines))
bad = []
for i in range(start, end):
    if re.search(r"\brun = FALSE\b", lines[i]):
        window = "\n".join(lines[max(start, i - 12):i + 2])
        if "g_exitReason" not in window:
            bad.append((i + 1, lines[i].strip()))
print("OK %d exit path(s) all record a reason" % sum(1 for i in range(start, end) if re.search(r"\brun = FALSE\b", lines[i]))
      if not bad else "BAD unrecorded: " + "; ".join("%d:%s" % b for b in bad))
PY
)
case "$r" in
  OK*) ok "every_exit_records_a_reason: $r" ;;
  *)   bad "every_exit_records_a_reason: $r" ;;
esac

# ---- 3. the compiled suite must have its chain to extract -------------------------------------
# wrapper-exit-emit-selftest.sh reads between these two markers. Without either one it extracts
# nothing, and a suite with nothing to compile is a suite that cannot fail.
need_raw chain_marker_begin 'WRAPPER-EXIT-CHAIN-BEGIN' 'the compiled suite has a start marker to extract from'
need_raw chain_marker_end   'WRAPPER-EXIT-CHAIN-END'   'the compiled suite has an end marker to extract to'

# ---- 4. AN ERROR MUST NAME ITS OWN CAUSE ------------------------------------------------------
# EXIT_REASON_DATA_ERROR's name is the string "a data error", and the caller that latches it was
# DISCARDING the Win32 status HandleDataMessage had just returned - so the line that breaches
# error_lines_undeclared said nothing about why. Measured on acceptance run 39476792836,
# 2026-10-20: three cells breached on that line and the cause could not be recovered from any
# artefact, because the code knew it and threw it away. The owner's rule on that metric is that an
# error line our code wrote, whose cause this run did not declare, is a defect to fix AT ITS CAUSE.
need data_error_names_status 'HandleDataMessage failed with 0x%x' \
     'the exit line reports the Win32 status, not just the label'
need data_error_keeps_first_status 'if (g_DataErrorStatus == ERROR_SUCCESS)' \
     'the FIRST status is kept, not the last - a later failure is a consequence of it'
# the old unconditional warning, which asserted three causes at once, must be GONE. Matched as a
# LogWarning CALL, not as text: the comment above the enum quotes the old line on purpose, and a
# check that cannot tell those apart would be unfixable.
gone old_warning_gone 'LogWarning\("an output pump is still running' \
     'the three-causes-at-once LogWarning is gone'

# ---- 5. the ordinary path no longer returns a failure -----------------------------------------
pc=$(sed -n '/vchan closed - drained/,/run = FALSE;/p' "$SRC")
if printf '%s' "$pc" | command grep -qF 'status = ERROR_SUCCESS;'; then
  ok "peer_closed_clears_status: the peer-closed path clears the stale ERROR_INVALID_FUNCTION"
else
  bad "peer_closed_clears_status: a successful guest-initiated call still returns ERROR_INVALID_FUNCTION"
fi
if printf '%s' "$pc" | command grep -qF 'EXIT_REASON_PEER_CLOSED'; then
  ok "peer_closed_records_reason: that same path latches the reason, so the cleanup can classify it"
else
  bad "peer_closed_records_reason: the peer-closed path does not record its reason"
fi

# ---- 6. THE CONSOLE-CONTROL CLOSE REPORTS ONLY WHAT CAN LEAVE SOMETHING BEHIND ----------------
# "data vchan NOT confirmed closed within 3000 ms of console control event 6 - exiting anyway" was
# one of the ten error lines the new binary wrote on win11r-logvol (2026-10-08). The ERROR is right
# when a ring mapping is left for the kernel to reclaim at process exit - the path the 2026-08-20
# NMI dump caught spinning on a TLB shootdown - and MEANINGLESS when there was never a data vchan,
# which is the commonest case here: a client that went away before libvchan_client_init could
# connect. Nothing is mapped then, and no cleanup will ever signal the close, so the error was
# guaranteed and said nothing.
need vchan_open_flag_exists 'g_VchanOpen' \
     'the handler can tell "no vchan was ever open" from "one was"'
need vchan_open_flag_set 'InterlockedExchange(&g_VchanOpen, 1)' \
     'the flag is set where InitVchan succeeds'
need vchan_open_flag_cleared 'InterlockedExchange(&g_VchanOpen, 0)' \
     'the flag is cleared where the cleanup closes the vchan, so it cannot lie'
need empty_close_is_quiet 'no data vchan to close at console control event' \
     'the never-had-a-vchan case is reported at INFO, not as an ERROR that says nothing'
need empty_close_says_why 'so its mapping is reclaimed at process exit' \
     'that INFO says why nothing is leaked'
need close_error_names_closing 'had begun closing it' \
     'the remaining ERROR names the cleanup-had-started state'
need close_error_names_not_reached 'never reached the close' \
     'and it names the cleanup-never-got-there state - the two are different bugs'

# ---- 7. NOTHING WAS MADE QUIETER BY A TIMEOUT, A RETRY OR A WATCHDOG -------------------------
# The house rule: never a timeout as a fix. The 120 s backstop predates this change.
need drain_bound_unchanged '#define DRAIN_TIMEOUT_MS (120 * 1000)' \
     'the 120 s drain bound is where it was'
need drain_expiry_says_truncated 'this transfer is TRUNCATED' \
     'and when it expires it still says the transfer was truncated, loudly, at its own site'
# no_new_wait, REANCHORED 2026-10-22. It used to count Sleep() in this file against the revision
# that still carried the old unconditional warning - 1df5a7b1, twenty-odd commits back - and report
# the outcome in the words of a verdict on one diff: "2 Sleep() calls against 1 before the fix - a
# wait was added". It went red when 9ad4dfc2 added QwWaitForInteractiveLogon's poll under an
# entirely different mandate, and it stayed red, accusing every later change of that one. A span
# cannot scope a diff, and a check whose red means "something, sometime, somewhere in here" is a
# check nobody can act on - it sat red while the braces shipped past it.
# So the waits are DECLARED. Each allowed site is named with the reason it is allowed; anything
# else, added OR removed, fails. Comments are stripped first: a plain grep counts the comment at
# :1143 that mentions the "Sleep(1)-polling send path" as a call.
# ALLOWED, one line per site, as "<argument expression>  <function>  <why>":
#   step   QwWaitForInteractiveLogon   poll for a logon that only WTS can report, bounded by timeoutMs
#   1      VchanWaitForSendSpace       wait for ring room; the alternative is dropping the reply
waitsites(){ python3 -c "
import re,sys
s=sys.stdin.read()
s=re.sub(r'/\*.*?\*/','',s,flags=re.S); s=re.sub(r'//[^\n]*','',s)
print('\n'.join(sorted(a.strip() for a in re.findall(r'\bSleep\s*\(([^)]*)\)', s))))"; }
declared=$(printf '%s\n' 1 step)
found=$(waitsites < "$SRC")
if [ "$found" = "$declared" ]; then
  ok "no_new_wait: the only waits in the unit are the two declared ones ($(printf '%s' "$found" | tr '\n' ' '))"
else
  bad "no_new_wait: the wait sites are not the declared set" \
      "found [$(printf '%s' "$found" | tr '\n' ' ')] declared [$(printf '%s' "$declared" | tr '\n' ' ')] - declare it above with its reason, or put it back"
fi

# ---- 8. EVERY CHECK ABOVE IS SEEN TO FAIL, ONE DEFECT AT A TIME -------------------------------
# WHAT WAS HERE. One leg read the last revision that still carried the old unconditional warning -
# `git log -S'the peer hung up first...'` in the SUBMODULE - and asserted three markers were absent
# from it. Two problems, and they compounded:
#   it covered 3 of 13 checks, so ten of them had never been seen to fail at all; and
#   it needed the submodule's full history, which no CI job here is known to carry (actions/checkout
#   fetch-depth applies to the superproject), which is why this suite was never in
#   tools/tests/offline-suites.txt. Nothing ran it on a schedule, and that is how its no_new_wait
#   leg sat red for days and how the two emission checks it used to carry passed on the shipped
#   brace defect without anyone seeing either fact. The exclusion caused the rot.
# NOW: no git, no history, no network. Each mutation reintroduces exactly ONE defect into a COPY of
# the unit and re-runs this whole file against it, requiring the NAMED check to go red.
if [ -z "${WRAPPER_MUTANT:-}" ]; then
  MT=$(mktemp -d "${TMPDIR:-/tmp}/wrapperexitmut-XXXXXX")
  WATCHED=""   # the ids a mutation was OBSERVED to turn red, accumulated from the runs themselves
  mutate() { # $1=target check id  $2=what the defect is  $3=python mutation on the text in `s`
    local m="$MT/$1.c" out
    python3 - "$SRC" "$m" <<PY
import sys
s = open(sys.argv[1], encoding="utf-8").read()
$3
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY
    if [ ! -s "$m" ] || cmp -s "$m" "$SRC"; then
      bad "seen_to_fail[$1]: the mutation changed nothing, so it proves nothing" "$2"; return
    fi
    out=$(WRAPPER_MUTANT=1 WRAPPER_SRC="$m" bash "$0" 2>&1)
    if printf '%s' "$out" | command grep -qE "^FAIL  $1:"; then
      WATCHED="$WATCHED $1"
      ok "seen_to_fail[$1]: goes red when $2"
    else
      bad "seen_to_fail[$1]: stayed GREEN when $2" "the check cannot detect the defect it is named for"
    fi
  }
  # One per property above. Matched by regex where column spacing would otherwise be baked in: the
  # literal form of the CTRL_STOP mutation silently matched nothing on its first draft, and the
  # "changed nothing, so it proves nothing" guard is the only reason that surfaced as a red.
  mutate reason_enum_complete 'an exit reason is deleted from the enum' \
    's = s.replace("EXIT_REASON_CTRL_STOP", "EXIT_REASON_CTRL_HALT")'
  mutate reason_name_is_wide 'ExitReasonName returns a narrow string the widened format cannot print' \
    's = s.replace("static const WCHAR *ExitReasonName", "static const char *ExitReasonName", 1)'
  mutate every_reason_has_a_name 'a reason is dropped from the name switch' \
    'import re; s = re.sub(r"\n[ \t]*case EXIT_REASON_CTRL_STOP:[^\n]*\n", "\n", s, count=1)'
  mutate every_exit_records_a_reason 'an exit path stops recording its reason' \
    'import re; s = re.sub(r"\n[ \t]*g_exitReason = EXIT_REASON_PEER_CLOSED;", "", s, count=1)'
  mutate chain_marker_begin 'the BEGIN marker the compiled suite extracts from is removed' \
    's = s.replace("WRAPPER-EXIT-CHAIN-BEGIN", "", 1)'
  mutate chain_marker_end 'the END marker the compiled suite extracts to is removed' \
    's = s.replace("WRAPPER-EXIT-CHAIN-END", "", 1)'
  mutate data_error_names_status 'the error line stops naming the Win32 status' \
    's = s.replace("HandleDataMessage failed with 0x%x", "HandleDataMessage failed", 1)'
  mutate data_error_keeps_first_status 'the status is overwritten by later failures' \
    's = s.replace("if (g_DataErrorStatus == ERROR_SUCCESS)", "if (1)", 1)'
  mutate old_warning_gone 'the three-causes-at-once LogWarning comes back' \
    's = s.replace("LogError(\"an output pump is still running", "LogWarning(\"an output pump is still running", 1)'
  mutate peer_closed_clears_status 'the peer-closed path stops clearing the stale status' \
    'import re; m = re.search(r"vchan closed - drained", s); i = s.index("status = ERROR_SUCCESS;", m.end()); s = s[:i] + s[i+len("status = ERROR_SUCCESS;"):]'
  mutate peer_closed_records_reason 'the peer-closed path stops latching its reason' \
    'import re; m = re.search(r"vchan closed - drained", s); i = s.index("EXIT_REASON_PEER_CLOSED", m.end()); s = s[:i] + "EXIT_REASON_UNSET" + s[i+len("EXIT_REASON_PEER_CLOSED"):]'
  mutate vchan_open_flag_exists 'the open flag is gone, so the handler cannot tell the two cases apart' \
    's = s.replace("g_VchanOpen", "g_VchanState")'
  mutate vchan_open_flag_set 'the flag is never set, so a real vchan reads as never opened' \
    's = s.replace("InterlockedExchange(&g_VchanOpen, 1)", "InterlockedExchange(&g_VchanOpen, 3)", 1)'
  mutate vchan_open_flag_cleared 'the flag is never cleared, so a closed vchan reads as open' \
    's = s.replace("InterlockedExchange(&g_VchanOpen, 0)", "InterlockedExchange(&g_VchanOpen, 2)", 1)'
  mutate empty_close_is_quiet 'the never-had-a-vchan case goes back to being an ERROR' \
    's = s.replace("no data vchan to close at console control event", "closed at console control event", 1)'
  mutate empty_close_says_why 'that INFO stops saying why nothing is leaked' \
    's = s.replace("so its mapping is reclaimed at process exit", "so nothing to do", 1)'
  mutate close_error_names_closing 'the ERROR stops naming the cleanup-had-started state' \
    's = s.replace("had begun closing it", "could not close it", 1)'
  mutate close_error_names_not_reached 'the ERROR stops naming the never-got-there state' \
    's = s.replace("never reached the close", "did not close", 1)'
  mutate drain_bound_unchanged 'the 120 s drain bound is quietly shortened' \
    's = s.replace("#define DRAIN_TIMEOUT_MS (120 * 1000)", "#define DRAIN_TIMEOUT_MS (30 * 1000)", 1)'
  mutate drain_expiry_says_truncated 'the expiry stops saying the transfer was truncated' \
    "s = s.replace('so this transfer is TRUNCATED\", DRAIN_TIMEOUT_MS', 'so this transfer ended\", DRAIN_TIMEOUT_MS', 1)"
  mutate no_new_wait 'a wait nobody declared is added' \
    'import re; s = re.sub(r"\n([ \t]*)return TRUE;\n\}\n", lambda m: "\n%sSleep(5);\n%sreturn TRUE;\n}\n" % (m.group(1), m.group(1)), s, count=1)'
  mutate no_new_wait 'a declared wait is removed, which the same set equality must also catch' \
    'import re; s = re.sub(r"\n[ \t]*Sleep\(1\);", "", s, count=1)'
  rm -rf "$MT"

  # A check with no mutation beside it has never been watched fail. BOTH SIDES COME FROM RUNS: the
  # ids are read out of a real self-run, and WATCHED holds only the ids a mutation was OBSERVED to
  # turn red - not the ids a `mutate` line is written for. An earlier version of this leg grepped
  # THIS FILE for "mutate <id>", which credits a mutation that silently matched nothing. A verifier
  # that reads its own bookkeeping is inert; this one reads the outcomes.
  # AND THE IDS ARE PER PROPERTY. The version before this one had one id over several `&&`-joined
  # greps, so a single mutation marked the id watched while its other conjuncts had never failed.
  ids=$(WRAPPER_MUTANT=1 bash "$0" 2>&1 | command grep -oE '^(PASS|FAIL)  [a-z_]+:' | awk '{print $2}' | tr -d ':' | sort -u)
  unwatched=""
  for id in $ids; do
    case " $WATCHED " in *" $id "*) ;; *) unwatched="$unwatched [$id]" ;; esac
  done
  if [ -z "$unwatched" ] && [ -n "$ids" ]; then
    ok "every_check_is_watched: all $(printf '%s\n' "$ids" | wc -l) check ids were SEEN to go red under a mutation"
  else
    bad "every_check_is_watched: never seen red:$unwatched" "those checks have never failed in front of anyone - add a mutation above"
  fi
fi

echo
echo "wrapper-exit-reason-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
