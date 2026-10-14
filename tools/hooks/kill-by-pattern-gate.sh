#!/bin/bash
# kill-by-pattern-gate.sh - Claude Code PreToolUse hook (matcher: Bash).
#
# THE RULE, AND IT IS ABSOLUTE: a process is never signalled because it MATCHED something. Only a
# pid that was written down, or one printed and read first, may be signalled.
#
# WHY A HOOK AND NOT A NOTE. This has now happened three times in this project, every time with the
# same mechanism and every time to my own shell:
#   * 2026-10-10, owner in capitals ("PKILL IS HARD PROHIBITED FOREVER"): a `pgrep`-fed kill loop
#     killed my own tool shell twice in one morning, because THE MATCHER CARRIES THE TEXT IT
#     SEARCHES FOR - a tool shell's /proc/<pid>/cmdline contains the whole command being run,
#     including the pattern, so any process-wide match includes the searcher.
#   * 2026-10-15, stopping an acceptance campaign: `for p in /proc/[0-9]*; do case $(cmdline) in
#     *release-accept*|*harness/matri*) ... ; done | while read pid; do kill -TERM "$pid"`. The two
#     campaign pids died as intended and SO DID TWO OF MY OWN SHELLS, whose cmdline contained those
#     very patterns. Minutes earlier I had done it correctly on the same task - print the candidates,
#     read them, signal two literal pids - which is the shape this gate forces.
# lint-harness.py L17 covers scripts IN the repo and knows `pkill -f` and `kill $(pgrep -f ...)`; it
# does not know the /proc-scan spelling and it cannot see a command I type. Hence this.
#
# WHAT IT BLOCKS: a signal verb (kill/pkill/killall/taskkill/Stop-Process) in the same command as a
# process-DISCOVERY source (pgrep, pidof, killall, pkill, `ps`, a /proc/<glob> scan). WHAT IT
# ALLOWS: a literal pid (`kill -TERM 12345`), a pid read from a file something wrote down
# (`kill "$(cat x.pid)"`), a liveness PROBE (`kill -0 <pid>`, which signals nothing), and reading
# /proc without signalling - identify, print, then signal in a SEPARATE command.
#
# stdin: the hook JSON. Exit 0 = allow, 2 = block. Self-test: tools/tests/killpattern-gate-selftest.sh.
# KILL_BY_PATTERN_GATE_DEFECT=1 restores the state where nothing enforced; the self-test needs it.
set -u
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 0
if [ "${KILL_BY_PATTERN_GATE_DEFECT:-}" = "1" ]; then exit 0; fi   # GUARD:kill-by-pattern
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
    """A commit message or heredoc body that TALKS about killing is prose. Same guard, and the same
    reason, as golden-boot-gate.sh: this gate's own fix commit describes the commands it forbids."""
    c = re.sub(r"<<-?\s*(['\"]?)(\w+)\1.*?^\s*\2\s*$", " ", c, flags=re.S | re.M)
    c = re.sub(r"(?:^|\s)(?:-m|--message)(?:=|\s+)('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")",
               " ", c, flags=re.S)
    return c


text = strip_prose(cmd)

# A signal verb at a COMMAND position: start of the line or after a separator / pipe / `do` / `then`.
SIGNAL = re.compile(
    r"(?:^|[;&|(]|\bdo\b|\bthen\b|\belse\b|\{|`|\$\()\s*"
    r"(?:sudo\s+|env\s+|command\s+|timeout\s+\S+\s+|xargs\s+(?:-[^\s]+\s+)*)*"
    r"(pkill|killall|taskkill|kill)\b", re.I)
# PowerShell's spellings never take a pid in our scripts' usage.
PS_SIGNAL = re.compile(r"\bStop-Process\b|\.Kill\(\)", re.I)

# Process DISCOVERY: anything that finds a process by what it looks like rather than by a recorded id.
DISCOVERY = [
    (re.compile(r"\bpgrep\b"),                       "pgrep"),
    (re.compile(r"\bpidof\b"),                       "pidof"),
    (re.compile(r"\bpkill\b"),                       "pkill"),
    (re.compile(r"\bkillall\b"),                     "killall"),
    (re.compile(r"\bps\s+-|\bps\s+a?u?x\b"),         "ps"),
    (re.compile(r"/proc/\[?[0-9*?]"),                "a /proc scan"),
    (re.compile(r"/proc/\*/"),                       "a /proc scan"),
    (re.compile(r"\bGet-Process\b", re.I),           "Get-Process"),
]

sig = SIGNAL.search(text)
ps_sig = PS_SIGNAL.search(text)
if not sig and not ps_sig:
    sys.exit(0)

# `kill -0` signals nothing - it is the sanctioned liveness probe.
only_probe = bool(sig) and not ps_sig and re.search(r"\bkill\s+-0\b", text) and not re.search(
    r"\bkill\s+(?!-0\b)(?:-[A-Za-z0-9]+\s+)*", text)
if only_probe:
    sys.exit(0)

found = [name for rx, name in DISCOVERY if rx.search(text)]
if not found:
    sys.exit(0)

verb = (sig.group(1) if sig else (ps_sig.group(0) if ps_sig else '?'))
sys.stderr.write(f"""BLOCKED by kill-by-pattern-gate.sh: `{verb}` in the same command as {found[0]}.
A process is NEVER signalled because it MATCHED something. THE MATCHER CARRIES THE TEXT IT SEARCHES
FOR: this tool shell's own /proc/<pid>/cmdline contains the whole command being run, pattern
included, so a process-wide match includes the searcher. It has killed my own shell three times -
2026-10-10 twice via pgrep ("PKILL IS HARD PROHIBITED FOREVER"), and 2026-10-15 via a /proc scan
piped into kill while stopping an acceptance campaign.
Do it in TWO commands, which is the shape that worked on that same task minutes earlier:
  1. IDENTIFY and PRINT, signalling nothing:
       for p in /proc/[0-9]*; do c=$(tr '\\0' ' ' < "$p/cmdline"); case "$c" in
         *<what you mean>*) echo "${{p#/proc/}} $c";; esac; done
  2. READ that output, then signal the LITERAL pids you saw:
       kill -TERM 12345 67890
A pid a process WROTE DOWN is also fine (kill "$(cat run.pid)"), as is `kill -0 <pid>` to probe.
""")
sys.exit(2)
PY
