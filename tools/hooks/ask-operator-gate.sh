#!/bin/bash
# ask-operator-gate.sh - Claude Code PreToolUse hook (matcher: AskUserQuestion|ExitPlanMode).
#
# THE RULE, ENFORCED HERE AND NOT IN PROSE (owner, 2026-09-25): "make operator intervention
# jev-bound. if you want to stop and ask something, ask jev first if you should."
#
# WHY IT IS A GATE AND NOT A SENTENCE. This project's own context audit measured the difference:
# rules that were mechanised fired 62 times in one session; rules that were prose were walked past,
# and only ONE of twelve failure episodes was a rule nobody had mechanised (findings/issues.md,
# 2026-09-21). A sentence telling me to consult Jev before interrupting the owner would be exactly
# the kind of rule that gets skipped in the moment it matters - when I am stuck and want to ask.
#
# WHAT IT REQUIRES: a Jev call, within the last ASK_GATE_WINDOW_MIN minutes, that actually put the
# question of INTERRUPTING THE OPERATOR to Jev. That is recognised by the wire log carrying one of
# the marker tokens below in the request. Jev's verdict is not parsed here on purpose: the gate
# enforces that the question was ASKED, not which way it was answered - deciding for the model
# would just move the judgement back into a script.
#
# AND IT CHECKS THE CLOCK (owner, 2026-10-15): "before asking principal, check time. if it is in
# range 1am-6am, better keep yourself busy overnight rather than ask 'should i do that lengthy
# task'". A scope question at 03:00 does not get answered at 03:00 - it stops the rig until morning
# and throws away the hours that are the cheapest ones to spend. The owner said this after I asked,
# at 03:05, whether to spend a multi-hour campaign on a clock fix; the right move was to start it.
# So between 01:00 and 05:59 local this refuses, and the model picks the option that keeps working.
#
# Exit 0 = allow. Exit 2 = block, and the message on stderr goes back to the model.
set -u
WINDOW_MIN="${ASK_GATE_WINDOW_MIN:-20}"
NIGHT_FROM="${ASK_GATE_NIGHT_FROM:-1}"   # inclusive hour
NIGHT_TO="${ASK_GATE_NIGHT_TO:-6}"       # exclusive hour
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
WIRE="${JEV_WIRE_LOG:-$ROOT/scratchpad/jev-wire.jsonl}"

# Markers that say "this Jev call was about whether to involve the operator".
MARKERS='ask_operator|should_ask|operator_intervention|escalate_to_owner|interrupt_the_owner|blocking_question'

# ---- THE SECOND SURFACE: A TURN THAT SIMPLY STOPS AND ASKS --------------------------------------
# OWNER, 2026-11-07: «so you asked me and paused bypassing operator interaction gate? how is it
# possible?» It is possible because this gate's matcher is AskUserQuestion|ExitPlanMode - TOOL CALLS.
# At ~04:00 that morning I ended a turn with prose that reported the campaign and named what it
# needed from him ("what blocks the cut now ... needs the rig, the owner's screen"). No tool was
# called, so nothing here ran, and the night window - the exact hours this gate exists to protect -
# was handed back to him anyway. A gate on the tool does not cover the behaviour: ENDING A TURN WITH
# A QUESTION IS THE INTERRUPTION. So the Stop event is gated by the same clock and the same Jev
# receipt. STOP_HOOK_ACTIVE means the stop was already blocked once: never loop a session.
if [ -n "${CLAUDE_HOOK_STDIN:-}" ] || [ ! -t 0 ]; then
    _hook_json=$(cat 2>/dev/null || true)
else
    _hook_json=""
fi
if printf '%s' "$_hook_json" | grep -q '"hook_event_name"[[:space:]]*:[[:space:]]*"Stop"'; then
    printf '%s' "$_hook_json" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && exit 0
    _tp=$(printf '%s' "$_hook_json" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$_tp" ] && [ -r "$_tp" ] || exit 0
    # The last assistant text, and whether it hands something to the owner. Deliberately narrow: a
    # question mark in the closing lines, or an explicit hand-back. A report that merely CONTAINS a
    # question mark mid-text is not one, and text naming this gate is how the rule gets explained.
    _handback=$(python3 - "$_tp" <<'PYASK'
import json, re, sys
last = ''
try:
    for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
        try: rec = json.loads(line)
        except Exception: continue
        if rec.get('type') != 'assistant': continue
        ch = [c.get('text','') for c in (rec.get('message') or {}).get('content') or []
              if isinstance(c, dict) and c.get('type') == 'text']
        if any(ch): last = '\n'.join(ch)
except Exception:
    sys.exit(0)
if not last or re.search(r'ask-operator-gate|ASK_OPERATOR_NIGHT_OK', last):
    sys.exit(0)
tail = '\n'.join([l for l in last.strip().splitlines() if l.strip()][-3:])
PHRASES = (r'\b(let me know|your call|up to you|tell me which|which would you|do you want me to|'
           r'shall i|should i|needs? (you|your|the owner)|waiting (for|on) (you|your)|'
           r'blocked on (you|your)|if you want|when you(\'re| are) ready)\b')
if re.search(PHRASES, last, re.I) or '?' in tail:
    print((re.search(PHRASES, last, re.I) or re.search(r'[^.\n]*\?', tail)).group(0)[:120])
PYASK
)
    [ -n "$_handback" ] || exit 0
    ASK_SURFACE="the END OF THIS TURN (no tool call - prose that hands the owner a question: \"$_handback\")"
else
    case "${_hook_json:+x}" in x) ;; *) ;; esac   # PreToolUse: the tool itself is the surface
    ASK_SURFACE=""
fi

# ---- THE CLOCK, BEFORE ANYTHING ELSE -----------------------------------------------------------
# NIGHT HOURS. Nothing here judges how important the question is: a question asked at 03:00 waits
# until morning whatever it is, so the only thing that changes is whether the intervening hours were
# spent. ASK_OPERATOR_NIGHT_OK=1 exists for the one case this cannot cover - proceeding under ANY
# assumption would be unsafe or destructive - and it is not for "this decision is a big one".
hour=$(date +%-H)
if [ "${ASK_OPERATOR_NIGHT_OK:-}" != "1" ] && [ "$hour" -ge "$NIGHT_FROM" ] && [ "$hour" -lt "$NIGHT_TO" ]; then
    cat >&2 <<EOM
BLOCKED by tools/hooks/ask-operator-gate.sh: it is $(date +%H:%M) local, inside the ${NIGHT_FROM}:00-${NIGHT_TO}:00 night window.${ASK_SURFACE:+
The surface is $ASK_SURFACE - ending a turn with a question is the interruption, tool or no tool.}
The owner's rule: "before asking principal, check time. if it is in range 1am-6am, better keep
yourself busy overnight rather than ask 'should i do that lengthy task'."

A scope question now is not answered now - it parks the rig until morning and spends none of the
hours that are cheapest to spend. So:
  1. Pick the option that KEEPS WORKING. If one path is longer but reversible, take it.
  2. State the assumption you proceeded under, in the turn and in findings/issues.md.
  3. Leave the question for the morning only if it is still open then.
A lengthy task is a REASON TO START, not a reason to ask.

ASK_OPERATOR_NIGHT_OK=1 overrides this, and only for a decision where proceeding under any
assumption would be unsafe or destructive - never for "this one is big".
EOM
    exit 2
fi

if [ ! -s "$WIRE" ]; then
    cat >&2 <<EOM
BLOCKED by tools/hooks/ask-operator-gate.sh: no Jev wire log at $WIRE.

Operator intervention is Jev-bound here (owner, 2026-09-25): before stopping to ask, ask Jev
whether you should. Put the actual question to it - what you are blocked on, what you would do
without an answer, and what it costs if you guess wrong - then proceed on its verdict.
EOM
    exit 2
fi

# Newest wire entry mentioning one of the markers, and how old it is.
now=$(date +%s)
recent=$(awk -v cutoff="$((now - WINDOW_MIN*60))" '
    { line=$0 }
    line ~ /'"$MARKERS"'/ { hit=NR }
    END { print hit+0 }' "$WIRE")

if [ "${recent:-0}" -eq 0 ]; then
    cat >&2 <<EOM
BLOCKED by tools/hooks/ask-operator-gate.sh: the Jev wire log has no call that asked whether to
involve the operator.

Operator intervention is Jev-bound here (owner, 2026-09-25): "if you want to stop and ask
something, ask jev first if you should."

Ask it first - state what you are blocked on, what you would do with no answer, and the cost of
guessing wrong - using a question id containing one of: ask_operator, should_ask,
operator_intervention, escalate_to_owner, interrupt_the_owner, blocking_question.
Then act on the verdict: if Jev says decide it yourself, decide it yourself.

(A genuine approval gate CLAUDE.md mandates - upstream submission, a dom0/policy change - is
still a real gate. Asking Jev first costs one call and is what the owner asked for.)
EOM
    exit 2
fi

# Freshness: the marker must be in a RECENT entry, not one from hours ago.
ts=$(sed -n "${recent}p" "$WIRE" | grep -oE '"(ts|timestamp|time)"[[:space:]]*:[[:space:]]*"?[0-9T:.Z@+-]+' | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+' | head -1)
if [ -n "$ts" ]; then
    then_s=$(date -d "$ts" +%s 2>/dev/null || echo 0)
    if [ "$then_s" -gt 0 ] && [ $((now - then_s)) -gt $((WINDOW_MIN*60)) ]; then
        cat >&2 <<EOM
BLOCKED by tools/hooks/ask-operator-gate.sh: the only Jev call about involving the operator is
older than ${WINDOW_MIN} minutes ($ts), so it is not about what you are asking now.

Ask Jev again, about THIS question, then proceed on its verdict.
EOM
        exit 2
    fi
fi
exit 0
