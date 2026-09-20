#!/usr/bin/env python3
"""Show what tools/hooks/serial-rig-gate.sh makes of a command line: the segments it splits into,
which it drops, and the text the mutating-verb regex finally sees. Debugging this gate by staring
at it produced three wrong guesses in a row on 2026-09-20; this prints the answer instead.

    tools/tests/gate-explain.py 'some command line'      (or - to read the line on stdin)
"""
import os, re, sys

src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'hooks',
                        'serial-rig-gate.sh'), encoding='utf-8').read()
# Start at the DEFINITIONS, not at the gate's own entry code: the lines above SEP parse the hook
# JSON and sys.exit(0) when it is not JSON - which silently exited this explainer, output and all.
head = 'import os, re, shlex, sys\n' + src[src.index('SEP = re.compile'):src.index("if hook.get('tool_name')")]
ns = {}
exec(head, ns)                                     # this IS the code under test

cmd = sys.stdin.read() if sys.argv[1] == '-' else sys.argv[1]
print('--- raw:', repr(cmd))
pulled, subs = ns['pull_subs'](cmd)
print('--- substitutions lifted out:', subs)
for piece in [pulled] + subs:
    try:
        segs = ns['segments'](piece)
    except ValueError as e:
        print('  [unparseable quoting: %s -> kept whole]' % e); continue
    for toks in segs:
        if toks:
            print('  %s  %s' % ('LAUNCH ' if ns['is_launch'](toks, False) else 'dropped', toks))
kept = ns['strip_prose'](cmd)
print('--- text the verb regex sees:', repr(kept))
mut = re.search(
    r'\bqvm-(create|start|run|clone|remove|shutdown|kill|volume\s+import|volume\s+revert'
    r'|features\s+\S+\s+\S|tags\s+\S+\s+(add|set))\b'
    r'|\bqtest\s+(run|push|pushrun|start|kill|shutdown)\b'
    r'|\bprime-run|\bquick-upgrade|\bmatrix\.sh|\bcheckpoint\.sh\s+(unpark|park)|\breprovision'
    r'|\brelease-acceptance|qubes\.WindowsUpdate|qubes\.VMShell|qubes\.VMExec', kept, re.I)
print('--- MATCH:', mut.group(0) if mut else None)
