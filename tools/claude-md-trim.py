#!/usr/bin/env python3
"""claude-md-trim.py - CLAUDE.md is 2.1x over the always-on budget. Let Jev decide, per section,
what is a BINDING RULE (stays) and what is narrative about how a past mistake happened (belongs in
findings/, which loads on demand).

Owner, 2026-09-21: "ask Jev to help you with that! Let him classify and trim properly."

DIVISION OF LABOUR, the project's standing one: this file SPLITS and COUNTS - sections, bytes,
which rules name an enforcing hook - and Jev CLASSIFIES. Nothing here decides a disposition, and
nothing here writes CLAUDE.md. It emits a proposal plus a candidate file for a human to accept.

    tools/claude-md-trim.py [--limit N] [--out DIR]
"""
from __future__ import annotations
import argparse, json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'CLAUDE.md'

RUBRIC = {'questions': {
    'disposition': {'type': 'choice', 'instructions': {'judge':
        'This is one section of the file that is injected into EVERY session before the first '
        'user message, and the file is 2.1x over its byte budget. Decide what happens to THIS '
        'section. A binding rule that changes what the agent may do must never be weakened; '
        'narrative about HOW a past mistake happened is what competes with it for attention and '
        'belongs in findings/, which loads on demand. Prefer keep-verbatim when unsure - a '
        'wrongly dropped rule is far worse than a wrongly kept paragraph.'},
        'criteria': {
            'keep-verbatim': 'a binding rule or a fact the agent must have before acting; removing or shortening it changes behaviour',
            'keep-rule-drop-story': 'the RULE must stay, but the account of the incident that produced it can move to findings/ and leave a one-line pointer',
            'replace-with-pointer': 'the content is already recorded in a skill or findings/ and a single line naming it is enough',
            'delete-stale': 'superseded, retracted, or describing something that no longer exists',
            'insufficient-evidence': 'cannot judge this section on its own'}},
    'load_bearing': {'type': 'noul', 'instructions': {'judge':
        'Would an agent that never read this section do something DIFFERENT - and worse - on the rig?'},
        'criteria': {'true': 'yes, behaviour would change for the worse', 'false': 'no, it is context rather than instruction'}},
    'already_enforced': {'type': 'noul', 'instructions': {'judge':
        'Does the section itself say the rule is enforced by code (a hook, a lint, a gate, a script that refuses)?'},
        'criteria': {'true': 'it names an enforcing mechanism', 'false': 'it relies on the reader remembering'}}}}


def sections(text: str):
    """Split on top-level headings, keeping the preamble. Deterministic, no judgement."""
    parts, cur, name = [], [], '(preamble)'
    for line in text.splitlines(keepends=True):
        if line.startswith('## '):
            if cur:
                parts.append((name, ''.join(cur)))
            name, cur = line.strip().lstrip('# ').strip(), [line]
        else:
            cur.append(line)
    if cur:
        parts.append((name, ''.join(cur)))
    return parts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--limit', type=int, default=0, help='judge only the N largest sections')
    ap.add_argument('--out', type=Path, default=ROOT / 'scratchpad')
    a = ap.parse_args()
    a.out.mkdir(exist_ok=True)

    secs = sections(SRC.read_text())
    total = sum(len(b.encode()) for _, b in secs)
    order = sorted(secs, key=lambda s: -len(s[1].encode()))
    if a.limit:
        order = order[:a.limit]

    results = []
    for name, body in order:
        nbytes = len(body.encode())
        state = ('SECTION: ' + name + '\n'
                 + 'BYTES: %d of %d in the file (the file is 38,462 bytes and the always-on budget '
                   'for CLAUDE.md + the memory index + skill descriptions is 24,000 TOTAL).\n\n'
                   'THE SECTION, verbatim:\n' % (nbytes, total)
                 + '-' * 70 + '\n' + body + '-' * 70 + '\n')
        sf = a.out / ('jev-cmd-%s-state.txt' % re.sub(r'[^a-z0-9]+', '-', name.lower())[:40])
        rf = a.out / 'jev-cmd-rubric.json'
        sf.write_text(state, encoding='utf-8')
        rf.write_text(json.dumps(RUBRIC), encoding='utf-8')
        p = subprocess.run([sys.executable, str(ROOT / 'tools' / 'jev.py'), str(rf), str(sf)],
                           capture_output=True, text=True)
        if p.returncode != 0:
            print('JEV DID NOT RUN for %r: %s' % (name, p.stderr.strip()[:200]), file=sys.stderr)
            return 2
        out = p.stdout.strip()
        disp = re.search(r'disposition choice=(\S+) conf=([0-9.]+)', out)
        lb = re.search(r'load_bearing noul=([0-9.]+)', out)
        results.append({'name': name, 'bytes': nbytes,
                        'disposition': disp.group(1) if disp else '?',
                        'conf': float(disp.group(2)) if disp else 0.0,
                        'load_bearing': float(lb.group(1)) if lb else 0.0,
                        'raw': out})
        print('%-52s %6d B  %-22s conf=%.2f lb=%.2f'
              % (name[:52], nbytes, results[-1]['disposition'], results[-1]['conf'],
                 results[-1]['load_bearing']))

    keep = sum(r['bytes'] for r in results if r['disposition'] == 'keep-verbatim')
    trim = sum(r['bytes'] for r in results if r['disposition'] in
               ('keep-rule-drop-story', 'replace-with-pointer', 'delete-stale'))
    print('\njudged %d section(s): keep-verbatim %d B, candidates for trimming %d B' %
          (len(results), keep, trim))
    print('NOTHING WAS WRITTEN. CLAUDE.md is the owner\'s binding file; this is a proposal.')
    (a.out / 'claude-md-trim-report.json').write_text(json.dumps(results, indent=1), encoding='utf-8')
    print('report: %s' % (a.out / 'claude-md-trim-report.json'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
