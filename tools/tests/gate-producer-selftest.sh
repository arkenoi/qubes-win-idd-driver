#!/bin/bash
# gate-producer-selftest.sh - make the never-fired gates FIRE.
#
# WHY THIS EXISTS. tools/log-sweep.py gates 33 metrics. On 2026-10-15 an audit found 14 of them not
# mentioned by any offline test at all, so no fixture anywhere could make them non-zero - and all 14
# are live code, computed every run and compared to a threshold. That is the DOM0LOUDNEVERFIRES
# shape: a counter nobody has seen fire, reporting 0, where 0 reads as a pass. dom0_loud_failures
# had been P1 with max 0 and structurally unable to see an INFO send for as long as it existed, and
# the suite covering it was green throughout because it asserted the wrong thing on purpose.
#
# A detector nobody has seen fire is not evidence. So each check below plants a line or an event
# that SHOULD trip one gate, and requires the metric to rise ABOVE its threshold. A gate that cannot
# be made to fire here is the finding, not a test bug - it means the metric cannot see its own
# subject, and it must be reported as such rather than quietly dropped.
#
# SCOPE. Ten of the fourteen are driven here - every event-driven and line-driven one, which is the
# whole death-and-crash family. The remaining four need multi-instance agent structure to exist
# (vchan_setups_per_shutdown, agent_ends_unrecorded, helper_relaunches,
# watchdog_fast_death_backoffs); they are NOT covered yet and stay listed in SWEEPGATESNOPRODUCER.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
SRC="$ROOT/tools/log-sweep.py"
T="$(mktemp -d "${TMPDIR:-/tmp}/gateprod-XXXXXX")"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){   printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad(){  printf 'FAIL %s   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
ck(){ # $1=name $2=want $3=got
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want=$2 got=$3"; fi; }

python3 - "$T" <<'PYGEN'
import base64, hashlib, os, sys
T = sys.argv[1]

def block(name, lines):
    text = "\n".join(lines); data = text.encode("utf-8")
    b64 = base64.b64encode(data).decode()
    chunks = [b64[i:i+76] for i in range(0, len(b64), 76)]
    out = ["LSW PULL name=%s lines=%d bytes=%d sha256=%s b64lines=%d" %
           (name, len(lines), len(data), hashlib.sha256(data).hexdigest(), len(chunks))]
    out += ["LSW B|" + c for c in chunks]
    out.append("LSW PULLEND name=%s b64lines=%d" % (name, len(chunks)))
    return out

def stream(files, ev):
    S = ["Microsoft Windows [Version 10.0.26300.9457]", "(c) Microsoft Corporation. All rights reserved.", "",
         "C:\\Windows\\System32>powershell -NoProfile -File log-sweep-collect.ps1",
         "LSW BEGIN v=1 now=2026-10-07T10:20:00.000 nowutc=2026-10-07T10:20:00.000Z tz=+00:00 "
         "host=RklYVFVSRQ== user=U1lTVEVN session=0 since=2026-10-07T09:00:00Z sincelocal=2026-10-07T09:00:00.000",
         "LSW LOGDIR pathb64=%s exists=1" % base64.b64encode(b"Q:\\Qubes Logs").decode()]
    for n, (name, fam, lines) in enumerate(files, 1):
        p = base64.b64encode(("Q:\\Qubes Logs\\" + name).encode()).decode()
        S.append("LSW FILE id=f%d pathb64=%s family=%s bytes=%d lines=%d written=2026-10-07T10:10:00.500 "
                 "created=2026-10-07T10:00:30.000 partial=0 total_lines=%d" %
                 (n, p, fam, len("\n".join(lines).encode()), len(lines), len(lines)))
        S += block("f%d" % n, lines)
    S.append("LSW EVENTS channels=4 required_missing=-")
    S += block("events", ev)
    S.append("LSW END files=%d pulled=%d errors=0 event_errors=0" % (len(files), len(files)))
    S += ["", "C:\\Windows\\System32>"]
    return S

def write(name, lines):
    with open(os.path.join(T, name), "w", encoding="utf-8") as f:
        f.write("\r\n".join(lines) + "\r\n")

WD = "gui-watchdog-20261007-100030-700.log"
AG = "gui-agent-20261007-100031-1000.log"
def L(ts, lvl, mod, msg): return "[20261007.%s.000-1000-%s] %s: %s" % (ts, lvl, mod, msg)

# The agent log carries the LINE-driven subjects. Each line is planted for exactly one gate.
agent = [
    L("100031", "I", "Init", "agent starting"),
    # fallbacks_fired: the project rule is that a fallback firing is an anomaly, logged and diagnosed
    L("100100", "W", "Capture", "no direct path for hwnd 0x31; falling back to the composite path"),
    # stale_error_lines: STALE_ERR_RE is literally "failed with error 0x0"
    L("100130", "E", "Qrexec", "QubesDB write failed with error 0x0 - the call reports failure and success at once"),
    # handshake_refusals
    L("100200", "W", "Gui", "QGAHANDSHAKE refused: protocol version mismatch (0:0)"),
    # helper_deaths: HELPER_DEATH_RE
    L("100230", "E", "Notif", "QGANOTIFBRIDGEEXIT bridge exited rc=1"),
    L("100300", "I", "Init", "agent steady"),
]
watchdog = [
    L("100030", "I", "Watchdog", "watchdog starting"),
    L("100330", "I", "Watchdog", "requested stop: exit 0x0"),
]

def EV(ts, log, eid, lvl, prov, msg):
    return "EV 2026-10-07 %s [%s] id=%d level=%d %s: %s" % (ts, log, eid, lvl, prov, msg)

events = [
    EV("09:59:00.000", "System", 6005, 4, "EventLog", "The Event log service was started."),
    # service_failures: SCM 7034 naming one of OUR services (QdbDaemon is in OUR_SERVICES_RE)
    EV("10:01:00.000", "System", 7034, 2, "Service Control Manager",
       "The QdbDaemon service terminated unexpectedly.  It has done this 1 time(s)."),
    # wer_crashes: Application 1000 naming one of OUR executables
    EV("10:02:00.000", "Application", 1000, 2, "Application Error",
       "Faulting application name: gui-agent.exe, version 4.3.36.0, faulting module: ntdll.dll"),
    # death_events: provider "Qubes Windows Tools", id 4001-4004.  death_record_mismatch too: this
    # names gui-agent.exe with a pid no watchdog death line corroborates within 5 s.
    # The message text is EV4001_RE's exact shape, copied from the pattern the supervisor writes -
    # the first version of this fixture invented "gui-agent.exe (pid 4242) died with ...", which
    # parsed to exe="?" and left death_record_mismatch at 0. A fixture that does not carry the real
    # shape measures nothing, and it looked like a passing gate.
    EV("10:03:00.000", "Application", 4001, 2, "Qubes Windows Tools",
       "(gui-agent.exe, PID 4242) exited without being asked to - exit code 0xc0000005"),
    # unexpected_shutdowns: System 6008
    EV("10:04:00.000", "System", 6008, 2, "EventLog",
       "The previous system shutdown at 10:03:30 on 2026-10-07 was unexpected."),
    # bugchecks: System 1001 whose PROVIDER carries BugCheck - event_wanted keys on the provider
    # string, so this fixture also measures whether that is the field a real record would fill.
    EV("10:05:00.000", "System", 1001, 2, "BugCheck",
       "The computer has rebooted from a bugcheck.  The bugcheck was: 0x0000001e"),
    EV("10:19:00.000", "System", 1074, 4, "User32",
       "The process shutdown.exe has initiated the power off of computer WIN-IDD-TEST"),
]
write("gates.pull", stream([(WD, "watchdog", watchdog), (AG, "agent", agent)], events))
PYGEN
[ -f "$T/gates.pull" ] || { echo "FATAL: fixture not generated"; exit 2; }

python3 "$SRC" decode "$T/gates.pull" --out "$T/logs" > "$T/decode.txt" 2>&1
rc=$?
[ "$rc" = 0 ] || { echo "FATAL: the fixture did not decode (rc=$rc): $(tail -3 "$T/decode.txt")"; exit 2; }

echo '{"thresholds": {}}' > "$T/baseline.json"
python3 "$SRC" analyze "$T/logs" --baseline "$T/baseline.json" --out "$T/r.json" \
        --summary "$T/r.txt" --label gates --workdir "$T/work" > "$T/analyze.out" 2>&1
[ -f "$T/r.json" ] || { echo "FATAL: no report produced: $(tail -5 "$T/analyze.out")"; exit 2; }

mv(){ python3 -c "
import json,sys
r=json.load(open('$T/r.json'))
m=r.get('metrics') or {}
print(m.get(sys.argv[1], 'ABSENT'))
" "$1"; }
fired(){ # $1=metric -> yes if strictly positive
  v=$(mv "$1"); case "$v" in ''|ABSENT|0|0.0) echo "no($v)" ;; *) echo yes ;; esac; }

echo "--- metrics this corpus produced"
for g in service_failures wer_crashes death_events death_record_mismatch unexpected_shutdowns \
         bugchecks fallbacks_fired stale_error_lines handshake_refusals helper_deaths; do
  printf '     %-26s %s\n' "$g" "$(mv "$g")"
done

# EACH GATE MUST RISE. A "no" here is a FINDING: the metric cannot see its own subject.
ck "service_failures fires on an SCM 7034 for one of our services"      yes "$(fired service_failures)"
ck "wer_crashes fires on an Application 1000 for one of our exes"       yes "$(fired wer_crashes)"
ck "death_events fires on a Qubes Windows Tools 4001"                   yes "$(fired death_events)"
ck "death_record_mismatch fires on a 4001 with no watchdog line"        yes "$(fired death_record_mismatch)"
ck "unexpected_shutdowns fires on a System 6008"                        yes "$(fired unexpected_shutdowns)"
ck "bugchecks fires on a System 1001 BugCheck"                          yes "$(fired bugchecks)"
ck "fallbacks_fired fires on a 'falling back to' line"                  yes "$(fired fallbacks_fired)"
ck "stale_error_lines fires on 'failed with error 0x0'"                 yes "$(fired stale_error_lines)"
ck "handshake_refusals fires on a QGAHANDSHAKE line"                    yes "$(fired handshake_refusals)"
ck "helper_deaths fires on a QGANOTIFBRIDGEEXIT line"                   yes "$(fired helper_deaths)"

# AND THE GATE MUST ACTUALLY BREACH, not merely count: a metric that rises without being compared
# to its threshold is the same silence in a different place.
br=$(python3 -c "
import json
r=json.load(open('$T/r.json'))
want={'service_failures','wer_crashes','death_events','unexpected_shutdowns','bugchecks',
      'fallbacks_fired','stale_error_lines','handshake_refusals','helper_deaths','death_record_mismatch'}
got={b['metric'] for b in r.get('breaches',[])}
print(len(want&got))
")
ck "all ten planted gates are reported as BREACHES, not just counted" 10 "$br"

# SEEN TO FAIL: the same analyzer over a corpus with none of those lines or events must leave every
# one of the ten at zero. Without this the checks above could be passing on something else.
python3 - "$T" <<'PYQUIET'
import base64, hashlib, os, sys
T = sys.argv[1]
def block(name, lines):
    text="\n".join(lines); data=text.encode("utf-8")
    b64=base64.b64encode(data).decode(); chunks=[b64[i:i+76] for i in range(0,len(b64),76)]
    out=["LSW PULL name=%s lines=%d bytes=%d sha256=%s b64lines=%d"%(name,len(lines),len(data),hashlib.sha256(data).hexdigest(),len(chunks))]
    out+=["LSW B|"+c for c in chunks]; out.append("LSW PULLEND name=%s b64lines=%d"%(name,len(chunks))); return out
def stream(files, ev):
    S=["LSW BEGIN v=1 now=2026-10-07T10:20:00.000 nowutc=2026-10-07T10:20:00.000Z tz=+00:00 "
       "host=RklYVFVSRQ== user=U1lTVEVN session=0 since=2026-10-07T09:00:00Z sincelocal=2026-10-07T09:00:00.000",
       "LSW LOGDIR pathb64=%s exists=1"%base64.b64encode(b"Q:\\Qubes Logs").decode()]
    for n,(name,fam,lines) in enumerate(files,1):
        p=base64.b64encode(("Q:\\Qubes Logs\\"+name).encode()).decode()
        S.append("LSW FILE id=f%d pathb64=%s family=%s bytes=%d lines=%d written=2026-10-07T10:10:00.500 "
                 "created=2026-10-07T10:00:30.000 partial=0 total_lines=%d"%(n,p,fam,len("\n".join(lines).encode()),len(lines),len(lines)))
        S+=block("f%d"%n,lines)
    S.append("LSW EVENTS channels=4 required_missing=-"); S+=block("events",ev)
    S.append("LSW END files=%d pulled=%d errors=0 event_errors=0"%(len(files),len(files))); return S
def L(ts,lvl,mod,msg): return "[20261007.%s.000-1000-%s] %s: %s"%(ts,lvl,mod,msg)
agent=[L("100031","I","Init","agent starting"), L("100300","I","Init","agent steady")]
watchdog=[L("100030","I","Watchdog","watchdog starting"), L("100330","I","Watchdog","requested stop: exit 0x0")]
events=["EV 2026-10-07 09:59:00.000 [System] id=6005 level=4 EventLog: The Event log service was started.",
        "EV 2026-10-07 10:19:00.000 [System] id=1074 level=4 User32: The process shutdown.exe has initiated the power off of computer WIN-IDD-TEST"]
open(os.path.join(T,"quiet.pull"),"w",encoding="utf-8").write("\r\n".join(stream([(("gui-watchdog-20261007-100030-700.log"),"watchdog",watchdog),(("gui-agent-20261007-100031-1000.log"),"agent",agent)],events))+"\r\n")
PYQUIET
python3 "$SRC" decode "$T/quiet.pull" --out "$T/qlogs" > "$T/qdecode.txt" 2>&1
python3 "$SRC" analyze "$T/qlogs" --baseline "$T/baseline.json" --out "$T/q.json" \
        --summary "$T/q.txt" --label quiet --workdir "$T/qwork" > "$T/qanalyze.out" 2>&1
qz=$(python3 -c "
import json
try: r=json.load(open('$T/q.json'))
except Exception as e: print('NOREPORT'); raise SystemExit
m=r.get('metrics') or {}
names=['service_failures','wer_crashes','death_events','death_record_mismatch','unexpected_shutdowns',
       'bugchecks','fallbacks_fired','stale_error_lines','handshake_refusals','helper_deaths']
print(sum(1 for n in names if (m.get(n) or 0) == 0))
")
ck "SEEN TO FAIL: over a corpus without them, all ten read zero" 10 "$qz"

# ================================================================================================
# THE FOUR STRUCTURE-DRIVEN GATES. These cannot be tripped by one planted line: they need agent and
# watchdog INSTANCES, a shutdown window, and a capture time. That is the only reason they were left
# out of the first corpus, and leaving them out is how they stayed unproven.
python3 - "$T" <<'PYSTRUCT'
import base64, hashlib, os, sys
T = sys.argv[1]
def block(name, lines):
    text="\n".join(lines); data=text.encode("utf-8")
    b64=base64.b64encode(data).decode(); chunks=[b64[i:i+76] for i in range(0,len(b64),76)]
    out=["LSW PULL name=%s lines=%d bytes=%d sha256=%s b64lines=%d"%(name,len(lines),len(data),hashlib.sha256(data).hexdigest(),len(chunks))]
    out+=["LSW B|"+c for c in chunks]; out.append("LSW PULLEND name=%s b64lines=%d"%(name,len(chunks))); return out
def stream(files, ev):
    S=["LSW BEGIN v=1 now=2026-10-07T10:20:00.000 nowutc=2026-10-07T10:20:00.000Z tz=+00:00 "
       "host=RklYVFVSRQ== user=U1lTVEVN session=0 since=2026-10-07T09:00:00Z sincelocal=2026-10-07T09:00:00.000",
       "LSW LOGDIR pathb64=%s exists=1"%base64.b64encode(b"Q:\\Qubes Logs").decode()]
    for n,(name,fam,lines) in enumerate(files,1):
        p=base64.b64encode(("Q:\\Qubes Logs\\"+name).encode()).decode()
        S.append("LSW FILE id=f%d pathb64=%s family=%s bytes=%d lines=%d written=2026-10-07T10:13:00.500 "
                 "created=2026-10-07T10:00:30.000 partial=0 total_lines=%d"%(n,p,fam,len("\n".join(lines).encode()),len(lines),len(lines)))
        S+=block("f%d"%n,lines)
    S.append("LSW EVENTS channels=4 required_missing=-"); S+=block("events",ev)
    S.append("LSW END files=%d pulled=%d errors=0 event_errors=0"%(len(files),len(files))); return S
def L(ts,pid,lvl,func,msg): return "[20261007.%s.000-%d-%s] %s: %s"%(ts,pid,lvl,func,msg)

# AGENT pid 1000. Its log simply STOPS at 10:12:30 - no requested stop, no death record - and the
# capture time is 10:20:00, so the instance ends "unknown" more than 120 s before the capture
# (agent_ends_unrecorded). WGCBROKER is launched TWICE inside this one instance
# (helper_relaunches). The vchan announcement at 10:12:30 falls inside the shutdown window opened
# by the 1074 at 10:12:00 (vchan_setups_per_shutdown: a new vchan announcement while going down).
agent=[L("100031",1000,"I","Init","agent starting"),
       L("100040",1000,"I","Helpers","WGCBROKER launched pid 2100"),
       L("100100",1000,"I","Helpers","WGCBROKER launched pid 2231"),
       L("101230",1000,"I","WatchForEvents","Awaiting for a vchan client")]
# WATCHDOG: a launch, then the agent dying inside 10 s of it (watchdog_fast_death_backoffs).
watchdog=[L("100030",700,"I","StartTargetProcess","Running process 'C:\\Program Files\\Qubes Tools\\bin\\gui-agent.exe' in session 1"),
          L("100035",700,"E","WatchdogThread","Process 'gui-agent.exe' died within 500 ms of starting")]
events=["EV 2026-10-07 09:59:00.000 [System] id=6005 level=4 EventLog: The Event log service was started.",
        "EV 2026-10-07 10:12:00.000 [System] id=1074 level=4 User32: The process shutdown.exe has initiated the power off of computer WIN-IDD-TEST"]
open(os.path.join(T,"struct.pull"),"w",encoding="utf-8").write("\r\n".join(stream(
    [("gui-watchdog-20261007-100030-700.log","watchdog",watchdog),
     ("gui-agent-20261007-100031-1000.log","agent",agent)],events))+"\r\n")
PYSTRUCT
python3 "$SRC" decode "$T/struct.pull" --out "$T/slogs" > "$T/sdecode.txt" 2>&1
python3 "$SRC" analyze "$T/slogs" --baseline "$T/baseline.json" --out "$T/s.json" \
        --summary "$T/s.txt" --label struct --workdir "$T/swork" > "$T/sanalyze.out" 2>&1
[ -f "$T/s.json" ] || { echo "FATAL: no structure report: $(tail -5 "$T/sanalyze.out")"; exit 2; }
sv(){ python3 -c "
import json,sys
m=(json.load(open('$T/s.json')).get('metrics') or {})
print(m.get(sys.argv[1],'ABSENT'))" "$1"; }
sfired(){ v=$(sv "$1"); case "$v" in ''|ABSENT|None|0|0.0) echo "no($v)" ;; *) echo yes ;; esac; }

echo "--- the four structure-driven gates"
for g in vchan_setups_per_shutdown agent_ends_unrecorded helper_relaunches watchdog_fast_death_backoffs; do
  printf '     %-30s %s\n' "$g" "$(sv "$g")"
done
ck "vchan_setups_per_shutdown fires on an announcement during the shutdown window" yes "$(sfired vchan_setups_per_shutdown)"
ck "agent_ends_unrecorded fires on a log that stops with no stop and no death"      yes "$(sfired agent_ends_unrecorded)"
ck "helper_relaunches fires on WGCBROKER launched twice in one instance"            yes "$(sfired helper_relaunches)"
ck "watchdog_fast_death_backoffs fires on a death within 10 s of launch"            yes "$(sfired watchdog_fast_death_backoffs)"

printf 'gate-producer-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
