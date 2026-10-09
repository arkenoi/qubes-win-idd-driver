#!/usr/bin/env python3
"""report-gate-review.py - find every place our code REPORTS A FAULT on a CLOCK, and have Jev judge
whether the clock is standing in for an observable condition.

Owner, 2026-10-09, after catching a dom0 ACTION notification ("The guest is waiting at the sign-in
or lock screen", advising "arm autologon") on a guest whose autologon was armed and which logged in
moments later: "what the actual fuck, it is exact stupid thing we were supposed to clean up
everywhere", and then, when I had fixed that one site and written down the lesson: "so what the fuck
are you going to do, drop it on the floor?"

He is right that a hand fan-out is not an answer. The defect had ALREADY been found and fixed one
day earlier, at the sibling notification twenty lines away in the same file (deslice-down,
2026-10-08: "The broker was healthy. The shell took 27 s to appear on that boot, so the deadline
left it about three seconds, and a dom0 ACTION notification went out about a helper that was fine").
That sweep was not driven by an enumeration of the report sites, so it fixed what it looked at. This
is the enumeration, so the next one cannot be.

This is the sibling of tools/lifecycle-review.py and REUSES its machinery rather than copying it -
the site extraction is brace-counted, not regex-truncated, and one implementation cannot drift from
the other. The division is the project's: finding the sites and pairing them with their gate is
CODE; deciding whether a gate is a fact or a stand-in is JEV's (.claude/skills/jev).

A site qualifies when ONE enclosing block contains BOTH:
  * a fault report  - a dom0 notification (QerrReport*), an ERROR/WARNING log line, a harness FAIL
                      verdict; and
  * a clock         - an elapsed-time comparison, a *_MS threshold, a deadline or a sleep-then-judge.
That pairing is mechanical and says nothing about correctness: a clock ANCHORED on an observable
event (deslice-down anchors at the launch and holds while no shell exists) is legitimate, and so is
a short anti-race grace that does not substitute for the fact (uac-pending waits 6 s for consent.exe
to finish creating its window, but still requires the window). Jev separates those from the real
defect, which is a clock that is the ONLY thing deciding whether a fault is reported.

    tools/report-gate-review.py [--list] [--jobs N] [--out DIR] [path ...]

Exit 0 = nothing flagged, 1 = something flagged, 2 = Jev did not run for at least one site, which
means the review is INCOMPLETE and must never be read as clean.
"""
from __future__ import annotations
import argparse
import concurrent.futures
import importlib.util
import json
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _load_lifecycle_review():
    """The shared site extractor. Imported, not copied: see the header."""
    path = ROOT / 'tools' / 'lifecycle-review.py'
    spec = importlib.util.spec_from_file_location('lifecycle_review', path)
    if spec is None or spec.loader is None:
        sys.exit(f'FATAL: cannot load {path} - this tool reuses its site extractor')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)          # main() is guarded by __name__, so nothing runs
    return mod


LR = _load_lifecycle_review()

# THE FAULT INJECTOR IS NOT A SUBJECT, and this is the one exclusion here - stated with its reason,
# not a convenience list. agent/gui-agent/faultinject.c exists to SYNTHESISE faults on a registry
# knob, so "a fault reported on a clock" is its specification rather than a defect, and the whole
# file sits behind `#if QGA_FAULT_INJECTION` - its own comment says "compiled out of anything
# shipped", and tools/cut-release.sh refuses any package whose binary carries the marker. Judging it
# produced 9 of 23 flags on the first full run (FiPumpStallMs, FiPrintWindowFail, FiShouldCaptureExit,
# FiMonStale, FiRingStallActive among them), every one a category error, which is enough noise to
# make the real set unreadable. Nothing else is skipped: a skip list is how the previous sweep missed
# a site, and the shapes already judged legitimate are given to Jev as context instead.
LR.SKIP = re.compile(LR.SKIP.pattern + r'|(^|/)faultinject\.(c|h)$')

# A FAULT REPORT. QerrReport* is the dom0 route; LogError/LogWarning are the guest log's own fault
# lines; the shell and PowerShell forms are how the harnesses announce one.
REPORT = (r'QerrReportText\s*\(|QerrReport\s*\(|LogError\s*\(|LogWarning\s*\(|'
          r'Write-(Error|Warning)\b|'
          r'\bverdict\s+\w+\s+"?(FAIL|INVALID)|say\s+"[^"]*\b(FAIL|INVALID|REFUS)')

# A CLOCK **DECIDING** SOMETHING - a COMPARISON against elapsed time, not merely a mention of time.
# The first version of this pattern matched any GetTickCount64 call, any `timeout`, any Start-Sleep,
# and returned 143 sites, most of them bounded waits that this tool's own CONTEXT says are NOT the
# defect. A bound is not a verdict: what makes the defect is a report whose CONDITION is "enough
# time has passed". So the shapes here all contain a relational operator against a time term.
CLOCK = (r'(>=|<=|>|<)\s*[^;\n]{0,40}\b[A-Z][A-Z0-9_]*_MS\b|'          # ... >= SOME_THRESHOLD_MS
         r'\b[A-Z][A-Z0-9_]*_MS\b[^;\n]{0,20}(>=|<=|>|<)|'              # SOME_MS < ...
         r'\b(now|GetTickCount64\(\))\s*-\s*\w+\s*(>=|<=|>|<)|'      # now - since >= ...
         # AND THE CANONICAL SHAPE, which the first two narrowings both MISSED: the deadline is
         # computed earlier and the comparison is against a plain variable - `now >= s_SecureNextWarn`
         # (desktop-stuck) and `now >= g_BrokerNextWarn` (deslice-down), i.e. BOTH of the sites this
         # tool exists for. Caught by its own defect arm: run against the pre-fix main.c it found 20
         # sites and flagged none, because ProcessNewFrame was never extracted as a site at all.
         # Comparing `now` against anything is a clock deciding, whatever the right-hand side is named.
         r'\b(now|GetTickCount64\(\))\s*(>=|<=|>|<)\s*\w+|'            # now >= s_SomeDeadline
         r'\w+\s*(>=|<=|>|<)\s*\w*(Next|Deadline|Due|Until|Expire)\w*|'
         r'\w+\s*-\s*s_\w+\s*(>=|<=|>|<)|'                            # x - s_since > ...
         r'(>=|<=|>|<)\s*\w*(deadline|Deadline|DEADLINE)|'
         r'\$\(\(\s*SECONDS\s*-\s*\w+\s*\)\)\s*-(lt|gt|le|ge)|'  # shell: $((SECONDS-t0)) -lt
         r'\bSECONDS\s*-\s*\w+\s*\)\)\s*-(lt|gt|le|ge)')

HIT = re.compile(f'({REPORT})|({CLOCK})')
REPORT_RE = re.compile(REPORT)
CLOCK_RE = re.compile(CLOCK)

# Known-good shapes are NOT skipped - they are judged and expected to come back clean, because a
# skip list is how the last sweep missed a site. They are named to Jev as context instead.
CONTEXT = """WHAT THIS PROJECT HAS ALREADY DECIDED ABOUT CLOCKS AND REPORTS (facts, 2026-10-09):

LEGITIMATE, and each was reached by measurement rather than taste:
 * A clock ANCHORED ON AN OBSERVABLE EVENT, with the impossible window excluded by a fact.
   deslice-down anchors at g_WgcLastLaunch (assigned at exactly one site, never sliding) and holds
   the clock at zero while GetShellWindow() is NULL, because the broker runs in the user's session
   and "not running for 30 s" before a shell exists is arithmetic about a window in which starting
   was impossible.
 * A SHORT ANTI-RACE GRACE that does not replace the fact. uac-pending waits UAC_PENDING_GRACE_MS
   = 6000 for consent.exe to finish creating its window, but still requires consent.exe to be
   running and to own top-level windows none of which can be mapped.
 * A RE-WARN INTERVAL that only limits how often an already-established fault is repeated.
 * A BOUNDED timeout on a guest call, so a dead guest cannot hang a harness. A bound is not a
   verdict; what matters is whether the VERDICT rests on it.

THE DEFECT, measured twice in two days:
 * desktop-stuck sent dom0 an ACTION notification ("waiting at the sign-in or lock screen", advising
   to arm autologon) after SECURE_DESKTOP_FIRST_WARN_MS = 30000 on the secure desktop and nothing
   else, on a guest with AutoAdminLogon=1, DefaultUserName set, and a console session that came up
   moments later. The block's own comment said autologon takes "15-17 s on this testbed, entirely
   normal" - so the clock was measuring boot speed and reporting it as a fault. Fixed by reading the
   arming state and the console user; one state (armed autologon that never completes) has no
   positive signal and is still clock-decided, which is NAMED in the source as the residual.
 * deslice-down did the same thing one day earlier and was fixed the same way (anchor on the
   observable launch).

SO THE QUESTION FOR EACH SITE IS NARROW: is the clock the ONLY thing deciding that a fault gets
reported, where an observable fact about that fault is available?"""

RUBRIC = {"questions": {
    "clock_decides_alone": {"type": "noul",
        "instructions": {"judge": "Judge ONLY from `state`. In this block, is a CLOCK the only thing "
                                  "deciding that a fault is REPORTED - i.e. no observable fact about the "
                                  "fault itself is required first? A clock anchored on an observed event, a "
                                  "short anti-race grace that still requires the fact, a re-warn interval, "
                                  "or a bounded call timeout are NOT this defect."},
        "criteria": {"true": "the report fires on elapsed time alone, with no fact about the fault required",
                     "false": "an observable fact is required, or the clock is anchored/bounded rather than deciding"}},
    "observable_available": {"type": "choice",
        "instructions": {"judge": "Judge ONLY from `state`. If the clock decides alone, is there an observable "
                                  "fact ALREADY REACHABLE in this code that would decide it instead? Name it only "
                                  "if the block or the context shows it; do not invent an API."},
        "criteria": {"in-block": "a fact already read in this very block could gate the report",
                     "nearby": "a fact reachable from this code (a registry value, a process, a session query, "
                               "a state variable) could gate it, though it is not read here yet",
                     "none": "no observable fact exists for this condition, so a bound is the honest fallback",
                     "not-applicable": "the clock does not decide alone, so the question does not arise"}},
    "false_report_plausible": {"type": "noul",
        "instructions": {"judge": "Judge ONLY from `state`. Could this site report a fault that is NOT occurring - "
                                  "on a slow boot, a slow guest, a busy rig - the way desktop-stuck and "
                                  "deslice-down both did?"},
        "criteria": {"true": "a slower-than-expected but healthy system can trip this report",
                     "false": "it cannot: the condition is established before the report"}},
    "load_bearing": {"type": "noul",
        "instructions": {"judge": "Judge ONLY from `state`. Does a PRODUCT verdict or a dom0-visible message depend "
                                  "on this report - as opposed to a debug line nobody grades?"},
        "criteria": {"true": "a dom0 notification, an acceptance verdict or a gate outcome depends on it",
                     "false": "it is diagnostic only"}}}}

DEFECT_Q = ('clock_decides_alone', 'false_report_plausible')


def qualifying_sites(paths: list[str]) -> list:
    """Sites whose block contains BOTH a fault report and a clock. Mechanical; no judgement.

    LR.sites() returns a LIST of dicts, each already carrying a line-numbered `code` field - that
    rendering is reused rather than re-sliced, so this tool and lifecycle-review cannot disagree
    about where a block begins and ends.
    """
    LR.HIT = HIT                                  # drive the shared extractor with our pattern
    found = LR.sites(paths)
    # THE DECIDING FACT IS OFTEN IN THE CALLER, SO THE CALLER TRAVELS WITH THE SITE. Measured
    # 2026-10-09: StartDismissCheckStuck(IN HWND start, IN DWORD fgPid) was scored
    # clock_decides_alone 0.88 - the highest of any site - because its block holds only a settle and
    # a LogWarning. The fact ("the hidden Start menu is STILL open") is established by its CALLER and
    # arrives as a parameter, and the state Jev was given was 2.9 KB with no caller in it at all.
    # lifecycle-review.py's add_callers() already finds callers, but it records them as SEPARATE
    # sites marked caller=True, and a caller block usually has no clock of its own - so this filter
    # was dropping exactly the context the judgement needed. Judging a function in isolation
    # systematically over-flags any whose precondition is a parameter.
    # EVERY site in the file is a potential caller, not only the ones add_callers() marked. It skips
    # a caller that is already a site of its own (`if name in targets or (rel, name) in out:
    # continue`), so the first version of this - which collected only caller=True entries - still
    # judged StartDismissCheckStuck with a 2948-byte state and no caller in it, identical before and
    # after, and its score did not budge from 0.88. Its caller IS a subject in its own right, which
    # is exactly the case that was being dropped.
    by_file = {}
    for st in found:
        if st.get('code'):
            by_file.setdefault(st['file'], []).append(st)
    keep = []
    for site in found:
        block = site.get('code') or ''
        rep = REPORT_RE.search(block)
        clk = CLOCK_RE.search(block)
        if not (rep and clk):
            continue
        extra = []
        blk = site.get('block') or ''
        if blk and not blk.startswith('top-level'):
            for c in by_file.get(site['file'], []):
                if c is site or c.get('block') == blk:
                    continue
                if re.search(rf'\b{re.escape(blk)}\s*\(', c['code'] or ''):
                    extra.append(f"// ---- THE CALLER of {blk}, where its precondition may be established:\n"
                                 + (c['code'] or ''))
        site['block_text'] = block + ('\n\n' + '\n\n'.join(extra) if extra else '')
        site['callers_added'] = len(extra)
        site['report_sample'] = rep.group(0)
        site['clock_sample'] = clk.group(0)
        keep.append(site)
    return keep


def prob(ans: dict, q: str) -> float:
    """A question's probability, under whichever key its type uses. jev.py puts a noul's value in
    "noul" and a choice's confidence in "confidence"; there is no "p" key, and assuming one is how
    this tool reported 0 flagged on a file whose known-bad block Jev had already scored."""
    v = ans.get(q) or {}
    for key in ('noul', 'confidence', 'score', 'p'):
        if key in v:
            try:
                return float(v[key])
            except (TypeError, ValueError):
                return 0.0
    return 0.0


def judge(site: dict, wdir: Path):
    state = (f"FILE: {site['file']}\nBLOCK: {site['block']}\nROLE: {site.get('role', '?')}\n"
             f"REPORT FOUND: {site['report_sample']}\nCLOCK FOUND: {site['clock_sample']}\n\n"
             f"{CONTEXT}\n\nTHE BLOCK:\n{site['block_text']}\n")
    tag = re.sub(r'[^\w.-]', '_', f"{site['file']}-{site['block']}")[:120]
    sf = wdir / f'{tag}.state.txt'
    rf = wdir / f'{tag}.rubric.json'
    af = wdir / f'{tag}.answers.json'
    sf.write_text(state, encoding='utf-8')
    rf.write_text(json.dumps(RUBRIC), encoding='utf-8')
    import subprocess
    r = subprocess.run([sys.executable, str(ROOT / 'tools' / 'jev.py'), str(rf), str(sf), '--out', str(af)],
                       capture_output=True, text=True, cwd=ROOT)
    if r.returncode == 2 or not af.exists():
        return site, None, (r.stderr or r.stdout).strip()[:200]
    try:
        raw = json.loads(af.read_text())
    except Exception as e:                      # noqa: BLE001 - a malformed answer is INCOMPLETE
        return site, None, f'unreadable answers: {e}'
    # JEV'S SHAPE, NOT A GUESSED ONE. jev.py writes {"model": ..., "answers": {q: {...}}, "usage":
    # ...} and a noul's value is under the key "noul", a choice's under "choice"/"confidence".
    # Reading ans[q]['p'] - which is what this did - found nothing for every question, so the
    # reviewer reported "0 flagged" no matter what Jev said. Caught by the defect arm: on the
    # pre-fix main.c Jev had scored the known-bad block false_report_plausible 0.67,
    # observable_available in-block 0.70 and load_bearing 0.87, and this still printed 0 flagged.
    ans = raw.get('answers', raw)
    if not isinstance(ans, dict):
        return site, None, f'unexpected answers shape: {type(ans).__name__}'
    return site, ans, None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--list', action='store_true', help='list the qualifying sites and exit; no Jev calls')
    ap.add_argument('--jobs', type=int, default=4)
    ap.add_argument('--out', default='')
    ap.add_argument('paths', nargs='*', default=[])
    a = ap.parse_args()

    paths = a.paths or LR.SCOPE
    found = qualifying_sites(paths)
    print(f'{len(found)} site(s) pair a fault report with a clock, over {len(paths)} scope path(s)')
    if a.list:
        for st in sorted(found, key=lambda d: (d['file'], d['start'])):
            print(f"  {st['file']}:{st['start'] + 1}-{st['end'] + 1}  {st['block']}")
            print(f"      report={st['report_sample']!r}  clock={st['clock_sample']!r}  hits={st['hits']}")
        return 0

    wdir = Path(a.out) if a.out else Path(tempfile.mkdtemp(prefix='report-gate-'))
    wdir.mkdir(parents=True, exist_ok=True)
    flagged, incomplete = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        for site, ans, err in ex.map(lambda st: judge(st, wdir), found):
            if ans is None:
                incomplete.append((site, err))
                continue
            hot = [q for q in DEFECT_Q if prob(ans, q) >= 0.5]
            if hot:
                flagged.append((site, ans, hot))

    print(f'\n{len(flagged)} flagged, {len(incomplete)} INCOMPLETE, evidence in {wdir}')
    for site, ans, hot in sorted(flagged, key=lambda t: -max(prob(t[1], q) for q in t[2])):
        worst = max(prob(ans, q) for q in hot)
        print(f"\n  {site['file']}:{site['start'] + 1}  {site['block']}   worst {worst:.2f}")
        for q in DEFECT_Q:
            if q in ans:
                print(f"      {q} {prob(ans, q):.2f}")
        obs = ans.get('observable_available', {})
        if obs:
            print(f"      observable_available={obs.get('choice')} conf {float(obs.get('confidence') or 0):.2f}")
        if 'load_bearing' in ans:
            print(f"      load_bearing {prob(ans, 'load_bearing'):.2f}")
    for site, err in incomplete:
        print(f"  INCOMPLETE {site['file']}:{site['start'] + 1} - {err}")

    if incomplete:
        return 2
    return 1 if flagged else 0


if __name__ == '__main__':
    sys.exit(main())
