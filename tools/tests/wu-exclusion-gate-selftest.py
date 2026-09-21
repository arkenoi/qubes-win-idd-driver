#!/usr/bin/env python3
"""Drive tools/wu-exclusion-audit.py's gate with the defect present.

The gate decides whether a wu-e2e run may be called green when items were excluded from the count
dom0 hears. A gate that has never been seen to FAIL is not evidence (CLAUDE.md), so every case
below asserts a specific outcome, and the PASS cases are written so that flipping one field alone
turns them into failures - that is what makes the pass meaningful.

No network, no Jev, no rig: the gate is fed the answer shapes jev.py writes with --out.
"""
import io, sys, contextlib
from pathlib import Path

import importlib.util
spec = importlib.util.spec_from_file_location(
    'wu_exclusion_audit', Path(__file__).resolve().parent.parent / 'wu-exclusion-audit.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


def item(choice, conf=0.9, concealed=0.0, reason_noul=0.9, dm='artefact-version', evidence=True):
    probs = {choice: conf, 'concealed-failure': concealed}
    return {'lines': '', 'rounds': ['round1'], 'evidence': evidence,
            'answers': {'classification': {'type': 'choice', 'choice': choice,
                                           'confidence': conf, 'probabilities': probs},
                        'reason_fits': {'type': 'noul', 'noul': reason_noul},
                        'decisive_measurement': {'type': 'choice', 'choice': dm,
                                                 'confidence': 0.8, 'probabilities': {dm: 0.8}}}}


CASES = [
    # (name, verdicts, expected rc, what must appear in the output)
    ('clean: a correct exclusion and a perpetual item',
     {'KB1': item('correct-exclusion'), 'DEFENDER': item('perpetual-by-nature')}, 0,
     'positively judged'),
    ('DEFECT: an item judged a concealed failure',
     {'KB1': item('correct-exclusion'), 'KB2': item('concealed-failure', concealed=0.8)}, 1,
     'CONCEALED FAILURE  KB2'),
    ('DEFECT: benign CHOICE but the probability mass says concealed',
     {'KB2': item('correct-exclusion', conf=0.45, concealed=0.55)}, 1, 'CONCEALED FAILURE'),
    ('DEFECT: insufficient evidence is UNPROVEN, not a pass',
     {'KB3': item('insufficient-evidence', conf=0.3, evidence=False)}, 1,
     'NO independent evidence was supplied'),
    ('DEFECT: a benign class resting on a reason that does not fit the item',
     {'KB4': item('correct-exclusion', reason_noul=0.2)}, 1, 'UNPROVEN           KB4'),
    ('DEFECT: no classification answer at all (instrument gave nothing)',
     {'KB5': {'lines': '', 'rounds': ['round1'], 'evidence': True, 'answers': {}}}, 1, 'UNPROVEN'),
    ('the decisive measurement is NAMED so the next step is actionable',
     {'KB6': item('concealed-failure', concealed=0.9, dm='cbs-servicing')}, 1,
     'decisive measurement: cbs-servicing'),
]

bad = 0
for name, verdicts, want_rc, want_txt in CASES:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = m.gate(verdicts)
    out = buf.getvalue()
    ok = (rc == want_rc) and (want_txt in out)
    print(('OK   ' if ok else 'FAIL ') + name + f'  (rc={rc}, want {want_rc})')
    if not ok:
        bad += 1
        print('\n'.join('       ' + l for l in out.strip().splitlines()))

print('GATE SELFTEST: ' + ('OK - the gate passes clean and was seen to FAIL on every defect'
                           if not bad else f'{bad} case(s) wrong'))
sys.exit(1 if bad else 0)
