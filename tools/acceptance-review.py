#!/usr/bin/env python3
"""acceptance-review.py - before a campaign runs, have Jev split it into the part that is
MECHANIZED and the part that is a JUDGEMENT, and say which judgements must be delegated.

Owner, 2026-09-21: "adjust acceptance scenario to Jev first (recheck mechanized part, delegate
judgement on non-mechanical stuff)."

Why this is not a reading exercise. A campaign cell states its own verdict, and the failure mode
this project keeps hitting is a check that CANNOT FAIL - it reads as a verdict while resting on
something the code never actually decides, or on something only a human eye could decide and no eye
is present. That is a classification over each cell, so it goes to Jev (see
.claude/skills/jev/SKILL.md and the memory note classifiers-belong-to-jev). Extraction and counting
stay here.

    tools/acceptance-review.py [--file mgmt/harness/matrix.sh]
"""
from __future__ import annotations
import argparse, json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

RUBRIC = {"questions": {
    "verdict_kind": {"type": "choice", "instructions": {"judge":
        "What KIND of verdict does this acceptance cell reach? Judge only the code in `state`. "
        "A comment claiming something is checked is not evidence that it is."},
        "criteria": {
            "mechanized": "every claim it makes is decided from deterministic facts the code actually reads",
            "needs-judgement": "it rests on something no deterministic rule settles - what a screen shows, whether a rendering is correct, which failure class a log excerpt is - and that judgement should be delegated rather than eyeballed",
            "cannot-fail": "it states a verdict that its own checks could not contradict",
            "insufficient-evidence": "the extract does not show enough to say"}},
    "delegate_what": {"type": "choice", "instructions": {"judge":
        "If a judgement is involved, what is it ABOUT? Pick the closest; 'none' if the cell is fully mechanized."},
        "criteria": {
            "screen-content": "what is actually on screen - desktop vs installer vs recovery vs lock screen",
            "rendering-correctness": "whether windows, borders, menus or toasts are rendered correctly",
            "log-classification": "which known failure class a log excerpt shows",
            "state-causation": "which of several candidate causes an observed guest state supports",
            "none": "fully mechanized, nothing to delegate"}},
    "blocking": {"type": "noul", "instructions": {"judge":
        "Would running this cell AS WRITTEN produce a result that could be mistaken for a product "
        "verdict when it is not one?"},
        "criteria": {"true": "it can produce a misleading pass or fail", "false": "its result means what it says"}}}}


def cells(text: str):
    for m in re.finditer(r'^(cell_[a-z]+)\(\)\{', text, re.M):
        name, i, depth = m.group(1), m.end() - 1, 0
        for j in range(i, len(text)):
            if text[j] == '{':
                depth += 1
            elif text[j] == '}':
                depth -= 1
                if depth == 0:
                    yield name, text[m.start():j + 1]
                    break


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--file', default='mgmt/harness/matrix.sh')
    a = ap.parse_args()
    txt = (ROOT / a.file).read_text(errors='replace')
    found = list(cells(txt))
    # the shared grader every install cell ends with - judged as its own unit
    g = re.search(r'^verify_installed\(\)\{.*?\n\}', txt, re.S | re.M)
    if g:
        found.append(('verify_installed', g.group(0)))
    if not found:
        print('no cells found - check the matcher'); return 1
    print(f'{len(found)} acceptance unit(s) to review\n')
    sdir = ROOT / 'scratchpad'; sdir.mkdir(exist_ok=True)
    plan = {}
    for name, body in found:
        body = body if len(body) < 14000 else body[:14000] + '\n# ...truncated for review...'
        state = (f"ACCEPTANCE UNIT `{name}` from {a.file}. It runs against a Windows guest on Qubes "
                 f"and states a verdict that a release decision is taken on.\n\n```bash\n{body}\n```")
        sf = sdir / f'jev-acc-{name}-state.txt'; rf = sdir / f'jev-acc-{name}-rubric.json'
        sf.write_text(state, encoding='utf-8'); rf.write_text(json.dumps(RUBRIC), encoding='utf-8')
        p = subprocess.run([sys.executable, str(ROOT / 'tools' / 'jev.py'), str(rf), str(sf)],
                           capture_output=True, text=True)
        if p.returncode != 0:
            print(f'JEV DID NOT RUN for {name}: rc={p.returncode} {p.stderr.strip()[:200]}', file=sys.stderr)
            return 2
        out = p.stdout.strip()
        print(f'=== {name}')
        print('\n'.join('    ' + l for l in out.splitlines()))
        plan[name] = out
    (sdir / 'acceptance-review.json').write_text(json.dumps(plan, indent=1), encoding='utf-8')
    print('\nplan written to scratchpad/acceptance-review.json')
    return 0


if __name__ == '__main__':
    sys.exit(main())
