#!/bin/bash
# wrong-interpreter-gate-selftest.sh - a script is run by ITS OWN interpreter.
#
# THE INCIDENT THIS IS BUILT FROM, 2026-10-24, twice in one session. I typed
#   bash tools/lint-harness.py
# Bash executed that Python file as shell, and its line `import argparse, os, re, sys` is a valid
# command here: `import` is IMAGEMAGICK'S screen capture, which with non-option arguments starts an
# INTERACTIVE grab. It took the X pointer/server grab and waited for a mouse click. The owner's
# xfce4-terminal froze, no GUI process could start for twelve minutes, and the tool call exceeded
# its 120 s timeout and was backgrounded - so the process holding the grab was out of sight. The
# owner asked twice ("why gui is stuck on this qube again"), and my first answer blamed swap, which
# cannot stop a process from STARTING. The same file had run correctly as
# `python3 tools/lint-harness.py` minutes earlier: both spellings were in front of me.
#
# Every blocking case runs TWICE: once with the gate in place (must block) and once with
# WRONG_INTERPRETER_GATE_DEFECT=1, which restores the state where nothing enforced (must NOT
# block). A case that blocks in both runs is being refused by something else, and this says so.
set -u
cd "$(dirname "$0")/../.." || exit 1
GATE=tools/hooks/wrong-interpreter-gate.sh
pass=0; fail=0
T=$(mktemp -d "${TMPDIR:-/tmp}/wronginterp.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

[ -x "$GATE" ] || [ -f "$GATE" ] || { echo "SELFTEST-ERROR: $GATE is missing"; exit 2; }

hookjson(){ python3 -c '
import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" > "$T/hook.json"; }

case_is(){ # <BLOCK|ALLOW> <label> <command>
    local want=$1 label=$2 cmd=$3 rc rc_defect
    hookjson "$cmd"
    bash "$GATE" <"$T/hook.json" >"$T/err" 2>&1; rc=$?
    if [ "$want" = BLOCK ]; then
        WRONG_INTERPRETER_GATE_DEFECT=1 bash "$GATE" <"$T/hook.json" >/dev/null 2>&1; rc_defect=$?
        if [ "$rc" -eq 2 ] && [ "$rc_defect" -eq 0 ]; then
            pass=$((pass+1)); printf '  PASS  %-56s blocked (knob proves the gate did it)\n' "$label"
        elif [ "$rc" -eq 2 ]; then
            fail=$((fail+1)); printf '  FAIL  %-56s blocked WITH the defect knob too - not this gate\n' "$label"
        else
            fail=$((fail+1)); printf '  FAIL  %-56s NOT blocked (rc=%s)\n' "$label" "$rc"
        fi
    else
        if [ "$rc" -eq 0 ]; then
            pass=$((pass+1)); printf '  PASS  %-56s allowed\n' "$label"
        else
            fail=$((fail+1)); printf '  FAIL  %-56s refused correct usage: %s\n' "$label" "$(head -1 "$T/err")"
        fi
    fi
}

echo "--- the exact command that froze the owner's desktop, and its family"
case_is BLOCK "bash <file>.py (THE incident)"          'bash tools/lint-harness.py 2>&1 | tail -3'
case_is BLOCK "sh <file>.py"                           'sh tools/log-sweep.py attribute'
case_is BLOCK "bash <file>.ps1"                        'bash guest/qubesdb-read.ps1'
case_is BLOCK "python3 <file>.sh"                      'python3 mgmt/harness/vmlock.sh'
case_is BLOCK "pwsh <file>.sh"                         'pwsh tools/sweep-gate.sh'
case_is BLOCK "after a pipe"                           'echo hi | bash tools/lint-harness.py'
case_is BLOCK "after a semicolon, mid-command"         'cd /tmp; bash /home/user/x/foo.py --flag'
case_is BLOCK "behind sudo"                            'sudo bash tools/lint-harness.py'
case_is BLOCK "behind timeout"                         'timeout 300 bash tools/lint-harness.py'
case_is BLOCK "behind a variable assignment"           'TMPDIR=/tmp bash tools/lint-harness.py'
case_is BLOCK "inside a for body"                      'for f in a b; do bash tools/x.py "$f"; done'
case_is BLOCK "quoted path"                            'bash "tools/lint harness.py"'
case_is BLOCK "zsh <file>.py"                          'zsh tools/lint-harness.py'
case_is BLOCK "bash <file>.pl"                         'bash tools/old/munge.pl'

echo "--- the right interpreter must never be refused"
case_is ALLOW "python3 <file>.py"                      'python3 tools/lint-harness.py 2>&1 | tail -5'
case_is ALLOW "bash <file>.sh"                         'bash tools/tests/log-sweep-selftest.sh'
case_is ALLOW "pwsh -File <file>.ps1"                  'pwsh -NoProfile -File guest/qubesdb-read.ps1'
case_is ALLOW "bash -c with a script string"           'bash -c "echo import argparse, os, re, sys"'
case_is ALLOW "bash -n (a deliberate syntax check)"    'bash -n mgmt/harness/supervision-e2e.sh'
case_is ALLOW "python3 -m"                             'python3 -m json.tool findings/x.json'
case_is ALLOW "python3 -c"                             'python3 -c "import re; print(1)"'
case_is ALLOW "a .py path as a plain ARGUMENT"         'git add tools/lint-harness.py && wc -l tools/lint-harness.py'
case_is ALLOW "grep for the string in a .py"           'command grep -n import tools/lint-harness.py'
case_is ALLOW "the gate's own name in prose"           'git commit -m "gate: refuse bash tools/lint-harness.py forever"'
case_is ALLOW "a heredoc body that quotes it"          'cat > /tmp/note <<EOF
never run: bash tools/lint-harness.py
EOF'

echo "--- and the shipped tree must not already contain the shape in a RUNNABLE position"
# A repo-wide check, because the gate only sees commands I type. A committed script that
# mis-sources a file would reintroduce the freeze with no gate in the path at all.
hits=$(command grep -rnE '(^|[;&|(]|[[:space:]])(sudo +|env +|timeout +[^ ]+ +)*(bash|sh|dash|zsh|ksh) +[^ ;&|]*\.(py|ps1|pl)\b' \
         --include='*.sh' --include='*.py' --include='*.yml' --include='*.yaml' \
         mgmt tools guest .github 2>/dev/null | command grep -v 'wrong-interpreter' | head -5)
if [ -z "$hits" ]; then
    pass=$((pass+1)); printf '  PASS  %-56s no committed caller mis-sources a script\n' "shipped tree"
else
    fail=$((fail+1)); printf '  FAIL  %-56s a committed caller mis-sources a script:\n%s\n' "shipped tree" "$hits"
    echo "        why it matters: the gate cannot see a command inside a committed script"
fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ] && exit 0 || exit 1
