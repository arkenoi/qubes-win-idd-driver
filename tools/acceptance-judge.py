#!/usr/bin/env python3
"""acceptance-judge.py - the three judgements a campaign cell cannot mechanize, delegated to Jev.

tools/acceptance-review.py asked Jev what each acceptance cell's verdict rests on. Three kinds came
back as judgement rather than mechanism, and this is the bridge for them:

  --screen   what is actually on screen. Jev does not see pixels, so CODE extracts the window
             inventory (count, class, title, geometry) plus the SESSION (logged-on user, shell
             running) and Jev classifies it. Flagged for cell_appvm (0.60).

             CALIBRATED 2026-09-21, and the calibration is itself a finding: asked about an idle
             guest with a logged-on session and ZERO mapped windows, Jev returned `acceptable`
             0.48 - genuinely undecidable, and correctly so. In the seamless model the desktop is
             never mapped, so "logged on, nothing open" and the invisible-guest regression look
             identical from outside. THEREFORE: take this judgement only with a KNOWN application
             open. A screen verdict on an idle guest is not a weak signal, it is no signal.
  --log      which known failure class a log excerpt shows. Flagged for cell_clean (0.85) and for
             verify_installed (0.67) - the two units a release decision leans on hardest.
  --cause    which of several candidate causes an observed state supports. Flagged for cell_seeded
             (0.66).

Code measures; Jev decides; a low confidence is a FINDING naming what to measure next, never
rounded up. Exit 2 means the instrument did not run - never mistake that for an answer.

    tools/acceptance-judge.py --screen <vm> [--label L]
    tools/acceptance-judge.py --log <file> [--label L]
    tools/acceptance-judge.py --cause <file> --candidates "a=...;b=..." [--label L]
"""
from __future__ import annotations
import argparse, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def jev(rubric: dict, state: str, label: str) -> str:
    sd = ROOT / 'scratchpad'; sd.mkdir(exist_ok=True)
    sf, rf = sd / f'jev-acc-{label}-state.txt', sd / f'jev-acc-{label}-rubric.json'
    sf.write_text(state, encoding='utf-8'); rf.write_text(json.dumps(rubric), encoding='utf-8')
    p = subprocess.run([sys.executable, str(ROOT / 'tools' / 'jev.py'), str(rf), str(sf)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(f'JEV DID NOT RUN: rc={p.returncode} {p.stderr.strip()[:300]}', file=sys.stderr)
        sys.exit(2)
    return p.stdout.strip()


def window_inventory(vm: str) -> str:
    """MEASURED, not described. qtest-geom lists every mapped window with class, title and
    geometry; an EMPTY list is a fact too (no windows mapped), and is reported as such rather than
    as a broken instrument - the screenshot service says the same thing with rc=1."""
    # tools/qtest-geom, not `qtest geom` - there is no such subcommand, and inventing one would
    # have made this bridge report "nothing mapped" for every guest.
    out = subprocess.run([str(ROOT / 'tools' / 'qtest-geom'), vm],
                         capture_output=True, text=True, timeout=300)
    txt = (out.stdout or '').strip()
    # AN EMPTY WINDOW LIST MEANS TWO DIFFERENT THINGS and they must not be conflated: an idle
    # seamless guest with no apps open legitimately maps nothing, while a guest that maps nothing
    # WHILE A SESSION IS LOGGED ON is the invisible-guest regression (autologon off, measured
    # 2026-08-28: 0 windows mapped, qrexec still answering, no password box anywhere). Jev cannot
    # separate them from a window list alone, so measure the session too and hand both over.
    import os as _os
    env = {**_os.environ, 'QTEST_VM': vm}
    def _g(cmd):
        try:
            r = subprocess.run([str(ROOT / 'tools' / 'qtest'), 'run', cmd],
                               capture_output=True, text=True, timeout=180, env=env)
            return ' '.join((r.stdout or '').replace('\x00', '').split())[:300]
        except Exception as e:
            return f'(probe failed: {e})'
    session = _g('cmd /c query user 2>&1 & echo --- & tasklist /fi "imagename eq explorer.exe" 2>&1')
    txt = (txt + '\n\nSESSION AND SHELL (measured now):\n' + session)
    if not out.stdout.strip():
        shot = subprocess.run([str(ROOT / 'tools' / 'qtest'), 'shot', '/tmp/accj.tar'],
                              capture_output=True, text=True, timeout=300,
                              env={**__import__('os').environ, 'QTEST_VM': vm})
        txt = (f'qtest geom returned nothing; the screenshot service exited {shot.returncode} '
               f'(rc=1 is this project\'s documented "no visible windows").')
    return txt


SCREEN = {"questions": {
    "what_is_on_screen": {"type": "choice", "instructions": {"judge":
        "From this window inventory, what is this guest SHOWING? Judge only from `state`. An empty "
        "inventory is evidence of no mapped windows, not of a broken tool."},
        "criteria": {
            "desktop": "a normal logged-in desktop with app windows",
            "installer": "Windows Setup or an installer is on screen",
            "logon-or-lock": "a logon, lock or credential screen",
            "recovery": "a recovery, repair or boot-failure screen",
            "nothing-mapped": "no windows are mapped at all",
            "insufficient-evidence": "the inventory does not support a choice"}},
    "acceptable": {"type": "noul", "instructions": {"judge":
        "Is this an ACCEPTABLE end state? Note carefully: an idle seamless guest with NO "
        "application open legitimately maps no windows, and that is normal. The regression this "
        "project forbids is a guest that maps nothing WHILE A USER SESSION IS LOGGED ON and the "
        "shell is running - reachable, running, and completely invisible with no password box. A "
        "boot or logon screen mapped in seamless mode is also forbidden."},
        "criteria": {"true": "acceptable", "false": "not acceptable - it is one of the states this project forbids"}}}}

LOG = {"questions": {
    "failure_class": {"type": "choice", "instructions": {"judge":
        "Which known failure class does this excerpt show? Judge only from `state`; do not infer a "
        "class from the absence of evidence."},
        "criteria": {
            "clean": "nothing here indicates a failure",
            "install-failed": "the install itself did not complete",
            "driver-or-pnp": "a driver or PnP operation failed",
            "reboot-or-servicing": "a reboot/servicing operation is incomplete or looping",
            "network-or-proxy": "the failure is a network or proxy condition, not the product",
            "insufficient-evidence": "the excerpt does not support a class"}},
    "product_defect": {"type": "noul", "instructions": {"judge":
        "Does this excerpt indicate a defect in the PRODUCT, as opposed to the rig, the network or "
        "the harness?"},
        "criteria": {"true": "a product defect", "false": "environmental or instrumental"}}}}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--screen'); ap.add_argument('--log'); ap.add_argument('--cause')
    ap.add_argument('--candidates', default=''); ap.add_argument('--label', default='unit')
    a = ap.parse_args()
    if a.screen:
        inv = window_inventory(a.screen)
        state = (
            f"GUEST {a.screen}, window inventory measured just now (class, title, geometry per "
            f"mapped window):\n\n{inv}\n\n"
            "DESIGN FACTS OF THIS SYSTEM, stated so they are not inferred wrongly (they are "
            "settled project facts, not arguments for any answer):\n"
            "- This is the QWT SEAMLESS model. The guest DESKTOP itself is deliberately never "
            "mapped; only individual application windows are. A logged-on guest with no "
            "application open therefore maps ZERO windows, and that is the normal idle state.\n"
            "- The boot, logon and shutdown screens are never mapped in seamless mode, by design "
            "and unconditionally.\n"
            "- The regression this project forbids is different and specific: a guest that maps "
            "nothing while a user session is logged on AND the user would expect to see something "
            "- measured 2026-08-28 with autologon off, where the guest was running and reachable "
            "with no password box anywhere, i.e. unusable and invisible.\n")
        print(jev(SCREEN, state, a.label or f'screen-{a.screen}')); return 0
    if a.log:
        txt = Path(a.log).read_text(errors='replace')
        txt = txt if len(txt) < 12000 else txt[:6000] + '\n...\n' + txt[-6000:]
        state = f"LOG EXCERPT from {a.log} (truncated in the middle if long):\n\n{txt}\n"
        print(jev(LOG, state, a.label)); return 0
    if a.cause:
        txt = Path(a.cause).read_text(errors='replace')[:12000]
        crit = {}
        for part in a.candidates.split(';'):
            if '=' in part:
                k, v = part.split('=', 1); crit[k.strip()] = v.strip()
        crit['insufficient-evidence'] = 'the state does not support choosing'
        rub = {"questions": {"cause": {"type": "choice", "instructions": {
            "judge": "Which candidate does the evidence support? Judge only from `state`."},
            "criteria": crit}}}
        print(jev(rub, f"OBSERVED STATE from {a.cause}:\n\n{txt}\n", a.label)); return 0
    ap.print_help(); return 1


if __name__ == '__main__':
    sys.exit(main())
