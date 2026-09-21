#!/bin/bash
# serial-rig-gate.sh - Claude Code PreToolUse hook (matcher: Workflow|Agent|Bash).
#
# THE RULE, ENFORCED HERE AND NOT IN PROSE: only ONE rig-MUTATING job runs at a time. A launch
# that would mutate a guest is REFUSED while a live per-guest lock is held by another job
# (${TMPDIR:-/tmp}/qwt-vmlock-<vm>, the lock mgmt/harness/vmlock.sh takes). Owner, 2026-09-17,
# after this session launched two overlapping acceptance workflows: CLAUDE.md's "Run VM-mutating
# jobs serially" was walked past because it was prose. Concurrent jobs on one guest interleave
# their probes and fabricate verdicts, and have destroyed hours of results twice.
#
# NARROW BY DESIGN so it cannot be argued around and cannot block legitimate monitoring:
#   * only MUTATING verbs trip it (qvm-create/start/run/clone/remove/shutdown/kill, qtest
#     run/push/start/kill, prime-run, quick-upgrade, matrix.sh, checkpoint.sh, reprovision,
#     release-acceptance, qubes.WindowsUpdate/VMShell/VMExec). PASSIVE reads - qvm-ls,
#     admin.vm.Stats, qvm-prefs (get), qtest state/shot, tail, grep - are NOT mutating and pass,
#     so you can always watch the running job.
#   * a lock is a conflict ONLY if its recorded holder pid is ALIVE (kill -0), exactly as
#     vmlock.sh's own refusal path decides (a dead holder is a stale lock, not a conflict).
#   * if THIS launch already holds the lock (QWT_VMLOCK_HELD set in the environment), it passes.
#
# stdin: the hook JSON. Exit 0 = allow, 2 = block (message handed back to the model).
# Self-test: tools/tests/serial-rig-gate-selftest.sh. SERIAL_GATE_DEFECT=1 re-introduces the
# original state (nothing enforces) and the self-test must then FAIL.
set -u
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 0
if [ "${SERIAL_GATE_DEFECT:-}" = "1" ]; then exit 0; fi   # GUARD:serial-gate
input=$(cat)
LOCKDIR="${TMPDIR:-/tmp}" python3 - "$input" <<'PY'
import glob, json, os, re, shlex, sys
try:
    hook = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)  # not our JSON - never block on a parse problem of our own
ti = hook.get('tool_input') or {}

# WHAT WE MATCH ON. Naively this was json.dumps(tool_input) - every byte of the call, including
# text that cannot possibly be a command. Measured 2026-09-20: that blocked a plain `git commit`
# because the COMMIT MESSAGE described work on one of the harnesses, so the gate read its own
# subject line as a launch. A message, a heredoc body and a -m argument are prose; a command is a
# command. Strip the prose, keep everything else - in particular do NOT strip ordinary quoting, or
# `bash -c "qvm-kill x"` would walk straight through. (# GUARD:prose)
SEP = re.compile(r'^[|&;()<>]+$')
PASSIVE = re.compile(r'^(ps|grep|egrep|fgrep|pgrep|tail|head|cat|less|awk|sed|echo|printf'
                     r'|date|ls|wc|sort|uniq|cut|tr|jq|stat|df|du|basename|dirname|realpath'
                     r'|which|type|hash|whereis|file)$')
HELPFLAG = ('--help', '-h', '--version')

def pull_subs(cmd):
    """Lift $(...) and `...` bodies OUT of the line. A command substitution RUNS its body, so it
    is a launch site even inside double quotes - where the segment splitter below would otherwise
    never see it. Innermost first, so nesting resolves."""
    subs = []
    for pat in (re.compile(r'\$\(([^()]*)\)'), re.compile(r'`([^`]*)`')):
        while True:
            m = pat.search(cmd)
            if not m:
                break
            subs.append(m.group(1))
            cmd = cmd[:m.start()] + ' ' + cmd[m.end():]
    return cmd, subs

def nl_to_sep(cmd):
    """Turn UNQUOTED newlines into `;`. A newline ends a command exactly as `;` does, but shlex
    treats it as ordinary whitespace and throws it away, so line 2 of a script merges into line 1's
    segment and inherits ITS command word. Measured 2026-09-20: a two-line edit whose second line
    was a read-only `for` loop over harness filenames was refused, because the merged segment began
    with `python3` and the `for`-list rule therefore never looked at it. shlex.lineno does not
    survive punctuation_chars mode reliably, so the boundary is found here, by scanning. A newline
    INSIDE quotes stays a newline - it is part of one argument, not a command break.
    (# GUARD:newline)"""
    out, q, esc = [], None, False
    for ch in cmd:
        if esc:
            out.append(ch); esc = False; continue
        if ch == '\\' and q != "'":
            out.append(ch); esc = True; continue
        if q:
            if ch == q:
                q = None
            out.append(ch); continue
        if ch in ('"', "'"):
            q = ch; out.append(ch); continue
        out.append(' ; ' if ch in '\r\n' else ch)
    return ''.join(out)

def segments(cmd):
    """Split into pipeline/subshell segments WITHOUT splitting inside quotes.

    The first version split with a bare regex on | ; && - which is quote-BLIND, so a `\\|`
    inside a grep PATTERN ended the segment and the pattern's tail landed in command position
    with the passive `grep` in front of it discarded. Measured 2026-09-20: that refused
    `grep -n 'a\\|b' "$(command -v qvm-shutdown)"`, a pure read, while a run held a lock.
    shlex knows about quoting; ValueError (unbalanced quotes) falls back to the whole line,
    which is the STRICT direction - it may block, it cannot silently allow. (# GUARD:quoting)"""
    lex = shlex.shlex(nl_to_sep(cmd), posix=False, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ''
    segs, cur = [], []
    for t in lex:
        if SEP.match(t):
            segs.append(cur); cur = []
        else:
            cur.append(t)
    segs.append(cur)
    return segs

# Shell KEYWORDS are not commands. Two kinds:
#   PREFIX  - what follows is still a command      (`if qvm-kill x`, `time qvm-start y`)
#   DATA    - what follows is a word LIST, not a command. `for f in a.sh b.sh` names FILES;
#             reading one of those names as an invocation is how this gate refused a plain
#             `for f in ... mgmt/reprovision-usb.sh ...; do grep ...; done` on 2026-09-20.
KW_PREFIX = {'if', 'elif', 'while', 'until', 'do', 'then', 'else', '!', 'time', '{', '}',
             'nohup', 'exec', 'source', '.'}
KW_DATA = {'for', 'select', 'case', 'in', 'esac', 'fi', 'done', 'local', 'declare', 'export',
           'readonly', 'return', 'exit', 'break', 'continue', 'shift', 'set', 'unset', 'trap'}

def is_launch(toks, overstrip):
    """Does this segment RUN something that mutates? toks is one segment, already split."""
    i = 0
    while i < len(toks) and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', toks[i]):
        i += 1                      # step over leading env assignments
    while i < len(toks) and toks[i] in KW_PREFIX:
        i += 1                      # `if`/`time`/`nohup` - the command is what comes after
    if i < len(toks) and toks[i] in KW_DATA:
        return False                # (# GUARD:keyword) the rest is a word list, not a command
    if i >= len(toks):
        return False
    name = os.path.basename(toks[i].strip('\'"'))
    rest = toks[i + 1:]
    if PASSIVE.match(name):
        return False
    if name in ('command', 'builtin') and rest and rest[0] in ('-v', '-V'):
        return False                # `command -v qvm-shutdown` LOOKS UP a path, runs nothing
    # `bash -n script.sh` PARSES and exits - it is the syntax check you run after editing a
    # harness, and it executes not one line of it. Measured 2026-09-20: refused while a run held a
    # lock, because the FILENAME was tools/release-acceptance.sh. -c is the executing form, so its
    # presence disqualifies the exemption. (# GUARD:syntaxcheck)
    if name in ('bash', 'sh', 'dash', 'zsh', 'ksh') and '-n' in rest and '-c' not in rest:
        return False
    # `git add mgmt/harness/matrix.sh` names a PATH. git cannot start a qube, so for these
    # subcommands its arguments are filenames, not invocations - measured 2026-09-20, staging the
    # very fix for this class was refused. `bisect run` and `submodule foreach` DO run commands and
    # are deliberately absent from the list. (# GUARD:git)
    if name == 'git' and rest:
        sub = next((t for t in rest if not t.startswith('-')), '')
        if sub in ('add', 'rm', 'mv', 'status', 'diff', 'log', 'show', 'commit', 'checkout',
                   'switch', 'restore', 'stash', 'reset', 'tag', 'config', 'ls-files', 'blame',
                   'apply', 'fetch', 'pull', 'push', 'branch', 'remote', 'rev-parse', 'grep',
                   'cat-file', 'clean', 'describe', 'shortlog', 'worktree'):
            return False
    # A qvm-* verb asked for its own USAGE is documentation: argparse prints and exits before
    # any action. The flag must be its OWN token - inside a quoted argument it belongs to the
    # GUEST's command line, not to qvm-run. (# GUARD:usage)
    if name.startswith('qvm-'):
        if overstrip:
            return not any(f in ' '.join(rest) for f in HELPFLAG)
        if any(t in HELPFLAG for t in rest):
            return False
    return True

def strip_prose(cmd):
    # heredoc bodies: <<EOF ... EOF, <<'EOF' ... EOF, <<-"EOF" ... EOF
    cmd = re.sub(r"<<-?\s*(['\"]?)(\w+)\1.*?^\s*\2\s*$", " ", cmd, flags=re.S | re.M)
    # A commit/tag message argument: -m '...', -m "...", --message=... . The double-quoted arm
    # MUST understand backslash escapes: a message that itself quotes a command ( \"qvm-kill x\" )
    # ends the naive [^"]* at the first inner quote and leaves the rest of the message exposed,
    # which is exactly how this blocked its own fix commit on 2026-09-20.
    cmd = re.sub(r"(?:^|\s)(?:-m|--message)(?:=|\s+)('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")", " ", cmd, flags=re.S)
    # `git commit -F -` style: the body arrives on stdin, already covered by the heredoc rule
    #
    # COMMAND POSITION. A rig verb is a launch only when something RUNS it. As an argument to a
    # read-only inspector it is a search pattern - and the gate's own refusal text tells you to
    # watch a running job with passive reads, so blocking `ps ... | grep quick-upgrade.sh` refuses
    # the very thing it recommends (measured 2026-09-20, the third shape of this same over-match).
    # Deliberately NOT passive: find and xargs (-exec runs things) and python3 (subprocess).
    overstrip = os.environ.get('SERIAL_GATE_DEFECT') == '2'   # GUARD:overstrip
    body, subs = (cmd, []) if overstrip else pull_subs(cmd)
    kept = []
    for piece in [body] + subs:
        try:
            segs = segments(piece)
        except ValueError:
            kept.append(piece); continue      # unparseable quoting -> keep it all (strict)
        for toks in segs:
            if is_launch(toks, overstrip):
                kept.append(' '.join(toks))
    return ' ; '.join(kept)

if hook.get('tool_name') in ('Bash', 'BashOutput') and isinstance(ti.get('command'), str):
    text = strip_prose(ti['command'])
    # The UNNARROWED command, kept for GUARD:lockscope only. strip_prose keeps command-position
    # segments and drops the rest - so in `for vm in a b c; do qvm-remove $vm; done` the guest
    # NAMES are dropped and only the loop body survives. Deciding WHICH guests a launch touches
    # from that text answers "none" for exactly the shape that most needs the answer.
    full_text = ti['command']
else:
    text = json.dumps(ti, ensure_ascii=False)
    full_text = text

# MUTATING verbs only. Passive reads (qvm-ls, admin.vm.Stats, qvm-prefs get, qtest state/shot)
# are deliberately absent so monitoring a running job is never blocked.
mut = re.compile(
    r'\bqvm-(create|start|run|clone|remove|shutdown|kill|volume\s+import|volume\s+revert|features\s+\S+\s+\S|tags\s+\S+\s+(add|set))\b'
    r'|\bqtest\s+(run|push|pushrun|start|kill|shutdown)\b'
    r'|\bqwt_shutdown\b'                      # shutdown-lib.sh's wrapper is a power cycle too
    r'|\bprime-run|\bquick-upgrade|\bmatrix\.sh|\bcheckpoint\.sh\s+(unpark|park)|\breprovision|\brelease-acceptance'
    r'|qubes\.WindowsUpdate|qubes\.VMShell|qubes\.VMExec', re.I)
hit = mut.search(text)
if not hit:
    sys.exit(0)
# WHAT was matched, and in which surviving segment. A refusal that only says "something matched"
# cost three wrong guesses on 2026-09-20 about which shape had tripped it; the gate knows, so it
# says. (# GUARD:explain)
lo, hi = max(0, hit.start() - 40), min(len(text), hit.end() + 40)
why = 'matched %r in: ...%s...' % (hit.group(0), text[lo:hi])

# If this very launch already owns a guest lock, it is the running job, not a second one.
if os.environ.get('QWT_VMLOCK_HELD'):
    sys.exit(0)

lockdir = os.environ.get('LOCKDIR', '/tmp')

# Which guests does this launch NAME? Needed by GUARD:lockscope below, and by the rig-state
# invariant further down, so it is read once. MISSING DATA FAILS: if the rig cannot be listed,
# named_guests stays empty and every lock refuses, which is the conservative direction.
import subprocess as _sp
_known = set()
try:
    _ls = _sp.run(['qvm-ls', '--raw-data', '--fields', 'name,state'],
                  capture_output=True, text=True, timeout=45)
    if _ls.returncode == 0 and _ls.stdout.strip():
        _known = {l.split('|')[0] for l in _ls.stdout.splitlines() if '|' in l and l.split('|')[0]}
except Exception:
    _known = set()
named_guests = {n for n in _known
                if re.search(r'(?<![\w.-])' + re.escape(n) + r'(?![\w.-])', full_text)}
if os.environ.get('SERIAL_GATE_DEFECT') == '4':   # re-introduces the over-match this guard fixes
    named_guests = set()

def alive(pid):
    try:
        os.kill(int(pid), 0); return True
    except (OSError, ValueError):
        return False

for lf in sorted(glob.glob(os.path.join(lockdir, 'qwt-vmlock-*'))):
    try:
        lines = [l for l in open(lf, encoding='utf-8', errors='replace').read().splitlines() if l.startswith('pid=')]
    except Exception:
        continue
    if not lines:
        continue
    last = lines[-1]   # run.py appends its own holder line; vmlock parses the LAST
    holder = re.search(r'\bholder=(\d+)', last)
    jobpid = re.search(r'\bpid=(\d+)', last)
    live_pid = None
    for m in (holder, jobpid):
        if m and alive(m.group(1)):
            live_pid = m.group(1); break
    if live_pid:
        vm = os.path.basename(lf).replace('qwt-vmlock-', '')
        # ---- GUARD:lockscope
        # A lock is PER GUEST, so it may only refuse a launch that touches THAT guest. Measured
        # 2026-09-21: removing six halted, unrelated leftovers was refused because a live job held
        # win11de-fb6 - a launch that could not have interleaved with it by any mechanism. An
        # over-match teaches people to route around the gate, which is how gates die.
        # The hole this must NOT open: a launch that names NO guest can still be driving the locked
        # one through QTEST_VM, which is exactly the 2026-09-21 mis-targeting. So the exemption
        # requires the launch to name at least one known guest AND not to name this locked one.
        if named_guests and vm not in named_guests:
            continue
        sys.stderr.write(
            f"BLOCKED by tools/hooks/serial-rig-gate.sh: a rig-mutating launch was refused because guest '{vm}' is "
            f"already held by a LIVE job (lock {lf}, holder pid {live_pid} alive):\n  {last}\n"
            f"Only one mutating job per guest runs at a time - two interleave their probes and fabricate verdicts "
            f"(CLAUDE.md 'Run VM-mutating jobs serially'). WATCH the running job with passive reads (qvm-ls, "
            f"admin.vm.Stats, qtest state/shot) instead, or wait for it to finish / stop it BY PID with SIGTERM "
            f"(never pkill -f). If that lock is stale, its holder pid would be dead - it is not.\n"
            f"The gate {why}\n"
            f"If that is not a launch, it is an over-match: tools/tests/gate-explain.py '<the line>' "
            f"shows the segmentation, and tools/tests/serial-rig-gate-selftest.sh is where the fix "
            f"gets a check.\n")
        sys.exit(2)

# ---------------------------------------------------------------------------------------------
# SECOND INVARIANT: ONE GUEST AT A TIME, whether or not anybody took a lock. (# GUARD:rigstate)
#
# Measured 2026-09-21, twice in one session 5.5 hours apart: every launch that produced two
# concurrent guests was a hand-written scratch probe run straight from Bash. Those take no
# vmlock, so the loop above found nothing to conflict with and allowed all of them - the gate
# was enforcing the rule only against the harnesses that were ALREADY obeying it. Owner:
# "you were expected to run one test guest at a time, no?" and, hours later, "you are running
# two concurrent guests again, whats the actual fuck". Jev classified both episodes
# mechanized-but-bypassable (0.99, 1.00) and rated this class the likeliest to recur (0.42).
#
# So the RIG's state decides, not the presence of a lock file: a launch that could START a guest
# is refused while some OTHER guest is already up. Verbs that REDUCE concurrency - shutdown,
# kill, remove - are never refused here. A launch naming only guests that are already up is the
# running job being worked on, and passes.
START = re.compile(r'\bqvm-(start|run)\b'
                   r'|\bqtest\s+(run|push|pushrun|start)\b'
                   r'|\bprime-run|\bquick-upgrade|\bmatrix\.sh|\bcheckpoint\.sh\s+unpark'
                   r'|\breprovision|\brelease-acceptance'
                   r'|qubes\.WindowsUpdate|qubes\.VMShell|qubes\.VMExec', re.I)
if os.environ.get('SERIAL_GATE_DEFECT') == '3':   # re-introduces the 2026-09-21 hole
    sys.exit(0)
if not START.search(text):
    sys.exit(0)

import subprocess, socket
def refuse(msg):
    sys.stderr.write("BLOCKED by tools/hooks/serial-rig-gate.sh (one guest at a time): " + msg + "\n")
    sys.exit(2)

# MISSING DATA FAILS - an unreadable rig state must not read as "nothing is running". qvm-ls is
# called through PATH so a test can put a fake one in front of it.
try:
    ls = subprocess.run(['qvm-ls', '--raw-data', '--fields', 'name,state'],
                        capture_output=True, text=True, timeout=45)
    if ls.returncode != 0 or not ls.stdout.strip():
        raise RuntimeError((ls.stderr or '').strip()[:200] or 'empty listing')
except Exception as e:
    refuse(f"the rig's power state could not be read ({e}), so this launch cannot be shown to be "
           f"the only one. Fix the read or stop the other job; an unreadable state is not an idle rig.")

rows = [l.split('|') for l in ls.stdout.splitlines() if '|' in l]
me = socket.gethostname().split('.')[0]
known = {r[0] for r in rows if r[0]}
running = {r[0]: r[1] for r in rows if len(r) > 1 and r[1] != 'Halted' and r[0] not in ('dom0', me)}
if not running:
    sys.exit(0)
# Which guests does this launch name? Qube names contain '-', so \b is useless here.
# The local qube and dom0 are excluded from NAMED as well as from RUNNING. Measured 2026-09-21: a
# launch was refused because the string 'win-idd-mgmt' appeared in a QubesIncoming PATH
# (C:\Users\...\QubesIncoming\win-idd-mgmt) - naming this dev qube in a path is not touching a
# second guest, and `running` already excludes it, so it could never satisfy the subset test.
named = {n for n in known
         if n not in ('dom0', me)
         and re.search(r'(?<![\w.-])' + re.escape(n) + r'(?![\w.-])', text)}
if named and named <= set(running):
    sys.exit(0)
up = ', '.join(f"{v} ({s})" for v, s in sorted(running.items()))
tgt = ', '.join(sorted(named)) if named else 'a guest it does not name'
refuse(
    f"{len(running)} guest(s) are already up ({up}) and this launch would touch {tgt}.\n"
    f"  Two rig jobs at once interleave their probes and fabricate verdicts (CLAUDE.md 'Run VM-mutating "
    f"jobs serially'; .claude/skills/rig-cycle #2). The gate above only sees jobs that TAKE a vmlock - "
    f"this check sees the rig itself, which is how two guests got up twice on 2026-09-21.\n"
    f"  To proceed: stop the other guest first (qvm-shutdown / qvm-kill / qvm-remove are never refused "
    f"here), or, if this launch IS the job that owns it, take the lock - "
    f"`source mgmt/harness/vmlock.sh; vm_lock <vm>` - which exempts it.\n"
    f"  The gate {why}")
sys.exit(0)
PY
