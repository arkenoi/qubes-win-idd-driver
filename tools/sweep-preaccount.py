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
    if not all(hasattr(mod, n) for n in ("normalize", "FAMILY_BY_NAME", "signature_level_kept")):
        return None
    return mod


# The log macros of the four component trees, mapped to the level letter the LINE will carry. The
# sweep keys on that letter (family|LEVEL|text), so a wrong letter here compares an E against a W and
# reports a line as unaccounted while the baseline holds it - the `stale_level` failure log-sweep.py
# already documents at its own line 4021.
MACRO_LEVEL = {
    "LogError": "E", "LogWarning": "W", "LogInfo": "I", "LogDebug": "D", "LogVerbose": "D",
    # BLogE WAS MISSING UNTIL 2026-11-07, and it is notifhost's ERROR emitter: 26 call sites against
    # BLogW's 16, so the louder half of that module's complaints was the invisible half. MACRO_RE
    # sorts by length descending, so "BLogE" is tried before "BLog" and the longer name wins; adding
    # it the other way round would have matched `BLog` and read the level as Info. The same omission
    # in tools/msg-audit.py's C_CALL read 42 of notifhost's complaints as zero while counting its 152
    # informational BLog lines as complaints - inverted on both sides, found the same day.
    "BLogE": "E", "BLogW": "W", "BLog": "I",
    "win_perror": "E", "win_perror2": "E",
    # THE GOING-DOWN DEGRADE MACROS (agent/gui-agent/lifecycle.h, agent ef3ce2b). The letter here is
    # the LOUD branch; the other branch is handled below, because one site emits TWO possible lines.
    # Without these two rows `MACRO_RE` matched neither - `\bLogError\s*\(` cannot match
    # `LogErrorUnlessGoingDown(` - so the eight sites the going-down fix routes were invisible to
    # this checker: it reported "2 log literal(s) added" on a commit that touched ten.
    "LogErrorUnlessGoingDown": "E", "LogWarningUnlessGoingDown": "W",
}
# EACH OF THESE EMITS TWO LINES, AND THE SECOND IS THE WHOLE POINT OF THE MACRO: the same text at
# LOG_LEVEL_INFO with a fixed suffix, whenever a going-down already holds. The sweep keys on
# family|LEVEL|text, so the degraded line is a DIFFERENT KEY from the loud one - which is precisely
# the failure this baseline already records against A6LEAK, where fc94490 lowered one line to Info
# and the two level-W rows that declared it stopped matching, re-judging the line per campaign and
# failing all three cells of 20261018-010748 (SWEEPGATEVERDICTUNSTABLE). Both keys are checked.
DEGRADE_MACROS = ("LogErrorUnlessGoingDown", "LogWarningUnlessGoingDown")
MACRO_RE = re.compile(r"\b(" + "|".join(sorted(MACRO_LEVEL, key=len, reverse=True)) + r")\s*\(")
# The extensions in which a MACRO_LEVEL name can be a CALL rather than a mention. See the measured
# incident at the hunk scan in diff_log_calls().
C_SOURCE = (".c", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".hxx")
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


def literal_runs(fmt):
    """Every stretch of FIXED text in a format string, in order."""
    return [p.strip() for p in CONVERSION_RE.split(fmt) if p and p.strip()]


def longest_literal_run(fmt):
    """The longest stretch of FIXED text in a format string - all a source-derived check can honestly
    compare, and in this project also the most distinctive part of the line, because that is where the
    QGA* tag sits."""
    parts = literal_runs(fmt)
    return max(parts, key=len) if parts else ""


def log_calls_in(text, tail=None):
    """Every log macro call in a block of C, as (offset, level, format-or-None).

    ONE extractor, used by the diff scan AND by the `since` scan below, because two spellings of
    this would be free to disagree about what a site emits - and then a line present at `since`
    would read as added, or an added one as present. `tail` is the degrade suffix: given, each
    going-down site also yields its INFO twin; None, only the loud branch."""
    out = []
    for mm in MACRO_RE.finditer(text):
        name = mm.group(1)
        # A MACRO'S OWN #define IS NOT AN EMITTER. lifecycle.h names both degrade macros in their
        # definitions, where there is no format literal to find, and they were reported as two
        # UNREADABLE lines - a refusal with nothing wrong behind it, which is how a check like this
        # becomes something people pass by editing the baseline.
        if text[text.rfind("\n", 0, mm.start()) + 1:mm.start()].lstrip().startswith("#"):
            continue
        rest = text[mm.end():]
        # THE DEGRADE MACROS TAKE THE STOP FLAG FIRST, so the format sits past the first comma.
        # Matching a literal run straight after `(` reads `FALSE, "QGA...` as no literal at all,
        # which turned every one of the eight routed sites into UNREADABLE on first run.
        if name in DEGRADE_MACROS:
            comma = rest.find(",")
            rest = rest[comma + 1:] if comma >= 0 else rest
        run = LITERAL_RUN_RE.match(rest.lstrip())
        fmt = "".join(LITERAL_RE.findall(run.group(1))) if run else ""
        out.append((mm.start(), MACRO_LEVEL[name], fmt or None))
        if name in DEGRADE_MACROS and fmt and tail is not None:
            out.append((mm.start(), "I", fmt + tail))
    return out


def literal_keys_at(rev, path, repo, prefix, tail):
    """The (level, longest-fixed-run) pairs a file ALREADY HELD at `rev`.

    THE DIFF CANNOT TELL AN ADDED LINE FROM A MOVED CALL. Measured 2026-11-07 on
    154c573cfa70..ef3ce2b5e0ef: routing eight sites through a degrade macro rewrote each call's
    first line, so all eight loud E/W branches - same text, same level, same function, present and
    undeclared for months - came back as this change's additions. A checker whose refusal names a
    line the change did not add teaches its reader to edit the baseline to shut it up, which is the
    opposite of what it is for. A file absent at `rev` returns the empty set: then every line in it
    really is new."""
    rel = path[len(prefix):] if prefix and path.startswith(prefix) else path
    out = subprocess.run(["git", "-C", repo or ROOT, "show", "%s:%s" % (rev, rel)],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return set()
    # EVERY run, not just the longest, BECAUSE THE DIFF SEES ONLY THE LINES IT TOUCHED. A call
    # written across four source lines whose FIRST line was edited yields a format cut off at the
    # first line's end, and the longest run of that fragment is a different string from the longest
    # run of the whole call - measured on QGASTARTDISMISS, where the fragment's `refused - foreground
    # held by pid` lost to `; the hidden menu may take clicks`'s one extra character in the full
    # format, so an unchanged line was still reported as added. Holding every run makes the
    # comparison independent of where the diff happened to stop.
    keys = set()
    for _, lvl, fmt in log_calls_in(out.stdout, tail):
        for part in literal_runs(fmt or ""):
            keys.add((lvl, part))
    return keys


def goingdown_tail(repo, head):
    """The fixed suffix the degrade macros append, READ OUT OF THE HEADER THAT DEFINES IT, AT `head`.

    It is not copied here. A second spelling of this string is the defect this project keeps paying
    for - the same reason normalize() and FAMILY_BY_NAME are imported rather than duplicated - and a
    copy would go stale the first time the wording changes, silently accounting a key no build emits.
    Read with `git show` and not off disk, because the checkout is not the revision under test: the
    preflight checks a PACKAGE's sha, and a tail read from the working tree would describe a build
    nobody is about to run. Raises when it cannot be read - a suffix this cannot see is not a suffix
    that is absent, and cmd_check turns a raise into exit 2, which is never a pass."""
    tried = []
    for rel in ("gui-agent/lifecycle.h", "agent/gui-agent/lifecycle.h"):
        spec = "%s:%s" % (head, rel)
        tried.append(spec)
        out = subprocess.run(["git", "-C", repo or ROOT, "show", spec],
                             capture_output=True, text=True)
        if out.returncode != 0:
            continue
        m = re.search(r'#\s*define\s+QGA_GOINGDOWN_TAIL\s+L"((?:[^"\\]|\\.)*)"', out.stdout)
        if m:
            return m.group(1)
        raise RuntimeError("%s defines no QGA_GOINGDOWN_TAIL; the degraded form of every "
                           "LogErrorUnlessGoingDown line is then unknowable from source" % spec)
    raise RuntimeError("none of %s exists, yet a going-down degrade macro is used in this diff"
                       % ", ".join(tried))


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
           "gui-agent", "watchdog", "include",
           # AND `src`, BECAUSE core-agent IS THE OTHER SUBMODULE AND ITS WHOLE TREE LIVES UNDER IT.
           # Measured 2026-11-07 on 7760000cba34..c766a4f2895e, the commit that degraded two
           # qrexec-wrapper lines: with `--repo core-agent` given correctly, this pathspec filtered
           # the diff to ZERO LINES, so the leg reported "0 log literal(s) added" on a diff that
           # adds two. A pathspec naming only the parent's directory names cannot match a path
           # inside a submodule, which is rooted at the submodule.
           "src"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("git diff %s..%s failed: %s" % (since, head, (out.stderr or "").strip()))
    # ONE HUNK'S ADDED LINES ARE SCANNED AS ONE TEXT, for the same reason C concatenates adjacent
    # literals: a log call is routinely written across several source lines. `prefix` makes a
    # submodule's paths repo-root-relative, so LOGFILE_BY_PATH stays keyed one way - in the agent
    # submodule the diff says `gui-agent/capture.c` while the table says `agent/gui-agent/`, and
    # without it every agent path would map to no family at all. The line reported is the literal's
    # own, derived from its offset inside the joined hunk (see below).
    # ONLY A FILE THAT COMPILES THESE MACROS CAN CALL ONE. Every name in MACRO_LEVEL is a C/C++
    # emitter, so a .py, .sh, .ps1, .json or .md file that merely NAMES one is prose about the macro,
    # never a call site - and this file and tools/msg-audit.py both discuss them at length. Measured
    # 2026-11-07 on HEAD~1..HEAD (d0814c66..6f082720, the commit that taught this checker the degrade
    # macros): the diff touched only tools/sweep-preaccount.py, the substring test below matched the
    # macro name inside a COMMENT, the tail read was demanded, and `agent/gui-agent/lifecycle.h` does
    # not resolve in the PARENT repo because agent/ is a gitlink - so the leg exited 2, an INSTRUMENT
    # failure, and campaign-preflight dies on a non-zero pre-account leg. A .py comment would have
    # aborted a campaign at minute 0.
    # This filter does NOT narrow the real coverage: PowerShell emitters (guest/*.ps1's Write-QwtLog,
    # packaging/setup's Write-Log) are not in MACRO_LEVEL and were never seen by this checker. That
    # gap is real and is recorded against the census, not closed here.
    found, hunks, cur_ok = [], [], False
    for raw in out.stdout.splitlines():
        if raw.startswith("+++ b/"):
            path = prefix + raw[6:]
            cur_ok = path.endswith(C_SOURCE)
            if cur_ok:
                hunks.append([path, 0, "", []])
            continue
        if raw.startswith("@@"):
            if not cur_ok:
                continue
            m = re.match(r"@@ -\S+ \+(\d+)(?:,\d+)? @@\s*(.*)$", raw)
            if m and hunks:
                fm = re.search(r"\b(\w+)\s*\(", m.group(2).strip())
                hunks.append([hunks[-1][0], int(m.group(1)), fm.group(1) if fm else "", []])
            continue
        if cur_ok and hunks and raw.startswith("+") and not raw.startswith("+++"):
            hunks[-1][3].append(raw[1:])
    # THE SUFFIX IS READ ONCE, AND ONLY WHEN A DEGRADE MACRO IS ACTUALLY IN THE DIFF: a tree with no
    # going-down site has no lifecycle.h to read, and demanding one there would turn every other
    # tree's clean leg into an instrument failure. The test runs over the SCANNED hunks, not the raw
    # diff, so it answers the question the sentence above claims to ask.
    scanned = "\n".join("\n".join(h[3]) for h in hunks)
    tail = goingdown_tail(repo, head) if any(m in scanned for m in DEGRADE_MACROS) else None
    for path, lineno, func, lines in hunks:
        if not lines:
            continue
        text = "\n".join(lines)
        # WHERE each joined line begins in `text`, so a macro's offset names the line it sits ON.
        # Reporting the hunk's FIRST line instead sent the reader 38 lines away from the literal:
        # measured on agent/gui-agent/capture.c, where QGADDARECREATE at 689 was refused as 651. A
        # refusal that names a file:line the reader then cannot find is worse than naming neither.
        starts, pos = [], 0
        for ln in lines:
            starts.append(pos)
            pos += len(ln) + 1
        for off, level, fmt in log_calls_in(text, tail):
            at = lineno + sum(1 for s in starts if s <= off) - 1
            found.append((path, at, func, level, fmt))
    # AND NOW DROP WHAT WAS ALREADY THERE, on (level, fixed run) - the pair the sweep's own key is
    # built from: if the sweep could not have told the two apart, neither may this.
    prior = {}
    for path in {e[0] for e in found}:
        prior[path] = literal_keys_at(since, path, repo, prefix, tail)
    kept = []
    for e in found:
        run = longest_literal_run(e[4] or "")
        # CONTAINED IN a prior run, not equal to one, BECAUSE THE DIFF CAN CUT A RUN IN HALF. The
        # QGANOTIFPID call's first line ends mid-sentence at `...notifhost.exe from the `, so the
        # fragment's longest run is a PREFIX of the whole call's `...from the install dir in
        # session` and no equality could ever hold. Bounded by the same 8 characters that make a run
        # readable at all, and by the level, so this cannot swallow a short coincidence - and the
        # direction of the remaining error is the one this file already accepts: it may pass a line
        # whose run matches something, and it never silently drops one it could not read.
        if len(run) >= 8 and any(lvl == e[3] and run in part for lvl, part in prior[e[0]]):
            continue
        kept.append(e)
    return kept


def preaccount_report(baseline, literals, sweep):
    """Which of these lines would the sweep meet for the first time? Returns four lists - accounted,
    unaccounted, unreadable, unkeyed - so nothing is folded into a count that hides which kind it was."""
    sigs = baseline.get("signatures") or {}
    pats = [p.get("regex", "") for p in (baseline.get("patterns") or []) if p.get("regex")]
    by_family = {}
    for key in sigs:
        by_family.setdefault(key.split("|")[0], []).append(sweep.normalize(key))
    accounted, unaccounted, unreadable, unkeyed = [], [], [], []
    for path, lineno, func, level, fmt in literals:
        fam = family_for(path, sweep)
        # A LINE THE SWEEP MAKES NO SIGNATURE OF HAS NOTHING TO ACCOUNT FOR: collect_signatures() drops
        # it before any baseline lookup, so a row written for it is never read. Its own rule decides,
        # imported, not copied. An unmapped path still fails below - the rule needs the family.
        if fam is not None and not sweep.signature_level_kept(fam, level, func):
            unkeyed.append((path, lineno, func, level, fam))
            continue
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
            # A PATTERN IS MATCHED AGAINST THE KEY, because that is what the sweep matches it against:
            # its rows are anchored like `^watchdog\|E\|WatchdogThread: Proc...`. This used to search
            # the bare longest literal run, so EVERY anchored row missed, and a line the sweep would
            # have accounted for was reported UNACCOUNTED - a refusal with nothing wrong behind it.
            # The run is also the wrong string for a row keyed on a QGA* tag: the tag sits in the
            # format's HEAD and the longest fixed stretch is routinely the tail.
            # AND A ROW MUST BE ANCHORED ON THE FIXED TEXT BEFORE ITS FIRST SPECIFIER. The sweep
            # matches a row against the normalised RENDERED line (`hwnd=0xH`); nothing static can
            # render, so this matches the FORMAT (`hwnd=0x%x`). A row written past the first
            # specifier is true for exactly one of the two - measured on QGATOASTIDENT, where
            # `hwnd=0xH` accounted for nothing until the regex stopped at `hwnd=`.
            pseudo = "%s|%s|%s: %s" % (fam, level, func, sweep.normalize(fmt))
            hit = any(re.search(rx, pseudo) for rx in pats)
        # The NEEDLE is the longest fixed run, which is the strongest thing to match on - but it is
        # often the line's TAIL, and a reader at preflight needs the head, where this project puts the
        # QGA* tag. Both are carried: the head identifies the line, the run is what was compared.
        head = fmt.split("%")[0].strip() or run
        (accounted if hit else unaccounted).append((path, lineno, func, level, head, fam))
    return accounted, unaccounted, unreadable, unkeyed


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
    accounted, unaccounted, unreadable, unkeyed = preaccount_report(baseline, literals, sweep)
    # RESOLVE BOTH ENDS FOR THE LABEL, because `[:12]` on a revision EXPRESSION truncates the part
    # that makes it one: `ef3ce2b5e0ef^` printed as `ef3ce2b5e0ef`, so a real parent..child range
    # read exactly like the empty `X..X` the preflight legitimately prints when the baseline is
    # stamped at the package's own commit. Measured 2026-11-07: the diff had used the caret and found
    # 10 literals, while the label said the range was a single commit. An instrument whose label does
    # not name what it measured is how a reader talks themselves out of a real number.
    def _short(rev):
        out = subprocess.run(["git", "-C", a.repo or ROOT, "rev-parse", "--short=12", rev],
                             capture_output=True, text=True)
        return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else rev[:12]
    print("PREACCOUNT %s..%s: %d log literal(s) added, %d accounted, %d UNACCOUNTED, %d unreadable, "
          "%d not keyed by the sweep (no signature at their level)"
          % (_short(since), _short(a.head), len(literals), len(accounted), len(unaccounted),
             len(unreadable), len(unkeyed)))
    for path, lineno, func, level, run, fam in unaccounted:
        print("  UNACCOUNTED %s:%d  %s|%s|%s: %s" % (path, lineno, fam, level, func, run[:100]))
    for path, lineno, func, level, fmt, why in unreadable:
        print("  UNREADABLE  %s:%d  %s%s" % (path, lineno, why,
                                             (" - " + fmt[:60]) if fmt else ""))
    if unaccounted or unreadable:
        # preaccounted_at holds a PARENT commit and a submodule leg's range is derived from it as
        # <stamp>:<submodule>, so that leg's own head is no sha to stamp. 2026-11-12, build-4.3.42.1278:
        # the agent leg's hint said `record --at 32129613e337`, the agent's sha.
        stamp = a.head[:12]
        if a.path_prefix:
            stamp = "<the parent commit that pins this %s tree>" % a.path_prefix.rstrip("/")
        print("REFUSE: the sweep would meet %d line(s) it has never been told about. Classify each "
              "with Jev, write them into %s, then stamp `record --at %s`."
              % (len(unaccounted) + len(unreadable), a.baseline, stamp))
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
