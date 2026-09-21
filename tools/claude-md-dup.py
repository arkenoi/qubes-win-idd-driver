#!/usr/bin/env python3
"""claude-md-dup.py - CLAUDE.md and .claude/settings.json's autoMode.environment are BOTH always-on
and say several of the same things. This pairs each duplicated rule and lets Jev decide whether the
CLAUDE.md passage is FULLY covered by the shorter environment entry, or carries something the
environment does not - in which case dropping it would lose a rule.

Code pairs and counts; Jev judges coverage. Nothing is written.
"""
from __future__ import annotations
import json, re, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent

PAIRS = [
    ('tag-based / drivable',          'You control every qube TAGGED', 'TAG-based'),
    ('off-limits + capabilities',     'Still genuinely off-limits',     'Genuinely unavailable from here'),
    ('guests disposable/hostile',     'The test VM is disposable and assumed hostile', 'disposable and assumed hostile'),
    ('repo is PUBLIC',                'THE REPO IS PUBLIC',             'THIS REPOSITORY IS PUBLIC'),
    ('serialise rig jobs',            'Run VM-mutating jobs serially',  'Rig jobs are serialised'),
    ('retired/parked stays closed',   'A line the owner has retired is closed', 'RETIRED or PARKED stays closed'),
    ('delegate judgments to Jev',     'Delegate every SEMANTIC judgment to it', 'delegate SEMANTIC judgments to Jev'),
]

RUBRIC = {'questions': {
    'coverage': {'type': 'choice', 'instructions': {'judge':
        'Both texts are injected into EVERY session. Is the CLAUDE.md passage FULLY covered by the '
        'environment entry, so that deleting it from CLAUDE.md loses nothing an agent needs before '
        'acting? Prefer partially-covered when unsure - a lost rule is far worse than a duplicated '
        'paragraph.'},
        'criteria': {
            'fully-covered': 'the environment entry states the same rule with the same force; the CLAUDE.md passage is redundant',
            'partially-covered': 'the environment entry states the rule but the CLAUDE.md passage adds specifics an agent would act on differently without',
            'not-covered': 'the environment entry does not carry this rule',
            'insufficient-evidence': 'cannot judge'}},
    'what_would_be_lost': {'type': 'choice', 'instructions': {'judge':
        'If the CLAUDE.md passage were deleted and only the environment entry remained, what is lost?'},
        'criteria': {
            'nothing': 'the rule survives intact',
            'concrete-commands': 'specific commands, paths or measured values the agent would otherwise have to rediscover',
            'the-reason': 'the incident that produced the rule, which belongs in findings/ anyway',
            'scope-or-exceptions': 'the boundary of the rule - what it does and does not cover',
            'the-rule-itself': 'the binding force of the rule'}}}}

md = (ROOT / 'CLAUDE.md').read_text()
env = json.load(open(ROOT / '.claude/settings.json'))['autoMode']['environment']

def passage(anchor):
    i = md.find(anchor)
    if i < 0: return ''
    s = md.rfind('\n', 0, i) + 1
    e = md.find('\n\n', i)
    return md[s: e if e > 0 else i + 600]

for label, md_anchor, env_anchor in PAIRS:
    p = passage(md_anchor)
    e = next((x for x in env if isinstance(x, str) and env_anchor in x), '')
    if not p or not e:
        print('%-30s SKIP (anchor not found)' % label); continue
    state = ('RULE: %s\n\nTHE ALWAYS-ON ENVIRONMENT ENTRY (%d bytes):\n%s\n\n'
             'THE CLAUDE.md PASSAGE (%d bytes):\n%s\n' % (label, len(e.encode()), e, len(p.encode()), p))
    sd = ROOT / 'scratchpad'; sd.mkdir(exist_ok=True)
    sf = sd / ('jev-dup-%s.txt' % re.sub(r'[^a-z0-9]+', '-', label.lower())[:30])
    rf = sd / 'jev-dup-rubric.json'
    sf.write_text(state, encoding='utf-8'); rf.write_text(json.dumps(RUBRIC), encoding='utf-8')
    r = subprocess.run([sys.executable, str(ROOT / 'tools' / 'jev.py'), str(rf), str(sf)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print('%-30s JEV DID NOT RUN' % label); continue
    cov = re.search(r'coverage choice=(\S+) conf=([0-9.]+)', r.stdout)
    lost = re.search(r'what_would_be_lost choice=(\S+)', r.stdout)
    print('%-30s %6d B  %-19s conf=%s  lost=%s'
          % (label, len(p.encode()), cov.group(1) if cov else '?',
             cov.group(2) if cov else '?', lost.group(1) if lost else '?'))
