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


# --------------------------------------------------------------------------- L2
def l2_vmlock_required() -> None:
    """RULE 15. Any harness that drives a guest must take the per-VM lock, or two of them can run
    on one subject and interleave their probes."""
    for f in HARNESS:
        txt = f.read_text(errors="replace")
        if "tools/qtest" not in txt:
            continue                                   # not a guest-driving harness
        if "vmlock.sh" in txt and "vm_lock" in txt:
            continue
        if f.name == "vmlock.sh":
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
    l3_no_nested_quote_powershell()
    l4_every_check_can_fail()
    l5_injector_string_collision()
    l6_probe_null_deref()
    l8_findings_current_state()
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
