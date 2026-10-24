#!/bin/bash
# wrong-interpreter-gate.sh - Claude Code PreToolUse hook (matcher: Bash).
#
# THE RULE: a script is run by ITS OWN interpreter. `bash x.py`, `sh x.py`, `bash x.ps1`,
# `python3 x.sh` are refused. Not a style point - on this qube one of them froze the owner's
# desktop for twelve minutes.
#
# WHY A HOOK AND NOT A NOTE. 2026-10-24, twice in one session, and the second time the owner had to
# ask: "why gui is stuck on this qube again". I typed `bash tools/lint-harness.py`. Bash then
# executed the Python source as shell, and line 26 of that file is
#
#     import argparse, os, re, sys
#
# `import` on this qube is IMAGEMAGICK'S SCREEN CAPTURE. Given non-option arguments it starts an
# INTERACTIVE grab: it took the X pointer/server grab and waited for a mouse click. The owner's
# xfce4-terminal froze, no new GUI client could do anything, and the tool call blew past its 120 s
# timeout and was backgrounded - so I stopped watching the thing that was holding the grab. The
# task log carries the mechanism verbatim: `tools/lint-harness.py: line 27: from: command not
# found` / `line 29: syntax error near unexpected token '('`.
#
# The hazard is NOT the linter and not Python. It is that `bash <path>` is a habit, the extension is
# right there in the command, and a mis-sourced script does not fail cleanly - it executes whatever
# of its lines happen to be valid shell. The same file had already run correctly as
# `python3 tools/lint-harness.py` minutes earlier in that session: both spellings were in front of
# me and the wrong one went into the backgrounded copy. Attention is not a control.
#
# WHAT IT BLOCKS: a shell interpreter (bash/sh/dash/zsh/ksh, with or without sudo/env/command/
# timeout in front) whose script argument ends .py/.ps1/.psm1/.pl/.rb, and python/python3 given a
# .sh/.bash/.ps1. WHAT IT ALLOWS: the right interpreter for the extension; `bash -c '...'` and
# `bash -n <file>` (a syntax check names its own interpreter deliberately); any mention inside a
# heredoc body or a -m/--message string, which is prose - this gate's own commit message quotes the
# command it forbids.
#
# stdin: the hook JSON. Exit 0 = allow, 2 = block.
# Self-test: tools/tests/wrong-interpreter-gate-selftest.sh.
# WRONG_INTERPRETER_GATE_DEFECT=1 restores the state where nothing enforced; the self-test needs it.
set -u
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 0
if [ "${WRONG_INTERPRETER_GATE_DEFECT:-}" = "1" ]; then exit 0; fi   # GUARD:wrong-interpreter
input=$(cat)
python3 - "$input" <<'PY'
import json, re, sys

try:
    hook = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
if hook.get('tool_name') != 'Bash':
    sys.exit(0)
cmd = (hook.get('tool_input') or {}).get('command', '') or ''
if not cmd.strip():
    sys.exit(0)


def strip_prose(c):
    """A heredoc body or a commit message that TALKS about `bash x.py` is prose, not a call. Same
    guard and same reason as kill-by-pattern-gate.sh: this gate's own fix commit names the command
    it refuses, and a gate that blocks its own documentation gets switched off."""
    c = re.sub(r"<<-?\s*(['\"]?)(\w+)\1.*?^\s*\2\s*$", " ", c, flags=re.S | re.M)
    c = re.sub(r"(?:^|\s)(?:-m|--message)(?:=|\s+)('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")",
               " ", c, flags=re.S)
    return c


text = strip_prose(cmd)

# WHAT EACH INTERPRETER MUST NOT BE HANDED. The value is the extensions it cannot run, and the
# program that should have been typed instead.
WRONG = [
    (r"bash|sh|dash|zsh|ksh", (".py", ".pyw"),          "python3"),
    (r"bash|sh|dash|zsh|ksh", (".ps1", ".psm1"),        "pwsh -File"),
    (r"bash|sh|dash|zsh|ksh", (".pl",),                 "perl"),
    (r"bash|sh|dash|zsh|ksh", (".rb",),                 "ruby"),
    (r"python3?|python3\.\d+",(".sh", ".bash"),         "bash"),
    (r"python3?|python3\.\d+",(".ps1", ".psm1"),        "pwsh -File"),
    (r"pwsh|powershell",      (".sh", ".bash", ".py"),  "the script's own interpreter"),
]

# A PREFIX that does not change which interpreter runs: sudo, env, command, timeout <dur>, nohup,
# stdbuf <flags>, nice, and a variable assignment such as TMPDIR=/x.
PREFIX = (r"(?:sudo\s+|env\s+(?:-\S+\s+)*|command\s+|nohup\s+|nice\s+(?:-n\s*\S+\s+)?"
          r"|stdbuf\s+(?:-\S+\s+)+|timeout\s+(?:-\S+\s+)*\S+\s+|[A-Za-z_][A-Za-z_0-9]*=\S*\s+)*")

for prog, bad_exts, right in WRONG:
    # The interpreter at a COMMAND position, then its options, then the first non-option word.
    rx = re.compile(
        r"(?:^|[;&|(]|\bdo\b|\bthen\b|\belse\b|\{|`|\$\()\s*" + PREFIX +
        r"\b(" + prog + r")\b"
        r"((?:\s+-[A-Za-z0-9-]+(?:[= ]\S+)?)*)"       # options, captured so -c / -n can be seen
        r"\s+(?P<arg>(?:'[^']*'|\"[^\"]*\"|[^\s;&|'\"]+))",
        re.I)
    for m in rx.finditer(text):
        opts = (m.group(3) or '')
        # `bash -c '<script text>'` names its interpreter for a STRING, not a file, and `bash -n
        # x.sh` / `python3 -m mod` are deliberate. Neither mis-sources a file.
        if re.search(r"(?:^|\s)-(?:c|n|m|i)\b", opts):
            continue
        arg = m.group('arg').strip("'\"")
        low = arg.lower()
        if not low.endswith(bad_exts):
            continue
        interp = m.group(2)
        sys.stderr.write(f"""BLOCKED by wrong-interpreter-gate.sh: `{interp} {arg}` runs a script with the wrong interpreter.
Use:  {right} {arg}
A mis-sourced script does NOT fail cleanly - it executes whatever of its lines are valid in the
shell you handed it to. On 2026-10-24 `bash tools/lint-harness.py` made bash run that file's line
`import argparse, os, re, sys`, which is IMAGEMAGICK'S `import`: it started an INTERACTIVE screen
grab, took the X pointer/server grab and waited for a mouse click. The owner's terminal froze, no
GUI process could start for twelve minutes, and the call exceeded its timeout and was backgrounded,
so the process holding the grab was out of sight. The owner had to ask twice.
The extension is in the command you just typed. Read it, then name the matching interpreter.
""")
        sys.exit(2)

sys.exit(0)
PY
