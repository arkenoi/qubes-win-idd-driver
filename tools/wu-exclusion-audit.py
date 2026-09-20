#!/usr/bin/env python3
"""wu-exclusion-audit.py - judge, PER ITEM, whether an update the guest stopped counting was
CORRECTLY EXCLUDED or is a CONCEALED FAILURE.

Why this exists. The owner asked (2026-09-20): "there is patch tuesday for which we KNOW that it
contains some updates that could be installed. how do we verify 'correct' exclusion versus genuine
failure?" The answer built first was a control PAIR - a pre-Tuesday guest that must not reach
empty, and an updated guest that must. Jev graded that design's ability to discriminate at
**0.24**, and named why with confidence 0.93: it grades dom0's AGGREGATE flag and never looks at
which exclusion reason was applied to which item, so an item excluded for the wrong reason still
yields a correct-looking aggregate. This tool is that missing half.

Division of labour (.claude/skills/jev/SKILL.md): this file EXTRACTS and COUNTS - parsing
update-status.json, deduplicating items across rounds, pairing each with whatever independent
evidence was collected from the servicing stack. Jev makes the judgment, one item at a time,
against the evidence for THAT item. Nothing here writes a verdict of its own.

    tools/wu-exclusion-audit.py <run-dir> [--evidence FILE.json] [--out answers.json]

<run-dir> is a wu-e2e.sh output directory (it contains round1/, round2/, ...).
--evidence is an optional {"<kb>": "<independently measured fact>"} map: what the servicing stack
says about that item, gathered from the guest AFTER the run. An item with no independent evidence
is judged on the row alone, and Jev is told so explicitly - so a thin brief reads as thin.
"""
from __future__ import annotations
import argparse, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def rows(run_dir: Path):
    """Every result row from every round, tagged with the round it came from. Deterministic."""
    for rd in sorted(run_dir.glob('round*'), key=lambda p: int(p.name[5:] or 0)):
        f = rd / 'update-status.json'
        if not f.exists():
            continue
        try:
            d = json.loads(f.read_text(encoding='utf-8-sig'))
        except Exception as e:
            print(f'{rd.name}: update-status.json unreadable ({e}) - MISSING DATA FAILS', file=sys.stderr)
            continue
        for r in (d.get('result') or []):
            yield rd.name, r
        for na in (d.get('not_actionable') or []):
            yield rd.name, {'kb': na if isinstance(na, str) else na.get('kb'),
                            'state': 'not-actionable', '_from': 'not_actionable', 'raw': na}


def excluded(r: dict) -> bool:
    """An item dom0 does NOT hear about as actionable. Structural, not a guess: severity=info
    anywhere in the row, state not-actionable, or an installer whose effect was NOT verified."""
    if r.get('severity') == 'info' or r.get('state') == 'not-actionable':
        return True
    files = r.get('files')
    if isinstance(files, list):
        return any(f.get('severity') == 'info' or f.get('verified_by_effect') is False for f in files)
    return False


def key(r: dict) -> str:
    return str(r.get('kb') or r.get('title') or '<no id>')


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('run_dir', type=Path)
    ap.add_argument('--evidence', type=Path, default=None)
    ap.add_argument('--out', type=Path, default=None)
    a = ap.parse_args()

    ev = json.loads(a.evidence.read_text()) if a.evidence else {}
    items: dict[str, dict] = {}
    for rnd, r in rows(a.run_dir):
        if not excluded(r):
            continue
        k = key(r)
        items.setdefault(k, {'kb': k, 'rounds': [], 'rows': []})
        items[k]['rounds'].append(rnd)
        items[k]['rows'].append(r)
    if not items:
        print('no excluded items found - nothing to audit (that is itself a result: say so)')
        return 0

    verdicts = {}
    for k, it in items.items():
        state = [
            'ITEM UNDER JUDGMENT: ' + k,
            'Seen excluded in rounds: ' + ', '.join(it['rounds']) + ' (of %d round(s) present)'
            % len(list(a.run_dir.glob('round*'))),
            '',
            'THE ROW THE GUEST WROTE (verbatim, first occurrence):',
            json.dumps(it['rows'][0], ensure_ascii=False, indent=1),
            '',
            'WHAT "EXCLUDED" MEANS HERE: dom0 is told a count of ACTIONABLE updates. This item is',
            'not in it, so dom0 can report "up to date" while this item is still outstanding. The',
            'question is whether that is correct (the item genuinely cannot and need not be',
            'installed on this path) or a concealed failure (it could and should have installed,',
            'and something went wrong that the row is papering over).',
            '',
            'RULE THE PROJECT ALREADY COMMITTED TO (docs/ADR-updater.md section 3): an installer',
            'that returns rc=0 without its measured effect is NOT a success, and a probe that ran',
            'and saw nothing is a NEGATIVE result, not a missing one.',
            '',
        ]
        if k in ev:
            state += ['INDEPENDENT EVIDENCE measured on the guest itself, outside the updater:',
                      str(ev[k]), '']
        else:
            state += ['INDEPENDENT EVIDENCE: NONE was collected for this item. The judgment below',
                      'rests on the updater\'s own row - i.e. on the word of the component under',
                      'test. Weigh that.', '']
        if len(it['rows']) > 1:
            state += ['The item was excluded in %d rounds; a REPEAT exclusion across rounds that'
                      % len(it['rows']),
                      'included a reboot is evidence about perpetuity, in either direction.', '']

        rubric = {'questions': {
            'classification': {'type': 'choice', 'instructions': {'judge':
                'Is this exclusion CORRECT or a CONCEALED FAILURE? Judge only from `state`. Do not '
                'treat the updater\'s own reason string as evidence for itself - it is the claim '
                'being tested. Prefer insufficient-evidence over a guess.'},
                'criteria': {
                    'correct-exclusion': 'the item genuinely cannot or need not be installed on this path, and dom0 not counting it is the truth',
                    'concealed-failure': 'the item could and should have installed; the row converts a failure or an unverified result into a benign-looking exclusion',
                    'perpetual-by-nature': 'the item is re-offered by design forever (e.g. signature/definition updates), so excluding it is correct AND it can never be "done"',
                    'insufficient-evidence': 'the state does not support choosing'}},
            'reason_fits': {'type': 'noul', 'instructions': {'judge':
                'Does the REASON the row gives actually fit what this item IS? A true reason applied '
                'to the wrong item, or a generic reason that would fit anything, is false here.'},
                'criteria': {'true': 'the stated reason is specific to this item and consistent with it',
                             'false': 'the reason is generic, unfalsifiable, or inconsistent with the item'}},
            'decisive_measurement': {'type': 'choice', 'instructions': {'judge':
                'Which single measurement on the guest would settle this item?'},
                'criteria': {
                    'artefact-version': 'the version of the artefact this installer actually changes, before and after',
                    'cbs-servicing': 'the servicing stack\'s own record (CBS/UBR/Get-HotFix) for this package',
                    're-offer-after-reboot': 'whether the item is still offered after a completed reboot cycle',
                    'catalog-resolve': 'whether this item resolves to an installable package in the catalog at all',
                    'nothing-material': 'the item is already settled by the evidence given'}}}}

        sdir = ROOT / 'scratchpad'
        sdir.mkdir(exist_ok=True)
        safe = ''.join(c if c.isalnum() else '-' for c in k)[:48]
        sf = sdir / f'jev-excl-{safe}-state.txt'
        rf = sdir / f'jev-excl-{safe}-rubric.json'
        sf.write_text('\n'.join(state), encoding='utf-8')
        rf.write_text(json.dumps(rubric), encoding='utf-8')
        p = subprocess.run([sys.executable, str(ROOT / 'tools' / 'jev.py'), str(rf), str(sf)],
                           capture_output=True, text=True)
        if p.returncode != 0:
            # exit 2 means the INSTRUMENT did not run. Never paper over it as an answer.
            print(f'JEV DID NOT RUN for {k}: rc={p.returncode} {p.stderr.strip()[:300]}', file=sys.stderr)
            return 2
        print(f'=== {k}  (rounds: {", ".join(it["rounds"])}, independent evidence: '
              f'{"yes" if k in ev else "NONE"})')
        print('\n'.join('    ' + l for l in p.stdout.strip().splitlines()))
        verdicts[k] = p.stdout.strip()

    if a.out:
        a.out.write_text(json.dumps(verdicts, indent=1), encoding='utf-8')
    return 0


if __name__ == '__main__':
    sys.exit(main())
