#!/usr/bin/env bash
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
# that trustworthy is check 2: every exit path must record a reason, so a path someone adds later
# falls to the loud branch rather than being silently classified as fine.
#
# It also clears the stale status on the ordinary path: ERROR_INVALID_FUNCTION was set at the top of
# every loop pass and never reassigned when the peer closed, so a fully successful guest-initiated
# call returned 1 from wmain as its process exit code.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/core-agent/src/qrexec-wrapper/qrexec-wrapper.c"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$SRC" ] || { echo "FAIL  $SRC is missing - nothing ran (missing data fails)"; exit 2; }

# ---- 1. the reason exists, is an enum, and every member is reported by name --------------------
miss=""
for m in EXIT_REASON_UNSET EXIT_REASON_PEER_CLOSED EXIT_REASON_CHILD_DRAINED \
         EXIT_REASON_DATA_ERROR EXIT_REASON_DRAIN_EXPIRED EXIT_REASON_CTRL_STOP; do
  command grep -qF "$m" "$SRC" || miss="$miss [$m]"
done
if [ -z "$miss" ] && command grep -qF 'static const WCHAR *ExitReasonName' "$SRC"; then
  ok "reason_named: every exit reason is declared and has a name the log can print"
else
  bad "reason_named: missing$miss, or ExitReasonName does not return WCHAR (the log format is widened by L##format)"
fi
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
python3 - "$SRC" <<'PY' > /tmp/wrapper-exit-reason.$$ 2>&1
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
r=$(cat /tmp/wrapper-exit-reason.$$); rm -f /tmp/wrapper-exit-reason.$$
case "$r" in
  OK*) ok "every_exit_records_a_reason: $r" ;;
  *)   bad "every_exit_records_a_reason: $r" ;;
esac

# ---- 3. only the case that can LOSE data is loud ----------------------------------------------
cl=$(sed -n '/if (pumpsFinished)/,/^    }/p' "$SRC")
n_err=$(printf '%s' "$cl" | command grep -c 'LogError("an output pump is still running')
n_dbg=$(printf '%s' "$cl" | command grep -c 'LogDebug("an output pump is still running')
if [ "$n_err" = 1 ] && [ "$n_dbg" = 2 ]; then
  ok "loud_where_it_matters: expected ends and the already-reported backstop at Debug, everything else at ERROR"
else
  bad "loud_where_it_matters: error=$n_err (want 1) debug=$n_dbg (want 2)"
fi
# The ERROR branch must be the LAST one and unconditional: that is what makes an exit path someone
# adds later land in it rather than being classified as fine by default.
last_branch=$(printf '%s' "$cl" | command grep -oE 'else if|else$|Log(Debug|Error)\("an output pump' | tail -2 | tr '\n' ' ')
if [ "$last_branch" = "else LogError(\"an output pump " ]; then
  ok "unrecorded_is_loud: the final branch is a bare else at ERROR, so an unrecorded reason is loud"
else
  bad "unrecorded_is_loud: the last branch is '$last_branch' - a new exit path could be silently fine"
fi
# the old unconditional warning, which asserted three causes at once, must be GONE
# Matched as a LogWarning CALL, not as text: the comment above the enum quotes the old line on
# purpose, and a check that cannot tell those apart would be unfixable.
if command grep -qE 'LogWarning\("an output pump is still running' "$SRC"; then
  bad "defect_removed: the warning that asserts three causes at once is still logged"
else
  ok "defect_removed: the three-causes-at-once LogWarning is gone"
fi

# ---- 4. the ordinary path no longer returns a failure ----------------------------------------
pc=$(sed -n '/vchan closed - drained/,/run = FALSE;/p' "$SRC")
if printf '%s' "$pc" | command grep -qF 'status = ERROR_SUCCESS;' && printf '%s' "$pc" | command grep -qF 'EXIT_REASON_PEER_CLOSED'; then
  ok "success_returns_success: the peer-closed path clears the stale ERROR_INVALID_FUNCTION"
else
  bad "success_returns_success: a successful guest-initiated call still returns ERROR_INVALID_FUNCTION as its exit code"
fi

# The revision that still carried the old warning, found by content rather than by position, so it
# keeps pointing at the pre-fix code after this change is committed. Checks 5 and 6 both need it:
# without it, check 5 would compare the fix against itself and pass for free.
prev=$(cd "$ROOT/core-agent" && git log --format=%H -S'the peer hung up first, a data error or a stop' -- src/qrexec-wrapper/qrexec-wrapper.c | head -1)

# ---- 4b. THE CONSOLE-CONTROL CLOSE REPORTS ONLY WHAT CAN LEAVE SOMETHING BEHIND ---------------
# "data vchan NOT confirmed closed within 3000 ms of console control event 6 - exiting anyway" was
# one of the ten error lines the new binary wrote on win11r-logvol (2026-10-08). The ERROR is right
# when a ring mapping is left for the kernel to reclaim at process exit - the path the 2026-08-20
# NMI dump caught spinning on a TLB shootdown - and MEANINGLESS when there was never a data vchan,
# which is the commonest case here: a client that went away before libvchan_client_init could
# connect. Nothing is mapped then, and no cleanup will ever signal the close, so the error was
# guaranteed and said nothing.
if command grep -qF 'g_VchanOpen' "$SRC" \
   && command grep -qF 'no data vchan to close at console control event' "$SRC" \
   && command grep -qF 'so its mapping is reclaimed at process exit' "$SRC"; then
  ok "close_report_is_specific: the ERROR is kept for the case that leaks a mapping, and the empty case is INFO"
else
  bad "close_report_is_specific: the handler still reports an ERROR when there was no vchan to close"
fi
# the flag must be set where the vchan is created and cleared where it is closed, or it lies
if command grep -qF 'InterlockedExchange(&g_VchanOpen, 1)' "$SRC" \
   && command grep -qF 'InterlockedExchange(&g_VchanOpen, 0)' "$SRC"; then
  ok "open_flag_tracks_the_vchan: set after InitVchan succeeds, cleared where the cleanup closes it"
else
  bad "open_flag_tracks_the_vchan: the flag is not maintained, so the branch above cannot be trusted"
fi
# and the ERROR branch must still say WHICH of the two cleanup states it was in
command grep -qF 'had begun closing it' "$SRC" && command grep -qF 'never reached the close' "$SRC" \
  && ok "close_error_is_diagnosable: the remaining ERROR names whether the cleanup had reached the close" \
  || bad "close_error_is_diagnosable: the ERROR still does not say what the cleanup was doing"

# ---- 5. NOTHING WAS MADE QUIETER BY A TIMEOUT, A RETRY OR A WATCHDOG -------------------------
# The house rule: never a timeout as a fix. The 120 s backstop predates this change and must be
# untouched, and no new wait may have appeared.
if command grep -qF '#define DRAIN_TIMEOUT_MS (120 * 1000)' "$SRC" \
   && command grep -qF 'this transfer is TRUNCATED' "$SRC"; then
  ok "backstop_untouched: the 120 s drain bound and its TRUNCATED error are as they were"
else
  bad "backstop_untouched: the drain bound or its error line changed"
fi
# Counted against the pre-fix revision, and with COMMENTS STRIPPED: a plain grep counts the comment
# at :775 that mentions the "Sleep(1)-polling send path" as if it were a call, which read as a wait
# this change had added when the diff adds none.
sleepcount(){ python3 -c "
import re,sys
s=sys.stdin.read()
s=re.sub(r'/\*.*?\*/','',s,flags=re.S); s=re.sub(r'//[^\n]*','',s)
print(len(re.findall(r'\bSleep\s*\(', s)))"; }
n_sleep=$(sleepcount < "$SRC")
if [ -n "$prev" ]; then
  n_sleep_before=$(cd "$ROOT/core-agent" && git show "$prev:src/qrexec-wrapper/qrexec-wrapper.c" 2>/dev/null | sleepcount)
else
  n_sleep_before=""
fi
if [ -z "$n_sleep_before" ]; then
  bad "no_new_wait: the pre-fix revision could not be read, so nothing was compared (missing data FAILS)"
elif [ "$n_sleep" -le "$n_sleep_before" ]; then
  ok "no_new_wait: no sleep was added ($n_sleep in code now, $n_sleep_before before the fix)"
else
  bad "no_new_wait: $n_sleep Sleep() calls against $n_sleep_before before the fix - a wait was added"
fi

# ---- 6. THE CHECKS MUST FAIL ON THE REVISION BEFORE THE FIX ----------------------------------
# A check never seen to fail is decoration. Run the marker checks against the last revision that
# still had the unconditional warning.
if [ -z "$prev" ]; then
  bad "seen_to_fail: could not find a revision carrying the old warning - the checks above prove nothing"
else
  old=$(cd "$ROOT/core-agent" && git show "$prev:src/qrexec-wrapper/qrexec-wrapper.c" 2>/dev/null)
  n_old_markers=0
  for m in 'EXIT_REASON_PEER_CLOSED' 'ExitReasonName' 'LogError("an output pump is still running'; do
    printf '%s' "$old" | command grep -qF "$m" && n_old_markers=$((n_old_markers+1))
  done
  if [ "$n_old_markers" = 0 ] && printf '%s' "$old" | command grep -qF 'the peer hung up first, a data error or a stop'; then
    ok "seen_to_fail: against $(printf '%s' "$prev" | cut -c1-8) every marker is absent and the old warning is present"
  else
    bad "seen_to_fail: the pre-fix revision has $n_old_markers/3 markers - the checks above prove nothing"
  fi
fi

echo
echo "wrapper-exit-reason-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
