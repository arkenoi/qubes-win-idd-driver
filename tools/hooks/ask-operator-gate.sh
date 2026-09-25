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
# Exit 0 = allow. Exit 2 = block, and the message on stderr goes back to the model.
set -u
WINDOW_MIN="${ASK_GATE_WINDOW_MIN:-20}"
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
WIRE="${JEV_WIRE_LOG:-$ROOT/scratchpad/jev-wire.jsonl}"

# Markers that say "this Jev call was about whether to involve the operator".
MARKERS='ask_operator|should_ask|operator_intervention|escalate_to_owner|interrupt_the_owner|blocking_question'

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
