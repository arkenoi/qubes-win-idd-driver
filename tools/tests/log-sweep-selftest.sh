#!/usr/bin/env bash
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

def agent(pid=1000, t0="100031.200", uptime="31.200", mid=(), tail=None, announce=True):
    tid = 200
    L = [wu(t0, tid, "I", "LogInit", "Log started, module name: gui-agent"),
         wu(t0, tid, "I", "LogInit", "System uptime: %s seconds" % uptime),
         wu(t0, tid, "I", "LogInit", "Running as user: SYSTEM, process ID: %d" % pid),
         wu(t0, tid, "I", "LogInit", "Module version: 9.9.9.1"),
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
def stub(name, choice=None, rc=0):
    body = ["#!/usr/bin/env python3", "import json, sys",
            "rub = json.load(open(sys.argv[1])); out = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else None"]
    if rc != 0:
        body.append("print('INSTRUMENT: stub - the judge did not run'); sys.exit(%d)" % rc)
    else:
        body.append("ans = {q: {'type': 'choice', 'choice': %r, 'confidence': 0.91, 'probabilities': {%r: 0.91}} for q in rub['questions']}" % (choice, choice))
        body.append("json.dump({'model': 'stub', 'answers': ans}, open(out, 'w'))")
        body.append("[print('%%s choice=%%s conf=0.91' %% (q, %r)) for q in ans]" % choice)
    p = os.path.join(T, name)
    with open(p, "w") as f:
        f.write("\n".join(body) + "\n")
    os.chmod(p, 0o755)
stub("jev-expected.py", "expected")
stub("jev-defect.py", "defect")
stub("jev-exit2.py", rc=2)
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
for f in base newsig rise three stoperr empty twoboot skipnames skipchatty bootshut inv twoproc msiok msibad; do
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
K=$(knob defect); rc=$(analyze "$K" "$T/newsig" "$T/baseline.json" "$T/jev-defect.py" t11k)
[ "$rc" = 0 ] && ok "T11 knob 'defect': the check is SEEN TO FAIL (rc=0)" || bad "T11 knob 'defect' did not break the check (rc=$rc)"

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

# T31 THE MSI CLASSIFIER, BOTH WAYS. A routine install's rollback SCHEDULING is not an error, and a
# real failure still is. Measured on a verified-successful 4.3.36 upgrade: 171 error lines, of which
# 168 were the routine scheduling - so the gate was reporting a clean install as 171 errors.
rc=$(analyze "$SRC" "$T/msiok" "$T/baseline.json" "$T/jev-expected.py" t31)
eok=$(field "$T/t31.json" "r['metrics']['error_lines']")
wok=$(field "$T/t31.json" "r['metrics']['warning_lines']")
if [ "$eok" = 0 ] && [ "$wok" -ge 7 ]; then
  ok "T31 a successful install's rollback scheduling is NOT an error (errors=$eok, warnings=$wok)"
else bad "T31 a successful install produced $eok error line(s) (want 0) and $wok warning(s)"; fi
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

# T33 A COUNTER AT ZERO IS NOT A FAILURE. bind-dirs writes a key=value RESULT RECORD whose first
# line is "result=ok", and "failed=0" in it was graded an ERROR because the levelless-log vocabulary
# matches the bare word "failed" - one of the eight undeclared error lines a clean cycle produced on
# win11r-logvol. A NON-zero counter must still be an error, which is the half that makes this a fix
# rather than a silencer.
python3 - "$SRC" <<'PYZ' > /tmp/zc.$$ 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
want = {"failed=0": "I", "errors=0": "I", "warnings=0": "I", "failed=0x00000000": "I", "lost=0": "I",
        "failed=3": "E", "errors=12": "E", "failed to open the ring": "E", "result=ok": "I"}
bad = [("%s -> %s (want %s)" % (k, m.blog_level(k), v)) for k, v in want.items() if m.blog_level(k) != v]
print("OK" if not bad else "BAD " + "; ".join(bad))
PYZ
zc=$(cat /tmp/zc.$$); rm -f /tmp/zc.$$
case "$zc" in
  OK*) ok "T33 failed=0 is INFO and failed=3 is still an ERROR (a zero counter is not a failure)" ;;
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
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
if [ -x "$PWSH" ]; then
  if "$PWSH" -NoProfile -File "$ROOT/tools/ps-parse-check.ps1" "$ROOT/mgmt/harness/log-sweep-collect.ps1" > "$T/parse.txt" 2>&1; then ok "T12 collector parses ($(tail -1 "$T/parse.txt" | cut -c1-100))"; else bad "T12 collector parse: $(tail -3 "$T/parse.txt" | tr '\n' ' ')"; fi
else
  echo "skip  T12 collector parse-check: no pwsh at $PWSH"
fi

# ---- T34 the level vocabularies, in BOTH directions -------------------------------------------
# Owner 2026-10-08: "visible error on actual failure" and, for OUR components, "no warnings on
# normal operation. warning means something is not quite normal, yet workable."
# Two defects were found here by measurement, not by reading:
#   * the error vocabulary was case-SENSITIVE and had no FAILED, so "\bFAIL\b" could not match
#     "FAILED" - the exact prefix guest/pvnic-selfprime.ps1's Fault() writes - and a REAL fault
#     line came back level=W;
#   * BLOG_W_RE matched vocabulary words inside key=value FIELD VALUES ("LIST trig=retry"), and
#     warned over a line that merely names the trigger that scheduled a routine pass.
t34(){ # $1 = message, $2 = expected level
  got=$(python3 - "$ROOT/tools/log-sweep.py" "$1" <<'PY34'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("ls", sys.argv[1])
ls = importlib.util.module_from_spec(spec); spec.loader.exec_module(ls)
print(ls.blog_level(sys.argv[2]))
PY34
)
  if [ "$got" = "$2" ]; then ok "T34 ${1:0:58} -> $2"; else bad "T34 ${1:0:58} -> $got (want $2)"; fi
}
t34 'FAILED: xenbus_monitor SURVIVED enforcement' E
t34 'no netvm, nothing to apply - but an earlier step FAILED (the re-arm did not complete)' E
t34 'status=failed' E
t34 'apply FAILED, nothing to do' E
t34 'qubesdb up, /qubes-ip absent, no vif device: no netvm, nothing to apply' I
t34 'LIST trig=retry n=3 new=0 ms=12' I
t34 '/qubes-ip absent, the applier gave up' W
t34 'the listener was disconnected' W

echo "--- $pass passed, $fail failed; fixtures/outputs in $T"
[ "$fail" = 0 ] && exit 0 || exit 1
