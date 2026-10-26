#!/usr/bin/env bash
# UNRELIABLE - DROPPED FROM PREFLIGHT 2026-10-25, owner's directive: never write a test for a
# test, and never fault-inject a harness fix as part of the harness. This file mutates another
# TEST or HARNESS file and runs the mutants, so a defect in it corrupts both arms. It is not in
# tools/tests/offline-suites.txt, nothing runs it, and it is NOT to be fixed or re-registered
# without the owner saying so. See TESTFORATESTRECURSION in findings/issues.md.
# log-sweep-selftest.sh - offline proof matrix for the PROACTIVE LOG SWEEP (tools/log-sweep.py; the rig wrapper is
# mgmt/harness/log-sweep.sh, the guest collector mgmt/harness/log-sweep-collect.ps1).
#
# No rig, no guest, no network: synthetic logs in the writers' formats are packed into the collector's LSW stream,
# decoded by the REAL decoder, analyzed by the REAL analyzer against a baseline the REAL baseline-init built from the
# clean fixture, with a stub judge standing in for tools/jev.py (answers 'expected', 'defect', or exits 2).
#
# Per this project's rule a check counts only once it has been SEEN TO FAIL with its defect present: every check
# below runs twice - on the shipped analyzer (must flag) and on a copy with ONE `# GUARD:<knob>` line replaced by
# the defect written beside it (must NOT flag). A guard never seen to fail is decoration.
#
#   knob        the defect it re-introduces                                        the check it must break
#   new         an unknown signature is not reported as NEW                        T1 new signature flagged
#   lookup      the baseline is never consulted (everything is NEW)                T2 known-expected not flagged
#   rise        a per-boot count above its ceiling is not reported as ROSE         T3 count rise flagged
#   instances   the instances-per-shutdown metric is never computed                T4 three agent instances in one shutdown = breach
#   stoperr     ERROR lines during a requested stop are not joined to the stop     T5 ERROR during a requested stop = breach
#   missing     a log the collector listed but the decode lacks is tolerated       T6 missing log FAILS
#   empty       an empty log is tolerated                                          T7 empty log FAILS
#   truncated   the decoder's integrity gate (counts, sha256, END line) is off     T8 truncated transfer FAILS (and T9 complete transfer passes)
#   jev2        jev.py exit 2 is not INCOMPLETE                                    T10 judge did not run = INCOMPLETE, never a pass
#   defect      a Jev 'defect' verdict does not fail the run                       T11 Jev-classified defect = FINDINGS
#   ficontext   the fault-injection context is read from the FILE NAME, not the   T13 context decided from the QGAFAULT-INIT evidence
#               QGAFAULT-INIT evidence (coordinator 2026-10-07: never the name)
#   fideclared  a DECLARED fault-injection run excuses broker hangs by itself      T14 a declaration excuses nothing; unproven = breach
#   brokersev   broker hangs/deaths outside fault injection are not thresholded   T15 broker_hangs / broker_deaths breach at P1 outside FI
#   fidetect    an injected hang the agent never detected is not counted          T16 M8: absence of the detection line = breach
#   issuerefs   the baseline audit no longer requires the issue references        T17 heartbeat/slot-ack/keyed-mutex/M7 refs present
#   closedrec   a CLOSED defect recurring is not a breach                         T18 closed-defect recurrence = P1 breach
#   presyncskew the wrapper's pre-sync clock measurement is dropped from the report  T41 presync_skew_s survives into the report
#   (T41/T42 also drive the rig WRAPPER's text, like T25: defect copies with the read, the sync, their order, or the
#   collector's -MaxFiles taken out must each fail the check)
#
#   LOGSWEEP_SELFTEST_OUT=<dir>  keep the fixtures and outputs there (default: a mktemp dir, removed on exit)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/tools/log-sweep.py"
T="${LOGSWEEP_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/logsweep-selftest-XXXXXX")}"
[ -n "${LOGSWEEP_SELFTEST_OUT:-}" ] || trap 'rm -rf "$T"' EXIT
mkdir -p "$T"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

# ---- the fixtures: synthetic logs in the writers' formats, packed as the collector's stream ------------------------
python3 - "$T" <<'PY'
import base64, hashlib, json, os, sys
T = sys.argv[1]
D = "20261007"
def wu(t, tid, lvl, func, msg):   # windows-utils line: [YYYYMMDD.HHMMSS.mmm-TID-L] Function: message
    return "[%s.%s-%s-%s] %s: %s" % (D, t, tid, lvl, func, msg)

def watchdog(pid=700, stop_pid=1000, extra_mid=(), stop_exit="0x0", asked="101000.002", gone="101000.400"):
    L = [wu("100030.000", 100, "I", "LogInit", "Log started, module name: gui-watchdog"),
         wu("100030.000", 100, "I", "LogInit", "System uptime: 30.000 seconds"),
         wu("100030.001", 100, "I", "LogInit", "Running as user: SYSTEM, process ID: %d" % pid),
         wu("100030.001", 100, "I", "LogInit", "Module version: 9.9.9.1"),
         wu("100030.001", 100, "I", "LogInit", "Session: 0"),
         wu("100030.001", 100, "I", "LogInit", 'Command line: "C:\\Program Files\\Qubes Tools\\bin\\gui-watchdog.exe"'),
         wu("100031.000", 101, "W", "WatchdogThread", "Process 'gui-agent.exe' not running, restarting it (servicestop=0 sm_shuttingdown=0 console=0x1 wtsstate=0)"),
         wu("100031.000", 101, "I", "StartTargetProcess", "Running process 'C:\\Program Files\\Qubes Tools\\bin\\gui-agent.exe' in session 1"),
         wu("100041.000", 101, "I", "WatchdogThread", "Process 'gui-agent.exe' has been up for 10000 ms, restart delay reset")]
    L += list(extra_mid)
    L += [wu("101000.000", 102, "I", "ControlHandlerEx", "preshutdown - the agent will not be restarted from here on, stopping"),
          wu("101000.001", 101, "I", "WatchdogThread", "service stop requested, watchdog thread exiting"),
          wu(asked, 101, "I", "StopOwnAgent", "service stopping: asked 'gui-agent.exe' (PID %d) to exit via Global\\QGA_SHUTDOWN, waiting up to 10000 ms on its handle" % stop_pid),
          wu(gone, 101, "I", "StopOwnAgent", "service stopping: 'gui-agent.exe' (PID %d) is gone, exit code %s" % (stop_pid, stop_exit)),
          wu("101000.401", 103, "I", "ServiceMain", "exiting")]
    return L

def agent(pid=1000, t0="100031.200", uptime="31.200", mid=(), tail=None, announce=True, ver="9.9.9.1"):
    tid = 200
    L = [wu(t0, tid, "I", "LogInit", "Log started, module name: gui-agent"),
         wu(t0, tid, "I", "LogInit", "System uptime: %s seconds" % uptime),
         wu(t0, tid, "I", "LogInit", "Running as user: SYSTEM, process ID: %d" % pid),
         wu(t0, tid, "I", "LogInit", "Module version: %s" % ver),
         wu(t0, tid, "I", "LogInit", "Session: 1"),
         wu(t0, tid, "I", "PerfInit", "QGAPROTO off (wobble probe off, drag-only trace off)")]
    if announce:
        L += [wu("100032.000", tid, "I", "WatchForEvents", "Awaiting for a vchan client, write buffer size: 65536"),
              wu("100032.500", tid, "I", "WatchForEvents", "A vchan client has connected"),
              wu("100032.501", tid, "W", "VchanReceiveBuffer", "(0000015AA09BEA70, version): no data, blocking read"),
              wu("100033.000", tid, "I", "WgcLaunch", "WGCBROKER launched via Task Scheduler (user session 1)")]
    L += list(mid)
    L += tail if tail is not None else [wu("100500.000", tid, "I", "AddAllWindows", "QGALEDGERSUM engineDamage=0 c8DrainVchan=0"),
                                        wu("101000.300", tid, "I", "WatchForEvents", "exiting")]
    return L

def events(extra=()):
    E = ["EV 2026-10-07 10:00:20.000 [System] id=6005 level=4 EventLog: The Event log service was started.",
         "EV 2026-10-07 10:00:20.100 [System] id=6013 level=4 EventLog: The system uptime is 20 seconds.",
         "EV 2026-10-07 10:09:58.000 [System] id=1074 level=4 User32: The process C:\\WINDOWS\\System32\\xenagent_9_1_0_0.exe (FIXTURE) has initiated the shutdown of computer FIXTURE on behalf of user NT AUTHORITY\\SYSTEM for the following reason: No title for this reason could be found / Reason Code: 0x8000000c / Shutdown Type: shutdown",
         "EV 2026-10-07 10:09:58.010 [Microsoft-Windows-TerminalServices-LocalSessionManager/Operational] id=54 level=4 Microsoft-Windows-TerminalServices-LocalSessionManager: Local multi-user session manager received system shutdown message",
         "EV 2026-10-07 10:10:03.000 [System] id=6006 level=4 EventLog: The Event log service was stopped.",
         "EV 2026-10-07 10:10:05.000 [System] id=13 level=4 Microsoft-Windows-Kernel-General: The operating system is shutting down at system time 2026-10-07T10:10:05.000000000Z.",
         "EV NONE [Microsoft-Windows-TaskScheduler/Operational]"]
    return E + list(extra)

def block(name, lines):
    text = "\n".join(lines)
    data = text.encode("utf-8")
    b64 = base64.b64encode(data).decode()
    chunks = [b64[i:i + 76] for i in range(0, len(b64), 76)]
    out = ["LSW PULL name=%s lines=%d bytes=%d sha256=%s b64lines=%d" % (name, len(lines), len(data), hashlib.sha256(data).hexdigest(), len(chunks))]
    out += ["LSW B|" + c for c in chunks]
    out.append("LSW PULLEND name=%s b64lines=%d" % (name, len(chunks)))
    return out

def stream(files, ev):
    """files: list of (basename, family, lines). The cmd.exe banner a `qtest pushrun` carries is included on purpose."""
    S = ["Microsoft Windows [Version 10.0.26300.9457]", "(c) Microsoft Corporation. All rights reserved.", "",
         "C:\\Windows\\System32>powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File log-sweep-collect.ps1 -SinceUtc 2026-10-07T09:00:00Z",
         "LSW BEGIN v=1 now=2026-10-07T10:20:00.000 nowutc=2026-10-07T10:20:00.000Z tz=+00:00 host=RklYVFVSRQ== user=U1lTVEVN session=0 since=2026-10-07T09:00:00Z sincelocal=2026-10-07T09:00:00.000",
         "LSW LOGDIR pathb64=%s exists=1" % base64.b64encode(b"Q:\\Qubes Logs").decode()]
    for n, (name, fam, lines) in enumerate(files, 1):
        p = base64.b64encode(("Q:\\Qubes Logs\\" + name).encode()).decode()
        S.append("LSW FILE id=f%d pathb64=%s family=%s bytes=%d lines=%d written=2026-10-07T10:10:00.500 created=2026-10-07T10:00:30.000 partial=0 total_lines=%d" % (n, p, fam, len("\n".join(lines).encode()), len(lines), len(lines)))
        S += block("f%d" % n, lines)
    S.append("LSW EVENTS channels=4 required_missing=-")
    S += block("events", ev)
    S.append("LSW END files=%d pulled=%d errors=0 event_errors=0" % (len(files), len(files)))
    S.append("")
    S.append("C:\\Windows\\System32>")
    return S

def write(name, lines):
    p = os.path.join(T, name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write("\r\n".join(lines) + "\r\n")

WD = "gui-watchdog-20261007-100030-700.log"
AG = "gui-agent-20261007-100031-1000.log"
# base: one boot, one agent, a clean requested stop at shutdown
write("base.pull", stream([(WD, "watchdog", watchdog()), (AG, "agent", agent())], events()))
# reqstop: the base cycle, but the requested stop exits with the code that NAMES the request.
# MEASURED win11-upgrade/win11-reinstall 2026-10-17: the watchdog asks via Global\QGA_SHUTDOWN and
# the agent is gone 773 ms later with 0x20514702 = QGA_EXIT_REQUESTED (agent/include/
# qga-exitcodes.h:22). The grader demanded 0x0 and breached on the product naming its own reason.
write("reqstop.pull", stream([(WD, "watchdog", watchdog(stop_exit="0x20514702")), (AG, "agent", agent())], events()))
# stalelvl: base + a WARNING line whose text T59's baseline declares at INFO. That is the real
# shape of the A6LEAK failure: fc94490 lowered that line to Info, so the current product emits it at
# I - but the log directory the sweep reads carries a PREDECESSOR build's lines too (the bind copies
# the old directory across), and those are still at W. The key is family|LEVEL|text, so the
# declaration matched nothing and the old build's line was judged fresh: 0.51, one hundredth over
# the defect floor, failing all three cells of campaign 20261018-010748.
# IT HAS TO BE THIS WAY ROUND: log-sweep.py:2662 excludes INFO from signatures entirely - "a line
# the writer declared INFO is, by the writer's own statement, not a failure" - so a declaration at W
# with the line emitted at I cannot be driven, because that line never becomes a signature.
stale_mid = [wu("100605.000", 200, "W", "T59Stale", "did a thing by design")]
write("stalelvl.pull", stream([(WD, "watchdog", watchdog()), (AG, "agent", agent(mid=stale_mid))], events()))
# stalewrd: the OTHER half of the same rot, and the half that failed a cell. T59's fixture changes
# the LEVEL and keeps the text; this one keeps the level and changes the TEXT. agent fc94490 also
# reworded "mapped UNCROPPED: the shadow-crop did not resolve within N ms" to "mapped uncropped
# after N ms, shadow strip visible until cropped", which orphaned the QGACROPLATE declaration and
# failed cell WIN10-reinstall of campaign 40243956400 on signatures_unclassified=1 - at x1 against
# a declared max_per_boot of 1, so the cell would otherwise have PASSED. Same shape here: a tag, a
# `(class X)` field, and prose that differs from what T59b's baseline declares.
# The second line is TAGLESS and FIELDLESS on purpose: it is the shape of our watchdog/qubesdb/
# qrexec declarations, which the tag arm cannot key at all, and it drives the weaker
# unique-function arm instead.
reword_mid = [wu("100606.000", 200, "W", "UpdateWindowData",
                 "T59BTAG hwnd 0x1a2b (class T59BClass) mapped uncropped after 40 ms, shadow strip visible"),
              wu("100607.000", 200, "W", "T59CSolo", "did the old thing one way")]
write("stalewrd.pull", stream([(WD, "watchdog", watchdog()), (AG, "agent", agent(mid=reword_mid))], events()))
# newsig: base + an ERROR line that is in no baseline
new_mid = [wu("100600.000", 200, "E", "FixtureNovelty", "a brand new failure 0x1234 that nobody has seen before")]
write("newsig.pull", stream([(WD, "watchdog", watchdog()), (AG, "agent", agent(mid=new_mid))], events()))
# rise: the expected 'blocking read' warning 12 times in one boot (baseline ceiling 1 -> limit 4)
rise_mid = [wu("1004%02d.000" % i, 200, "W", "VchanReceiveBuffer", "(0000015AA09BEA%02d, version): no data, blocking read" % i) for i in range(12)]
write("rise.pull", stream([(WD, "watchdog", watchdog()), (AG, "agent", agent(mid=rise_mid))], events()))
# three: the 2026-10-07 shape - the agent dies at shutdown, is relaunched twice into the ending session, the third is stopped
death1 = [wu("100958.600", 101, "E", "WatchdogThread", "Process 'gui-agent.exe' (PID 1000) exited with code 0x40010004 without this service asking it to - the agent DIED (servicestop=0 sm_shuttingdown=0 console=0x1 wtsstate=0)"),
          wu("100958.650", 101, "W", "WatchdogThread", "Process 'gui-agent.exe' not running, restarting it (servicestop=0 sm_shuttingdown=0 console=0x1 wtsstate=0)"),
          wu("100958.650", 101, "I", "StartTargetProcess", "Running process 'C:\\Program Files\\Qubes Tools\\bin\\gui-agent.exe' in session 1"),
          wu("100958.735", 101, "E", "WatchdogThread", "Process 'gui-agent.exe' (PID 1001) exited with code 0x40010004 without this service asking it to - the agent DIED (servicestop=0 sm_shuttingdown=0 console=0x1 wtsstate=0)"),
          wu("100959.756", 101, "E", "WatchdogThread", "Process 'gui-agent.exe' died within 10000 ms of starting (exit code 0x40010004), 1 time(s) in a row - backing off to 2000 ms (servicestop=0 sm_shuttingdown=0 console=0x1 wtsstate=0). The guest has NO GUI while this lasts; the agent log names the failure."),
          wu("100959.756", 101, "I", "StartTargetProcess", "Running process 'C:\\Program Files\\Qubes Tools\\bin\\gui-agent.exe' in session 1")]
ag1 = agent(1000, tail=[wu("100958.500", 200, "I", "EnsureOnInputDesktop", "input desktop changed: 'Default' -> 'Winlogon', re-attaching")])
ag2 = agent(1001, t0="100958.704", uptime="598.704", announce=False, tail=[wu("100958.711", 200, "I", "PerfInit", "QGAPROTO off (wobble probe off, drag-only trace off)")])
ag3 = agent(1002, t0="100959.807", uptime="599.807", announce=False,
            mid=[wu("101000.100", 200, "I", "WatchForEvents", "Awaiting for a vchan client, write buffer size: 65536"), wu("101000.150", 200, "I", "WatchForEvents", "A vchan client has connected")],
            tail=[wu("101000.300", 200, "I", "WatchForEvents", "exiting")])
ev3 = events(extra=["EV 2026-10-07 10:09:58.641 [Application] id=4001 level=2 Qubes Windows Tools: The GUI agent (gui-agent.exe, PID 1000) exited without being asked to - exit code 0x40010004 - after running 0:09:27 (567000 ms). A Qubes Windows Tools component died; this is a major error.",
                    "EV 2026-10-07 10:09:58.739 [Application] id=4001 level=2 Qubes Windows Tools: The GUI agent (gui-agent.exe, PID 1001) exited without being asked to - exit code 0x40010004 - after running 0:00:00 (78 ms). A Qubes Windows Tools component died; this is a major error."])
write("three.pull", stream([(WD, "watchdog", watchdog(stop_pid=1002, extra_mid=death1)), (AG, "agent", ag1),
                            ("gui-agent-20261007-100958-1001.log", "agent", ag2), ("gui-agent-20261007-100959-1002.log", "agent", ag3)], ev3))
# stoperr: the requested stop logs an ERROR between 'asked' and 'is gone' (a stale error code), and exits 0xb7
tail_err = [wu("101000.300", 200, "I", "WatchForEvents", "exiting"),
            wu("101000.302", 200, "E", "WinMain", "WatchForEvents failed with error 0xb7: Cannot create a file when that file already exists.")]
write("stoperr.pull", stream([(WD, "watchdog", watchdog(stop_exit="0xb7")), (AG, "agent", agent(tail=tail_err))], events()))
# empty: a listed log with zero lines
write("empty.pull", stream([(WD, "watchdog", watchdog()), (AG, "agent", agent()), ("etw-proxy.log", "etwproxy", [])], events()))
# truncated: the base stream with one base64 line of the agent block removed
base = open(os.path.join(T, "base.pull"), encoding="utf-8").read().splitlines()   # text mode folds \r\n
idx = [i for i, l in enumerate(base) if l.startswith("LSW B|")]
del base[idx[len(idx) // 2]]
write("truncated.pull", base)
# cut: the base stream cut before its END line
cut = open(os.path.join(T, "base.pull"), encoding="utf-8").read().splitlines()
cut = cut[:[i for i, l in enumerate(cut) if l.startswith("LSW END")][0]]
write("cut.pull", cut)

# ---- the GRADER'S OWN defects, found by the lifecycle retest 2026-10-07 ----------------------------------------
# twoboot: TWO boots 100 SECONDS apart - the ordinary shape on this rig, where a guest boots in ~55 s and the harness
# shuts it down ~30 s after the session. One agent per boot, each leaving with its session. The grader used to merge
# them (150 s clustering) and report "2 agent instances in one boot"; and the first shutdown's window, approximated as
# start + 120 s, used to run past the second boot and count ITS agent too.
def short_wd(pid, wdt, uptime, launch_pid, lt, endt, tid):
    return [wu(wdt, tid, "I", "LogInit", "Log started, module name: gui-watchdog"),
            wu(wdt, tid, "I", "LogInit", "System uptime: %s seconds" % uptime),
            wu(wdt, tid, "I", "LogInit", "Running as user: SYSTEM, process ID: %d" % pid),
            wu(wdt, tid, "I", "LogInit", "Module version: 9.9.9.1"),
            wu(wdt, tid, "I", "LogInit", "Session: 0"),
            wu(wdt, tid, "I", "LogInit", 'Command line: "C:\\Program Files\\Qubes Tools\\bin\\gui-watchdog.exe"'),
            wu(lt, tid + 1, "I", "WatchdogThread", "QGAWDLAUNCH 'gui-agent.exe' started as PID %d in session 1" % launch_pid),
            wu(endt, tid + 1, "I", "WatchdogThread", "QGAWDSESSIONEND 'gui-agent.exe' (PID %d) reports session 1 ending - acknowledged" % launch_pid),
            wu(endt, tid + 1, "I", "WatchdogThread", "QGAWDSESSIONEND 'gui-agent.exe' (PID %d) left with its session" % launch_pid)]
def short_agent(pid, t0, uptime, exitt):
    return agent(pid, t0=t0, uptime=uptime, announce=True,
                 mid=[wu(exitt, 200, "I", "WatchForEvents", "QGAEXIT stop event signalled - leaving with 0x20514703")],
                 tail=[wu(exitt, 200, "I", "WinMain", "QGAEXIT exiting with 0x20514703 (the session is ending (WM_ENDSESSION)) - an expected exit, not a failure")])
# boot 1 at 10:00:00 (uptime 30 at 10:00:30), its agent exits 10:01:00; boot 2 at 10:01:40 - exactly 100 s later
TB = [("gui-watchdog-20261007-100030-700.log", "watchdog", short_wd(700, "100030.000", "30.000", 1000, "100031.000", "100100.000", 100)),
      ("gui-agent-20261007-100031-1000.log", "agent", short_agent(1000, "100031.200", "31.200", "100100.000")),
      ("gui-watchdog-20261007-100210-702.log", "watchdog", short_wd(702, "100210.000", "30.000", 1010, "100211.000", "100240.000", 110)),
      ("gui-agent-20261007-100211-1010.log", "agent", short_agent(1010, "100211.200", "31.200", "100240.000"))]
ev_two = ["EV 2026-10-07 10:00:20.000 [System] id=6013 level=4 EventLog: The system uptime is 20 seconds.",
          "EV 2026-10-07 10:01:00.000 [System] id=1074 level=4 User32: The process C:\\WINDOWS\\System32\\xenagent_9_1_0_0.exe (FIXTURE) has initiated the shutdown",
          # NO end marker for this one: its window is approximated as start + 120 s and would reach into boot 2
          "EV 2026-10-07 10:02:00.000 [System] id=6013 level=4 EventLog: The system uptime is 20 seconds.",
          "EV 2026-10-07 10:02:40.000 [System] id=1074 level=4 User32: The process C:\\WINDOWS\\System32\\xenagent_9_1_0_0.exe (FIXTURE) has initiated the shutdown",
          "EV 2026-10-07 10:02:45.000 [System] id=13 level=4 Microsoft-Windows-Kernel-General: The operating system is shutting down at system time 2026-10-07T10:02:45.000000000Z.",
          "EV NONE [Microsoft-Windows-TaskScheduler/Operational]"]
write("twoboot.pull", stream(TB, ev_two))
# clockflip: ONE PER-DAY AGENT LOG that straddles the guest's clock correction, plus a later boot in
# the SAME file. MEASURED on win11-acc 2026-10-09, which is what this reproduces: the agent writes
# 'gui-agent-<yyyymmdd>.log' and APPENDS to it all day, and the guest's clock jumps backwards ~60 s
# into every boot when sync-clock-from-dom0 lands - so the agent's own lines run 055237 then 025240
# inside one file. The boot estimates taken either side of that jump land one offset apart, and the
# analyzer counted ONE boot TWICE (it reported boots=4 with 1@03:39:28 and 4@06:39:31); and because
# lf.boot_time is overwritten by each LogInit, a per-day file offered a SINGLE estimate however many
# boots it spanned. The offset here is 1 h rather than 3 so both phases stay inside the stream's
# since-window; the detector's floor is 600 s, far below either.
# EVERY tail IS EXPLICIT. agent()'s default tail lands at 100500.000, which would put the backward
# jump at 100500->090100 = 4140 s instead of the 3600 s separating the two boot ESTIMATES - and the
# merge only fires when the measured correction matches that separation, so the fixture would not
# drive the case it exists for. (It did not, on the first run: offset read 4140.)
CF_LINES = (agent(1000, t0="100031.200", uptime="31.200", announce=True,
                  tail=[wu("100100.000", 200, "I", "WinMain",
                           "QGAEXIT exiting with 0x20514703 (the session is ending (WM_ENDSESSION)) - an expected exit, not a failure")])
            + agent(1001, t0="090100.000", uptime="60.000", announce=False, tail=[])   # SAME boot, corrected phase
            + agent(1002, t0="091500.000", uptime="30.000", announce=False, tail=[]))  # a LATER, genuinely different boot
CF = [("gui-agent-20261007.log", "agent", CF_LINES)]
ev_flip = ["EV NONE [Microsoft-Windows-TaskScheduler/Operational]"]
write("clockflip.pull", stream(CF, ev_flip))
# rapidboot: FOUR BOOTS CLOSER TOGETHER THAN THE FORWARD ATTRIBUTION WINDOW, one agent instance each.
# This is the MEASURED geometry of win10-clean under package 38857675399 on 2026-10-16: boots 214 s,
# 62 s and 55 s apart, each instance starting ~10-20 s into its own boot (real LogInit uptimes 14.125,
# 10.750, 9.453, 10.093 s), each exiting "an expected exit, not a failure". boot_for() reached 150 s
# FORWARD and kept the LAST boot it admitted, so boots 2, 3 and 4 each claimed the instance that ran
# BEFORE them, three of the four landed in boot 4, and agent_instances_per_boot read 3 against a max
# of 1 - with the owner asking whether the agent was restarting three times a boot. It was not.
# Every number below is that capture's, so nothing here is a shape I invented.
# The prefix must carry pid:tid, because that is what the instance split keys on and what the
# patched logger writes; this block predates wu2(), so it spells the prefix out itself.
def _rb(pid, t0, uptime, texit):
    p = lambda t, f, m: "[%s.%s-%d:%d-I] %s: %s" % (D, t, pid, pid + 4, f, m)
    L = [p(t0, "LogInit", "Log started, module name: gui-agent"),
         p(t0, "LogInit", "System uptime: %s seconds" % uptime),
         p(t0, "LogInit", "Running as user: SYSTEM, process ID: %d" % pid),
         p(t0, "LogInit", "Module version: 4.3.36.977"),
         p(t0, "LogInit", "Session: 1")]
    if texit:
        L.append(p(texit, "WinMain", "QGAEXIT exiting with 0x20514703 (the session is ending "
                                     "(WM_ENDSESSION)) - an expected exit, not a failure"))
    # ONE GRADED LINE PER BOOT, so the forward attribution window has a LINE-level observable.
    # Added 2026-10-17: the anchor now decides an INSTANCE's boot (GUARD:instboot), which is a
    # strict improvement where an uptime line exists - and it left the fwdallow guard with nothing
    # to move, because every observable in this fixture was the instance count. The forward window
    # still governs LINES (log-sweep.py: `l.boot = lf.boot if (lf.boot and one_process) else
    # boot_for(l.ts)`), and this file holds four processes, so one_process is False and boot_for
    # decides. A signature present once per boot therefore measures exactly what the window does.
    # THE FWDPROBE SIGNATURE MOVED OUT OF THIS FILE (2026-10-17). It was put here when the forward
    # window governed LINES; now a line in a file WITH init records is attributed from its own
    # uptime anchor (GUARD:lineboot), so a probe in THIS file measures the anchor, not the window.
    # It lives in the un-anchored blog file appended to RB below, which is what boot_for still
    # decides - and only there, so the signature selector is unambiguous.
    return L
RB = [("gui-agent-20261007.log", "agent",
       _rb(3824, "091032.353", "14.125", "091243.431") + _rb(3844, "091354.000", "10.750", "091358.000")
       + _rb(3864, "091454.000", "9.453", "091525.000") + _rb(3884, "091556.000", "10.093", None))]
# AND THE FORWARD WINDOW'S OWN OBSERVABLE, in a file that has NO init anchor. Since 2026-10-17 a
# line in a file WITH LogInit records is attributed from its own uptime (GUARD:lineboot), which is
# strictly better - and it took the FWDPROBE signature above out of boot_for's hands, leaving
# GUARD:fwdallow undrivable for the second time. The forward window still decides every line in a
# file that declares no init at all (blog/plain families: QubesPvNic.log, agent.log, bridge.log -
# all present in a real capture), so that is where the guard is driven now. `blog` is HH:MM:SS plus
# text, with no pid and no uptime, so there is nothing for an anchor to read.
RB.append(("QubesPvNic.log", "blog",
           ["%s [WARN] FWDPROBE one graded line per boot, for the forward-window guard" % t
            for t in ("09:10:25", "09:13:50", "09:14:50", "09:15:52")]))
write("rapidboot.pull", stream(RB, ["EV NONE [Microsoft-Windows-TaskScheduler/Operational]"]))
# taskok: ONE task that COMPLETED with return code 0 and ONE that genuinely failed to launch, so the
# difference between "ran" and "failed" is what the metric is driven on. Without this the taskrc knob
# could not be driven by the suite at all - no other fixture carries a TaskScheduler 201.
TOK = [("gui-agent-20261007-100031-1000.log", "agent", agent(1000, t0="100031.200", uptime="31.200"))]
ev_taskok = ["EV 2026-10-07 10:00:20.000 [System] id=6013 level=4 EventLog: The system uptime is 20 seconds.",
             'EV 2026-10-07 10:01:00.000 [Microsoft-Windows-TaskScheduler/Operational] id=201 level=4 Microsoft-Windows-TaskScheduler: Task Scheduler successfully completed task "\\QwtClockSync" , instance "{a}" , action "powershell.exe" with return code 0.',
             'EV 2026-10-07 10:01:05.000 [Microsoft-Windows-TaskScheduler/Operational] id=203 level=3 Microsoft-Windows-TaskScheduler: Task Scheduler failed to launch action "powershell.exe" in instance "{b}" of task "\\QubesPvNic". Additional Data: Error Value: 2.',
             "EV NONE [Microsoft-Windows-TaskScheduler/Operational]"]
write("taskok.pull", stream(TOK, ev_taskok))
# vchanwd: an instance that ANNOUNCED a vchan, was never connected to, and WITHDREW the announcement
# on its way out - which the agent logs in those words. MEASURED on win11-acc 2026-10-09: pid 3704
# started 263 s into an install boot, announced, dom0 never attached because the session was ending,
# and it logged "VCHAN no client ever connected - the vchan announcement is withdrawn before exit"
# and exited 0x20514703 (WM_ENDSESSION) - "an expected exit, not a failure", in its own words. The
# gate counted that as a dangling vchan against a threshold of 0.
VWD_LINES = (agent(1000, t0="100031.200", uptime="31.200", announce=False,
                   tail=[wu("100100.000", 200, "I", "WatchForEvents", "Awaiting for a vchan client, write buffer size: 65536"),
                         wu("100204.381", 200, "I", "WatchForEvents", "VCHAN no client ever connected - the vchan announcement is withdrawn before exit"),
                         wu("100204.381", 200, "I", "WatchForEvents", "exiting"),
                         wu("100204.405", 200, "I", "WinMain", "QGAEXIT exiting with 0x20514703 (the session is ending (WM_ENDSESSION)) - an expected exit, not a failure")]))
VWD = [("gui-agent-20261007-100031-1000.log", "agent", VWD_LINES)]
ev_vwd = ["EV 2026-10-07 10:00:20.000 [System] id=6013 level=4 EventLog: The system uptime is 20 seconds.",
          "EV NONE [Microsoft-Windows-TaskScheduler/Operational]"]
write("vchanwd.pull", stream(VWD, ev_vwd))
# phaseflip: a log that straddles the guest's clock correction, with ONE ERROR LINE in the
# PRE-CORRECTION segment, built so the two readings of that line fall on OPPOSITE sides of a --since
# window. The stream's collector clock is 10:20, so the ahead segment is stamped 13:00 (three hours
# ahead of its real 10:00) and the corrected segment 10:00. THE JUMP IS THE OFFSET BY CONSTRUCTION:
# 13:00:01 -> 10:00:01 is exactly 10800 s, so detect_clock_offset measures 3 h. A first version put
# the corrected segment at 10:31, which made the jump 8941 s, so the shifted line landed at 10:31 -
# still inside the window - and the case failed for the fixture's arithmetic rather than the code's.
# With --since 10:30 the error line's STAMP (13:00) is inside the window while its TRUE time (10:00)
# is outside - exactly how the real sweep came to report 35 error lines for a window in which the
# guest wrote none.
PF_LINES = (agent(1000, t0="130000.000", uptime="31.200", announce=False,
                  tail=[wu("130001.000", 200, "E", "GetFrame", "duplication->AcquireNextFrame() failed with error 0x887a0026: pre-correction phase"),
                        wu("100001.000", 200, "I", "WatchForEvents", "Awaiting for a vchan client, write buffer size: 65536"),
                        wu("100002.000", 200, "I", "WatchForEvents", "A vchan client has connected"),
                        wu("100003.000", 200, "I", "WatchForEvents", "VCHAN no client ever connected - the vchan announcement is withdrawn before exit")]))
PF = [("gui-agent-20261007-130000-1000.log", "agent", PF_LINES)]
ev_pf = ["EV NONE [Microsoft-Windows-TaskScheduler/Operational]"]
write("phaseflip.pull", stream(PF, ev_pf))
# skipnames / skipchatty: the collector's cap dropped files and NAMES them; a verdict-deciding family is louder
import base64 as _b64
def with_skip(src, names, out):
    L = open(os.path.join(T, src), encoding="utf-8").read().splitlines()
    enc = ",".join(_b64.b64encode(n.encode()).decode() for n in names)
    L.insert([i for i, l in enumerate(L) if l.startswith("LSW END")][0], "LSW FILESKIPPED n=%d namesb64=%s" % (len(names), enc))
    write(out, L)
with_skip("base.pull", ("gui-agent-20261007-090000-999.log", "qrexec-wrapper-20261007-085959-1.log"), "skipnames.pull")
with_skip("base.pull", ("qrexec-wrapper-20261007-085959-1.log", "qubesdb-daemon-20261007-085959-2.log"), "skipchatty.pull")

# inv: the LOG DIRECTORY INVENTORY, which is what the collector reports about the directory itself
# rather than about the files it pulled. The numbers here are the shape the file explosion had on a
# real guest (368 of 386 files belonging to one module), so the summary is exercised on the case the
# measurement exists for.
def with_inventory(src, out, files=386, lines=41000, nbytes=5 * 1048576, mods=(("qrexec-wrapper", 368, 22000, 0), ("gui-agent", 3, 15000, 0), ("qubesdb-daemon", 2, 3500, 1))):
    L = open(os.path.join(T, src), encoding="utf-8").read().splitlines()
    at = [i for i, l in enumerate(L) if l.startswith("LSW END")][0]
    rows = ["LSW INVENTORY direxists=1 files=%d bytes=%d lines=%d modules=%d" % (files, nbytes, lines, len(mods))]
    for nm, nf, nl, un in mods:
        rows.append("LSW INVMODULE nameb64=%s files=%d bytes=%d lines=%d unreadable=%d" % (
            _b64.b64encode(nm.encode()).decode(), nf, nbytes // max(len(mods), 1), nl, un))
    L[at:at] = rows
    write(out, L)
with_inventory("base.pull", "inv.pull")

# twoproc: ONE agent file holding TWO processes, written the way the patched logger writes - the
# prefix carries pid:tid, and the file name carries only the date. This is the shape that made
# "one file = one instance" collapse every process of the day into one, which zeroed the metric the
# three-instances-per-shutdown defect is measured by. The two processes INTERLEAVE, because that is
# what concurrent appenders to one file do.
def wu2(t, pid, tid, lvl, func, msg):   # the patched prefix: [YYYYMMDD.HHMMSS.mmm-PID:TID-L]
    return "[%s.%s-%d:%d-%s] %s: %s" % (D, t, pid, tid, lvl, func, msg)
def agent_two_procs():
    A, B = 1000, 1100
    L = []
    for pid, t0, up in ((A, "100031.200", "31.200"), (B, "100131.200", "91.200")):
        L += [wu2(t0, pid, pid + 1, "I", "LogInit", "Log started, module name: gui-agent"),
              wu2(t0, pid, pid + 1, "I", "LogInit", "System uptime: %s seconds" % up),
              wu2(t0, pid, pid + 1, "I", "LogInit", "Running as user: SYSTEM, process ID: %d" % pid),
              wu2(t0, pid, pid + 1, "I", "LogInit", "Session: 1"),
              wu2(t0, pid, pid + 1, "I", "WatchForEvents", "Awaiting for a vchan client")]
    # interleaved tails, so neither process's lines are contiguous in the file
    L += [wu2("100200.000", A, A + 1, "I", "WatchForEvents", "A vchan client has connected"),
          wu2("100200.100", B, B + 1, "I", "WatchForEvents", "A vchan client has connected"),
          wu2("100200.200", A, A + 1, "I", "WatchForEvents", "exiting"),
          wu2("100200.300", B, B + 1, "I", "WatchForEvents", "exiting")]
    return L
# msi: the verbose installer log, in both directions. A ROUTINE install schedules its rollback
# actions up front in case something fails, and those lines all contain the word "Rollback"; a
# classifier that keys on the bare word called 168 of one successful upgrade's 171 error lines
# errors and drowned the three that were real.
def msi(t, msg):
    return "MSI (s) (A4:B8) [%s]: %s" % (t, msg)
MSI_ROUTINE = [
    msi("10:00:31:200", "Machine policy value 'DisableRollback' is 0"),
    msi("10:00:31:201", "PROPERTY CHANGE: Adding MsiRollbackInstall property. Its value is '{GUID}Qubes Windows Tools'."),
    msi("10:00:31:202", "Executing op: ActionStart(Name=MsiRollbackInstall,,)"),
    msi("10:00:31:203", "Executing op: CustomActionSchedule(Action=MsiRollbackInstall,ActionType=3073,Source=BinaryData,Target=RollbackInstall)"),
    msi("10:00:31:204", "MSI_LUA : Custom Action 'MsiRollbackInstall' is running with sufficient privileges."),
    msi("10:00:31:205", "Executing op: RollbackInfo(,RollbackAction=Rollback,RollbackDescription=Rolling back action:,,CleanupAction=RollbackCleanup)"),
    msi("10:00:31:206", "Doing action: MsiRollbackInstall"),
    msi("10:00:40:000", "Product: Qubes Windows Tools -- Installation completed successfully."),
]
MSI_FAILED = MSI_ROUTINE + [
    msi("10:00:41:000", "Action ended 10:00:41: InstallFinalize. Return value 3."),
    msi("10:00:41:100", "Product: Qubes Windows Tools -- Installation failed."),
    msi("10:00:41:200", "Action ended 10:00:41: INSTALL. Return value 3."),
    msi("10:00:41:300", "MainEngineThread is returning 1603"),
]
write("msiok.pull", stream([("msi-verbose.log", "msi", MSI_ROUTINE)], ["EV NONE [Application]"]))
write("msibad.pull", stream([("msi-verbose.log", "msi", MSI_FAILED)], ["EV NONE [Application]"]))

TP = [("gui-agent-%s.log" % D, "agent", agent_two_procs()),
      ("gui-watchdog-%s.log" % D, "watchdog", watchdog())]
write("twoproc.pull", stream(TP, ["EV NONE [Application]"]))

# turnover: A PER-DAY LOG THAT SPANS TWO BOOTS, with the REAL numbers from run 38994277148's
# win11-upgrade capture - nothing here is a shape I invented. Every windows-utils module writes one
# file per DAY ('<module>-<yyyymmdd>.log'), so a module that runs once per boot puts several boots
# into one file and the turnover is invisible unless each record is anchored on its OWN uptime.
#   network-setup: pid 7700 at 06:57:32.825 uptime 28.234 s, pid 7852 at 06:59:06.125 uptime
#                  46.062 s - 93 s apart on the wall, 18 s apart in uptime, so TWO boots.
#   qubesdb-daemon: pid 7604 at 06:57:28 uptime 24.00 s AND pid 7604 at 06:59:05 uptime 45.70 s -
#                  the SAME pid in two different boots, because Windows reuses pids freely.
# Both facts were read off the capture; both are what the two knobs below break.
def _wuinit(name, pid, t, up, ver):
    return [wu2(t, pid, pid + 4, "I", "LogInit", "Log started, module name: %s" % name),
            wu2(t, pid, pid + 4, "I", "LogInit", "System uptime: %s seconds" % up),
            wu2(t, pid, pid + 4, "I", "LogInit", "Running as user: SYSTEM, process ID: %d" % pid),
            wu2(t, pid, pid + 4, "I", "LogInit", "Module version: %s" % ver),
            wu2(t, pid, pid + 4, "I", "LogInit", "Session: 1")]
TO = [("network-setup-20261007.log", "winutils",
       _wuinit("network-setup", 7700, "065732.825", "28.234", "4.2.2.0")
       + _wuinit("network-setup", 7852, "065906.125", "46.062", "4.2.2.0")),
      ("qubesdb-daemon-20261007.log", "qubesdb",
       _wuinit("qubesdb-daemon", 7604, "065728.000", "24.000", "4.3.1.0")
       + _wuinit("qubesdb-daemon", 7604, "065905.000", "45.700", "4.3.1.0"))]
# 6013 states the uptime, so the boot census has both boots from a source OUTSIDE the files whose
# attribution is under test - otherwise this case could only ever agree with itself.
ev_turnover = ["EV 2026-10-07 06:57:04.585 [System] id=6013 level=4 EventLog: The system uptime is 0 seconds.",
               "EV 2026-10-07 06:58:13.963 [System] id=6013 level=4 EventLog: The system uptime is 0 seconds.",
               "EV NONE [Application]"]
write("turnover.pull", stream(TO, ev_turnover))

# ---- fault-injection context fixtures (coordinator correction 2026-10-07) ----
BANNER = [wu("100031.300", 200, "W", "FiInit", "QGAFAULT-INIT build=QGA-FAULT-INJECTION:on armdelay=30s negcreate=0(hwnd=0x0) ringstall=0s pumpstall=0s pumplose=0 captureexit=0 dupcreate=0 legacysend=0 rawcreate=0 pwfail=0 gateoff=0x0 damagedelay=0ms")]
def broker_seq(reg="100500.000", hung="100502.008", died="100502.008", reap="100502.015", back="100502.540", pid=4000, with_hung=True, with_reap=True):
    L = [wu("100033.100", 200, "I", "BrokerSupervise", "WGCBROKER ready (pid %d validated)" % pid),
         wu(reg, 200, "I", "BrokerRegister", "QGABROKERREG hwnd=0x7022a slot=8 185x147 buf=262144 t=2131296")]
    if with_hung:
        L += [wu(hung, 200, "E", "BrokerSupervise", "QGABROKERHUNG de-slice broker process is still RUNNING but has not acknowledged the request on slot 8 for 2000 ms (CtlAck 13, wanted 14) - a hang, not a crash; it is blocked in stage=loop"),
              wu(died, 200, "E", "BrokerSupervise", "QGABROKERDIED de-slice broker STOPPED SERVING after being ready (death #1, pid was %d). This is a MAJOR FAILURE, not a hiccup: while it is gone there is NO composite fallback on an eligible guest" % pid)]
        if with_reap:
            L += [wu(reap, 200, "W", "BrokerSupervise", "QGABROKERREAP terminating hung de-slice broker pid %d before relaunch - without this the new instance exits on the singleton mutex and the outage never ends." % pid),
                  wu("100502.400", 200, "I", "WgcLaunch", "WGCBROKER launched via Task Scheduler (user session 1)"),
                  wu(back, 200, "W", "BrokerSupervise", "QGABROKERBACK de-slice broker RECOVERED after 532 ms down (deaths=1). The relaunch worked, but a broker death is a real failure - windows withheld during the outage were never shown.")]
    return L
M8REC = ["M8|name=wgcbroker|pid=4000|suspend=0|t=10:04:55.000", "M8|name=wgcbroker|pid=4000|resume=-1073741558|t=10:05:05.040|alive=False"]
# fi-banner: a fault-injection agent build (the banner) hangs its broker - excused by the banner
write("fibanner.pull", stream([(WD, "watchdog", watchdog()), (AG, "agent", agent(mid=BANNER + broker_seq()))], events()))
# nofi: the same hang on a plain build, no record: a REAL hang and death
write("nofi.pull", stream([(WD, "watchdog", watchdog()), (AG, "agent", agent(mid=broker_seq()))], events()))
# m8: a plain build, the harness's M8 record (pid 4000 suspended 10:04:55..10:05:05) joins the hang by pid and time
write("m8.pull", stream([(WD, "watchdog", watchdog()), (AG, "agent", agent(mid=broker_seq()))], events()))
# m8miss: the record and the registration during the suspension, but the agent never detected the hang
write("m8miss.pull", stream([(WD, "watchdog", watchdog()), (AG, "agent", agent(mid=broker_seq(with_hung=False)))], events()))
# heartbeat: the CLOSED 2026-09-27 shape recurring on a plain build
HB = [wu("100500.000", 200, "E", "BrokerSupervise", "QGABROKERDIED de-slice broker STOPPED HEARTBEATING after being ready (death #1, pid was 4000). This is a MAJOR FAILURE, not a hiccup: the heartbeat has not advanced (bridge tick 100, agent tick 106, 6000 ms)")]
write("heartbeat.pull", stream([(WD, "watchdog", watchdog()), (AG, "agent", agent(mid=HB))], events()))
with open(os.path.join(T, "m8-records.txt"), "w") as f:
    f.write("\n".join(M8REC) + "\n")
with open(os.path.join(T, "context-declared.json"), "w") as f:
    json.dump({"fault_injection_declared": True, "source": "selftest: a declared run"}, f)

# the stub judges: every question answered 'expected' / 'defect', or the instrument failing (exit 2)
def stub(name, choice=None, rc=0, conf=0.91):
    body = ["#!/usr/bin/env python3", "import json, sys",
            "rub = json.load(open(sys.argv[1])); out = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else None"]
    if rc != 0:
        body.append("print('INSTRUMENT: stub - the judge did not run'); sys.exit(%d)" % rc)
    else:
        body.append(("ans = {q: {'type': 'choice', 'choice': %r, 'confidence': " + repr(conf) +
                     ", 'probabilities': {%r: " + repr(conf) + "}} for q in rub['questions']}") % (choice, choice))
        body.append("json.dump({'model': 'stub', 'answers': ans}, open(out, 'w'))")
        body.append(("[print('%%s choice=%%s conf=" + repr(conf) + "' %% (q, %r)) for q in ans]") % choice)
    p = os.path.join(T, name)
    with open(p, "w") as f:
        f.write("\n".join(body) + "\n")
    os.chmod(p, 0o755)
stub("jev-expected.py", "expected")
stub("jev-defect.py", "defect")
stub("jev-exit2.py", rc=2)
# A DEFECT VERDICT BELOW THE FLOOR. baseline-init in log-sweep.py classifies a Jev choice only at
# >= 0.5 and calls anything below it "unsettled ... a human decision is owed"; the analyze path read
# no confidence at all, so 0.40 failed a release cell exactly as 1.00 would. Measured on campaign
# run 38994277148: win10-appvm failed on ONE such verdict, A6LEAK at defect 0.40, whose WARNING
# level is itself a recorded decision (lowering it was reverted the same day at Jev 0.07).
stub("jev-defect-weak.py", "defect", conf=0.40)
print("fixtures written to", T)
# bootshut: a BOOT whose agent launch lands ONE SECOND before the shutdown marker - the install's own reboot
# chain, and the shape that was reported on 2026-10-07 as a relaunch into an ending session (a P2 breach, Jev
# 0.73, against the build that had just fixed that defect). The 2 s pre-roll for marker jitter pulled the
# boot's own launch into the window; nothing of ours had ENDED before it, so it is not a relaunch.
WDB = "gui-watchdog-20261007-100955-710.log"
AGB = "gui-agent-20261007-100957-1010.log"
wd_bs = [wu("100955.000", 100, "I", "LogInit", "Log started, module name: gui-watchdog"),
         wu("100955.000", 100, "I", "LogInit", "System uptime: 5.000 seconds"),
         wu("100955.001", 100, "I", "LogInit", "Running as user: SYSTEM, process ID: 710"),
         wu("100955.001", 100, "I", "LogInit", "Module version: 9.9.9.1"),
         wu("100955.001", 100, "I", "LogInit", "Session: 0"),
         wu("100955.001", 100, "I", "LogInit", 'Command line: "C:\\Program Files\\Qubes Tools\\bin\\gui-watchdog.exe"'),
         wu("100957.000", 101, "W", "WatchdogThread", "Process 'gui-agent.exe' not running, restarting it (servicestop=0 sm_shuttingdown=0 console=0x1 wtsstate=0)"),
         wu("100957.000", 101, "I", "StartTargetProcess", "Running process 'C:\\Program Files\\Qubes Tools\\bin\\gui-agent.exe' in session 1"),
         wu("100957.020", 101, "I", "WatchdogThread", "QGAWDLAUNCH 'gui-agent.exe' started as PID 1010 in session 1"),
         wu("101000.000", 102, "I", "ControlHandlerEx", "preshutdown - the agent will not be restarted from here on, stopping"),
         wu("101000.001", 101, "I", "WatchdogThread", "service stop requested, watchdog thread exiting"),
         wu("101000.002", 101, "I", "StopOwnAgent", "service stopping: asked 'gui-agent.exe' (PID 1010) to exit via Global\\QGA_SHUTDOWN, waiting up to 10000 ms on its handle"),
         wu("101000.400", 101, "I", "StopOwnAgent", "service stopping: 'gui-agent.exe' (PID 1010) is gone, exit code 0x0"),
         wu("101000.401", 103, "I", "ServiceMain", "exiting")]
ag_bs = agent(1010, t0="100957.200", uptime="7.200")
write("bootshut.pull", stream([(WDB, "watchdog", wd_bs), (AGB, "agent", ag_bs)], events()))

# ---- twobuild: ONE module, TWO builds, both inside one window -------------------------------------------------
# THE SHAPE MEASURED ON win11-nfy 2026-10-16, which is the shape of every quick-upgrade cell: the OLD build is
# running when the upgrade starts, writes its last lines, and the NEW build starts three minutes later. One log
# directory then holds `gui-agent-<date>-<time>-<pid>.log` (old build, the per-process name) beside
# `gui-agent-<date>.log` (new build, the per-day name), and NO timestamp separates the two builds.
# The ERROR line below is the real one: the old build's "WatchForEvents failed with error 0x0", which the sweep
# billed to the new build - whose binary provably does not contain that string - so a committed fix was reported
# as not working and the release was briefly suspected of shipping stale binaries.
TBO = "gui-agent-20261007-100031-1000.log"
TBN = "gui-agent-20261007.log"
#
# AND TWO MORE CONDITIONS THE SAME SHAPE REACHES, added 2026-10-19 after they failed the 4.3.37
# acceptance on the win11-upgrade cell. error_lines was build-scoped; dom0_loud_failures (P1) and
# helper_relaunches (P2) were not, so the candidate was graded on the binary it REPLACED:
#   instance pid 4824  4.3.35.795   WGCBROKER launched: 2   + "NOTIFYERR ... sent to dom0"
#   instance pid 8132  4.3.37.1026  WGCBROKER launched: 1
#   instance pid 7924  4.3.37.1026  WGCBROKER launched: 1
# ONE OF EACH ON EITHER SIDE, exactly as T54 does: the prior build gets the doubled launch and a
# dom0 notification, the build under test gets a single launch and a notification of its OWN. A
# filter that dropped both sides would pass a one-sided test while blinding a P1.
tb_old = agent(ver="9.9.9.0", mid=[wu("100200.000", 200, "E", "WinMain",
                                      "WatchForEvents failed with error 0x0: The operation completed successfully."),
                                   # ONE added launch, not two: the agent() template already writes one, so this
                                   # gives the predecessor TWO in one instance - the measured 4.3.35 shape, whose
                                   # own log shows them 2.6 s apart - and therefore exactly ONE excess.
                                   wu("100203.600", 200, "I", "WgcLaunch",
                                      "WGCBROKER launched via Task Scheduler (user session 1)"),
                                   wu("100204.000", 200, "W", "PlatLog",
                                      "NOTIFYERR gui-agent.deslice-down sent to dom0 (#1 this boot; delivery is notifhost's to log)")])
tb_new = [wu("100400.000", "3992:4016", "I", "LogInit", "Log started, module name: gui-agent"),
          wu("100400.000", "3992:4016", "I", "LogInit", "System uptime: 240.000 seconds"),
          wu("100400.001", "3992:4016", "I", "LogInit", "Running as user: SYSTEM, process ID: 3992"),
          wu("100400.001", "3992:4016", "I", "LogInit", "Module version: 9.9.9.1"),
          wu("100400.001", "3992:4016", "I", "LogInit", "Session: 1"),
          wu("100401.000", "3992:4016", "I", "WatchForEvents", "A vchan client has connected"),
          wu("100402.000", "3992:4016", "I", "WgcLaunch",
             "WGCBROKER launched via Task Scheduler, user session 1, restart-on-failure PT1M x3"),
          wu("100403.000", "3992:4016", "W", "PlatLog",
             "NOTIFYERR gui-agent.deslice-down sent to dom0 (#1 this boot; delivery is notifhost's to log)"),
          wu("100500.000", "3992:4016", "I", "WatchForEvents", "exiting")]
# AND THE HALF NO VERSION CAN REACH. Two of our sources declare no module version at all - bridge.log
# (blog: HH:MM:SS plus text, no pid, no uptime, no init) and TaskScheduler records, which come from
# the Windows Event Log. On an upgrade cell their predecessor-era entries are billed to the new
# build and `is_prior_build` has nothing to test, so the INSTALL ANCHOR separates them by WHEN the
# new build first ran - here the 9.9.9.1 init at 10:04:00. One entry of each kind sits on EITHER
# SIDE of it on purpose: the earlier must be excluded, and the later must still COUNT, or the anchor
# would be a blanket time filter rather than a build separator.
TB_BRIDGE = ("bridge.log", "blog",
             ["10:02:30 [WARN] ETW IPC disconnected (recs=38 bad=0) - tier down, DB fallback, reconnecting",
              "10:05:30 [WARN] ETW IPC proxy pipe absent (2) - tier down, DB fallback (reconnect pending)"])
ev_twobuild = ['EV 2026-10-07 10:02:40.000 [Microsoft-Windows-TaskScheduler/Operational] id=203 level=3 Microsoft-Windows-TaskScheduler: Task Scheduler failed to launch action "powershell.exe" in instance "{aaaa1111-0000-0000-0000-000000000001}" of task "\\QwtClockSync" , in error code 2147942403.',
               'EV 2026-10-07 10:05:40.000 [Microsoft-Windows-TaskScheduler/Operational] id=203 level=3 Microsoft-Windows-TaskScheduler: Task Scheduler failed to launch action "powershell.exe" in instance "{aaaa1111-0000-0000-0000-000000000002}" of task "\\QwtClockSync" , in error code 2147942403.']
write("twobuild.pull", stream([(TBO, "agent", tb_old), (TBN, "agent", tb_new), TB_BRIDGE], events(ev_twobuild)))

# ---- nulhole: AN INSTANCE WHOSE "Log started" WAS LOST TO A NUL HOLE --------------------------
# THE SHAPE IS THE MEASURED ONE, bytes and all. 4.3.37 release acceptance, win10-clean: an unclean
# guest shutdown left 7976 NUL bytes inside the per-day agent log (and 15191 across five files on
# that cell; ZERO on the other seven), swallowing pid 3748's "Log started" line. The block then
# begins at "System uptime", and because the normal order is
#     Log started -> System uptime -> Running as user ... process ID
# that uptime landed on the PREVIOUS instance's record and only the pid line opened a new one:
#     record 0: pid 3652, uptime 12.421   <- 3748's uptime; 3652's own 16.843 overwritten
#     record 1: pid 3748, uptime None
# Boot attribution reads the init's uptime, so two of three instances were billed to the NEXT boot,
# two landed in boot 4, and agent_instances_per_boot breached at 2 against a max of 1 - on a guest
# whose own log says every exit was orderly (QGAEXIT ... an expected exit, not a failure).
# The three uptimes and pids below are that capture's.
NH_A = [wu2("100031.200", 3652, 3656, "I", "LogInit", "Log started, module name: gui-agent"),
        wu2("100031.200", 3652, 3656, "I", "LogInit", "System uptime: 16.843 seconds"),
        wu2("100031.200", 3652, 3656, "I", "LogInit", "Running as user: SYSTEM, process ID: 3652"),
        wu2("100031.200", 3652, 3656, "I", "LogInit", "Module version: 9.9.9.1"),
        wu2("100031.200", 3652, 3656, "I", "LogInit", "Session: 1"),
        wu2("100240.000", 3652, 3700, "I", "LifecycleWndProc", "QGAENDSESSION orderly exit complete - exit code QGA_EXIT_SESSION_END")]
# The SECOND instance, with its "Log started" MISSING - that is the whole point of the fixture.
NH_B = [wu2("101130.000", 3748, 3752, "I", "LogInit", "System uptime: 12.421 seconds"),
        wu2("101130.000", 3748, 3752, "I", "LogInit", "Running as user: SYSTEM, process ID: 3748"),
        wu2("101130.000", 3748, 3752, "I", "LogInit", "Module version: 9.9.9.1"),
        wu2("101130.000", 3748, 3752, "I", "LogInit", "Session: 1"),
        wu2("101200.000", 3748, 3752, "I", "WatchForEvents", "exiting")]
# Two boots, one per instance, from the uptimes above: 10:01:31.2 - 16.843 and 10:11:30 - 12.421.
ev_nulhole = ['EV 2026-10-07 10:01:14.357 [System] id=6005 level=4 EventLog: The Event log service was started.',
              'EV 2026-10-07 10:11:17.579 [System] id=6005 level=4 EventLog: The Event log service was started.']
write("nulhole.pull", stream([("gui-agent-20261007.log", "agent", NH_A + NH_B)], events(ev_nulhole)))

# ---- pidreuse: ONE PID, TWO BOOTS, TWO INITS - the condition the fastreboot fixture could not hold
# THE NUMBERS ARE THE MEASURED ONES. Campaign 20261018-172640, win11-clean: the accept battery
# reboots the guest for boot-path acceptance, and the agent came up with THE SAME PID either side -
#   20:40:18.765  pid 4312  System uptime 37.125 s   -> boot 20:39:41.6
#   20:42:03.897  pid 4312  System uptime 35.187 s   -> boot 20:41:28.7
# two boots 107 s apart, each with its own exact uptime. Keyed on the pid alone that was ONE
# instance - announces=2, every helper twice - so vchan_reconnects=1 ("the session LOST its daemon")
# and helper_relaunches=3 breached at max 0 on a guest that did nothing wrong.
#
# WHY THIS FIXTURE HAD TO EXIST. T53d already names the failure - "one pid in two boots collapses
# when the first init wins" - and passes, because it covers the per-file boot publication rather
# than the instance table. And fastreboot above gives each of its three boots a DIFFERENT pid
# (3716/3912/3844), so the condition could not arise in it. The fixture was built around the bug.
# Windows hands out pids in multiples of 4 from a low pool that resets each boot, so an agent
# launching at the same stage of two boots can repeat its pid - not a coincidence, though a scan of
# every capture held here found it once.
PRA = "gui-agent-20261018.log"
def pr_agent(t0, up, pid, tid, last):
    return [wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "Log started, module name: gui-agent"),
            wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "System uptime: %s seconds" % up),
            wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "Running as user: SYSTEM, process ID: %d" % pid),
            wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "Module version: 9.9.9.1"),
            wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "Session: 1"),
            wu(t0, "%d:%d" % (pid, tid), "I", "WatchForEvents", "Awaiting for a vchan client, write buffer size: 65536"),
            wu(t0, "%d:%d" % (pid, tid), "I", "WatchForEvents", "A vchan client has connected"),
            wu(t0, "%d:%d" % (pid, tid), "I", "WgcLaunch", "WGCBROKER launched via Task Scheduler, user session 1"),
            wu(t0, "%d:%d" % (pid, tid), "I", "NotifRunInSession", "NOTIFHOST launched via Task Scheduler (user session 1, resident)"),
            wu(last, "%d:%d" % (pid, tid), "I", "WatchForEvents", "exiting")]
# THE SAME PID 4312 IN BOTH, which is the whole point of the fixture.
pr_ag = (pr_agent("204018.765", "37.125", 4312, 4316, "204150.000")
       + pr_agent("204203.897", "35.187", 4312, 4316, "204400.000"))
write("pidreuse.pull", stream([(PRA, "agent", pr_ag)], events([])))

# ---- fastreboot: TWO BOOTS 37 s APART, one agent each -------------------------------------------
# THE NUMBERS ARE THE MEASURED ONES, not a model of them. win10-clean 2026-10-17, the installer's
# own reboot chain: agent instances at 01:30:23.851/01:33:57.838/01:34:32.832 reporting System
# uptime 19.437/13.406/11.281 s, i.e. boots at 01:30:04.414, 01:33:44.432 and 01:34:21.551 - the
# last two 37.1 s apart, inside BOOT_TOL_S=45, so they merged. The merged boot's instance then fell
# inside the previous shutdown window and the relaunch test fired. Four P2 breaches, one cause.
# The watchdog here does what the real one did: a FRESH service pid per boot, one StartTargetProcess
# at its own startup, and NOT ONE "not running, restarting it" line anywhere.
FRA = "gui-agent-20261007.log"
FRW = "gui-watchdog-20261007.log"
def fr_agent(t0, up, pid, tid, last):
    return [wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "Log started, module name: gui-agent"),
            wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "System uptime: %s seconds" % up),
            wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "Running as user: SYSTEM, process ID: %d" % pid),
            wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "Module version: 9.9.9.1"),
            wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "Session: 1"),
            wu(t0, "%d:%d" % (pid, tid), "I", "WatchForEvents", "Awaiting for a vchan client, write buffer size: 65536"),
            wu(t0, "%d:%d" % (pid, tid), "I", "WatchForEvents", "A vchan client has connected"),
            wu(last, "%d:%d" % (pid, tid), "I", "WatchForEvents", "exiting")]
def fr_wd(t0, pid, tid, agent_t):
    return [wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "Log started, module name: gui-watchdog"),
            wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "Running as user: SYSTEM, process ID: %d" % pid),
            wu(t0, "%d:%d" % (pid, tid), "I", "LogInit", "Module version: 9.9.9.1"),
            wu(agent_t, "%d:%d" % (pid, tid), "I", "StartTargetProcess", "Running process 'C:\\Program Files\\Qubes Tools\\bin\\gui-agent.exe' in session 1")]
fr_ag = (fr_agent("013023.851", "19.437", 3716, 3720, "013246.008")
       + fr_agent("013357.838", "13.406", 3912, 3916, "013404.640")
       + fr_agent("013432.832", "11.281", 3844, 3848, "013509.256"))
fr_wdl = (fr_wd("013023.739", 3572, 3664, "013023.739")
        + fr_wd("013357.765", 3760, 3896, "013357.765")
        + fr_wd("013432.791", 3780, 3832, "013432.791")
        + [wu("013246.810", "3572:3576", "I", "ControlHandlerEx", "preshutdown - the agent will not be restarted from here on, stopping")])
# The SECOND marker is the win11-appvm shape: a shutdown message landing 3 s AFTER a boot
# (01:34:21 from pid 3844's uptime anchor), so that boot's own agent launch and startup announce
# fall inside a window whose end is a guess - with nothing of ours ended before them. Measured
# 2026-10-17: that produced vchan_setups_per_shutdown=1 against a guest whose watchdog log shows a
# fresh service start, its own StartTargetProcess, and `nothing starts in session 1` at the end.
fr_ev = ["EV 2026-10-07 01:32:45.327 [Microsoft-Windows-TerminalServices-LocalSessionManager/Operational] id=54 level=4 Microsoft-Windows-TerminalServices-LocalSessionManager: Local multi-user session manager received system shutdown message",
         "EV 2026-10-07 01:34:24.100 [Microsoft-Windows-TerminalServices-LocalSessionManager/Operational] id=54 level=4 Microsoft-Windows-TerminalServices-LocalSessionManager: Local multi-user session manager received system shutdown message",
         "EV NONE [Microsoft-Windows-TaskScheduler/Operational]"]
write("fastreboot.pull", stream([(FRA, "agent", fr_ag), (FRW, "watchdog", fr_wdl)], fr_ev))

# ---- svcrestart: ONE boot, TWO agents, an ORDERLY SERVICE STOP between them ---------------------
# The win11-reinstall shape: a same-version reinstall stops the services, replaces the files and
# starts them again, so two agent instances share one boot. MEASURED 2026-10-17, boot 3:
#   02:11:03 ControlHandlerEx: stopping...
#   02:11:03 StopOwnAgent: asked (PID 4556) to exit via Global\QGA_SHUTDOWN
#   02:11:04 StopOwnAgent: (PID 4556) is gone, exit code 0x20514702   <- QGA_EXIT_REQUESTED
#   02:11:04 ServiceMain: exiting
#   02:12:24 a NEW gui-watchdog LogInit (uptime 268.843 s - the SAME boot) launches the next agent
SRA = "gui-agent-20261007.log"
SRW = "gui-watchdog-20261007.log"
sr_ag = (fr_agent("020836.998", "41.331", 4556, 4560, "021104.083")
       + fr_agent("021224.767", "269.100", 7268, 7272, "021241.097"))
sr_wd = (fr_wd("020835.900", 4356, 4360, "020835.900")
       + [wu("021103.389", "4356:4424", "I", "ControlHandlerEx", "stopping..."),
          wu("021103.389", "4356:4424", "I", "WatchdogThread", "service stop requested, watchdog thread exiting"),
          wu("021103.389", "4356:4424", "I", "StopOwnAgent", "service stopping: asked 'gui-agent.exe' (PID 4556) to exit via Global\\QGA_SHUTDOWN, waiting up to 10000 ms on its handle"),
          wu("021104.170", "4356:4424", "I", "StopOwnAgent", "service stopping: 'gui-agent.exe' (PID 4556) is gone, exit code 0x20514702"),
          wu("021104.171", "4356:4412", "I", "ServiceMain", "exiting")]
       + fr_wd("021224.503", 7196, 8832, "021224.505"))
write("svcrestart.pull", stream([(SRA, "agent", sr_ag), (SRW, "watchdog", sr_wd)], ["EV NONE [Microsoft-Windows-TaskScheduler/Operational]"]))

PY
[ $? -eq 0 ] || { echo "FATAL: fixture generation failed"; exit 2; }

# ---- knobs: a copy of the analyzer with ONE guard line replaced by its defect ---------------------------------------
knob(){ # $1=name -> path of the defect copy (exactly one line must change)
  local n="$1" out="$T/log-sweep-$n.py"
  local hits; hits=$(grep -c "# GUARD:$n DEFECT: " "$SRC")
  [ "$hits" = 1 ] || { echo "FATAL: GUARD:$n appears $hits times in $SRC (want exactly 1)"; exit 2; }
  sed -E "s|^( *)[^#]*# GUARD:$n DEFECT: (.*)$|\1\2|" "$SRC" > "$out"
  [ "$(diff "$SRC" "$out" | grep -c '^>')" = 1 ] || { echo "FATAL: knob $n changed $(diff "$SRC" "$out" | grep -c '^>') lines"; exit 2; }
  python3 -m py_compile "$out" || { echo "FATAL: knob $n does not compile"; exit 2; }
  echo "$out"
}

decode(){ python3 "$1" decode "$2" --out "$3" > "$3.decode.txt" 2>&1; echo $?; }
analyze(){ # $1=analyzer $2=logsdir $3=baseline $4=judge $5=tag -> rc; report at $T/$5.json
  python3 "$1" analyze "$2" --baseline "$3" --out "$T/$5.json" --summary "$T/$5.txt" --label "$5" --workdir "$T/work-$5" --jev-cmd "$4" > "$T/$5.out" 2>&1; echo $?
}
field(){ python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2"; }

# ---- decode every fixture with the real decoder --------------------------------------------------------------------
for f in base newsig stalelvl stalewrd rise three stoperr empty twoboot clockflip rapidboot taskok vchanwd phaseflip skipnames skipchatty bootshut inv twoproc msiok msibad twobuild pidreuse fastreboot reqstop svcrestart turnover nulhole; do
  rc=$(decode "$SRC" "$T/$f.pull" "$T/$f")
  [ "$rc" = 0 ] || { echo "FATAL: the $f fixture did not decode (rc=$rc): $(tail -2 "$T/$f.decode.txt")"; exit 2; }
  # EVERY LINE IN THESE CORPORA IS WRITTEN BY THIS TEST, so the run declares the errors it caused - which is
  # what the gate condition asks of any run (owner 2026-10-07: a clean error log is the gate condition; Jev:
  # zero-except-declared-injection 1.00). Without this the new threshold fires on the fixtures' own stimulus
  # and every other assertion is measured through a breach that has nothing to do with it.
  # ONLY where the fixture actually carries an error line - a declaration that matches nothing is itself a
  # breach under the new rule, and declaring errors for a corpus that has none tripped exactly that on the
  # clean fixture the first time round. The condition keeps the declarations honest as fixtures change.
  if command grep -rqE '^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+-E\]' "$T/$f/files" 2>/dev/null; then
    printf '{"source": "log-sweep-selftest.sh fixture %s", "declared_errors": [{"pattern": ".", "why": "synthetic fixture: this suite wrote every line in it"}]}\n' "$f" > "$T/$f/context.json"
  fi
done
# AND twobuild DECLARES ONLY THE ERROR LINE IT INJECTS, not every line. The catch-all above
# ("pattern": ".") is what made dom0_loud_failures and notifications_lost UNREACHABLE in this suite:
# _declared_line() matched every line, so both P1 metrics read 0 on every fixture whatever the code
# did, and neither had a single offline assertion. That is how the missing build scope in dom0_loud()
# survived to fail a release campaign (T57). The injected ERROR line stays declared, so T44/T54 are
# measuring exactly what they did before.
printf '{"source": "log-sweep-selftest.sh fixture twobuild", "declared_errors": [{"pattern": "WatchForEvents failed with error 0x0", "why": "synthetic fixture: this suite injects that one error line"}]}\n' > "$T/twobuild/context.json"

cp -r "$T/base" "$T/missing" && rm "$T/missing/files/gui-agent-20261007-100031-1000.log"

# ---- the fixture baseline: the REAL baseline-init over the clean fixture's report -----------------------------------
rc=$(analyze "$SRC" "$T/base" none "$T/jev-expected.py" base0)
[ "$rc" = 0 ] || { echo "FATAL: the clean fixture is not CLEAN against an empty baseline (rc=$rc): $(head -3 "$T/base0.txt")"; exit 2; }
python3 "$SRC" baseline-init "$T/base0.json" --out "$T/baseline.json" > "$T/baseline-init.txt" 2>&1 || { echo "FATAL: baseline-init failed"; exit 2; }
nb=$(field "$T/baseline.json" "len(r['signatures'])")
[ "$nb" -ge 5 ] || { echo "FATAL: the fixture baseline holds only $nb signatures"; exit 2; }
echo "info  fixture baseline: $nb signatures from the clean boot ($T/baseline.json)"

# T1 new signature flagged (knob: new)
rc=$(analyze "$SRC" "$T/newsig" "$T/baseline.json" "$T/jev-expected.py" t1); n=$(field "$T/t1.json" "[s['key'] for s in r['new']]")
if printf '%s' "$n" | grep -q "FixtureNovelty"; then ok "T1 new signature flagged (new=$n)"; else bad "T1 new signature NOT flagged (rc=$rc new=$n)"; fi
K=$(knob new); rc=$(analyze "$K" "$T/newsig" "$T/baseline.json" "$T/jev-expected.py" t1k); n=$(field "$T/t1k.json" "len(r['new'])")
[ "$n" = 0 ] && ok "T1 knob 'new': the check is SEEN TO FAIL (new=$n)" || bad "T1 knob 'new' did not break the check (new=$n)"

# T2 a known-expected signature is not flagged (knob: lookup)
rc=$(analyze "$SRC" "$T/base" "$T/baseline.json" "$T/jev-expected.py" t2); n=$(field "$T/t2.json" "len(r['new'])"); b=$(field "$T/t2.json" "len(r['breaches'])")
[ "$rc" = 0 ] && [ "$n" = 0 ] && [ "$b" = 0 ] && ok "T2 clean boot against its baseline: CLEAN (rc=0, new=0, breaches=0)" || bad "T2 clean boot flagged: rc=$rc new=$n breaches=$b ($(sed -n 2,4p "$T/t2.txt" | tr '\n' ' ' | cut -c1-200))"
K=$(knob lookup); rc=$(analyze "$K" "$T/base" "$T/baseline.json" "$T/jev-expected.py" t2k); n=$(field "$T/t2k.json" "len(r['new'])")
[ "$n" -gt 0 ] && ok "T2 knob 'lookup': the check is SEEN TO FAIL (new=$n)" || bad "T2 knob 'lookup' did not break the check (new=$n)"

# T3 count rise flagged (knob: rise)
rc=$(analyze "$SRC" "$T/rise" "$T/baseline.json" "$T/jev-expected.py" t3); n=$(field "$T/t3.json" "[(s['key'][:60], s['max_per_boot'], s.get('rise_limit')) for s in r['rose']]")
if printf '%s' "$n" | grep -q "VchanReceiveBuffer"; then ok "T3 count rise flagged (rose=$n)"; else bad "T3 count rise NOT flagged (rc=$rc rose=$n)"; fi
K=$(knob rise); rc=$(analyze "$K" "$T/rise" "$T/baseline.json" "$T/jev-expected.py" t3k); n=$(field "$T/t3k.json" "len(r['rose'])")
[ "$n" = 0 ] && ok "T3 knob 'rise': the check is SEEN TO FAIL (rose=$n)" || bad "T3 knob 'rise' did not break the check (rose=$n)"

# T4 three agent instances in one shutdown = breach (knob: instances)
rc=$(analyze "$SRC" "$T/three" "$T/baseline.json" "$T/jev-expected.py" t4); v=$(field "$T/t4.json" "r['metrics']['agent_instances_per_shutdown']"); b=$(field "$T/t4.json" "[x['metric'] for x in r['breaches']]")
d=$(field "$T/t4.json" "r['metrics']['agent_deaths_at_shutdown']"); sh=$(field "$T/t4.json" "[w['instances'] for w in r['shutdowns']]")
if [ "$rc" = 1 ] && [ "$v" = 3 ] && printf '%s' "$b" | grep -q "agent_instances_per_shutdown" && [ "$d" = 2 ]; then ok "T4 three instances in one shutdown = breach (rc=1, instances/shutdown=3, deaths at shutdown=2, windows=$sh)"; else bad "T4 rc=$rc instances/shutdown=$v deaths=$d breaches=$b windows=$sh"; fi
K=$(knob instances); rc=$(analyze "$K" "$T/three" "$T/baseline.json" "$T/jev-expected.py" t4k); b=$(field "$T/t4k.json" "[x['metric'] for x in r['breaches']]")
if printf '%s' "$b" | grep -q "agent_instances_per_shutdown"; then bad "T4 knob 'instances' did not break the check ($b)"; else ok "T4 knob 'instances': the check is SEEN TO FAIL (breaches now $b)"; fi

# T5 an ERROR during a requested stop = breach (knob: stoperr)
rc=$(analyze "$SRC" "$T/stoperr" "$T/baseline.json" "$T/jev-expected.py" t5); v=$(field "$T/t5.json" "r['metrics']['errors_during_requested_stop']"); nz=$(field "$T/t5.json" "r['metrics']['requested_stop_nonzero_exit']"); b=$(field "$T/t5.json" "[x['metric'] for x in r['breaches']]")
if [ "$rc" = 1 ] && [ "$v" = 1 ] && [ "$nz" = 1 ] && printf '%s' "$b" | grep -q "errors_during_requested_stop"; then ok "T5 ERROR during a requested stop = breach (rc=1, errors_during_requested_stop=1, requested_stop_nonzero_exit=1)"; else bad "T5 rc=$rc errors_during_requested_stop=$v nonzero_exit=$nz breaches=$b"; fi
K=$(knob stoperr); rc=$(analyze "$K" "$T/stoperr" "$T/baseline.json" "$T/jev-expected.py" t5k); v=$(field "$T/t5k.json" "r['metrics']['errors_during_requested_stop']")
[ "$v" = 0 ] && ok "T5 knob 'stoperr': the check is SEEN TO FAIL (errors_during_requested_stop=$v)" || bad "T5 knob 'stoperr' did not break the check ($v)"

# T6 a missing log FAILS (knob: missing)
rc=$(analyze "$SRC" "$T/missing" "$T/baseline.json" "$T/jev-expected.py" t6); p=$(field "$T/t6.json" "[x[0] for x in r['data_problems']]")
if [ "$rc" = 3 ] && printf '%s' "$p" | grep -q "missing"; then ok "T6 missing log FAILS (rc=3, problems=$p)"; else bad "T6 missing log: rc=$rc problems=$p"; fi
K=$(knob missing); rc=$(analyze "$K" "$T/missing" "$T/baseline.json" "$T/jev-expected.py" t6k); p=$(field "$T/t6k.json" "[x[0] for x in r['data_problems']]")
if printf '%s' "$p" | grep -q "missing"; then bad "T6 knob 'missing' did not break the check (problems=$p)"; else ok "T6 knob 'missing': the check is SEEN TO FAIL (rc=$rc problems=$p)"; fi

# T7 an empty log FAILS (knob: empty)
rc=$(analyze "$SRC" "$T/empty" "$T/baseline.json" "$T/jev-expected.py" t7); p=$(field "$T/t7.json" "[x[0] for x in r['data_problems']]")
if [ "$rc" = 3 ] && printf '%s' "$p" | grep -q "empty"; then ok "T7 empty log FAILS (rc=3, problems=$p)"; else bad "T7 empty log: rc=$rc problems=$p"; fi
K=$(knob empty); rc=$(analyze "$K" "$T/empty" "$T/baseline.json" "$T/jev-expected.py" t7k); p=$(field "$T/t7k.json" "[x[0] for x in r['data_problems']]")
if printf '%s' "$p" | grep -q "empty"; then bad "T7 knob 'empty' did not break the check (problems=$p)"; else ok "T7 knob 'empty': the check is SEEN TO FAIL (rc=$rc problems=$p)"; fi

# T8 a truncated transfer FAILS at decode (knob: truncated), T9 a complete one passes
rc=$(decode "$SRC" "$T/truncated.pull" "$T/truncated"); rc2=$(decode "$SRC" "$T/cut.pull" "$T/cut")
if [ "$rc" != 0 ] && [ "$rc2" != 0 ]; then ok "T8 truncated transfer FAILS (block with a base64 line missing rc=$rc; stream cut before END rc=$rc2)"; else bad "T8 truncated transfer accepted (rc=$rc / $rc2)"; fi
K=$(knob truncated); rc=$(decode "$K" "$T/truncated.pull" "$T/truncated-k"); rc2=$(decode "$K" "$T/cut.pull" "$T/cut-k")
if [ "$rc" = 0 ] && [ "$rc2" = 0 ]; then ok "T8 knob 'truncated': the check is SEEN TO FAIL (both accepted)"; else bad "T8 knob 'truncated' did not break the check (rc=$rc / $rc2)"; fi
rc=$(decode "$SRC" "$T/base.pull" "$T/base-again"); n=$(grep -c ': OK' "$T/base-again.decode.txt")
[ "$rc" = 0 ] && [ "$n" = 3 ] && ok "T9 complete transfer decodes (rc=0, 3 blocks verified)" || bad "T9 complete transfer rc=$rc blocks=$n"

# T10 jev.py exit 2 = INCOMPLETE, never a pass (knob: jev2)
rc=$(analyze "$SRC" "$T/newsig" "$T/baseline.json" "$T/jev-exit2.py" t10); st=$(field "$T/t10.json" "r['status']")
[ "$rc" = 4 ] && [ "$st" = INCOMPLETE ] && ok "T10 judge exit 2 = INCOMPLETE (rc=4)" || bad "T10 judge exit 2: rc=$rc status=$st"
K=$(knob jev2); rc=$(analyze "$K" "$T/newsig" "$T/baseline.json" "$T/jev-exit2.py" t10k); st=$(field "$T/t10k.json" "r['status']")
[ "$rc" != 4 ] && ok "T10 knob 'jev2': the check is SEEN TO FAIL (rc=$rc status=$st)" || bad "T10 knob 'jev2' did not break the check"
rc=$(analyze "$SRC" "$T/newsig" "$T/baseline.json" "$T/jev-expected.py" t10n --no-jev 2>/dev/null); true
python3 "$SRC" analyze "$T/newsig" --baseline "$T/baseline.json" --out "$T/t10n.json" --label t10n --workdir "$T/work-t10n" --no-jev > "$T/t10n.out" 2>&1; rc=$?
[ "$rc" = 4 ] && ok "T10b --no-jev with items to judge = INCOMPLETE (rc=4)" || bad "T10b --no-jev rc=$rc"

# T11 a Jev 'defect' verdict = FINDINGS (knob: defect)
rc=$(analyze "$SRC" "$T/newsig" "$T/baseline.json" "$T/jev-defect.py" t11); jd=$(field "$T/t11.json" "r['judged_defects']")
[ "$rc" = 1 ] && [ "$jd" != "[]" ] && ok "T11 Jev-classified defect = FINDINGS (rc=1, judged=$jd)" || bad "T11 rc=$rc judged=$jd"
K=$(knob defect); rc=$(analyze "$K" "$T/newsig" "$T/baseline.json" "$T/jev-defect.py" t11k); jdk=$(field "$T/t11k.json" "r['judged_defects']")
# THE CONTROL IS ON THIS METRIC, NOT ON THE RUN'S rc. The newsig fixture carries an undeclared
# ERROR/WARNING line, so signatures_unclassified (max 0, P1) now fails this run whatever the
# judged-defect check does - that is the three-class default acting, and it masks a whole-run rc as
# a control. The knob's own effect is that no defect is judged, so that is what is asserted.
[ "$jdk" = "[]" ] && ok "T11 knob 'defect': the check is SEEN TO FAIL (judged_defects=[] with the knob)" \
                  || bad "T11 knob 'defect' did not break the check (judged=$jdk rc=$rc)"

# ---- fault-injection context (coordinator correction 2026-10-07) --------------------------------------------------
for f in fibanner nofi m8 m8miss heartbeat; do
  rc=$(decode "$SRC" "$T/$f.pull" "$T/$f"); [ "$rc" = 0 ] || { echo "FATAL: the $f fixture did not decode (rc=$rc)"; exit 2; }
done
mkdir -p "$T/m8/markers" "$T/m8miss/markers"; cp "$T/m8-records.txt" "$T/m8/markers/"; cp "$T/m8-records.txt" "$T/m8miss/markers/"
cp -r "$T/nofi" "$T/declared" && cp "$T/context-declared.json" "$T/declared/context.json"
# a baseline that knows the shapes the way the tracked one does: slot-ack shapes expected ONLY under fault injection,
# the heartbeat shape a CLOSED known-defect (built by the REAL baseline-init over the clean fixture's report)
python3 "$SRC" baseline-init "$T/base0.json" --out "$T/baseline-fi.json" \
  --expected-in-fi 'QGABROKER(HUNG|REAP|BACK)=rest-zero M8=expected only under an evidenced injection' \
  --expected-in-fi 'QGABROKERDIED de-slice broker STOPPED SERVING=rest-zero M8=expected only under an evidenced injection' \
  --known-defect 'QGABROKERDIED de-slice broker STOPPED HEARTBEATING=broker-heartbeat-reap (CLOSED 2026-09-27 - a recurrence is a REGRESSION)=fixed 2026-09-27' > /dev/null 2>&1 \
  || { echo "FATAL: baseline-init with context rules failed"; exit 2; }
BLFI="$T/baseline-fi.json"
sev(){ python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(next((b['severity'] for b in r['breaches'] if b['metric']==sys.argv[2]), '-'))" "$1" "$2"; }

# T13 the context comes from the QGAFAULT-INIT evidence, never the file name (knob: ficontext)
rc=$(analyze "$SRC" "$T/fibanner" "$BLFI" "$T/jev-expected.py" t13); ctx=$(field "$T/t13.json" "r['context']['fault_injection']"); bh=$(field "$T/t13.json" "r['metrics']['broker_hangs']"); bd=$(field "$T/t13.json" "r['metrics']['broker_deaths']"); ex=$(field "$T/t13.json" "r['metrics']['broker_events_excused']")
[ "$ctx" = True ] && [ "$bh" = 0 ] && [ "$bd" = 0 ] && [ "$ex" = 2 ] && ok "T13 QGAFAULT-INIT banner -> context fault_injection=true, the hang/death excused (broker_hangs=0 broker_deaths=0 excused=2)" || bad "T13 banner capture: context=$ctx broker_hangs=$bh broker_deaths=$bd excused=$ex rc=$rc"
K=$(knob ficontext); rc=$(analyze "$K" "$T/fibanner" "$BLFI" "$T/jev-expected.py" t13k); ctx=$(field "$T/t13k.json" "r['context']['fault_injection']"); bh=$(field "$T/t13k.json" "r['metrics']['broker_hangs']")
[ "$ctx" = False ] && [ "$bh" = 1 ] && ok "T13 knob 'ficontext' (context from the file name): the check is SEEN TO FAIL (context=$ctx broker_hangs=$bh)" || bad "T13 knob 'ficontext' did not break the check (context=$ctx broker_hangs=$bh)"

# T14 a declared run excuses nothing; declared with no evidence is itself a breach (knob: fideclared)
rc=$(analyze "$SRC" "$T/declared" "$BLFI" "$T/jev-expected.py" t14); d=$(field "$T/t14.json" "r['context']['declared']"); ctx=$(field "$T/t14.json" "r['context']['fault_injection']"); bh=$(field "$T/t14.json" "r['metrics']['broker_hangs']"); up=$(field "$T/t14.json" "r['metrics']['fi_context_unproven']"); b=$(field "$T/t14.json" "[x['metric'] for x in r['breaches']]")
if [ "$d" = True ] && [ "$ctx" = False ] && [ "$bh" = 1 ] && [ "$up" = 1 ] && printf '%s' "$b" | grep -q "fi_context_unproven" && printf '%s' "$b" | grep -q "broker_hangs"; then ok "T14 declared-only run: context stays false, broker_hangs=1 and fi_context_unproven=1 both breach"; else bad "T14 declared=$d context=$ctx broker_hangs=$bh unproven=$up breaches=$b"; fi
K=$(knob fideclared); rc=$(analyze "$K" "$T/declared" "$BLFI" "$T/jev-expected.py" t14k); bh=$(field "$T/t14k.json" "r['metrics']['broker_hangs']")
[ "$bh" = 0 ] && ok "T14 knob 'fideclared' (a declaration excuses): the check is SEEN TO FAIL (broker_hangs=$bh)" || bad "T14 knob 'fideclared' did not break the check (broker_hangs=$bh)"

# T15 outside fault injection a broker hang / death breaches at P1 and the shapes are OUT OF CONTEXT (knob: brokersev)
rc=$(analyze "$SRC" "$T/nofi" "$BLFI" "$T/jev-expected.py" t15); bh=$(field "$T/t15.json" "r['metrics']['broker_hangs']"); bd=$(field "$T/t15.json" "r['metrics']['broker_deaths']"); s1=$(sev "$T/t15.json" broker_hangs); s2=$(sev "$T/t15.json" broker_deaths); ooc=$(field "$T/t15.json" "len(r['out_of_context'])")
[ "$rc" = 1 ] && [ "$bh" = 1 ] && [ "$bd" = 1 ] && [ "$s1" = P1 ] && [ "$s2" = P1 ] && [ "$ooc" -ge 2 ] && ok "T15 plain build: broker_hangs=1 [P1], broker_deaths=1 [P1], $ooc shapes reported out of context" || bad "T15 rc=$rc hangs=$bh deaths=$bd sev=$s1/$s2 out_of_context=$ooc"
K=$(knob brokersev); rc=$(analyze "$K" "$T/nofi" "$BLFI" "$T/jev-expected.py" t15k); s1=$(sev "$T/t15k.json" broker_hangs); s2=$(sev "$T/t15k.json" broker_deaths)
[ "$s1" = - ] && [ "$s2" = - ] && ok "T15 knob 'brokersev': the check is SEEN TO FAIL (no broker breach)" || bad "T15 knob 'brokersev' did not break the check ($s1/$s2)"

# T16 M8: the record joins the hang (excused, detection OK); without the detection line the injection is a silent failure (knob: fidetect)
rc=$(analyze "$SRC" "$T/m8" "$BLFI" "$T/jev-expected.py" t16); ctx=$(field "$T/t16.json" "r['context']['fault_injection']"); bh=$(field "$T/t16.json" "r['metrics']['broker_hangs']"); fm=$(field "$T/t16.json" "r['metrics']['fi_detection_missing']"); chk=$(field "$T/t16.json" "r['context']['records'][0]['checks']")
[ "$ctx" = True ] && [ "$bh" = 0 ] && [ "$fm" = 0 ] && printf '%s' "$chk" | grep -q "^\['OK" && ok "T16 M8 record joins the hang by pid+time: excused, detection OK ($chk)" || bad "T16 m8: context=$ctx broker_hangs=$bh missing=$fm checks=$chk"
rc=$(analyze "$SRC" "$T/m8miss" "$BLFI" "$T/jev-expected.py" t16m); fm=$(field "$T/t16m.json" "r['metrics']['fi_detection_missing']"); s=$(sev "$T/t16m.json" fi_detection_missing)
[ "$rc" = 1 ] && [ "$fm" = 1 ] && [ "$s" = P1 ] && ok "T16 M8 with the detection line absent: fi_detection_missing=1 [P1]" || bad "T16 m8miss: rc=$rc missing=$fm sev=$s"
K=$(knob fidetect); rc=$(analyze "$K" "$T/m8miss" "$BLFI" "$T/jev-expected.py" t16k); fm=$(field "$T/t16k.json" "r['metrics']['fi_detection_missing']")
[ "$fm" = 0 ] && ok "T16 knob 'fidetect': the check is SEEN TO FAIL (missing=$fm)" || bad "T16 knob 'fidetect' did not break the check ($fm)"

# T17 the tracked baseline carries the required issue references; a baseline that lost them is refused (knob: issuerefs)
TB="$ROOT/mgmt/harness/log-sweep-baseline.json"
if [ -f "$TB" ]; then
  out=$(python3 "$SRC" baseline-audit "$TB" 2>&1); rc=$?
  [ "$rc" = 0 ] && ok "T17 tracked baseline audit: $(printf '%s' "$out" | head -1 | cut -c1-120)" || bad "T17 tracked baseline audit failed: $(printf '%s' "$out" | head -3 | tr '\n' ' ' | cut -c1-300)"
  python3 - "$TB" "$T/baseline-stripped.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
for k, v in list(b.get("signatures", {}).items()) + list(enumerate(b.get("patterns", []))):
    v.pop("issue", None); v.pop("context", None)
json.dump(b, open(sys.argv[2], "w"))
PY
  out=$(python3 "$SRC" baseline-audit "$T/baseline-stripped.json" 2>&1); rc=$?
  [ "$rc" != 0 ] && ok "T17 a baseline stripped of its issue refs is refused ($(printf '%s' "$out" | head -1 | cut -c1-100))" || bad "T17 stripped baseline accepted"
  K=$(knob issuerefs); out=$(python3 "$K" baseline-audit "$T/baseline-stripped.json" 2>&1); rc=$?
  [ "$rc" = 0 ] && ok "T17 knob 'issuerefs': the check is SEEN TO FAIL (stripped baseline accepted)" || bad "T17 knob 'issuerefs' did not break the check (rc=$rc)"
else
  bad "T17 tracked baseline $TB is missing"
fi

# T18 the CLOSED heartbeat defect recurring is a P1 breach (knob: closedrec)
rc=$(analyze "$SRC" "$T/heartbeat" "$BLFI" "$T/jev-expected.py" t18); cr=$(field "$T/t18.json" "r['metrics']['closed_defect_recurrence']"); s=$(sev "$T/t18.json" closed_defect_recurrence); kd=$(field "$T/t18.json" "[x['baseline'].get('issue','')[:40] for x in r['known_defects_present']]")
[ "$rc" = 1 ] && [ "$cr" = 1 ] && [ "$s" = P1 ] && printf '%s' "$kd" | grep -q "CLOSED 2026-09-27" && ok "T18 heartbeat shape recurring: closed_defect_recurrence=1 [P1], known-defect present with the CLOSED issue" || bad "T18 rc=$rc recurrence=$cr sev=$s known=$kd"
K=$(knob closedrec); rc=$(analyze "$K" "$T/heartbeat" "$BLFI" "$T/jev-expected.py" t18k); cr=$(field "$T/t18k.json" "r['metrics']['closed_defect_recurrence']")
[ "$cr" = 0 ] && ok "T18 knob 'closedrec': the check is SEEN TO FAIL (recurrence=$cr)" || bad "T18 knob 'closedrec' did not break the check ($cr)"

# ---- T19-T23: THE GRADER'S OWN DEFECTS, every one of them found by the lifecycle retest on 2026-10-07 ------------
# Each of these made the grader file a defect against the PRODUCT that the guest's logs did not support. A grader is
# an instrument: it gets the same treatment as the code it judges.
analyze_since(){ # $1=analyzer $2=logsdir $3=baseline $4=judge $5=tag $6=since -> rc
  python3 "$1" analyze "$2" --baseline "$3" --out "$T/$5.json" --summary "$T/$5.txt" --label "$5" --workdir "$T/work-$5" --jev-cmd "$4" --since "$6" > "$T/$5.out" 2>&1; echo $?
}

# T19 two boots 100 s apart are TWO boots, one agent each (knob: boottol - the old 150 s clustering merged them)
rc=$(analyze "$SRC" "$T/twoboot" "$T/baseline.json" "$T/jev-expected.py" t19)
nb=$(field "$T/t19.json" "r['metrics']['boots']"); pb=$(field "$T/t19.json" "r['metrics']['agent_instances_per_boot']")
if [ "$nb" -ge 2 ] && [ "$pb" = 1 ]; then ok "T19 two boots 100 s apart are $nb boots with 1 agent each (the ordinary shape on this rig)"
else bad "T19 boots=$nb instances/boot=$pb (want >=2 and 1)"; fi
K=$(knob boottol); rc=$(analyze "$K" "$T/twoboot" "$T/baseline.json" "$T/jev-expected.py" t19k)
pbk=$(field "$T/t19k.json" "r['metrics']['agent_instances_per_boot']")
[ "$pbk" -gt 1 ] && ok "T19 knob 'boottol': the check is SEEN TO FAIL - the two boots merge and one boot reads $pbk agents"                  || bad "T19 knob 'boottol' did not break the check (instances/boot=$pbk)"

# T20 a shutdown window never swallows the next boot's agent (knob: winclamp)
sw=$(field "$T/t19.json" "r['metrics']['agent_instances_per_shutdown']"); rl=$(field "$T/t19.json" "r['metrics']['agent_relaunches_at_shutdown']")
if [ "$sw" -le 1 ] && [ "$rl" = 0 ]; then ok "T20 a window ends at the next boot: instances/shutdown=$sw relaunches=$rl"
else bad "T20 instances/shutdown=$sw relaunches=$rl (want <=1 and 0)"; fi
K=$(knob winclamp); rc=$(analyze "$K" "$T/twoboot" "$T/baseline.json" "$T/jev-expected.py" t20k)
swk=$(field "$T/t20k.json" "r['metrics']['agent_instances_per_shutdown']")
[ "$swk" -gt 1 ] && ok "T20 knob 'winclamp': the check is SEEN TO FAIL - an unclamped window reads $swk agents per shutdown"                  || bad "T20 knob 'winclamp' did not break the check (instances/shutdown=$swk)"

# T21 --since re-windows the PER-WINDOW metrics too (knob: winsince - they used to count the whole capture)
rc=$(analyze_since "$SRC" "$T/twoboot" "$T/baseline.json" "$T/jev-expected.py" t21 "2026-10-07 10:02:00")
sh=$(field "$T/t21.json" "r['metrics']['shutdowns_in_window']")
[ "$sh" = 1 ] && ok "T21 --since re-windows the per-window metrics (shutdowns_in_window=1 of 2)" || bad "T21 shutdowns_in_window=$sh (want 1)"
K=$(knob winsince); rc=$(analyze_since "$K" "$T/twoboot" "$T/baseline.json" "$T/jev-expected.py" t21k "2026-10-07 10:02:00")
shk=$(field "$T/t21k.json" "r['metrics']['shutdowns_in_window']")
[ "$shk" != 1 ] && ok "T21 knob 'winsince': the check is SEEN TO FAIL - the window is ignored and $shk shutdown(s) counted"                 || bad "T21 knob 'winsince' did not break the check (shutdowns_in_window=$shk)"

# T22 a dropped log is NAMED, and a dropped VERDICT log is a louder problem than a dropped chatty one
rc=$(analyze "$SRC" "$T/skipnames" "$T/baseline.json" "$T/jev-expected.py" t22)
pv=$(field "$T/t22.json" "[p[0] for p in r['data_problems']]")
rc2=$(analyze "$SRC" "$T/skipchatty" "$T/baseline.json" "$T/jev-expected.py" t22b)
pc=$(field "$T/t22b.json" "[p[0] for p in r['data_problems']]")
if printf '%s' "$pv" | grep -q "skipped-verdict" && ! printf '%s' "$pc" | grep -q "skipped-verdict"; then
  ok "T22 a dropped agent log is called out (skipped-verdict); dropped chatty logs are not ($pv vs $pc)"
else bad "T22 verdict=$pv chatty=$pc (want skipped-verdict only in the first)"; fi

# T29 THE LOG DIRECTORY'S OWN VOLUME IS REPORTED, and its absence is reported as absence.
# Jev named this the one unmeasured fact that would most change the logging decision
# (missing_measurement = total-line-volume-per-boot, confidence 1.00), and nothing reported it - so
# "386 files, 368 of them one module's" was counted by hand once and was gone by the next run.
rc=$(analyze "$SRC" "$T/inv" "$T/baseline.json" "$T/jev-expected.py" t29)
ifiles=$(field "$T/t29.json" "r['header']['inventory']['files']")
ilines=$(field "$T/t29.json" "r['header']['inventory']['lines']")
imods=$(field "$T/t29.json" "len(r['header']['invmodules'])")
if [ "$ifiles" = 386 ] && [ "$ilines" = 41000 ] && [ "$imods" = 3 ]; then
  ok "T29 the inventory reaches the report intact (386 files, 41000 lines, 3 modules)"
else bad "T29 inventory files=$ifiles lines=$ilines modules=$imods (want 386/41000/3)"; fi
if grep -q 'LOGDIR INVENTORY: 386 files, 41000 lines' "$T/t29.txt" && grep -qE 'qrexec-wrapper +368 file' "$T/t29.txt"; then
  ok "T29 the summary NAMES the volume and the module responsible for it"
else bad "T29 the summary does not report the volume: $(grep -a 'INVENTORY' "$T/t29.txt" | head -1)"; fi
# an UNREADABLE file must be reported as missing, never counted as empty
if grep -q 'UNREADABLE - counted as missing, never as empty' "$T/t29.txt"; then
  ok "T29 an unreadable log is reported as missing data, not as zero lines"
else bad "T29 the unreadable file in the fixture is not called out"; fi
# SEEN TO FAIL: a stream with no inventory must say the volume is NOT KNOWN, not imply zero
rc=$(analyze "$SRC" "$T/base" "$T/baseline.json" "$T/jev-expected.py" t29k)
if grep -q 'LOGDIR INVENTORY: absent' "$T/t29k.txt" && grep -q 'NOT KNOWN' "$T/t29k.txt"; then
  ok "T29 knob 'no inventory': the check is SEEN TO FAIL - the volume is reported as NOT KNOWN"
else bad "T29 knob: a stream without an inventory does not say the volume is unknown"; fi

# T30 AN AGENT INSTANCE IS A PROCESS, NOT A FILE. The log is one file per module per day now, so a
# file holds every process that ran that day. Reading a file as an instance collapsed them into one
# instance spanning the whole day, which zeroed agent_instances_per_shutdown - the metric the
# three-instances-per-shutdown defect is measured by - and, with --since, dropped the day-spanning
# instance entirely so agent_instances_per_boot read 0 and "nothing ran" looked like a clean run.
rc=$(analyze "$SRC" "$T/twoproc" "$T/baseline.json" "$T/jev-expected.py" t30)
ni=$(field "$T/t30.json" "r['metrics']['agent_instances']")
pids=$(field "$T/t30.json" "sorted(i['pid'] for w in r['structure']['windows'] for i in w['instances']) if r.get('structure') else []")
if [ "$ni" = 2 ]; then
  ok "T30 two processes in ONE file are two instances (agent_instances=$ni)"
else bad "T30 agent_instances=$ni for one file holding two processes (want 2)"; fi
# the per-process facts must not be the whole file's: each instance announced ONCE, so a per-instance
# sum over the shared file would read 2 and breach vchan_reconnects on an ordinary day
vr=$(field "$T/t30.json" "r['metrics']['vchan_reconnects']")
if [ "$vr" = 0 ]; then
  ok "T30 per-instance counts are that process's own (vchan_reconnects=0, not a false breach)"
else bad "T30 vchan_reconnects=$vr - the per-instance sums are counting the whole shared file"; fi
# SEEN TO FAIL: with the per-file keying restored, the same corpus must read ONE instance
K=$(knob perfileinst); rc=$(analyze "$K" "$T/twoproc" "$T/baseline.json" "$T/jev-expected.py" t30k)
nik=$(field "$T/t30k.json" "r['metrics']['agent_instances']")
if [ "$nik" = 1 ]; then
  ok "T30 knob 'perfileinst': the check is SEEN TO FAIL - keying on the file reads $nik instance for two processes"
else bad "T30 knob 'perfileinst' did not collapse the instances (agent_instances=$nik, want 1)"; fi

# T31 THE MSI CLASSIFIER, BOTH WAYS. A routine install's rollback SCHEDULING is neither an error nor
# a warning, and a real failure is still an error. Measured on a verified-successful 4.3.36 upgrade:
# 171 error lines, of which 168 were the routine scheduling - so the gate was reporting a clean
# install as 171 errors.
# THIS LEG USED TO REQUIRE `wok >= 7`, AND THAT WAS THE HALF-FIX. The 2026-10-08 change only split
# the LEVEL, so the routine lines stayed SELECTED and became warnings; pinning >= 7 pinned that.
# It cost a cell on 2026-10-23: signatures_unclassified began gating ERROR *and WARNING* at P1, and
# win10-clean of acceptance run 40006931995 failed with 13 unclassified signatures, TEN of them this
# bookkeeping (`Note: 1: 2 2: <path>`, `RollbackInfo(...)`, and CustomActionSchedule/PROPERTY CHANGE
# lines naming WiX's own Wix4RollbackAddMachineCertificate_X64). MSI_SUSPECT_RE no longer SELECTS
# them, so a clean install contributes neither errors nor warnings - which is what the expectation
# below now says. Re-graded on that real capture: unclassified 13 -> 0, warning_lines 324 -> 93,
# error_lines UNCHANGED at 1. Jev: narrowing sound 0.90, a real rollback still caught 0.88.
rc=$(analyze "$SRC" "$T/msiok" "$T/baseline.json" "$T/jev-expected.py" t31)
eok=$(field "$T/t31.json" "r['metrics']['error_lines']")
wok=$(field "$T/t31.json" "r['metrics']['warning_lines']")
if [ "$eok" = 0 ] && [ "$wok" = 0 ]; then
  ok "T31 a successful install's rollback scheduling is neither an error nor a warning (errors=$eok, warnings=$wok)"
else bad "T31 a successful install produced $eok error line(s) and $wok warning(s) (want 0 and 0)"; fi
# SEEN TO FAIL: a real failure must still be errors
rc=$(analyze "$SRC" "$T/msibad" "$T/baseline.json" "$T/jev-expected.py" t31b)
ebad=$(field "$T/t31b.json" "r['metrics']['error_lines']")
if [ "$ebad" -ge 3 ]; then
  ok "T31 a FAILED install is still errors (errors=$ebad: Return value 3, Installation failed, MainEngineThread returning 1603)"
else bad "T31 a failed install produced only $ebad error line(s) - the classifier has gone blind"; fi

# T32 A --since WINDOW IS ONLY AS GOOD AS THE GUEST'S CLOCK. Measured 2026-10-08 on win11r-logvol:
# the collector reported tz=+00:00 with now=nowutc=09:50:36 while this host's UTC was 06:50, so the
# guest believed UTC was three hours later than it was. Every line looked newer than the window, and
# a quiet boot's sweep silently admitted two shutdown errors from earlier runs. The direction of the
# error is what makes it dangerous: a clean run reads dirty, and a declared fault-injection window
# covers lines it never caused.
python3 - "$T" <<'PYX'
import json, os, sys
T = sys.argv[1]
src = os.path.join(T, "base", "meta.json")
dst = os.path.join(T, "skew")
os.makedirs(dst, exist_ok=True)
for n in os.listdir(os.path.join(T, "base")):
    s, d = os.path.join(T, "base", n), os.path.join(dst, n)
    if os.path.isdir(s):
        import shutil
        shutil.rmtree(d, ignore_errors=True); shutil.copytree(s, d)
    else:
        import shutil; shutil.copy2(s, d)
m = json.load(open(os.path.join(dst, "meta.json")))
# the guest's own clock, three hours ahead of this host's, and it believes it is UTC
import datetime as dt
ahead = (dt.datetime.utcnow() + dt.timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]
m.setdefault("begin", {})["nowutc"] = ahead + "Z"
m["begin"]["now"] = ahead
m["begin"]["tz"] = "+00:00"
json.dump(m, open(os.path.join(dst, "meta.json"), "w"))
print("skew fixture written")
PYX
# Called directly, because the skew check needs the SECOND clock: --host-utc, which the helper does
# not pass. The fixture's guest clock is three hours ahead of the host value given here.
python3 "$SRC" analyze "$T/skew" --baseline "$T/baseline.json" --out "$T/t32.json" \
  --summary "$T/t32.txt" --label t32 --workdir "$T/work-t32" --jev-cmd "$T/jev-expected.py" \
  --since "2026-10-07 10:00:00" --host-utc "$(date -u +%Y-%m-%dT%H:%M:%S)" > "$T/t32.out" 2>&1
pk=$(field "$T/t32.json" "[p[0] for p in r['data_problems']]")
if printf '%s' "$pk" | grep -q clockskew; then
  ok "T32 a guest clock 3 h from the host is a DATA problem, not absorbed ($pk)"
else bad "T32 a 3 h guest clock skew was absorbed silently: data_problems=$pk"; fi
# SEEN TO FAIL the other way: the unskewed fixture must NOT report it
# the in-sync case: the fixture's own recorded clock, given as the host's, so they agree
base_nowutc=$(python3 -c "import json,sys;print((json.load(open(sys.argv[1])).get('begin') or {}).get('nowutc','').rstrip('Z'))" "$T/base/meta.json")
python3 "$SRC" analyze "$T/base" --baseline "$T/baseline.json" --out "$T/t32b.json" \
  --summary "$T/t32b.txt" --label t32b --workdir "$T/work-t32b" --jev-cmd "$T/jev-expected.py" \
  --since "2026-10-07 10:00:00" --host-utc "$base_nowutc" > "$T/t32b.out" 2>&1
pb=$(field "$T/t32b.json" "[p[0] for p in r['data_problems']]")
if ! printf '%s' "$pb" | grep -q clockskew; then
  ok "T32 an in-sync guest does NOT report a skew (no false positive)"
else bad "T32 the unskewed fixture reports a clock skew: $pb"; fi

# T33 SEVERITY COMES FROM THE WRITER'S DECLARED LEVEL, AND FROM NOTHING ELSE. This used to test a
# vocabulary: that "failed=0" was not an error (a success record's own accounting), that "failed=3"
# was, that "absent" in a line whose conclusion is "nothing to apply" was not a warning. Every one
# of those cases existed because the vocabulary had been WRONG about it, and the exceptions needed
# their own exceptions - "errors=12" read as routine because \berror\b does not match the plural.
# The vocabulary is deleted. The writers declare (qtb_shared.h BLog/BLogW/BLogE,
# pvnic-selfprime.ps1 L/LW/LE), so a declared tag decides and an UNDECLARED line is not guessed at
# all - it returns None and is recorded, because an unjudgeable line is a gap to close at the
# writer. Owner: "severity is wired on logger side and evaluated by sweeper irregardless of
# message text", and "if you drop the vocabulary and fucking guesswork? it is abomination".
python3 - "$SRC" <<'PYZ' > /tmp/zc.$$ 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# DECLARED: the tag decides, including where the old vocabulary got it backwards.
declared = {
    "[INFO] failed=0":                                        "I",
    "[ERROR] errors=12":                                      "E",   # plural the vocabulary missed
    "[ERROR] FAILED: xenbus_monitor SURVIVED enforcement":    "E",   # ALL-CAPS it could not see
    "[INFO] /qubes-ip absent, no vif device: nothing to apply":"I",   # "absent" is not a warning
    "[WARN] LIST trig=retry n=3":                             "W",
    "[WARN] the listener was disconnected":                   "W",
    "[FATAL] the ring could not be opened":                   "E",
}
# UNDECLARED: never guessed, whatever words it contains.
undeclared = ["failed=3", "apply FAILED, nothing to do", "status=failed",
              "the listener was disconnected", "/qubes-ip absent, the applier gave up"]
bad = ["%s -> %s (want %s)" % (k, m.blog_level(k), v) for k, v in declared.items() if m.blog_level(k) != v]
bad += ["%s -> %s (want None: undeclared must not be guessed)" % (k, m.blog_level(k))
        for k in undeclared if m.blog_level(k) is not None]
if len(m.BLOG_UNDECLARED) != len(undeclared):
    bad.append("recorded %d undeclared, expected %d" % (len(m.BLOG_UNDECLARED), len(undeclared)))
print("OK" if not bad else "BAD " + "; ".join(bad))
PYZ
zc=$(cat /tmp/zc.$$); rm -f /tmp/zc.$$
case "$zc" in
  OK*) ok "T33 a declared tag decides the level; an undeclared line is recorded, never guessed" ;;
  *)   bad "T33 $zc" ;;
esac

# T23 a filter on a key that does not exist must not silently zero a metric (knob: winkey - the defect I shipped
# for ten minutes while fixing T21, caught only because shutdowns_in_window=0 contradicted shutdowns=5)
pb2=$(field "$T/t21.json" "r['metrics']['agent_instances_per_boot']")
[ "$pb2" -ge 1 ] && ok "T23 a windowed re-grade still counts instances (instances/boot=$pb2, not 0)" || bad "T23 instances/boot=$pb2 - the window zeroed it"
K=$(knob winkey); rc=$(analyze_since "$K" "$T/twoboot" "$T/baseline.json" "$T/jev-expected.py" t23k "2026-10-07 10:02:00")
pbk2=$(field "$T/t23k.json" "r['metrics']['agent_instances_per_boot']")
[ "$pbk2" = 0 ] && ok "T23 knob 'winkey': the check is SEEN TO FAIL - filtering on a missing key reads 0 instances"                || bad "T23 knob 'winkey' did not break the check (instances/boot=$pbk2)"

# ---- T24-T25: a crash is not a verdict, and a boot key of either type must not kill the analyzer ---------------
# Both measured on the toast run of 2026-10-07: the analyzer died on mixed int/str boot keys ("'<' not supported
# between instances of 'int' and 'str'"), python exited 1, and the rig wrapper announced "rc=1 status=FINDINGS" for a
# run that had produced NO REPORT AT ALL - a graded verdict over nothing.
rc=$(analyze "$SRC" "$T/twoboot" "$T/baseline.json" "$T/jev-expected.py" t24)
pb=$(field "$T/t24.json" "list(r['new'][0]['per_boot'].keys()) if r['new'] else ['-']")
if [ -f "$T/t24.json" ]; then ok "T24 a capture with attributed and unattributed boots still produces a report (per_boot keys $pb)"
else bad "T24 the analyzer produced no report"; fi
K=$(knob bootkeysort); rc=$(analyze "$K" "$T/twoboot" "$T/baseline.json" "$T/jev-expected.py" t24k)
if [ ! -f "$T/t24k.json" ] || [ "$rc" = 2 ]; then ok "T24 knob 'bootkeysort': the check is SEEN TO FAIL - the analyzer dies and writes no report (rc=$rc)"
else bad "T24 knob 'bootkeysort' did not break the check (rc=$rc, report present)"; fi

# T25 the rig wrapper must refuse a verdict when there is no readable report (it is a shell check, so it is driven
# directly: a bad report file with the analyzer's own exit code 1 must come back INCOMPLETE, not FINDINGS)
WRAP="$ROOT/mgmt/harness/log-sweep.sh"
if grep -q "GUARD:reportparses" "$WRAP"; then
  mkdir -p "$T/wrap"; printf 'not json at all\n' > "$T/wrap/report.json"
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$T/wrap/report.json" >/dev/null 2>&1; then
    bad "T25 the fixture report parsed - the case cannot be driven"
  else ok "T25 the wrapper's guard exists and an unreadable report is detectably unreadable (INCOMPLETE, not FINDINGS)"; fi
else bad "T25 mgmt/harness/log-sweep.sh has no GUARD:reportparses - a crash would still read as FINDINGS"; fi

# T26/T27 A LAUNCH IS NOT YET A RELAUNCH. bootshut is a boot whose agent launch lands 1 s before the
# shutdown marker: nothing of ours has ENDED before it, so it must not count. three is the real defect shape
# (the agent dies at a shutdown and the watchdog starts another), where it must count - otherwise the fix
# would have silenced the metric rather than corrected it.
rc=$(analyze "$SRC" "$T/bootshut" "$T/baseline.json" "$T/jev-expected.py" t26)
rl=$(field "$T/t26.json" "r['metrics']['agent_relaunches_at_shutdown']")
b=$(field "$T/t26.json" "[x['metric'] for x in r['breaches']]")
if [ "$rl" = 0 ] && ! printf '%s' "$b" | grep -q 'agent_relaunches_at_shutdown'; then
  ok "T26 the boot's own launch 1 s before a shutdown is not a relaunch (relaunches=$rl, no breach)"
else bad "T26 bootshut: relaunches=$rl breaches=$b - the boot's own launch was counted as a relaunch into the ending session"; fi
K=$(knob relaunchneedsend); rc=$(analyze "$K" "$T/bootshut" "$T/baseline.json" "$T/jev-expected.py" t26k)
rlk=$(field "$T/t26k.json" "r['metrics']['agent_relaunches_at_shutdown']")
# MISSING DATA FAILS: an empty reading here used to pass this check, because knob() exits inside a subshell
# when its marker is unusable and "" != 0 is true in test(1). The reading must be a NUMBER, and >= 1.
if printf '%s' "$rlk" | grep -qE '^[0-9]+$' && [ "$rlk" -ge 1 ]; then
  ok "T26 knob relaunchneedsend: without the preceding-end rule the boot launch IS miscounted (relaunches=$rlk)"
else bad "T26 knob relaunchneedsend: the defect copy reported '$rlk' (want a number >= 1) - the check proves nothing"; fi
rc=$(analyze "$SRC" "$T/three" "$T/baseline.json" "$T/jev-expected.py" t27)
rl3=$(field "$T/t27.json" "r['metrics']['agent_relaunches_at_shutdown']")
if [ "$rl3" -ge 1 ]; then ok "T27 the real shape still counts: a death at a shutdown followed by a launch = $rl3 relaunch(es)"
else bad "T27 the 2026-10-07 defect shape now reports $rl3 relaunches - the fix silenced the metric instead of correcting it"; fi

# T28 THE GATE CONDITION: an error line the run did not declare is a breach; a declared one is not; and a
# declaration that matches nothing is a breach of its own (the stimulus it names did not happen).
cp -r "$T/newsig" "$T/undeclared" && rm -f "$T/undeclared/context.json"
rc=$(analyze "$SRC" "$T/undeclared" "$T/baseline.json" "$T/jev-expected.py" t28u)
u=$(field "$T/t28u.json" "r['metrics']['error_lines_undeclared']"); b=$(field "$T/t28u.json" "[x['metric'] for x in r['breaches']]")
if [ "$u" -ge 1 ] && printf '%s' "$b" | grep -q 'error_lines_undeclared'; then
  ok "T28 an UNDECLARED error line breaches the gate (undeclared=$u)"
else bad "T28 undeclared=$u breaches=$b - an error line nobody declared did not fail the gate"; fi
rc=$(analyze "$SRC" "$T/newsig" "$T/baseline.json" "$T/jev-expected.py" t28d)
d=$(field "$T/t28d.json" "r['metrics']['error_lines_undeclared']"); bd=$(field "$T/t28d.json" "[x['metric'] for x in r['breaches']]")
if [ "$d" = 0 ] && ! printf '%s' "$bd" | grep -q 'error_lines_undeclared'; then
  ok "T28 a DECLARED error line does not breach it (the stimulus the run caused)"
else bad "T28 declared run: undeclared=$d breaches=$bd"; fi
cp -r "$T/base" "$T/stale" && printf '{"source":"t28","declared_errors":[{"pattern":"ThisErrorNeverHappens0xDEAD","why":"a stimulus that was not applied"}]}\n' > "$T/stale/context.json"
rc=$(analyze "$SRC" "$T/stale" "$T/baseline.json" "$T/jev-expected.py" t28s)
sm=$(field "$T/t28s.json" "r['metrics']['declared_errors_unmatched']"); bs=$(field "$T/t28s.json" "[x['metric'] for x in r['breaches']]")
if [ "$sm" -ge 1 ] && printf '%s' "$bs" | grep -q 'declared_errors_unmatched'; then
  ok "T28 a declaration that matches NOTHING breaches too - the run proved less than it claims"
else bad "T28 stale declaration: unmatched=$sm breaches=$bs"; fi

# the collector must parse (the Linux pwsh is the same parser Windows PowerShell uses) when pwsh is present
PWSH="$("$(dirname "$0")/pwsh-path.sh" || true)"
if [ -x "$PWSH" ]; then
  if "$PWSH" -NoProfile -File "$ROOT/tools/ps-parse-check.ps1" "$ROOT/mgmt/harness/log-sweep-collect.ps1" > "$T/parse.txt" 2>&1; then ok "T12 collector parses ($(tail -1 "$T/parse.txt" | cut -c1-100))"; else bad "T12 collector parse: $(tail -3 "$T/parse.txt" | tr '\n' ' ')"; fi
else
  echo "skip  T12 collector parse-check: no pwsh at $PWSH"
fi

# ---- T34 THE VOCABULARY MUST NOT COME BACK -----------------------------------------------------
# This block used to test a 188-term error/warning vocabulary "in BOTH directions". It is deleted,
# and these are the exact lines it used to grade - every one a real log line, and every one a case
# the vocabulary had been WRONG about at least once. None of them may receive a severity now,
# whatever words they contain: the writer declares, or the line is unjudgeable and reported as such.
# This is a regression guard, not a behaviour test - if any of these starts returning a level
# again, a vocabulary has been reintroduced somewhere.
python3 - "$SRC" <<'PYV' > /tmp/t34.$$ 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
was_graded = [
    "FAILED: xenbus_monitor SURVIVED enforcement",
    "no netvm, nothing to apply - but an earlier step FAILED (the latch)",
    "status=failed",
    "apply FAILED, nothing to do",
    "qubesdb up, /qubes-ip absent, no vif device: no netvm, nothing to apply",
    "LIST trig=retry n=3 new=0 ms=12",
    "/qubes-ip absent, the applier gave up",
    "the listener was disconnected",
    "failed=0", "errors=12", "crash in the decode loop", "schema mismatch",
]
guessed = [(l, m.blog_level(l)) for l in was_graded if m.blog_level(l) is not None]
print("OK" if not guessed else "BAD a vocabulary graded: " +
      "; ".join("%s -> %s" % (l[:40], v) for l, v in guessed))
PYV
t34=$(cat /tmp/t34.$$); rm -f /tmp/t34.$$
case "$t34" in
  OK*) ok "T34 none of the 12 lines the deleted vocabulary used to grade receives a severity now" ;;
  *)   bad "T34 $t34" ;;
esac

# ---- T35 a launch the system refused because it was SHUTTING DOWN is not a task failure ------
# MEASURED on win11r-err 2026-10-08, on a CLEAN cycle: id=203, task \QwtDeathReporter, "Error
# Value: 2147943515" = 0x8007045B = ERROR_SHUTDOWN_IN_PROGRESS - the scheduler saying the action
# never started because the machine was going down. guest/qwt-report-death.ps1 already accepts that
# code on its own; this event-level count did not, so a shutdown doing exactly the right thing
# contributed an undeclared error line. A REAL launch failure must still count, which is checked.
t35(){ # $1=eid $2=message $3=expected(True|False) $4=label
  got=$(python3 - "$ROOT/tools/log-sweep.py" "$1" "$2" <<'PY35'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("ls", sys.argv[1])
ls = importlib.util.module_from_spec(spec); spec.loader.exec_module(ls)
print(ls.event_wanted("Microsoft-Windows-TaskScheduler/Operational", int(sys.argv[2]),
                      "Microsoft-Windows-TaskScheduler", sys.argv[3]))
PY35
)
  if [ "$got" = "$3" ]; then ok "T35 $4"; else bad "T35 $4 -> $got (want $3)"; fi
}
t35 203 'Task Scheduler failed to launch action "powershell.exe" in instance "{x}" of task "\QwtDeathReporter". Additional Data: Error Value: 2147943515.' False 'a 203 refused for shutdown is not a failure'
t35 203 'Task Scheduler failed to launch action "powershell.exe" in instance "{x}" of task "\QwtDeathReporter". Additional Data: Error Value: 2.' True 'a REAL 203 launch failure still counts'
t35 201 'Task Scheduler successfully completed task "\QubesPvNic" , action "powershell.exe" with return code 1' True 'a 201 with a non-zero result still counts'
t35 203 'Task Scheduler failed to launch action in task "\NotOurs". Additional Data: Error Value: 2.' False 'a task that is not ours is not ours'

# ---- VOCABULARY DRIFT: the gate must know every word the producer can say ----------------------
# THE DEFECT THIS EXISTS FOR, measured 2026-10-08. agent/watchdog/watchdog.c:498 writes
#   QGAWDDEATH '<image>' (PID N) exited with code 0xH without this service asking it to
# while DEATH_RE matched only the older "Process '<image>' (PID N) ..." form, and the call site was
# gated on l.func == "WatchdogThread" while HEAD logs the decision from JudgeAgentExit. Two P1
# metrics with max 0 - agent_unrequested_deaths and agent_deaths_at_shutdown - were therefore
# STRUCTURALLY ZERO on any build carrying the rename, and a run that printed two QGAWDDEATH lines
# reported zero deaths. Nothing failed: the producer learned a word the gate did not know.
#
# Patching the regexes fixes today; THIS stops tomorrow. Every QGAWD* tag watchdog.c can log must be
# either matched by DEATH_RE or listed in WATCHDOG_NOT_A_DEATH_TAGS, so a new or reworded tag fails
# here at commit instead of silently pinning a metric to zero. It found two tags missing from the
# first draft of that list (QGAWDSESSIONCONTINUES, QGAWDTRIGGER).
drift=$(python3 - "$SRC" "$ROOT/agent/watchdog/watchdog.c" <<'PYF'
import io, re, sys
sweep = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
try:
    wc = io.open(sys.argv[2], encoding='utf-8', errors='replace').read()
except OSError:
    print("SKIP watchdog.c not readable from here"); raise SystemExit
produced = set(re.findall(r'"(QGAWD[A-Z-]+)', wc))
if not produced:
    print("FAIL no QGAWD tags found in watchdog.c - the reconciliation has nothing to check"); raise SystemExit
listed = set(re.findall(r'"(QGAWD[A-Z-]+)"', sweep))
unclassified = sorted(t for t in produced if t != "QGAWDDEATH" and t not in listed)
stale = sorted(t for t in listed if t not in produced and t != "QGAWDDEATH")
if unclassified: print("FAIL unclassified tag(s) the gate does not know: " + ", ".join(unclassified))
elif stale:      print("WARN listed but no longer produced: " + ", ".join(stale))
else:            print("OK %d tags all classified" % len(produced))
PYF
)
case "$drift" in
  OK*|SKIP*|WARN*) ok "drift: $drift" ;;
  *)               bad "drift: $drift" ;;
esac

# THE DEATH METRIC MUST SEE BOTH WORDINGS, checked against the REGEX itself rather than a fixture -
# a fixture written to fit the regex is how these checks became decoration in the first place.
wording=$(python3 - "$SRC" <<'PYF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", sys.argv[1]); m = importlib.util.module_from_spec(spec)
sys.modules["ls"] = m
try: spec.loader.exec_module(m)
except SystemExit: pass
head = "QGAWDDEATH 'gui-agent.exe' (PID 7360) exited with code 0x40010004 without this service asking it to - the agent DIED"
old  = "Process 'gui-agent.exe' (PID 5320) exited with code 0x40010004 without this service asking it to - the agent DIED"
notd = "QGAWDREQUESTED 'gui-agent.exe' (PID 100) exited on request (0x0) - not a death, nothing relaunched"
res = []
if not m.DEATH_RE.match(head): res.append("HEAD wording (QGAWDDEATH) NOT matched")
if not m.DEATH_RE.match(old):  res.append("pre-4.3.36 wording NOT matched")
if m.DEATH_RE.match(notd):     res.append("QGAWDREQUESTED wrongly counted as a death")
if "JudgeAgentExit" not in getattr(m, "WATCHDOG_DEATH_FUNCS", ()): res.append("JudgeAgentExit not in WATCHDOG_DEATH_FUNCS")
print("OK" if not res else "FAIL " + "; ".join(res))
PYF
)
case "$wording" in
  OK) ok "death wording: HEAD and pre-4.3.36 forms both match, QGAWDREQUESTED does not, JudgeAgentExit is gated in" ;;
  *)  bad "death wording: $wording" ;;
esac

# AND BOTH HALVES MUST BE SEEN TO FAIL. The knobs put the shipped defect back, one line each.
for kn in deathwording deathfunc; do
  K=$(knob "$kn") || { bad "knob $kn could not be built"; continue; }
  r=$(python3 - "$K" "$kn" <<'PYF'
import importlib.util, sys, io
spec = importlib.util.spec_from_file_location("lsk", sys.argv[1]); m = importlib.util.module_from_spec(spec)
sys.modules["lsk"] = m
try: spec.loader.exec_module(m)
except SystemExit: pass
head = "QGAWDDEATH 'gui-agent.exe' (PID 7360) exited with code 0x40010004 without this service asking it to - the agent DIED"
if sys.argv[2] == "deathwording":
    print("BROKEN" if not m.DEATH_RE.match(head) else "STILL-SEES")
else:
    # THE KNOB REWRITES THE CALL SITE, NOT THE CONSTANT. A first version of this probe asked whether
    # JudgeAgentExit was still in WATCHDOG_DEATH_FUNCS - which the knob never touches - so it reported
    # STILL-SEES against a correctly applied defect. Read the source the knob produced.
    src = io.open(sys.argv[1], encoding="utf-8", errors="replace").read()
    gated = "elif l.func in WATCHDOG_DEATH_FUNCS:" in src
    print("BROKEN" if not gated else "STILL-SEES")
PYF
)
  [ "$r" = BROKEN ] && ok "knob $kn: with the defect back, the gate goes blind to the shipped wording" \
                    || bad "knob $kn: the defect did not blind the gate ($r) - the check is decoration"
done

# ---- T36: the clock correction must not turn one boot into two, and a per-day file must offer
# every instance's own estimate. Both were measured on win11-acc 2026-10-09 (see the fixture).
rc=$(analyze "$SRC" "$T/clockflip" "$T/baseline.json" "$T/jev-expected.py" t36)
b=$(field "$T/t36.json" 'r["header"]["boots"]')
off=$(field "$T/t36.json" 'r["header"]["clock_offset_s"]')
[ "$off" = "3600.0" ] && ok "T36 the clock correction is measured from the logs themselves (offset=${off}s)" \
                      || bad "T36 offset read '$off', want 3600.0"
[ "$b" = 2 ] && ok "T36 a per-day log spanning two boots yields two, not one" \
             || bad "T36 boots=$b, want 2"
# WHAT THIS FIXTURE DOES NOT DRIVE, said plainly rather than asserted: the ahead-phase boot estimate
# does not survive into this fixture's cluster list, so the PHASE MERGE (GUARD:clockphase) and the
# two-phase line attribution (GUARD:bootphase) are NOT exercised here - a synthetic one-file stream
# does not reproduce enough of the per-file state the analyzer keeps. Both knobs were driven against
# the REAL capture from win11-acc (scratchpad/sweep-win11-acc/logs, 57 files, 14849 lines), where
# each changes exactly one line and compiles: shipped boots=6 / instances_per_boot=2;
# knob clockphase boots=11; knob allinits boots=3 and instances_per_boot=5; knob bootphase
# instances_per_boot=7. The shipped numbers were cross-checked by hand from the agent's own LogInit
# uptime lines. Closing this gap means a fixture that carries two phases through the decoder.
# ---- T36b BOOTS CLOSER TOGETHER THAN THE ATTRIBUTION WINDOW ------------------------------------
# The grader must not invent a restart out of boot spacing. Four boots, one instance each; the
# forward allowance is now derived (never past BOOT_TOL_S, never past the midpoint to the next boot)
# instead of a flat 150 s that was wider than the 55 s gaps this rig actually produces.
rc=$(analyze "$SRC" "$T/rapidboot" "$T/baseline.json" "$T/jev-expected.py" t36b)
rbb=$(field "$T/t36b.json" 'r["header"]["boots"]')
rbi=$(field "$T/t36b.json" 'r["metrics"]["agent_instances"]')
rbp=$(field "$T/t36b.json" 'r["metrics"]["agent_instances_per_boot"]')
[ "$rbb" = 4 ] && ok "T36b four boots 214/62/55 s apart are four boots (boots=$rbb)" \
               || bad "T36b boots=$rbb, want 4"
[ "$rbi" = 4 ] && ok "T36b all four agent instances are seen (agent_instances=$rbi)" \
               || bad "T36b agent_instances=$rbi, want 4"
[ "$rbp" = 1 ] && ok "T36b each lands in its OWN boot - no restart is invented (agent_instances_per_boot=$rbp)" \
               || bad "T36b agent_instances_per_boot=$rbp, want 1"
# SEEN TO FAIL: with the flat 150 s forward window back, the later boots claim the earlier LINES.
# THE OBSERVABLE MOVED, AND WHY. This knob used to be driven through agent_instances_per_boot. Since
# 2026-10-17 an instance's boot comes from ITS OWN uptime anchor (GUARD:instboot) - strictly better
# than a forward window wherever an anchor exists - so the knob could no longer move the instance
# count and this check could not be driven at all. The forward window still governs LINES, so the
# guard is driven there now: a signature written once per boot shows exactly what the window did.
# Deleting the check instead would have left the feature with no test, which is how a real rule dies.
KF=$(knob fwdallow)
pbv(){ # $1=analyzer $2=tag -> "<distinct boots> <max_per_boot>" for the FWDPROBE signature
  python3 "$1" analyze "$T/rapidboot" --baseline none --out "$T/$2.json" --summary "$T/$2.txt" \
      --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" > "$T/$2.out" 2>&1
  field "$T/$2.json" '(lambda v: str(len((v.get("per_boot") or {}))) + " " + str(v.get("max_per_boot")))([x for x in r["signatures"].values() if "FWDPROBE" in x["key"]][0])'
}
read -r fwb fwm <<<"$(pbv "$SRC" t36bl)"
[ "$fwb" = 4 ] && [ "$fwm" = 1 ] && ok "T36b each boot keeps its OWN line (boots=$fwb max_per_boot=$fwm)" \
                || bad "T36b FWDPROBE spread over $fwb boot(s), max_per_boot=$fwm - want 4 and 1"
read -r fwbk fwmk <<<"$(pbv "$KF" t36bk)"
[ "$fwmk" = 3 ] && ok "knob fwdallow: SEEN TO FAIL - the flat 150 s window puts 3 of 4 boots' lines in one boot (boots=$fwbk max_per_boot=$fwmk)" \
               || bad "knob fwdallow: boots=$fwbk max_per_boot=$fwmk, want max_per_boot=3 - the case cannot be driven"

K=$(knob allinits); rc=$(analyze "$K" "$T/clockflip" "$T/baseline.json" "$T/jev-expected.py" t36a)
ba=$(field "$T/t36a.json" 'r["header"]["boots"]')
[ "$ba" = 1 ] && ok "knob allinits: with only the last init, a per-day file offers ONE boot (boots=$ba)" \
              || bad "knob allinits: boots=$ba, want 1 - the case cannot be driven"

# ---- T37 a task that COMPLETED is not a task failure -------------------------------------------
# MEASURED 2026-10-09 on win11-acc. task_failures counted every TaskScheduler 201 and 203 for one of
# our tasks, and 201 reads "Task Scheduler SUCCESSFULLY COMPLETED task X ... with return code N".
# Our tasks are meant to run and complete every boot (QwtClockSync, QubesPvNic, QwtModuleBases,
# QubesPvNicRearm, QwtDeathReporter), so a metric whose threshold is max 0 could never read 0 however
# clean the guest was - the same shape as a release suite that cannot pass. That capture's window held
# five records: FOUR with return code 0 and one QwtDeathReporter with 2147943691 = 0x8007045B =
# ERROR_SHUTDOWN_IN_PROGRESS, the shutdown reaping a task, which this analyzer already excuses for
# id=203. On the real capture the metric went 19 -> 0 and the breach disappeared.
t37(){ # $1=eid $2=message $3=expected(True|False) $4=label
  got=$(python3 - "$ROOT/tools/log-sweep.py" "$1" "$2" <<'PY37'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("ls", sys.argv[1])
ls = importlib.util.module_from_spec(spec); spec.loader.exec_module(ls)
print(ls.task_record_is_failure(int(sys.argv[2]), sys.argv[3]))
PY37
)
  if [ "$got" = "$3" ]; then ok "T37 $4"; else bad "T37 $4 -> $got (want $3)"; fi
}
t37 201 'Task Scheduler successfully completed task "\QwtClockSync" , action "powershell.exe" with return code 0' False 'a 201 with return code 0 is a success, not a failure'
t37 201 'Task Scheduler successfully completed task "\QubesPvNic" , action "powershell.exe" with return code 1' True 'a 201 with a non-zero return code still counts'
t37 201 'Task Scheduler successfully completed task "\QwtDeathReporter" , action "powershell.exe" with return code 2147943691' False 'a 201 carrying the shutdown code is the shutdown, not a defect'
t37 201 'Task Scheduler successfully completed task "\QwtModuleBases" , action "x" with no code at all' True 'a 201 with no parsable return code counts - missing data is not an excuse'
t37 203 'Task Scheduler failed to launch action "powershell.exe" in task "\QwtDeathReporter". Additional Data: Error Value: 2.' True 'a real 203 launch failure still counts'
# THE METRIC, not the predicate: the knob drops the predicate from the count, so only a run over a
# fixture carrying both kinds of record can drive it. taskok has one 201 (return code 0) and one real
# 203, so the shipped analyzer must count ONE and the knob'd one TWO.
rc=$(analyze "$SRC" "$T/taskok" "$T/baseline.json" "$T/jev-expected.py" t37m)
tf=$(field "$T/t37m.json" 'r["metrics"]["task_failures"]')
[ "$tf" = 1 ] && ok "T37 the metric counts the real 203 and not the completed 201 (task_failures=$tf)" \
              || bad "T37 task_failures=$tf over taskok, want 1"
KT=$(knob taskrc); rc=$(analyze "$KT" "$T/taskok" "$T/baseline.json" "$T/jev-expected.py" t37k)
tfk=$(field "$T/t37k.json" 'r["metrics"]["task_failures"]')
[ "$tfk" = 2 ] && ok "knob taskrc: with the return code ignored, the COMPLETED task counts too (task_failures=$tfk)" \
               || bad "knob taskrc: task_failures=$tfk, want 2 - the case cannot be driven"

# ---- T38 an announcement the agent WITHDREW is not a dangling vchan ---------------------------
rc=$(analyze "$SRC" "$T/vchanwd" "$T/baseline.json" "$T/jev-expected.py" t38)
vw=$(field "$T/t38.json" 'r["metrics"]["vchan_announce_without_connect"]')
[ "$vw" = 0 ] && ok "T38 a withdrawn announcement is not counted (vchan_announce_without_connect=$vw)" \
              || bad "T38 vchan_announce_without_connect=$vw over vchanwd, want 0"
KW=$(knob vchanwithdrawn); rc=$(analyze "$KW" "$T/vchanwd" "$T/baseline.json" "$T/jev-expected.py" t38k)
vwk=$(field "$T/t38k.json" 'r["metrics"]["vchan_announce_without_connect"]')
[ "$vwk" = 1 ] && ok "knob vchanwithdrawn: with the withdrawal ignored, correct behaviour counts as a defect (=$vwk)" \
               || bad "knob vchanwithdrawn: got $vwk, want 1 - the case cannot be driven"

# ---- T39 the --since window must mean REAL time, not pre-correction stamps --------------------
# The analyze() helper passes no --since, so this case calls the analyzer directly with one.
pf(){ # $1=analyzer $2=tag -> prints error_lines
  python3 "$1" analyze "$T/phaseflip" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" \
      --since 2026-10-07T10:30:00Z > "$T/$2.out" 2>&1
  field "$T/$2.json" 'r["metrics"]["error_lines"]'
}
el=$(pf "$SRC" t39)
sh=$(field "$T/t39.json" 'r["header"]["clock_phase_shifted_lines"]')
[ "$el" = 0 ] && ok "T39 a pre-correction error line is OUTSIDE a window its stamp appears inside (error_lines=$el)" \
              || bad "T39 error_lines=$el over phaseflip, want 0 - the window is still reading raw stamps"
[ "${sh:-0}" -ge 1 ] && ok "T39 and the shift is reported, not silent (clock_phase_shifted_lines=$sh)" \
                     || bad "T39 clock_phase_shifted_lines=$sh, want >=1"
KP=$(knob phasenorm); elk=$(pf "$KP" t39k)
[ "$elk" = 1 ] && ok "knob phasenorm: without the shift the same line is counted in a window it never belonged to (error_lines=$elk)" \
               || bad "knob phasenorm: error_lines=$elk, want 1 - the case cannot be driven"

# ---- T40 a thresholded per-instance metric must respect the --since window --------------------
# MEASURED 2026-10-09 on win10-acc. SEVEN thresholded per-instance metrics were computed over every
# instance in the capture rather than the windowed list, so a sweep graded OTHER RUNS and OLDER
# BUILDS. That guest's only breach was errors_during_requested_stop = 2 (Jev: defect 1.00), and both
# lines belong to instance pid 3228, "Module version: 4.3.35.795", whose requested stop ran at
# 04:22:26 while the window opened at 05:32:20 - an older build, an hour outside the window. The logs
# are per-DAY, so every capture holds earlier instances and this fired on all of them.
# stoperr is reused: its instance logs an ERROR during its requested stop at ~10:01, and a window
# opening at 10:30 puts that instance outside it.
sw(){ # $1=analyzer $2=tag -> prints errors_during_requested_stop
  python3 "$1" analyze "$T/stoperr" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" \
      --since 2026-10-07T10:30:00Z > "$T/$2.out" 2>&1
  field "$T/$2.json" 'r["metrics"]["errors_during_requested_stop"]'
}
ew=$(sw "$SRC" t40)
[ "$ew" = 0 ] && ok "T40 an instance outside the window is not graded (errors_during_requested_stop=$ew)" \
              || bad "T40 errors_during_requested_stop=$ew with the instance outside the window, want 0"
KI=$(knob instwindow); ewk=$(sw "$KI" t40k)
[ "$ewk" = 1 ] && ok "knob instwindow: with the window ignored, another run's instance is graded (=$ewk)" \
               || bad "knob instwindow: got $ewk, want 1 - the case cannot be driven"

# ---- T44 the window is TEMPORAL; the thing under test is a BUILD ------------------------------
# T40 fixed half of this class with the time window. This is the half a window cannot reach: on a
# quick-upgrade cell both builds run INSIDE it, minutes apart. MEASURED win11-nfy 2026-10-16 - see
# the twobuild fixture. A line is a prior build's only when its own module declared a newer version
# somewhere in the capture, which is what leaves single-version stock modules (file-receiver
# 4.2.2.0, qubesdb-daemon 4.3.1.0, qwtng-netsetup 0.0.0.0) untouched.
tb(){ # $1=analyzer $2=tag -> prints "<error_lines> <error_lines_prior_build> <mix>"
  python3 "$1" analyze "$T/twobuild" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" > "$T/$2.out" 2>&1
  field "$T/$2.json" 'str(r["metrics"]["error_lines"])+" "+str(r["metrics"].get("error_lines_prior_build"))+" "+str(r["metrics"].get("prior_build_mix"))'
}
read -r t44e t44p t44m <<<"$(tb "$SRC" t44)"
[ "$t44e" = 0 ] && ok "T44 the superseded build's ERROR line is not billed to the build under test (error_lines=$t44e)" \
                || bad "T44 error_lines=$t44e, want 0 - the old build's line is still counted as the new build's"
[ "$t44p" = 1 ] && ok "T44 and the exclusion is REPORTED, not silent (error_lines_prior_build=$t44p)" \
                || bad "T44 error_lines_prior_build=$t44p, want 1 - an excluded line must stay a figure"
case "$t44m" in *9.9.9.0*9.9.9.1*) ok "T44 the version mix is named (prior_build_mix=$t44m)" ;;
                *) bad "T44 prior_build_mix=$t44m, want both versions of gui-agent" ;; esac
# ---- T54 THE INSTALL ANCHOR: the half no version can reach ------------------------------------
# bridge.log declares no version and TaskScheduler records carry none, so is_prior_build has nothing
# to test on them and the predecessor's entries were billed to the new build. The anchor separates
# them by WHEN the build under test first ran (the 9.9.9.1 init at 10:04:00). The fixture puts one
# fallback line and one task failure on EITHER SIDE of it, so this proves BOTH halves: the earlier
# is excluded, the later is NOT. A filter that dropped both would pass a one-sided test.
ta(){ # $1=analyzer $2=tag -> "<fallbacks_fired> <task_failures> <install_anchor>"
  python3 "$1" analyze "$T/twobuild" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" > "$T/$2.out" 2>&1
  field "$T/$2.json" 'str(r["metrics"].get("fallbacks_fired"))+" "+str(r["metrics"].get("task_failures"))+" "+str(r["metrics"].get("install_anchor"))'
}
read -r t54f t54t t54a <<<"$(ta "$SRC" t54)"
[ "$t54f" = 1 ] && ok "T54 the predecessor's versionless fallback is excluded, the later one is KEPT (fallbacks_fired=$t54f)" \
                || bad "T54 fallbacks_fired=$t54f, want 1 - one line each side of the anchor, only the earlier excluded"
[ "$t54t" = 1 ] && ok "T54 the predecessor's TaskScheduler failure is excluded, the later one is KEPT (task_failures=$t54t)" \
                || bad "T54 task_failures=$t54t, want 1 - Event Log records carry no version, only the anchor places them"
case "$t54a" in *10:04:00*) ok "T54 the anchor is the build-under-test's first init, and is REPORTED ($t54a)" ;;
                *) bad "T54 install_anchor=$t54a, want the 9.9.9.1 init at 10:04:00" ;; esac
# NO KNOB FOR THIS ONE (owner, 2026-10-18: "we do NOT want to regularly FI tests for breach
# metering ... make sure metering works properly once, thats it"). The three checks above are the
# ordinary ones - a line each side of the anchor, and the anchor reported - and they are enough to
# say the metering is right. Driving it to failure was done once, by hand, on the real capture and
# on this fixture: without the anchor both predecessor entries come back as 2 and 2.

KB=$(knob priorbuild); read -r t44ke _ _ <<<"$(tb "$KB" t44k)"
[ "$t44ke" = 1 ] && ok "knob priorbuild: SEEN TO FAIL - without the build scope the old build's line is graded as the new build's (error_lines=$t44ke)" \
                 || bad "knob priorbuild: error_lines=$t44ke, want 1 - the case cannot be driven"

# ---- T55 A COUNT CAN BE SCOPED IN ONE PLACE; A CLASSIFICATION CANNOT ---------------------------
# T44/T54 scoped the line-level METRICS to the build under test. collect_signatures feeds the
# baseline comparison - NEW, ROSE, KNOWN-DEFECT PRESENT, UNSETTLED PRESENT - and it was the one
# consumer that never asked the predicate, so ONE capture stated both things at once: error_lines=0
# because `_prior` excluded the line, and "KNOWN-DEFECT PRESENT" because the comparison did not.
# MEASURED on the 20261018-063720 upgrade cell: 134 signatures carried the predecessor's lines, 3 of
# them graded KNOWN-DEFECT PRESENT, including "ReleaseFrame ... keyed mutex was abandoned" whose log
# declares `Module version: 4.3.35.795` while the build under test excludes exactly that HRESULT at
# capture.c:1669. The row is NOT dropped - dropping it would conceal the line - it is reported under
# its real author, which is the thing that was wrong.
export T55KEY='agent|E|WinMain: WatchForEvents failed with error 0xH: The operation completed successfully.'
cls(){ # $1=report json -> the bucket(s) $T55KEY appears in
  field "$1" '" ".join(sorted(b for b in ("new","rose","known_defects_present","unsettled_present","prior_build") if any(s["key"]==__import__("os").environ["T55KEY"] for s in (r.get(b) or [])))) or "NONE"'
}
t55=$(cls "$T/t44.json")
[ "$t55" = "prior_build" ] && ok "T55 the superseded build's error signature is classified as the PRIOR BUILD's, in no other bucket ($t55)" \
                           || bad "T55 the signature is in [$t55], want prior_build alone - a class is a statement about the build under test"
# SEEN TO FAIL THROUGH THE KNOB THAT ALREADY EXISTS - no second marker in product code (Jev:
# not_needed 0.97). GUARD:priorbuild sits on the predicate every consumer calls, so driving it makes
# count_prior 0 everywhere and the classification arm never fires. t44k.json is that knob's report.
t55k=$(cls "$T/t44k.json")
case "$t55k" in prior_build|NONE) bad "T55 knob priorbuild does not reach the classification - the row is still [$t55k], so the bucket is untested" ;;
                *) ok "T55 SEEN TO FAIL via knob priorbuild: with the scope off the predecessor's line is graded as the build under test's [$t55k]" ;; esac
# AND THE FILTER MUST NOT EAT A SINGLE-VERSION MODULE: the clean fixture has one build only, so its
# error/warning counts must be untouched by all of the above (a filter that over-reaches here would
# zero the gate metric on every normal run, which reads exactly like a pass).
bw=$(field "$T/t2.json" 'r["metrics"]["warning_lines"]')
bp=$(field "$T/t2.json" 'str(r["metrics"].get("error_lines_prior_build"))+" "+str(r["metrics"].get("prior_build_mix"))')
[ "${bw:-0}" -ge 1 ] && [ "$bp" = "0 {}" ] && ok "T44 a single-build capture is untouched (warning_lines=$bw, prior_build=$bp)" \
                     || bad "T44 single-build capture disturbed: warning_lines=$bw prior_build=$bp, want >=1 and '0 {}'"

# ---- T45 --build names the build under test, because a DOWNGRADE inverts "newest" --------------
# Jev scored the self-calibrating rule 0.61 with 0.39 on "it has a failure mode that matters", and
# this is the one: installing an OLDER build over a newer one makes the superseded half the half
# that is kept. --build wins over "highest version seen", and the disagreement is a DATA PROBLEM,
# never a silent preference.
tbb(){ # $1=--build value $2=tag -> "<error_lines> <prior_build> <problem kinds>"
  python3 "$SRC" analyze "$T/twobuild" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" \
      --build "$1" > "$T/$2.out" 2>&1
  field "$T/$2.json" 'str(r["metrics"]["error_lines"])+" "+str(r["metrics"]["error_lines_prior_build"])+" "+str(sorted({p[0] for p in r["data_problems"]}))'
}
read -r t45e t45p t45k <<<"$(tbb 9.9.9.1 t45)"
[ "$t45e" = 0 ] && [ "$t45p" = 1 ] && ok "T45 --build agreeing with newest changes nothing (error_lines=$t45e prior=$t45p)" \
                || bad "T45 --build 9.9.9.1 gave error_lines=$t45e prior=$t45p, want 0 and 1"
read -r t45de t45dp t45dk <<<"$(tbb 9.9.9.0 t45d)"
[ "$t45de" = 1 ] && [ "$t45dp" = 0 ] && ok "T45 a DOWNGRADE scopes to --build, not to newest (error_lines=$t45de prior=$t45dp)" \
                 || bad "T45 --build 9.9.9.0 gave error_lines=$t45de prior=$t45dp, want 1 and 0 - the filter still prefers newest"
case "$t45dk" in *build-scope*) ok "T45 and the downgrade is a DATA PROBLEM, not a silent choice ($t45dk)" ;;
                 *) bad "T45 downgrade raised no build-scope data problem (kinds=$t45dk)" ;; esac

# ---- T46 a superseded module whose NEWEST build wrote nothing in the window is a FAILURE -------
# The one way the filter can manufacture a zero: the upgrade lands at the very end of the window,
# so the build under test has written no line and its 0 means "nothing was considered". The
# GUARD:winsince comment records three metrics already lost to that reading.
sb(){ # $1=analyzer $2=tag -> "<rc> <problem kinds> <silent modules>"
  python3 "$1" analyze "$T/twobuild" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" \
      --since 2026-10-07T10:06:00Z > "$T/$2.out" 2>&1
  printf '%s ' "$?"
  field "$T/$2.json" 'str(sorted({p[0] for p in r["data_problems"]}))+" "+str(r["metrics"]["modules_superseded_silent"])'
}
read -r t46rc t46k t46m <<<"$(sb "$SRC" t46)"
case "$t46k$t46m" in *build-scope*gui-agent*) ok "T46 the newest build writing nothing in the window FAILS (rc=$t46rc kinds=$t46k silent=$t46m)" ;;
                     *) bad "T46 kinds=$t46k silent=$t46m, want a build-scope problem naming gui-agent" ;; esac
[ "$t46rc" != 0 ] && ok "T46 and it is a non-zero rc, not a pass (rc=$t46rc)" \
                  || bad "T46 rc=$t46rc - a sweep that considered nothing must not pass"
KS=$(knob silentbuild); read -r t46krc t46kk _ <<<"$(sb "$KS" t46k)"
case "$t46kk" in *build-scope*) bad "knob silentbuild: still raised the problem (kinds=$t46kk) - the case cannot be driven" ;;
                 *) ok "knob silentbuild: SEEN TO FAIL - without it the empty window passes silently (kinds=$t46kk)" ;; esac

# ---- T47 TWO BOOTS 37 s APART MUST NOT MERGE, and each instance belongs to ITS OWN boot --------
# MEASURED win10-clean 2026-10-17 and reproduced by the fastreboot fixture with the same numbers.
# One clustering error produced FOUR P2 breaches on a build whose watchdog log carries zero
# "not running, restarting it" lines: agent_instances_per_boot, agent_instances_per_shutdown,
# agent_relaunches_at_shutdown and vchan_setups_per_shutdown. Jev scored the relaunch one defect
# 0.87 against a correct binary, which is what a grader artefact costs when nobody checks the
# emitter. Two knobs, because the defect had TWO independent halves and fixing one left the other.
fr(){ # $1=analyzer $2=tag -> "<boots> <per_boot> <per_shutdown> <relaunches> <vchan>"
  python3 "$1" analyze "$T/fastreboot" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" > "$T/$2.out" 2>&1
  field "$T/$2.json" 'str(len(r["boots"]))+" "+str(r["metrics"]["agent_instances_per_boot"])+" "+str(r["metrics"]["agent_instances_per_shutdown"])+" "+str(r["metrics"]["agent_relaunches_at_shutdown"])+" "+str(r["metrics"]["vchan_setups_per_shutdown"])'
}
read -r b47 pb47 ps47 rl47 vc47 <<<"$(fr "$SRC" t47)"
[ "$pb47" = 1 ] && ok "T47 one agent per boot, with boots 37 s apart kept apart (boots=$b47 per_boot=$pb47)" \
               || bad "T47 agent_instances_per_boot=$pb47 (boots=$b47), want 1 - two boots 37 s apart merged"
[ "$rl47" = 0 ] && ok "T47 and no relaunch is invented from a boot's own agent (relaunches=$rl47)" \
               || bad "T47 agent_relaunches_at_shutdown=$rl47, want 0 - the watchdog never logged a restart"
[ "$ps47" = 1 ] && [ "$vc47" = 0 ] && ok "T47 the shutdown-window metrics are clean too (per_shutdown=$ps47 vchan=$vc47)" \
                || bad "T47 per_shutdown=$ps47 vchan=$vc47, want 1 and 0"
KE=$(knob exacttol); read -r b47e pb47e _ _ rl47e <<<"$(fr "$KE" t47e)"
[ "$pb47e" -ge 2 ] || [ "$rl47e" -ge 1 ] \
  && ok "knob exacttol: SEEN TO FAIL - with one tolerance for exact and inexact estimates the boots merge (boots=$b47e per_boot=$pb47e)" \
  || bad "knob exacttol: boots=$b47e per_boot=$pb47e - the case cannot be driven"
KA=$(knob announceneedsend); read -r _ _ _ _ vc47a <<<"$(fr "$KA" t47a)"
[ "$vc47a" -ge 1 ] \
  && ok "knob announceneedsend: SEEN TO FAIL - a boot's OWN startup announce counts as a vchan setup while going down (=$vc47a)" \
  || bad "knob announceneedsend: vchan_setups_per_shutdown=$vc47a, want >=1 - the case cannot be driven"
KB=$(knob instboot); read -r b47i pb47i _ _ _ <<<"$(fr "$KB" t47i)"
[ "$pb47i" -ge 2 ] \
  && ok "knob instboot: SEEN TO FAIL - with the clusters right, a line's boot still mis-attributes the instance (per_boot=$pb47i)" \
  || bad "knob instboot: per_boot=$pb47i, want >=2 - the case cannot be driven"

# ---- T48 a TOLERATED declaration claims no stimulus, so its absence is not a breach ------------
# MEASURED 2026-10-17: the owner declared the geometry-changed line ("declare those 4 for now"),
# and as a CAUSED declaration it failed win10-appvm - a cell whose product wrote ZERO error lines -
# because the line only appears when a resolution changes and that cell never changes one. A caused
# declaration is a claim that a stimulus was APPLIED, so unmatched is rightly a breach; a tolerated
# one is an owner override and its absence is good news.
td(){ # $1=analyzer $2=tag $3=1 for tolerate -> "<unmatched> <tolerated> <undeclared>"
  python3 - "$T/base/context.json" "$3" <<'PYX'
import json,sys
d={"pattern":"FixtureNoveltyNeverAppears","why":"a pattern that matches nothing in the clean fixture"}
if sys.argv[2]=="1": d["tolerate"]=True
json.dump({"source":"selftest T48","declared_errors":[d]},open(sys.argv[1],"w"))
PYX
  python3 "$1" analyze "$T/base" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" > "$T/$2.out" 2>&1
  field "$T/$2.json" 'str(r["metrics"]["declared_errors_unmatched"])+" "+str(r["metrics"].get("declared_errors_tolerated"))+" "+str(r["metrics"]["error_lines_undeclared"])'
}
_ctxsave="$T/base/context.json.t48save"; [ -f "$T/base/context.json" ] && cp "$T/base/context.json" "$_ctxsave"
read -r u48t tl48t _ <<<"$(td "$SRC" t48t 1)"
[ "$u48t" = 0 ] && [ "$tl48t" = 1 ] && ok "T48 an unmatched TOLERATED declaration is not a breach (unmatched=$u48t tolerated=$tl48t)" \
                || bad "T48 unmatched=$u48t tolerated=$tl48t, want 0 and 1"
read -r u48c tl48c _ <<<"$(td "$SRC" t48c 0)"
[ "$u48c" = 1 ] && ok "T48 an unmatched CAUSED declaration still breaches - the stimulus did not happen (unmatched=$u48c)" \
               || bad "T48 unmatched=$u48c for a caused declaration, want 1 - the old rule must survive"
KT=$(knob tolerate); read -r u48k _ _ <<<"$(td "$KT" t48k 1)"
[ "$u48k" = 1 ] && ok "knob tolerate: SEEN TO FAIL - without the kind, a tolerated declaration breaches on its own absence (unmatched=$u48k)" \
               || bad "knob tolerate: unmatched=$u48k, want 1 - the case cannot be driven"

# ---- T48b THE WRAPPER MUST ACTUALLY WRITE THE KIND --------------------------------------------
# log-sweep.py reading `tolerate: true` is only half of it: mgmt/harness/log-sweep.sh has to put it
# there from --tolerate-error. That plumbing was UNTESTED, and if it were wrong every declaration
# the matrix passes would arrive as CAUSED and every cell without the line would breach as
# unmatched - the exact failure these tests exist to prevent. Jev scored the test set 0.56 with
# this gap in it. Driven by extracting the wrapper's own context block and running it.
wrapctx(){ # $1=the wrapper to drive -> "<caused-flag> <tolerated-flag>"
  python3 - "$1" <<'PYX'
import subprocess, json, os, re, sys, tempfile
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"(python3 - \"\$OUT/logs/context\.json\".*?\nPY\n)", src, re.S)
if not m:
    print("NOBLOCK NOBLOCK"); raise SystemExit(0)
d = tempfile.mkdtemp(); os.makedirs(os.path.join(d, "logs"))
harness = "set -uo pipefail\nOUT=%s\nFI_DECLARED=\"\"\n" % d
harness += "PRESYNC_GUEST_UTC=x; PRESYNC_HOST_UTC=y; PRESYNC_SKEW_S=0; POSTSYNC_GUEST_UTC=z\n"
harness += "DECL_PAT=(); DECL_WHY=(); DECL_TOL=()\n"
harness += 'DECL_PAT+=("CAUSEDPAT"); DECL_WHY+=("guaranteed"); DECL_TOL+=(0)\n'
harness += 'DECL_PAT+=("TOLPAT"); DECL_WHY+=("permitted"); DECL_TOL+=(1)\n'
harness += m.group(1)
r = subprocess.run(["bash", "-c", harness], capture_output=True)
try:
    ctx = json.load(open(os.path.join(d, "logs", "context.json")))
    got = {e["pattern"]: bool(e.get("tolerate", False)) for e in ctx.get("declared_errors", [])}
    print("%s %s" % (got.get("CAUSEDPAT"), got.get("TOLPAT")))
except Exception:
    print("ERR ERR")
PYX
}
read -r wc1 wt1 <<<"$(wrapctx "$ROOT/mgmt/harness/log-sweep.sh")"
[ "$wc1" = False ] && [ "$wt1" = True ] \
  && ok "T48b the wrapper writes tolerate=true for --tolerate-error and nothing for --declare-error (caused=$wc1 tolerated=$wt1)" \
  || bad "T48b wrapper wrote caused=$wc1 tolerated=$wt1, want False and True - the kind does not reach context.json"
# SEEN TO FAIL: with the kind stripped out of the wrapper, both arrive as caused.
sed -E 's/\*\*\(\{"tolerate": True\} if t == "1" else \{\}\)/**{}/' "$ROOT/mgmt/harness/log-sweep.sh" > "$T/wrapper-nokind.sh"
read -r wc2 wt2 <<<"$(wrapctx "$T/wrapper-nokind.sh")"
[ "$wt2" = False ] \
  && ok "T48b SEEN TO FAIL: with the kind stripped, a tolerated declaration arrives as CAUSED (tolerated=$wt2)" \
  || bad "T48b the stripped wrapper still wrote tolerated=$wt2 - the case cannot be driven"
[ -f "$_ctxsave" ] && mv "$_ctxsave" "$T/base/context.json" || rm -f "$T/base/context.json"

# ---- T49 a requested stop REPORTS ITS REASON, and a named reason is not a failure -------------
# The agent exits with QGA_EXIT_REQUESTED when the watchdog asks it to stop through
# Global\QGA_SHUTDOWN. requested_stop_nonzero_exit demanded 0x0 and so fired on the product
# correctly naming the request it was given - and its own `why` still cites "the 0xb7 case", the
# stale-GetLastError defect of 2026-10-07 that these reason codes were introduced to fix.
# The product owns this decision in QgaExitIsExpected(); the grader uses the same set.
rs(){ # $1=analyzer $2=tag -> requested_stop_nonzero_exit
  python3 "$1" analyze "$T/reqstop" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" > "$T/$2.out" 2>&1
  field "$T/$2.json" 'r["metrics"]["requested_stop_nonzero_exit"]'
}
t49=$(rs "$SRC" t49)
[ "$t49" = 0 ] && ok "T49 a requested stop exiting QGA_EXIT_REQUESTED is not a non-zero failure (=$t49)" \
               || bad "T49 requested_stop_nonzero_exit=$t49, want 0 - the agent named the reason it was asked for"
KR=$(knob reqstopreason); t49k=$(rs "$KR" t49k)
[ "$t49k" = 1 ] && ok "knob reqstopreason: SEEN TO FAIL - demanding 0x0 breaches on the named reason (=$t49k)" \
                || bad "knob reqstopreason: got $t49k, want 1 - the case cannot be driven"

# ---- T50 the installer's own SERVICE RESTART is not a second instance of the boot -------------
# A same-version reinstall stops and starts the services inside one boot. The metric's why is "the
# agent is started once per boot; a second instance is a death or a restart" - an orderly requested
# service stop is NEITHER, and forgiving it is counted rather than hidden.
sv(){ # $1=analyzer $2=tag -> "<per_boot> <service_restarts>"
  python3 "$1" analyze "$T/svcrestart" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" > "$T/$2.out" 2>&1
  field "$T/$2.json" 'str(r["metrics"]["agent_instances_per_boot"])+" "+str(r["metrics"].get("agent_service_restarts"))'
}
read -r t50p t50r <<<"$(sv "$SRC" t50)"
[ "$t50p" = 1 ] && ok "T50 two agents in one boot across an orderly service stop count as one (per_boot=$t50p)" \
               || bad "T50 agent_instances_per_boot=$t50p, want 1 - the installer's own restart is counted"
[ "$t50r" = 1 ] && ok "T50 and the forgiveness is a FIGURE, not an absence (agent_service_restarts=$t50r)" \
               || bad "T50 agent_service_restarts=$t50r, want 1"
KV=$(knob svcrestart); read -r t50kp _ <<<"$(sv "$KV" t50k)"
[ "$t50kp" = 2 ] && ok "knob svcrestart: SEEN TO FAIL - the installer's restart counts as a second instance (per_boot=$t50kp)" \
                || bad "knob svcrestart: per_boot=$t50kp, want 2 - the case cannot be driven"

# ---- T51 a task's RETURN CODE is the field that decides what the record means -----------------
# A TaskScheduler 201 says "successfully completed" whatever the action returned, so the return code
# is the whole content of the record. `task_record_is_failure` reads it, and SHUTDOWN_RESULT_CODES_RE
# names the two values that mean "the shutdown reaped the task" - by design, not a failure. But the
# SIGNATURE went through the generic folding: 2147943691 -> H, 0 -> N. MEASURED win10-clean, campaign
# run 38994277148: Jev classified three such records as DEFECTS at 0.41-0.64, answering honestly
# about a string from which the deciding fact had been removed - and the same condition SPLIT in two,
# because the two values fold to different tokens.
nrm(){ # $1=analyzer $2=text -> the normalised tail
  python3 - "$1" "$2" <<'PYX'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", sys.argv[1])
ls = importlib.util.module_from_spec(spec); spec.loader.exec_module(ls)
print(ls.normalize(sys.argv[2]))
PYX
}
T51BASE='Task Scheduler successfully completed task "\QubesPvNic" , instance "{2dc8b2aa}" , action "powershell.exe" with return code'
case "$(nrm "$SRC" "$T51BASE 2147943691.")" in
  *"return code SHUTDOWNREFUSAL"*) ok "T51 a shutdown-reaped task is NAMED, not folded to a digit" ;;
  *) bad "T51 the refusal code is still folded: $(nrm "$SRC" "$T51BASE 2147943691.")" ;;
esac
case "$(nrm "$SRC" "$T51BASE 0.")" in
  *"return code ZERO"*) ok "T51 a clean return is ZERO, distinct from the refusal" ;;
  *) bad "T51 return code 0 did not become ZERO" ;;
esac
# A GENUINE failure code must stay distinguishable from both - it is neither zero nor a refusal.
r51=$(nrm "$SRC" "$T51BASE 1603.")
case "$r51" in
  *SHUTDOWNREFUSAL*|*ZERO*) bad "T51 a real failure code (1603) was named as a refusal or a zero: $r51" ;;
  *) ok "T51 a real failure code is neither - it stays distinguishable" ;;
esac
KN=$(knob taskrcname)
case "$(nrm "$KN" "$T51BASE 2147943691.")" in
  *"return code SHUTDOWNREFUSAL"*) bad "knob taskrcname: the refusal is still named - the case cannot be driven" ;;
  *) ok "knob taskrcname: SEEN TO FAIL - without the rule the deciding fact folds away again" ;;
esac

# ---- T52 a Jev verdict below the floor is REPORTED and owed a decision, not a release failure --
# baseline-init in log-sweep.py already classifies defect/expected/noise only at >= 0.5 and calls
# anything below it "unsettled ... a human decision is owed". The analyze path read no confidence at
# all, so the two halves of one file disagreed about what a weak verdict means. MEASURED campaign
# run 38994277148: win10-appvm failed on ONE verdict - A6LEAK at defect 0.40 - with zero metric
# breaches and zero undeclared error lines, on a line whose WARNING level is a recorded decision
# (lowering it was reverted the same day at Jev 0.07). A sub-floor verdict is still in the report.
wk(){ # $1=analyzer $2=tag -> "<status> <judged_defects> <sub_floor>"
  python3 "$1" analyze "$T/newsig" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-defect-weak.py" > "$T/$2.out" 2>&1
  field "$T/$2.json" 'str(r["status"])+" "+str(len(r.get("judged_defects") or []))+" "+str(len(r.get("judged_sub_floor") or []))'
}
read -r t52s t52d t52f <<<"$(wk "$SRC" t52)"
[ "$t52d" = 0 ] && ok "T52 a defect at 0.40 does not fail the run (judged_defects=$t52d, status=$t52s)" \
               || bad "T52 judged_defects=$t52d with a 0.40 verdict, want 0 - below the floor this file uses elsewhere"
[ "$t52f" -ge 1 ] && ok "T52 and it IS reported, not silent (judged_sub_floor=$t52f)" \
                  || bad "T52 judged_sub_floor=$t52f - a sub-floor verdict must still be visible"
KD=$(knob defectfloor); read -r t52ks t52kd _ <<<"$(wk "$KD" t52k)"
[ "$t52kd" -ge 1 ] && ok "knob defectfloor: SEEN TO FAIL - without it a 0.40 verdict fails the run (judged_defects=$t52kd, status=$t52ks)" \
                   || bad "knob defectfloor: judged_defects=$t52kd, want >=1 - the case cannot be driven"
# AND A CONFIDENT DEFECT MUST STILL FAIL: the floor must not become a blanket.
cf(){ python3 "$SRC" analyze "$T/newsig" --baseline "$T/baseline.json" --out "$T/$1.json" \
        --summary "$T/$1.txt" --label "$1" --workdir "$T/work-$1" --jev-cmd "$T/jev-defect.py" > "$T/$1.out" 2>&1
      field "$T/$1.json" 'str(len(r.get("judged_defects") or []))'; }
t52c=$(cf t52c)
[ "$t52c" -ge 1 ] && ok "T52 a defect at 0.91 still fails the run (judged_defects=$t52c)" \
                  || bad "T52 a CONFIDENT defect no longer fails - the floor became a blanket"

# ---- T41-T42 the rig wrapper: the guest's clock is read BEFORE it is synced, and the collector's cap is passed ----
# MEASURED 2026-10-10 on win10-acc: the wrapper never called `qtest synctime`, so the collector ran with the guest
# at +10804 s - 1116 lines were phase-corrected and the sweep
# graded ITSELF rc=3 DATA (clockskew) instead of returning a verdict; and the collector's default 60-file cap skipped
# 12 files, the second reason for rc=3. The wrapper needs a guest, so like T25 these are shape checks on its text,
# each SEEN TO FAIL on a copy with the fix taken out. THE ORDER IS THE FIX: syncing before measuring would destroy
# the evidence (the skew is a finding about the product's clock sync), and syncing after collecting would leave the
# analyzer's clockskew check (T31/T32) firing on every sweep.
WRAP="$ROOT/mgmt/harness/log-sweep.sh"
mkdir -p "$T/wrap"
chg(){ diff "$WRAP" "$1" | grep -c '^[<>]'; }   # changed lines between the wrapper and a defect copy
wrap_clock(){ # $1=wrapper -> "ok" or the reason: read (GUARD:presyncread) < sync (GUARD:synctime) < collector pushrun
  local r s p
  r=$(grep -an 'GUARD:presyncread' "$1" | cut -d: -f1 | head -1)
  s=$(grep -an 'GUARD:synctime' "$1" | cut -d: -f1 | head -1)
  p=$(grep -an 'qtest pushrun mgmt/harness/log-sweep-collect.ps1' "$1" | cut -d: -f1 | head -1)
  [ -n "$r" ] || { echo "no pre-sync guest clock read"; return; }
  [ -n "$s" ] || { echo "no synctime call"; return; }
  [ -n "$p" ] || { echo "no collector pushrun"; return; }
  grep -aq 'presync_skew_s' "$1" || { echo "the skew is never recorded (no presync_skew_s)"; return; }
  [ "$r" -lt "$s" ] || { echo "the clock is read at :$r, AFTER the sync at :$s - the skew is measured once it is gone"; return; }
  [ "$s" -lt "$p" ] || { echo "synctime at :$s runs AFTER the collector at :$p"; return; }
  echo ok
}
v=$(wrap_clock "$WRAP")
[ "$v" = ok ] && ok "T41 the wrapper reads the guest clock and records presync_skew_s, then syncs, then collects" \
              || bad "T41 mgmt/harness/log-sweep.sh: $v"
sed '/GUARD:presyncread/d' "$WRAP" > "$T/wrap/noread.sh"; vr=$(wrap_clock "$T/wrap/noread.sh")
sed '/GUARD:synctime/d'    "$WRAP" > "$T/wrap/nosync.sh"; vs=$(wrap_clock "$T/wrap/nosync.sh")
awk '{L[NR]=$0; if(index($0,"GUARD:presyncread")) r=NR; if(index($0,"GUARD:synctime")) s=NR}
     END{for(i=1;i<=NR;i++){ if(i==r && s) print L[s]; if(i==s) continue; print L[i] }}' "$WRAP" > "$T/wrap/syncfirst.sh"
vo=$(wrap_clock "$T/wrap/syncfirst.sh")
m="noread=$(chg "$T/wrap/noread.sh") nosync=$(chg "$T/wrap/nosync.sh") syncfirst=$(chg "$T/wrap/syncfirst.sh")"
[ "$m" = "noread=1 nosync=1 syncfirst=2" ] || bad "T41 the defect copies are not minimal mutants ($m changed lines)"
[ "$vr" != ok ] && [ "$vs" != ok ] && [ "$vo" != ok ] \
  && ok "T41 SEEN TO FAIL: without the read '$vr'; without the sync '$vs'; synced before reading '$vo'" \
  || bad "T41 a defect copy passed (noread='$vr' nosync='$vs' syncfirst='$vo') - the check proves nothing"
# ...and the measurement SURVIVES INTO THE REPORT: a context.json carrying the wrapper's fields (the 2026-10-10
# numbers) lands in report.json context.guest_clock and on the summary's CLOCK line; knob presyncskew drops it.
cp -r "$T/base" "$T/presync"
python3 - "$T/presync/context.json" <<'PY'
import json, os, sys
p = sys.argv[1]
c = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {"source": "log-sweep-selftest.sh fixture presync"}
c["guest_clock"] = {"presync_guest_utc": "2026-10-10T10:59:54.1234567Z", "presync_host_utc": "2026-10-10T07:59:50Z",
                    "presync_skew_s": 10804, "postsync_guest_utc": "2026-10-10T07:59:53.0000000Z"}
json.dump(c, open(p, "w", encoding="utf-8"))
PY
rc=$(analyze "$SRC" "$T/presync" "$T/baseline.json" "$T/jev-expected.py" t41)
sk=$(field "$T/t41.json" "r['context']['guest_clock']['presync_skew_s']")
cl=$(grep -a '^CLOCK: pre-sync skew +10804 s' "$T/t41.txt" | head -1)
[ "$sk" = 10804 ] && [ -n "$cl" ] && ok "T41 presync_skew_s=$sk survives into report.json and the summary ($cl)" \
  || bad "T41 presync_skew_s='$sk' summary line '$cl' - the measured skew did not reach the report"
K=$(knob presyncskew); rc=$(analyze "$K" "$T/presync" "$T/baseline.json" "$T/jev-expected.py" t41k)
skk=$(field "$T/t41k.json" "r['context'].get('guest_clock')")
[ "$skk" = None ] && ok "T41 knob presyncskew: SEEN TO FAIL - the report drops the measurement (guest_clock=$skk)" \
  || bad "T41 knob presyncskew: guest_clock='$skk', want None - the case cannot be driven"
# ...and because the wrapper now writes context.json on EVERY run, a context.json that carries only the clock must
# declare nothing: the undeclared error line of newsig (T28) still breaches the gate through it.
cp -r "$T/newsig" "$T/clockonly"
python3 - "$T/clockonly/context.json" <<'PY'
import json, sys
json.dump({"source": "log-sweep-selftest.sh fixture clockonly",
           "guest_clock": {"presync_guest_utc": "2026-10-10T10:59:54.1234567Z", "presync_host_utc": "2026-10-10T07:59:50Z",
                           "presync_skew_s": 10804, "postsync_guest_utc": None}}, open(sys.argv[1], "w", encoding="utf-8"))
PY
rc=$(analyze "$SRC" "$T/clockonly" "$T/baseline.json" "$T/jev-expected.py" t41c)
uc=$(field "$T/t41c.json" "r['metrics']['error_lines_undeclared']"); bc=$(field "$T/t41c.json" "[x['metric'] for x in r['breaches']]")
if printf '%s' "$uc" | grep -qE '^[0-9]+$' && [ "$uc" -ge 1 ] && printf '%s' "$bc" | grep -q 'error_lines_undeclared'; then
  ok "T41 a context.json carrying only the clock declares nothing (undeclared=$uc still breaches)"
else bad "T41 clockonly: undeclared='$uc' breaches=$bc - the clock-only context.json silenced an undeclared error"; fi

# T42 the collector's cap: on its own default (60) a skip is a DATA failure, so the wrapper passes
# -MaxFiles "${LOGSWEEP_MAX_FILES:-N}" with N >= 400. Not re-graded: a skip under the raised cap still fails.
wrap_cap(){ # $1=wrapper -> "ok" or the reason
  local p n
  p=$(grep -a 'qtest pushrun mgmt/harness/log-sweep-collect.ps1' "$1" | head -1)
  [ -n "$p" ] || { echo "no collector pushrun"; return; }
  n=$(printf '%s' "$p" | grep -oE -- '-MaxFiles "\$\{LOGSWEEP_MAX_FILES:-[0-9]+\}"' | grep -oE '[0-9]+')
  [ -n "$n" ] || { echo "no -MaxFiles: the collector runs on its own default cap (60)"; return; }
  [ "$n" -ge 400 ] || { echo "-MaxFiles default $n is below 400"; return; }
  echo ok
}
v=$(wrap_cap "$WRAP")
[ "$v" = ok ] && ok "T42 the wrapper passes -MaxFiles \"\${LOGSWEEP_MAX_FILES:-N}\" (N >= 400) to the collector" \
              || bad "T42 mgmt/harness/log-sweep.sh: $v"
sed -E '/qtest pushrun mgmt\/harness\/log-sweep-collect\.ps1/ s/ -MaxFiles "\$\{LOGSWEEP_MAX_FILES:-[0-9]+\}"//' "$WRAP" > "$T/wrap/nocap.sh"
sed -E '/qtest pushrun mgmt\/harness\/log-sweep-collect\.ps1/ s/LOGSWEEP_MAX_FILES:-[0-9]+/LOGSWEEP_MAX_FILES:-60/' "$WRAP" > "$T/wrap/cap60.sh"
vn=$(wrap_cap "$T/wrap/nocap.sh"); v6=$(wrap_cap "$T/wrap/cap60.sh")
m="nocap=$(chg "$T/wrap/nocap.sh") cap60=$(chg "$T/wrap/cap60.sh")"
[ "$m" = "nocap=2 cap60=2" ] || bad "T42 the defect copies are not minimal mutants ($m changed lines)"
[ "$vn" != ok ] && [ "$v6" != ok ] \
  && ok "T42 SEEN TO FAIL: without the token '$vn'; with the collector's own default '$v6'" \
  || bad "T42 a defect copy passed (nocap='$vn' cap60='$v6') - the check proves nothing"

# ---- T43 the collector tells "could not read" from "filtered everything" -------------------------
# MEASURED 2026-10-10 on win10-acc, in TWO separate captures: the System channel reported
# "EV NONE [System]" while the EVENTS line said required_missing=- , so the sweep was blind to every
# shutdown marker (109/1074/6006) and every SCM record (7023/7024/7031/7034) and still reported itself
# complete. System is declared Required in the collector's own channel table. The collector needs a
# guest, so this is a shape check on its text, seen to fail on a copy with the guard removed.
COLL="$ROOT/mgmt/harness/log-sweep-collect.ps1"
coll_raw(){ # $1=collector -> "ok" or the reason
  command grep -aq 'GUARD:channelraw' "$1" || { echo "no raw-vs-kept guard"; return; }
  command grep -aq '\$raw = \$recs.Count' "$1" || { echo "the raw record count is never taken"; return; }
  command grep -aq 'raw -eq 0 -and \$ch.Required' "$1" || { echo "a required channel with no records at all is not flagged"; return; }
  command grep -aq 'EV NONE \[\$log\] raw=\$raw kept=0' "$1" || { echo "the NONE line does not carry raw/kept"; return; }
  echo ok
}
v=$(coll_raw "$COLL")
[ "$v" = ok ] && ok "T43 the collector distinguishes a channel it could not read from one whose filters dropped everything, and fails a REQUIRED channel that returned nothing" \
              || bad "T43 mgmt/harness/log-sweep-collect.ps1: $v"
mkdir -p "$T/coll"
sed '/raw -eq 0 -and \$ch.Required/d' "$COLL" > "$T/coll/noflag.ps1"; vn=$(coll_raw "$T/coll/noflag.ps1")
sed '/\$raw = \$recs.Count/d'        "$COLL" > "$T/coll/noraw.ps1";  vr=$(coll_raw "$T/coll/noraw.ps1")
m="noflag=$(diff "$COLL" "$T/coll/noflag.ps1" | grep -c '^[<>]') noraw=$(diff "$COLL" "$T/coll/noraw.ps1" | grep -c '^[<>]')"
[ "$m" = "noflag=1 noraw=1" ] || bad "T43 the defect copies are not minimal mutants ($m changed lines)"
[ "$vn" != ok ] && [ "$vr" != ok ] \
  && ok "T43 SEEN TO FAIL: without the flag '$vn'; without the raw count '$vr'" \
  || bad "T43 a defect copy passed (noflag='$vn' noraw='$vr') - the check proves nothing"


# --- T-CLOCK: A CHANNEL BOUNDARY IS NOT A CLOCK CORRECTION --------------------------------------
# detect_clock_offset's rule is "a backward jump between consecutive lines of ONE FILE, which
# nothing else here produces". That holds for a log with one writer appending in order. events.txt
# is several CHANNELS concatenated, each in its own time order, so every channel boundary is a
# backward jump of however far apart their windows are. MEASURED on win10-reinstall, acceptance run
# 38826875627: TerminalServices at 04:17:02 followed by TaskScheduler at 04:00:50 - a 972 s
# "correction" reported as a P1 on a guest whose pre-sync skew was THREE SECONDS. A corpus-wide
# scan found zero backward jumps over 600 s in any single-writer log. Re-measured with the fix, the
# real corpora went 960 -> 0 and 1260 -> 0, while win10-clean stayed 0.
python3 - <<'PYCLK'
import importlib.util, datetime, sys
spec = importlib.util.spec_from_file_location("ls", "tools/log-sweep.py")
m = importlib.util.module_from_spec(spec)
try: spec.loader.exec_module(m)
except SystemExit: pass
class L:
    def __init__(s, ts, log=None): s.ts = ts; s.extra = ({"log": log} if log else {})
class F:
    def __init__(s, lines): s.lines = lines
T = datetime.datetime(2026, 10, 16, 4, 0, 0)
d = datetime.timedelta
bad = 0
art = [L(T+d(seconds=1000), "ChanA"), L(T+d(seconds=1020), "ChanA"),
       L(T+d(seconds=50), "ChanB"),   L(T+d(seconds=70), "ChanB")]
v = m.detect_clock_offset([F(art)])
print(("  PASS  " if v == 0.0 else "  FAIL  ") + "a channel boundary is not a correction (got %s)" % v)
bad += (v != 0.0)
real = [L(T+d(seconds=1000), "ChanA"), L(T+d(seconds=20), "ChanA")]
v = m.detect_clock_offset([F(real)])
print(("  PASS  " if v >= 900 else "  FAIL  ") + "a real correction INSIDE a channel is still caught (got %s)" % v)
bad += (v < 900)
plain = [L(T+d(seconds=1000)), L(T+d(seconds=20))]
v = m.detect_clock_offset([F(plain)])
print(("  PASS  " if v >= 900 else "  FAIL  ") + "a real correction in a single-writer log is still caught (got %s)" % v)
bad += (v < 900)
# SEEN TO FAIL: the previous rule - one `prev` for the whole file - calls the artefact a correction
def old_rule(files):
    jumps = {}
    for lf in files:
        prev = None
        for l in lf.lines:
            if prev is not None:
                back = (prev - l.ts).total_seconds()
                if back > 600:
                    k = int(round(back/60.0)); jumps[k] = jumps.get(k, 0) + 1
            prev = l.ts
    return float(max(sorted(jumps), key=lambda k: (jumps[k], k)) * 60) if jumps else 0.0
v = old_rule([F(art)])
print(("  PASS  " if v > 0 else "  FAIL  ") + "SEEN TO FAIL: the old whole-file rule reports %s on that artefact" % v)
bad += (v <= 0)
sys.exit(1 if bad else 0)
PYCLK
if [ $? -eq 0 ]; then pass=$((pass+4)); else fail=$((fail+1)); fi

# --- dom0_lost: a RECOVERABLE handoff attempt is not a loss, a real loss still is ----------------
# MEASURED on win11-nfy 2026-10-16. "this message reaches nobody" is written at four sites, all in
# NotifyHandoffToSession, all returning false to a caller that falls through to ConnUp - and one of
# them breached notifications_lost at P1 one second before FWD_RTT ok=1 delivered the message.
# The opposite error is just as bad and was also live: `NOTIFY defer` was absent from DOM0_SEND_RE,
# so the deferral fix's own loss line ("cannot write ... notification LOST") counted as ZERO - a
# loss path added to the product with the gate for lost notifications blind to it.
python3 - "$ROOT/tools/log-sweep.py" <<'PYLOST'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class L:
    def __init__(s, msg): s.msg, s.level = msg, "W"
class F:
    name = "bridge.log"
    def __init__(s, msgs): s.lines = [L(x) for x in msgs]
CASES = [
 (0, "handoff no-user attempt",   "NOTIFY handoff: no user in session 2 - this message reaches nobody"),
 (0, "handoff no console session","NOTIFY handoff: no active console session - this message reaches nobody"),
 (0, "handoff schtasks /create",  "NOTIFY handoff: schtasks /create failed 2 - this message reaches nobody"),
 (0, "handoff schtasks /run",     "NOTIFY handoff: schtasks /run failed 2 - this message reaches nobody"),
 (1, "one-shot no connection",    "NOTIFY one-shot: no connection to dom0 - notification LOST summary=x"),
 (1, "defer queue write failed",  "NOTIFY defer: cannot write C:\\x - notification LOST summary=x"),
 (0, "deferred and queued",       "NOTIFY deferred: no route yet - queued as deferred-1.txt, the session bridge sends it summary=x"),
 (1, "death not notified",        "DEATH #1 NOT notified: qwt-notify-error.ps1 is missing"),
]
bad = 0
for want, label, msg in CASES:
    got = len(m.dom0_lost([F([msg])]))
    if got != want:
        print("FAIL dom0_lost %-26s want=%d got=%d" % (label, want, got)); bad += 1
sys.exit(1 if bad else 0)
PYLOST
if [ $? -eq 0 ]; then pass=$((pass+8)); else fail=$((fail+1)); fi

# --- dom0_loud: a run's OWN declared notifications do not count against it -----------------------
# MEASURED 2026-10-16 on win11-nfy: dom0_loud_failures breached at 6 (P1) and all six were toasts a
# suite fired on purpose - notify-errors-guest-test exists to put user-visible error notifications
# on the dom0 desktop and ends on a photograph of one. A P1 that fires on the test's own fixtures
# devalues the one signal built to be trusted. The exemption is the sanctioned one, from the same
# context.json channel error_lines_undeclared already honours, and declaring is not free:
# declared_errors_unmatched fails a declaration that matches nothing.
# THE PROPERTY THAT MATTERS: a declaration must NOT swallow a real product failure.
python3 - "$ROOT/tools/log-sweep.py" <<'PYLOUD'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("ls", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class L:
    def __init__(s, msg): s.msg, s.level, s.raw = msg, "E", msg
class F:
    def __init__(s, n, p): s.name, s.lines, s.family, s.path = n, [L(x) for x in p], "agent", None
REAL = "NOTIFY one-shot: sent ok=1 summary=The PV NIC setup task failed"
f = F("bridge.log", [
    "NOTIFY one-shot: sent ok=1 summary=gate default check",
    "NOTIFY one-shot: sent ok=1 summary=acceptance probe: a human should act",
    "NOTIFY one-shot: sent ok=1 summary=Render witness: a human should see this",
    "NOTIFY one-shot: sent ok=1 summary=deferproof-134310",
    REAL])
bad = 0
undeclared = len(m.dom0_loud([f]))
if undeclared != 5:
    print("FAIL dom0_loud with no declaration: want 5 got %d" % undeclared); bad += 1
rx = [re.compile(r"summary=(gate default check|acceptance probe|Render witness|deferproof-)")]
kept = [x for x in m.dom0_loud([f]) if not any(r.search(x[2]) for r in rx)]
if len(kept) != 1:
    print("FAIL declared run: want 1 loud left, got %d" % len(kept)); bad += 1
elif kept[0][2] != REAL:
    print("FAIL the surviving loud line is not the real product failure: %s" % kept[0][2]); bad += 1
sys.exit(1 if bad else 0)
PYLOUD
if [ $? -eq 0 ]; then pass=$((pass+3)); else fail=$((fail+1)); fi

# THE COUNT IS PRINTED AFTER THE LAST CHECK. It used to be emitted ~90 lines early, so every
# block below it added passes that were never reported - the suite under-stated its own size,
# ---- T53: A PER-DAY LOG SPANS BOOTS, AND THE RECORD MUST SAY WHICH -------------------------------------------------
# The owner, 2026-10-17: "we have log turnover issue when it is not recognized over reboots."
# What it cost: the file record published `pid` and `boot` from the LAST init, so
# network-setup-20261017.log read `pid 7852, boot 7` while holding pid 7700 in boot 6 AND pid 7852
# in boot 7. That record was taken at face value and two boots were written up as one - a whole
# line of investigation on a phantom. qrexec-wrapper-20261017.log is the extreme case: one process
# per CALL, 1344 lines, 144 pids, all published as a single pid and a single boot.
# Every number in the fixture is from run 38994277148's win11-upgrade capture, and the boot census
# here comes from System 6013 records - OUTSIDE the files under test - so this cannot pass by
# agreeing with itself.
rc=$(analyze "$SRC" "$T/turnover" "$T/baseline.json" "$T/jev-expected.py" t53)
_ns(){ field "$T/$1.json" "[f['boots'] for f in r['files'] if 'network-setup' in f['name']][0]"; }
_qd(){ field "$T/$1.json" "[f['boots'] for f in r['files'] if 'qubesdb-daemon' in f['name']][0]"; }
if [ "$(_ns t53)" = "[1, 2]" ] && [ "$(_qd t53)" = "[1, 2]" ]; then
  ok "T53a a per-day log spanning two boots reports BOTH"
else bad "T53a the boot span is wrong (network-setup=$(_ns t53) qubesdb=$(_qd t53), want [1, 2] and [1, 2])" "$(tail -3 "$T/t53.out")"; fi

# (b) AND THE SINGULAR FIELDS REFUSE TO GUESS: a consumer wanting one boot for a file that has two
# gets NULL, not the last one - which is the field that was misread.
if [ "$(field "$T/t53.json" "[f['boot'] for f in r['files'] if 'network-setup' in f['name']][0]")" = "None" ] \
   && [ "$(field "$T/t53.json" "[f['pid'] for f in r['files'] if 'network-setup' in f['name']][0]")" = "None" ]; then
  ok "T53b a file with two boots and two pids publishes neither as its one value"
else bad "T53b the file still claims one boot/pid for a file that spans two" "$(tail -2 "$T/t53.out")"; fi

# (c) RETIRED 2026-10-21 - the premise is no longer reachable. This drove GUARD:lineboot by
# requiring that the timestamp lookup loses the turnover. It stopped firing because TWO LATER FIXES
# to boot_for prevent the collapse independently: the forward allowance became derived
# (min(BOOT_TOL_S=45, half the gap to the next boot)) where it had been a flat 150 s, so the first
# init can no longer reach the next boot across this fixture's 69 s gap; and the phase correction
# tries both clock phases and prefers the boot a line FOLLOWS. Three shapes were built and none made
# the defect bite: a late init inside the forward allowance (the dist<0 tie-break saves it), a 3 h
# phase shift in either direction (the correction handles it), and a line with no timestamp (which
# IS misattributed, but the file's init records carry stamps so its boots set still holds both).
# Jev: premise_subsumed_by_later_fixes 0.64, retiring_it_loses_no_coverage 0.71.
# THE DEBT IS REAL AND RECORDED, not papered over: GUARD:lineboot now has NO leg that drives it, so
# replacing line_boot with the timestamp lookup would not be caught here. findings/issues.md carries
# that as LINEBOOTUNDRIVEN. T53a still asserts the property positively against the same fixture.

# (d) SEEN TO FAIL - pid reuse. GUARD:pidts drops the `c["ts"] <= l.ts` condition from the pid match,
# so the FIRST init carrying a pid wins. Windows reuses pids and this capture really does log pid
# 7604 in two different boots (uptime 24.00 s and 45.70 s); on the real data that knob lost a boot.
K=$(knob pidts); rc=$(analyze "$K" "$T/turnover" "$T/baseline.json" "$T/jev-expected.py" t53d)
if [ "$(_qd t53d)" != "[1, 2]" ]; then
  ok "T53d SEEN TO FAIL: one pid in two boots collapses when the first init wins (qubesdb=$(_qd t53d))"
else bad "T53d the pidts knob changed nothing - the guard is decoration" "qubesdb=$(_qd t53d)"; fi


# and a new case appended at the end (dom0_lost, 2026-10-16) moved the total by nothing.
# ---- T56 ONE PID IN TWO BOOTS IS TWO INSTANCES, and no tolerance decides it -------------------
# An instance is delimited by its OWN init record, so a reused pid cannot merge by being close
# enough in time - there is no window in it to widen. See the pidreuse fixture for the measurement.
pr(){ # $1=analyzer $2=tag -> "<agent_instances> <vchan_reconnects> <helper_relaunches>"
  python3 "$1" analyze "$T/pidreuse" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" > "$T/$2.out" 2>&1
  field "$T/$2.json" 'str(r["metrics"].get("agent_instances"))+" "+str(r["metrics"].get("vchan_reconnects"))+" "+str(r["metrics"].get("helper_relaunches"))'
}
read -r t56i t56v t56h <<<"$(pr "$SRC" t56)"
[ "$t56i" = 2 ] && ok "T56 one pid with two inits is TWO instances (agent_instances=$t56i)" \
                || bad "T56 agent_instances=$t56i, want 2 - the reused pid collapsed into one instance"
[ "$t56v" = 0 ] && ok "T56 its second boot's announce is NOT a lost daemon (vchan_reconnects=$t56v)" \
                || bad "T56 vchan_reconnects=$t56v, want 0 - a second boot's announce read as a reconnect"
[ "$t56h" = 0 ] && ok "T56 its second boot's helpers are NOT relaunches (helper_relaunches=$t56h)" \
                || bad "T56 helper_relaunches=$t56h, want 0 - a second boot's helpers read as relaunches"

# SEEN TO FAIL by the pre-fix rule itself rather than a new knob (Jev: not_needed 0.98). Keying on
# the pid alone is one sed away and reproduces the measured breach exactly.
PIDKEY="$T/log-sweep-pidkey.py"
sed -E 's|^( *)gen\[key\] = gen.get\(key, 0\) \+ 1$|\1gen[key] = 1|' "$SRC" > "$PIDKEY"
_nd=$(diff "$SRC" "$PIDKEY" | grep -c '^>')
if [ "$_nd" = 1 ] && python3 -m py_compile "$PIDKEY" >/dev/null 2>&1; then
  read -r p56i p56v p56h <<<"$(pr "$PIDKEY" t56k)"
  if [ "$p56i" = 1 ] && [ "$p56v" = 1 ]; then
    ok "T56 SEEN TO FAIL: keyed on the pid alone it is ONE instance with a phantom reconnect (instances=$p56i reconnects=$p56v relaunches=$p56h)"
  else
    bad "T56 the pre-fix rule did not reproduce the defect (instances=$p56i reconnects=$p56v relaunches=$p56h)"
  fi
else
  bad "T56 could not build the pre-fix variant - the sed changed $_nd line(s), want 1"
fi

# ---- T57 EVERY METRIC IS BUILD-SCOPED, not just the line-level ones -----------------------------
# THE THIRD TIME THIS CLASS WAS FOUND IN compute_metrics. T44/T54 scoped errors_during_requested_stop
# and stale_error_lines; T55 scoped the classification. dom0_loud_failures (P1, max 0) and
# helper_relaunches (P2, max 0) were still computed over the whole capture, and both were written
# ABOVE the block that establishes the scope - so the rule the comment there states could not reach
# them. MEASURED on the 4.3.37 release acceptance, win11-upgrade cell: both breached, the P1 on a
# notification the REPLACED build sent about ITS de-slice broker (the candidate carries the fix and
# emitted nothing), the P2 on a doubled WGCBROKER launch in the REPLACED build's one instance while
# both candidate instances launched it exactly once. Jev: conceals_real_error 0.15, scope_both 0.94.
# The scope now sits at the TOP of compute_metrics, so there is no position left that evades it.
tbm(){ # $1=analyzer $2=tag -> "<dom0_loud_failures> <helper_relaunches>"
  python3 "$1" analyze "$T/twobuild" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" > "$T/$2.out" 2>&1
  field "$T/$2.json" 'str(r["metrics"]["dom0_loud_failures"])+" "+str(r["metrics"]["helper_relaunches"])'
}
read -r t57l t57h <<<"$(tbm "$SRC" t57)"
# ONE, NOT ZERO: the build under test sends its own notification in this fixture, and it must still
# count. A zero here would mean the filter ate both sides and blinded the P1 on every run.
[ "$t57l" = 1 ] && ok "T57 the REPLACED build's dom0 notification is not billed to the candidate, and the candidate's own one still counts (dom0_loud_failures=$t57l)" \
                || bad "T57 dom0_loud_failures=$t57l, want 1 - one notification each side, only the predecessor's excluded"
[ "$t57h" = 0 ] && ok "T57 the REPLACED build's doubled helper launch is not a relaunch of the candidate (helper_relaunches=$t57h)" \
                || bad "T57 helper_relaunches=$t57h, want 0 - the candidate launched the broker once"
KL=$(knob loudpriorbuild); read -r t57lk _ <<<"$(tbm "$KL" t57kl)"
[ "$t57lk" = 2 ] && ok "knob loudpriorbuild: SEEN TO FAIL - unscoped, the predecessor's notification fails the candidate on a P1 (dom0_loud_failures=$t57lk)" \
                 || bad "knob loudpriorbuild: dom0_loud_failures=$t57lk, want 2 - the case cannot be driven"
KR=$(knob relpriorbuild); read -r _ t57hk <<<"$(tbm "$KR" t57kr)"
[ "$t57hk" = 1 ] && ok "knob relpriorbuild: SEEN TO FAIL - unscoped, the predecessor's second launch reads as the candidate relaunching a helper (helper_relaunches=$t57hk)" \
                 || bad "knob relpriorbuild: helper_relaunches=$t57hk, want 1 - the case cannot be driven"
# AND THE SINGLE-VERSION FIXTURE MUST BE UNTOUCHED: a filter that over-reaches zeroes a P1 on every
# ordinary cell, which reads exactly like a pass.
t57c=$(field "$T/t2.json" 'r["metrics"]["dom0_loud_failures"]')
[ -n "$t57c" ] && ok "T57 a one-build capture is unaffected by the scope (dom0_loud_failures=$t57c)" \
               || bad "T57 could not read dom0_loud_failures from the one-build report"

# ---- T58 A LOST "Log started" MUST NOT SLIDE THE NEXT INSTANCE'S UPTIME ONTO THE PREVIOUS ONE --
# See the nulhole fixture for the measurement. The uptime is the only init line that cannot be
# confused between instances, so a SECOND uptime in one record opens a new record there.
nh(){ # $1=analyzer $2=tag -> "<instances> <per_boot> <boots> <pid:boot,...>"
  python3 "$1" analyze "$T/nulhole" --baseline "$T/baseline.json" --out "$T/$2.json" \
      --summary "$T/$2.txt" --label "$2" --workdir "$T/work-$2" --jev-cmd "$T/jev-expected.py" > "$T/$2.out" 2>&1
  field "$T/$2.json" 'str(r["metrics"]["agent_instances"])+" "+str(r["metrics"]["agent_instances_per_boot"])+" "+str(r["metrics"]["boots"])+" "+",".join("%s:%s"%(i["pid"],i["boot"]) for i in r["instances"])'
}
read -r n58i n58p n58b n58m <<<"$(nh "$SRC" t58)"
[ "$n58i" = 2 ] && ok "T58 an init block with no 'Log started' is still its own instance (agent_instances=$n58i)" \
                || bad "T58 agent_instances=$n58i, want 2 - the lost line cost an instance"
[ "$n58p" = 1 ] && ok "T58 each instance is billed to ITS OWN boot, so the per-boot count stays 1 (=$n58p, boots=$n58b)" \
                || bad "T58 agent_instances_per_boot=$n58p, want 1 - the uptime slid onto the previous record (map $n58m)"
n58x=$(printf '%s' "$n58m" | tr ',' '\n' | cut -d: -f2 | sort -u | grep -ac .)
[ "$n58x" = 2 ] && ok "T58 the two instances map to DIFFERENT boots ($n58m)" \
                || bad "T58 instance->boot map is $n58m - both instances share a boot, which is the defect"
# SEEN TO FAIL BY REVERSING THE FIX IN A COPY, not by reading HEAD.
# The first version of this control ran `git show HEAD:tools/log-sweep.py` as "the previous
# analyzer" - and the moment the fix was committed, HEAD CONTAINED IT, so the control answered
# correctly and T58 failed for ever on code that is right. A negative control anchored on a moving
# ref rots the instant its own fix lands; that is the same class as a GUARD knob becoming
# decoration. The reversal below is pinned to the LINE THE FIX ADDED, exactly as T56 pins the
# pre-fix instance rule, and the suite refuses to grade if it does not change precisely one line.
PREV="$T/log-sweep-prefix.py"
sed -E 's|^( *)if not lf\.inits or lf\.inits\[-1\]\["uptime_s"\] is not None:$|\1if not lf.inits:|' "$SRC" > "$PREV"
_n58d=$(diff "$SRC" "$PREV" | grep -c '^>')
if [ "$_n58d" = 1 ] && python3 -m py_compile "$PREV" >/dev/null 2>&1; then
  read -r p58i p58p _ p58m <<<"$(nh "$PREV" t58prev)"
  if [ "$p58p" != 1 ] || [ "$p58i" != 2 ]; then
    ok "T58 SEEN TO FAIL with the fix reversed: the lost line mis-bills the instances (instances=$p58i per_boot=$p58p map=$p58m)"
  else
    bad "T58 the reversed analyzer gave the right answer too (instances=$p58i per_boot=$p58p) - the reversal no longer reaches the defect" "sed changed $_n58d line(s)"
  fi
else bad "T58 could not build the pre-fix variant - the sed changed $_n58d line(s), want 1" "the fix's line may have been reworded; re-pin the sed"; fi

# T59 A DECLARATION ORPHANED BY A LEVEL CHANGE IS NOT A NEW SIGNATURE.
# Signature keys are family|LEVEL|text. fc94490 (2026-10-10) deliberately lowered the A6LEAK
# by-design line from Warning to Info, with Jev over that site at defect 0.03 - and the baseline's
# two entries for it were keyed at W. They stopped matching, the line arrived as NEW, it was
# re-judged per campaign at 0.51 (one hundredth over the defect floor) and failed all three cells of
# campaign 20261018-010748. It then sat in the register for three days as a decision the owner owed.
# The fixture: a baseline that declares a line at W, and a log that emits the same text at I.
_t59txt='T59Stale: did a thing by design'
python3 - "$T/baseline.json" "$T/t59-baseline.json" "$_t59txt" <<'T59PY'
import json,sys
b=json.load(open(sys.argv[1]))
b.setdefault("signatures",{})["agent|I|%s" % sys.argv[3]] = {
    "status":"expected","reason":"declared at I, the level the product emits now; a predecessor build's copy of this line is still at W in the swept directory","max_per_boot":1,
    "family":"agent","level":"I"}
json.dump(b,open(sys.argv[2],"w"),indent=1)
T59PY
rc=$(analyze "$SRC" "$T/stalelvl" "$T/t59-baseline.json" "$T/jev-expected.py" t59)
_t59n=$(field "$T/t59.json" "len(r.get('stale_level') or [])")
if [ "${_t59n:-0}" -ge 1 ]; then
  ok "T59 a line declared at I and emitted at W is reported as a STALE DECLARATION (n=$_t59n)"
else
  bad "T59 the orphaned declaration was not reported (n=$_t59n, rc=$rc)" "it would be judged as a new signature, which is how one unchanged line failed three cells"
fi
_t59d=$(field "$T/t59.json" "[ (d['seen_level'],d['declared_level'],d['declared_status']) for d in (r.get('stale_level') or []) ]")
case "$_t59d" in *"'W'"*"'I'"*) ok "T59 and it names BOTH levels and the declared status ($_t59d)" ;;
  *) bad "T59 the report does not name both levels: $_t59d" ;; esac
if grep -qa 'STALE DECLARATIONS' "$T/t59.txt"; then
  ok "T59 the summary says so where a human reads it, before the NEW SIGNATURES list"
else
  bad "T59 the summary does not mention it" "the finding would die with the process that found it"
fi
# SEEN TO FAIL: with the detector's loop removed, the same run reports nothing.
_t59k="$T/t59-nodetect.py"
python3 - "$SRC" "$_t59k" <<'T59PY'
import re,sys
s=open(sys.argv[1]).read()
n=s.count("    for _s in new:\n")
s=s.replace("    for _s in new:\n", "    for _s in []:\n", 1)
open(sys.argv[2],"w").write(s)
print(n)
T59PY
if grep -qa 'for _s in \[\]:' "$_t59k"; then
  rc=$(analyze "$_t59k" "$T/stalelvl" "$T/t59-baseline.json" "$T/jev-expected.py" t59k)
  _k=$(field "$T/t59k.json" "len(r.get('stale_level') or [])")
  [ "${_k:-0}" = 0 ] \
    && ok "T59 SEEN TO FAIL: with the detector's loop emptied the orphan is invisible again (n=$_k)" \
    || bad "T59 the emptied detector still reported $_k" "the leg does not measure the detector"
else
  bad "T59 could not build the no-detector variant" "the substitution did not apply"
fi

# T59b A DECLARATION ORPHANED BY A REWORD IS NOT A NEW SIGNATURE EITHER.
# T59 covers the level change. This covers the reword, which is the half that actually failed a
# cell: WIN10-reinstall of campaign 40243956400 reported signatures_unclassified=1 and
# stale_level=0, because the detector T59 guards joins on IDENTICAL text at a DIFFERENT level and
# this rot is different text at the SAME level. The orphaned line was x1 against a declared
# max_per_boot of 1, so the cell would have passed had the declaration matched.
# The fixture declares the OLD prose. It is keyable because its tag comes with an interpolated
# `(class X)` field - the detector keys a declaration whose tag is QGA-prefixed OR which carries at
# least one interpolated field, and T59BTAG is deliberately NOT QGA-prefixed so this fixture
# exercises the field arm. The third leg below strips the field and shows the rot goes invisible,
# which is what stops that predicate being decoration.
_t59bold='UpdateWindowData: T59BTAG hwnd 0xH (class T59BClass) mapped UNCROPPED: the crop did not resolve within N ms'
python3 - "$T/baseline.json" "$T/t59b-baseline.json" "$_t59bold" <<'T59BPY'
import json,sys
b=json.load(open(sys.argv[1]))
s=b.setdefault("signatures",{})
s["agent|W|%s" % sys.argv[3]] = {
    "status":"expected","reason":"the PRE-REWORD wording; the product now says it differently","max_per_boot":1,
    "family":"agent","level":"W"}
# The tagless, fieldless case: only the FUNCTION is stable, and it is declared exactly once, which
# is the whole basis of the weaker arm. The fifth leg below makes it non-unique and shows it go dark.
s["agent|W|T59CSolo: did the old thing ANOTHER way entirely"] = {
    "status":"expected","reason":"the PRE-REWORD wording of a tagless line","max_per_boot":1,
    "family":"agent","level":"W"}
json.dump(b,open(sys.argv[2],"w"),indent=1)
T59BPY
rc=$(analyze "$SRC" "$T/stalewrd" "$T/t59b-baseline.json" "$T/jev-expected.py" t59b)
_t59bn=$(field "$T/t59b.json" "len(r.get('stale_text') or [])")
if [ "${_t59bn:-0}" -ge 1 ]; then
  ok "T59b a reworded line is reported as a STALE DECLARATION BY REWORD (n=$_t59bn)"
else
  bad "T59b the reworded declaration was not reported (n=$_t59bn, rc=$rc)" "it is judged a new signature, which is how WIN10-reinstall failed on a line within its own bound"
fi
_t59bd=$(field "$T/t59b.json" "[ (d['tag'],d['function'],d['declared_status'],d['declared_max_per_boot'],d['count']) for d in (r.get('stale_text') or []) ]")
case "$_t59bd" in *"'T59BTAG'"*"'UpdateWindowData'"*)
    ok "T59b and it names the tag, the function, and what the declaration ALLOWS ($_t59bd)" ;;
  *) bad "T59b the report does not name the tag/function/bound: $_t59bd" "the reader cannot tell whether the line was within its declared bound" ;; esac
if grep -qa 'STALE DECLARATIONS BY REWORD' "$T/t59b.txt"; then
  ok "T59b the summary says so where a human reads it, before the NEW SIGNATURES list"
else
  bad "T59b the summary does not mention it" "the finding would die with the process that found it"
fi
# It must NOT also fire the level detector - the two rots have opposite fixes and must stay apart.
_t59bl=$(field "$T/t59b.json" "len(r.get('stale_level') or [])")
[ "${_t59bl:-0}" = 0 ] \
  && ok "T59b and the LEVEL detector stays silent on a reword (stale_level=$_t59bl)" \
  || bad "T59b the level detector also fired ($_t59bl)" "a reword would be reported as a level change, whose fix is different"
# BOTH ARMS, AND EACH SAYING WHICH IT IS. The tag arm found the QGACROPLATE-shaped line; the
# weaker unique-function arm found the tagless one. They must not be reported identically: the
# weaker arm's false-positive rate is UNMEASURED (it never fired across the 24 gradeable campaign
# reports), because a function that legitimately gains a second line reports there too.
_t59bh=$(field "$T/t59b.json" "sorted(set(d.get('how') for d in (r.get('stale_text') or [])))")
case "$_t59bh" in *"'tag'"*"'unique-function'"*)
    ok "T59b both arms fired and each row says WHICH ($_t59bh)" ;;
  *) bad "T59b the arms are not both present/labelled: $_t59bh" "a same-function guess would read as a tag match" ;; esac
if grep -qa '\[unique-function\] T59CSolo' "$T/t59b.txt"; then
  ok "T59b and the summary labels the weaker arm inline, where a human reads it"
else
  bad "T59b the summary does not label the weaker arm" "$(grep -a 'T59CSolo' "$T/t59b.txt" | head -2)"
fi
# SEEN TO FAIL for the weaker arm specifically: give that function a SECOND declaration and it is
# no longer uniquely identified, so the arm must go dark while the tag arm keeps working.
python3 - "$T/t59b-baseline.json" "$T/t59b-dupfunc-baseline.json" <<'T59BPY'
import json,sys
b=json.load(open(sys.argv[1]))
s=b["signatures"]
solo=[k for k in s if "T59CSolo" in k]
assert len(solo)==1, "want exactly one T59CSolo declaration, found %d" % len(solo)
s["agent|W|T59CSolo: a second declared line from the same function at the same level"] = dict(s[solo[0]])
json.dump(b,open(sys.argv[2],"w"),indent=1)
T59BPY
rc=$(analyze "$SRC" "$T/stalewrd" "$T/t59b-dupfunc-baseline.json" "$T/jev-expected.py" t59bd)
_d=$(field "$T/t59bd.json" "sorted(set(d.get('how') for d in (r.get('stale_text') or [])))")
case "$_d" in *"unique-function"*)
    bad "T59b the weaker arm still fired on a non-unique function ($_d)" "it would join a new line to an unrelated declaration" ;;
  *"tag"*) ok "T59b SEEN TO FAIL: with that function declared twice the weaker arm goes dark, tag arm intact ($_d)" ;;
  *) bad "T59b both arms went dark ($_d)" "the duplicate declaration broke the tag arm too" ;; esac
# THE FALSE-POSITIVE CLASS THE SECOND ARM WOULD OTHERWISE CREATE, driven directly. A function that
# legitimately gains a SECOND log line is NOT rot: its original declaration is still matched by its
# original line. Jev put false_positive_risk at 0.70 on the widened detector, so the discriminator
# is "rot means the declaration matched NOTHING" - and here the declaration DOES match, so the new
# line must be reported as new and nothing must be called stale.
python3 - "$T/t59b-baseline.json" "$T/t59b-matched-baseline.json" <<'T59BPY'
import json,sys
b=json.load(open(sys.argv[1]))
s=b["signatures"]
solo=[k for k in s if "T59CSolo" in k]
assert len(solo)==1, "want exactly one T59CSolo declaration, found %d" % len(solo)
# Declare the wording the fixture ACTUALLY emits, so the declaration matches - while the function
# still has exactly one declaration, which is what the uniqueness arm keys on.
s["agent|W|T59CSolo: did the old thing one way"] = s.pop(solo[0])
json.dump(b,open(sys.argv[2],"w"),indent=1)
T59BPY
rc=$(analyze "$SRC" "$T/stalewrd" "$T/t59b-matched-baseline.json" "$T/jev-expected.py" t59bm)
_m=$(field "$T/t59bm.json" "[d['function'] for d in (r.get('stale_text') or [])]")
case "$_m" in *T59CSolo*)
    bad "T59b a MATCHED declaration was still called stale ($_m)" "every added log line in a one-declaration function would be reported as rot" ;;
  *) ok "T59b a declaration that MATCHED is never called stale, so a genuinely new line is not rot (rows: $_m)" ;; esac
# SEEN TO FAIL 1: the GUARD knob. With the detector's loop emptied, the same run reports nothing.
_t59bk="$T/t59b-nodetect.py"
python3 - "$SRC" "$_t59bk" <<'T59BPY'
import sys
s=open(sys.argv[1]).read()
old="    for _sn in new:   # GUARD:staletext DEFECT: for _sn in []:\n"
assert s.count(old)==1, "GUARD:staletext line not unique (%d) - re-pin this leg" % s.count(old)
open(sys.argv[2],"w").write(s.replace(old,"    for _sn in []:\n",1))
T59BPY
if grep -qa 'for _sn in \[\]:' "$_t59bk"; then
  rc=$(analyze "$_t59bk" "$T/stalewrd" "$T/t59b-baseline.json" "$T/jev-expected.py" t59bk)
  _k=$(field "$T/t59bk.json" "len(r.get('stale_text') or [])")
  [ "${_k:-0}" = 0 ] \
    && ok "T59b SEEN TO FAIL: with the detector's loop emptied the reword is invisible again (n=$_k)" \
    || bad "T59b the emptied detector still reported $_k" "the leg does not measure the detector"
else
  bad "T59b could not build the no-detector variant" "the GUARD:staletext substitution did not apply"
fi
# SEEN TO FAIL 2: the keyability predicate. Strip the interpolated `(class X)` from the declared
# entry and - its tag not being QGA-prefixed - nothing in the baseline is keyable any more, so the
# same rot goes unreported. That is what makes the predicate load-bearing rather than a comment.
python3 - "$T/t59b-baseline.json" "$T/t59b-noqga-baseline.json" <<'T59BPY'
import json,sys
b=json.load(open(sys.argv[1]))
s=b["signatures"]
hit=[k for k in s if "T59BTAG" in k]
assert len(hit)==1, "want exactly one T59BTAG declaration, found %d" % len(hit)
new=hit[0].replace(" (class T59BClass)","")
assert new!=hit[0], "the field strip changed nothing; re-pin it to the fixture's wording"
s[new]=s.pop(hit[0])
json.dump(b,open(sys.argv[2],"w"),indent=1)
T59BPY
if [ -s "$T/t59b-noqga-baseline.json" ]; then
  # The assertion is on THAT line, not on the whole report: the shared fixture baseline carries
  # other agent declarations whose functions are unique, so demanding global silence would be
  # asserting something this mutation cannot produce - which is how the first cut of this leg
  # failed. T59BTAG's tag is not QGA-prefixed, so with its field stripped nothing keys it.
  rc=$(analyze "$SRC" "$T/stalewrd" "$T/t59b-noqga-baseline.json" "$T/jev-expected.py" t59bq)
  _q=$(field "$T/t59bq.json" "[d['function'] for d in (r.get('stale_text') or []) if d.get('how')=='tag']")
  case "$_q" in *UpdateWindowData*)
      bad "T59b the unkeyable declaration was still joined by the tag arm ($_q)" "the keyability predicate is decoration - any uppercase word anywhere would act as a tag" ;;
    *) ok "T59b SEEN TO FAIL: with the interpolated field stripped, its non-QGA tag keys nothing and the tag arm does not join it (tag-arm functions: $_q)" ;; esac
else
  bad "T59b could not build the unkeyable baseline" "the field strip did not apply"
fi
# ZERO COVERAGE MUST ANNOUNCE ITSELF, because it looks exactly like zero rot - that is how a
# detector becomes decoration without anyone noticing. This needs a baseline that keys NOTHING, so
# it is built explicitly rather than mutated: one declaration with no `Function: ` prefix at all.
python3 - "$T/t59b-baseline.json" "$T/t59b-blind-baseline.json" <<'T59BPY'
import json,sys
b=json.load(open(sys.argv[1]))
b["signatures"]={"plain|W|a declaration with no Function prefix, so nothing can be keyed on it":
                 {"status":"expected","reason":"keys nothing: no Function: prefix, no tag, no field",
                  "max_per_boot":1,"family":"plain","level":"W"}}
b.pop("patterns",None)
json.dump(b,open(sys.argv[2],"w"),indent=1)
T59BPY
rc=$(analyze "$SRC" "$T/stalewrd" "$T/t59b-blind-baseline.json" "$T/jev-expected.py" t59bz)
_zi=$(field "$T/t59bz.json" "((r.get('stale_text_index') or {}).get('identities'), (r.get('stale_text_index') or {}).get('unique_function_keys'), len(r.get('stale_text') or []))")
if [ "$_zi" = "(0, 0, 0)" ] && grep -qa 'REWORD DETECTOR COVERS NOTHING' "$T/t59bz.txt"; then
  ok "T59b and a run that can key NOTHING announces it (identities,unique,rows=$_zi), so the silence is not read as clean"
else
  bad "T59b zero coverage was silent or non-zero ($_zi)" "a detector covering nothing reports exactly like a detector finding nothing"
fi
# The covered run must NOT carry that announcement, or it is noise rather than a signal.
if grep -qa 'REWORD DETECTOR COVERS NOTHING' "$T/t59b.txt"; then
  bad "T59b the covered run also announced zero coverage" "the announcement does not discriminate"
else
  _ci=$(field "$T/t59b.json" "((r.get('stale_text_index') or {}).get('identities'), (r.get('stale_text_index') or {}).get('unique_function_keys'))")
  ok "T59b and a covered run does not announce it (identities,unique=$_ci)"
fi

# T60 EVERY GATED PER-INSTANCE METRIC IS BUILD-SCOPED, asserted structurally because the defect
# class is "the next one gets added unscoped and nothing says so".
#
# compute_metrics has grown this defect FOUR times. Its own comment used to promise it could not
# recur - "There is no position left in this function from which the scope is unreachable, so the
# next metric cannot repeat it" - and that promise is part of why nobody looked: REACHABLE IS NOT
# USED. errors_during_requested_stop and stale_error_lines were the first two, helper_relaunches
# the third, and on 2026-10-23 an audit found agent_ends_unrecorded, requested_stop_nonzero_exit
# and vchan_announce_without_connect all still unscoped. agent_ends_unrecorded was failing
# win11-upgrade at 1 (max 0) on pid 5256 declaring 4.3.35.795 - the ENTRY FIXTURE's agent, stopped
# by the MSI during the in-place upgrade - while both candidate instances were fine. Scoping it took
# that real capture from BREACHES (1; P1 0) to BREACHES (0; P1 0).
#
# A per-instance metric is one whose comprehension iterates insts/inst; GATED means it has a `max`
# in the thresholds. Line-level metrics are out of scope here: they carry _prior/_unattrib instead,
# a different predicate for a different question.
t60_scan(){ # $1=analyzer -> prints the gated per-instance metrics that LACK _inst_prior, and a count
  local f="$1" ln m bad="" n=0
  while IFS= read -r ln; do
    m=$(printf '%s\n' "$ln" | sed -n 's/.*m\["\([a-z_][a-z_]*\)"\].*/\1/p')
    [ -n "$m" ] || continue
    command grep -q "\"$m\": {\"max\":" "$f" || continue
    n=$((n+1))
    printf '%s\n' "$ln" | command grep -q '_inst_prior' || bad="$bad $m"
  done <<T60IN
$(command grep -E 'm\["[a-z_]+"\] *= *len\(\[i for i in (inst|insts)' "$f")
T60IN
  printf '%s|%s' "$n" "$bad"
}
t60=$(t60_scan "$SRC"); t60_n=${t60%%|*}; t60_bad=${t60#*|}
if [ "${t60_n:-0}" -lt 3 ]; then
  bad "T60 found only ${t60_n:-0} gated per-instance metric(s)" "the extraction stopped matching - it would pass on anything"
elif [ -z "$t60_bad" ]; then
  ok "T60 all $t60_n gated per-instance metrics are build-scoped (_inst_prior)"
else
  bad "T60 gated per-instance metric(s) not build-scoped:$t60_bad" "an instance of the REPLACED build is charged to the candidate - this has happened four times"
fi
# SEEN TO FAIL: strip the predicate from one of them and the leg must name that one.
t60_v="$T/ls-unscoped.py"
sed 's/if not _inst_prior(i) and i\["stop"\]/if i["stop"]/' "$SRC" > "$t60_v"
if command grep -qE 'm\["requested_stop_nonzero_exit"\] *= *len\(\[i for i in insts if i\["stop"\]' "$t60_v"; then
  t60v=$(t60_scan "$t60_v"); t60v_bad=${t60v#*|}
  case "$t60v_bad" in
    *requested_stop_nonzero_exit*) ok "T60 SEEN TO FAIL: with the predicate stripped the leg names requested_stop_nonzero_exit" ;;
    *) bad "T60 the unscoped variant was not caught (bad='$t60v_bad')" "the leg does not measure the predicate" ;;
  esac
else
  bad "T60 could not build the unscoped variant" "the substitution did not apply"
fi

echo "--- $pass passed, $fail failed; fixtures/outputs in $T"
[ "$fail" = 0 ] && exit 0 || exit 1
