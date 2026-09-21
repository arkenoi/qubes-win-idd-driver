#!/usr/bin/env python3
"""guest-state-judge.py - MEASURE a guest's state, then let Jev NAME it.

Why this exists. Owner, 2026-09-21, after I diagnosed one guest twice and was wrong both times
("no QWT so it ignores ACPI", then "wedged specimen") when it had simply RESTARTED WITHOUT QWT AND
WAS WAITING: *"So when you need to GUESS, ask fucking Jev! He is not THAT BAD in guesswork as
you!"* - and the standing rule that anything which assigns a case to a class belongs to Jev, not to
a hand call. "Which state is this guest in" is exactly that classifier.

The division of labour is the project's: THIS FILE MEASURES AND COUNTS, Jev judges. Nothing here
writes a verdict of its own, and every fact handed over is a measurement with its timestamp, or an
explicit "could not be measured" - because the failure mode being fixed is a verdict built on one
screenshot and a power state.

WHAT IT MEASURES, which is precisely what was available and untaken on 2026-09-21:
  * the power state TWICE, seconds apart, each stamped - `Running` after a restart is
    indistinguishable from `Running` continuously unless you look more than once;
  * the guest's OWN uptime, twice, via qrexec - the only thing that proves whether it has BOOTED
    since the request. If qrexec does not answer, that is reported as a fact, not silently skipped;
  * two screenshots a minute apart, compared - whether the pixels CHANGED, not whether pixels exist
    (a desktop is what an autologon resume looks like);
  * what the boot is WAITING FOR: which block devices are assigned/attached and whether they are
    actually present, since a guest resuming an install without its medium waits forever.

    tools/guest-state-judge.py <vm> [--request "what it was last asked to do"] [--gap SECONDS]
"""
from __future__ import annotations
import argparse, json, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(cmd: list[str], timeout: int = 120) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or '') + (p.stderr or '')
    except subprocess.TimeoutExpired:
        return 124, '<timed out>'
    except Exception as e:                                    # noqa: BLE001
        return 125, f'<{type(e).__name__}: {e}>'


def power(vm: str) -> str:
    rc, out = run(['qvm-ls', '--raw-data', '--fields', 'state', vm], 60)
    return out.strip() if rc == 0 and out.strip() else 'UNREADABLE'


def uptime(vm: str) -> str:
    """The guest's own boot time. This is the ONLY fact that distinguishes 'still up' from 'came
    back up'. No qrexec means no answer - which is itself reported, never treated as 'no reboot'."""
    # NOT wmic - removed from Windows 11 24H2+; on this rig's 25H2 image it answers "could not be
    # found", so the first version of this probe could never return a boot time and every verdict
    # would have been UNKNOWN. Measured 2026-09-21.
    rc, out = run(['tools/qtest', 'run',
                   "powershell -NoProfile -Command "
                   "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')"], 120)
    import re as _re
    m = _re.search(r'\d{4}-\d{2}-\d{2}T[\d:.]+', out.replace('\r', ''))
    if m:
        return m.group(0)
    return f'UNAVAILABLE (no boot time came back; rc={rc})'


def shot_bytes(vm: str, tag: str) -> str:
    sd = ROOT / 'scratchpad'; sd.mkdir(exist_ok=True)
    out = sd / f'gsj-{vm}-{tag}.tar'
    rc, err = run(['tools/qtest', 'shot', str(out)], 120)
    n = out.stat().st_size if out.exists() else 0
    # rc=1 with ZERO bytes is this rig's DOCUMENTED "no visible windows" (mgmt/CLAUDE.md), i.e. a
    # measurement about the guest - NOT a broken instrument. Reporting it as "no capture" hands the
    # judge an instrument failure where there is a fact, which is the same conflation this whole
    # tool exists to stop. Only a non-zero rc WITH bytes, or a timeout, is a real capture failure.
    if rc != 0 and n == 0:
        return 'NO MAPPED WINDOWS (rc=1, 0 bytes - the documented "no visible windows" answer, a fact about the guest)'
    if rc != 0:
        return f'CAPTURE FAILED (rc={rc}, {n} bytes) - instrument problem, says nothing about the guest'
    return f'{n} bytes' + (' (EMPTY TAR = no mapped windows, a fact, not a broken tool)' if n < 2048 else '')


def devices(vm: str) -> str:
    code = (
        "import qubesadmin\n"
        "q=qubesadmin.Qubes(); vm=q.domains[%r]\n"
        "asg=[str(a) for a in vm.devices['block'].get_assigned_devices()]\n"
        "me=q.domains['win-idd-mgmt']\n"
        "att=[d.port_id for d in me.devices['block'] "
        "if getattr(getattr(d,'attachment',None),'name','')==%r]\n"
        "print('assigned=%%s attached_from_this_qube=%%s' %% (asg or 'none', att or 'none'))\n"
    ) % (vm, vm)
    rc, out = run([sys.executable, '-c', code], 90)
    return out.strip() if rc == 0 else f'UNREADABLE (rc={rc})'


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('vm')
    ap.add_argument('--request', default='<not stated>',
                    help='what the guest was last asked to do, e.g. "qvm-shutdown at 11:53:51Z"')
    ap.add_argument('--gap', type=int, default=60, help='seconds between the paired reads')
    a = ap.parse_args()
    env = {'QTEST_VM': a.vm}
    import os
    os.environ.update(env)          # tools/qtest defaults to win-idd-test without this

    t0 = time.strftime('%H:%M:%SZ', time.gmtime())
    p1, u1, s1 = power(a.vm), uptime(a.vm), shot_bytes(a.vm, 'a')
    dev = devices(a.vm)
    time.sleep(a.gap)
    t1 = time.strftime('%H:%M:%SZ', time.gmtime())
    p2, u2, s2 = power(a.vm), uptime(a.vm), shot_bytes(a.vm, 'b')

    state = [
        'GUEST UNDER JUDGMENT: ' + a.vm,
        'What it was last asked to do: ' + a.request,
        '',
        'PAIRED READS, %s then %s (gap %ds):' % (t0, t1, a.gap),
        '  power state:   %s  ->  %s' % (p1, p2),
        '  guest uptime:  %s  ->  %s' % (u1, u2),
        '  screenshot:    %s  ->  %s' % (s1, s2),
        '',
        'BLOCK DEVICES: ' + dev,
        '',
        'HOW TO READ THESE, from measurements already paid for on this rig:',
        '  * `Running` at both reads does NOT mean it stayed up. A guest that went down and came',
        '    back reads Running both times. The guest\'s OWN boot time is what separates them; if',
        '    it moved between the reads, the guest REBOOTED.',
        '  * A screenshot showing a desktop is NOT health. An autologon resume shows a desktop.',
        '    Identical capture sizes across the gap mean nothing changed; differing sizes mean it',
        '    is doing something.',
        '  * An EMPTY capture means no mapped windows - documented behaviour, not a broken tool.',
        '  * A guest resuming an install whose medium is NOT attached waits indefinitely, looking',
        '    exactly like a guest that is refusing to shut down.',
        '  * uptime UNAVAILABLE means qrexec did not answer. On a guest with no QWT that is normal',
        '    and says nothing about health; missing data must not be read as either outcome.',
        '',
        'BASE RATE, from the owner who runs this rig (2026-09-21): a guest that genuinely does',
        'not respond to a shutdown request happens about 10% of the time. The other ~90% of the',
        'cases that LOOK like it are something else - most often a guest that restarted and is',
        'waiting. Weight the priors accordingly: still-up-ignoring-request is the RARE answer',
        'here and needs positive evidence, not merely the absence of a halt.',
    ]

    rubric = {'questions': {
        'guest_state': {'type': 'choice', 'instructions': {'judge':
            'Name this guest\'s state from the measurements in `state` ONLY. Do not assume a '
            'component is broken because a request had no visible effect. Prefer '
            'insufficient-evidence over a guess - a wrong name here has twice sent this project '
            'down a dead end.'},
            'criteria': {
                'restarted-and-waiting': 'it has booted since the request and is now sitting waiting for something (a medium, a stage, input) - the power state reads Running because it keeps coming back',
                'still-up-ignoring-request': 'it has NOT booted since the request and is still the same session, i.e. the request genuinely had no effect',
                'shutting-down-slowly': 'it is in the process of going down and simply has not finished',
                'unreachable-but-alive': 'the domain is up but nothing in the guest answers - no qrexec, no window changes - with no evidence it rebooted',
                'halted': 'it is down',
                'insufficient-evidence': 'the measurements do not support choosing'}},
        'reboot_since_request': {'type': 'noul', 'instructions': {'judge':
            'Is there POSITIVE evidence the guest booted since the request? Absence of evidence '
            'is false here, not true.'},
            'criteria': {'true': 'a measured boot time moved, or something else positively shows a boot',
                         'false': 'no measurement shows a boot, including when uptime was unavailable'}},
        'missing_measurement': {'type': 'choice', 'instructions': {'judge':
            'Which single measurement, absent here, would most change this verdict?'},
            'criteria': {
                'guest-boot-time': 'the guest\'s own boot time across the two reads',
                'screen-delta': 'whether the screen content changed over a longer window',
                'what-it-awaits': 'which medium or stage this boot expects and whether it is present',
                'console': 'the PV console, for a guest below the OS',
                'nothing-material': 'the evidence already settles it'}}}}

    sd = ROOT / 'scratchpad'; sd.mkdir(exist_ok=True)
    sf, rf = sd / f'jev-gsj-{a.vm}-state.txt', sd / f'jev-gsj-{a.vm}-rubric.json'
    sf.write_text('\n'.join(state), encoding='utf-8')
    rf.write_text(json.dumps(rubric), encoding='utf-8')
    print('\n'.join(state))
    print()
    p = subprocess.run([sys.executable, str(ROOT / 'tools' / 'jev.py'), str(rf), str(sf)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(f'JEV DID NOT RUN: rc={p.returncode} {p.stderr.strip()[:300]}', file=sys.stderr)
        return 2                      # the instrument did not run - never paper over it
    print('JEV:')
    print('\n'.join('  ' + l for l in p.stdout.strip().splitlines()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
