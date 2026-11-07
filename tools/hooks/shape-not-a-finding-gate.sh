#!/bin/bash
# shape-not-a-finding-gate.sh - THREE surfaces, one rule: a recurrence is a FAILED FIX, never news.
#
#   PreToolUse  Edit|Write|MultiEdit  - the record (findings/, CLAUDE.md, docs/, memory, skills)
#   PreToolUse  Bash                  - the commit MESSAGE (git commit / git tag)
#   Stop                              - THE DECISION POINT: the turn may not end on a sentence that
#                                       tells the owner about a repeat while naming no fix.
#
# THE RULE, OWNER 2026-11-07, VERBATIM: «when you are trying to tell me about "new shape", IT IS NOT
# FUCKING NEW SHAPE, IT IS YOU FAILED TO FIX AND NEED TO RE-DO PROPERLY RIGHT NOW», and then: «can
# you make it sure that i would never hear from you about "new shape" again and that it becomes an
# automatic decision point?» - which is why the Stop surface exists. A gate on the record alone was
# not enough: commit e2966531 took the FOURTH loss of an OPEN P1 (TOASTBANNERLOSTONDIRECTPATH) and
# spent the turn on a discriminator, an N=1 caveat and a REPORT to the owner, while the mechanism sat
# unread in agent/gui-agent/toasthold.c - ToastHoldNoteChanged armed the re-examination deadline for
# a SHOWN banner only, so a suppressed banner whose window was repainted with a new toast was never
# decided again. Four sightings, zero repairs; the register had already said what to do next.
#
# WHAT COUNTS AS A REPEAT: a new/another/different/Nth shape, an Nth loss or instance, "fired again",
# "came back", "recurrence", "the same defect again".
#
# THE ONE WAY THROUGH is to have fixed it - the same text must carry `FIX-LANDED: <commit, file:line
# or mechanism>`. Deliberate: the record and the report then FOLLOW the repair instead of replacing
# it. CLOSED / RETIRED / RETRACTED pass too (the thing is over). Text that is ABOUT this rule - it
# names this gate - passes, so the rule can be explained and changed.
#
# This gate cannot see code, so it cannot check the fix is real; Jev's pre-commit review and the suite
# that measures the defect do that. What it removes is the option of reaching for the register, the
# commit message or the owner's attention as the FIRST move after a known defect fires again.
#
# stdin: the hook JSON. PreToolUse: exit 0 allow, 2 block. Stop: a JSON decision on stdout.
# SHAPE_GATE_DEFECT=1 re-introduces the original state (nothing enforces).
set -u
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 0
if [ "${SHAPE_GATE_DEFECT:-}" = "1" ]; then exit 0; fi   # GUARD:shape-gate DEFECT: a recurrence is recorded/reported instead of fixed
input=$(cat)
python3 - "$input" <<'PY'
import json, os, re, sys
try:
    hook = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)  # not our JSON - never block on a parse problem of our own

REPEAT = [
    r'\b(new|another|different|second|third|fourth|fifth|4th|5th|2nd|3rd)\s+shape\b',
    r'\bshape\s*\(\s*[a-z]\s*\)',
    r'\b(\d+(?:st|nd|rd|th)|second|third|fourth|fifth)\s+(loss|instance|occurrence|sighting|time)\b',
    r'\b(fired|happened|failed|lost|broke|returned|recurred)\s+again\b',
    r'\b(came|comes)\s+back\b',
    r'\brecurrence\b',
    r'\bsame\s+(defect|failure|issue|bug)\s+again\b',
    r'\bgets?\s+its\s+\w+\s+(loss|instance)\b',
]
# Having fixed it is the way through; so is recording that the thing is over; so is talking ABOUT
# this rule (otherwise the gate could never be explained, audited or removed).
EXEMPT = re.compile(r'\bFIX-LANDED\b|\bCLOSED\b|\bRETIRED\b|\bRETRACTED\b'
                    r'|shape-not-a-finding-gate|SHAPE_GATE_DEFECT')

# Nothing in this tree looked for a phrase that says "it happened again" (searched 2026-11-07: four
# code hits, all unrelated - a sweep regex, the qrexec wrapper, two installers).
def repeat_in(text):
    if not text or EXEMPT.search(text):
        return None
    for pat in REPEAT:
        m = re.search(pat, text, re.I)
        if m:
            return m.group(0)
    return None

WHY = ('Owner 2026-11-07: a "new shape" is not a finding - it is the fix having failed, and the work is '
       'to redo it properly NOW. Find the mechanism in the CODE (not in the log prose), change it, prove '
       'it against the failing run\'s own artefacts. Then write `FIX-LANDED: <commit, file:line or '
       'mechanism>` in the same text and this gate lets it through. If the thing is genuinely over, say '
       'CLOSED / RETIRED / RETRACTED.')

event = str(hook.get('hook_event_name') or '')
ti = hook.get('tool_input') or {}
tool = str(hook.get('tool_name') or '')

# ---- Stop: the automatic decision point ----------------------------------------------------------
# The turn may not END on a sentence that hands the owner a repeat with no repair. Reads the last
# assistant text in the transcript; on any doubt it allows, and `stop_hook_active` means it has
# already re-entered once - a gate that wedges the session is worse than the defect it guards.
if event == 'Stop' or (not tool and hook.get('transcript_path')):
    if hook.get('stop_hook_active'):
        sys.exit(0)
    tp = str(hook.get('transcript_path') or '')
    if not tp or not os.path.exists(tp):
        sys.exit(0)
    last = ''
    try:
        with open(tp, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get('type') != 'assistant':
                    continue
                msg = rec.get('message') or {}
                chunks = [c.get('text', '') for c in (msg.get('content') or [])
                          if isinstance(c, dict) and c.get('type') == 'text']
                if any(chunks):
                    last = '\n'.join(chunks)
    except Exception:
        sys.exit(0)
    hit = repeat_in(last)
    if hit:
        print(json.dumps({
            "decision": "block",
            "reason": (f"This turn ends by telling the owner about a repeat ({hit!r}) with no fix named. "
                       f"{WHY} Do the repair now, in this turn, and then say what landed."),
            "systemMessage": f"shape-not-a-finding-gate: held the turn - {hit!r} reported, no fix named",
        }))
    sys.exit(0)

# ---- PreToolUse / Bash: the commit message -------------------------------------------------------
if tool == 'Bash':
    cmd = str(ti.get('command') or '')
    if 'git commit' not in cmd and 'git tag' not in cmd:
        sys.exit(0)
    hit = repeat_in(cmd)
    if hit:
        sys.stderr.write(f"BLOCKED by tools/hooks/shape-not-a-finding-gate.sh: this commit message records a "
                         f"REPEAT ({hit!r}) and names no fix.\n{WHY}\n")
        sys.exit(2)
    sys.exit(0)

# ---- PreToolUse / Edit|Write|MultiEdit: the record -----------------------------------------------
path = str(ti.get('file_path') or ti.get('path') or '')
if not path:
    sys.exit(0)
# The record, exactly as retired-names-gate.sh scopes it: a correction applied to one copy is not a
# correction, and neither is a recurrence noted in one copy.
guarded = re.compile(r'(^|/)(CLAUDE\.md|CLAUDE\.local\.md|FINDINGS\.md)$|(^|/)(findings|docs)/|/memory/'
                     r'|/\.claude/skills/')
if not guarded.search(path):
    sys.exit(0)
parts = []
for k in ('content', 'new_string'):
    if ti.get(k): parts.append(str(ti[k]))
for e in ti.get('edits') or []:
    if isinstance(e, dict) and e.get('new_string'): parts.append(str(e['new_string']))
hit = repeat_in('\n'.join(parts))
if hit:
    sys.stderr.write(f"BLOCKED by tools/hooks/shape-not-a-finding-gate.sh: this edit to {path} records a "
                     f"REPEAT ({hit!r}) and names no fix.\n{WHY}\n")
    sys.exit(2)
sys.exit(0)
PY
