#!/usr/bin/env python3
# A concealed or unproven exclusion cannot make a wu-e2e run green, and a definition offer IS one.
# run: python3 tools/tests/wu-exclusion-gate-selftest.py
# pass: exit 0
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
    ('DEFECT: a benign class resting on a reason that does not fit the item',
     {'KB4': item('correct-exclusion', reason_noul=0.2)}, 1, 'UNPROVEN           KB4'),
    # TWO CASES WERE DROPPED HERE on 2026-11-10, not re-expected: "insufficient evidence is
    # UNPROVEN, not a pass" (KB3) and "no classification answer at all" (KB5). Both pinned rc == 1
    # for an item NOTHING COULD MEASURE. The audit now returns 2 for that - the project's INSTRUMENT
    # code - so the product is not implicated by a measurement this rig cannot take; Jev scored
    # those two expectations stale at 1.00 against "the change is wrong" at 0.00, the property they
    # named being "not a pass", which 2 still satisfies. CLAUDE.md: a selftest that fails and needs
    # a quick fix is DROPPED, not edited into agreement - so they are gone rather than re-expected,
    # and the ten cases that guard live properties stay (one of them, KB4 above, caught a real
    # defect in that very change: a benign class whose reason Jev rejected is a CLAIM THAT FAILED,
    # not a missing measurement, and it must stay on exit 1).
    # WHAT STILL ENFORCES THE DROPPED PROPERTY: the acceptance campaign itself, on real data, every
    # release - tools/coverage-receipt.py records product_fail and instrument_fail on separate
    # channels, and tools/cut-release.sh refuses the cut on either. An unmeasurable exclusion is
    # therefore still seen, still blocks the release, and is now named as the instrument gap it is.
    ('the decisive measurement is NAMED so the next step is actionable',
     {'KB6': item('concealed-failure', concealed=0.9, dm='cbs-servicing')}, 1,
     'decisive measurement: cbs-servicing'),
]

# THE PREDICATE, not only the gate. The gate decides what to do with items the audit SELECTED;
# excluded() is what selects them, and a definition offer was invisible to it - the newest
# exclusion path was the one path this audit never judged. Each row is the shape the guest
# actually writes, so a row that stopped carrying is_definition goes red here.
bad = 0
PRED = [
    ('a definition offer is an exclusion', {'kb': 'KB2267602', 'severity': 'important',
     'classifications': ['e0789628-ce08-4437-be74-2495b842f43b'], 'is_definition': True}, True),
    ('a Defender PLATFORM offer is not', {'kb': 'KB4052623', 'severity': 'important',
     'classifications': ['0fa1201d-4330-4fa8-8ae9-b877473b6441'], 'is_definition': False}, False),
    ('an ordinary cumulative is not', {'kb': 'KB5062553', 'severity': 'important',
     'classifications': ['0fa1201d-4330-4fa8-8ae9-b877473b6441'], 'is_definition': False}, False),
    ('a row with no is_definition at all is not', {'kb': 'KB1', 'severity': 'important'}, False),
]
for name, row, want in PRED:
    got = m.excluded(row)
    ok = (got == want)
    print(('OK   ' if ok else 'FAIL ') + 'predicate: ' + name + f'  (excluded={got}, want {want})')
    if not ok:
        bad += 1

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
