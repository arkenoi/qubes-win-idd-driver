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
import glob, json, os, re, sys
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
def strip_prose(cmd):
    # heredoc bodies: <<EOF ... EOF, <<'EOF' ... EOF, <<-"EOF" ... EOF
    cmd = re.sub(r"<<-?\s*(['\"]?)(\w+)\1.*?^\s*\2\s*$", " ", cmd, flags=re.S | re.M)
    # A commit/tag message argument: -m '...', -m "...", --message=... . The double-quoted arm
    # MUST understand backslash escapes: a message that itself quotes a command ( \"qvm-kill x\" )
    # ends the naive [^"]* at the first inner quote and leaves the rest of the message exposed,
    # which is exactly how this blocked its own fix commit on 2026-09-20.
    cmd = re.sub(r"(?:^|\s)(?:-m|--message)(?:=|\s+)('(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\")", " ", cmd, flags=re.S)
    # `git commit -F -` style: the body arrives on stdin, already covered by the heredoc rule
    return cmd

if hook.get('tool_name') in ('Bash', 'BashOutput') and isinstance(ti.get('command'), str):
    text = strip_prose(ti['command'])
else:
    text = json.dumps(ti, ensure_ascii=False)

# MUTATING verbs only. Passive reads (qvm-ls, admin.vm.Stats, qvm-prefs get, qtest state/shot)
# are deliberately absent so monitoring a running job is never blocked.
mut = re.compile(
    r'\bqvm-(create|start|run|clone|remove|shutdown|kill|volume\s+import|volume\s+revert|features\s+\S+\s+\S|tags\s+\S+\s+(add|set))\b'
    r'|\bqtest\s+(run|push|pushrun|start|kill|shutdown)\b'
    r'|\bprime-run|\bquick-upgrade|\bmatrix\.sh|\bcheckpoint\.sh\s+(unpark|park)|\breprovision|\brelease-acceptance'
    r'|qubes\.WindowsUpdate|qubes\.VMShell|qubes\.VMExec', re.I)
if not mut.search(text):
    sys.exit(0)

# If this very launch already owns a guest lock, it is the running job, not a second one.
if os.environ.get('QWT_VMLOCK_HELD'):
    sys.exit(0)

lockdir = os.environ.get('LOCKDIR', '/tmp')
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
        sys.stderr.write(
            f"BLOCKED by tools/hooks/serial-rig-gate.sh: a rig-mutating launch was refused because guest '{vm}' is "
            f"already held by a LIVE job (lock {lf}, holder pid {live_pid} alive):\n  {last}\n"
            f"Only one mutating job per guest runs at a time - two interleave their probes and fabricate verdicts "
            f"(CLAUDE.md 'Run VM-mutating jobs serially'). WATCH the running job with passive reads (qvm-ls, "
            f"admin.vm.Stats, qtest state/shot) instead, or wait for it to finish / stop it BY PID with SIGTERM "
            f"(never pkill -f). If that lock is stale, its holder pid would be dead - it is not.\n")
        sys.exit(2)
sys.exit(0)
PY
