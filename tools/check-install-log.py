#!/usr/bin/env python3
"""Assert the install-log invariants that C1/C3/C4/C6 grade on.

WHY THIS EXISTS. These three checks were graded by HAND-RUN GREPS and recorded straight into the
ledger, so there was no instrument to prove and every row could only say PASS-UNPROVEN. Worse, the
hand version of `one-precondition-no-mid-reboot` was described as "exactly 1 PRECONDITION line in
the run slice", which a whole-file count gets wrong: `C1-win10-full/WIN10-grade-final.log` contains
FOUR, and all four are correct - they are four separate runs, each with its own `run_id`.

The real invariant is ONE PRECONDITION PER run_id. A repeated run_id means the installer emitted its
precondition twice inside a single run, i.e. it restarted mid-run - which is the defect the check is
actually about.

  tools/check-install-log.py <install-log> [--json]

Exit 0 = all invariants hold. Exit 1 = at least one failed (it says which, and why).
"""
import json
import re
import sys
from collections import Counter

PRECOND = re.compile(r'===\s*PRECONDITION\s*===\s*(\{.*)$')
RUNID = re.compile(r'"run_id"\s*:\s*"([0-9a-f]+)"')


def check(path):
    text = open(path, 'r', errors='replace').read()
    lines = text.splitlines()
    res = {}

    # --- one PRECONDITION per run_id -----------------------------------------------------------
    ids = []
    unparsed = 0
    for ln in lines:
        m = PRECOND.search(ln)
        if not m:
            continue
        r = RUNID.search(m.group(1))
        if r:
            ids.append(r.group(1))
        else:
            unparsed += 1
    dupes = {k: v for k, v in Counter(ids).items() if v > 1}
    res['one_precondition_per_run'] = {
        'ok': (not dupes) and unparsed == 0 and len(ids) > 0,
        'runs': len(ids),
        'distinct_runs': len(set(ids)),
        'repeated_run_ids': dupes,
        'preconditions_without_a_run_id': unparsed,
        # len(ids)==0 fails deliberately: a log with NO precondition line has not shown the
        # installer ran its precondition at all, which is not the same as showing it ran once.
        'note': 'a repeated run_id means the installer emitted its precondition twice in one run '
                '- it restarted mid-run',
    }

    # --- no REFUSING --------------------------------------------------------------------------
    refusing = [ln.strip()[:160] for ln in lines if 'REFUSING' in ln]
    res['no_refusing'] = {'ok': len(refusing) == 0, 'count': len(refusing), 'lines': refusing[:5]}

    # --- xenbus monitor disabled before msiexec (the 81d2b79 brick guard) -----------------------
    # NOT a line-number comparison. Two things break that, and both are real in the campaign logs:
    #   * "msiexec" appears in ANNOTATIONS long before the invocation - e.g.
    #     "trusted 9 payload certs (Root + TrustedPublisher) [stage 2, before msiexec]" at line 15,
    #     while the actual call is "running msiexec ADDLOCAL=..." at line 29;
    #   * the monitor is disabled BEFORE msiexec runs but LOGGED at line 30, i.e. after the
    #     "running msiexec" announcement. Log order is not execution order.
    # The installer already states the ordering it guarantees, by tagging the line "[before
    # msiexec]". Assert THAT. A first-match line comparison flagged a perfectly good C6 run.
    invoked = [i for i, ln in enumerate(lines) if re.search(r'running\s+msiexec', ln, re.I)]
    # TWO legitimate forms satisfy the guard, and requiring only the first flagged all three C1
    # (clean-install) logs:
    #   upgrade path : "xenbus_monitor disabled, AutoReboot=0 (was Disabled/Stopped) [before msiexec]"
    #   clean install: "xenbus_monitor disabled, AutoReboot=0 (service not present yet) [stage 1: ...]"
    # In the second there is no monitor service at all, so nothing can answer a reboot prompt - the
    # brick this guards against cannot occur. Both are "provably disarmed before msiexec".
    before = [i for i, ln in enumerate(lines)
              if re.search(r'xenbus_monitor\s+disabled.*\[before msiexec\]', ln, re.I)
              or re.search(r'xenbus_monitor\s+disabled.*service not present yet', ln, re.I)]
    res['monitor_disabled_before_msiexec'] = {
        # na when the slice contains no msiexec invocation at all (a grade-only log) - say so
        # rather than passing vacuously.
        'ok': (len(before) >= 1) if invoked else True,
        'na': not invoked,
        'msiexec_invocations': len(invoked),
        'monitor_before_msiexec_lines': len(before),
        'note': 'the installer tags the line "[before msiexec]"; that annotation is the ordering '
                'guarantee, because the monitor is disabled before the call but logged after the '
                'announcement of it',
    }

    failed = [k for k, v in res.items() if not v['ok']]
    return {'file': path, 'checks': res, 'failed': failed, 'ok': not failed}


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    if not args:
        print(__doc__.strip().splitlines()[-3], file=sys.stderr)
        return 2
    out = check(args[0])
    if '--json' in argv:
        print(json.dumps(out, indent=2))
    else:
        for name, v in out['checks'].items():
            mark = 'na  ' if v.get('na') else ('OK  ' if v['ok'] else 'FAIL')
            extra = ''
            if name == 'one_precondition_per_run':
                extra = f"runs={v['runs']} distinct={v['distinct_runs']} repeated={v['repeated_run_ids'] or '{}'}"
            elif name == 'no_refusing':
                extra = f"count={v['count']}" + (f" e.g. {v['lines'][0]}" if v['lines'] else '')
            else:
                extra = f"msiexec_invocations={v['msiexec_invocations']} monitor_before={v['monitor_before_msiexec_lines']}"
            print(f"{mark} {name}: {extra}")
        print(('INSTALLLOG=OK' if out['ok'] else 'INSTALLLOG=FAIL ' + ','.join(out['failed'])))
    return 0 if out['ok'] else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
