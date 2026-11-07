#!/usr/bin/env python3
"""sweep-preaccount.py - WILL THE SWEEP HAVE TO DISCOVER THIS CHANGE'S LOG LINES MID-RUN?

Owner, 2026-11-07: "on ANY change, update the sweep data so the sweep is going to pass. wasting a
run on discovery that it would not is extremely stupid. So do xerj plus jev on this wired as part of
preflight. How many times you failed to pre-account new lines?"

EIGHT recorded occasions, and that is a floor rather than a total, because the live register holds
only open issues:

  1    acceptance run 40006931995: win10-clean failed with 13 unclassified signatures, ten of them
       the MSI `Note: 1:` / `Rollback` pair. The incident is written into log-sweep.py's own header.
  2    f7c3088a  "the new detail key was unclassified"
  3    b36d5b9c  "the QGATOASTREPAINT declaration did not name its newest producer"
  4    bffa4a79  a release line "three artifacts declared and nothing wrote" - the same mismatch
                 seen from the other side
  5-7  QGAVCHANUNDECLARED, which RECURRED A THIRD TIME on a sha that already carried the fix
  8    SWEEPNOTREAD: 13 breaches and 39 undeclared error lines unread for a whole session

Every one is the same shape: our own change emits a line, nothing tells the baseline, and a run is
spent discovering it. `log-sweep.py baseline-init` learns signatures FROM a run - discovery by
construction - so it cannot help before that run exists. This asks the question statically, from the
diff, so an unaccounted line is refused at preflight instead.

WHAT IT CANNOT DO, SAID PLAINLY. A format string's `%s` is not knowable from source, so a
source-derived key can never equal a runtime key in general. This does not pretend to: for each log
literal a change adds it takes the LONGEST LITERAL RUN - the fixed text between conversions, which in
this project is where the distinctive QGA* tag lives - and asks whether any baseline signature of the
same family, or any baseline pattern, already carries that run. A line whose longest run is unknown to
the baseline is one the sweep has never been told about. The errors fall in the honest direction: it
can pass a line whose run coincidentally matches something, and it never silently skips one it could
not read. An unmappable path, an unreadable literal or a run too short to decide on is REPORTED and
fails the check, because a producer this cannot read is not a producer that does not exist.

    tools/sweep-preaccount.py check  --baseline <baseline.json> [--since <sha>] [--head <sha>]
    tools/sweep-preaccount.py record --baseline <baseline.json> --at <sha>

`check` exits 0 when nothing is unaccounted, 1 when something is (each named with file:line), and 2
when it could not run - which is never a pass. `record` stamps `preaccounted_at`, the field that was
missing: the baseline carries `generated`, `merged_from` and `source_reports` and NO commit, so
nothing could say which product version it accounts for.

TWO THINGS ARE IMPORTED RATHER THAN COPIED, because a second definition of either is the defect this
project keeps paying for: log-sweep.py's `normalize()`, which builds the keys this compares against,
and its `FAMILY_BY_NAME`, which is the authoritative log-file-to-family map. Loaded by path because
the module name has a hyphen - the same way tools/core-stackscan.py loads xen-core-rip.py.
"""

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def _load_sweep():
    """log-sweep.py as a module, for normalize() and FAMILY_BY_NAME. None when it cannot be loaded:
    comparing against keys built by a different rule would be a fabricated verdict."""
    spec = importlib.util.spec_from_file_location("log_sweep", os.path.join(HERE, "log-sweep.py"))
    if spec is None or spec.loader is None:
        return None
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except Exception:
        return None
    if not hasattr(mod, "normalize") or not hasattr(mod, "FAMILY_BY_NAME"):
        return None
    return mod


# The log macros of the four component trees, mapped to the level letter the LINE will carry. The
# sweep keys on that letter (family|LEVEL|text), so a wrong letter here compares an E against a W and
# reports a line as unaccounted while the baseline holds it - the `stale_level` failure log-sweep.py
# already documents at its own line 4021.
MACRO_LEVEL = {
    "LogError": "E", "LogWarning": "W", "LogInfo": "I", "LogDebug": "D", "LogVerbose": "D",
    "BLogW": "W", "BLog": "I",
    "win_perror": "E", "win_perror2": "E",
}
MACRO_RE = re.compile(r"\b(" + "|".join(sorted(MACRO_LEVEL, key=len, reverse=True)) + r")\s*\(")
LITERAL_RE = re.compile(r'L?"((?:[^"\\]|\\.)*)"')
# C CONCATENATES ADJACENT LITERALS, AND SO MUST THIS. Found while validating against 4e0e3e29..adc2b202:
# notifhost's ETW line is written as two `L"..."` pieces on two source lines, so a per-line scan produced
# TWO fragments - one of them the meaningless tail `) - the gui-agent launches it; the listing is` - and
# compared each against the baseline on its own. A fragment is a weaker needle than the line, which is
# how a check like this drifts into decoration. The run of adjacent literals is taken as one string.
LITERAL_RUN_RE = re.compile(r'((?:L?"(?:[^"\\]|\\.)*"\s*)+)')
CONVERSION_RE = re.compile(
    r"%[-+ #0]*[\d*]*(?:\.\d+)?(?:hh|h|ll|l|L|w|z|j|t|I64|I32|I)?[diouxXeEfgGaAcspnSsZ%]")

# WHICH LOG FILE a source path writes into. The FAMILY is never named here - it comes from
# log-sweep.py's FAMILY_BY_NAME, so this table cannot invent a family the sweep does not know.
# Each row carries the evidence for it; the first matching prefix wins, so a specific file precedes
# its directory.
LOGFILE_BY_PATH = (
    # agent/gui-agent/etwproxy.c is PART OF THE AGENT and logs through the agent's own macros: the
    # only writers of etw-proxy.log are tools/notifhost/etwproxy.cpp:496 and qtb_shared.h:67.
    ("agent/watchdog/", "gui-watchdog-20260101-000000-1.log"),
    ("agent/gui-agent/", "gui-agent.log"),
    ("agent/", "gui-agent.log"),
    ("tools/notifhost/etwproxy.cpp", "etw-proxy.log"),            # qtb_shared.h:67, etwproxy.cpp:496
    ("tools/notifhost/", "bridge.log"),                           # qtb_shared.h:107-109, :158
    ("core-agent/src/qrexec-agent/", "qrexec-agent-1.log"),
    ("core-agent/src/qrexec-wrapper/", "qrexec-wrapper-1.log"),
    ("core-agent/src/relocate-dir/", "relocate-dir-1.log"),       # FAMILY_BY_NAME: binddirs
    # The PowerShell qrexec services and the guest helpers log one file per script per day through
    # core-agent/src/qubes-rpc-services/log.ps1, which FAMILY_BY_NAME matches by name.
    ("core-agent/src/qubes-rpc-services/", "log.ps1-20260101.log"),
    ("guest/", "guest.ps1-20260101.log"),
    ("packaging/setup/", "qwt-improved-install.log"),
)


def family_for(path, sweep):
    """The baseline family a path's log lines will carry, resolved through the sweep's own map. None
    when this path writes into no log the sweep reads (the kernel driver is the real case), which the
    caller REPORTS rather than skipping: a family nobody mapped is how a producer goes unnoticed."""
    for prefix, logname in LOGFILE_BY_PATH:
        if path.startswith(prefix):
            for rx, fam in sweep.FAMILY_BY_NAME:
                if rx.search(logname):
                    return fam
            return None
    return None


def longest_literal_run(fmt):
    """The longest stretch of FIXED text in a format string - all a source-derived check can honestly
    compare, and in this project also the most distinctive part of the line, because that is where the
    QGA* tag sits."""
    parts = [p.strip() for p in CONVERSION_RE.split(fmt) if p and p.strip()]
    return max(parts, key=len) if parts else ""


def added_log_literals(since, head, repo=None, prefix=""):
    """Every log literal this change ADDS, as (path, line, function, level, format-or-None).

    Reads `git diff -U0` with the enclosing function in the hunk header, which is where the sweep's
    keys get their `Function: ` prefix. Raises on a git failure: a diff that did not run is not an
    empty diff.

    `repo` IS A PARAMETER BECAUSE agent/ IS A SUBMODULE. Found while validating this file: a diff
    taken in the parent shows the gitlink and NOT one line of the agent's source, so the agent - the
    tree that writes most of the lines this exists to catch - would have reported a reassuring zero.
    The caller runs this once per tree, with that tree's own sha range; the preflight step does."""
    cmd = ["git", "-C", repo or ROOT, "diff", "--unified=0", "--no-color", "--no-ext-diff",
           "%s..%s" % (since, head), "--",
           "agent", "driver", "core-agent", "tools", "guest", "packaging",
           "gui-agent", "watchdog", "include"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("git diff %s..%s failed: %s" % (since, head, (out.stderr or "").strip()))
    # ONE HUNK'S ADDED LINES ARE SCANNED AS ONE TEXT, for the same reason C concatenates adjacent
    # literals: a log call is routinely written across several source lines. `prefix` makes a
    # submodule's paths repo-root-relative, so LOGFILE_BY_PATH stays keyed one way - in the agent
    # submodule the diff says `gui-agent/capture.c` while the table says `agent/gui-agent/`, and
    # without it every agent path would map to no family at all. The line reported is the literal's
    # own, derived from its offset inside the joined hunk (see below).
    found, hunks = [], []
    for raw in out.stdout.splitlines():
        if raw.startswith("+++ b/"):
            hunks.append([prefix + raw[6:], 0, "", []])
            continue
        if raw.startswith("@@"):
            m = re.match(r"@@ -\S+ \+(\d+)(?:,\d+)? @@\s*(.*)$", raw)
            if m and hunks:
                fm = re.search(r"\b(\w+)\s*\(", m.group(2).strip())
                hunks.append([hunks[-1][0], int(m.group(1)), fm.group(1) if fm else "", []])
            continue
        if hunks and raw.startswith("+") and not raw.startswith("+++"):
            hunks[-1][3].append(raw[1:])
    for path, lineno, func, lines in hunks:
        if not lines:
            continue
        text = " ".join(lines)
        # WHERE each joined line begins in `text`, so a macro's offset names the line it sits ON.
        # Reporting the hunk's FIRST line instead sent the reader 38 lines away from the literal:
        # measured on agent/gui-agent/capture.c, where QGADDARECREATE at 689 was refused as 651. A
        # refusal that names a file:line the reader then cannot find is worse than naming neither.
        starts, pos = [], 0
        for ln in lines:
            starts.append(pos)
            pos += len(ln) + 1
        for mm in MACRO_RE.finditer(text):
            run = LITERAL_RUN_RE.match(text[mm.end():].lstrip())
            fmt = "".join(LITERAL_RE.findall(run.group(1))) if run else ""
            at = lineno + sum(1 for s in starts if s <= mm.start()) - 1
            found.append((path, at, func, MACRO_LEVEL[mm.group(1)], fmt or None))
    return found


def preaccount_report(baseline, literals, sweep):
    """Which of these lines would the sweep meet for the first time? Returns three lists - accounted,
    unaccounted, unreadable - so nothing is folded into a count that hides which kind it was."""
    sigs = baseline.get("signatures") or {}
    pats = [p.get("regex", "") for p in (baseline.get("patterns") or []) if p.get("regex")]
    by_family = {}
    for key in sigs:
        by_family.setdefault(key.split("|")[0], []).append(sweep.normalize(key))
    accounted, unaccounted, unreadable = [], [], []
    for path, lineno, func, level, fmt in literals:
        fam = family_for(path, sweep)
        run = longest_literal_run(fmt) if fmt else ""
        if fmt is None or fam is None or len(run) < 8:
            why = ("no log of the sweep's maps this path" if fam is None else
                   "the literal could not be read from this line" if fmt is None else
                   "only %d characters of fixed text - too little to decide on" % len(run))
            unreadable.append((path, lineno, func, level, fmt, why))
            continue
        needle = sweep.normalize(run)
        hit = any(needle in k for k in by_family.get(fam, []))
        if not hit:
            hit = any(re.search(rx, run) for rx in pats)
        # The NEEDLE is the longest fixed run, which is the strongest thing to match on - but it is
        # often the line's TAIL, and a reader at preflight needs the head, where this project puts the
        # QGA* tag. Both are carried: the head identifies the line, the run is what was compared.
        head = fmt.split("%")[0].strip() or run
        (accounted if hit else unaccounted).append((path, lineno, func, level, head, fam))
    return accounted, unaccounted, unreadable


def cmd_check(a):
    sweep = _load_sweep()
    if sweep is None:
        print("PREACCOUNT INSTRUMENT: log-sweep.py could not be loaded for normalize() and "
              "FAMILY_BY_NAME - comparing against keys built by a different rule would be a "
              "fabricated verdict")
        return 2
    with open(a.baseline, encoding="utf-8") as f:
        baseline = json.load(f)
    since = a.since or baseline.get("preaccounted_at")
    if not since:
        print("PREACCOUNT INSTRUMENT: the baseline carries no preaccounted_at and --since was not "
              "given, so there is no commit to diff from. Stamp one first:\n"
              "    tools/sweep-preaccount.py record --baseline %s --at <sha>" % a.baseline)
        return 2
    try:
        literals = added_log_literals(since, a.head, a.repo, a.path_prefix)
    except RuntimeError as e:
        print("PREACCOUNT INSTRUMENT: %s" % e)
        return 2
    accounted, unaccounted, unreadable = preaccount_report(baseline, literals, sweep)
    print("PREACCOUNT %s..%s: %d log literal(s) added, %d accounted, %d UNACCOUNTED, %d unreadable"
          % (since[:12], a.head[:12], len(literals), len(accounted), len(unaccounted),
             len(unreadable)))
    for path, lineno, func, level, run, fam in unaccounted:
        print("  UNACCOUNTED %s:%d  %s|%s|%s: %s" % (path, lineno, fam, level, func, run[:100]))
    for path, lineno, func, level, fmt, why in unreadable:
        print("  UNREADABLE  %s:%d  %s%s" % (path, lineno, why,
                                             (" - " + fmt[:60]) if fmt else ""))
    if unaccounted or unreadable:
        print("REFUSE: the sweep would meet %d line(s) it has never been told about. Classify each "
              "with Jev, write them into %s, then stamp `record --at %s`."
              % (len(unaccounted) + len(unreadable), a.baseline, a.head[:12]))
        return 1
    print("OK: every log line this change adds is already accounted for")
    return 0


def cmd_record(a):
    """Stamp the commit this baseline accounts for.

    ATOMICALLY, because the sweep reads this file WHILE a campaign runs: `open(w)` truncates before
    it writes, so a reader arriving in that window gets a partial file - which the sweep reports as
    INVALID-SWEEP-DATA and which costs the cells that were mid-flight. Written beside the target and
    renamed, so a reader sees either the old file or the new one.

    IN THE ORDER IT WAS LOADED: `sort_keys=True` reformatted 86 lines for a 1-line change the first
    time this ran. The sweep's own writer uses sort_keys=False (tools/log-sweep.py:5371), so sorting
    here churns a file whose every line gets reviewed, while a campaign is reading it."""
    with open(a.baseline, encoding="utf-8") as f:
        baseline = json.load(f)
    baseline["preaccounted_at"] = a.at
    tmp = a.baseline + ".preaccount.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(baseline, f, indent=1)
        f.write("\n")
    os.replace(tmp, a.baseline)
    print("PREACCOUNT recorded: %s accounts for the product at %s" % (a.baseline, a.at[:12]))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    ck = sub.add_parser("check")
    ck.add_argument("--baseline", required=True)
    ck.add_argument("--since")
    ck.add_argument("--head", default="HEAD")
    ck.add_argument("--repo", help="the tree to diff in; agent/ is a submodule and must be given "
                                   "its own sha range")
    ck.add_argument("--path-prefix", default="", dest="path_prefix",
                    help="prepended to the diff's paths so a submodule's are repo-root-relative, "
                         "e.g. --path-prefix agent/")
    rc = sub.add_parser("record")
    rc.add_argument("--baseline", required=True)
    rc.add_argument("--at", required=True)
    a = ap.parse_args(argv)
    return cmd_check(a) if a.cmd == "check" else cmd_record(a)


if __name__ == "__main__":
    sys.exit(main())
