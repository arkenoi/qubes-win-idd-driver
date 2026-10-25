#!/usr/bin/env python3
"""Mechanical lints for the acceptance harnesses. No judgement required.

WHY THIS EXISTS. Protocol rules 14-25 encode real lessons, but they are all META-rules: they ask
a reader to notice something ("could this evidence come from something else?", "does the stimulus
reach the code under test?"). That works exactly as well as the reader's attention on the day, and
the whole point of this campaign is that attention is not a control. Owner, 2026-08-31: *"those
are general rules, LLM-dependant. I want ... simple checks even stupidiest model can follow not
relying on meta-rules. Preferably even code."*

So: every rule that CAN be made mechanical is made mechanical here. Each lint is a hard yes/no
over the source, with a name, the rule it enforces, and the incident that motivated it. Run it,
read the exit code, done.

    tools/lint-harness.py [--ledger PATH] [--quiet]

Exit 0 = clean, 1 = findings, 2 = usage/internal error.

NOT EVERY RULE IS HERE, deliberately. Rule 24 ("the stimulus must reach the code under test") and
rule 21 ("triage by how loud the failure is") are genuinely judgement calls; pretending to automate
them would produce a lint that passes while the thing it names goes unchecked - which is the exact
disease this file is treating. They stay as prose, and are listed at the bottom as NOT LINTED so
their absence is visible rather than assumed.
"""
from __future__ import annotations
import argparse, os, re, sys
from pathlib import Path

ROOT = Path(os.environ.get("LINT_ROOT") or Path(__file__).resolve().parent.parent)
HARNESS: list[Path] = []
GUEST_PS: list[Path] = []
PY_TOOLS: list[Path] = []
FAULTINJECT = ROOT / "agent" / "gui-agent" / "faultinject.c"

def _rescan() -> None:
    """Re-read the tree. Exists so the SELF-TEST can point the lints at a fixture containing a
    deliberate violation of each rule - a lint that has never been seen to fire is exactly the
    unproven check this whole file is about (H5, applied to the linter)."""
    global HARNESS, GUEST_PS, FAULTINJECT
    # SCOPE: campaign harnesses AND tools/*.sh. Measured 2026-09-01: L3 scanned only
    # mgmt/harness and therefore missed two real nested-quote violations in tools/ - one of them
    # in bench-agent.sh, the source of the canonical benchmark baselines, where a silently-empty
    # query corrupts the numbers everything else is compared against. The doc's own VERIFY
    # command found what the lint could not, which is the argument for having both.
    # tools/tests/ is excluded: those files contain DELIBERATE violations as fixtures.
    HARNESS = sorted((ROOT / "mgmt" / "harness").glob("*.sh")) + \
              [p for p in sorted((ROOT / "tools").glob("*.sh")) if "tests" not in p.parts]
    GUEST_PS = sorted((ROOT / "guest").glob("*.ps1"))
    # L11 also has to see the python tools: the boot-time read that shipped broken on 2026-09-21
    # lived in tools/guest-state-judge.py, which no lint was looking at.
    global PY_TOOLS
    PY_TOOLS = [p for p in sorted((ROOT / "tools").glob("*.py"))
                if "tests" not in p.parts and p.name != "lint-harness.py"]
    FAULTINJECT = ROOT / "agent" / "gui-agent" / "faultinject.c"

_rescan()

findings: list[tuple[str, str, str]] = []          # (lint, location, message)
def finding(lint: str, where: str, msg: str) -> None:
    findings.append((lint, where, msg))


# A RULE THAT IS AGREED BUT NOT YET SATISFIED EVERYWHERE. It is printed in full, by name, and it
# does NOT gate - because the alternatives are worse: tools/lint-baseline.txt forbids additions
# ("Never ADD entries"), and a rule quietly weakened until it passes is the "baselined away"
# failure this file warns about at the top. A pending rule gates as soon as its list is empty,
# which is one line below. Nothing here is hidden; the count is printed whether or not anyone asks.
pending: list[tuple[str, str, str]] = []


def pending_finding(lint: str, where: str, msg: str) -> None:
    pending.append((lint, where, msg))


# --------------------------------------------------------------------------- L1
def l1_no_double_background() -> None:
    """RULE 14. `nohup ... &` inside a harness makes the wrapper exit 0 while the runner keeps
    going; the caller then believes it finished. On 2026-08-31 that produced two P5 runs on one
    guest and a fabricated SG2 FAIL."""
    for f in HARNESS:
        for n, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if "nohup" in line and line.rstrip().endswith("&"):
                finding("L1-double-background", f"{f.name}:{n}",
                        "nohup ... & backgrounds a runner the caller cannot wait on")


# --------------------------------------------------------------------------- L2b
def l2b_reboot_must_be_proven() -> None:
    """A harness that reboots a guest must PROVE the reboot happened, not assume it.

    `qtest shutdown` is asynchronous. On 2026-09-09 a test issued it, polled "is the guest up",
    declared success 34 seconds later, and ran every post-reboot assertion against the still-running
    pre-reboot guest - one of which PASSED by re-reading a file written 30 seconds earlier. The only
    honest evidence is a boot identity that CHANGED (Win32_OperatingSystem.LastBootUpTime), which is
    what mgmt/harness/e2e-wait.sh's g_reboot_proven does. Use it."""
    for f in HARNESS:
        txt = f.read_text(errors="replace")
        lines = [ln for ln in txt.splitlines()
                 if ln.lstrip() and not ln.lstrip().startswith("#")]
        body = "\n".join(lines)
        if "qtest shutdown" not in body:
            continue
        if "qvm-start" not in body:
            continue                                   # shuts down but never brings it back
        if "g_reboot_proven" in body or "LastBootUpTime" in body:
            continue                                   # the boot identity is checked
        finding("L2b-unproven-reboot", f.name,
                "reboots a guest (qtest shutdown + qvm-start) without checking the boot identity "
                "changed - use g_reboot_proven from e2e-wait.sh")


# --------------------------------------------------------------------------- L2
def l2_vmlock_required() -> None:
    """RULE 15. Any harness that drives a guest must take the per-VM lock, or two of them can run
    on one subject and interleave their probes."""
    for f in HARNESS:
        txt = f.read_text(errors="replace")
        # CALLS, not mentions. This matched the substring anywhere, so a static checker or a script
        # that merely NAMES the tool in a comment was reported as "drives a guest" - which is how
        # tools/check-capture-callers.sh, a grep, was told to take a VM lock. A call is the tool
        # named on a line that is not a comment.
        if not any("tools/qtest" in ln for ln in txt.splitlines()
                   if ln.lstrip() and not ln.lstrip().startswith("#")):
            continue                                   # not a guest-driving harness
        if "vmlock.sh" in txt and "vm_lock" in txt:
            continue
        if f.name == "vmlock.sh":
            continue
        # SOURCED LIBRARIES are exempt, narrowly and for a reason: they run INSIDE a caller that
        # already holds the lock, so taking it again would deadlock rather than protect anything.
        # shutdown-lib.sh joined this list on 2026-09-21 when qwt_shutdown started reading the
        # guest's OWN BOOT TIME (one read-only qrexec call) to tell "rebooted while we waited"
        # from "ignoring the request" - a distinction that had been guessed wrong almost daily.
        # The exemption is by NAME, not by pattern, so a new guest-driving harness cannot inherit
        # it by accident, and tools/tests/lint-selftest.sh drives L2 against a fixture to prove
        # the rule still fires for everything else. wu-liveness.sh joined on 2026-10-02: the pass-liveness
        # probe wu-e2e.sh and the killed-pass cell source while they hold the guest's lock.
        # logvol-lib.sh joined on 2026-10-13: the secondary log volume library (PLAN-acceptance-optimization
        # section 3) reads one power state and pushes its guest-side binder, both from a cell harness that
        # already holds the lock; its own caller contract says so in its header.
        # rtc-lib.sh joined on 2026-10-14: w_rtc_utc sets RealTimeIsUniversal and reads it back -
        # two qtest calls - from a harness that already holds the guest's lock. It exists as its own
        # file precisely so prime-run.sh can source it without sourcing e2e-wait.sh; while it lived
        # in the latter, the call resolved to nothing (RTCCALLUNRESOLVED).
        if f.name in ("shutdown-lib.sh", "wu-liveness.sh", "logvol-lib.sh", "rtc-lib.sh"):
            continue
        finding("L2-missing-vmlock", f.name,
                "drives a guest via tools/qtest but never calls vm_lock")


# --------------------------------------------------------------------------- L19
def l19_guest_run_must_sweep_the_log() -> None:
    """RULE: A HARNESS THAT DRIVES A GUEST MUST READ THAT GUEST'S ERROR LOG.

    The owner made a clean error log the gate condition ("Make clean error log the gate
    condition. Any error is fuckup!") and tools/log-sweep.py has carried an
    error_lines_undeclared threshold for it since. Then a harness was written for a field report
    that counted notifications and looked at nothing else: when its count probe broke it printed
    MISSING DATA and carried on past four [ERROR] lines it had itself printed, and past 766
    error/warning lines in the guest's log, including the one the owner could see on his screen.
    He had to point at it. Asked whether this agent reads, detects and acts on all errors, Jev
    answered 0.03, named this - a harness that does not check the logs - the worst of the four
    failures at 0.65, and scored the remedy at 1.00: every rig harness runs the sweep and fails
    on undeclared error lines, enforced so a harness without it cannot pass. Owner, same day:
    "also yes, every rig run calls for log sweep and action".

    A harness satisfies this by calling mgmt/harness/log-sweep.sh, or tools/log-sweep.py, or by
    delegating to another harness that does. Exemptions are BY NAME, never by pattern, so a new
    guest-driving harness cannot inherit one by accident."""
    # a harness that merely reads one value off a guest is not a run; the rule targets the ones
    # that BOOT or INSTALL, which is where a log accumulates something worth reading
    drivers = ("qvm-start", "quick-upgrade.sh", "prime-run.sh", "clone-guest.sh")
    # clean-boot-sweep.sh IS a sweeper: it archives the guest's logs, boots clean and calls
    # log-sweep.sh. The rule already allows "delegating to another harness that does"; without
    # the name here the lint cannot see the delegation and asks for a second sweep.
    sweepers = ("log-sweep.sh", "log-sweep.py", "clean-boot-sweep.sh")
    # These are the sweep itself, or libraries sourced inside a caller that already sweeps, or
    # single-purpose readers that boot nothing of their own.
    exempt = ("log-sweep.sh", "vmlock.sh", "shutdown-lib.sh", "wu-liveness.sh", "e2e-wait.sh",
              "env-assert.sh", "checkpoint.sh", "clone-guest.sh", "clone-to-template.sh",
              "seal-qwt-golden.sh", "build-media.sh", "reprovision-usb.sh")
    for f in HARNESS:
        if f.name in exempt:
            continue
        txt = f.read_text(encoding="utf-8", errors="replace")
        code = [ln for ln in txt.splitlines() if ln.lstrip() and not ln.lstrip().startswith("#")]
        if not any(any(d in ln for d in drivers) for ln in code):
            continue                                   # boots nothing: not a rig run
        if any(any(sw in ln for sw in sweepers) for ln in code):
            continue
        pending_finding("L19-guest-run-without-log-sweep", f.name,
                "boots or installs a guest but never sweeps its error log - a clean error log is "
                "the gate condition, so a run that does not read the log cannot report on it")


# --------------------------------------------------------------------------- L20
def l20_module_log_read_must_be_bounded() -> None:
    """RULE: A PATTERN MATCH IN A MODULE LOG MUST BE BOUNDED TO THE RUN IT IS JUDGING.

    The guest logger is one file per module per day, so every instance that ran today is in the file
    a harness greps and an unbounded match can be satisfied by an earlier one. Found by hand in four
    places: failproof-gates.sh took `Select -First 1` of the QGAFAULT-INIT banner - the OLDEST of
    the day - so the fault-injection gate would have been confirmed against a stale banner; p5-run.sh
    and promoted-checks.sh counted matches over the whole file.

    Bounded by any of: a mark plus `$all[$mark..]`, `-Last 1`, a slice from the last `process ID:`
    record, a timestamp filter, or a scope to the RUNNING instance's pid. The pid scope was added
    2026-10-09: on this rig a timestamp filter is not usable at all (the guest clock flips ~3 h about
    60 s into every boot), while the pid the process wrote into its own line prefix
    ([date.time.ms-<pid>:<tid>-LEVEL]) is a strictly stronger bound than -Tail - it cannot match an
    earlier instance, which is the whole point of the rule. A cell with two reboot arms in one day
    needs exactly this: without it, arm A's lines are counted into arm B's verdict.
    Pending, not gating, until the named list is empty."""
    # the read has to be of a windows-utils MODULE log - the ones several processes now share
    reads_module_log = re.compile(r"(gui-agent|qrexec-(?:agent|wrapper)|qubesdb-daemon)-\*?\.?log|Filter\s+'?(gui-agent|qrexec-\w+|qubesdb-daemon)-\*\.log")
    bounded = ("-Last 1", "process ID:", "$all[", "-Tail", "total_lines", "KeepRx", "AfterLine",
               # a scope to the running instance's pid, as written into the line prefix
               "agentPid", "pidRx", "$runningPid")
    # PER READ SITE, not per file. A file-level version of this rule read p5-run.sh as clean because
    # ONE of its reads used -Tail while the AGENTMAP count right above it was unbounded - exactly the
    # false negative that let the defect through in the first place. Selecting the newest FILE with
    # -First 1 is legitimate, so the window starts at the read and covers the lines that consume it.
    # The next 14 lines THAT ARE CODE: counting comments against the budget flagged a read that is
    # bounded a few lines further down, past the comment explaining it.
    WINDOW = 14
    # A bare line count is a mark, not a verdict - it is how the bounded harnesses take their offset.
    judges = ("Select-String", "-SimpleMatch", "-Pattern", "-match", "findstr", "| grep")
    for f in HARNESS:
        lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
        code_at = [i for i, ln in enumerate(lines) if ln.strip() and not ln.lstrip().startswith("#")]
        for n, line in enumerate(lines, 1):
            if line.lstrip().startswith("#") or not reads_module_log.search(line):
                continue
            after = [i for i in code_at if i >= n - 1][:WINDOW]
            window = [lines[i] for i in after]
            if not any(any(j in ln for j in judges) for ln in window):
                continue                                   # a mark or a bare count, not a verdict
            if any(any(b in ln for b in bounded) for ln in window):
                continue
            pending_finding("L20-unbounded-module-log-read", f"{f.name}:{n}",
                    "matches a pattern in a module log with nothing bounding it to this run - "
                    "instances share one file per day now, so an earlier one can satisfy the check "
                    "(%s)" % line.strip()[:70])


# --------------------------------------------------------------------------- L3
def l3_no_nested_quote_powershell() -> None:
    """RULE 16. `powershell -Command "... \\"...\\" ..."` is re-split at every hop and FAILS
    SILENTLY - no output, no error. rnd8's keyed-mutex counter returned nothing for an unknown
    period and the empty values were written out as a product FAIL."""
    pat = re.compile(r'powershell[^\n]*-Command\s+"[^\n]*\\"')
    for f in HARNESS:
        for n, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if pat.search(line):
                finding("L3-nested-quote-powershell", f"{f.name}:{n}",
                        "escaped quotes inside -Command; use -EncodedCommand (fails SILENTLY)")


# --------------------------------------------------------------------------- L4
VERDICT_RE = re.compile(r"printf\s+'([^']*)'")
GOOD = {"PASS", "PASS-UNPROVEN"}
BAD = {"FAIL", "INVALID-INSTRUMENT", "INVALID-VACUOUS", "BLOCKED", "N/A"}

def l4_every_check_can_fail() -> None:
    """RULE 18, made mechanical. A check that never emits a NON-PASS verdict cannot fail, and a
    check that cannot fail is worthless however carefully it is worded. This does not need to
    understand the check - only that both branches exist in the file that emits it.

    Four checks failed this in one day (SG4, keyed-mutex, RND-3, mode-followed). mode-followed is
    the clearest: it was emitted ONLY from a PASS branch, so no input could have reddened it."""
    for f in HARNESS:
        verdicts: dict[str, set[str]] = {}
        for fmt in VERDICT_RE.findall(f.read_text(errors="replace")):
            fields = fmt.split("\\t")
            if len(fields) < 3:
                continue
            name, verdict = fields[1].strip(), fields[2].strip()
            if not name or "%" in verdict:
                continue
            # a printf-built name keeps its literal stem so the two branches still group together
            verdicts.setdefault(name, set()).add(verdict)
        for name, vs in sorted(verdicts.items()):
            if vs & GOOD and not (vs & BAD):
                finding("L4-check-cannot-fail", f"{f.name}:{name}",
                        f"only ever emits {sorted(vs)} - no branch can produce FAIL/INVALID")


# --------------------------------------------------------------------------- L5
LOGCALL_RE = re.compile(r'Log(?:Warning|Info|Debug|Error)\s*\(\s*"((?:[^"\\]|\\.)*)"', re.S)
GREP_PAT_RE = re.compile(r"""Select-String\s+-Pattern\s+["']([^"']+)["']""")

def l5_injector_string_collision() -> None:
    """RULE 19, made mechanical. FI_CAPTURE_EXIT's message contained the words "capture thread",
    which is exactly what RND-8 counted thread deaths with - so the check detected the INJECTOR
    ANNOUNCING ITSELF and the red proved nothing.

    Collect every literal the fault injector logs, collect every regex the harnesses grep agent
    logs with, and fail on any alternative that appears in both."""
    if not FAULTINJECT.exists():
        return
    logged = " ".join(LOGCALL_RE.findall(FAULTINJECT.read_text(errors="replace"))).lower()
    if not logged:
        return
    for f in HARNESS:
        for pattern in GREP_PAT_RE.findall(f.read_text(errors="replace")):
            for alt in (a.strip() for a in pattern.split("|")):
                # only meaningful multi-word phrases; single tokens produce noise
                if len(alt) < 8 or " " not in alt:
                    continue
                if alt.lower() in logged:
                    finding("L5-injector-collision", f"{f.name}",
                            f'grep pattern "{alt}" also appears in a fault-injector log message: '
                            f"the check would detect the injector, not the defect")


# --------------------------------------------------------------------------- L6
NULLDEREF_RE = re.compile(r"\(\s*Get-(?:FileHash|Item|ItemProperty|Process|ChildItem)[^)]*\)\s*\.\s*\w+\s*\.\s*\w+")

def l6_probe_null_deref() -> None:
    """RULE 23, made mechanical. `(Get-FileHash <missing>).Hash.ToLower()` throws, and inside a
    [pscustomobject] literal that kills the WHOLE object - so the probe emits nothing at all for
    precisely the state it exists to report. pvnic-latch-readback did this: on a guest with the
    applier missing it printed MARKJSON and stopped.

    Chained property access on a cmdlet that can return $null is the signature."""
    for f in GUEST_PS:
        txt = f.read_text(errors="replace")
        # SCOPE: only INSTRUMENTS. A deploy script that throws is a failed deploy and says so
        # loudly; a probe that throws goes SILENT and its caller reads that as "no data". Only
        # files that emit structured output are graded here.
        if "ConvertTo-Json" not in txt and "=== RESULT ===" not in txt:
            continue
        for n, line in enumerate(txt.splitlines(), 1):
            s = line.strip()
            if s.startswith("#"):
                continue
            # a Test-Path / if-guard on the same line is the fix, not the defect
            if "Test-Path" in s or re.search(r"\bif\s*\(", s):
                continue
            if NULLDEREF_RE.search(s):
                finding("L6-probe-null-deref", f"{f.name}:{n}",
                        "chained property access on a cmdlet that can return $null - "
                        "throws on the defective state the probe exists to report")


# --------------------------------------------------------------------------- L7
def l7_orphan_ledger_checks(ledger: Path) -> None:
    """RULE 20, made mechanical. A ledger row that no harness emits is a hand-recorded OBSERVATION,
    not a check; H5 cannot apply to it. Uses EXACT-literal matching, because a prefix sweep wrongly
    reported six checks as implemented on 2026-08-31."""
    if not ledger or not ledger.exists():
        return
    names: set[str] = set()
    for line in ledger.read_text(errors="replace").splitlines():
        f = line.split("\t")
        if len(f) >= 3 and f[2] in ("PASS", "PASS-UNPROVEN") and f[1]:
            names.add(f[1])
    sources = [p for p in (list(HARNESS) + GUEST_PS +
                           sorted((ROOT / "tools").glob("*.sh")) +
                           sorted((ROOT / "tools").glob("*.py"))) if p.name != "lint-harness.py"]
    blobs = {p: p.read_text(errors="replace") for p in sources}
    for name in sorted(names):
        if any(name in txt for txt in blobs.values()):
            continue
        stem = re.sub(r"-\d+x\d+$", "-%s", name)       # printf-built, e.g. mode-followed-1024x768
        if stem != name and any(stem in txt for txt in blobs.values()):
            continue
        finding("L7-orphan-ledger-check", name,
                "no harness emits this verdict: it is an observation, not a deployed check")


def l8_findings_current_state() -> None:
    """The record must answer a topic from its HEAD, not from its chronology.

    FINDINGS.md was one 24,994-line append-only log: 566 dated sections carrying 654 lines that
    retract or supersede something earlier. Reading a topic top-down therefore returned the STALE
    answer, which is not a filing complaint - it produced wrong work twice on 2026-09-01 (the drag
    wobble was read as "parked" when a later section says FIXED; the README said "QWT ships no
    xencons" months after we shipped it). Split into findings/<topic>.md, each with a CURRENT
    STATE head that supersedes its History. These checks keep that shape:

      a. every topic file has a CURRENT STATE block;
      b. every bullet in it is dated `[verified <date>]` or explicitly `UNVERIFIED`, so an
         undistilled claim cannot masquerade as a settled one;
      c. FINDINGS.md stays an index - if prose reappears there, the log is regrowing.
    """
    fdir = ROOT / "findings"
    if not fdir.is_dir():
        return
    for p in sorted(fdir.glob("*.md")):
        txt = p.read_text(errors="replace")
        if "## CURRENT STATE" not in txt:
            finding("L8-findings-no-current-state", p.name,
                    "no '## CURRENT STATE' block: the topic can only be answered by reading its "
                    "whole history, which is the failure this split exists to remove")
            continue
        head = txt.split("## CURRENT STATE", 1)[1].split("## History", 1)[0]
        for line in head.splitlines():
            s = line.strip()
            if not s.startswith(("- ", "* ")):
                continue
            if "UNVERIFIED" in s or re.search(r"\[verified \d{4}-\d{2}-\d{2}\]", s):
                continue
            finding("L8-findings-undated-claim", f"{p.name}: {s[:70]}",
                    "CURRENT STATE bullet carries neither [verified <date>] nor UNVERIFIED")

    # L30: A CLOSED ENTRY MAY NOT SIT IN THE LIVE REGISTER. Owner, 2026-10-21: "ZERO closed issues
    # are allowed in main file, and most of archeology needs to be purged, especially history of
    # stupid ways we failed." findings/issues.md had reached 800K / 239 CURRENT STATE entries, 138
    # of them already fixed and never retired, and at that size a Jev call carrying the register
    # died with max_tokens_exceeded - the register could no longer be submitted as evidence about
    # itself. Retiring them is not a tidy-up; it is what keeps the file usable.
    # The marker is read from the entry HEAD - the leading bracket group - and NOT from the
    # narrative, because the narrative routinely says "FIXED" about something adjacent. Matching the
    # whole line is exactly how my own first pass classified HALTREFUSED660 [P1, OPEN] as closed.
    # A head that states both (a fix landed for part of it, the rest is open) stays: the rule fires
    # only on a head that says closed and never says open.
    CLOSED_MARKS = ("FIXED", "CLOSED", "RESOLVED", "RETIRED", "REFUTED", "WITHDRAWN",
                    "RETRACTED", "STALE", "DECISION TAKEN", "NOT OURS", "UPSTREAM DESIGN")
    OPEN_MARKS = ("OPEN", "QUEUED", "PENDING", "OWNER'S CALL", "NOT YET WIRED", "OWED",
                  "REQUESTED", "NOT FIXED", "UNVERIFIED", "RECURRED", "HELD BY THE OWNER")
    live = fdir / "issues.md"
    if live.exists():
        txt = live.read_text(encoding="utf-8", errors="replace")
        for line in txt.split("## History", 1)[0].splitlines():
            s = line.strip()
            if not s.startswith(("- ", "* ")):
                continue
            m = re.match(r"[-*] (.{0,140}?)\]", s)
            head = (m.group(1) if m else s[:120]).upper()
            if any(c in head for c in CLOSED_MARKS) and not any(o in head for o in OPEN_MARKS):
                finding("L30-closed-entry-in-live-register", f"issues.md: {s[:70]}",
                        "entry head says it is closed - retire it to findings/issues-closed.md")

    idx = ROOT / "FINDINGS.md"
    if idx.exists():
        body = idx.read_text(errors="replace")
        if re.search(r"^#{1,2} \d{4}-\d{2}-\d{2}", body, re.M):
            finding("L8-findings-index-regrowing", "FINDINGS.md",
                    "a dated section was appended to the INDEX: it belongs in findings/<topic>.md")


# --------------------------------------------------------------------------- L32
# A TEST FILE MUST HAVE A PRODUCER, OR SAY WHY IT HAS NONE. Measured 2026-10-25: 73 test files had
# no producer that runs them, and the ones anyone bothered to run were red - clock-sync had been
# failing since the puller swapped a wall-clock deadline for a Stopwatch, qrexec-user-normalise
# since a log line was demoted from LogInfo to LogDebug, and ledger-invariant-audit.py, which
# polices the pixel-ledger invariant, was red while that invariant failed a release campaign. An
# unrun suite is not coverage; it is a file that looks like coverage.
#
# SCOPE: every *.sh and *.py directly under tools/tests, deliberately NOT the *-selftest.sh
# spelling. The census that first counted these missed five files exactly because it globbed a
# naming convention, and a check scoped to a convention cannot see the file that breaks it.
def l32_every_test_file_has_a_producer() -> None:
    tdir = ROOT / "tools" / "tests"
    if not tdir.is_dir():
        return
    listed = tdir / "offline-suites.txt"
    registered: set[str] = set()
    if listed.exists():
        registered = {ln.strip() for ln in listed.read_text(errors="replace").splitlines()
                      if ln.strip() and not ln.lstrip().startswith("#")}
    # The declaration file: "<name>   <reason>". The reason is REQUIRED - a bare name would make
    # this an allowlist, and an allowlist with no reasons is how an exclusion rots.
    decl = tdir / "not-in-the-gate.txt"
    declared: dict[str, str] = {}
    if decl.exists():
        for ln in decl.read_text(errors="replace").splitlines():
            s = ln.strip()
            if not s or s.startswith("#"):
                continue
            parts = s.split(None, 1)
            name = parts[0]
            reason = (parts[1].strip() if len(parts) > 1 else "")
            declared[name] = reason
            if not reason:
                finding("L32-producer-missing", f"{decl.name}: {name}",
                        "declared out of the gate with NO REASON - an exclusion with no reason is "
                        "how an excluded suite rots; give the one line or register the file")
    # A declaration that names nothing cannot be audited, so it is a finding too.
    for name in sorted(declared):
        if not (tdir / name).exists():
            finding("L32-producer-missing", f"{decl.name}: {name}",
                    "declared out of the gate but no such file - the declaration has rotted; "
                    "remove the line")
    # A PRODUCER IS SOMETHING THAT RUNS. A CI workflow, a gate or another script naming the file
    # is a producer; a mention in docs/ or in a .txt is NOT - prose runs nothing. Measured
    # 2026-10-25: 7 files were counted as covered by an earlier census of mine purely because a
    # document mentioned them, which is the same error as scoping the census to one filename
    # pattern - both let a file that nothing runs look like coverage.
    producers: list[Path] = []
    for pat in ("*.yml", "*.yaml"):
        producers += sorted((ROOT / ".github" / "workflows").glob(pat))
    # RECURSIVE under tools/, because the git hooks in tools/hooks/ run suites too and a
    # non-recursive glob flagged 8 files they do run. tools/tests itself is NOT a producer: a
    # sibling suite naming another does not run it, and if one genuinely does, that is a
    # one-line reason in not-in-the-gate.txt, where the chain is visible.
    for pat in ("*.sh", "*.py"):
        producers += [q for q in sorted((ROOT / "tools").rglob(pat)) if "tests" not in q.parts]
    producers += sorted((ROOT / "mgmt").rglob("*.sh"))
    producers += sorted((ROOT / ".githooks").rglob("*")) if (ROOT / ".githooks").is_dir() else []
    # WHOLE-LINE COMMENTS ARE DROPPED BEFORE THE MATCH, and the reason is the same one that makes
    # a doc not a producer: prose runs nothing, and a comment inside tools/foo.sh is prose. Keyed
    # on the first non-space character only - cutting from any `#` would truncate real calls
    # (${v#prefix}, a colour code, a URL fragment) and lose the producer instead of the mention.
    # A trailing-comment mention survives this; that is the deliberate residue, and it is far
    # rarer than the commented-out call or the "see also x-selftest.sh" line this removes.
    blob = ""
    for q in producers:
        try:
            blob += "\n".join(ln for ln in q.read_text(errors="replace").splitlines()
                               if not ln.lstrip().startswith("#")) + "\n"
        except OSError:
            pass
    # WORD-BOUNDARIED, not a substring: `foo.sh` must not be found inside `xfoo.sh` or
    # `foo.sh.bak`. A census that over-matches reads as coverage, and every error in this rule's
    # history has been the flattering one.
    def _named(name: str) -> bool:
        return re.search(r"(?<![\w.-])" + re.escape(name) + r"(?![\w-])", blob) is not None

    for p in sorted(list(tdir.glob("*.sh")) + list(tdir.glob("*.py"))):
        if p.name in registered or p.name in declared or _named(p.name):
            continue
        finding("L32-producer-missing", f"tools/tests/{p.name}",
                "nothing runs this file: no CI workflow, gate or script names it, it is not in "
                "offline-suites.txt, and it is not declared in not-in-the-gate.txt with a reason. "
                "An unrun test rots red unnoticed - that is how a backlog of them accumulated here "
                "(SUITESNOBODYRUNS). The live count is whatever this rule prints; a figure copied "
                "into prose is the thing that rots")


def l33_pwsh_is_located_in_one_place() -> None:
    """L33: nothing but tools/tests/pwsh-path.sh may know where pwsh is.

    MEASURED, CI run 40192417696 and 40156224497 before it: `test` was RED for a day on

        FAIL  clock-sync-selftest.sh  rc=1   settime_behaviour: the model did not run - no verdict

    because the suite ran its model under `"${PWSH:-/home/user/pwsh/pwsh}"` - a path that exists on
    one machine - while the ubuntu runner has pwsh ON PATH throughout. Sixty-odd lines across
    fifty-eight files each resolved pwsh for themselves, in ten spellings, against six locations
    (/home/user/pwsh, /home/user/pwsh74, /home/user/bin/pwsh7, /home/user/.local/pwsh, $HOME/pwsh,
    $HOME/pwsh74). Nothing kept them in sync; the owner's words, 2026-10-25, are that the
    configurations cannot be kept in sync organically.

    The second cost was an instrument one: thirteen sites wrote `PWSH="${PWSH:-A}"` and then
    `[ -x "$PWSH" ] || PWSH=B`, so PWSH=/nonexistent - the fixture for "pwsh is absent" - silently
    measured B. Eleven of twenty-eight "runs without pwsh" passes were uninterpretable because of
    it when the CI suite list was chosen.

    So the location is a single file, and a PATH probe outside it is the same defect wearing a
    portable coat: it ignores an explicit PWSH. A COMMENT may still discuss any of this - a source
    assertion that reads comments fails on correct code, and this project has paid for that
    three times (see l32's note)."""
    # The six locations, plus the probe. Kept in step with pwsh-path.sh's own candidate list, which
    # pwsh-path-selftest.sh asserts names every one of them.
    loc = re.compile(r"(?:/home/user/(?:pwsh|pwsh74|bin/pwsh7|\.local/pwsh)|\$HOME/(?:pwsh|pwsh74))/pwsh")
    probe = re.compile(r"command -v [\"']?pwsh")
    # lint-harness.py is in this set because it has to SPELL the locations in order to
    # forbid them, and it never runs pwsh. Loosening the pattern until it stopped matching
    # its own source would weaken the rule to hide a self-match.
    # gate-as-runner.sh probes PATH on purpose: it is the harness that MASKS every install and
    # then ASSERTS what is reachable, so the probe is the assertion, not a second lookup.
    owner = {"pwsh-path.sh", "pwsh-path-selftest.sh", "lint-harness.py", "gate-as-runner.sh"}
    scope: list[Path] = []
    for d in ("tools", "mgmt", "guest", "packaging", ".githooks"):
        if (ROOT / d).is_dir():
            for pat in ("*.sh", "*.py", "*.ps1", "*"):
                scope += [q for q in (ROOT / d).rglob(pat) if q.is_file()]
    seen: set[Path] = set()
    for f in sorted(scope):
        if f in seen or f.name in owner:
            continue
        seen.add(f)
        if f.suffix not in (".sh", ".py", ".ps1", ""):
            continue
        try:
            lines = f.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for i, ln in enumerate(lines, 1):
            st = ln.lstrip()
            if not st or st.startswith("#"):
                continue
            hit = "a hardcoded pwsh location" if loc.search(ln) else (
                  "its own PATH probe for pwsh" if probe.search(ln) else "")
            if not hit:
                continue
            finding("L33-pwsh-second-lookup", f"{f.relative_to(ROOT)}:{i}",
                    f"{hit} - pwsh is located in exactly one place, tools/tests/pwsh-path.sh. "
                    "Call it (`V=\"$(\"$(dirname \"$0\")/pwsh-path.sh\" || true)\"`) and keep this "
                    "file's own handling of absence. A second lookup drifts: that is how `test` "
                    "was red in CI for a day on a path that exists on one machine, and how "
                    "PWSH=/nonexistent came to measure an installed pwsh instead of an absent one")


NOT_LINTED = [
    ("findings rule 4", "a commit appending history must also touch CURRENT STATE - needs the "
                        "git diff, so it lives in the pre-commit hook, not here"),
    ("rule 21", "triage by how loud the failure is - a judgement about severity"),
    ("rule 24", "the stimulus must reach the code under test - needs a run, not a grep"),
    ("rule 25", "never upgrade a check on a sibling row's proof - judgement about subject class"),
]


# --------------------------------------------------------------------------- L9
# --------------------------------------------------------------------------- L10
# Only variables that NAME A DRIVE TARGET. A default BASE IMAGE to clone from (B10, BASE, G10)
# is a different thing: it selects a source, it does not silently send commands somewhere. Flagging
# those too would bury the real rule in noise and it would be baselined away, which is how a lint
# stops mattering.
TARGET_VARS = r'(?:QTEST_VM|VM|SUBJ|SUBJECT|CHURN|TARGET|GUEST|TPL|DEST|HOLDER|BASE|SRC|GOLDEN|MGMT|DEV|B10|B11|G10|G11|OS|OS_FAMILY)'
# Also catches the unbraced `X=${1:-win...}` form and the OS-FAMILY selectors, which pick
# WHICH golden gets driven and so target the wrong guest just as surely as a qube name.
# Shell's ${VAR:-default}, and PYTHON's `else "default"`. Extending the FILE scope to .py was not
# enough - this pattern only knew the shell idiom, so `sys.argv[1] if len(sys.argv) > 1 else
# "win11-fresh"` still went unreported after tools/ .py files were being scanned. Both forms now.
DEFAULT_TARGET_RE = re.compile(
    r'(?:\$\{' + TARGET_VARS + r'|\b' + TARGET_VARS + r'="?\$\{\d+)'
    r'[^}]*:-(dom0|win[0-9a-z-]*)\}'
    r'''|else\s+["'](dom0|win[0-9a-z][0-9a-z-]*)["']'''
    r'''|\.get\([^)]*,\s*["'](dom0|win[0-9a-z][0-9a-z-]*)["']\)''')

def l10_no_default_target_guest() -> None:
    """RULE 21 (owner, 2026-09-21: "no attempts to target dom0 or self as default target qube
    where explicit target is required"). A defaulted target turns "I forgot to name the guest"
    into "silently drive a different guest". tools/qtest defaulted to win-idd-test, which sent
    BOTH arms of an A/B to a halted VM, recorded "Request refused" where a pass result belongs,
    started that VM twice, and left three Windows guests running at once against the one-guest
    rule. Name the target or be refused - there is no safe default."""
    # dom0/ and tools/ too. They were NOT scanned, which is how dom0's resize service kept
    # win-idd-test baked in long after that qube stopped existing: it answered every request with
    # GEOM ok=0 err=no_window, and the capability looked absent rather than misconfigured.
    scanned = list(HARNESS)
    for sub in ("dom0", "tools"):
        d = ROOT / sub
        if d.is_dir():
            # .py TOO. This scanned only .sh and qtest, and tools/replay-dom0-update.py read
            # `VM = sys.argv[1] if len(sys.argv) > 1 else "win11-fresh"` - so running it with no
            # argument fired a real qrexec call at a guest nobody named (observed 2026-10-14).
            # The comment above already records this exact gap biting once; the fix then reached
            # shell only.
            scanned += sorted(p for p in d.iterdir()
                              if p.is_file() and (p.suffix in (".sh", ".py") or p.name == "qtest"))
    for f in scanned:
        for n, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
            s = line.lstrip()
            if s.startswith("#"):
                continue
            m = DEFAULT_TARGET_RE.search(line)
            if m:
                hit = next((g for g in m.groups() if g), "?")
                finding("L10-default-target-guest", f"{f.name}:{n}",
                        f"defaults a target to '{hit}' - name it explicitly or refuse")


# --------------------------------------------------------------------------- L11
# Commands MEASURED ABSENT on the guests this repo drives. Each entry carries the measurement
# that retired it and what replaces it. This list grows only from a measurement, never from a
# recollection.
ABSENT_ON_GUEST = {
    "wmic": ("removed from Windows 11 24H2+; on this rig's German 25H2 image it answers "
             "'konnte nicht gefunden werden' (measured 2026-09-21) - use "
             "Get-CimInstance Win32_OperatingSystem"),
}
_ABSENT_RE = re.compile(r"(?<![\w.-])(" + "|".join(ABSENT_ON_GUEST) + r")(?![\w.-])")


def l11_absent_guest_command() -> None:
    """A probe built on a command the target OS does not have is not a weak check - it is a check
    that CANNOT PASS, and every verdict resting on it is decoration.

    Measured 2026-09-21: a boot-time classifier was committed as THE fix for a whole class of
    wrong shutdown verdicts, in two places (mgmt/harness/shutdown-lib.sh and
    tools/guest-state-judge.py), reading boot time with `wmic`. wmic is gone from Windows 11
    24H2+ and the reporter's image is German 25H2, so both would have returned empty on every
    modern guest and fallen into UNKNOWN forever. It was never driven against a guest before the
    commit; it was found an hour later, by accident, in unrelated output.

    CLAUDE.md: "A check counts as evidence only once it has been seen to FAIL." This lint cannot
    prove a probe was driven - it can refuse the one class where the answer is knowable from the
    source alone: the command does not exist where it is sent."""
    for f in HARNESS + GUEST_PS + PY_TOOLS:
        for n, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
            s = line.lstrip()
            if s.startswith("#") or s.startswith("//"):
                continue
            m = _ABSENT_RE.search(line)
            if m:
                finding("L11-absent-guest-command", f"{f.name}:{n}",
                        f"'{m.group(1)}' {ABSENT_ON_GUEST[m.group(1)]}")


def l9_no_shutdown_wait() -> None:
    """`qvm-shutdown --wait` is a KILL ON A TIMER, not a wait. From qubesadmin 4.3.33:

        parser.add_argument('--timeout', ..., default=60,
            help='timeout after which domains are killed when using --wait')

    So the bare form hard-kills a Windows guest 60 s in, and `timeout 300 qvm-shutdown --wait`
    does NOT buy 300 s - the kill lands at 60, inside the wrapper, silently, with rc=0.

    Measured 2026-09-20 across ten call sites: every poll loop written UNDER one of these was
    dead code (the guest was already dead when the loop started), stability-e2e.sh's comment
    promised "8 min covers a guest applying updates", matrix.sh's guard killed while its own
    comment said "ACPI only - a killed guest leaves a dirty volume", and seal-qwt-golden.sh
    sealed a GOLDEN from a killed guest, which every clone then inherits.

    Use mgmt/harness/shutdown-lib.sh's qwt_shutdown, which asks and then polls and never kills.
    A mention in a comment is not a call (see L2)."""
    for f in HARNESS:
        for i, ln in enumerate(f.read_text(errors="replace").splitlines(), 1):
            if not ln.lstrip() or ln.lstrip().startswith("#"):
                continue
            if re.search(r"qvm-shutdown\b[^|;&]*--wait", ln):
                finding("L9-shutdown-wait-kills", f"{f.name}:{i}",
                        "`qvm-shutdown --wait` KILLS after --timeout (default 60s); "
                        "use qwt_shutdown from mgmt/harness/shutdown-lib.sh")


def l31_qemu_args_one_writer() -> None:
    """L31: `qemu-extra-args` is written in ONE place, and that place refuses a live domain.

    The value is read at DOMAIN CREATION and nowhere else. Writing it while a domain is up changes
    nothing the running guest can see, while making every later reader believe the device set it
    describes is in force.

    MEASURED, campaign 40134888669: matrix.sh rewrote these args at 22:12:18 to drop the priming
    sticks ("the log volume's device KEPT") against a RUNNING win10-acc. Eight seconds later the log
    volume bind refused with `no_volume_labelled_DIAG_with_LOGVOL.TAG`, and the guest - asked
    directly - reported the 256 MB image as `XENSRC PVDISK bus=SCSI ... parts=0` with no USB disk
    device at all. The campaign aborted on its first cell, 11 minutes in, having spent 10 of them
    installing. Owner 2026-10-25: "no rewriting arguments on the fly."

    So: route every write through `logvol_qemu_write` (mgmt/harness/logvol-lib.sh), which refuses
    unless the domain is Halted or absent, and carries LOGVOL_QEMU_WRITE_LIVE=1 as the single
    deliberate, logged exemption. A mention in a comment or an echoed instruction is not a call."""
    # BOTH ARGUMENT ORDERS. The first regex required the `--`/`--unset` to come AFTER the feature
    # name, so `qvm-features --unset <vm> qemu-extra-args` - the blanket wipe, which deletes the
    # controller the evidence volume rides on - sailed past it in three teardown paths. Jev, asked
    # where a guest could still get the wrong device set, answered
    # a-blanket-unset-deleting-the-log-volume-device at 0.94. A read (`qvm-features <vm>
    # qemu-extra-args` with no value) is NOT a write and must stay silent.
    rx = re.compile(r"qvm-features\b(?=[^|;&]*\bqemu-extra-args\b)[^|;&]*(--unset\b|--\s)")
    # SCOPE: HARNESS (mgmt/harness/*.sh + tools/*.sh) PLUS mgmt/*.sh. The first cut covered only
    # HARNESS and said so - "mgmt/prime-selftest.sh and mgmt/reprovision-usb.sh still write these
    # args directly ... routing them through the one writer is owed work". Jev was then asked where
    # a guest could still be booted with the wrong device set and answered
    # `a-caller-writing-qemu-extra-args-directly` at 0.99, which is that gap by name. Those two are
    # now routed through logvol_devices_apply and the scope includes them, so the rule covers every
    # live writer rather than documenting a hole. The directory is explicit, not HARNESS widened:
    # mgmt/*.sh holds provisioning scripts the other 30 rules were never written against.
    scope = list(HARNESS) + [p for p in sorted((ROOT / "mgmt").glob("*.sh"))]
    for f in scope:
        if f.name == "logvol-lib.sh":
            continue                      # the one writer; its own qvm-features call is the write
        for i, ln in enumerate(f.read_text(errors="replace").splitlines(), 1):
            st = ln.lstrip()
            if not st or st.startswith("#"):
                continue
            if "echo" in st or "printf" in st or "say " in st:
                continue                  # an instruction PRINTED for an operator is not a write
            if rx.search(ln):
                finding("L31-qemu-args-not-one-writer", f"{f.name}:{i}",
                        "writes qemu-extra-args directly; use logvol_qemu_write (logvol-lib.sh), "
                        "which refuses on a live domain - the value only means anything at domain "
                        "creation (campaign 40134888669 aborted on a rewrite against a live guest)")


def l12_provisioning_recipe() -> None:
    """L12: the provisioning recipe is mgmt/harness/provision-recipe.sh, and these are the shapes
    that broke it.

    (a) a block assignment without --required. Measured 2026-09-22, interleaved 3x3 on one subject:
        --required + the stick's qemu-extra-args rc=0 3/3; the SAME assignment PLAIN rc=1 3/3 with
        "libxenlight failed to create new domain". A plain assignment is attached AFTER the domain
        is created, so it can never be in the stubdomain's initial config and qemu cannot open the
        path qemu-extra-args names.
    (b) a default that selects the plain mode (PRIME_ASSIGN_MODE:-plain and friends). One such edit,
        made as a "workaround" on 2026-09-21, cost a day and a half and produced a void findings
        entry declaring the rig dead.
    (c) a LIVE `qvm-device block attach` carrying devtype=cdrom. qubesd refuses it with "Got empty
        response from qubesd" through both the CLI and the raw API, before AND after a host reboot.
        The disc goes in at START: qvm-start --cdrom=<holder>:<loop>.

    The recipe file itself is exempt: it owns the constants."""
    for f in HARNESS:
        if f.name == "provision-recipe.sh":
            continue
        for i, ln in enumerate(f.read_text(errors="replace").splitlines(), 1):
            if not ln.lstrip() or ln.lstrip().startswith("#"):
                continue
            if re.search(r"qvm-device\s+block\s+assign", ln) and "--required" not in ln \
               and not re.search(r'\$\{?_?req', ln) and "provision_assign_stick" not in ln:
                finding("L12-provisioning-recipe", f"{f.name}:{i}",
                        "block assign without --required: the device is then attached AFTER domain "
                        "creation and never reaches the stubdomain (rc=1 3/3, 2026-09-22). Use "
                        "provision_assign_stick from mgmt/harness/provision-recipe.sh")
            if re.search(r"ASSIGN_MODE[^\n]*:-\s*plain", ln):
                finding("L12-provisioning-recipe", f"{f.name}:{i}",
                        "a default selecting the PLAIN assignment mode - that exact edit broke "
                        "provisioning on 2026-09-21; the recipe is --required")
            if re.search(r"qvm-device\s+block\s+attach", ln) and "devtype=cdrom" in ln:
                finding("L12-provisioning-recipe", f"{f.name}:{i}",
                        "a LIVE cdrom attach is refused by qubesd (empty response, measured either "
                        "side of a host reboot); boot the disc instead - provision_boot_with_disc")


# Topics the owner has RETIRED. Each was closed by measurement, written down, and then re-opened
# anyway from code reading - twice for set-gui-mode, and the retired list in CLAUDE.md was added
# after xenbus and the Win10 parked updates suffered the same. Prose did not stop it: the list is
# already written as a binding instruction and was still walked past, which is why this is code.
# Jev, asked what would prevent a THIRD recurrence, put an automated check at 0.55 and the binding
# list alone at 0.14.
#
# A mention is fine. RE-ASSERTING one as open/unexplained/a defect is not. A line that is doing
# the retiring (or the retracting) says so, and is allowed.
# topic -> (what names it, what the RETIRED CLAIM about it looks like). Both must match, so the
# topic can still be discussed: set-gui-mode being fire-and-forget with no back-channel is a live,
# true fact about it; "it returns a stale error code" is the claim that was measured and closed.
RETIRED_TOPICS = {
    "set-gui-mode return code": (
        r"set[- ]?gui[- ]?mode",
        r"GetLastError|stale|garbage|exit\s+(code|status)|returns?\s+\S*\s*(error|nonzero|non-zero)",
    ),
    "exit status 46": (r"exit status 46|status\s+46\b", r".",),
    "xenbus": (r"\bxenbus\b", r".",),
    "win10 22h2 parked updates": (r"KB5071959|parked updates", r".",),
}
REOPEN_WORDS = r"\b(open|unexplained|unknown|defect|bug|broken|regression|root cause|needs? (a )?fix|report(ing)? upstream)\b"
# Word boundaries matter: without them "explained" matched inside "UNexplained", which excused
# the exact sentence this check exists to catch. Found by driving the check with that sentence.
RETIRE_MARKERS = r"\bRETIRED\b|\bCLOSED\b|DO NOT RE-?OPEN|\bretract\w*\b|\bPARKED\b|do not chase|\bexplained\b"

def l14_retired_topics_not_reopened() -> None:
    """A retired line must not come back as an open defect.

    Scope: findings/*.md CURRENT STATE bullets, plus the commit message when one is being made.
    The check fires only when a retired topic and re-opening language share a line AND the line
    carries no retirement/retraction marker.
    """
    targets: list[tuple[str, str]] = []
    fdir = ROOT / "findings"
    if fdir.is_dir():
        for p in sorted(fdir.glob("*.md")):
            for line in p.read_text(errors="replace").splitlines():
                st = line.strip()
                if st.startswith(("- ", "* ")):
                    targets.append((p.name, st))
    # A commit message is wrapped at arbitrary columns, so matching it LINE BY LINE splits the
    # topic from the word that re-opens it - which is exactly how the sentence this check was
    # built from slipped through on the first two attempts. Judge it as one blob.
    msg = os.environ.get("LINT_COMMIT_MSG_FILE", "")
    if msg and Path(msg).exists():
        blob = " ".join(Path(msg).read_text(errors="replace").split())
        if blob:
            targets.append(("commit message", blob))

    for where, line in targets:
        if re.search(RETIRE_MARKERS, line, re.I):
            continue
        if not re.search(REOPEN_WORDS, line, re.I):
            continue
        for topic, (pat, claim) in RETIRED_TOPICS.items():
            if re.search(pat, line, re.I) and re.search(claim, line, re.I):
                finding("L14-retired-topic-reopened", f"{where}: {line[:70]}",
                        f"names the RETIRED topic '{topic}' as open/defective. It was closed by "
                        f"measurement - read CLAUDE.md RETIRED AND PARKED LINES and run "
                        f"`git log --oneline -S<name> -- .` before asserting this again")
                break


# --------------------------------------------------------------------------- L15
# Windows PowerShell 5.1's built-in aliases (Get-Alias on a stock 5.1). Command resolution is Alias > Function > Cmdlet, so a
# function with one of these names is never called by its name.
PS51_ALIASES = set("""% ? ac asnp cat cd chdir clc clear clhy cli clp cls clv cnsn compare copy cp cpi cpp curl cvpa dbp del diff
dir dnsn ebp echo epal epcsv epsn erase etsn exsn fc fhx fl foreach ft fw gal gbp gc gcb gci gcm gcs gdr ghy gi gjb gl gm gmo gp
gps gpv group gsn gsnp gsv gu gv gwmi h history icm iex ihy ii ipal ipcsv ipmo ipsn irm ise iwmi iwr kill lp ls man md measure mi
mount move mp mv nal ndr ni nmo npssc nsn nv ogv oh popd ps pushd pwd r rbp rcjb rcsn rd rdr ren ri rjb rm rmdir rmo rni rnp rp
rsn rsnp rujb rv rvpa rwmi sajb sal saps sasv sbp sc scb select set shcm si sl sleep sls sort sp spjb spps spsv start sujb sv swmi
tee trcm type wget where wjb write""".split())

def l15_ps_function_named_like_alias() -> None:
    """No PowerShell function may be named like a Windows PowerShell 5.1 built-in alias.

    Incident 2026-10-02: an in-session probe defined `function Diff` and called `Diff $snap`; on 5.1 `diff` is an alias of
    Compare-Object, aliases win over functions, and Compare-Object PROMPTED for its missing -DifferenceObject - the probe hung
    for good with no CPU, three runs lost. The same sweep found `function H` (h = Get-History) in swap-qrexec-wrapper.ps1, whose
    hash fields were therefore errors, and `function R` (r = Invoke-History) in install-office-eval.ps1, whose RESULT lines never
    printed. pwsh 7 on Linux has no `diff` alias, so a local test cannot see it - hence a lint.
    """
    files = sorted((ROOT / "guest").glob("*.ps1")) + sorted((ROOT / "tools").glob("*.ps1")) + \
            sorted((ROOT / "mgmt").rglob("*.ps1"))
    for p in files:
        if "tests" in p.parts:
            continue
        for i, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
            m = re.match(r"\s*function\s+([A-Za-z0-9_-]+)", line, re.I)
            if m and m.group(1).lower() in PS51_ALIASES:
                finding("L15-ps-function-is-an-alias", f"{p.relative_to(ROOT)}:{i}",
                        f"function '{m.group(1)}' is shadowed by the PowerShell 5.1 alias '{m.group(1).lower()}' "
                        f"(aliases win over functions) - rename it")


def l16_ps_script_scope_case_collision() -> None:
    """A PowerShell variable may not be written under a name that differs only in CASE from a $script: variable of the same file.

    PowerShell names are case-insensitive, so at script scope `$st = ...` IS `$script:St`. Incident 2026-10-02: the updater's
    error-site logging (e6037f5d, 2026-09-21) wrote `$st = "$($_.ScriptStackTrace)"` inside the main catch, turned the status
    object into a string, and silenced the 0x8024402C remedy committed one hour earlier - in every release for eleven days. The
    differing case is the tell that the author meant a DIFFERENT variable; same-case reuse is the ordinary script-level idiom and is
    left alone. Generated copies under mgmt/prime-jobs are skipped (they are refreshed from guest/, not edited).
    """
    files = [p for d in ("guest", "packaging", "tools", "mgmt") for p in sorted((ROOT / d).rglob("*.ps1"))
             if "tests" not in p.parts and "prime-jobs" not in p.parts]
    for p in files:
        txt = p.read_text(errors="replace")
        scoped = {}
        for m in re.finditer(r"\$script:([A-Za-z_][A-Za-z0-9_]*)", txt, re.I):
            scoped.setdefault(m.group(1).lower(), set()).add(m.group(1))
        if not scoped:
            continue
        for i, line in enumerate(txt.splitlines(), 1):
            code = line.split("#", 1)[0]
            pats = (r"(?<![:\w$])\$([A-Za-z_][A-Za-z0-9_]*)\s*[+\-]?=(?!=)", r"foreach\s*\(\s*\$([A-Za-z_][A-Za-z0-9_]*)\s+in")
            for pat in pats:
                for m in re.finditer(pat, code, re.I):
                    name = m.group(1)
                    spellings = scoped.get(name.lower())
                    if spellings and name not in spellings:
                        finding("L16-ps-script-scope-case-collision", f"{p.relative_to(ROOT)}:{i}",
                                f"'${name}' is the same variable as '$script:{sorted(spellings)[0]}' (names are case-insensitive) - "
                                f"rename the local or write $script:{sorted(spellings)[0]} on purpose")


# --------------------------------------------------------------------------- L17
# "By name" = Get-Process (or its aliases gps/ps) called without -Id/-InputObject: what comes back is ANY process with that name.
_PS_GETPROC = re.compile(r"(?<![\w$\-.])(Get-Process|gps|ps)(?![\w-])([^|;)}\n]*)", re.I)
_PS_START = re.compile(r"\bStart-(?!Sleep\b|Transcript\b)[A-Za-z]+\b|Process\]::Start\(", re.I)


def _ps_code_lines(txt: str) -> list[str]:
    """The code of each line: block comments blanked, a line comment cut at its first ' #'. Approximate (a '#' inside a
    string also cuts), but it only ever REMOVES text, so it can hide a shape, never invent one."""
    out: list[str] = []
    inblock = False
    for line in txt.splitlines():
        code = line
        if inblock:
            if "#>" in code:
                code = code.split("#>", 1)[1]
                inblock = False
            else:
                out.append("")
                continue
        while "<#" in code:
            pre, rest = code.split("<#", 1)
            if "#>" in rest:
                code = pre + rest.split("#>", 1)[1]
            else:
                code = pre
                inblock = True
                break
        if code.lstrip().startswith("#"):
            code = ""
        else:
            code = re.split(r"\s#", code, maxsplit=1)[0]
        out.append(code)
    return out


def _ps_byname_getproc(code: str) -> bool:
    for m in _PS_GETPROC.finditer(code):
        if not re.search(r"-(Id|InputObject)\b", m.group(2), re.I):
            return True
    return False


def _ps_shipped_scripts() -> list[Path]:
    """Every PowerShell script that SHIPS, as packaging/make-setup.ps1 stages it: each single
    `Copy-Item (Need (Join-Path $RepoRoot 'guest\\X.ps1') ...)`; every foreach list of quoted names (resolved against guest/
    and packaging/setup/); the whole of packaging/setup/*.ps1 (copied by name from $setupSrc); the core-agent rpc-services
    dir, copied wholesale; plus the overlay installer packaging/payload/install-qwt-improved.ps1 (built by make-package.ps1).
    Without a make-setup.ps1 (a selftest fixture) every guest/*.ps1 counts, and whatever exists under packaging/setup,
    packaging/payload and the rpc-services dir - a superset, never a skip. A rpc-services dir that is not checked out (the
    core-agent submodule, in a worktree) is SAID on stderr rather than skipped silently; the main checkout lints it."""
    found: dict[str, Path] = {}

    def add(p: Path) -> None:
        if p.is_file() and p.suffix.lower() == ".ps1":
            found[str(p.resolve())] = p

    setup_dir = ROOT / "packaging" / "setup"
    rpc = ROOT / "core-agent" / "src" / "qubes-rpc-services"
    ms = ROOT / "packaging" / "make-setup.ps1"
    if ms.exists():
        txt = ms.read_text(errors="replace")
        for m in re.finditer(r"Join-Path\s+\$RepoRoot\s+'([^']+\.ps1)'", txt, re.I):
            add(ROOT / m.group(1).replace("\\", "/"))
        for m in re.finditer(r"foreach\s*\(\s*\$\w+\s+in\s+([^()]*?)\)\s*\{", txt, re.S):
            for n in re.findall(r"'([^']+\.ps1)'", m.group(1)):
                add(ROOT / "guest" / n)
                add(setup_dir / n)
    else:
        for p in GUEST_PS:
            add(p)
    for p in sorted(setup_dir.glob("*.ps1")):
        add(p)
    for p in sorted((ROOT / "packaging" / "payload").glob("*.ps1")):
        add(p)
    if rpc.is_dir():
        for p in sorted(rpc.glob("*.ps1")):
            add(p)
    elif ms.exists():
        print(f"L17: {rpc.relative_to(ROOT)} is not checked out (the core-agent submodule) - its scripts were NOT linted "
              "in this checkout", file=sys.stderr)
    return sorted(found.values())


OUR_SCRIPT_ROOTS = ("agent", "packaging", "guest", "mgmt", "tools")
OUR_SCRIPT_SUFFIXES = {".ps1", ".sh", ".py", ".cmd", ".bat"}
# Files that CARRY the refused shapes as data: this linter, and the review instrument that found and ranked the sites
# (scratchpad/lifecycle-review; its script names the shapes it searches for).
PATTERN_CARRIERS = {"lint-harness.py", "lifecycle-review.py"}


_OUR_SCRIPTS_CACHE: dict[str, list[Path]] = {}


def _all_our_scripts() -> list[Path]:
    """EVERY script of ours. Widened 2026-10-07 from the shipped set (owner: "why did you miss kill-by-name during the
    previous sweep?" - the 2026-10-03 sweep covered SHIPPED scripts only, so every harness and dev script kept its
    by-name kills). PowerShell, shell, python and cmd under agent/, packaging/, guest/, mgmt/ and tools/ - the bash
    harnesses EMBED the PowerShell they send and the `taskkill /im` they run, so they are read as text like any
    .ps1 - plus the shipped set as make-setup.ps1 stages it (the core-agent rpc dir, the overlay payload).
    Out: tools/tests/ (deliberate fixtures), mgmt/prime-jobs/ (generated copies of guest/), scratchpad/, and the
    pattern carriers. Scanned once per tree (three lints walk it; the rpc-dir notice is said once)."""
    key = str(ROOT)
    if key in _OUR_SCRIPTS_CACHE:
        return _OUR_SCRIPTS_CACHE[key]
    found: dict[str, Path] = {}
    for root in OUR_SCRIPT_ROOTS:
        d = ROOT / root
        if not d.is_dir():
            continue
        for p in sorted(d.rglob("*")):
            if not p.is_file() or p.suffix.lower() not in OUR_SCRIPT_SUFFIXES:
                continue
            if "tests" in p.parts or "prime-jobs" in p.parts or "scratchpad" in p.parts or ".git" in p.parts:
                continue
            if p.name in PATTERN_CARRIERS:
                continue
            found[str(p.resolve())] = p
    for p in _ps_shipped_scripts():
        found[str(p.resolve())] = p
    _OUR_SCRIPTS_CACHE[key] = sorted(found.values())
    return _OUR_SCRIPTS_CACHE[key]


def l17_process_by_name() -> None:
    """L17: no script of ours may KILL or ADOPT a process it found by NAME.

    Owner, 2026-10-03 ("NAMED!!!????"), docs/ADR-updater.md 12.4. Measured that day: the boot-time scan adopted a relay another
    process had started (Ensure-Proxy started one only if no process NAMED qubes-updates-relay existed, else served through whatever
    listened) and its Remove-Proxy TerminateProcess'ed every process with that name, mid-transfer, no log line, no crash record. A
    process found by name is ANY process with that name: killing it is a decision about something we did not start, adopting it
    hands our traffic to it. The 2026-10-02 process audit listed these sites and left them in place - hence a lint, not a note.

    POSIX SHAPES - added 2026-10-10, owner: "PKILL IS HARD PROHIBITED FOREVER". The rule had only ever
    covered the Windows spellings, so `pkill -f <pattern>` and `kill $(pgrep -f <pattern>)` were legal
    in every harness - and a pattern matches THE PROCESS DOING THE MATCHING: my own tool shell carries
    the whole script text I am searching for, so a `pgrep`-fed kill loop killed my own shell twice in
    one hour, and an unanchored busy-check reported the rig busy because it found itself. There is no
    safe pattern: a pid is either one a process wrote down (its own pidfile, $! without setsid, a
    recorded lock) or it is a guess. `pgrep`/`pidof` for COUNTING or REPORTING stay legal; feeding one
    to kill does not. A pid that must be killed is verified first (/proc/<pid>/comm).

    SHAPES (each has a fixture in tools/tests/lint-selftest.sh):
      kill   Stop-Process -Name / with a positional name; `Get-Process <name> | ... Stop-Process` or `| % { $_.Kill() }` on one
             line; taskkill /im; a Win32_Process selected by Name and Terminate'd; a variable bound to a by-name Get-Process (or an
             alias of one) and later .Kill()ed / Stop-Process'ed / taskkill'ed - rebinding it from anything else clears it
      adopt  an if/elseif/while whose condition holds a by-name Get-Process (or such a variable) and whose block starts something
             (Start-*, except Start-Sleep; Process::Start) - "start our own only if none is named so" IS adoption; a by-name
             Get-Process retained as $script:/$global: state
    Counting (@(...).Count) and waiting on (WaitForExit) a process found by name are neither kill nor adopt and stay silent - the
    updater's TiWorker settle does exactly that.

    SCOPE: EVERY script of ours (_all_our_scripts: agent/, packaging/, guest/, mgmt/, tools/ - PowerShell, shell, python,
    cmd - plus the shipped set as make-setup.ps1 stages it). First landed 2026-10-03 on the updater payload alone (Jev,
    updater-payload 1.00 over all-shipped, because the other sites needed their own redesign); widened the same day to
    every SHIPPED script once those were fixed - setup installer (xenbus_monitor by the SCM's pid; the GUI quiesce stops
    the watchdog SERVICE, whose stop now takes its own agent down, and reports survivors), activate-idd.ps1 (same),
    pvnic-selfprime.ps1 (QwtngNetSetup and xenbus_monitor by the SCM's pid), quiet-desktop.ps1 (the user's OneDrive is
    left alone), the overlay installer (service stop + the agent's own QGA_SHUTDOWN request, survivors reported).
    Widened again 2026-10-07 to ALL our code (owner: "why did you miss kill-by-name during the previous sweep?") - the
    harnesses and dev scripts had kept every by-name kill: the agent killed under its armed watchdog (now
    guest/restart-gui-agent.ps1 through mgmt/harness/lifecycle-lib.sh), control windows by `taskkill /im` (now
    ctl_start/ctl_stop by recorded identity), relays by name (now guest/relay-own.ps1 by handle). The native watchdog
    is outside this lint: its one enumeration site (watchdog.c IsProcessRunning) is detection-only by design since
    2026-10-03 (a same-named agent it did not start is reported and waited out, never adopted or stopped), and
    scratchpad/proc-audit2/audit.py lists every native TerminateProcess/enumeration site for review. The baseline file
    is not the place for L17 findings (it must never grow).
    """
    kill_direct = re.compile(r"\bStop-Process\b([^|;)}\n]*)", re.I)
    taskkill_im = re.compile(r"\btaskkill(\.exe)?\b[^\n]*?/im\b", re.I)
    wmi_kill = re.compile(r"Win32_Process[^\n]*\bName\b[^\n]*\b(Terminate|Invoke-CimMethod)\b|\b(Terminate|Invoke-CimMethod)\b[^\n]*Win32_Process[^\n]*\bName\b", re.I)
    cond_block = re.compile(r"\s*(?:\}\s*)?(?:if|elseif|while)\s*\((.*)\)\s*\{(.*)$", re.I)
    # POSIX: pkill/killall at all, and any kill fed from a pattern match
    posix_pkill = re.compile(r"(?<![\w-])(pkill|killall)\b")
    posix_kill_pgrep = re.compile(r"\bkill\b[^\n]*\$\(\s*(pgrep|pidof)\b"
                                  r"|\bfor\s+\w+\s+in\s+\$\(\s*(pgrep|pidof)\b[^\n]*"
                                  # THE /proc SPELLING, added 2026-10-15 after it killed my own
                                  # tool shells. The rule knew `pkill -f` and `kill $(pgrep -f ...)`
                                  # but not a scan of /proc/<glob>/cmdline whose matches feed kill -
                                  # which is the same defect, and the same mechanism: a tool shell's
                                  # cmdline contains the whole command being run, pattern included,
                                  # so the matcher matches itself. tools/hooks/kill-by-pattern-gate.sh
                                  # catches it in a command I TYPE; this catches it in a script.
                                  r"|/proc/[\[\*][^\n]*\bkill\b"
                                  r"|\bkill\b[^\n]*/proc/[\[\*]"
                                  r"|\bps\s+(?:-[A-Za-z]+|a?u?x)\b[^\n]*\|[^\n]*\bkill\b")
    for p in _all_our_scripts():
        text = p.read_text(errors="replace")
        rel = p.relative_to(ROOT)
        if p.suffix in (".sh", ".bash", "") or text.startswith("#!"):
            for i, raw in enumerate(text.splitlines(), 1):
                code = raw.split("#", 1)[0] if not raw.lstrip().startswith("#") else ""
                if not code.strip():
                    continue
                # ADVICE about pkill, inside a string, is not a kill: vmlock.sh and
                # serial-rig-gate.sh both carry the warning "never pkill -f", and flagging those
                # would teach people to delete the warning. A real call has the token OUTSIDE any
                # quotes, so quoted spans are removed before the search rather than guessing at
                # which line shapes are messages.
                bare = re.sub(r"'[^']*'|\"[^\"]*\"", "", code)
                if posix_pkill.search(bare):
                    finding("L17-process-by-name", f"{rel}:{i}",
                            f"pkill/killall kills by PATTERN - prohibited outright (owner 2026-10-10). "
                            f"Kill a pid the process wrote down, verified via /proc/<pid>/comm: {code.strip()[:90]}")
                m = posix_kill_pgrep.search(bare)
                if m:
                    finding("L17-process-by-name", f"{rel}:{i}",
                            f"kill fed from a pattern match - a pattern matches the matcher's own shell: "
                            f"{code.strip()[:90]}")
        lines = _ps_code_lines(text)
        tainted: set[str] = set()
        for i, code in enumerate(lines, 1):
            if not code.strip():
                continue
            byname = _ps_byname_getproc(code)
            for m in kill_direct.finditer(code):
                args = m.group(1)
                if re.search(r"-Name\b", args, re.I) or re.match(r"\s+(?![-$])[\w*'\"]", args):
                    finding("L17-process-by-name", f"{rel}:{i}", f"Stop-Process by name: {code.strip()[:100]}")
            if byname and re.search(r"\|[^\n]*(Stop-Process|\.Kill\(|taskkill)", code, re.I):
                finding("L17-process-by-name", f"{rel}:{i}", f"a process found by name is killed in the same pipeline: {code.strip()[:100]}")
            if taskkill_im.search(code):
                finding("L17-process-by-name", f"{rel}:{i}", f"taskkill /im kills by image name: {code.strip()[:100]}")
            if wmi_kill.search(code):
                finding("L17-process-by-name", f"{rel}:{i}", f"a Win32_Process selected by Name is terminated: {code.strip()[:100]}")
            for v in sorted(tainted):
                ve = re.escape(v)
                if re.search(rf"\${ve}\b[^\n]*(\.Kill\(|\|[^|\n]*Stop-Process|taskkill)|\bStop-Process\b[^\n]*\${ve}\b|\btaskkill\b[^\n]*\${ve}\b", code, re.I):
                    finding("L17-process-by-name", f"{rel}:{i}",
                            f"'${v}' holds a process found by name (Get-Process without -Id) and is killed here: {code.strip()[:100]}")
            m = cond_block.match(code)
            if m:
                cond, rest = m.group(1), m.group(2)
                cond_byname = _ps_byname_getproc(cond) or any(re.search(rf"\${re.escape(t)}\b", cond) for t in tainted)
                if cond_byname:
                    body = [rest]
                    depth = 1 + rest.count("{") - rest.count("}")
                    j = i   # 1-based index of the current line; lines[j] is the next one
                    while depth > 0 and j < len(lines) and j < i + 300:
                        body.append(lines[j])
                        depth += lines[j].count("{") - lines[j].count("}")
                        j += 1
                    if _PS_START.search("\n".join(body)):
                        finding("L17-process-by-name", f"{rel}:{i}",
                                f"existence of a process found by name decides whether to START our own (adoption): {code.strip()[:100]}")
            if byname and re.match(r"\s*\$(script|global):\w+\s*=(?!=)", code, re.I):
                finding("L17-process-by-name", f"{rel}:{i}", f"a process found by name is retained as script state (adoption): {code.strip()[:100]}")
            # taint bookkeeping, after the uses on this line: a binding from a by-name lookup (or an alias of one) taints; any other
            # binding of the same name clears it
            m = re.match(r"\s*\$(?:script:|global:)?(\w+)\s*=(?!=)\s*(.*)$", code)
            if m:
                v, rhs = m.group(1), m.group(2)
                if _ps_byname_getproc(rhs) or any(re.match(rf"[@(\s]*\${re.escape(t)}\b", rhs) for t in tainted):
                    tainted.add(v)
                else:
                    tainted.discard(v)
            m = re.search(r"\bforeach\s*\(\s*\$(\w+)\s+in\s+(.*)\)\s*\{", code, re.I)
            if m:
                v, src = m.group(1), m.group(2)
                if _ps_byname_getproc(src) or any(re.search(rf"\${re.escape(t)}\b", src) for t in tainted):
                    tainted.add(v)
                else:
                    tainted.discard(v)


# --------------------------------------------------------------------------- L21
def l21_second_exit_trap_replaces_the_first() -> None:
    """RULE: ONE `trap ... EXIT` PER SCRIPT. Bash keeps a SINGLE EXIT trap, so a second
    installation silently REPLACES the first and whatever the first was cleaning is never cleaned.

    Measured 2026-10-09 in packaging/make-iso.sh: two mktemp -d, each with its own
    `trap ... EXIT`, so $STAGE leaked on every run. Eight 32 MiB trees had accumulated in /tmp -
    a 1 GiB tmpfs on the rig qube - and the ninth run failed that script's OWN space check
    ("need ~98124 KiB, have 89060"), taking an acceptance cell with it. mgmt/harness/p5-run.sh had
    the same shape, with `trap restore EXIT` replacing `trap 'rm -rf "$TMP"' EXIT`.

    A script with several things to clean uses ONE handler that cleans all of them (declare the
    later variables empty up front so the handler can be installed once). Disarming - `trap ''
    ... EXIT` inside a teardown, to stop recursion - is NOT a second handler and is not flagged."""
    pat = re.compile(r"^\s*trap\s+(?P<h>'[^']*'|\"[^\"]*\"|[^\s]+)\s+[^#]*\bEXIT\b")
    # HARNESS is mgmt/harness + tools; the measured defect was in packaging/make-iso.sh, which
    # every acceptance cell runs, so this rule scans that directory too rather than leaving the
    # one script it was found in out of scope.
    for f in HARNESS + sorted((ROOT / "packaging").glob("*.sh")):
        txt = f.read_text(encoding="utf-8", errors="replace")
        armed = []
        for i, ln in enumerate(txt.splitlines(), 1):
            if ln.lstrip().startswith("#"):
                continue
            m = pat.match(ln)
            if not m:
                continue
            handler = m.group("h").strip("'\"")
            if handler.strip() == "":
                continue                      # disarming, not a second handler
            armed.append(i)
        if len(armed) > 1:
            finding("L21-second-exit-trap", f"{f.name}:{armed[1]}",
                    f"a second `trap ... EXIT` (first at line {armed[0]}) - bash keeps one, so the "
                    "first handler never runs and what it cleaned is leaked")


# --------------------------------------------------------------------------- L18
# Processes the rig KNOWS are relaunched by something that is still armed when a script ends them, and what that
# relauncher is. Owner, 2026-10-07: "if you terminate something that relaunches you need to make sure it STOPS
# relaunching beforehand ... thats why we do not kill processes by name". Ending one of these by name races its
# relauncher, and the test then measures whichever instance won: the harnesses restarted the agent with
# `Stop-Service QubesGuiWatchdog; Get-Process gui-agent | Stop-Process -Force; Start-Service` and grew an
# INVALID-INSTRUMENT branch for "the old one survived Stop-Process" instead of fixing the cause. Each entry says who
# relaunches it and what the sanctioned way is.
RELAUNCHED = {
    "gui-agent": ("the QubesGuiWatchdog service (watchdog.c relaunches the agent it owns the instant it exits; since "
                  "2026-10-03 its STOP ends that agent by handle) - restart through the service: guest/restart-gui-agent.ps1 "
                  "via mgmt/harness/lifecycle-lib.sh, and never end the agent by hand"),
    "gui-watchdog": "the SCM's recovery actions for QubesGuiWatchdog (sc failure ... restart) - stop the SERVICE through the SCM",
    "wgcbroker": "gui-agent, which supervises and relaunches its broker",
    "notifhost": "gui-agent, which relaunches the notification bridge",
    "etwproxy": ("gui-agent, which relaunches the ETW proxy on a backoff (etwproxy.c) - a supervision DRILL ends it by the pid "
                 "the agent LOGGED when it launched it ('ETWPROXYSUP launched etwproxy.exe pid='), never by a name scan"),
    "qwtng-netsetup": "the QwtngNetSetup service (SCM recovery) - stop the service, by its SCM-reported pid",
    "xenbus_monitor": "the xenbus_monitor service (SCM recovery) - disable and stop the service, by its SCM-reported pid",
    "qubes-updates-relay": ("the updater pass that started it, and the QubesWindowsUpdateScan/Run task that runs passes - own a "
                            "relay by handle (guest/relay-own.ps1), end the TASK, or wait for the pass; never the relay by name"),
    "explorer": ("Winlogon's AutoRestartShell, which relaunches the shell the instant it exits - end the Shell_TrayWnd owner by "
                 "pid and WAIT for Winlogon's instance (guest/set-visual-performance.ps1), or leave it"),
    "shellexperiencehost": "the shell, which relaunches it on demand - never ended (guest/dismiss-toast.ps1 clears the history instead)",
    "startmenuexperiencehost": "the shell, which relaunches it on demand - never ended",
}
_RELAUNCHED_ALT = "|".join(re.escape(n) for n in RELAUNCHED)
_RELAUNCHED_RE = re.compile(r"(?<![\w-])(" + _RELAUNCHED_ALT + r")(?:\.exe)?(?![\w-])", re.I)
_KILL_RE = re.compile(r"\bStop-Process\b|\.Kill\(|\btaskkill(?:\.exe)?\b|\bTerminateProcess\b|\.Terminate\(\)"
                      r"|\bInvoke-CimMethod\b[^\n]*\bTerminate\b", re.I)
# The name in the kill's TARGET position - not anywhere on the line: a one-line script that starts etwproxy.exe by
# path through Process::Start and ends THAT handle (p3a T4) names the exe without ending anything by name.
_KILL_TARGET_RES = [
    re.compile(r"\bStop-Process\s+(?:-Name\s+)?['\"]?(" + _RELAUNCHED_ALT + r")(?:\.exe)?['\"]?(?![\w-])", re.I),
    re.compile(r"(?<![\w$\-.])(?:Get-Process|gps|ps)\b(?![\w-])[^|\n]*?(?<![\w-])(" + _RELAUNCHED_ALT + r")(?:\.exe)?(?![\w-])[^|\n]*\|[^\n]*(?:Stop-Process|\.Kill\(|taskkill)", re.I),
    re.compile(r"\btaskkill(?:\.exe)?\b[^\n]*/im\s+['\"]?(" + _RELAUNCHED_ALT + r")(?:\.exe)?", re.I),
    re.compile(r"Win32_Process[^\n]*\bName\b[^\n]*?(?<![\w-])(" + _RELAUNCHED_ALT + r")(?:\.exe)?[^\n]*\b(?:Terminate|Invoke-CimMethod)\b", re.I),
]


def _kill_target_name(code: str) -> str:
    for rx in _KILL_TARGET_RES:
        m = rx.search(code)
        if m:
            return m.group(1).lower()
    return ""
_TASKLIST_IMAGE_RE = re.compile(r"\btasklist\b[^\n]*imagename\s+eq\s+([\w.-]+)", re.I)
_TASKKILL_PID_RE = re.compile(r"\btaskkill(?:\.exe)?\b[^\n]*/pid\b", re.I)
_TASK_END_RE = re.compile(r"\bschtasks(?:\.exe)?\b[^\n]*/end\b[^\n]*/tn\s+(\S+)|\bStop-ScheduledTask\b[^\n]*-TaskName\s+(\S+)", re.I)
_TASK_CREATE_RE = re.compile(r"\bschtasks(?:\.exe)?\b[^\n]*/create\b[^\n]*/tn\s+(\S+)|\bRegister-ScheduledTask\b[^\n]*-TaskName\s+(\S+)", re.I)
_FUNC_START_RE = re.compile(r"^\s*function\s+[\w-]+|^\s*[\w-]+\s*\(\)\s*\{", re.I)


def _tasks_with_restart_on_failure() -> set[str]:
    """Task names whose DEFINITION in our scripts restarts them on failure: a <RestartOnFailure> block (task XML) or
    New-ScheduledTaskSettingsSet -RestartCount, attributed to the nearest FOLLOWING registration in the same file
    (schtasks /create /tn NAME, Register-ScheduledTask -TaskName NAME). Today no task of ours carries one; the set
    exists so the day one does, /end on it is refused."""
    tasks: set[str] = set()
    for p in _all_our_scripts():
        pending = False
        for ln in p.read_text(errors="replace").splitlines():
            if re.search(r"<RestartOnFailure>|-RestartCount\b", ln, re.I):
                pending = True
            m = _TASK_CREATE_RE.search(ln)
            if m and pending:
                tasks.add((m.group(1) or m.group(2)).strip("'\""))
                pending = False
    return tasks


def _disarmed_above(lines: list[str], i: int, task: str) -> bool:
    """Is task TASK disabled or deleted somewhere between the start of the enclosing function (or the file) and line i?"""
    t = re.escape(task)
    disarm = re.compile(rf"/change\b[^\n]*/tn\s+['\"]?{t}['\"]?\b[^\n]*/disable|/delete\b[^\n]*/tn\s+['\"]?{t}['\"]?\b"
                        rf"|\bDisable-ScheduledTask\b[^\n]*{t}|\bUnregister-ScheduledTask\b[^\n]*{t}", re.I)
    for j in range(i - 2, -1, -1):           # lines[j] is line j+1; start just above line i
        if _FUNC_START_RE.search(lines[j]):
            return False
        if disarm.search(lines[j]):
            return True
    return False


def l18_relauncher_armed() -> None:
    """L18: a process, service child or task whose RELAUNCHER IS ARMED is never ended by name, and never without the
    relauncher disarmed first (owner 2026-10-07, see RELAUNCHED). Scope: every script of ours (_all_our_scripts).

    SHAPES (each has a fixture in tools/tests/lint-selftest.sh):
      a. gui-agent ended by ANY means on a line that names it (Stop-Process, .Kill(), taskkill, Terminate) - the
         old harness restart `Stop-Service QubesGuiWatchdog; Get-Process gui-agent | Stop-Process` included: the
         service IS the stopper, nothing ends the agent by hand;
      b. any name in RELAUNCHED ended by name: Stop-Process -Name / Get-Process <name> | Stop-Process or .Kill() /
         taskkill /im <name>.exe / a Win32_Process Terminate; a variable bound by a by-name lookup of such a name and
         ended later; a pid SELECTED by a `tasklist /fi "imagename eq <name>"` scan and ended with taskkill /pid
         within the next 12 lines (by name in two steps - the p3a drills' old shape);
      c. a scheduled task ended with schtasks /end or Stop-ScheduledTask while its definition carries RestartOnFailure
         (_tasks_with_restart_on_failure), unless it is disabled or deleted first in the same function (or the file
         above it).
    Not shapes: Stop-Service/Start-Service (the owner's interface); Stop-Process -Id of a pid the script recorded when
    IT started the process (lifecycle-lib.sh ctl_stop, relay-own.ps1 Stop-OwnRelay); a drill's taskkill /pid of the pid
    the SUPERVISOR logged; counting or waiting on a by-name lookup; a comment.
    """
    restart_tasks = _tasks_with_restart_on_failure()
    for p in _all_our_scripts():
        lines = _ps_code_lines(p.read_text(errors="replace"))
        rel = p.relative_to(ROOT)
        named: dict[str, set[str]] = {}               # variable -> RELAUNCHED names its binding looked up by name
        scans: list[tuple[int, str]] = []             # (line, name) of a tasklist-by-imagename of a RELAUNCHED name
        for i, code in enumerate(lines, 1):
            if not code.strip():
                continue
            if _KILL_RE.search(code):
                n = _kill_target_name(code)
                if n:
                    finding("L18-relauncher-armed", f"{rel}:{i}",
                            f"'{n}' is ended by name while its relauncher is armed - it is relaunched by {RELAUNCHED[n]}: "
                            f"{code.strip()[:100]}")
                else:
                    for v, names in named.items():
                        if re.search(rf"\${re.escape(v)}\b", code):
                            n = sorted(names)[0]
                            finding("L18-relauncher-armed", f"{rel}:{i}",
                                    f"'${v}' holds '{n}' found by name and ends it here while its relauncher is armed - it is "
                                    f"relaunched by {RELAUNCHED[n]}: {code.strip()[:100]}")
                            break
                if _TASKKILL_PID_RE.search(code):
                    for ln, n in scans:
                        if 0 < i - ln <= 12:
                            finding("L18-relauncher-armed", f"{rel}:{i}",
                                    f"taskkill /pid of a pid SELECTED by a tasklist imagename scan for '{n}' (line {ln}) - by name in "
                                    f"two steps, while its relauncher is armed - it is relaunched by {RELAUNCHED[n]}: {code.strip()[:100]}")
                            break
            m = _TASKLIST_IMAGE_RE.search(code)
            if m:
                n = re.sub(r"\.exe$", "", m.group(1).lower())
                if n in RELAUNCHED:
                    scans.append((i, n))
            # bindings: a variable bound by a by-name lookup (or an alias of one) carries the names; any other binding clears it
            mb = re.match(r"\s*\$(?:script:|global:)?(\w+)\s*=(?!=)\s*(.*)$", code)
            if mb:
                v, rhs = mb.group(1), mb.group(2)
                names: set[str] = set()
                if _ps_byname_getproc(rhs):
                    names = {h.group(1).lower() for h in _RELAUNCHED_RE.finditer(rhs)}
                else:
                    for t, tn in named.items():
                        if re.match(rf"[@(\s]*\${re.escape(t)}\b", rhs):
                            names |= tn
                if names:
                    named[v] = names
                else:
                    named.pop(v, None)
            mf = re.search(r"\bforeach\s*\(\s*\$(\w+)\s+in\s+(.*)\)\s*\{", code, re.I)
            if mf:
                v, src = mf.group(1), mf.group(2)
                names = set()
                if _ps_byname_getproc(src):
                    names = {h.group(1).lower() for h in _RELAUNCHED_RE.finditer(src)}
                else:
                    for t, tn in named.items():
                        if re.search(rf"\${re.escape(t)}\b", src):
                            names |= tn
                if names:
                    named[v] = names
                else:
                    named.pop(v, None)
            me = _TASK_END_RE.search(code)
            if me:
                tn = (me.group(1) or me.group(2)).strip("'\"")
                if tn in restart_tasks and not _disarmed_above(lines, i, tn):
                    finding("L18-relauncher-armed", f"{rel}:{i}",
                            f"scheduled task '{tn}' is ended while its definition carries RestartOnFailure (Task Scheduler relaunches "
                            f"it) and it was not disabled or deleted first in this function: {code.strip()[:100]}")


def l23_no_pipe_into_grep_q_for_a_guest_probe() -> None:
    """L23: a guest probe must CAPTURE its output and match it, never pipe it into `grep -q`.

    MEASURED 2026-10-14, and it decides whether a guest is alive. `grep -q` exits the instant it
    matches; the producer is usually still writing, so it dies of SIGPIPE; `timeout` reports that
    death as 141; and `set -o pipefail` - which matrix.sh, prime-run.sh, quick-upgrade.sh and
    collect-failure.sh all set, and which a sourced library inherits - makes 141 the status of the
    whole pipeline. A guest that ANSWERED CORRECTLY is then graded dead.

    Rates measured on a healthy producer: 86 of 200 in collect-failure's own probe, 41 of 300 and
    8 of 150 in two shapes of w_alive. It is silent, it is intermittent, and every consumer of
    w_alive rested on it - w_session, w_install, w_halt_stable and the 10-minute TERMINAL verdict.
    A phantom wedge also made the collector fetch a multi-GB memory image of a healthy guest.

    The fix is local: `grep -qa X <<< "$(producer)"`, or capture into a variable and use `case`.
    The substitution completes before grep starts, so there is no pipe to break - 0 of 300 after.

    Only GUEST-CALLING producers are flagged. A pipeline out of a local, fast command is a
    different risk and flagging all of them would bury this rule in noise until it got baselined
    away, which is how a real rule dies.

    THE SECOND HARM, AND WHY pipefail IS NO LONGER A CONDITION. This rule used to fire only where
    pipefail was in effect, on the reasoning that "without it the pipeline returns grep's own status
    and the shape is correct - mgmt/clone-to-template.sh and mgmt/win-install-watch.sh both use it
    under a plain `set -u` and are not defective". The first paragraph above refutes that in its own
    words: the producer dies of SIGPIPE whatever the shell's pipefail setting is. Mis-grading is the
    harm pipefail adds; killing the guest's caller is there without it.
    MEASURED on win11-nfy 2026-10-16: `alive(){ T=30 q run 'cmd /c echo LIVE' | grep -qa LIVE; }`
    (gate-preflight.sh, failproof-gates.sh) killed qrexec-client-vm between the request and the
    guest-side connect-back twice in 163 calls, and the GUEST logged
    `InitVchan: QGAVCHANFAIL ... xenstore node unreadable (0x5 = absent or denied); request dropped`
    - an ERROR line against the owner's clean-error-log gate condition, whose level is settled as
    ERROR (findings/issues.md QGAVCHANFAIL: demotion scored 0.39, gate forgiveness 0.73 as hiding).
    So the caller must stop creating the condition, which is this rule.

    AND WHY IT FOUND NOTHING FOR TWO DAYS. On 2026-10-16 the rule reported 0 findings against 30
    live sites - including quick-upgrade.sh, matrix.sh and gate-remainder.sh. Three holes, each
    fixed in the pattern below: the producer had to be a literal `timeout`/`./tools/qtest`/
    `qrexec-client-vm`, so a local wrapper (`q run`, `gq`, `grun`, `r`, `qrun`) hid it; the grep had
    to be the first word after the pipe, so `| command grep -qa` hid it; and the pipefail gate hid
    the rest. A detector that has never fired on the real population is a receipt for a check
    nobody ran. `cmd /c` is in the producer set because it only ever addresses a Windows guest,
    which is what makes a local wrapper detectable at all."""
    # A guest-calling producer by any spelling in use here, including a wrapper named by its payload.
    _prod = (r"(?:\./tools/qtest\b|\btools/qtest\b|\$\{?QTEST_BIN\}?|\bqrexec-client-vm\b"
             r"|\bqvm-run\b|cmd\s+/c\b)")
    # grep may be reached through `command`, `env`, or a VAR=value prefix.
    _grepq = (r"(?:\|)\s*(?:command\s+|env\s+|LC_ALL=\S+\s+|[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*"
              r"grep\s+-[a-zA-Z]*q")
    probe = re.compile(_prod + r"[^|]*" + _grepq)
    files = sorted((ROOT / "mgmt").glob("*.sh")) + \
            sorted((ROOT / "mgmt" / "harness").glob("*.sh")) + \
            [p for p in sorted((ROOT / "tools").glob("*.sh")) if "tests" not in p.parts]
    bodies = {f: f.read_text(errors="replace") for f in files}
    pipefail = {f for f, t in bodies.items() if re.search(r"set\s+-[a-zA-Z]*o\s+pipefail|set\s+-o\s+pipefail", t)}
    # a file sourced BY a pipefail file inherits it at run time
    inherits = {f for f in files
                if any(re.search(r"(?:^|\s)(?:source|\.)\s+\S*" + re.escape(f.name), bodies[g], re.M)
                       for g in pipefail)}
    for f in files:
        heredoc = None
        buf, bufn = "", None
        for n, ln in enumerate(bodies[f].splitlines(), 1):
            st = ln.lstrip()
            if heredoc is not None:
                if st == heredoc:
                    heredoc = None
                continue
            m = re.search(r"<<-?\s*[\'\"]?(\w+)", ln)
            if m and "<<<" not in ln:
                heredoc = m.group(1)
                continue
            if not st or st.startswith("#"):
                continue
            # A BACKSLASH CONTINUATION HIDES THE PIPE from a per-line scan. That is not
            # hypothetical: prime-run.sh:476 wrote the probe on one line and `| grep -qa QREADY` on
            # the next, and carried this exact defect - in the clean-install path, at the moment the
            # guest first answers - past this gate until 2026-10-14. Join them before matching.
            cur, curn = (buf + " " + st, bufn) if buf else (st, n)
            if cur.rstrip().endswith("\\"):
                buf, bufn = cur.rstrip()[:-1], curn
                continue
            buf, bufn = "", None
            if probe.search(cur):
                # Both harms are real; pipefail decides whether the SECOND one is also present.
                also = (" and pipefail then grades a live guest dead (86/200)"
                        if f in pipefail or f in inherits else "")
                finding("L23-pipe-into-grep-q-probe", f"{f.name}:{curn}",
                        "a guest probe piped into grep -q: grep's early exit SIGPIPEs the qrexec "
                        "client mid-connect, and the guest logs QGAVCHANFAIL request dropped"
                        + also + "; capture it and match instead")


def l27_detached_guest_launch_must_not_use_start() -> None:
    """L27: a guest call that DETACHES a long-running process must not use `cmd /c start`.

    `start` passes every inheritable handle whatever the redirection, so the launched process
    inherits the qrexec data vchan's pipes and holds them for its whole life. The wrapper's output
    pumps then never see EOF and the call cannot finish.

    MEASURED 2026-09-27, commit d3fe180: `cmd /c start ... <nul >nul` did NOT prevent it and the
    call still died at the installer's own service stop on win11de-v3/-v4 (rc=255 after 51-55 s).
    quick-upgrade.sh carries that finding and the remedy - Start-Process goes through ShellExecute,
    which inherits no handles, so the call returns as soon as the launch is done. THE REDIRECTION IS
    NOT THE FIX, which is why this rule does not accept one.

    MEASURED AGAIN 2026-10-17, campaign run 38994277148, cell win11-reinstall, because the finding
    was recorded in one harness and never applied in the others: two matrix.sh launches (the
    reboot-dialog watcher, 2700 s, and install.cmd) each left a wrapper with a live output pump
    until a console control event tore it down 118 s and 63 s in, both reporting at ERROR that
    output "may not have reached the peer" - the only two undeclared error lines that cell carried.
    The same shape produced a 120 s TRUNCATED transfer and a lost exit code on the previous
    campaign. Jev, asked whether to demote that ERROR instead: fix-the-callers 0.79."""
    bad_start = re.compile(r"(?:\bqrun\b|\bgrun\b|\bgq\b|\./tools/qtest\b|\btools/qtest\b|\$\{?QTEST_BIN\}?)"
                           r"[^#]*?cmd\s+/c\s+(?:\\?\")?start\b")
    files = sorted((ROOT / "mgmt").glob("*.sh")) + \
            sorted((ROOT / "mgmt" / "harness").glob("*.sh")) + \
            [p for p in sorted((ROOT / "tools").glob("*.sh")) if "tests" not in p.parts]
    for f in files:
        for n, ln in enumerate(f.read_text(errors="replace").splitlines(), 1):
            st = ln.lstrip()
            if not st or st.startswith("#"):
                continue
            if bad_start.search(st):
                finding("L27-detached-guest-launch-uses-start", f"{f.name}:{n}",
                        "a detached guest launch via `cmd /c start`: start passes every inheritable "
                        "handle whatever the redirection, so the launched process holds this call's "
                        "vchan pipes and the wrapper's pumps never see EOF (measured d3fe180, and "
                        "again 2026-10-17); use Start-Process, which inherits none")


def l22_vm_start_must_assert_sole_guest() -> None:
    """L22: anything that STARTS a guest must first call assert_sole_guest from
    mgmt/harness/serial-rig.sh.

    WHY A LINT AND NOT A HOOK. tools/hooks/serial-rig-gate.sh already refuses a launch while another
    guest is up - but it is a PreToolUse hook, so it can only inspect the TEXT of the command being
    run. On 2026-10-13 a vendor-media install was launched as `nohup bash /tmp/.../win11r.sh`: the
    command text named no harness, the hook saw nothing, and win11r-base was created and booted while
    win10-dptest was still Running from a run that had ended five minutes earlier. Two 8 GiB guests
    at once. The same wrapper defeats tools/hooks/golden-boot-gate.sh identically. A gate that is
    stepped around by moving the command into a file is a reminder, not a gate - so the assertion has
    to live in the script that does the starting, where it holds however the script was invoked.

    SCOPE IS WIDER THAN HARNESS ON PURPOSE. HARNESS globs mgmt/harness/*.sh and tools/*.sh, which
    does NOT include mgmt/*.sh - and mgmt/reprovision-usb.sh, the script that actually booted the
    second guest, lives there. A rule that could not see the file that caused the incident would be
    theatre.

    Exemptions are BY NAME, never by pattern, so a new guest-driving harness cannot inherit one:
    serial-rig.sh owns the function, and the sourced libraries run inside a caller that has already
    asserted."""
    exempt = ("serial-rig.sh", "vmlock.sh", "shutdown-lib.sh", "provision-recipe.sh",
              "e2e-wait.sh", "log-sweep.sh")
    files = sorted((ROOT / "mgmt").glob("*.sh")) + \
            sorted((ROOT / "mgmt" / "harness").glob("*.sh")) + \
            [p for p in sorted((ROOT / "tools").glob("*.sh")) if "tests" not in p.parts]
    for f in files:
        if f.name in exempt:
            continue
        text = f.read_text(errors="replace")
        # A usage message that PRINTS `qvm-start` is advice, not a launch. Three of the first 13
        # findings were exactly that - echo lines in the stick/disc/iso builders telling the reader
        # how to attach the medium. A rule that cannot tell an invocation from prose about an
        # invocation is the same self-matching defect as L17's.
        heredoc = None
        starts = []
        for i, ln in enumerate(text.splitlines(), 1):
            s = ln.lstrip()
            if heredoc is not None:
                if s == heredoc:
                    heredoc = None
                continue
            m = re.search(r"<<-?\s*[\'\"]?(\w+)", ln)
            if m:
                heredoc = m.group(1)
                continue
            if not s or s.startswith("#"):
                continue
            if re.match(r"(echo|printf|say|log)\b", s):
                continue
            # qvm-run auto-starts a halted guest, so it starts one just as surely as qvm-start.
            if re.search(r"\bqvm-start\b", ln) or re.search(r"\bqvm-run\b", ln):
                starts.append(i)
        if not starts:
            continue
        # vm_lock asserts it internally (mgmt/harness/vmlock.sh) - it is the one place every
        # guest-mutating harness already passes through WITH the vm name, so taking the lock
        # is the same guarantee and does not need a second call.
        if "vm_lock" in text:
            continue
        if "assert_sole_guest" in text and "serial-rig.sh" in text:
            continue
        finding("L22-serial-rig-not-asserted", f"{f.name}:{starts[0]}",
                "starts a guest without asserting it is the only one: source "
                "mgmt/harness/serial-rig.sh and call `assert_sole_guest \"$VM\"` before the start. "
                "The PreToolUse hook cannot cover this - it reads the launching command's text, so "
                "wrapping the script in another script walks past it (measured 2026-10-13, two "
                "guests up at once)")


# --------------------------------------------------------------------------- L24
RELEASE_GRADING = {"matrix.sh", "quick-upgrade.sh", "wu-e2e.sh", "e2e-wait.sh", "verdict-lib.sh",
                   "logvol-lib.sh", "run-lib.sh", "shutdown-lib.sh", "lifecycle-lib.sh",
                   "template-update-test.sh", "prime-run.sh"}

def l24_failure_report_must_declare_a_level() -> None:
    """RULE: IN A HARNESS THAT GRADES A RELEASE, A LINE REPORTING A FAILURE MUST DECLARE A SEVERITY.

    tools/sweep-gate.sh can only judge a line whose WRITER declared Error or Warning - that is the
    whole point of it, after two predecessors tried to recognise an error by its wording and missed
    a gui-agent crash loop because no word in the line was on their list. A failure reported without
    a level is therefore invisible to the sweep, and the sweep is what stops a run LOOKING clean
    while its own log carries an unread error. That is not hypothetical: a 96-of-96 campaign shipped
    `WARNING log-volume bind failed` on both upgrade cells and every reader, model included, missed
    it. Measured 2026-10-14: 27% of the failure-reporting sites in these files declared a level.

    Declare it by writing [ERROR] or [WARN] into the message, or a bare WARNING/ERROR/FATAL label.
    Where the severity depends on a count, decide it at the emitter - only the line that knows $FAIL
    can tell "summary: 3 passed, 2 failed" from "summary: 5 passed, 0 failed".

    EXEMPT, deliberately: byte-exact machine contracts (the '=== MATRIX:' and '=== done:' markers
    other tools parse), and prose - a line that explains a condition rather than reporting one.

    ITS COUNT IS NOT A COVERAGE METRIC. Do not quote it as one. The site count has been 97 (a word
    list), then 215 (control flow, too loose), then 76 (tightened) - for the same unchanged tree,
    because every version of this detector has its own false positives and negatives. Known
    false positives right now include e2e-wait.sh:118 and :124, which are a progress line and a
    status line that sit near a `return 1`. The author tightened the regex, watched 215 become 76,
    and presented that as progress while BOTH of those lines were still flagged - i.e. the number
    moved and the defects did not. A detector whose own count swings 3x is a review aid, not a
    measurement, and the honest denominator for "how much of our failure reporting declares a
    severity" is not available from it.

    What it IS good for: pointing at a specific line a human should look at. That is why it is
    pending and never gating."""
    reports = re.compile(r'\b(say|log|_vs_log|_lv_say|echo)\b[^|]*"')
    # A FAILURE SITE IS CONTROL FLOW, NOT VOCABULARY. This rule used to find them with a word list
    # (FAIL|REFUS|ERROR|cannot|UNEXPECTED|...) - the exact technique tools/sweep-gate.sh exists to
    # replace, and it was wrong in both directions: it missed a report whose words happened not to
    # be on the list, and it counted explanatory prose that contains "cannot". It also produced the
    # site COUNT this rule was quoted for, so that number could never be trusted either.
    #
    # What makes a line a failure REPORT is where control goes next: the run ends non-zero, or a
    # verdict helper records a failure. Those are structural and enumerable.
    #   no() / verdict FAIL     - the harnesses' own verdict recorders
    #   Fail / finish <nonzero> - the single-exit helpers
    #   exit <nonzero>, return <nonzero> on the same line or the next few
    # `no` is a COMMAND here, not the English word. Matching \bno\s flagged
    # `DEADLINE ${dl}s with no session` and a dozen like it, which is the same false-positive
    # disease as the word list, just with a shorter list. So: statement position, and an argument.
    failure = re.compile(r"(^|[;&|{]\s*|\bthen\s+|\bdo\s+|\belse\s+)no\s+[\"'$]"
                         r"|(^|[;&|{]\s*)Fail\s+[\"'$]"
                         r"|\bfinish\s+[1-9]|\bverdict\s+(FAIL|INVALID)"
                         r"|\bexit\s+[1-9]|\breturn\s+[1-9]")
    # DECLARED, counting the three ways a line can carry a level without spelling it out:
    #   a literal tag; an interpolated guard (${sev}/${_mx_sev}) set immediately above; and
    #   declaration BY THE CALLEE - `finish <nonzero>` goes through finish(), which prefixes
    #   [ERROR] for any non-zero rc, so the caller must not repeat it.
    declared = re.compile(r"\[(ERROR|WARN|WARNING)\]|\b(WARNING|ERROR|FATAL|CRITICAL)\b:?\s"
                          r"|\$\{_?mx_?sev(:-)?[^}]*\}|\$\{sev(:-)?[^}]*\}"
                          r"|_mx_sev=|_l=|sev=|printf '\[ERROR\]"
                          r"|\bfinish\s+[1-9]")
    # NOT A REPORT AT ALL: a classifier branch that echoes a CLASS, and a pipeline that re-prints
    # lines out of a file some other emitter already levelled. Neither originates a failure line.
    not_a_report = re.compile(r"\)\s*echo\s+(INVALID|FAIL|PASS)\b"
                              r"|grep\s[^|]*\|\s*(sed|tee|head|tail)")
    # a line that EXPLAINS rather than reports, and the two parsed markers
    prose = re.compile(r"=== (MATRIX|done):|this cannot tell them apart|it cannot occur here"
                       r"|harmless:|the open question|its contract requires|not calling this"
                       r"|INJECTED |rows = ")
    for f in HARNESS:
        if f.name not in RELEASE_GRADING:
            continue
        lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
        for n, line in enumerate(lines, 1):
            if line.lstrip().startswith("#") or not reports.search(line):
                continue
            # the exit may be on this line or just after it: `log "..."; exit 1` and
            #   log "..."
            #   exit 1
            # are the same site. Three lines of lookahead, code only.
            # THE EXIT MUST BE IMMEDIATE. A three-line lookahead attributed a `return 1` to the
            # progress lines above it, flagging `t+${now}s qvm=... screen=...` as a failure report.
            # Same line, or the very next line of code, and nothing else in between.
            nxt = next((l for l in lines[n:n + 4]
                        if l.strip() and not l.lstrip().startswith("#")), "")
            window = line + " ;; " + nxt
            if not failure.search(window) or declared.search(line) or prose.search(line):
                continue
            if not_a_report.search(line):
                continue
            pending_finding("L24-failure-report-without-a-level", f"{f.name}:{n}",
                    "reports a failure with no declared severity, so tools/sweep-gate.sh cannot see "
                    "it - write [ERROR] or [WARN] into the message, or mark the line as prose")


# --------------------------------------------------------------------------- L25
# Phrases Windows renders through FormatMessage, i.e. in the SYSTEM locale. Branching on one is a
# locale dependency; the numeric code beside it is not. This is a word list, and a word list is the
# wrong tool for CLASSIFYING an error - but it is the right tool for pointing a reviewer at a line.
OS_MESSAGE_PHRASES = (
    "access is denied", "the pipe has been ended", "cannot find the file",
    "the system cannot find", "is not recognized", "was abandoned", "not enough",
    "permission denied", "no such file", "already exists", "zugriff verweigert",
    "wurde beendet", "nicht finden", "nicht erkannt", "wurde abgebrochen",
)

def l25_product_must_not_branch_on_localised_text() -> None:
    """RULE: PRODUCT CODE MUST NOT DECIDE ANYTHING FROM A LOCALISED OS MESSAGE.

    FormatMessage renders a Win32 code in the SYSTEM locale, so the same failure reads "Die Pipe
    wurde beendet." on a German guest and "The pipe has been ended." on an English one. A branch
    taken on those words works on one guest and silently does nothing on the other - and this rig's
    main subject is a German 25H2 image, so the failing case is the normal case here.

    Found 2026-10-14 in guest/sync-clock-from-dom0.ps1: a terminal 'dom0-refused' decision was
    taken on `$out -match 'denied|refused|no such domain'`, where part of $out is win_perror output.
    The numeric code was available the whole time. The owner's rule: the harness may carry EN+DE
    with caveats, the product may not.

    The code is the locale-independent identity - branch on $rc / the HRESULT, and keep the rendered
    sentence for the log line only. HARNESS and TEST paths are exempt: a fixture that proves we
    handle a German guest has to contain German. Pending, not gating."""
    PRODUCT = ("agent/", "core-agent/", "guest/")
    decides = re.compile(r"-match|-eq|==|\bif\b.*\bgrep\b|Select-String|findstr|\bcase\b")
    for p in sorted(ROOT.rglob("*.ps1")) + sorted(ROOT.rglob("*.c")) + sorted(ROOT.rglob("*.cpp")):
        rel = str(p.relative_to(ROOT)).replace("\\", "/")
        if not rel.startswith(PRODUCT) or "/tests/" in rel or rel.endswith("-test.ps1"):
            continue
        try:
            lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            st = line.strip()
            if st.startswith("#") or st.startswith("//"):
                continue
            low = line.lower()
            if not any(ph in low for ph in OS_MESSAGE_PHRASES) or not decides.search(line):
                continue
            pending_finding("L25-product-branches-on-localised-text", f"{rel}:{n}",
                    "decides something from a localised OS message - FormatMessage renders it in "
                    "the system locale, so this works on one guest and silently does not on "
                    "another; branch on the numeric code and keep the sentence for the log")


def l26_no_hardware_clock_convention_is_written() -> None:
    """RULE: NOTHING WRITES RealTimeIsUniversal, AND NOTHING CLEARS A QUBE'S `timezone` FEATURE.

    Windows reads a hardware clock as LOCAL time - always, unless RealTimeIsUniversal says otherwise
    - and a Qubes qube with `timezone=localtime` presents DOM0'S LOCAL time on that clock. They
    already agree. The guest needs one thing on top: dom0's zone, which the installer reads from
    /qubes-timezone. Stock QWT sets neither a zone nor a convention; its whole time handling is
    update-time.bat, one line asking dom0 for the date.

    THE VALUE WAS WRITTEN IN FIVE DIFFERENT SHAPES OVER TWO WEEKS - forced in four answer files,
    baked into a golden, written by the harness after every install, written as a constant by the
    installer, then derived by it, then latched by a per-boot task from a witness - and every one of
    them was machinery for a window that only existed because the qube's `timezone` feature is set
    LATE. dom0 sets it when the GUEST reports os+qrexec, which cannot happen before the first
    install, so a qube created without it runs its whole install on a true-UTC clock and then has the
    clock change under it a boot later: one boot three hours behind, the next three hours ahead,
    clock_boot_correction_s = 10800 against a max of 60.

    The window is removed, not managed: every path that CREATES a guest sets `timezone=localtime`
    before its first boot. So there is no convention to declare and no second state to converge to,
    and a new writer of that value - or anything clearing that feature - is a return to the defect.
    See docs/ADR-clock.md."""
    write = re.compile(r"(New-ItemProperty|Set-ItemProperty|reg(\.exe)? +add)[^\n]*RealTimeIsUniversal"
                       r"|RealTimeIsUniversal[^\n]*(/t +REG_DWORD|-PropertyType +DWord)")
    for p in sorted(ROOT.rglob("*")):
        if not p.is_file():
            continue
        rel = str(p.relative_to(ROOT)).replace("\\", "/")
        # EXEMPT: this rule's own regex, and the offline selftests that prove it fires - a detector
        # must not flag its own pattern, and a fixture proving we catch a forced write contains one.
        if rel.startswith(("upstream/", ".git/", "scratchpad/", "evidence/", "mgmt/prime-jobs/",
                           "tools/tests/")) or rel == "tools/lint-harness.py":
            continue
        if p.suffix.lower() not in (".ps1", ".sh", ".xml", ".cmd", ".py", ".wxs", ""):
            continue
        try:
            txt = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "RealTimeIsUniversal" not in txt:
            continue
        body = re.sub(r"<!--.*?-->", "", txt, flags=re.S)
        body = "\n".join(re.sub(r"(?<!\$)#.*$", "", ln) for ln in body.splitlines())
        for n, line in enumerate(body.splitlines(), 1):
            if write.search(line):
                finding("L26-hardware-clock-convention-written", f"{rel}:{n}",
                        "writes RealTimeIsUniversal - nothing should. A qube with timezone=localtime "
                        "already presents dom0 local time and Windows already reads a hardware clock "
                        "as local; set the qube feature at create time instead (docs/ADR-clock.md)")
    unset = re.compile(r"qvm-features +--unset +\S+ +timezone")
    for p in sorted(ROOT.rglob("*.sh")) + sorted(ROOT.rglob("*.py")):
        rel = str(p.relative_to(ROOT)).replace("\\", "/")
        if rel.startswith(("upstream/", "scratchpad/", "evidence/", "tools/tests/")):
            continue
        try:
            lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            if unset.search(re.sub(r"#.*$", "", line)):
                finding("L26-qube-timezone-feature-cleared", f"{rel}:{n}",
                        "clears the qube's `timezone` feature - that puts the guest's clock back on "
                        "true UTC and brings the whole transition back; it must be SET at create "
                        "time, never cleared (docs/ADR-clock.md)")

def l28_c_file_includes_its_own_header() -> None:
    """A .c file must include its sibling .h, or its own declarations are unchecked.

    MEASURED, and it cost a build: util.h gained `FOREGROUND_HOW` and `ApplyForeground`, util.c
    defined ApplyForeground - and util.c did not include util.h. gcc never saw it (the file cannot
    be syntax-checked offline: aclapi.h is not in the stubs), and the offline check I did run
    DECLARED the typedef itself, so it could not notice the missing include. MSVC found it:
    "util.c(296,42): error C2081: 'FOREGROUND_HOW': name in formal parameter list illegal",
    run 39029243791.

    The real hazard is not the compile error - that is loud. It is that a definition whose
    declaration the compiler never sees is never checked AGAINST that declaration, so a signature
    can drift from its header silently for as long as every caller happens to agree with one of them.
    """
    for c in sorted((ROOT / "agent").rglob("*.c")):
        h = c.with_suffix(".h")
        if not h.exists():
            continue
        try:
            src = c.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if f'#include "{h.name}"' in src:
            continue
        rel = c.relative_to(ROOT)
        msg = (f"defines things declared in {h.name} but never includes it, so its definitions are "
               f"not checked against their declarations (util.c did this and broke the MSVC build)")
        # TWO LEGACY OFFENDERS, named rather than baselined away. They predate this rule, neither
        # can be syntax-checked on this qube (the win32 stubs do not cover their headers), and
        # adding an include to them could surface real signature drift in files no mandate here
        # touches - so they are PENDING, printed every run, and this rule gates the moment the list
        # is empty. A NEW offender gates immediately, which is the case that cost a build.
        if rel.name in ("debug.c", "xorg-keymap.c"):
            pending_finding("L28-c-file-skips-its-own-header", str(rel), msg + " [legacy: predates the rule]")
            continue
        finding("L28-c-file-skips-its-own-header", str(rel), msg)


def l29_log_device_failure_must_be_hard() -> None:
    """L29: A LOG DEVICE FAILURE IS FATAL. There is no soft one.

    The log volume is the only thing that survives a WEDGE - a guest that will not halt cannot be
    asked for its logs, and reading the image with mtools needs no guest at all. That is its whole
    reason to exist. So a cell whose log device failed cannot produce evidence, and grading it
    produces a verdict about nothing.

    MEASURED, 2026-10-20, acceptance run 39225775322 WIN10-clean: the binder reported
    `LOGVOL-BIND fail reason=no_volume_labelled_DIAG_with_LOGVOL.TAG`, the harness logged
    `[WARN] log-volume bind failed ... logs stay on C:` and CARRIED ON. Eleven minutes later the
    guest wedged with a SPIN shape - the first wedge captured since the stall fix - and there was
    nothing from inside it, because the only instrument that would have survived had failed and the
    run had been told that was acceptable. The campaign then destroyed the specimen.

    A WARN here is the harness deciding on its own that evidence is optional. It is not.
    """
    # THE PREDICATE IS THE CALL, NOT THE MESSAGE. Two earlier versions of this rule keyed on the
    # word "[WARN]" and then on failure wording, and BOTH were defeated by rewording - I silenced
    # the first myself on 2026-10-20 by changing [WARN] to FAIL while the harness carried on
    # unchanged, and the second fired on a doc comment, a python print, a corpus fixture and the
    # deliberate LOGVOL_BIND=0 opt-out. A gate a rename defeats is not a gate, and one that cries
    # on comments gets baselined away. So it keys on the log-device PRIMITIVES: if a call to one of
    # them is tested in an `if`, the failure branch must stop.
    PRIMS = ("logvol_bind_guest", "logvol_attach ", "logvol_create ")
    STOPS = ("return 1", "return 2", "exit 1", "exit 2", "die ", "no \"", "no '")
    for f in _all_our_scripts():
        if f.suffix != ".sh":
            continue
        try:
            lines = f.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for i, ln in enumerate(lines, 1):
            s = ln.strip()
            if s.startswith("#") or not s.startswith("if "):
                continue
            if not any(pr in ln for pr in PRIMS):
                continue
            blk, depth = [], 0
            for k in range(i - 1, min(i + 25, len(lines))):
                blk.append(lines[k])
                if lines[k].strip().startswith("fi") and depth == 0 and k > i - 1:
                    break
            block = "\n".join(blk)
            if "else" not in block:
                continue                      # no failure branch at all is a different rule's problem
                
            fail_branch = block.split("else", 1)[1]
            if any(stp in fail_branch for stp in STOPS):
                continue
            finding("L29-log-device-failure-soft", f"{f.name}:{i}",
                    "a log-device primitive is tested and its FAILURE branch does not stop "
                    "(no return/exit/die/no): the cell is then graded with no instrument that "
                    "survives a wedge. Measured 2026-10-20 run 39225775322 WIN10-clean - the bind "
                    "failed, the harness carried on, the guest went SPIN, and nothing from inside "
                    "it survived.")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ledger", type=Path, default=None, help="verdicts.tsv, enables L7")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--baseline", type=Path, default=None,
                    help="fingerprint file of accepted LEGACY findings (superseded bash-harness "
                         "lineage, owner purge 2026-09-01); only findings NOT in it fail")
    ap.add_argument("--write-baseline", type=Path, default=None,
                    help="write current finding fingerprints and exit 0")
    ap.add_argument("--root", type=Path, default=None, help="tree to lint (default: the repo)")
    a = ap.parse_args()
    if a.root:
        global ROOT
        ROOT = a.root.resolve()
        _rescan()
    findings.clear()

    l28_c_file_includes_its_own_header()
    l1_no_double_background()
    l2_vmlock_required()
    l2b_reboot_must_be_proven()
    l3_no_nested_quote_powershell()
    l4_every_check_can_fail()
    l5_injector_string_collision()
    l6_probe_null_deref()
    l8_findings_current_state()
    l14_retired_topics_not_reopened()
    l9_no_shutdown_wait()
    l10_no_default_target_guest()
    l11_absent_guest_command()
    l12_provisioning_recipe()
    l31_qemu_args_one_writer()
    l15_ps_function_named_like_alias()
    l16_ps_script_scope_case_collision()
    l17_process_by_name()
    l18_relauncher_armed()
    l19_guest_run_must_sweep_the_log()
    l20_module_log_read_must_be_bounded()
    l21_second_exit_trap_replaces_the_first()
    l22_vm_start_must_assert_sole_guest()
    l23_no_pipe_into_grep_q_for_a_guest_probe()
    l24_failure_report_must_declare_a_level()
    l25_product_must_not_branch_on_localised_text()
    l26_no_hardware_clock_convention_is_written()
    l27_detached_guest_launch_must_not_use_start()
    l29_log_device_failure_must_be_hard()
    l32_every_test_file_has_a_producer()
    l33_pwsh_is_located_in_one_place()
    if a.ledger:
        l7_orphan_ledger_checks(a.ledger)

    def fp(f: tuple[str, str, str]) -> str:
        return f"{f[0]}|{f[1]}"

    if a.write_baseline:
        a.write_baseline.write_text(
            "# accepted LEGACY lint findings - superseded bash-harness lineage (owner purge\n"
            "# 2026-09-01, protocol/run.py is the framework). Never ADD entries; editing a\n"
            "# legacy file re-exposes its findings (line-anchored) so touched code gets fixed.\n"
            + "".join(sorted(fp(f) + "\n" for f in findings)))
        print(f"baseline written: {len(findings)} fingerprints")
        return 0

    legacy: set[str] = set()
    if a.baseline and a.baseline.exists():
        legacy = {ln.strip() for ln in a.baseline.read_text().splitlines()
                  if ln.strip() and not ln.startswith("#")}
    live = [f for f in findings if fp(f) not in legacy]
    baselined = len(findings) - len(live)

    by_lint: dict[str, list[tuple[str, str]]] = {}
    for lint, where, msg in live:
        by_lint.setdefault(lint, []).append((where, msg))

    for lint in sorted(by_lint):
        print(f"\n{lint}  ({len(by_lint[lint])})")
        for where, msg in by_lint[lint]:
            print(f"  {where}\n      {msg}")

    if pending and not a.quiet:
        from collections import Counter as _C
        print("\nPENDING RULES (agreed, enumerated, NOT YET GATING - each gates when its list empties):")
        for lint, n in _C(l for l, _, _ in pending).most_common():
            msg = next(m for ll, _, m in pending if ll == lint)
            print(f"  {lint}  ({n} still to fix)")
            print(f"      {msg}")
            for ll, where, _m in pending:
                if ll == lint:
                    print(f"        - {where}")

    if not a.quiet:
        print("\nNOT LINTED (judgement, deliberately left as prose):")
        for rule, why in NOT_LINTED:
            print(f"  {rule}: {why}")

    tail = f"FINDINGS: {len(live)}" if live else "CLEAN"
    if baselined:
        tail += f" ({baselined} legacy baselined)"
    print(f"\n{tail}")
    return 1 if live else 0


if __name__ == "__main__":
    sys.exit(main())
