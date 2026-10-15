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

# SEEN TO FAIL, because this check never had been. Put the level gate back as the ONLY filter and
# the INFO send must stop counting - that is the defect this suite used to require.
python3 - <<'PYDEF' > "$T/defect.txt" 2>&1
import importlib.util, re, sys
src = open("tools/log-sweep.py", encoding="utf-8").read()
src = src.replace('if lvl in ("W", "E") or DOM0_SENT_RE.search(msg):', 'if lvl in ("W", "E"):')
ns = {}
spec = importlib.util.spec_from_loader("lsdef", loader=None)
m = importlib.util.module_from_spec(spec)
try:
    exec(compile(src, "lsdef", "exec"), m.__dict__)
except SystemExit:
    pass
class L:
    def __init__(s, msg, lvl): s.msg, s.level = msg, lvl
class F:
    def __init__(s, name, pairs): s.name, s.lines = name, [L(a, b) for a, b in pairs]
f = F("bridge.log", [("NOTIFY one-shot: sent ok=1 summary=The PV NIC setup task failed", "I")])
print("DEFECT_COUNTED", len(m.dom0_loud([f])))
PYDEF
ck "with the level gate back, the INFO send is missed" "DEFECT_COUNTED 0" "$(grep -a '^DEFECT_COUNTED' "$T/defect.txt")"

echo "loudness-channel-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
