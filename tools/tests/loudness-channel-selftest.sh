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

python3 - "$T" > "$T/out.txt" 2>&1 <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", "tools/log-sweep.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class L:  # the smallest stand-in for a parsed line
    def __init__(self, msg): self.msg = msg
class F:
    def __init__(self, name, msgs, family="agent"):
        self.name, self.lines, self.family, self.path = name, [L(x) for x in msgs], family, None

files = [F("gui-agent-20261014.log", [
    "NotifIpcEnsure: QGANOTIFIPC toast-hold records section created (2624 bytes, 32 records)",
    "Init: NOTIFYERR gate: enabled=1 source=default (ACTION faults also go to dom0)",   # configuration, not a send
    "Received request from client 3: domain '@default', service 'qubes.Notifications', user 'user'",
    "NotifRunInSession: NOTIFHOST launched via Task Scheduler (user session 1, resident)",
    "Received request from client 3: domain '@default', service 'qubes.Notifications', user 'user'",  # duplicate
])]
sends, _ = m.dom0_sends(files)
print("SENDS", len(sends))
print("CONFIG_EXCLUDED", 0 if any("gate: enabled=" in s[1] for s in sends) else 1)

cmp = {"breaches": [], "new": [], "rose": [], "out_of_context": []}
items = m.build_jev_items(cmp, None, {}, files, None, sends)
loud = [i for i in items if i["kind"] == "loud"]
print("ITEMS", len(loud))
rub = m.jev_rubric(loud)
crit = sorted(list(rub["questions"].values())[0]["criteria"].keys()) if rub["questions"] else []
print("CRITERIA", ",".join(crit))
# the clock metric that must never be absorbed again
t = m.DEFAULT_THRESHOLDS.get("clock_boot_correction_s", {})
print("CLOCKMETRIC", t.get("max"), t.get("severity"))
PY
cat "$T/out.txt" | sed 's/^/     /' | head -8

g(){ grep -a "^$1 " "$T/out.txt" | head -1 | cut -d' ' -f2-; }

# 3 = the QGANOTIF line + the two identical qubes.Notifications requests. The NOTIFHOST
# launch line in this fixture matches no pattern at all, which is correct: it is not a send.
ck "candidate sends are extracted"                 "3"   "$(g SENDS)"
ck "a line that only CONFIGURES the route is not a send" "1" "$(g CONFIG_EXCLUDED)"
ck "distinct candidates become Jev items (deduped)" "2"   "$(g ITEMS)"
ck "the judgement is Jev's, with loudness as a class" "insufficient-evidence,loud_failure,not_a_send,working_as_intended" "$(g CRITERIA)"
ck "the clock correction is a P1 metric"           "60 P1" "$(g CLOCKMETRIC)"

# The shipped file must act on the verdict, not merely collect it.
ck "a loud_failure verdict fails the sweep"        "1" \
   "$(grep -c 'it\["kind"\] == "loud" and j\["choice"\] == "loud_failure"' tools/log-sweep.py)"
ck "loud findings are carried into the report"     "1" \
   "$(grep -c '"loud_failures": loud_failures' tools/log-sweep.py)"
# And nothing may decide loudness by pattern any more.
ck "no regex decides which send is a failure"      "0" \
   "$(grep -c 'DOM0_LOUD_RE' tools/log-sweep.py)"

echo "loudness-channel-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
