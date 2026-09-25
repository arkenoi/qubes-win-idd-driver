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
        # the rule still fires for everything else.
        if f.name in ("shutdown-lib.sh",):
            continue
        finding("L2-missing-vmlock", f.name,
                "drives a guest via tools/qtest but never calls vm_lock")


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
