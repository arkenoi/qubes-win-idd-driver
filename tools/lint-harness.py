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
        if f.name in ("shutdown-lib.sh", "wu-liveness.sh"):
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
    record, or a timestamp filter. Pending, not gating, until the named list is empty."""
    # the read has to be of a windows-utils MODULE log - the ones several processes now share
    reads_module_log = re.compile(r"(gui-agent|qrexec-(?:agent|wrapper)|qubesdb-daemon)-\*?\.?log|Filter\s+'?(gui-agent|qrexec-\w+|qubesdb-daemon)-\*\.log")
    bounded = ("-Last 1", "process ID:", "$all[", "-Tail", "total_lines", "KeepRx", "AfterLine")
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

    idx = ROOT / "FINDINGS.md"
    if idx.exists():
        body = idx.read_text(errors="replace")
        if re.search(r"^#{1,2} \d{4}-\d{2}-\d{2}", body, re.M):
            finding("L8-findings-index-regrowing", "FINDINGS.md",
                    "a dated section was appended to the INDEX: it belongs in findings/<topic>.md")


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
DEFAULT_TARGET_RE = re.compile(
    r'(?:\$\{' + TARGET_VARS + r'|\b' + TARGET_VARS + r'="?\$\{\d+)'
    r'[^}]*:-(dom0|win[0-9a-z-]*)\}')

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
            scanned += sorted(p for p in d.iterdir()
                              if p.is_file() and (p.suffix == ".sh" or p.name == "qtest"))
    for f in scanned:
        for n, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
            s = line.lstrip()
            if s.startswith("#"):
                continue
            m = DEFAULT_TARGET_RE.search(line)
            if m:
                finding("L10-default-target-guest", f"{f.name}:{n}",
                        f"defaults a target to '{m.group(1)}' - name it explicitly or refuse")


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
    for p in _all_our_scripts():
        lines = _ps_code_lines(p.read_text(errors="replace"))
        rel = p.relative_to(ROOT)
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
    l15_ps_function_named_like_alias()
    l16_ps_script_scope_case_collision()
    l17_process_by_name()
    l18_relauncher_armed()
    l19_guest_run_must_sweep_the_log()
    l20_module_log_read_must_be_bounded()
    l21_second_exit_trap_replaces_the_first()
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
