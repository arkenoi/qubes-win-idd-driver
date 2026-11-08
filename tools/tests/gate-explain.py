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
head = ('import os, re, shlex, sys\n'
        + src[src.index('SEP = re.compile'):src.index("if hook.get('tool_name')")]
        # AND THE VERB REGEX, READ OUT OF THE GATE RATHER THAN COPIED. It is defined BELOW the
        # gate's entry code (`mut = re.compile` at :229 against `if hook.get(` at :216), so the
        # slice above cannot reach it - which is why a hand-written copy used to stand at the
        # bottom of this file. That copy had DRIFTED: it was missing `qwt_shutdown` and the whole
        # `qrexec-client-vm <guest> qubes.*` / `admin.vm.<acting verb>` class added 2026-10-15,
        # so this explainer printed "MATCH: None" for the very shape that incident added - a
        # diagnostic that contradicts the gate on the gate's own case, which is worse than no
        # diagnostic at all. One source of truth: the gate's own text.
        + src[src.index('mut = re.compile'):src.index('hit = mut.search')])
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
            # is_launch takes ONE argument. This passed two, so the explainer died with a
            # TypeError before printing a single segment - on EVERY command line, not just an
            # awkward one. The gate's own refusal text sends you here (serial-rig-gate.sh:324),
            # so the one tool it names for telling an over-match from a real launch answered
            # nothing at all.
            print('  %s  %s' % ('LAUNCH ' if ns['is_launch'](toks) else 'dropped', toks))
kept = ns['strip_prose'](cmd)
print('--- text the verb regex sees:', repr(kept))
hit = ns['mut'].search(kept)
print('--- MATCH:', hit.group(0) if hit else None)
