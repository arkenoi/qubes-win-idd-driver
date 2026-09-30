#!/bin/bash
# jev-first-gate.sh - Claude Code PreToolUse hook (matcher: Workflow|Agent).
#
# THE RULE, ENFORCED HERE AND NOT IN PROSE (owner, 2026-10-01): "jev first, fable second" - and, after it
# had to be repeated: "just using one simple hint: two words: JEV FIRST" / "i am telling it to you each
# time, but if i omit you revert to default fable fuckery immediately! please dont!"
#
# WHY A GATE. The prose rule existed (memory, 2026-09-21: differentials are code, not agents) and was
# walked past: on 2026-09-30/10-01 an 8-agent Fable design workflow re-read the whole agent and broker
# (~2.5M tokens) for forks that four small Jev calls then settled. Semantic forks go to Jev FIRST; a
# multi-agent workflow or a Fable agent comes SECOND, to mechanise what Jev decided.
#
# WHAT IT REQUIRES: a Jev call (any) in the wire log within the last JEV_FIRST_WINDOW_MIN minutes before
# a Workflow is launched or an Agent is spawned on the Fable model. The verdict is not parsed: the gate
# enforces that Jev was consulted first, not what it said.
#
# Exit 0 = allow. Exit 2 = block, and the message on stderr goes back to the model.
set -u
WINDOW_MIN="${JEV_FIRST_WINDOW_MIN:-60}"
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
WIRE="${JEV_WIRE_LOG:-$ROOT/scratchpad/jev-wire.jsonl}"

input=$(cat)
verdict=$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    o = json.loads(sys.stdin.read() or "{}")
except Exception:
    print("allow"); sys.exit(0)
tool = o.get("tool_name", "")
ti = o.get("tool_input") or {}
if tool == "Workflow":
    print("gate")
elif tool == "Agent" and str(ti.get("model", "")).lower() == "fable":
    print("gate")
else:
    print("allow")
')
[ "$verdict" = "gate" ] || exit 0

last=""
if [ -s "$WIRE" ]; then
    last=$(tail -n 200 "$WIRE" | python3 -c '
import json, sys, datetime
best = None
for line in sys.stdin:
    try:
        ts = json.loads(line).get("ts")
        t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S%z").timestamp()
    except Exception:
        continue
    best = t if best is None or t > best else best
print(int(best) if best else "")
')
fi
now=$(date +%s)
if [ -n "$last" ] && [ $((now - last)) -le $((WINDOW_MIN * 60)) ]; then
    exit 0
fi

cat >&2 <<EOM
BLOCKED by tools/hooks/jev-first-gate.sh: no Jev call in the last $WINDOW_MIN minutes before a
Workflow / Fable agent.

JEV FIRST (owner, 2026-10-01): put the semantic forks to Jev before fanning out - a few questions per
call, a distilled state, the owner's binding rule as the premise, options with their consequences
written out, an insufficient-evidence option; close low-confidence gaps and re-ask. THEN, if anything
is left to mechanise, one Fable agent (or a workflow the owner asked for) works from the verdicts.
python3 tools/jev.py RUBRIC.json STATE --out ANSWERS.json   (.claude/skills/jev/SKILL.md)
EOM
exit 2
