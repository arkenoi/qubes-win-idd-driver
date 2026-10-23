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
#       LATEREGALWAYSLOUD  a cold boot's late registration is written up as a fault, which is what the FIRST
#                          attempt at this fix left in place: it asked whether the broker was ready at a site
#                          reached only once it is, so the quiet branch was unreachable (receipted 2026-10-11)
#       FAULTFROMREG       the per-window fault clock runs from REGISTRATION even when the broker could not
#                          feed the window yet, so a window registered into a broker that was still coming up
#                          is declared NOT SHOWN and dom0 is told "a window could not be shown" - measured
#                          2026-10-11 about a window that appeared, white and correct, 11 s later
#       HOLDALWAYSLOUD     every broker hold is written up as a fault, so the ~11 s on each cold boot in which
#                          the broker simply has not started yet produces three WARNINGs about correct
#                          behaviour - the log noise the owner refuses
#       STARTCLOSEUNSAID   both ways a hidden-Start opening ENDS stay silent and simply re-arm, as they
#                          did before 2026-10-17 - so a dismissal that worked and one that never ran
#                          leave identical logs, and only the FAILURE is ever written down
#       STARTNEVERSTUCK    a hidden Start still holding input past the settle time reads as "still
#                          closing", for ever - the measured GWeck #172 shape (1031 ms against a
#                          1000 ms bound, twice on win11de-sm) would then never be reported at all
#       STARTRETURNNULL    activation is handed to the shell desktop even when there is no shell
#                          window, i.e. to NULL - at logon and shutdown there is none
#       GIANTSHELLFRAME    a SCREEN-SIZED shell surface is announced as a normal WM-managed window,
#                          so dom0 gets a full-screen framed draggable window instead of a menu -
#                          the 2026-08-12 shape ("a shell CoreWindow announced or=0 at 5120x1336"),
#                          which the crop gate alone does not stop because a crop can resolve to the
#                          window's own full extent
#       COMPANIONSHOWN     the SearchHost companion of a hidden Start opening is presented, so a
#                          menu declared not-shown still puts a slice of itself on dom0's screen
#       SEARCHALWAYSHIDDEN the opposite direction: a standalone Win+S Search the user asked for is
#                          refused too - the discriminator has two halves and both must be seen
#       SEARCHASTOAST      a Search flyout is measured by the TOAST card rule, which is how the
#                          single-BOOL selector behaved; measured, both its candidates collapse to a
#                          728x32 sliver at one raw size, so any crop from them clips the flyout
#       XCNOTIFYKEPT       xencontrol's per-notify Debug line is kept - 118 identical lines in one
#                          run saying the vchan transport worked
#       HOLDREASONALLNORMAL  every BROKERHOLD reason reads as normal, so a broker that dropped a slot
#                          or a feed lost past its bound goes as quiet as a first frame that has not
#                          landed yet - the blanket demotion that was already made once and reverted
#       SLOWALWAYSLOUD     the capture loop warns from the FIRST second of a slow pass, so a guest merely
#                          busy installing produces a warning every second - measured as 13 lines over ~9
#                          passes of 1-3 s against a 15 s wedge that never fired once
#       SHELLBYNAME        the shell fact matches the literal explorer.exe, so a KIOSK guest whose Winlogon\Shell
#                          is one app reads ABSENT although it has a desktop - and the lock verdict then says
#                          "no session" about a running one
#       ZERODUE            a zeroed de-slice clock reads as "warning due now" - the 2026-10-11 defect that put one
#                          false "the notification and menu capture helper is not running" toast on dom0 per cold
#                          boot, with the agent's own uptime printed as the outage
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
for d in SYSKILLNOW TERMINATEDDEATH RELAUNCHDEATH RECONNECTDEATH REQUESTEDDEATH REQUESTEDERROR HELPERSYSKILLDEATH HELPERSTOPTEARDOWN PRESHELLLOCK SHELLPROCSILENT DISARMHIDESCRASH ZERODUE SHELLBYNAME HOLDALWAYSLOUD FAULTFROMREG LATEREGALWAYSLOUD SLOWALWAYSLOUD HOLDREASONALLNORMAL STARTCLOSEUNSAID STARTNEVERSTUCK STARTRETURNNULL GIANTSHELLFRAME COMPANIONSHOWN SEARCHALWAYSHIDDEN SEARCHASTOAST XCNOTIFYKEPT MENUKEYALWAYSFORWARD; do
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
# THE LEVEL OF BROKERLATEREG IS FED FROM A SNAPSHOT, and the reused flag is what makes that fragile:
# PwRegFailLogged is a one-shot LOG flag whose value is now load-bearing for a log LEVEL, so a future
# change to QGABROKERREGFAIL's logging could silently turn a healthy cold boot loud again. Jev flagged
# exactly that (worst_residual reused-flag 0.28, 2026-10-11). This pins the three things that must hold
# together: both facts are read BEFORE the retry, the level comes from QgaLateRegIsStartup, and the
# dead gate it replaces (a broker-ready test at a site reached only once the broker is ready) is gone.
main_latereg_level() { grep -q 'const BOOL refusedWhileUp = windowData->PwRegFailLogged;' "$1" &&
                       grep -q 'const BOOL hadSlotBefore  = windowData->PwBrokerEverSourced;' "$1" &&
                       grep -q 'if (QgaLateRegIsStartup(refusedWhileUp, hadSlotBefore))' "$1" &&
                       ! grep -q 'if (QgaHoldIsStartup(FALSE, g_BrokerReadyAt != 0))' "$1" &&
                       # the snapshot must precede the call it is a snapshot of
                       [ "$(grep -n 'const BOOL refusedWhileUp' "$1" | cut -d: -f1)" -lt \
                         "$(grep -n 'if (BrokerRegister(windowData))' "$1" | cut -d: -f1)" ]; }
# A HOLD WHOSE REASON IS NORMAL IS NOT LOGGED, AND MUST NOT SPEND THE ONE-SHOT. Owner 2026-10-17:
# "we should not log this at all. we should log when something goes wrong." PwHoldLogged is one-shot
# PER WINDOW, so a silent first-frame hold that still SET it would suppress that window's one real
# line for ever - a later hold for slot-holds-another-hwnd or dims-mismatch-STUCK would never be
# said. The guard is therefore the CONJUNCTION in the condition, not the absence of a log call.
mc_hold_quiet_keeps_latch() {
    # the gate tests both the latch AND the reason, so a normal reason returns without touching it
    grep -q 'if (!entry->PwHoldLogged && !QgaHoldReasonIsNormal(holdWhy))' "$1" &&
    # and the reason reached it from the refusal itself
    grep -q 'PwConsumeBrokerFrame(entry, &pwRect, &holdWhy)' "$1" &&
    # a normal reason has NO log call of its own: exactly two BROKERHOLD arms remain
    [ "$(grep -c 'Log\(Info\|Warning\)("BROKERHOLD' "$1")" = 2 ]
}
shape "main.c: a BROKERHOLD reason classed normal logs NOTHING and does not spend the one-shot, so a later real reason still reports" \
      mc_hold_quiet_keeps_latch "$MAIN" 'if (!entry->PwHoldLogged && !QgaHoldReasonIsNormal(holdWhy))'
shape "main.c: BROKERLATEREG's level comes from QgaLateRegIsStartup fed by flags snapshotted BEFORE the retry (never the inert broker-ready test)" \
      main_latereg_level "$MAIN" 'if (QgaLateRegIsStartup(refusedWhileUp, hadSlotBefore))'

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
    grep -q 'const BOOL shellUp = ShellWindowNow() != NULL;' "$1" && grep -q 'sid != 0xFFFFFFFF && ShellWindowNow())' "$1" &&
    grep -q 'if (!ShellWindowNow()) return FALSE;' "$1" && [ "$(grep -c '|| !ShellWindowNow()) return;' "$1")" -eq 2 ] &&
    grep -q 'data->Handle == ShellWindowNow())' "$1" && grep -q '!ShellWindowNow() || g_OnSecureDesktop ||' "$1"; }
shape "main.c: the shell-seen latch is set only through ShellWindowNow (the one GetShellWindow() call in code), which every phase gate asks" main_shell_latch "$MAIN" 'const HWND shell = GetShellWindow();'

# THE DE-SLICE DOWN-CLOCK IS HELD UNTIL THE LAUNCH IS ISSUED, so the report cannot fire in flight.
# DEFECT, MEASURED 2026-10-23 on two subjects and CLIENT-VISIBLE both times: the hold required BOTH
# conditions (`!ShellWindowNow() && !g_WgcLaunched`), so a guest whose shell appeared early armed the
# clock with `now` at the first poll - 064605.351 - while the launch did not go out until 064633.799.
# The deadline expired at 064635.351 and `WGCBROKER ready (pid 8632 validated)` landed 49 ms later.
# "Has not been running for 30 s" can only mean 30 s since we asked it to run. The arm branch already
# anchored on g_WgcLastLaunch, but only once the launch HAD happened, and nothing re-anchored it.
# WIDENING A HOLD CAN CREATE A SILENCE, so the leg also requires the hold to SAY why it is holding:
# a shell up longer than the report's own deadline with no launch issued is the launch guard's
# anomaly, said once at W, not a broker reported as down.
main_deslice_launch_hold() {
    grep -q 'if (!g_WgcLaunched)' "$1" &&
    ! grep -q 'if (!ShellWindowNow() && !g_WgcLaunched)' "$1" &&
    grep -q 'const ULONGLONG anchor = g_WgcLastLaunch ? g_WgcLastLaunch : now;' "$1" &&
    grep -q 'LogWarning("QGABROKERLAUNCHNOTISSUED shell up %I64u s and the de-slice broker launch has not been "' "$1" &&
    grep -q 'g_ShellSeenTick = GetTickCount64();' "$1" &&
    grep -q 'const BOOL pendingTooLong = shellUp && g_ShellSeenTick && (now - g_ShellSeenTick) >= DESLICE_LAUNCH_PENDING_MS;' "$1" &&
    grep -q '#define DESLICE_LAUNCH_PENDING_MS 90000' "$1" &&
    grep -q 'g_BrokerNextWarn = g_ShellSeenTick + DESLICE_LAUNCH_PENDING_MS;' "$1" &&
    grep -q 'g_BrokerDownSince = g_ShellSeenTick;' "$1" &&
    awk '/if \(!g_WgcLaunched\)$/{h=NR} /const ULONGLONG anchor = g_WgcLastLaunch \? g_WgcLastLaunch : now;/{a=NR} END{exit !(h && a && h<a)}' "$1"; }
shape "main.c: the de-slice down-clock is HELD only for the grace window (the report cannot fire in flight), then reported anchored at the SHELL after a PENDING window clear of the measured launch latency so the hold is neither a silence nor a second in-flight report, and anchored at the LAUNCH once it is issued" main_deslice_launch_hold "$MAIN" 'const ULONGLONG anchor = g_WgcLastLaunch ? g_WgcLastLaunch : now;'

# THE FOURTH ARM of the 30 s classifier (docs/ADR-uac.md 5): LogonUI up before this agent saw a shell is named as that,
# never as a lock, and the WARNING carries shell-seen beside console-user.
main_preshell_arm() { grep -q 'else if (logonui && !shellSeen)' "$1" && grep -q 'console-user=%d shell-seen=%d' "$1" &&
    awk '/else if \(logonui && !shellSeen\)/{a=NR} /else if \(logonui\)$/{b=NR} END{exit !(a && b && a<b)}' "$1"; }
shape "main.c: the 30 s classifier has the fourth arm (LogonUI up before this agent saw a shell) ahead of the two-state LogonUI arm, and carries shell-seen" main_preshell_arm "$MAIN" 'else if (logonui && !shellSeen)'

# ---- the hidden Start dismissal: the MECHANISM, pinned in shape (2026-10-17) ----------------------------
# NO KEYSTROKE, EVER, from this path. SendInput was measured closing Open-Shell's own menu (Jev
# race_is_real 0.96) and the posted replacement does not close Start at all - main.c's own comment
# of 2026-10-04 says so and two guest runs agree. If either comes back, this fails.
# Anchored on the PRESENCE of the verdict call as well as the absence of a keystroke: a pure
# absence check can never be made to fail by removing a line, which this harness rightly refuses.
main_dismiss_no_keystroke() {
    grep -q 'QgaHiddenStartVerdict(' "$1" &&
    awk '/^static void StartOpeningExamine/{f=1} f&&/PostMessage|SendInput|VK_ESCAPE|InjectInput/{bad=1} f&&/^}/&&f{exit bad} END{exit bad}' "$1"
}
shape "main.c: the hidden-Start dismissal posts NO KEYSTROKE of its own" main_dismiss_no_keystroke "$MAIN" 'const QGA_START_VERDICT verdict = QgaHiddenStartVerdict('
# AND THE ONLY INJECTION ON THAT PATH IS A ZERO-DISTANCE MOUSE MOVE. The dismissal reaches
# SendInput through the shared ApplyForeground, which nudges the input queue so the foreground lock
# allows the activation - measured, because without it the guest answered "activation to 0x30062
# refused - foreground held by pid 6088" twice in one run. Jev nudge-is-allowed 0.91, on the
# grounds that the ban is on a KEYSTROKE (one was measured closing Open-Shell's own menu) and a
# cursor-less mouse move cannot dismiss anything. So this pins the event TYPE and that it carries
# no displacement: if the nudge ever becomes a key, or gains a dx/dy, it fails here.
util_nudge_is_a_bare_mouse_move() {
    awk '/^BOOL ApplyForeground/{f=1}
         f&&/nudge\.type *= *INPUT_MOUSE/{m=1}
         f&&/nudge\.mi\.dwFlags *= *MOUSEEVENTF_MOVE/{z=1}
         f&&/nudge\.(type *= *INPUT_KEYBOARD|ki\.)/{bad=1}
         f&&/nudge\.mi\.(dx|dy) *= *[^0]/{bad=1}
         f&&/^}/{exit !(m&&z) || bad}
         END{exit !(m&&z) || bad}' "$1"
}
shape "util.c: the activation nudge is a MOUSE move with no displacement, never a key" util_nudge_is_a_bare_mouse_move "$ROOT/agent/gui-agent/util.c" 'nudge.mi.dwFlags = MOUSEEVENTF_MOVE;   // dx = dy = 0: the cursor does not move'
# A STUCK hidden menu is an ERROR, not a warning: it is taking the user's clicks, which is not a
# workable state (it was a LogWarning until 2026-10-17).
main_dismiss_stuck_error() {
    awk '/case QGA_START_STUCK:/{f=NR} f&&NR>f&&NR<f+12&&/LogError\(/{ok=1} END{exit !ok}' "$1"
}
shape "main.c: a Start still open past the bound is reported at ERROR" main_dismiss_stuck_error "$MAIN" 'LogError("QGASTARTDISMISS 0x%x: still open %llu ms after activation returned'
# THE CLOSURE IS SAID. Both ways an opening ends report at Info and re-arm, so a dismissal that
# worked is distinguishable from one that never ran - which it was not before.
main_dismiss_closure_said() {
    awk '/case QGA_START_CLOSED_CLOAKED:/{f=NR} f&&NR>f&&NR<f+14&&/LogInfo\(/{i=1} f&&NR>f&&NR<f+14&&/g_StartDismissSent = FALSE;/{r=1} END{exit !(i&&r)}' "$1"
}
shape "main.c: a closed hidden Start is recorded at Info and re-arms" main_dismiss_closure_said "$MAIN" 'LogInfo("QGASTARTDISMISS 0x%x: closed (%s) %llu ms after %s",'
# ONE ACTIVATION BODY, two callers. Two copies of an attach-and-detach would drift, and the easy
# way to write it wrong is to leave out the detach.
shape_apply_both() {
    grep -q 'ApplyForeground(target, &how)' "$1" && ! grep -q 'AttachThreadInput' "$1"
}
shape "main.c: the dismissal activates through the shared ApplyForeground, with no attach logic of its own" shape_apply_both "$MAIN" 'const BOOL applied = ApplyForeground(target, &how);'
vch_records_dom0_focus() {
    grep -q 'InterlockedExchangePointer((PVOID volatile\*)&g_Dom0FocusWindow, (PVOID)window);' "$1" &&
    grep -q 'ApplyForeground(window, &how)' "$1"
}
shape "vchan-handlers.c: dom0's focus decision is recorded, and applied through the shared body" vch_records_dom0_focus "$ROOT/agent/gui-agent/vchan-handlers.c" 'InterlockedExchangePointer((PVOID volatile*)&g_Dom0FocusWindow, (PVOID)window);'
# util.c's shared body must always detach what it attached.
util_apply_detaches() {
    awk '/^BOOL ApplyForeground/{f=1} f&&/AttachThreadInput\(ourThread, fgThread, TRUE\)/{a=1} f&&/AttachThreadInput\(ourThread, fgThread, FALSE\)/{d=1} f&&/^}/&&a{exit !d} END{exit !(a&&d)}' "$1"
}
shape "util.c: ApplyForeground always detaches the input queue it attached" util_apply_detaches "$ROOT/agent/gui-agent/util.c" 'AttachThreadInput(ourThread, fgThread, FALSE);'

# ---- the startup dump: governing settings at Info, labelled experiments at Debug (2026-10-17) ----
# The owner's rule is that normal operation is quiet. 27 Info lines per start described 27 feature
# switches. Only FOUR moved, and the number is the honest one: Jev, given the author's own
# descriptions, would not call either the drag/DDA family (noul 0.42) or the instrumentation family
# (0.41) experiment knobs, and chose "move only the ones the source itself labels" (0.61). perf.h
# heads exactly one block "Feature switches for attribution" and calls FocusRaise an experiment, so
# those four moved and the rest stay until there is better evidence than 0.57.
PERF="$AGENT/gui-agent/perf.c"
perf_labelled_at_debug() {
    grep -q 'LogInfo("QGASTARTPOLICY' "$1" || return 1
    for t in QGADDACAPTURE QGAFRAMEDROP QGASWEEPEXEMPT QGAFOCUSRAISE; do
        grep -q "LogDebug(\"$t" "$1" || return 1
        grep -q "LogInfo(\"$t" "$1" && return 1
    done
    # and the dump stays bounded: a new Info line per switch is the thing being prevented
    local n; n=$(awk '/^void PerfInit/,/^}/' "$1" | grep -c 'LogInfo(')
    [ "$n" -le 24 ]
}
shape "perf.c: the labelled attribution switches log at Debug, the cell is said once at Info, and the dump stays bounded" perf_labelled_at_debug "$PERF" 'LogInfo("QGASTARTPOLICY blockkey=%s seamlessStart=%s -> %s",'
# PROVENANCE IS APPENDED, NEVER INSERTED. guest/verify-running-agent.ps1 matches the prefix
# 'QGASHELLMANAGED policy=', and a prefix inserted in FRONT blinded three consumers on 2026-10-16.
perf_provenance_appended() {
    grep -q 'LogInfo("QGASHELLMANAGED policy=%u (0=none 1=all 2=start-only) (%s)"' "$1" &&
    grep -q 'LogInfo("QGASEAMLESSSTART %s (%s)"' "$1"
}
shape "perf.c: the value's source is APPENDED to the two settings lines, so the prefix consumers still match" perf_provenance_appended "$PERF" 'LogInfo("QGASHELLMANAGED policy=%u (0=none 1=all 2=start-only) (%s)", g_ShellManaged,'

# EVERY xencontrol logger, not just the one I happened to patch. There are two (capture.c and
# perwindow.c); guarding only capture.c left 98 of 118 per-notify Debug lines alive, because the
# per-window path is the busy one. This counts the callbacks and requires each to ask the predicate.
xc_all_loggers_guarded() {
    local n g
    n=$(command grep -rlE 'XENCONTROL_LOG_LEVEL logLevel, IN const char\* function' "$1"/*.c 2>/dev/null | wc -l)
    g=$(command grep -rl 'QgaXcLineKept' "$1"/*.c 2>/dev/null | wc -l)
    [ "$n" -ge 2 ] && [ "$n" = "$g" ]
}
shape "agent: EVERY xencontrol logger asks QgaXcLineKept, not just one of them" xc_all_loggers_guarded "$AGENT/gui-agent" 'if (!QgaXcLineKept((int)logLevel, function))   // GUARD:xcnotify'

say "--- outputs in $OUT"
exit $bad
