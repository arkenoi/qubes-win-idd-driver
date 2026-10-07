#!/usr/bin/env python3
"""lifecycle-review.py - have Jev judge every place our code TERMINATES or (RE)LAUNCHES a process.

Owner, 2026-10-07: "if you terminate something that relaunches you need to make sure it STOPS relaunching
beforehand", "rely on windows system services if we need to keep smth running", "use jev proactively", and
"why did you miss kill-by-name during the previous sweep?". The 2026-10-03 sweep (lint L17) asked one question -
by name or by handle - and only of SHIPPED scripts. This asks all four, of ALL our code:

  armed_relauncher   the target has a relauncher (a supervisor loop, SCM recovery, a task, Winlogon) that is still
                     armed when the code terminates it
  by_name            the target is chosen by image name / title / port owner, not a handle or the owner's pid
  relaunch_unguarded a supervisor relaunches after a death without excluding that the context is ending
  own_keepalive      a hand-written keep-alive loop where a Windows mechanism would do

Finding the sites is code (regex + brace-counted enclosing block); judging them is Jev's (.claude/skills/jev).

    tools/lifecycle-review.py [--list] [--jobs N] [--out DIR] [path ...]
Exit 0 = nothing flagged, 1 = something flagged, 2 = Jev did not run for at least one site (the review is
INCOMPLETE - never read that as clean).
"""
from __future__ import annotations
import argparse, concurrent.futures, json, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCOPE = ['agent/gui-agent', 'agent/watchdog', 'agent/include', 'tools/notifhost', 'tools/wgcbroker',
         'packaging', 'guest', 'mgmt', 'tools']
EXT = {'.c': 'c', '.cpp': 'c', '.h': 'c', '.ps1': 'ps', '.psm1': 'ps', '.sh': 'sh', '.cs': 'c'}
SKIP = re.compile(r'(^|/)(tests?|fixtures?)/|_test\.|selftest|lifecycle-review\.py$|^mgmt/prime-jobs/')

TERM = r'TerminateProcess\s*\(|NtTerminateProcess|Stop-Process|\.Kill\(\s*\)|\btaskkill\b|schtasks(\.exe)?\s+/end|' \
       r'Stop-ScheduledTask|Stop-Service|\bsc(\.exe)?\s+stop\b'
LAUNCH = r'CreateProcess(AsUser)?W?\s*\(|ShellExecute(Ex)?W?\s*\(|Start-Process|schtasks(\.exe)?\s+/(run|create)|' \
         r'Start-ScheduledTask|Register-ScheduledTask|Start-Service|\bsc(\.exe)?\s+(start|failure)\b|RestartOnFailure'
HIT = re.compile(f'({TERM})|({LAUNCH})', re.I)
COMMENT = {'c': re.compile(r'^\s*(//|\*|/\*)'), 'ps': re.compile(r'^\s*#'), 'sh': re.compile(r'^\s*#')}
HEADER = {'c': re.compile(r'^[A-Za-z_][\w\s\*]*?\b(\w+)\s*\([^;]*$'),
          'ps': re.compile(r'^\s*function\s+([\w-]+)', re.I),
          'sh': re.compile(r'^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\)\s*\{?')}
MAXLINES, WINDOW, CALLEE_LINES = 180, 45, 220
MSGLINE = re.compile(r'\b(Log(Info|Warning|Error|Debug)?|Write-(Log|Output|Host|Warning|Error|Verbose)|throw|remedy|'
                     r'printf|StringCch\w+|Get-TaskResultMeaning)\b|^\s*0x[0-9a-f]+\s*\{|\$\w*[Rr]emedy', re.I)

RELAUNCHERS = """KNOWN RELAUNCHERS IN THIS SYSTEM (facts, as of 2026-10-07):
- The QubesGuiWatchdog service (session 0) relaunches gui-agent.exe whenever it exits, except after the service's own
  stop; it is the only way the agent gets into the user's session.
- SCM recovery actions (restart after 5/15/60 s, failureflag 1) are armed on QdbDaemon, QrexecAgent, QubesGuiWatchdog
  and QwtngNetSetup: a service process that ends without the service reporting STOPPED is restarted by the SCM.
- gui-agent relaunches its helpers when they exit or their heartbeat goes stale: wgcbroker.exe (scheduled task
  Qubes-WgcBroker, schtasks /it), the notification bridge notifhost.exe (a scheduled task), etwproxy.exe
  (CreateProcessAsUser).
- Winlogon restarts explorer.exe when it exits (AutoRestartShell=1, the Windows default); the shell restarts
  ShellExperienceHost / StartMenuExperienceHost.
- Scheduled tasks (QubesWindowsUpdateScan, QubesAutologonGuard, QwtDeathReporter, QubesPrime, the updater's tasks)
  run their action again at their next trigger; the updater's pass starts qubes-updates-relay.
- Windows' session teardown (logoff, shutdown) terminates every process in the session (exit 0x40010004) BEFORE any
  service is told the machine is going down. Measured 2026-10-07: GetSystemMetrics(SM_SHUTTINGDOWN) called from a
  session-0 service reports SESSION 0 and read 0 at every such death; SERVICE_CONTROL_PRESHUTDOWN arrived 4-32 s later,
  after the user session was gone; the WTS state read 'active'. None of these tells a session-0 supervisor in time."""

DEFECT_Q = ('armed_relauncher', 'by_name', 'relaunch_unguarded', 'own_keepalive')
RUBRIC = {"questions": {
    "armed_relauncher": {"type": "choice", "instructions": {"judge":
        "Does this code TERMINATE a process, service or task while that target's RELAUNCHER (the table in `state`, "
        "or one visible in the code) is still armed, without disarming it FIRST? Not a termination: a stop REQUESTED "
        "through the SCM (Stop-Service / sc stop - the SCM does not restart a service it was asked to stop) or "
        "through the target's own stop event. A supervisor that ends its OWN hung child in order to relaunch it, "
        "under its own control, is sound. If the disarm could happen in a caller the excerpt does not show, say "
        "insufficient-evidence rather than guess. Comments are not evidence."},
        "criteria": {"defect": "terminates while the target's relauncher is armed and nothing shown disarms it first",
                     "sound": "terminates, and the relauncher is disarmed first, or none exists",
                     "not-applicable": "no termination here",
                     "insufficient-evidence": "cannot be decided from this excerpt"}},
    "by_name": {"type": "choice", "instructions": {"judge":
        "Does this code select a PROCESS to terminate or adopt by its image name, window title or the port it "
        "listens on, instead of a handle it holds from starting it or the pid the SCM reports for a service? A "
        "scheduled task or a service addressed by its registered name is NOT by-name - that name is its identity."},
        "criteria": {"defect": "a process is selected by name, title or port owner",
                     "sound": "handle or owner-reported pid only",
                     "not-applicable": "no process is selected for termination or adoption"}},
    "relaunch_unguarded": {"type": "choice", "instructions": {"judge":
        "Does this code RELAUNCH a process IN RESPONSE TO ITS DEATH, exit or lost heartbeat (a supervisor's relaunch) "
        "without RELIABLY establishing first that the death was not its CONTEXT ENDING - the session being torn down, "
        "the machine shutting down, the owning service stopping, or the owning process exiting? Deaths cluster exactly "
        "there, so an unguarded relaunch lands in the ending context. A GUARD COUNTS ONLY IF THE SIGNAL IT READS IS "
        "TRUE AT THE MOMENT OF THE DEATH: check every signal the guard reads against the measured facts in `state`; "
        "a guard built on a signal the facts say stays false or arrives later (e.g. SM_SHUTTINGDOWN read from a "
        "session-0 service, the WTS connect state, SERVICE_CONTROL_PRESHUTDOWN) establishes nothing, and the relaunch "
        "is then a defect however carefully the guard is written. A launch on demand (a request, a user action, an "
        "install step, a one-shot helper) is not-applicable."},
        "criteria": {"defect": "relaunches after a death and no guard that works per the facts excludes an ending context",
                     "sound": "relaunches only after a guard that works per the facts excludes an ending context",
                     "not-applicable": "not a relaunch-after-death",
                     "insufficient-evidence": "cannot be decided from this excerpt"}},
    "own_keepalive": {"type": "choice", "instructions": {"judge":
        "Is this a hand-written restart / keep-alive loop for something a Windows mechanism could keep running - SCM "
        "recovery actions for a SERVICE, or Task Scheduler restart settings where a 1-minute minimum fits? A relaunch "
        "that must happen within seconds (no Windows mechanism offers that) or the one launch into a user session "
        "that Windows cannot do is sound."},
        "criteria": {"defect": "an own keep-alive loop where a Windows mechanism fits",
                     "sound": "a relaunch no Windows mechanism can do",
                     "not-applicable": "not a keep-alive loop"}},
    "load_bearing": {"type": "noul", "instructions": {"judge":
        "If this code misbehaves, does a SHIPPED behaviour or a test/gate VERDICT depend on it (as opposed to a "
        "one-off developer convenience)?"},
        "criteria": {"true": "a product behaviour or a verdict depends on it", "false": "convenience only"}}}}


def shipped_names() -> set[str]:
    names = set()
    for f in ('packaging/make-setup.ps1', 'packaging/make-package.ps1', 'packaging/stage-qwt-repo.ps1'):
        p = ROOT / f
        if p.exists():
            # 'guest\x.ps1' paths AND the bare quoted names of the foreach staging lists ('pvnic-selfprime.ps1', ...)
            names |= {m.lower() for m in re.findall(r"['\"\\/]([\w.-]+\.(?:ps1|cs))['\"]", p.read_text(errors='replace'))}
    return {n for n in names if (ROOT / 'guest' / n).exists()}


def role(rel: str, shipped: set[str]) -> str:
    if rel.startswith(('agent/', 'tools/notifhost/', 'tools/wgcbroker/', 'packaging/setup/', 'packaging/payload/')):
        return 'SHIPPED'
    if rel.startswith('guest/') and Path(rel).name.lower() in shipped:
        return 'SHIPPED'
    if rel.startswith(('mgmt/', 'tools/')):
        return 'HARNESS'
    return 'DEV'


def in_string(line: str, pos: int) -> bool:
    """True when the match at pos sits inside a quoted string (an odd number of unescaped quotes before it)."""
    pre = re.sub(r'\\.', '', line[:pos])
    return pre.count('"') % 2 == 1 or (pre.count("'") % 2 == 1 and '"' not in pre)


def depths(lines: list[str]) -> list[int]:
    """Brace depth at the START of each line (strings/comments not parsed - good enough to find blocks)."""
    d, out = 0, []
    for ln in lines:
        out.append(d)
        d += ln.count('{') - ln.count('}')
        d = max(d, 0)
    return out


def enclosing(lines: list[str], dep: list[int], i: int, kind: str):
    """(name, start, end) of the block holding line i, or a window when it is top-level or huge."""
    hdr = HEADER[kind]
    n = len(lines)
    for s in range(i, -1, -1):
        m = hdr.match(lines[s])
        if not m:
            continue
        # The block opens at the first '{' on or after the header line (C puts it on the next line) and ends on
        # the line after which the depth is back at the header's depth.
        k = next((j for j in range(s, min(n, s + 4)) if '{' in lines[j]), None)
        if k is None:
            continue
        e = next((j for j in range(k, n) if (dep[j + 1] if j + 1 < n else 0) <= dep[s]), n - 1)
        if s <= i <= e:
            return m.group(1), s, e + 1
    return None, max(0, i - WINDOW // 2), min(n, i + WINDOW // 2)


def sites(paths: list[str]):
    shipped = shipped_names()
    out = {}
    for base in paths:
        p = ROOT / base
        files = [p] if p.is_file() else sorted(q for q in p.rglob('*') if q.is_file())
        for f in files:
            rel = str(f.relative_to(ROOT))
            kind = EXT.get(f.suffix.lower())
            if not kind or SKIP.search(rel) or '/.git/' in rel:
                continue
            lines = f.read_text(errors='replace').splitlines()
            dep = None
            for i, ln in enumerate(lines):
                m = HIT.search(ln)
                # A command named inside MESSAGE text (a remedy, a log line) is not a call; a quoted command handed
                # to a runner (the harness's `q run '...'`) is - so only message lines are filtered, never bash.
                if not m or COMMENT[kind].match(ln) or (kind != 'sh' and MSGLINE.search(ln) and in_string(ln, m.start())):
                    continue
                dep = dep or depths(lines)
                name, s, e = enclosing(lines, dep, i, kind)
                if e - s > MAXLINES:
                    s, e = max(s, i - MAXLINES // 2), min(e, i + MAXLINES // 2)
                if name is None:   # top-level code: one site per window, not one per hit
                    near = next((k for k, v in out.items() if k[0] == rel and k[1].startswith('L')
                                 and v['start'] <= i <= v['end']), None)
                    if near:
                        out[near]['hits'].append(i + 1)
                        out[near]['end'] = max(out[near]['end'], e)
                        continue
                key = (rel, name or f'L{s + 1}')
                site = out.setdefault(key, {'file': rel, 'block': name or f'top-level L{s + 1}', 'role': role(rel, shipped),
                                            'hits': [], 'start': s, 'end': e})
                site['hits'].append(i + 1)
                site['start'], site['end'] = min(site['start'], s), max(site['end'], e)
    add_callers(out)
    for v in out.values():
        lines = (ROOT / v['file']).read_text(errors='replace').splitlines()
        if v['end'] - v['start'] > MAXLINES * 2:
            v['end'] = v['start'] + MAXLINES * 2
        v['code'] = '\n'.join(f'{n + 1:5d}  {lines[n]}' for n in range(v['start'], min(v['end'], len(lines))))
        if EXT.get(Path(v['file']).suffix.lower()) == 'c':
            body = '\n'.join(lines[v['start']:v['end']])
            extra, budget = [], CALLEE_LINES
            for name, s0, e0 in c_functions(lines, depths(lines)):
                if name == v['block'] or not re.search(rf'\b{re.escape(name)}\s*\(', body) or e0 - s0 > budget:
                    continue
                extra.append(f'// ---- called from the site above: {name}\n' +
                             '\n'.join(f'{n + 1:5d}  {lines[n]}' for n in range(s0, e0)))
                budget -= e0 - s0
            if extra:
                v['code'] += '\n\n' + '\n\n'.join(extra)
    return list(out.values())


def c_functions(lines: list[str], dep: list[int]):
    """Every top-level C function block: (name, start, end_exclusive)."""
    n, out = len(lines), []
    for s in range(n):
        m = HEADER['c'].match(lines[s])
        if not m or dep[s] != 0:
            continue
        k = next((j for j in range(s, min(n, s + 4)) if '{' in lines[j]), None)
        if k is None:
            continue
        e = next((j for j in range(k, n) if (dep[j + 1] if j + 1 < n else 0) <= 0), n - 1)
        out.append((m.group(1), s, e + 1))
    return out


def add_callers(out: dict, levels: int = 2):
    """A relaunch DECISION often lives one or two calls above the CreateProcess/schtasks line (the watchdog's
    WatchdogThread calls StartTargetProcess; NotifBridgeSupervise -> NotifBridgeLaunch -> NotifRunInSession).
    Add, per C file, the functions that call a launching function, up to `levels` deep."""
    files = {v['file'] for v in out.values() if EXT.get(Path(v['file']).suffix.lower()) == 'c'}
    for rel in files:
        lines = (ROOT / rel).read_text(errors='replace').splitlines()
        funcs = c_functions(lines, depths(lines))
        targets = {v['block'] for v in out.values() if v['file'] == rel and not v['block'].startswith('top-level')}
        for _ in range(levels):
            new = set()
            for name, s, e in funcs:
                if name in targets or (rel, name) in out:
                    continue
                calls = [i + 1 for i in range(s + 1, e) for t in targets
                         if re.search(rf'\b{re.escape(t)}\s*\(', lines[i]) and not COMMENT['c'].match(lines[i])]
                if calls:
                    out[(rel, name)] = {'file': rel, 'block': name, 'role': role(rel, shipped_names()),
                                        'hits': sorted(set(calls)), 'start': s, 'end': e, 'caller': True}
                    new.add(name)
            if not new:
                break
            targets |= new


def judge(site: dict, wdir: Path):
    state = (f"{RELAUNCHERS}\n\nSITE: {site['file']} - {site['block']} ({site['role']}: "
             f"{'ships to users' if site['role'] == 'SHIPPED' else 'rig harness / developer script, not shipped'}). "
             + (f"This function CALLS a launching function (lines {site['hits']}) - the relaunch decision may be "
                f"here." if site.get('caller') else f"Termination/launch calls on lines {site['hits']}.")
             + f"\n\n```\n{site['code']}\n```\n\n"
             "Judge the code as written. A comment that says the code is safe is not evidence that it is.")
    tag = re.sub(r'[^\w.-]', '_', f"{site['file']}-{site['block']}")[:120]
    sf, rf = wdir / f'{tag}.state.txt', wdir / f'{tag}.rubric.json'
    sf.write_text(state, encoding='utf-8')
    rf.write_text(json.dumps(RUBRIC), encoding='utf-8')
    of = wdir / f'{tag}.answers.json'
    p = subprocess.run([sys.executable, str(ROOT / 'tools' / 'jev.py'), str(rf), str(sf), '--out', str(of)],
                       capture_output=True, text=True)
    if p.returncode != 0 or not of.exists():
        return None, f'rc={p.returncode} {p.stderr.strip()[:200]}'
    a = json.loads(of.read_text()).get('answers', {})
    ans = {}
    for k in RUBRIC['questions']:
        if k not in a:
            return None, f'answer {k} missing'
        if 'noul' in a[k]:
            ans[k] = round(float(a[k]['noul']), 2)
        else:
            pr = a[k].get('probabilities') or {}
            ans[k] = [a[k]['choice'], round(float(pr.get('defect', 0.0)), 2), round(float(pr.get('insufficient-evidence', 0.0)), 2)]
    return ans, None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('paths', nargs='*', default=SCOPE)
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--jobs', type=int, default=8)
    ap.add_argument('--only', help='judge only sites whose file:block matches this regex (calibration)')
    ap.add_argument('--out', default=str(ROOT / 'scratchpad' / 'lifecycle-review'))
    a = ap.parse_args()
    found = sites(a.paths)
    if a.only:
        found = [x for x in found if re.search(a.only, f"{x['file']}:{x['block']}")]
    if not found:
        print('no sites found - that is itself suspicious; check the matcher'); return 2
    by_role = {r: sum(1 for s in found if s['role'] == r) for r in ('SHIPPED', 'HARNESS', 'DEV')}
    print(f"{len(found)} site(s): {by_role}")
    if a.list:
        for s in found:
            print(f"  {s['role']:7s} {s['file']}:{s['hits'][0]}  {s['block']}  hits={s['hits']}")
        return 0
    wdir = Path(a.out); wdir.mkdir(parents=True, exist_ok=True)
    failed, results = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = {ex.submit(judge, s, wdir): s for s in found}
        for fu in concurrent.futures.as_completed(futs):
            s = futs[fu]
            ans, err = fu.result()
            if ans is None:
                failed.append((s, err)); continue
            flags = [k for k in DEFECT_Q if ans[k][1] >= 0.5]                     # P(defect) >= 0.5
            unsure = [k for k in DEFECT_Q if k not in flags and ans[k][2] >= 0.4]  # Jev says it cannot tell
            results.append({**{k: s[k] for k in ('file', 'block', 'role', 'hits')}, 'answers': ans, 'flags': flags,
                            'unsure': unsure})
    rank = {'SHIPPED': 0, 'HARNESS': 1, 'DEV': 2}
    results.sort(key=lambda r: (not r['flags'], rank[r['role']], -max([r['answers'][k][1] for k in r['flags']] or [0])))
    (wdir / 'report.json').write_text(json.dumps({'results': results, 'jev_failed': [(s['file'], s['block'], e) for s, e in failed]}, indent=1))
    flagged = [r for r in results if r['flags']]
    for r in flagged:
        ans = ' '.join(f"{k}(P={r['answers'][k][1]:.2f})" for k in r['flags'])
        print(f"FLAG {r['role']:7s} {r['file']}:{r['hits'][0]} {r['block']}  {ans}  load_bearing={r['answers'].get('load_bearing', 0):.2f}")
    unsure = [r for r in results if r['unsure'] and not r['flags']]
    for r in unsure:
        print(f"UNSURE {r['role']:7s} {r['file']}:{r['hits'][0]} {r['block']}  {' '.join(r['unsure'])}")
    print(f"\n{len(flagged)} of {len(results)} judged site(s) flagged, {len(unsure)} undecided; report {wdir / 'report.json'}")
    if failed:
        print(f"JEV DID NOT RUN for {len(failed)} site(s) - the review is INCOMPLETE:", file=sys.stderr)
        for s, e in failed:
            print(f"  {s['file']} {s['block']}: {e}", file=sys.stderr)
        return 2
    return 1 if flagged else 0


if __name__ == '__main__':
    sys.exit(main())
