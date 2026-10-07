#!/usr/bin/env python3
"""gate-scope.py - what the gate must run for THIS release, computed from the diff, and the refusal.

Owner, 2026-10-07: "i doubt we need fault injection on this path for every acceptance run. we may optimize our
acceptance a bit depending on what we touch and run full fault injection path and all install variants only when we
touch certain things or once in 10 updates or so."

That REPLACES the standing "full acceptance before every release" rule, so it is code, not prose: in this project a
rule that is prose has been walked past repeatedly (hence the serial-rig hook and the lint rules). The design was
decided with Jev - an UNMAPPED path requires the FULL set (0.97), the floor trips on whichever of four conditions
comes first (0.96), enforcement computes and refuses rather than being documented (1.00), and the danger it must
survive is a shared helper mapping narrow while affecting many paths (0.62), which is why a changed file expands
through its REVERSE-DEPENDENCY CLOSURE before anything is mapped.

    tools/gate-scope.py required <base>..<head> [--json]     what the gate must cover, and why
    tools/gate-scope.py floor                                does the floor trip, and on which condition
    tools/gate-scope.py check <coverage.json> [<base>..<head>]   REFUSES when coverage misses a required suite
    tools/gate-scope.py ledger-add --version V --tag T --run R --range B..H --covered a,b --result pass|fail

Exit codes:  0 satisfied / nothing required   1 something is required that is not covered (the refusal)
             2 the tool could not decide (missing map, unreadable ledger, bad git range) - never "nothing required"
A coverage file is {"suites": ["win11-clean", ...]} plus anything else the harness wants to record.
"""
from __future__ import annotations
import argparse, fnmatch, json, re, subprocess, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import os
# GATE_SCOPE_ROOT lets the offline suite drive the whole tool against a fixture repository (tools/tests/
# gate-scope-selftest.sh): the map, the ledger and `git diff` all come from there. Unset in every real use.
ROOT = Path(os.environ.get('GATE_SCOPE_ROOT') or Path(__file__).resolve().parent.parent).resolve()
MAP = ROOT / 'mgmt' / 'gate-scope.json'
LEDGER = ROOT / 'mgmt' / 'gate-ledger.json'

# How one file reaches another. A changed file expands to every file that USES it, transitively: that is the
# shared-helper hazard Jev named (0.62) - a library everything sources must not map to its own narrow scope.
REFS = [
    # bash: source / . with a path
    (re.compile(r'^\s*(?:source|\.)\s+["\']?(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)?([\w./-]+\.sh)'), '.sh'),
    # PowerShell dot-source
    (re.compile(r'^\s*\.\s+["\']?[^"\'\n]*?([\w.-]+\.ps1)'), '.ps1'),
    # python import of a sibling module
    (re.compile(r'^\s*(?:from|import)\s+([\w.]+)'), '.py'),
    # C/C++ include
    (re.compile(r'^\s*#\s*include\s+["<]([\w./-]+\.h)[">]'), '.h'),
    # a harness naming another script or a tool it runs
    (re.compile(r'(?:bash|python3|pwsh)?\s*["\']?((?:mgmt|tools|guest|packaging)/[\w./-]+\.(?:sh|py|ps1))'), ''),
]
TEXT_SUFFIX = {'.sh', '.ps1', '.psm1', '.py', '.c', '.cpp', '.h', '.cs', '.yml', '.yaml', '.cmd', '.bat'}


def die(msg: str) -> None:
    print(f'gate-scope: {msg}', file=sys.stderr)
    sys.exit(2)


def load_map() -> dict:
    if not MAP.exists():
        die(f'the scope map is missing ({MAP.relative_to(ROOT)}) - nothing can be decided')
    try:
        m = json.loads(MAP.read_text())
    except Exception as e:
        die(f'the scope map does not parse: {e}')
    for k in ('core', 'full', 'floor', 'patterns'):
        if k not in m:
            die(f'the scope map has no "{k}"')
    return m


def load_ledger() -> dict:
    if not LEDGER.exists():
        die(f'the ledger is missing ({LEDGER.relative_to(ROOT)}) - the floor cannot be counted')
    try:
        return json.loads(LEDGER.read_text())
    except Exception as e:
        die(f'the ledger does not parse: {e}')


def git(*args: str) -> str:
    p = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True)
    if p.returncode != 0:
        die(f'git {" ".join(args)} failed: {p.stderr.strip()[:200]}')
    return p.stdout


def changed_files(rng: str) -> list[str]:
    if '..' not in rng:
        die(f'"{rng}" is not a git range (expected base..head)')
    out = git('diff', '--name-only', rng).split('\n')
    return sorted({f.strip() for f in out if f.strip()})


def submodule_expand(files: list[str], m: dict) -> list[str]:
    """A submodule POINTER change is the whole diff of that submodule. Rather than reach into its history (the
    pointer may name a commit this checkout does not have), it expands to the submodule's own prefix, which the
    patterns map - so agent/ changing as a pointer requires what agent/** requires."""
    out = list(files)
    for name, info in (m.get('submodules') or {}).items():
        if name in files or f'{name}/' in files:
            out.append(info.get('prefix', name + '/') + '**POINTER**')
    return out


def closure(files: list[str]) -> dict[str, str]:
    """Every file that USES a changed file, transitively. Returns {file: why} - the changed files map to '', the
    ones pulled in name the file they use."""
    tracked = [f for f in git('ls-files').split('\n') if f.strip()]
    # index: basename -> the tracked paths with that name (a reference names a file, rarely a full path)
    by_name: dict[str, list[str]] = {}
    for t in tracked:
        by_name.setdefault(Path(t).name, []).append(t)
    # users[target] = {files that reference it}
    users: dict[str, set[str]] = {}
    for t in tracked:
        if Path(t).suffix.lower() not in TEXT_SUFFIX:
            continue
        p = ROOT / t
        try:
            text = p.read_text(errors='replace')
        except Exception:
            continue
        for line in text.splitlines():
            for rx, suf in REFS:
                mm = rx.search(line)
                if not mm:
                    continue
                ref = mm.group(1)
                cands: list[str] = []
                if '/' in ref and ref in tracked:
                    cands = [ref]
                else:
                    base = Path(ref).name
                    if suf == '.py':
                        base = base.split('.')[-1] + '.py'
                    cands = by_name.get(base, [])
                for c in cands:
                    if c != t:
                        users.setdefault(c, set()).add(t)
    out: dict[str, str] = {f: '' for f in files}
    frontier = list(files)
    while frontier:
        nxt = []
        for f in frontier:
            for u in sorted(users.get(f, ())):
                if u not in out:
                    out[u] = f
                    nxt.append(u)
        frontier = nxt
    return out


def match(path: str, m: dict) -> tuple[list[str] | None, str]:
    """The suites a path requires, and the pattern that said so. None = UNMAPPED."""
    pats = m['patterns']
    for pat in sorted(pats, key=len, reverse=True):
        if fnmatch.fnmatch(path, pat) or (pat.endswith('/**') and path.startswith(pat[:-2])):
            e = pats[pat]
            return list(e.get('suites', [])), pat
    return None, ''


def required(rng: str, m: dict) -> dict:
    files = submodule_expand(changed_files(rng), m)
    if not files:
        die(f'no files changed in {rng} - a release with an empty diff is not a release')
    # GATE_SCOPE_NO_CLOSURE is the self-test's defect knob for the shared-helper hazard (Jev 0.62): with the
    # closure off, a library everything sources maps only to its own narrow scope, and the suite must then FAIL.
    if os.environ.get('GATE_SCOPE_NO_CLOSURE') == '1':   # GUARD:closure
        clo = {f: '' for f in files if not f.endswith('**POINTER**')}
    else:
        clo = closure([f for f in files if not f.endswith('**POINTER**')])
    for f in files:
        if f.endswith('**POINTER**'):
            clo[f] = 'submodule pointer'
    want: dict[str, list[str]] = {}
    unmapped: list[str] = []
    full = False
    for f, why in sorted(clo.items()):
        suites, pat = match(f, m)
        if suites is None:
            unmapped.append(f)
            full = True
            continue
        if 'full' in suites:
            full = True
        for s in suites:
            if s == 'full':
                continue
            tag = f'{f} ({m["patterns"][pat].get("reason", pat)})' + (f' <- {why}' if why else '')
            want.setdefault(s, []).append(tag)
    floor_hit, floor_why = floor(m)
    if floor_hit:
        full = True
    suites = list(m['full']['suites']) if full else sorted(set(m['core']['suites']) | set(want))
    if not full:
        for s in m['core']['suites']:
            want.setdefault(s, []).append('the always-run core')
    return {'range': rng, 'changed': [f for f in files if not f.endswith('**POINTER**')],
            'closure_added': sorted(f for f, w in clo.items() if w and not f.endswith('**POINTER**')),
            'unmapped': unmapped, 'full': full, 'floor': floor_why if floor_hit else '',
            'suites': suites, 'why': want}


def floor(m: dict) -> tuple[bool, str]:
    led = load_ledger()
    rel = [r for r in led.get('releases', []) if isinstance(r, dict)]
    fulls = [r for r in rel if r.get('full') and r.get('result') == 'pass']
    if not fulls:
        return True, 'no full gate has ever passed on record'
    last = fulls[-1]
    since = [r for r in rel if r.get('date', '') > last.get('date', '')]
    f = m['floor']
    if len(since) >= int(f.get('releases', 10)):
        return True, f'{len(since)} release(s) since the last full gate ({last.get("version")}), the limit is {f.get("releases")}'
    try:
        d = datetime.fromisoformat(last['date'].replace('Z', '+00:00'))
    except Exception:
        return True, f'the last full gate\'s date is unreadable ({last.get("date")!r})'
    age = datetime.now(timezone.utc) - d
    if age > timedelta(days=int(f.get('days', 21))):
        return True, f'the last full gate was {age.days} day(s) ago ({last.get("version")}), the limit is {f.get("days")}'
    if any(r.get('full') and r.get('result') == 'fail' for r in since):
        return True, 'a full gate has FAILED since the last passing one'
    mapchange = git('log', '-1', '--format=%H', '--', 'mgmt/gate-scope.json').strip()
    if mapchange and last.get('map_commit') and mapchange != last['map_commit']:
        return True, f'the scope map changed since the last full gate ({mapchange[:8]} vs {last["map_commit"][:8]})'
    return False, f'{len(since)} release(s) and {age.days} day(s) since the last full gate ({last.get("version")})'


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('required'); r.add_argument('range'); r.add_argument('--json', action='store_true')
    sub.add_parser('floor')
    c = sub.add_parser('check'); c.add_argument('coverage'); c.add_argument('range', nargs='?')
    la = sub.add_parser('ledger-add')
    for f in ('version', 'tag', 'run', 'range', 'covered', 'result'):
        la.add_argument('--' + f, required=(f in ('version', 'range', 'covered', 'result')))
    a = ap.parse_args()
    m = load_map()

    if a.cmd == 'floor':
        hit, why = floor(m)
        print(('FLOOR TRIPS: ' if hit else 'floor not reached: ') + why)
        return 1 if hit else 0

    if a.cmd == 'required':
        res = required(a.range, m)
        if a.json:
            print(json.dumps(res, indent=1)); return 0
        print(f'{len(res["changed"])} changed file(s), {len(res["closure_added"])} pulled in by the closure')
        if res['unmapped']:
            print(f'UNMAPPED ({len(res["unmapped"])}) -> the FULL set is required; map them or accept the full gate:')
            for f in res['unmapped'][:20]:
                print(f'    {f}')
        if res['floor']:
            print(f'FLOOR -> the FULL set is required: {res["floor"]}')
        print(f'{"FULL" if res["full"] else "SCOPED"} - {len(res["suites"])} suite(s) required:')
        for s in res['suites']:
            print(f'    {s:28s} {res["why"].get(s, ["(the full set)"])[0][:110]}')
        return 0

    if a.cmd == 'check':
        try:
            cov = json.loads(Path(a.coverage).read_text())
        except Exception as e:
            die(f'the coverage file does not read: {e}')
        have = set(cov.get('suites') or [])
        if not have:
            die('the coverage file names no suites - missing data fails, it is not "nothing was required"')
        rng = a.range or cov.get('range')
        if not rng:
            die('no range given and the coverage file carries none')
        res = required(rng, m)
        missing = [s for s in res['suites'] if s not in have]
        extra = sorted(have - set(res['suites']))
        print(f'required {len(res["suites"])}, covered {len(have)}' + (f', also ran {len(extra)}' if extra else ''))
        if missing:
            print('REFUSED - the gate did not cover:')
            for s in missing:
                print(f'    {s:28s} required by: {res["why"].get(s, ["(the full set)"])[0][:110]}')
            if res['floor']:
                print(f'    (the floor is in force: {res["floor"]})')
            print('Run those suites and record them, or run the full gate.')
            return 1
        print('satisfied' + (f' (the full set was required: {res["floor"] or "an unmapped path or a pattern"})' if res['full'] else ''))
        return 0

    if a.cmd == 'ledger-add':
        led = load_ledger()
        res = required(a.range, m)
        rec = {'version': a.version, 'tag': a.tag or '', 'package_run': a.run or '',
               'date': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'range': a.range,
               'required': res['suites'], 'covered': sorted(set(a.covered.split(','))),
               'full': sorted(set(a.covered.split(','))) >= sorted(set(m['full']['suites'])) or
                       set(m['full']['suites']) <= set(a.covered.split(',')),
               'result': a.result, 'map_commit': git('log', '-1', '--format=%H', '--', 'mgmt/gate-scope.json').strip()}
        led.setdefault('releases', []).append(rec)
        LEDGER.write_text(json.dumps(led, indent=1) + '\n')
        print(f'ledger: {a.version} {a.result}, {len(rec["covered"])} suite(s) covered, full={rec["full"]}')
        return 0
    return 2


if __name__ == '__main__':
    sys.exit(main())
