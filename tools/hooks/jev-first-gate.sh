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
# WHAT IT ALSO REQUIRES, of a Workflow: that the script DECLARE where the judgement sits and what each
# stage spends (JEV-JUDGE:, MODEL-PLAN:), and that it pin a model: somewhere if it calls agent(). The
# entry receipt proves the fork was asked BEFORE the fan-out and says nothing about the run's insides -
# a workflow whose verify stage was one expensive model scoring another's prose passed it cleanly.
#
# stdin: the hook JSON. Exit 0 = allow, 2 = block (message handed back to the model).
# No self-test: the suite that drove this was deleted 2026-11-06, when the BUILD check above made its
# "named+fresh receipt -> allowed" fixture assert the retired contract; the owner's standing rule is that
# a selftest which fails and needs a quick fix is dropped whole, and Jev chose the disposition
# (delete_the_whole_suite 0.87, conf 0.83) over repairing the fixture. What enforces the property is this
# hook's shape: its last statement is `exit 2`, so a state it does not recognise BLOCKS rather than
# allows, and the build half refuses a script whose text it cannot read. Verify a change to it inside the
# turn - pipe a tool_input JSON at it and read the rc - and back the file up first.
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

# THE RECEIPT IS NAMED, not merely recent. This used to allow any launch with a Jev call in the
# window - so unrelated calls kept it warm and a workflow whose own fork was never asked went
# through. It cost ~1.1M subagent tokens over three passes on 2026-10-17; the question, asked
# afterwards, answered in one call and invalidated the result. A window cannot show WHICH decision
# was asked. So the launcher names the answers file, and this checks that file.
fork=$(printf '%s' "$input" | python3 -c '
import json, os, re, sys
try: o = json.loads(sys.stdin.read() or "{}")
except Exception: sys.exit(0)
ti = o.get("tool_input") or {}
hay = " ".join(str(ti.get(k, "")) for k in ("script", "prompt", "name", "description"))
# A scriptPath launch - which is how a RESUME is relaunched - carries no script text, so a receipt
# named inside the script was invisible here and every resume was refused with no way to comply.
p = str(ti.get("scriptPath") or "")
if p and os.path.isfile(p):
    try: hay += " " + open(p, encoding="utf-8", errors="replace").read()
    except Exception: pass
m = re.search(r"JEV-FORK:\s*(\S+)", hay)
print(m.group(1) if m else "")
')
if [ -z "$fork" ]; then
    cat >&2 <<EOM
BLOCKED by tools/hooks/jev-first-gate.sh: this launch names no Jev fork receipt.

JEV FIRST is about THIS decision, not about having called Jev recently. Put the fork to Jev in a
small premise-framed call, write the answers with --out, then name that file in the launch:

    JEV-FORK: scratchpad/jev-<fork>-out.json

in the workflow script (a comment line is fine) or in the agent prompt. The gate checks the file
exists, parses as Jev answers, and is newer than $WINDOW_MIN minutes. It does not read the verdict.
EOM
    exit 2
fi
if [ ! -s "$ROOT/$fork" ] && [ ! -s "$fork" ]; then
    echo "BLOCKED by tools/hooks/jev-first-gate.sh: named fork receipt '$fork' does not exist or is empty." >&2
    exit 2
fi
fpath="$ROOT/$fork"; [ -s "$fpath" ] || fpath="$fork"
if ! python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
a = d.get("answers", d)
if not isinstance(a, dict) or not a: raise SystemExit(1)
' "$fpath" 2>/dev/null; then
    echo "BLOCKED by tools/hooks/jev-first-gate.sh: '$fork' is not a Jev answers file (no answers map)." >&2
    exit 2
fi
# THE BUILD, NOT ONLY THE ENTRY. A named receipt proves the fork was ASKED before the fan-out. It says
# nothing about where the judgement sits INSIDE the run, or what each stage spends - so a workflow whose
# verify stage was one model scoring another model's prose passed this gate cleanly. Owner, 2026-11-06:
# "you build workflows without jev as judgement. you have entry gate with jev, but it does not ensure
# that the build is right and tokens are optimized."
#
# Two declarations are required of a Workflow script, checked the way JEV-FORK is - that they were
# WRITTEN, never what they say, because only the author knows the stages:
#   JEV-JUDGE:  what Jev judges in this run, or NONE and why nothing in it needs judging
#   MODEL-PLAN: the tier each stage spends
# and one hard check with no judgement in it: a script with agent() calls and no model: anywhere pinned
# no tier at all, so every stage silently inherits the session model - the most expensive one.
build=$(printf '%s' "$input" | python3 -c '
import json, os, re, sys
root = sys.argv[1] if len(sys.argv) > 1 else ""
try: o = json.loads(sys.stdin.read() or "{}")
except Exception: sys.exit(0)
if o.get("tool_name") != "Workflow": sys.exit(0)
ti = o.get("tool_input") or {}
src = str(ti.get("script") or "")
p = str(ti.get("scriptPath") or "")
if not src and p:
    try: src = open(p, encoding="utf-8", errors="replace").read()
    except Exception: pass
# Fail CLOSED, as every other arm of this script does: a build that cannot be read cannot be checked,
# and reporting the three declaration misses of an empty string would name the wrong defect. An inline
# launch always carries text, and a bare name: launch never reaches here - the entry half refuses it
# first, because a saved workflow name cannot carry the receipt path.
if not src:
    print("the script text could not be read" + (" from scriptPath " + p if p else "")); sys.exit(0)
bad = []
if not re.search(r"JEV-JUDGE:\s*\S", src): bad.append("no JEV-JUDGE declaration")
if not re.search(r"MODEL-PLAN:\s*\S", src): bad.append("no MODEL-PLAN declaration")
if re.search(r"\bagent\s*\(", src) and not re.search(r"\bmodel\s*:", src):
    bad.append("agent() calls but no model: pinned anywhere - every stage inherits the session tier")
# THE DECLARATION MUST NOT DIVERGE FROM THE RUN. A declaration that can say anything is worth what it
# costs to type, so the one part of it that is decidable is decided here: every tier the script LITERALLY
# pins must be named in MODEL-PLAN. A computed model (model: d.tier) is unquoted and is not checked -
# that keeps this at zero false positives, and the declaration still has to cover what it can see.
dec, lines = "", src.splitlines()
for i, ln in enumerate(lines):
    if "MODEL-PLAN:" in ln:
        dec = ln
        for nxt in lines[i + 1:]:
            if not re.match(r"\s*(//|#|\*)", nxt): break
            dec += " " + nxt
        break
pinned = sorted(set(re.findall(r"\bmodel\s*:\s*[\x27\"]([A-Za-z0-9._-]+)[\x27\"]", src)))
missing = [t for t in pinned if t not in dec]
if dec and missing:
    bad.append("MODEL-PLAN does not name the tier(s) the script actually pins: " + ", ".join(missing))
# THE PLAN IS AN ARTIFACT, NOT A COMMENT. A plan written inside the script cannot govern the script, and
# one artifact cannot diverge from another that does not exist - divergence is measurable only between two
# (Jev: named_checked_artifact 0.89 conf 0.85, pins_and_literal_phases 0.91 conf 0.88). So the launch names
# a plan file written BEFORE the script, and everything the script LITERALLY commits to must appear in it.
# A computed tier or phase name is not a literal and is exempt: the first false positive is what gets a
# check argued around instead of obeyed.
m = re.search(r"WORKFLOW-PLAN:\s*(\S+)", src)
if not m:
    bad.append("no WORKFLOW-PLAN declaration naming the plan file")
else:
    rel, plan = m.group(1), ""
    for cand in ([os.path.join(root, rel), rel] if root else [rel]):
        try:
            plan = open(cand, encoding="utf-8", errors="replace").read()
            break
        except Exception:
            continue
    if not plan.strip():
        bad.append("the plan file named by WORKFLOW-PLAN (" + rel + ") does not exist or is empty")
    else:
        phases = sorted(set(re.findall(r"\bphase\s*(?:\(\s*|:\s*)[\x27\"]([^\x27\"]+)[\x27\"]", src)))
        gone = sorted(set([t for t in pinned if t not in plan] + [f for f in phases if f not in plan]))
        if gone:
            bad.append("the plan does not name what the script commits to: " + ", ".join(gone))
print("; ".join(bad))
' "$ROOT")
if [ -n "$build" ]; then
    cat >&2 <<EOM
BLOCKED by tools/hooks/jev-first-gate.sh: the fork receipt is fine, the BUILD is not - $build.

JEV FIRST is satisfied; this is the other half. Put three comment lines in the script:

    // JEV-JUDGE: <what Jev judges here, in code, over the artifacts the stages return>
    //            or: NONE - <why nothing in this run is a judgement>
    // MODEL-PLAN: <stage>=<tier> per stage, e.g. spec=sonnet judge=jev write=main-thread
    // WORKFLOW-PLAN: scratchpad/workflow-plan-<name>.md

THE PLAN COMES FIRST, and it is a FILE, not a comment: a plan written inside the script cannot
govern the script. Answer .claude/skills/jev-workflow/PLANNING-PROMPT.md into that file BEFORE any
script text exists - it asks, in order, whether a workflow is warranted at all, what would
disconfirm the plan, the fork and its relevance question, the per-stage placement and spend, what
Jev judges, who writes, and the literals below. The plan must NAME every tier the script pins as a
quoted literal and every literal phase name it runs; computed tiers and phase names are exempt.

WHAT COUNTS AS A JUDGEMENT, and therefore Jev's: a verdict, a score, a classification, a ranking,
"is this real", "does this hold". A model may not perform any step a script could produce
deterministically (.claude/skills/jev-classifier/SKILL.md) - checking a cited file:line, diffing,
counting and matching are CODE. One model re-reading a high-stakes result against its original is
sanctioned, but ALONGSIDE Jev, never instead of it.

TIERS: an unpinned agent() inherits the session model, which is the dearest tier, so a mechanical
read costs what the hardest judgement costs. Name the tier per stage, and the effort with it.
MODEL-PLAN must name every tier the script literally pins - the declaration is checked against the
run, not taken on trust. A computed model (model: d.tier) is not checkable and is not checked.
Read .claude/skills/jev-workflow/SKILL.md before changing this build.
EOM
    exit 2
fi

last=$(date -r "$fpath" +%s 2>/dev/null || echo "")
now=$(date +%s)
if [ -n "$last" ] && [ $((now - last)) -le $((WINDOW_MIN * 60)) ]; then
    exit 0
fi

cat >&2 <<EOM
BLOCKED by tools/hooks/jev-first-gate.sh: the named fork receipt is older than $WINDOW_MIN minutes, before a
Workflow / Fable agent.

JEV FIRST (owner, 2026-10-01): put the semantic forks to Jev before fanning out - a few questions per
call, a distilled state, the owner's binding rule as the premise, options with their consequences
written out, an insufficient-evidence option; close low-confidence gaps and re-ask. THEN, if anything
is left to mechanise, one Fable agent (or a workflow the owner asked for) works from the verdicts.
python3 tools/jev.py RUBRIC.json STATE --out ANSWERS.json   (.claude/skills/jev/SKILL.md)
EOM
exit 2
