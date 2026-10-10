#!/usr/bin/env bash
# lifecycle-selftest.sh - offline proof matrix for the agent's END-OF-LIFE ORDER (docs/ADR-supervision.md section 5):
# agent/include/qga-lifecycle.h (the service's decision on every agent exit, the agent's reading of its own exit code,
# the per-pid lifecycle channel), agent/gui-agent/lifecycle.c (the end-session window and handshake) and
# agent/watchdog/watchdog.c (the launch triggers, the one relaunch, the failure exit for the SCM).
#
# Runs on this dev qube with gcc alone (no rig, no guest, no Windows toolchain) against tools/tests/win32stub plus the
# REAL windows-utils headers:
#   clean build of watchdog/lifecycle_test.c    MUST pass (every row of the exit table, the invariants R1/R2/R5, the exit
#                                               reading, the channel names)
#   QGA_LIFECYCLE_DEFECT_* builds               MUST fail - a guard never seen to fail is decoration:
#       TERMINATEDDEATH  0x40010004 relaunched into the ending session (the measured defect: three agents per shutdown)
#       RELAUNCHDEATH    the service relaunches a dead agent itself (the old loop) instead of failing for the SCM
#       RECONNECTDEATH   a reconnect exit writes a death record       REQUESTEDDEATH  a requested exit is a death
#       REQUESTEDERROR   the agent logs an expected exit as a failure (the stale "WatchForEvents failed" ERROR line)
#       HELPERSYSKILLDEATH  a helper the SYSTEM killed (0x40010004) is written up as a death - the measured 2026-10-10
#       DISARMHIDESCRASH   once launches are disarmed, a helper CRASH is written up as expected - the hole the
#                           owner closed 2026-10-10 ("a REAL abnormal termination should be always reported loudly")
#                           defect: two 4003 records for notifhost.exe on ordinary shutdowns, each a dom0 "major error" toast
#       HELPERSTOPTEARDOWN  a helper's stop wait expiring during the session's TEARDOWN is graded an ERROR miss - the
#                           measured 2026-10-10 defect: "the bridge did not leave within 3 s of the stop file" at a
#                           shutdown whose end the agent had logged 0.5 s before writing the file
#       PRESHELLLOCK        a LOCK reading is asserted with no shell seen or found - the measured 2026-10-10 defect:
#                           "the session is LOCKED after 0 s" on an agent's first secure frame, dom0 notified, on a
#                           guest the owner saw was never locked
#       SHELLPROCSILENT     an UNREADABLE process list is read as "no shell" on the LOCK-without-window path, so a
#                           real lock met by a fresh agent would be PRE_SHELL and unsaid (the review's latch-never-set)
#   UNCOMPILED SHAPE CHECKS, each also run against a copy with the guarded line removed and required to FAIL then:
#       watchdog.c and lifecycle.c parse with gcc -fsyntax-only against the stubs; the channel is created before the
#       agent is resumed; WinMain's first act is LifecycleStart; the exit path disarms helpers before any helper is
#       told to leave; every exitLoop site names its reason; an expected exit of the window-event thread is INFO;
#       both helper shutdowns grade their wait through QgaHelperStopOutcome and carry the facts; the lock report is
#       QgaLockVerdict's LOCKED arm only, the shell-seen latch is set only through ShellWindowNow, and the 30 s
#       classifier has its fourth arm.
#   CI compiles the real thing; this proves the C is well-formed and the contract is pinned, nothing about linking.
#
#   AGENT_DIR=<path>           the agent checkout (default: the agent submodule); WINDOWS_UTILS_INC=<path> the real headers
#   LIFECYCLE_OUT=<dir>        where the builds and outputs go (default: a mktemp dir)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="${AGENT_DIR:-$ROOT/agent}"
UTILS_INC="${WINDOWS_UTILS_INC:-$ROOT/upstream/ro/qubes-windows-utils/include}"
STUB="$ROOT/tools/tests/win32stub"
OUT="${LIFECYCLE_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/lifecycle-selftest-XXXXXX")}"
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }

WD="$AGENT/watchdog/watchdog.c"; LC="$AGENT/gui-agent/lifecycle.c"; MAIN="$AGENT/gui-agent/main.c"
for need in "$AGENT/include/qga-lifecycle.h" "$AGENT/watchdog/lifecycle_test.c" "$WD" "$LC" "$MAIN" "$UTILS_INC/log.h" "$STUB/windows.h" "$STUB/sddl.h"; do
    if [ ! -f "$need" ]; then say "FAIL  missing $need - nothing ran (missing data fails)"; exit 2; fi
done

INC=(-I"$STUB" -I"$AGENT/include" -I"$AGENT/gui-agent" -I"$UTILS_INC")
build() { gcc -std=c99 -Wall -Wextra -Werror -D_DEFAULT_SOURCE "${INC[@]}" ${2:-} "$AGENT/watchdog/lifecycle_test.c" -o "$OUT/$1" 2>"$OUT/$1.build.err"; }

# ---- the table: clean must pass -----------------------------------------------------------------------
if build clean ""; then
    "$OUT/clean" >"$OUT/clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
    if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 35 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
    else say "FAIL  clean: rc=$rc ok=$n fail=$f"; grep '^FAIL' "$OUT/clean.out" | head -5; bad=1; fi
else say "FAIL  clean build: $(head -3 "$OUT/clean.build.err")"; bad=1; fi

# ---- every defect knob must make the suite FAIL --------------------------------------------------------
for d in TERMINATEDDEATH RELAUNCHDEATH RECONNECTDEATH REQUESTEDDEATH REQUESTEDERROR HELPERSYSKILLDEATH HELPERSTOPTEARDOWN PRESHELLLOCK SHELLPROCSILENT DISARMHIDESCRASH; do
    if build "defect-$d" "-DQGA_LIFECYCLE_DEFECT_$d"; then
        "$OUT/defect-$d" >"$OUT/defect-$d.out" 2>&1; rc=$?
        f=$(grep -c '^FAIL' "$OUT/defect-$d.out")
        if [ "$rc" -ne 0 ] && [ "$f" -gt 0 ]; then say "PASS  defect $d: suite FAILED as required (rc=$rc, $f failing checks: $(grep '^FAIL' "$OUT/defect-$d.out" | head -1 | cut -c6-110))"
        else say "FAIL  defect $d: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1; fi
    else say "FAIL  defect $d build: $(head -3 "$OUT/defect-$d.build.err")"; bad=1; fi
done

# ---- UNCOMPILED: the two files parse against the stubs + the real headers -------------------------------
for f in "$WD" "$LC"; do
    gcc -std=c99 -fsyntax-only -Wall -Wextra -D_DEFAULT_SOURCE "${INC[@]}" "$f" >"$OUT/$(basename "$f").syntax" 2>&1
    errs=$(grep -c 'error:' "$OUT/$(basename "$f").syntax")
    if [ "$errs" -eq 0 ]; then say "PASS  $(basename "$f"): gcc -fsyntax-only clean against the stubs + real headers (UNCOMPILED: CI builds it; $(grep -c 'warning:' "$OUT/$(basename "$f").syntax") warning(s))"
    else say "FAIL  $(basename "$f"): $errs syntax error(s): $(grep -m1 'error:' "$OUT/$(basename "$f").syntax")"; bad=1; fi
done

# ---- UNCOMPILED shapes, each seen to fail with its guarded line removed ----------------------------------
shape() { # $1 label, $2 check fn, $3 file, $4 marker of the guarded line (the mutated copy drops the line carrying it)
    local mut="$OUT/mut-$2.c"
    if "$2" "$3"; then
        grep -v -F -- "$4" "$3" > "$mut"
        if "$2" "$mut"; then say "FAIL  shape: $1 - the check still passes with the guarded line removed (it cannot fail)"; bad=1
        else say "PASS  shape: $1 (and FAILS with the guarded line removed)"; fi
    else say "FAIL  shape: $1"; bad=1; fi
}
# the service creates the channel for the suspended agent, then resumes it
wd_channel_before_resume() { awk '/CREATE_SUSPENDED/{c=NR} /LifecycleChannelCreate\(pi.dwProcessId, channel\)/{a=NR} /ResumeThread\(pi.hThread\)/{b=NR} END{exit !(c && a && b && c<a && a<b)}' "$1"; }
shape "watchdog.c: the agent is created suspended, its channel created, THEN resumed" wd_channel_before_resume "$WD" 'LifecycleChannelCreate(pi.dwProcessId, channel)'
# the notice is acknowledged and latches the session; the latch is read before every launch
wd_notice_latch() { awk '/wait == WAIT_OBJECT_0 \+ idxNotice/{f=1} f&&/endedSession = agentSession;/{a=NR} f&&/SetEvent\(channel.Ack\)/{b=NR} END{exit !(a && b)}' "$1" && grep -q 'consoleSession == endedSession' "$1"; }
shape "watchdog.c: the end-session notice latches the session and is acknowledged; no launch into a latched session" wd_notice_latch "$WD" 'endedSession = agentSession;'
# A LATCHED SESSION THAT NEITHER ENDS NOR CANCELS IS LEFT, LOUDLY (the Jev review of this change, 0.53): the latch is
# also a bounded failure detector, so a vetoed end whose agent died cannot cost the session its GUI for good.
wd_latch_detector() { grep -q 'SESSION_END_NEVER_HAPPENED_MS' "$1" &&
    awk '/wait == WAIT_TIMEOUT/{f=1} f&&/QGAWDSESSIONSTUCK/{a=NR} f&&/endedSession = NO_SESSION;/{b=NR} f&&/launchWanted = TRUE;/{c=NR} END{exit !(a && b && c && a<b && b<=c)}' "$1" &&
    grep -q 'endedSessionAt = GetTickCount64();' "$1"; }
shape "watchdog.c: a latched session that neither ends nor cancels is reported at ERROR and allowed again (the detector)" wd_latch_detector "$WD" 'endedSessionAt = GetTickCount64();'
# THE ONE RELAUNCH AFTER AN EXIT: only the verdict's RelaunchNow. The five sites that want a launch are, and must
# remain: the initial value; a session ARRIVING (a logon/connect trigger); the verdict's RelaunchNow (the reconnect);
# a foreign same-named agent having exited; and the stuck-latch detector re-allowing a session nothing ever ended.
# None of them is a relaunch after a DEATH - that path now fails the service and leaves the restart to the SCM.
wd_one_relaunch() { grep -q 'if (v.RelaunchNow)' "$1" && [ "$(grep -c 'launchWanted = TRUE;' "$1")" -le 5 ] &&
    awk '/if \(v.RelaunchNow\)/{f=NR} f&&/launchWanted = TRUE;/&&NR==f+1{ok=1} END{exit !ok}' "$1"; }
shape "watchdog.c: after an exit, only the verdict's RelaunchNow (RECONNECT) launches again" wd_one_relaunch "$WD" 'if (v.RelaunchNow)'
# WinMain: the first act, before Init
main_first_act() { awk '/^int CALLBACK WinMain/{w=NR} w&&/LifecycleStart\(\);/{a=NR} w&&/DWORD initStatus = Init\(\);/{b=NR} END{exit !(w && a && b && a<b)}' "$1"; }
shape "main.c: WinMain's first act is LifecycleStart(), before Init()" main_first_act "$MAIN" 'LifecycleStart();'
# the exit path: disarm before any helper shutdown
main_disarm_first() { awk '/LogDebug\("main loop finished"\);/{m=NR} m&&/HelpersDisarm\(L"the agent is exiting"\);/{a=NR} m&&/BrokerShutdown\(\);/{b=NR} m&&/NotifBridgeShutdown\(\);/{c=NR} m&&/EtwProxyShutdown\(\);/{d=NR} END{exit !(m && a && b && c && d && a<b && b<c && c<d)}' "$1"; }
shape "main.c: the exit path disarms helper relaunch BEFORE the broker, the bridge and the proxy are told to leave" main_disarm_first "$MAIN" 'HelpersDisarm(L"the agent is exiting");'
# every exitLoop site names its reason: a LifecycleLatchExit within the 3 lines before it
main_exit_reasons() { awk '/LifecycleLatchExit\(/{l=NR} /exitLoop = TRUE;/{ if (!(l && NR-l<=3)) bad++ } END{exit (bad>0)}' "$1"; }
shape "main.c: every exitLoop site latches its QGA_EXIT_* reason (never a stale GetLastError)" main_exit_reasons "$MAIN" 'LifecycleLatchExit(QGA_EXIT_RECONNECT);   // a fresh agent re-announces'
# the helper shutdowns disarm the task before ending the helper
main_task_disarm_first() { awk '/^static void BrokerShutdown/{f=1} f&&/HelperTaskDisarm\(WGC_TASK_NAME/{a=NR} f&&/Shutdown = 1;/{b=NR} f&&/\/delete \/tn " WGC_TASK_NAME/{c=NR} f&&/^}/{exit} END{exit !(a && b && c && a<b && b<c)}' "$1" && awk '/^static void NotifBridgeShutdown/{f=1} f&&/HelperTaskDisarm\(NOTIF_TASK_NAME/{a=NR} f&&/NotifBridgeRequestStop\(\);/{b=NR} f&&/\/delete \/tn " NOTIF_TASK_NAME/{c=NR} f&&/^}/{exit} END{exit !(a && b && c && a<b && b<c)}' "$1"; }
shape "main.c: BrokerShutdown/NotifBridgeShutdown disarm the task, ask the helper to leave, then delete (R1)" main_task_disarm_first "$MAIN" 'HelperTaskDisarm(WGC_TASK_NAME, L"the agent'"'"'s exit");'
# no relaunch loop left in the agent: the helpers are launched once per life, no throttle, no relaunch deadline
main_no_relaunch() { grep -q 'if (!g_WgcLaunched && !HelpersDisarmed()' "$1" && grep -q 'if (g_NotifLaunched || HelpersDisarmed()) return;' "$1" && ! grep -q 'relaunching after the exit reported' "$1" && ! grep -q 'now - g_WgcLastLaunch < 8000' "$1"; }
shape "main.c: each helper is launched ONCE per agent life, never relaunched (Task Scheduler's restart-on-failure is the relauncher)" main_no_relaunch "$MAIN" 'if (g_NotifLaunched || HelpersDisarmed()) return;'
# the task definitions carry Task Scheduler's own RestartOnFailure for the resident helpers
# THE HELPER TASKS MUST QUEUE A NEW INSTANCE, NOT DROP IT. They fire on a RegistrationTrigger and the agent
# re-registers them at every Init, so on a RESTART the start is requested while the previous helper - owned by
# the agent that just exited - is still running as that task's instance. With IgnoreNew the scheduler silently
# dropped it (measured 2026-10-07, twice: the agent logged the launch, the task came back Ready/0, the old
# bridge exited two seconds later and nothing replaced it, and the guest had no notification bridge for the
# rest of the session). Queue makes the scheduler serialize them instead of discarding one.
# keyed to the XML LINE, not the word: the comment above the change in main.c names IgnoreNew to explain
# what it replaced, and the first version of this predicate failed on that comment (the same self-matching
# trap this suite has hit before).
# THE COMPLETION SIGNAL IS SET WHERE THE WORK FINISHES. If it were set by whoever wakes on g_ExitDone, the
# handoff between the two threads would be exactly the window in which the system's kill makes a COMPLETED
# orderly exit read as a forced one - the false ERROR this whole mechanism exists to remove (Jev flagged that
# first version at race-remains 0.70).
# TIGHTENED 2026-10-07: setting it in LifecycleExitDone was still TOO LATE. That runs once the main thread is
# actually leaving - after the window-event thread's 2 s join - while the work the service cares about (the
# vchan withdrawal, the UNMAP/DESTROY sweep, the staging grant) finished long before, and Windows reaps the
# process during session teardown. Measured on a clean shutdown: the agent logged "orderly exit complete" at
# 153432.110 and the watchdog logged QGAWDSESSIONEND-FORCED 104 ms later, with the 10 s budget never
# approached. So the signal moved to LifecycleOrderlyComplete(), which main.c calls on the line after
# CaptureStagingRevokeOnExit() - the last orderly step. The setter still lives in lifecycle.c ONLY.
lc_done_at_work() { awk '/^void LifecycleOrderlyComplete\(void\)/{f=1} f&&/SetEvent\(g_Done\)/{hit=1} f&&/^}/{exit} END{exit !hit}' "$1" &&
                    [ "$(grep -c 'SetEvent(g_Done)' "$1")" -eq 1 ]; }
shape "lifecycle.c: the orderly-exit signal is set in LifecycleOrderlyComplete, and nowhere else in the file" \
      lc_done_at_work "$LC" 'SetEvent(g_Done);'

# and the agent must actually CALL it at the completion point - a setter nobody calls signals nothing
main_signals_at_completion() { awk '/CaptureStagingRevokeOnExit\(\);/{f=1; next} f&&/LifecycleOrderlyComplete\(\);/{hit=1; exit} f&&/LogInfo\("exiting"\)/{exit} END{exit !hit}' "$1"; }
shape "main.c: LifecycleOrderlyComplete() is called right after the last orderly step (CaptureStagingRevokeOnExit), before 'exiting'" \
      main_signals_at_completion "$MAIN" 'LifecycleOrderlyComplete();'

main_helper_queue() { grep -q '<MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>' "$1" &&
                      ! grep -qE '^ *L" *<MultipleInstancesPolicy>IgnoreNew' "$1"; }
shape "main.c: a helper task QUEUES a new instance behind the outgoing one, never drops it (IgnoreNew)" \
      main_helper_queue "$MAIN" '<MultipleInstancesPolicy>Queue</MultipleInstancesPolicy>'

main_restart_on_failure() { grep -q '<RestartOnFailure><Interval>' "$1" && grep -q 'HelperTaskRegister(WGC_TASK_NAME, longExe, args, userId, TRUE,' "$1" && grep -q 'return NotifRunInSession(NOTIF_TASK_NAME, args, TRUE);' "$1"; }
shape "main.c: the broker's and the bridge's tasks are registered with RestartOnFailure (the one-shots without)" main_restart_on_failure "$MAIN" 'return NotifRunInSession(NOTIF_TASK_NAME, args, TRUE);'
# item I: the window-event thread's exit on request is INFO; the ERROR stays for a thread that dies while the agent runs
main_winevt_expected() { grep -q 'QGA_WINEVT_EXPECTED' "$1" && grep -q 'LogError("QGAWINEVTDEAD window event thread died unexpectedly, using fallback")' "$1" && ! grep -q 'LogError("window event thread exiting - tracking falls back to periodic resync")' "$1"; }
shape "main.c: the window-event thread's exit on the agent's request is INFO, a death while running stays ERROR (QGAWINEVTDEAD)" main_winevt_expected "$MAIN" 'QGA_WINEVT_EXPECTED'
# item I: WinMain never logs "WatchForEvents failed"; an expected exit is INFO with its reason, a failure ERROR with its code
main_exit_log() { ! grep -q 'win_perror("WatchForEvents")' "$1" && grep -q 'if (QgaExitIsExpected(exitCode))' "$1" && grep -q 'LogError("QGAEXIT exiting with 0x%x: %s"' "$1"; }
shape "main.c: WinMain logs an expected exit at INFO with its reason and a failure at ERROR with its code (no stale GetLastError)" main_exit_log "$MAIN" 'if (QgaExitIsExpected(exitCode))'
# the etwproxy: one launch, no backoff relaunch, disarmed exits are expected
etw_no_relaunch() { ! grep -q 'EtwProxyBackoffLocked\|EtwProxyRelaunchCb\|CreateTimerQueueTimer' "$1" && grep -q 'if (g_State != EPS_IDLE || g_Shutdown || g_Disarmed)' "$1" && grep -q 'while the session is ending - expected, not a death' "$1"; }
shape "etwproxy.c: no backoff relaunch timer; no launch while disarmed; an exit while the session ends is expected" etw_no_relaunch "$AGENT/gui-agent/etwproxy.c" 'if (g_State != EPS_IDLE || g_Shutdown || g_Disarmed)'

# A TEARDOWN IS NOT A STOP-FILE MISS (2026-10-10). Each helper shutdown grades its bounded wait through
# QgaHelperStopOutcome with LifecycleSessionEnding(); the teardown arm is INFO, the miss stays ERROR, and both lines
# carry the wait result, the elapsed ms, the helper's pid and the session-ending flag. Pinned per function so a
# site that quietly goes back to "!= WAIT_OBJECT_0 -> LogError" fails here.
main_stop_outcome() {
    awk '/^static void BrokerShutdown/{f=1} f&&/const BOOL ending = LifecycleSessionEnding\(\);/{s=NR} f&&/switch \(QgaHelperStopOutcome\(ending, wait\)\)/{a=NR} f&&/case QGA_HELPER_STOP_TEARDOWN:/{b=NR} f&&/LogInfo\("WGCBROKER broker pid %lu still up at session end, Windows ends it: "/{c=NR} f&&/LogError\("WGCBROKER broker pid %lu did not stop within 2 s, ending it by task delete: "/{d=NR} f&&/^}/{exit} END{exit !(s && a && b && c && d && s<a && a<b && b<c && c<d)}' "$1" &&
    awk '/^static void NotifBridgeShutdown/{f=1} f&&/const BOOL ending = LifecycleSessionEnding\(\);/{s=NR} f&&/switch \(QgaHelperStopOutcome\(ending, wait\)\)/{a=NR} f&&/case QGA_HELPER_STOP_TEARDOWN:/{b=NR} f&&/LogInfo\("NOTIFBRIDGE the bridge pid %lu did not leave on the stop file - Windows ends it with the/{c=NR} f&&/LogError\("NOTIFBRIDGE bridge pid %lu did not stop within 3 s, ending it by task delete: "/{d=NR} f&&/^}/{exit} END{exit !(s && a && b && c && d && s<a && a<b && b<c && c<d)}' "$1" &&
    [ "$(grep -c 'wait=0x%lx elapsed=%I64u ms session-ending=' "$1")" -eq 4 ]; }
shape "main.c: BrokerShutdown and NotifBridgeShutdown grade their bounded wait through QgaHelperStopOutcome - a teardown expiry INFO, a miss ERROR, both carrying wait/elapsed/pid/session-ending" main_stop_outcome "$MAIN" 'switch (QgaHelperStopOutcome(ending, wait))'

# A LOCK IS READ, NOT ASSUMED (2026-10-10). The report is QgaLockVerdict's LOCKED arm and nothing else returns TRUE
# to the reporting site; the verdict is fed ShellSeenSinceStart(), the shell-PROCESS fact (read only on the
# LOCK-without-window path, from the console session) and LifecycleSessionEnding() beside the WTS reading; the refused
# PRE_SHELL arm is SAID (the fourth arm); the LOCKED line carries the facts it rests on, including which fact found
# the shell (shell-by=window|process).
main_lock_verdict() {
    awk '/^static BOOL SecureDesktopLockedNow/{f=1} f&&/const BOOL shellSeen = ShellSeenSinceStart\(\);/{s=NR} f&&/const BOOL ending = LifecycleSessionEnding\(\);/{e=NR} f&&/if \(!shellSeen && !ending && r->Level == 1 && r->SessionFlags == WTS_SESSIONSTATE_LOCK\)/{l=NR} f&&/r->ShellProcess = ShellProcessInConsoleSession\(&r->ShellProcessError\);/{p=NR} f&&/QgaLockVerdict\(shellSeen, r->ShellProcess, ending, r->Level, r->SessionFlags\)/{a=NR} f&&/if \(v == QGA_LOCK_LOCKED\)/{b=NR} f&&/return TRUE;/{c=NR} f&&/case QGA_LOCK_PRE_SHELL:/{d=NR} f&&/LogInfo\("QGADESKPRESHELL /{g=NR} f&&/^}/{exit} END{exit !(s && e && l && p && a && b && c && d && g && s<l && e<l && l<p && p<a && a<b && b<c && c<d && d<g)}' "$1" &&
    awk '/^static QGA_SHELL_PROCESS ShellProcessInConsoleSession/{f=1} f&&/CreateToolhelp32Snapshot\(TH32CS_SNAPPROCESS, 0\)/{a=NR} f&&/ProcessIdToSessionId\(pe.th32ProcessID, &psid\) && psid == csid/{b=NR} f&&/return QGA_SHELLPROC_UNREAD;/{u=NR} f&&/^}/{exit} END{exit !(a && b && u && a<b)}' "$1" &&
    grep -q 'else if (SecureDesktopLockedNow(now, s_LockReported, &s_LockCheckNext, &s_LockArmsSaid,' "$1" &&
    grep -q '&s_ShellProcAbsent, &lockRead))' "$1" && grep -q 's_ShellProcAbsent = FALSE;   // a new episode may have reached a shell since' "$1" &&
    awk '/^static BOOL SecureDesktopLockedNow/{f=1} f&&/if \(\*shellAbsent\)/{a=NR} f&&/\*shellAbsent = TRUE;/{b=NR} f&&/^}/{exit} END{exit !(a && b && a<b)}' "$1" &&
    [ "$(grep -c 'wts-flags=%lu level=%lu input-desktop=%s LogonUI.exe=%d' "$1")" -eq 2 ] &&
    grep -q 'LogWarning("QGADESKSTUCK session LOCKED, seamless inactive until unlocked: shell-by=%s secure-for=%I64u s "' "$1" &&
    grep -q 'lockRead.ShellSeen ? L"window" : L"process"' "$1" &&
    grep -q 'shell-seen=%d shell-process=%s shell-process-err=%lu' "$1" &&
    grep -q 'C_ASSERT(QGA_WTS_SESSIONSTATE_LOCK == WTS_SESSIONSTATE_LOCK);' "$1"; }
shape "main.c: the lock report is QgaLockVerdict's LOCKED arm only, fed shell-seen + the shell-process fact (read only on the LOCK-without-window path) + session-ending + the WTS reading; PRE_SHELL is said; the LOCKED line says shell-by=window|process" main_lock_verdict "$MAIN" 'if (v == QGA_LOCK_LOCKED)'

# THE SHELL-SEEN LATCH IS SET ONLY BY CONSULTS THE AGENT ALREADY MAKES: the one GetShellWindow() call in code is the
# one inside ShellWindowNow (comment-only lines are excluded from the count), and every phase gate asks through it.
main_shell_latch() {
    awk '/^static HWND ShellWindowNow\(void\)/{f=1} f&&/const HWND shell = GetShellWindow\(\);/{a=NR} f&&/InterlockedExchange\(&g_ShellSeen, 1\)/{b=NR} f&&/^}/{exit} END{exit !(a && b && a<b)}' "$1" &&
    [ "$(grep -v '^[[:space:]]*//' "$1" | grep -c 'GetShellWindow()')" -eq 1 ] &&
    grep -q 'if (!ShellWindowNow() && !g_WgcLaunched)' "$1" && grep -q 'sid != 0xFFFFFFFF && ShellWindowNow())' "$1" &&
    grep -q 'if (!ShellWindowNow()) return FALSE;' "$1" && [ "$(grep -c '|| !ShellWindowNow()) return;' "$1")" -eq 2 ] &&
    grep -q 'data->Handle == ShellWindowNow())' "$1" && grep -q '!ShellWindowNow() || g_OnSecureDesktop ||' "$1"; }
shape "main.c: the shell-seen latch is set only through ShellWindowNow (the one GetShellWindow() call in code), which every phase gate asks" main_shell_latch "$MAIN" 'const HWND shell = GetShellWindow();'

# THE FOURTH ARM of the 30 s classifier (docs/ADR-uac.md 5): LogonUI up before this agent saw a shell is named as that,
# never as a lock, and the WARNING carries shell-seen beside console-user.
main_preshell_arm() { grep -q 'else if (logonui && !shellSeen)' "$1" && grep -q 'console-user=%d shell-seen=%d' "$1" &&
    awk '/else if \(logonui && !shellSeen\)/{a=NR} /else if \(logonui\)$/{b=NR} END{exit !(a && b && a<b)}' "$1"; }
shape "main.c: the 30 s classifier has the fourth arm (LogonUI up before this agent saw a shell) ahead of the two-state LogonUI arm, and carries shell-seen" main_preshell_arm "$MAIN" 'else if (logonui && !shellSeen)'

say "--- outputs in $OUT"
exit $bad
