#!/bin/bash
# claim-receipt-gate.sh - Claude Code STOP hook. The turn does not end while its last message
# states a CAPABILITY LIMIT or names a GUEST STATE that no measurement in this session supports.
#
# WHY A STOP HOOK AND NOT A LINT. Every other gate here guards a file: the commit gate, the lint,
# the serial gate. The two failure classes that survived them are SPOKEN, not committed -
# "prime-run's loop needs sudo, so a human set those up" and "the guest is transient" were
# sentences to the owner, and by the time either could reach a file the damage (an invented
# blocker, a wrong diagnosis, an hour of the owner's day) was already done. Owner, 2026-09-21:
# "DO NOT EVEN TRY to present me any invented 'blockers' that were not validated by Jev" and
# "WHY THE FUCK YOU THINK IT IS TRANSIENT?? IT MAY BE BUT STOP INVENTING SHIT!". The sixth
# instance of the sudo fabrication was written into a commit message where it then read back as
# established fact - so the sentence is the artefact, and this gate is where a sentence is made
# to carry its receipt.
#
# WHAT SATISFIES IT (any one, per claim line):
#   * a Jev judgment in scratchpad/jev-wire.jsonl newer than the last user message - the claim was
#     put to the judge this turn;
#   * the line carries its own receipt: noul=/conf=/choice= numbers, "measured", "[verified DATE]",
#     or a findings/ citation;
#   * the line is a QUOTE (starts with '>', or the phrase sits inside backticks - `Transient` as
#     printed by qvm-ls is data, not a diagnosis).
#
# NARROW ON PURPOSE. Two closed vocabularies, assertive forms only. A gate that fires on ordinary
# prose gets turned off, and then it protects nothing.
# stdin: hook JSON. exit 0 = let the turn end, 2 = block (stderr goes back to the model).
# Self-test: tools/tests/claim-receipt-gate-selftest.sh. CLAIM_GATE_DEFECT=1 re-introduces the
# original state (nothing checks) and the self-test must then FAIL.
set -u
# DRAIN STDIN FIRST, always. Exiting before reading the hook JSON leaves the writer with a closed
# pipe - harmless for Claude Code, but it made the defect-knob case of the self-test exit 120
# under `set -o pipefail`, i.e. the check that proves this gate load-bearing could not run.
input=$(cat)
[ "${CLAIM_GATE_DEFECT:-}" = "1" ] && exit 0      # GUARD:claimreceipt
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 0
python3 - "$input" <<'PY'
import json, os, re, sys

def note(m):
    # A gate that quietly does nothing is worse than no gate (repo doctrine) - say so, then allow.
    sys.stderr.write("claim-receipt-gate DID NOT RUN: %s\n" % m); sys.exit(0)

try:
    hook = json.loads(sys.argv[1])
except Exception as e:
    note("unparseable hook JSON (%s)" % e)
if hook.get('stop_hook_active'):
    sys.exit(0)                      # already blocked once this turn - never loop
tp = hook.get('transcript_path')
if not tp or not os.path.exists(tp):
    note("no transcript at %r" % tp)

last_assistant, last_user_ts = None, ''
try:
    for line in open(tp, encoding='utf-8', errors='replace'):
        try: d = json.loads(line)
        except Exception: continue
        t, msg = d.get('type'), d.get('message') or {}
        if t == 'assistant':
            txt = '\n'.join(b.get('text', '') for b in (msg.get('content') or [])
                            if isinstance(b, dict) and b.get('type') == 'text').strip()
            if txt: last_assistant = txt
        elif t == 'user':
            c = msg.get('content')
            txt = c if isinstance(c, str) else '\n'.join(
                b.get('text', '') for b in (c or []) if isinstance(b, dict) and b.get('type') == 'text')
            if txt and txt.strip() and not txt.lstrip().startswith(('<task-notification>', '<local-command',
                                                                   '<command-name', '<bash-input', '<bash-stdout')):
                last_user_ts = d.get('timestamp', '') or last_user_ts
except Exception as e:
    note("transcript unreadable (%s)" % e)
if not last_assistant:
    sys.exit(0)

# A Jev judgment taken THIS TURN answers for every claim in it: the judge was asked.
wire = os.environ.get('JEV_WIRE_LOG') or 'scratchpad/jev-wire.jsonl'
if last_user_ts and os.path.exists(wire):
    try:
        for line in open(wire, encoding='utf-8', errors='replace'):
            ts = (json.loads(line).get('ts') or '')
            # both are ISO-8601; compare the naive prefix, which is enough to order minutes
            if ts and ts[:19] >= last_user_ts[:19]:
                sys.exit(0)
    except Exception:
        pass

CLAIMS = [
    # (1) a CAPABILITY that this qube supposedly lacks. Six fabrications to date, each written
    #     down afterwards as if it were knowledge (CLAUDE.md, block-device capability table).
    (re.compile(r'\b(needs?|requires?|require)\s+(sudo|root|dom0\b|a dom0 shell|the owner)', re.I),
     'a capability limit'),
    (re.compile(r'\bonly\s+(the\s+)?(owner|you|dom0)\s+can\b', re.I), 'a capability limit'),
    (re.compile(r'\b(not possible|impossible|cannot be done|no way)\s+from\s+(this qube|here)\b', re.I),
     'a capability limit'),
    (re.compile(r'\b(off-limits|out of reach|unavailable)\s+(from|to)\s+(this qube|us|me)\b', re.I),
     'a capability limit'),
    (re.compile(r'\bblocked\s+at\s+the\s+(platform|host|toolstack)\s+level\b', re.I), 'a blocker'),
    # (2) a GUEST STATE named rather than measured. tools/guest-state-judge.py exists to measure
    #     it and let Jev name it; every one of these was wrong at least once this month.
    (re.compile(r'\b(is|was|remains|stays|seems|looks|appears to be)\s+'
                r'(wedged|stalled|hung|deaf|stuck|transient)\b', re.I), 'a guest state'),
    (re.compile(r'\bignoring\s+(the\s+)?(acpi|shutdown|request)', re.I), 'a guest state'),
    (re.compile(r'\bit(?:\'s|’s| is)\s+(a\s+)?(transient|stall|wedge)\b', re.I), 'a guest state'),
]
RECEIPT = re.compile(r'noul=|conf=|choice=|\bjev\b|measured\b|\[verified |findings/|scratchpad/', re.I)

hits = []
in_fence = False
for raw in last_assistant.splitlines():
    s = raw.strip()
    if s.startswith('```'):
        in_fence = not in_fence; continue
    if in_fence or s.startswith('>') or s.startswith('|'):
        continue                                   # quoted text and tables are data, not diagnosis
    bare = re.sub(r'`[^`]*`', ' ', raw)            # `Transient` as PRINTED by qvm-ls is data
    if RECEIPT.search(raw):
        continue                                   # the line carries its own receipt
    for rx, kind in CLAIMS:
        m = rx.search(bare)
        if m:
            hits.append((kind, m.group(0).strip(), s[:150])); break
if not hits:
    sys.exit(0)

lines = '\n'.join("  - %s: %r\n      in: %s" % h for h in hits[:4])
sys.stderr.write(
    "BLOCKED by tools/hooks/claim-receipt-gate.sh: this turn states %d claim(s) with no measurement "
    "behind them in this session.\n%s\n"
    "This is the class that has cost the most here: a capability this qube supposedly lacks (six "
    "fabrications to date - `udisksctl loop-setup` was 'impossible' while matrix.sh had been using it "
    "for two weeks) and a guest state named instead of measured ('it is transient', 'ignoring ACPI' - "
    "wrong nearly every time).\n"
    "Before ending the turn, do ONE of:\n"
    "  1. run the cheapest disproving probe (under a minute) and say what it printed;\n"
    "  2. put the question to the judge - tools/jev.py with the candidates - and quote the numbers;\n"
    "  3. cite the measurement that already exists (findings/..., [verified DATE], a Jev score);\n"
    "  4. if you are quoting someone or showing tool output, put it in backticks or a > quote.\n"
    "Saying it more carefully is not one of the options.\n" % (len(hits), lines))
sys.exit(2)
PY
