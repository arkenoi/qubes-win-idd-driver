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

# A dom0-path line its own writer declared W or E. Both facts come from the right place: the level
# from the writer, the path from OUR OWN protocol tokens - neither is guessed, and no judge is
# needed to combine them.
ck "a dom0-path line declared W or E is LOUD"             "4" "$(g LOUD)"
ck "a SUCCESSFUL send is not loud"                        "1" "$(g SUCCESS_EXCLUDED)"
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
ck "no Jev item kind for loudness remains"       "0" "$(grep -c 'kind.\] == .loud.' tools/log-sweep.py)"
ck "the dom0 token dictionary still exists"      "1" "$(grep -c '^DOM0_SEND_RE' tools/log-sweep.py)"
ck "severity is never taken from the dictionary" "1" "$(awk '/^def dom0_loud/,/^    return loud$/' tools/log-sweep.py | grep -c 'not in ("W", "E")')"

echo "loudness-channel-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
