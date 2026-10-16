#!/bin/bash
# loudness-channel-selftest.sh - a failure the USER CAN SEE is P1, so the sweep must read that channel.
#
# WHY. On 2026-10-14 the sweep graded five breaches for one acceptance cell and labelled every one
# P2, from a table of structural metrics. The owner saw the failure on his screen: "it IS fucking p1
# because it is a loud failure. and you do not even know it is loud, WHY". The answer to WHY was
# that nothing in this tool read the channel on which a condition reaches the user - it derived
# severity from counts and thresholds, which cannot know what was displayed.
#
# Put to Jev with that rule as the premise, the channel was named at 0.99 confidence:
# dom0_notifications - what dom0 was ASKED TO DISPLAY. Nothing else establishes the user saw
# anything. The same call judged the agent-relaunch breach loud_likely_unproven (0.80): the path
# that would show it is installed, so the channel has to be collected before severity can be settled.
#
# AND THE JUDGEMENT IS JEV'S, NOT A REGEX'S. My first attempt split the candidates with a second
# pattern and called "NOTIFHOST launched via Task Scheduler ... args:" a user-visible failure,
# because its arguments mention a notify-errors path. Classifiers belong to Jev on this project;
# the regex here is only a cheap prefilter.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

T=$(mktemp -d "${TMPDIR:-/tmp}/loudness-channel.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: expected '$2', got '$3'"; fi; }

python3 - "$T" > "$T/out.txt" 2>&1 <<'PYIN'
import importlib.util
spec = importlib.util.spec_from_file_location("ls", "tools/log-sweep.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class L:
    def __init__(self, msg, lvl): self.msg, self.level = msg, lvl
class F:
    def __init__(self, name, pairs, family="agent"):
        self.name, self.lines, self.family, self.path = name, [L(a, b) for a, b in pairs], family, None

files = [F("bridge.log", [
    ("NOTIFY one-shot: sent ok=1 summary=hello",                                     "I"),
    ("NOTIFY one-shot: sent ok=0 summary=hello - notification LOST",                 "E"),
    ("NOTIFY one-shot: no connection to dom0 (policy refusal?) - notification LOST", "E"),
    ("NOTIFY handoff: no active console session - this message reaches nobody",      "W"),
    ("NotifRunInSession: NOTIFHOST launched via Task Scheduler (args ...notify-errors...)", "I"),
    ("Init: NOTIFYERR gate: enabled=1 source=default",                               "I"),
    ("QGAERRBOX: shown to the user",                                                 "E"),
    ("CaptureThread: main loop slow",                                                "W"),
])]
loud = m.dom0_loud(files)
print("LOUD", len(loud))
print("SUCCESS_EXCLUDED", 0 if any("ok=1" in x[2] for x in loud) else 1)
print("LAUNCH_EXCLUDED",  0 if any("NOTIFHOST launched" in x[2] for x in loud) else 1)
print("CONFIG_EXCLUDED",  0 if any("gate: enabled=" in x[2] for x in loud) else 1)
print("OFFPATH_EXCLUDED", 0 if any("CaptureThread" in x[2] for x in loud) else 1)
t = m.DEFAULT_THRESHOLDS.get("dom0_loud_failures", {})
print("METRIC", t.get("max"), t.get("severity"))
cmp = m.compare({}, {"thresholds": {}}, {"dom0_loud_failures": len(loud)})
print("BREACHES", len(cmp["breaches"]))
PYIN
cat "$T/out.txt" | sed 's/^/     /' | head -9

g(){ grep -a "^$1 " "$T/out.txt" | head -1 | cut -d' ' -f2-; }

# WHAT THIS SUITE USED TO ASSERT, AND WHY IT HELD THE DEFECT IN PLACE. It required a dom0-path
# line to be declared W or E, and it asserted that a SUCCESSFUL send was NOT loud - with
# "NOTIFY one-shot: sent ok=1 summary=hello" at level I sitting in the fixture above as the case it
# excluded. That is a category error: the level of a SEND line describes whether the send
# succeeded, not what the user was shown. An emitter that successfully delivers a failure toast
# correctly writes INFO, because it is reporting its own success.
# MEASURED 2026-10-15 on win10-clean: the guest logged
#     [INFO] NOTIFY one-shot: sent ok=1 summary=The PV NIC setup task failed
# dom0 put that in front of the user, dom0_loud_failures read 0 for that cell, and the battery
# PASSED. A P1 with max 0 had never once been able to fire - and this suite was green throughout,
# because it asserted the exclusion AND asserted the source still contained the level gate.
# A test that pins a belief into the code cannot discover the belief is wrong.
ck "a dom0-path line declared W or E is LOUD"             "5" "$(g LOUD)"
ck "a SUCCESSFUL send IS loud - the user saw it"          "0" "$(g SUCCESS_EXCLUDED)"
# this one fooled a hand-written classifier: it matches the dictionary (its args name a
# notify-errors path) but is written at INFO, because it is a launch, not a failed send.
ck "a launch line that merely names the path is not loud" "1" "$(g LAUNCH_EXCLUDED)"
ck "a line that only CONFIGURES the route is not loud"    "1" "$(g CONFIG_EXCLUDED)"
ck "a W line that is NOT on the dom0 path is not loud"    "1" "$(g OFFPATH_EXCLUDED)"
ck "loudness is P1, with a zero threshold"                "0 P1" "$(g METRIC)"
ck "and it breaches"                                      "1" "$(g BREACHES)"

# A release gate should give the same answer twice and cost nothing to run, so no judge sits in
# this path. The dictionary is the sanctioned exception to "no vocabulary": it decides the PATH,
# never the severity, which still comes from the writer's declared level.
#
# NOTHING BELOW ASSERTS ON THE SOURCE TEXT. Four checks here used to grep log-sweep.py for the
# expressions the implementation happened to contain, which is how the previous version of this
# suite held the defect in place: it required the source to still say `lvl in ("W", "E")`, so the
# code could not be corrected without the test going red. The two properties those greps claimed
# are already asserted by the fixture above, as behaviour: LOUD=5 counts the W-level
# "NOTIFY handoff" line, which IS a dom0-path line that is not a send, so the level still
# qualifies those; and the same 5 counts the INFO "sent ok=1" line, so a send is recognised on its
# own. A property worth protecting is worth planting a line for.

# SEEN TO FAIL, BOTH WAYS. This metric has now been wrong in two opposite directions and each
# shipped: first the level gate alone, which could not see an INFO send (the delivered failure, on
# win10-clean 2026-10-15); then "level OR send token", which called an internal diagnostic a
# user-visible failure - on win11-appvm, acceptance run 38826875627, the single line it raised a P1
# for was `[W] BrokerReportDeaf: QGAWGCITEMCLOSED ... reopened at once`, a condition that recovered
# immediately, with no NOTIFY line anywhere in that cell's bridge.log. So the fixture carries BOTH
# shapes and the two previous rules must each get one of them wrong.
python3 - <<'PYDEF' > "$T/defect.txt" 2>&1
import importlib.util, sys
src = open("tools/log-sweep.py", encoding="utf-8").read()
def load(s):
    spec = importlib.util.spec_from_loader("lsdef", loader=None)
    m = importlib.util.module_from_spec(spec)
    try: exec(compile(s, "lsdef", "exec"), m.__dict__)
    except SystemExit: pass
    return m
class L:
    def __init__(s, msg, lvl): s.msg, s.level = msg, lvl
class F:
    def __init__(s, name, pairs): s.name, s.lines = name, [L(a, b) for a, b in pairs]
DELIVERED = ("NOTIFY one-shot: sent ok=1 summary=The PV NIC setup task failed", "I")
DIAGNOSTIC = ("BrokerReportDeaf: QGAWGCITEMCLOSED hwnd 0x40020 slot 0: Windows closed the capture item, reopened at once", "W")
f = F("bridge.log", [DELIVERED, DIAGNOSTIC])

now = load(src)
got = [x[2][:28] for x in now.dom0_loud([f])]
print("NOW_COUNT", len(got))
print("NOW_HAS_DELIVERED", int(any("sent ok=1" in x for x in got)))
print("NOW_HAS_DIAGNOSTIC", int(any("BrokerReportDeaf" in x for x in got)))

# rule 1: the level gate alone - misses the delivered failure
one = load(src.replace("if DOM0_OUTCOME_RE.search(msg):", 'if lvl in ("W", "E"):'))
print("RULE1_HAS_DELIVERED", int(any("sent ok=1" in x[2] for x in one.dom0_loud([f]))))
# rule 2: level OR token - counts the recovered diagnostic
two = load(src.replace("if DOM0_OUTCOME_RE.search(msg):", 'if lvl in ("W", "E") or DOM0_OUTCOME_RE.search(msg):'))
print("RULE2_HAS_DIAGNOSTIC", int(any("BrokerReportDeaf" in x[2] for x in two.dom0_loud([f]))))
PYDEF
ck "now: the delivered failure IS counted"                  "NOW_HAS_DELIVERED 1"     "$(grep -a '^NOW_HAS_DELIVERED' "$T/defect.txt")"
ck "now: the recovered diagnostic is NOT"                   "NOW_HAS_DIAGNOSTIC 0"    "$(grep -a '^NOW_HAS_DIAGNOSTIC' "$T/defect.txt")"
ck "SEEN TO FAIL rule 1 (level only): misses the delivered failure" "RULE1_HAS_DELIVERED 0" "$(grep -a '^RULE1_HAS_DELIVERED' "$T/defect.txt")"
ck "SEEN TO FAIL rule 2 (level OR token): counts the recovered diagnostic" "RULE2_HAS_DIAGNOSTIC 1" "$(grep -a '^RULE2_HAS_DIAGNOSTIC' "$T/defect.txt")"

echo "loudness-channel-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
