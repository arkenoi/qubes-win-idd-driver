#!/usr/bin/env bash
# deathevent-selftest.sh - offline proof matrix for the supervisors' death record (docs/ADR-supervision.md section 2):
# agent/include/deathevent.h, the ONE Event Log entry the QubesGuiWatchdog service and the gui-agent write when a child
# they started exits without being asked to, and the shipped call sites that write it.
#
# Runs on this dev qube with gcc alone (no rig, no guest, no Windows toolchain) against tools/tests/win32stub (the Win32
# surface the files use, types + arities only) plus the REAL windows-utils headers:
#   clean build of gui-agent/deathevent_test.c   MUST pass (the record's source, type, id, six strings, bounds, failure paths)
#   DEATHEVENT_DEFECT_* builds                   MUST fail - a guard never seen to fail is decoration:
#       WARNING   written as a warning            SHAREDID  one id for every child            NOCODE  the exit code dropped
#       HANGASEXIT a hang written as "exited, exit code unknown" (rz39 defect 2)
#   UNCOMPILED SHAPE CHECK of the shipped callers: watchdog/watchdog.c parses with gcc -fsyntax-only against the stubs and the
#   real log.h/config.h/qubes-io.h (the main.c and etwproxy.c sites pull ETW/LSA/DirectX headers no stub covers, so they are
#   held to a static shape: the include, exactly one DeathEventReport per child id, no LogWarning left on the death lines).
#   CI compiles the real thing; this proves the C is well-formed and the contract is pinned, nothing about linking.
#
#   AGENT_DIR=<path>           the agent checkout (default: the agent submodule); WINDOWS_UTILS_INC=<path> the real headers
#   DEATHEVENT_OUT=<dir>       where the builds and outputs go (default: a mktemp dir)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="${AGENT_DIR:-$ROOT/agent}"
UTILS_INC="${WINDOWS_UTILS_INC:-$ROOT/upstream/ro/qubes-windows-utils/include}"
STUB="$ROOT/tools/tests/win32stub"
OUT="${DEATHEVENT_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/deathevent-selftest-XXXXXX")}"
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }

for need in "$AGENT/include/deathevent.h" "$AGENT/gui-agent/deathevent_test.c" "$UTILS_INC/log.h" "$STUB/windows.h"; do
    if [ ! -f "$need" ]; then say "FAIL  missing $need - nothing ran (missing data fails)"; exit 2; fi
done

INC=(-I"$STUB" -I"$AGENT/include" -I"$UTILS_INC")
build() { gcc -std=c99 -Wall -Wextra -Werror -D_DEFAULT_SOURCE "${INC[@]}" ${2:-} "$AGENT/gui-agent/deathevent_test.c" -o "$OUT/$1" 2>"$OUT/$1.build.err"; }

# ---- the record: clean must pass -------------------------------------------------------------------------
if build clean ""; then
    "$OUT/clean" >"$OUT/clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
    if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 40 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
    else say "FAIL  clean: rc=$rc ok=$n fail=$f"; grep '^FAIL' "$OUT/clean.out" | head -5; bad=1; fi
else say "FAIL  clean build: $(head -3 "$OUT/clean.build.err")"; bad=1; fi

# ---- every defect knob must make the suite FAIL -----------------------------------------------------------
for d in WARNING SHAREDID NOCODE HANGASEXIT; do
    if build "defect-$d" "-DDEATHEVENT_DEFECT_$d"; then
        "$OUT/defect-$d" >"$OUT/defect-$d.out" 2>&1; rc=$?
        f=$(grep -c '^FAIL' "$OUT/defect-$d.out")
        if [ "$rc" -ne 0 ] && [ "$f" -gt 0 ]; then say "PASS  defect $d: suite FAILED as required (rc=$rc, $f failing checks: $(grep '^FAIL' "$OUT/defect-$d.out" | head -1 | cut -c6-90))"
        else say "FAIL  defect $d: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1; fi
    else say "FAIL  defect $d build: $(head -3 "$OUT/defect-$d.build.err")"; bad=1; fi
done

# ---- UNCOMPILED: the watchdog parses against the stubs + the real headers ---------------------------------
if [ -f "$AGENT/watchdog/watchdog.c" ]; then
    gcc -std=c99 -fsyntax-only -Wall -Wextra -D_DEFAULT_SOURCE "${INC[@]}" "$AGENT/watchdog/watchdog.c" >"$OUT/watchdog.syntax" 2>&1
    errs=$(grep -c 'error:' "$OUT/watchdog.syntax")
    if [ "$errs" -eq 0 ]; then say "PASS  watchdog.c: gcc -fsyntax-only clean against the stubs + real log.h/config.h/qubes-io.h (UNCOMPILED: CI builds it; $(grep -c 'warning:' "$OUT/watchdog.syntax") pre-existing warning(s))"
    else say "FAIL  watchdog.c: $errs syntax error(s): $(grep -m1 'error:' "$OUT/watchdog.syntax")"; bad=1; fi
else say "FAIL  $AGENT/watchdog/watchdog.c missing"; bad=1; fi

# ---- UNCOMPILED: the agent's three sites, held to a static shape -----------------------------------------
shape() { # $1 label, $2 ok(0/1)
    if [ "$2" -eq 1 ]; then say "PASS  shape: $1"; else say "FAIL  shape: $1"; bad=1; fi
}
MAIN="$AGENT/gui-agent/main.c"; ETW="$AGENT/gui-agent/etwproxy.c"; WD="$AGENT/watchdog/watchdog.c"
for f in "$MAIN" "$ETW" "$WD"; do
    shape "$(basename "$f") includes deathevent.h" "$(grep -q '#include "deathevent.h"' "$f" && echo 1 || echo 0)"
done
shape "main.c writes exactly one record for the broker (DEATHEVENT_ID_WGCBROKER)" "$([ "$(grep -c 'DeathEventReport(DEATHEVENT_ID_WGCBROKER' "$MAIN")" -eq 1 ] && echo 1 || echo 0)"
shape "main.c writes exactly one record for the bridge (DEATHEVENT_ID_NOTIFBRIDGE)" "$([ "$(grep -c 'DeathEventReport(DEATHEVENT_ID_NOTIFBRIDGE' "$MAIN")" -eq 1 ] && echo 1 || echo 0)"
shape "etwproxy.c writes exactly one record for the proxy (DEATHEVENT_ID_ETWPROXY)" "$([ "$(grep -c 'DeathEventReport(DEATHEVENT_ID_ETWPROXY' "$ETW")" -eq 1 ] && echo 1 || echo 0)"
shape "watchdog.c writes exactly one record for the agent (DEATHEVENT_ID_GUI_AGENT)" "$([ "$(grep -c 'DeathEventReport(DEATHEVENT_ID_GUI_AGENT' "$WD")" -eq 1 ] && echo 1 || echo 0)"
# the death lines are ERROR: no LogWarning carries these tokens any more
shape "QGANOTIFBRIDGEEXIT is logged at ERROR" "$(grep -q 'LogError("QGANOTIFBRIDGEEXIT' "$MAIN" && ! grep -q 'LogWarning("QGANOTIFBRIDGEEXIT' "$MAIN" && echo 1 || echo 0)"
shape "QGABROKERDIED is logged at ERROR" "$(grep -q 'LogError("QGABROKERDIED' "$MAIN" && ! grep -q 'LogWarning("QGABROKERDIED' "$MAIN" && echo 1 || echo 0)"
shape "the etwproxy exit lines ('proxy exited rc=') are logged at ERROR" "$([ "$(grep -c 'LogWarning("ETWPROXYSUP proxy exited rc=' "$ETW")" -eq 0 ] && [ "$(grep -c 'LogError("ETWPROXYSUP proxy exited rc=' "$ETW")" -ge 3 ] && echo 1 || echo 0)"
shape "the etwproxy park line is logged at ERROR" "$(grep -q 'LogError("ETWPROXYSUP parked for this boot' "$ETW" && echo 1 || echo 0)"
# rz39: a hang is written as a hang (DEATHEVENT_EXIT_HUNG); the watchdog's death line names the 0x5aa grant-table cause only for that code
shape "main.c writes the broker's hang as DEATHEVENT_EXIT_HUNG, never as an exit with no code" "$(grep -q 'hung ? DEATHEVENT_EXIT_HUNG : DEATHEVENT_EXIT_UNKNOWN' "$MAIN" && echo 1 || echo 0)"
shape "watchdog.c's death line says the grant-table cause only when the code is 0x5aa, never as a hard-coded cause" \
      "$(grep -q 'exitCode == 0x5aa' "$WD" && ! grep -q 'grant-table exhaustion, 0x5aa, needs a reboot' "$WD" && echo 1 || echo 0)"
# 2026-10-07 (docs/ADR-supervision.md 4-5): the service has NO relaunch loop - a dead agent makes it fail itself for the SCM's recovery
shape "watchdog.c has no relaunch loop: no quick-death backoff, no Sleep poll" \
      "$(! grep -qE 'QUICK_DEATH_MS|BACKOFF_MAX_MS|backoffMs|Sleep\(' "$WD" && echo 1 || echo 0)"
shape "watchdog.c fails itself for the SCM on an agent death (QGA_SVC_EXIT_AGENT_DIED reported as the service-specific exit code)" \
      "$(grep -q 'InterlockedExchange(&g_ServiceFailCode, (LONG)QGA_SVC_EXIT_AGENT_DIED)' "$WD" && grep -q 'dwServiceSpecificExitCode = (DWORD)failCode' "$WD" && echo 1 || echo 0)"
shape "watchdog.c decides every agent exit through the pure table (QgaDecideAgentExit), never SM_SHUTTINGDOWN (measured never to fire)" \
      "$(grep -q 'QgaDecideAgentExit(' "$WD" && ! grep -q 'SM_SHUTTINGDOWN' "$WD" && echo 1 || echo 0)"


# ---- NO GUI DOMAIN IS A START-TIME CONDITION, NOT A DEATH (include/qga-exitcodes.h; Jev 0.94, 2026-10-03) ---------------------
# A qube with guivm '' made the agent exit 0 at Init and the watchdog relaunch it for ever (47 times in one boot, then once a minute);
# with the death events that would be a death per relaunch. Each check below is ALSO run against a copy of its file with the guarded
# line removed, and must then FAIL - a shape check never seen to fail is decoration.
nogui_agent_absent()  { grep -q 'status = QGA_EXIT_NO_GUI_DOMAIN;' "$1" && grep -q 'LogInfo("QGANOGUIDOMAIN' "$1"; }
nogui_agent_initrc()  { grep -q 'return (int)QGA_EXIT_NO_GUI_DOMAIN;' "$1" && grep -q 'return (int)win_perror2(initStatus, "Init");' "$1" && ! grep -q 'return win_perror("Init");' "$1"; }
# (2026-10-07: the latch is set from the pure verdict - QGA_DECIDE_NOGUI_LATCH writes no record, held row by row in
# tools/tests/lifecycle-selftest.sh - and the service's only wait is INFINITE: no poll, no timeout, ever.)
nogui_wd_latch()      { awk '/case QGA_DECIDE_NOGUI_LATCH:/{f=1} f{print} f&&/break;/{exit}' "$1" > "$OUT/nogui-latch.c"
                        grep -q 'LogInfo("QGAWDNOGUIDOMAIN' "$OUT/nogui-latch.c" && ! grep -q 'DeathEventReport' "$OUT/nogui-latch.c" && grep -q 'noGuiDomain = TRUE;' "$1"; }
# The wait is INFINITE BY DEFAULT and there is no Sleep() poll - but it is no longer literally INFINITE at the
# call, and asserting that spelling made this check fail on a change that improved the behaviour. The invariant
# is: the default is INFINITE; the ONE thing that may make it finite is a latched session end with no agent of
# ours left in that session (the single state nothing observable can leave); and that deadline LOGS
# QGAWDSESSIONSTUCK and re-arms launching rather than quietly going round again.
nogui_wd_wait()       { grep -q 'DWORD waitMs = INFINITE;' "$1" &&
                        [ "$(grep -c 'WaitForMultipleObjects(waitCount, waitHandles, FALSE, waitMs)' "$1")" -eq 1 ] &&
                        grep -q 'endedSessionAt != 0 && !agentProcess' "$1" &&
                        grep -q 'QGAWDSESSIONSTUCK' "$1" &&
                        ! grep -q 'Sleep(' "$1"; }
nogui_wd_norelaunch() { awk '/if \(launchWanted && !agentProcess && !foreignProcess && !noGuiDomain\)/{a=NR} /StartTargetProcess\(cmdline/{b=NR} END{exit !(a && b && a<b)}' "$1"; }
nogui() { # $1 label, $2 check fn, $3 file, $4 marker of the guarded line (the mutated copy drops the line carrying it)
    local mut="$OUT/nogui-mut-$2.c"
    if "$2" "$3"; then
        grep -v -- "$4" "$3" > "$mut"
        if "$2" "$mut"; then say "FAIL  nogui: $1 - the check still passes with the guarded line removed (it cannot fail)"; bad=1
        else say "PASS  nogui: $1 (and FAILS with the guarded line removed)"; fi
    else say "FAIL  nogui: $1"; bad=1; fi
}
nogui "the agent: the key absent is QGA_EXIT_NO_GUI_DOMAIN, logged once at INFO" nogui_agent_absent "$MAIN" 'status = QGA_EXIT_NO_GUI_DOMAIN;'
nogui "the agent: the exit code is Init's own status, never GetLastError's 0" nogui_agent_initrc "$MAIN" 'return (int)win_perror2(initStatus'
nogui "the watchdog: that exit latches, logs QGAWDNOGUIDOMAIN, writes no death record" nogui_wd_latch "$WD" 'QGA_NOGUI_LATCH'
nogui "the watchdog: it waits with no deadline except a latched session end, and never polls" nogui_wd_wait "$WD" 'DWORD waitMs = INFINITE;'
nogui "the watchdog: while latched it never launches" nogui_wd_norelaunch "$WD" 'QGA_NOGUI_NORELAUNCH'
shape "main.c and watchdog.c include qga-exitcodes.h" "$(grep -q '#include "qga-exitcodes.h"' "$MAIN" && grep -q '#include "qga-exitcodes.h"' "$WD" && echo 1 || echo 0)"

say "--- outputs in $OUT"
exit $bad
