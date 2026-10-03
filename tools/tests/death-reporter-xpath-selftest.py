#!/usr/bin/env python3
"""death-reporter-xpath-selftest.py - the ONE reporter's subscription, evaluated as DATA (docs/ADR-supervision.md 3).

The installer (packaging/setup/Install-QwtImproved.ps1, region DEATH-REPORTER) registers the QwtDeathReporter task
with an XPath subscription over the Application, System and TaskScheduler/Operational logs, filtered to OUR
executables, services and tasks. This test rebuilds every Select exactly as the installer joins it (the quoted lists
and the 'or' joins are read from the shipped region, not re-typed here), evaluates each one with lxml against sample
events - ours and not ours, each id - and requires the match matrix below. It also holds the installer's three lists
together with the reporter's tables (guest/qwt-report-death.ps1) and with what packaging/make-setup.ps1 stages.

HONEST LIMIT. lxml is XPath 1.0; Windows' Event Log evaluator is a documented SUBSET of it (no contains(), no
namespaces - the event XML is matched without its xmlns, which is why the samples carry none). Every form used here
(Provider[@Name=...], EventID=..., or/and, Data='x' over positional Data, Data[@Name='x']='y', !=0) is inside that
subset; the release gate on a guest is what proves the task fires (a forced gui-agent crash -> Application 1000 ->
the task runs -> the deaths log). Run with no arguments: the clean matrix, then every knob below re-run in a
subprocess and required to FAIL (a guard never seen to fail is decoration). XPATH_DEFECT=<knob> runs one knob:
    noexefilter   the 1000/1001 selects lose their executable filter   -> notepad.exe's crash is subscribed to
    anyresult     the 201 select loses ResultCode!=0                   -> a helper's clean exit (0) is subscribed to
    noerrorexit   the SCM select loses 7023/7024                        -> QrexecAgent's error exit is NOT subscribed to
    selftrigger   the task list gains \\QwtDeathReporter                -> the reporter would trigger itself
"""
import os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
INSTALLER = ROOT / 'packaging' / 'setup' / 'Install-QwtImproved.ps1'
REPORTER = ROOT / 'guest' / 'qwt-report-death.ps1'
MAKESETUP = ROOT / 'packaging' / 'make-setup.ps1'
KNOBS = ('noexefilter', 'anyresult', 'noerrorexit', 'selftrigger')

try:
    from lxml import etree
except ImportError:
    print('FAIL  lxml is not installed - nothing ran (missing data fails)')
    sys.exit(2)


def region(text: str, name: str) -> str:
    b = text.index(f'# ---- {name}-BEGIN'); e = text.index(f'# ---- {name}-END')
    return text[b:e]


def ps_list(src: str, var: str) -> list[str]:
    """the quoted strings of `$var = @( ... )` in the installer region (single-quoted PowerShell literals)"""
    m = re.search(r'\$' + var + r'\s*=\s*@\((.*?)\)\s*(#[^\n]*)?\n', src, re.S)
    if not m:
        raise SystemExit(f'FAIL  ${var} = @(...) not found in the DEATH-REPORTER region')
    return re.findall(r"'([^']+)'", m.group(1))


def ps_hash_keys(src: str, var: str) -> list[str]:
    m = re.search(r'\$script:' + var + r'\s*=\s*@\{(.*?)\n\}', src, re.S)
    if not m:
        raise SystemExit(f'FAIL  $script:{var} = @{{...}} not found in the reporter')
    return re.findall(r"'([^']+)'\s*=", m.group(1))


def build_selects(reg: str, defect: str) -> dict[str, list[str]]:
    """the Select XPaths per channel, joined exactly as Register-QwtDeathReporter joins them"""
    exes = ps_list(reg, 'ourExes'); svcs = ps_list(reg, 'ourServices'); tasks = ps_list(reg, 'ourTasks')
    if defect == 'selftrigger':
        tasks = tasks + ['\\QwtDeathReporter']
    exe_or = ' or '.join(f"Data='{e}'" for e in exes)
    svc_or = ' or '.join(f"Data[@Name='param1']='{s}'" for s in svcs)
    task_or = ' or '.join(f"Data[@Name='TaskName']='{t}'" for t in tasks)
    selects: dict[str, list[str]] = {'Application': [], 'System': [], 'Microsoft-Windows-TaskScheduler/Operational': []}
    for m in re.finditer(r'"<Select Path=`"(\$tsPath|[A-Za-z]+)`">(.*?)</Select>"', reg):
        path = m.group(1).replace('$tsPath', 'Microsoft-Windows-TaskScheduler/Operational')
        xp = m.group(2).replace('$exeOr', exe_or).replace('$svcOr', svc_or).replace('$taskOr', task_or)
        if defect == 'noexefilter' and ('1000' in xp or '1001' in xp):
            xp = re.sub(r' and EventData\[.*\]\]$', ']', xp)
        if defect == 'anyresult' and 'EventID=201' in xp:
            xp = xp.replace("Data[@Name='ResultCode']!=0 and ", '')
        if defect == 'noerrorexit' and '7031' in xp:
            xp = xp.replace(' or EventID=7023 or EventID=7024', '')
        selects[path].append(xp)
    if not all(selects.values()):
        raise SystemExit(f'FAIL  the region yields no Select for some channel: { {k: len(v) for k, v in selects.items()} }')
    return selects


def ev(provider: str, eid: int, channel: str, positional=(), named=None) -> etree._Element:
    data = ''.join(f'<Data>{p}</Data>' for p in positional)
    data += ''.join(f'<Data Name="{k}">{v}</Data>' for k, v in (named or {}).items())
    return etree.fromstring(f'<Event><System><Provider Name="{provider}"/><EventID>{eid}</EventID><Channel>{channel}</Channel>'
                            f'<EventRecordID>7</EventRecordID></System><EventData>{data}</EventData></Event>')


def crash(exe): return ev('Application Error', 1000, 'Application', [exe, '1.0', 'x', 'ucrtbase.dll', '1', 'x', 'c0000409', '1', '0x1a2c', '0x1', 'C:\\x\\' + exe, 'C:\\y', 'g', '', ''])
def wer(exe): return ev('Windows Error Reporting', 1001, 'Application', ['0', '4', 'APPCRASH', 'n', '0', exe, '1.0', 'x', 'm', '1', 'x', 'c0000409', '1', '', '', 'f', 'C:\\WER\\ReportArchive\\x', '', '0', 'g', '1', 'h', 'c'])
def clr(exe): return ev('.NET Runtime', 1026, 'Application', [f'Application: {exe}\nException Info: System.Exception'])
def ours(eid): return ev('Qubes Windows Tools', eid, 'Application', ['text', 'gui-agent.exe', '1', '0x1', '1', 'd'])
def scm(eid, display): return ev('Service Control Manager', eid, 'System', named={'param1': display, 'param2': '1'})
def task(eid, name, result): return ev('Microsoft-Windows-TaskScheduler', eid, 'Microsoft-Windows-TaskScheduler/Operational', named={'TaskName': name, 'TaskInstanceId': 'i', 'ActionName': 'a', 'ResultCode': result})


def matrix(selects) -> list[tuple[str, bool, bool]]:
    """(case, want match, got match) for every sample against the selects of its channel"""
    samples = [
        ('1000 gui-agent.exe crash',                    crash('gui-agent.exe'), True),
        ('1000 wgcbroker.exe crash',                    crash('wgcbroker.exe'), True),
        ('1000 qwtng-netsetup.exe crash',               crash('qwtng-netsetup.exe'), True),
        ('1000 qubes-updates-relay.exe crash',          crash('qubes-updates-relay.exe'), True),
        ('1000 notepad.exe crash (not ours)',           crash('notepad.exe'), False),
        ('1000 cat.exe crash (generic name, excluded)', crash('cat.exe'), False),
        ('1001 gui-agent.exe report',                   wer('gui-agent.exe'), True),
        ('1001 explorer.exe report (not ours)',         wer('explorer.exe'), False),
        ('1026 managed crash (unfiltered: the script decides)', clr('contoso.exe'), True),
        ('4001 our source',                             ours(4001), True),
        ('4004 our source',                             ours(4004), True),
        ('Application Error 1002 (a hang: not subscribed)', ev('Application Error', 1002, 'Application', ['gui-agent.exe']), False),
        ('7031 Qubes RPC agent',                        scm(7031, 'Qubes RPC agent'), True),
        ('7034 QubesDB daemon',                         scm(7034, 'QubesDB daemon'), True),
        ('7023 Qubes GUI agent watchdog (error exit)',  scm(7023, 'Qubes GUI agent watchdog'), True),
        ('7024 Qubes PV NIC address applier',           scm(7024, 'Qubes PV NIC address applier'), True),
        ('7031 Print Spooler (not ours)',               scm(7031, 'Print Spooler'), False),
        ('7036 Qubes RPC agent (a state change: not subscribed)', scm(7036, 'Qubes RPC agent'), False),
        ('201 \\Qubes-WgcBroker result 3221226505',    task(201, '\\Qubes-WgcBroker', '3221226505'), True),
        ('201 \\QubesPvNic result 1',                   task(201, '\\QubesPvNic', '1'), True),
        ('201 \\Qubes-WgcBroker result 0 (a clean exit)', task(201, '\\Qubes-WgcBroker', '0'), False),
        ('201 \\Microsoft\\Windows\\Defrag\\ScheduledDefrag result 1 (not ours)', task(201, '\\Microsoft\\Windows\\Defrag\\ScheduledDefrag', '1'), False),
        ('203 \\QubesAutologonGuard',                   task(203, '\\QubesAutologonGuard', '2147942402'), True),
        ('203 \\QwtDeathReporter (never: no self-trigger)', task(203, '\\QwtDeathReporter', '2147942402'), False),
        ('201 \\QwtDeathReporter result 1 (never: no self-trigger)', task(201, '\\QwtDeathReporter', '1'), False),
        ('100 \\QubesPvNic (a start: not subscribed)',  task(100, '\\QubesPvNic', '0'), False),
    ]
    rows = []
    for name, e, want in samples:
        channel = e.findtext('System/Channel')
        wrapper = etree.Element('log'); wrapper.append(e)   # '*' IS the Event element, as Windows evaluates it
        got = any(bool(wrapper.xpath(xp)) for xp in selects[channel])
        rows.append((name, want, got))
    return rows


def run(defect: str) -> int:
    text = INSTALLER.read_text(encoding='utf-8', errors='replace')
    reg = region(text, 'DEATH-REPORTER')
    selects = build_selects(reg, defect)
    fail = 0
    for name, want, got in matrix(selects):
        ok = want == got
        fail += 0 if ok else 1
        print(f"{'ok  ' if ok else 'FAIL'} xpath: {name} -> {'subscribed' if got else 'not subscribed'} (want {'subscribed' if want else 'not subscribed'})")
    # the three lists agree across the installer, the reporter and the packaging
    rep = REPORTER.read_text(encoding='utf-8', errors='replace')
    inst_exes = set(ps_list(reg, 'ourExes')); rep_exes = set(ps_hash_keys(rep, 'QwtDeathExes'))
    inst_svcs = set(ps_list(reg, 'ourServices')); rep_svcs = set(ps_hash_keys(rep, 'QwtDeathServices'))
    inst_tasks = set(ps_list(reg, 'ourTasks'))
    rep_tasks = set(ps_hash_keys(rep, 'QwtDeathHelperTasks')) | set(re.findall(r"'(\\[A-Za-z-]+)'", re.search(r'\$script:QwtDeathScriptTasks\s*=\s*@\((.*?)\)', rep, re.S).group(1)))
    for label, a, b in (('executables', inst_exes, rep_exes), ('services', inst_svcs, rep_svcs), ('tasks', inst_tasks, rep_tasks)):
        ok = a == b
        fail += 0 if ok else 1
        print(f"{'ok  ' if ok else 'FAIL'} drift: the installer's {label} are the reporter's ({len(a)} vs {len(b)}; only-installer={sorted(a - b)} only-reporter={sorted(b - a)})")
    ms = MAKESETUP.read_text(encoding='utf-8', errors='replace')
    staged = set(re.findall(r"'([a-z0-9-]+\.exe)'", ms)) - {'vc_redist.x64.exe', 'devcon.exe', 'xencons_monitor.exe', 'xencons_tty.exe', 'qrexec-agent.exe'}
    staged = {s for s in staged if s in ('wgcbroker.exe', 'notifhost.exe', 'etwproxy.exe', 'qrexec-wrapper.exe', 'bind-dirs.exe', 'qubesdb-read.exe', 'gui-agent.exe', 'gui-watchdog.exe')}
    missing = sorted(staged - inst_exes)
    ok = not missing
    fail += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} drift: every binary make-setup.ps1 stages into bin is subscribed (missing={missing})")
    print(f"{'PASS' if not fail else 'FAIL'}  xpath matrix{(' under defect ' + defect) if defect else ''}: {fail} failing checks")
    return 1 if fail else 0


def main() -> int:
    defect = os.environ.get('XPATH_DEFECT', '')
    if defect:
        if defect not in KNOBS:
            print(f'FAIL  unknown XPATH_DEFECT={defect} ({" ".join(KNOBS)})'); return 2
        return run(defect)
    bad = 0
    print('==== clean ====')
    if run('') != 0:
        bad = 1
    for k in KNOBS:
        print(f'==== defect {k} (must FAIL) ====')
        p = subprocess.run([sys.executable, __file__], env={**os.environ, 'XPATH_DEFECT': k}, capture_output=True, text=True)
        fails = [ln for ln in p.stdout.splitlines() if ln.startswith('FAIL xpath')]
        if p.returncode != 0 and fails:
            print(f'PASS  defect {k}: the matrix FAILED as required ({len(fails)} failing: {fails[0][5:95]})')
        else:
            print(f'FAIL  defect {k}: the matrix did NOT fail (rc={p.returncode}) - that guard is decoration'); bad = 1
    return bad


if __name__ == '__main__':
    sys.exit(main())
