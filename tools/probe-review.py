#!/usr/bin/env python3
"""probe-review.py - have Jev judge every PROBE in the harnesses BEFORE it is trusted.

Owner, 2026-09-21: "review all probes consistency with Jev before using! Correctness is a simple
verdict you can catch in advance."

That is the lesson of a whole night: almost every "failure" on the rig was an instrument defect,
and each was found by RUNNING it rather than by reading it. They were not subtle, and they repeat:

  * a fixed sleep standing in for a condition that could be observed (60 s "settle" after a reboot)
  * one successful sample treated as a stable state (wait_qrexec returning on the first answer, so
    a 31 MB copy was driven into a guest that had answered once)
  * a transient no-answer treated as a definitive negative (the proxy preflight aborting two runs;
    `type` returning 0 bytes read as "the file says nothing")
  * an empty result treated as a meaningful value rather than as missing data
  * a check whose exit condition the OLD artefact already satisfies (waiting for a guard marker
    that the previous build also contains)
  * a before/after comparison built from different things (three artefacts before, two after, so
    the comparison was always "changed")

Each of those is a CLASSIFICATION over a small piece of code, which is Jev's job, not a hand call
(see .claude/skills/jev/SKILL.md and the memory note classifiers-belong-to-jev). This file does the
extraction and counting; Jev decides.

    tools/probe-review.py [file ...]        (default: the harnesses and rig tools)
    tools/probe-review.py --list            just show what would be judged
"""
from __future__ import annotations
import argparse, json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT = ['mgmt/harness/wu-e2e.sh', 'mgmt/harness/wu-bar.sh', 'mgmt/harness/shutdown-lib.sh']

# A PROBE is a shell function that SAMPLES the guest or the rig and returns a verdict about it.
# Matching is structural: a function whose body reaches for the guest (qtest/qrexec), the toolstack
# (qvm-*), or the network (curl), and which loops or compares.
REACH = re.compile(r'\b(tools/qtest|qrexec-client-vm|qvm-ls|qvm-features|qvm-check|curl)\b')
FUNC = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{', re.M)


def functions(text: str):
    """Every shell function, with its body. Brace counting, not a regex - a regex over nested
    braces silently truncates the body and would hand Jev half a probe to judge."""
    for m in FUNC.finditer(text):
        name, i, depth = m.group(1), m.end() - 1, 0
        for j in range(i, len(text)):
            if text[j] == '{':
                depth += 1
            elif text[j] == '}':
                depth -= 1
                if depth == 0:
                    yield name, text[m.start():j + 1], text[:m.start()].count('\n') + 1
                    break


RUBRIC = {"questions": {
    "defect": {"type": "choice", "instructions": {"judge":
        "Does this probe have one of these defects AS WRITTEN? Judge only the code in `state`. "
        "Every one of these has actually shipped in this project and cost a run, so do not assume "
        "competence; but do not invent a defect either - 'sound' is a real answer."},
        "criteria": {
            "timed-not-proven": "a fixed sleep or timeout stands in for a condition that could be observed directly",
            "single-sample": "one successful sample is treated as a stable state",
            "no-retry": "a transient no-answer or empty result is treated as a definitive negative",
            "empty-as-value": "an empty or missing result is used as if it were a meaningful value",
            "cannot-fail": "the check cannot distinguish the passing case from the failing one",
            "asymmetric-compare": "a before/after comparison is built from different things, so it can report a change that did not happen",
            "sound": "none of these - the probe proves what it claims"}},
    "load_bearing": {"type": "noul", "instructions": {"judge":
        "If this probe is wrong, would a RUN be graded on it - i.e. does a verdict about the "
        "product depend on this answer?"},
        "criteria": {"true": "a product verdict depends on it", "false": "it only affects convenience or logging"}}}}


def judge(name: str, body: str, where: str) -> str:
    state = (f"PROBE `{name}`, from {where}. It runs on a Qubes dev qube against a Windows guest "
             f"reached over qrexec; the guest can be slow, rebooting, or mid-install, and the "
             f"toolstack and an HTTP proxy can both answer late.\n\n```bash\n{body}\n```\n\n"
             "Judge the code as written. Comments describing intent are not evidence that the code "
             "does it.")
    sdir = ROOT / 'scratchpad'; sdir.mkdir(exist_ok=True)
    sf, rf = sdir / f'jev-probe-{name}-state.txt', sdir / f'jev-probe-{name}-rubric.json'
    sf.write_text(state, encoding='utf-8'); rf.write_text(json.dumps(RUBRIC), encoding='utf-8')
    p = subprocess.run([sys.executable, str(ROOT / 'tools' / 'jev.py'), str(rf), str(sf)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(f'JEV DID NOT RUN for {name}: rc={p.returncode} {p.stderr.strip()[:200]}', file=sys.stderr)
        sys.exit(2)          # exit 2 = the instrument did not run; never paper over it
    return p.stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('files', nargs='*', default=DEFAULT)
    ap.add_argument('--list', action='store_true')
    a = ap.parse_args()
    found = []
    for f in (a.files or DEFAULT):
        p = ROOT / f
        if not p.exists():
            print(f'missing: {f}', file=sys.stderr); continue
        txt = p.read_text(errors='replace')
        for name, body, line in functions(txt):
            if REACH.search(body):
                found.append((name, body, f'{f}:{line}'))
    if not found:
        print('no probes found - that is itself suspicious; check the matcher'); return 1
    print(f'{len(found)} probe(s) to judge\n')
    if a.list:
        for n, _, w in found: print(f'  {n:24s} {w}')
        return 0
    bad = 0
    for n, b, w in found:
        out = judge(n, b, w)
        first = out.splitlines()[0] if out else ''
        flag = '' if 'defect choice=sound' in first else '   <-- REVIEW'
        print(f'=== {n}  ({w}){flag}')
        print('\n'.join('    ' + l for l in out.splitlines()))
        if 'defect choice=sound' not in first:
            bad += 1
    print(f'\n{bad} of {len(found)} probe(s) flagged')
    return 0 if bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
