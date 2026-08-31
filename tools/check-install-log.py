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

    # --- stage RESULT invariants ----------------------------------------------------------------
    # The installer emits `=== RESULT === {"stage":"...","ok":bool,...}` per stage. Grade the stages
    # the slice actually contains; a slice without a stage is `na`, never a vacuous pass.
    stage_res = []
    for ln in lines:
        m = re.search(r'===\s*RESULT\s*===\s*(\{.*)$', ln)
        if not m:
            continue
        try:
            o = json.loads(m.group(1))
        except Exception:
            continue
        if isinstance(o, dict) and 'stage' in o:
            stage_res.append(o)

    def stage_rows(name):
        return [o for o in stage_res if o.get('stage') == name]

    s1 = stage_rows('stage1-prepare')
    res['stage1_prepare_ok'] = {
        'ok': (all(o.get('ok') for o in s1) if s1 else True),
        'na': not s1, 'count': len(s1),
        'not_ok': [o for o in s1 if not o.get('ok')][:2],
    }
    s2 = stage_rows('stage2-install')
    res['stage2_install_ok'] = {
        'ok': (all(o.get('ok') for o in s2) and len(s2) >= 1) if s2 else True,
        'na': not s2, 'count': len(s2),
        'not_ok': [o for o in s2 if not o.get('ok')][:2],
    }
    # resume_fires_once: the resume path must run stage 2 EXACTLY once. Two stage2 RESULTs means the
    # resume fired twice - a second unnecessary install pass over a guest that was already done.
    res['resume_fires_once'] = {
        'ok': (len(s2) == 1) if s2 else True, 'na': not s2, 'stage2_results': len(s2),
    }

    # --- the msiexec command line ---------------------------------------------------------------
    msi_lines = [ln for ln in lines if re.search(r'running\s+msiexec', ln, re.I)]
    # REINSTALL=ALL is BRANCH-SPECIFIC, not universal. Measured across the campaign: the
    # same-version reinstall path (C6) uses `REINSTALL=ALL`; clean install (C1) and the
    # uninstall-first upgrades (C3/C4) use `REINSTALL=(none)` - correctly, since there is nothing
    # to reinstall. Demanding ALL unconditionally failed 8 of 10 good logs, and cross-checking the
    # ledger showed only the two C6 cells ever claimed this check. What IS universal is that
    # ADDLOCAL carries PvDriversDisk and MoveUsers.
    reinstall_vals = [m.group(1) for ln in msi_lines
                      for m in [re.search(r'REINSTALL=(\S+?)[\s)]', ln + ' ')] if m]
    addlocal_ok = all(('PvDriversDisk' in ln and 'MoveUsers' in ln) for ln in msi_lines)
    is_all = any(v.upper().startswith('ALL') for v in reinstall_vals)
    res['reinstall_all_on_msiexec'] = {
        'ok': addlocal_ok and (is_all if reinstall_vals else True),
        # na when the branch did not ask for a reinstall - the cell does not claim this check there
        'na': (not msi_lines) or (bool(reinstall_vals) and not is_all),
        'invocations': len(msi_lines), 'reinstall': reinstall_vals[:2], 'addlocal_ok': addlocal_ok,
    }

    # --- pnputil ---------------------------------------------------------------------------------
    # rc=259 ("Already exists in the system") is SUCCESS for a driver already in the store; the
    # check exists because treating 259 as an error once failed a correct install.
    pnp_ok = [ln for ln in lines if re.search(r'added successfully|Already exists in the system', ln, re.I)]
    pnp_bad = [ln.strip()[:140] for ln in lines
               if re.search(r'pnputil', ln, re.I) and re.search(r'\bfail|error', ln, re.I)]
    res['pnputil_259_accepted'] = {
        'ok': (len(pnp_bad) == 0) if (pnp_ok or pnp_bad) else True,
        'na': not (pnp_ok or pnp_bad), 'accepted': len(pnp_ok), 'failures': pnp_bad[:2],
    }

    # An `na` check must NOT read as a pass and must NOT fail the run either - the same rule
    # health-check.ps1 already applies ("counting them as failures made acceptance unpassable on the
    # very path it creates"). They are reported separately so a release CLAIM can require one while
    # a run does not.
    failed = [k for k, v in res.items() if not v['ok'] and not v.get('na')]
    na = [k for k, v in res.items() if v.get('na')]
    return {'file': path, 'checks': res, 'failed': failed, 'not_applicable': na, 'ok': not failed}


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
            elif name == 'monitor_disabled_before_msiexec':
                extra = f"msiexec_invocations={v['msiexec_invocations']} monitor_before={v['monitor_before_msiexec_lines']}"
            else:
                extra = ' '.join(f"{k}={v[k]}" for k in v if k not in ('ok','na','note'))
            print(f"{mark} {name}: {extra}")
        na = out.get('not_applicable') or []
        tail = 'INSTALLLOG=OK' if out['ok'] else 'INSTALLLOG=FAIL ' + ','.join(out['failed'])
        print(tail + (('  na=' + ','.join(na)) if na else ''))
    return 0 if out['ok'] else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
