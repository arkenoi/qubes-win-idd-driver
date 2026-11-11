#!/usr/bin/env python3
"""coverage-receipt.py - the coverage receipt the release-cut gate reads: ONE receipt per BUILD TAG, a verdict per
MODULE, accumulated across runs through ONE merge rule (docs/ADR-acceptance.md section 7), with PRODUCT-FAIL and
INSTRUMENT-FAIL told apart (PLAN-acceptance-optimization section 6; docs/ADR-acceptance.md section 4).

    tools/coverage-receipt.py --out scratchpad/gate-coverage-<build-tag>.json --build <build-tag> --package-run <id>
                              [--campaign <dir> --cells "<cell> ..."] [--feature <name>=<rc>]...
                              [--feature-ledger <name>=<path>]... [--package-verify-rc <n>]
                              [--module <name>=<class>]... [--fi-module <name>]... [--fi-run <id>]
                              [--range <b>..<h>] [--built-from <sha>] [--harness <sha>] [--run <evidence dir>]
                              [--attempt <id>] [--narrowed <name>]

THE IDENTITY IS THE BUILD TAG, NEVER HEAD. Owner, 2026-11-11: «we are not accepting "head", we accept a precise
build»; «take separate verdicts by modules, make instrument fixes never invalidating those verdicts»; «it costs us a
new full acceptance run on every minor documentation change or harness fix». Until that date the receipt was named by
the HARNESS checkout's HEAD, read at the END of a multi-hour run (tools/release-acceptance.sh), and the remainder
merged with an inline python of its own that wrote the harness sha as `built_from`. A harness or documentation commit
between two runs split one build's coverage across two files, and the cut found neither.

A MODULE is what this receipt used to call a suite: package-verify, each matrix cell, each feature test, each
remainder suite. Each entry records: class, harness (full sha of the checkout that ran it - PROVENANCE, never
identity), harness_dirty (when that checkout had uncommitted changes), run (the evidence dir), attempt, at (UTC),
package_run, and fi_run where the module ran on the fault-injection package.

THE MERGE RULE lives in merge_module() below and NOWHERE ELSE. Both writers reach it by running this file: the
acceptance (tools/release-acceptance.sh step 7, from the campaign's own JSON) and the remainder (tools/gate-remainder.sh,
as --module name=class words). Per module:
  * an instrument-fail or not-run NEVER replaces a measured verdict (pass or product-fail);
  * a measured verdict replaces an instrument-fail or not-run;
  * a measured verdict replaces an earlier MEASURED verdict ONLY when the run that produced it records a different
    harness commit - so an instrument fix takes effect, and a re-run with no change cannot turn a product-fail green.
The top-level `suites` (pass + product-fail = covered), `product_fail`, `instrument_fail`, `not_run`, `result` and
`classes` are RECOMPUTED from the module map on every write, so every existing reader of those fields keeps working
(tools/gate-scope.py check reads `suites` and `range`; tools/release-acceptance.sh reads `classes`).

HOW A CELL IS CLASSED: by tools/acceptance_json.py from the matrix's own JSON - <dir>/matrix/matrix-result.json and the
rows in <dir>/matrix/checks.jsonl, where the cell and the class are fields set where mgmt/harness/matrix.sh decides
them. NO LOG TEXT IS READ. Until 2026-11-11 this file recovered both by a regex over the campaign's *.out lines, with
a token list of its own, and was blinded by a change to that prose (the 4.3.36 receipt: every cell "not run" with the
evidence on disk). Owner, 2026-11-11: "we were intended to stop grepping and make json parser instead, grep is
unreliable". The rules are the reader's and are stated in its header; in short:
  cell class:  a FAIL row -> product-fail;  else an INVALID row -> instrument-fail;  else a PASS row -> pass;
               no row -> not-run;  rows that cannot be relied on (the run did not end through its exit trap, a lost
               or corrupt row) -> EVERY cell instrument-fail, with the reason.
  A campaign directory with no matrix-result.json has no matrix verdict at all: every cell is not-run. That includes
  campaigns recorded before the rows existed - they cannot be re-classed by this tool, and that is deliberate.
  `cell_verdict_source` in the receipt says which it was: rows | none.
A feature test is classed by the class its own ledger DECLARES when one is passed (--feature-ledger; see main()), and
otherwise by its exit: 0 pass, 2 instrument-fail, anything else product-fail. package-verify by its rc. A --module
word is classed by its caller, which read the suite's ledger through mgmt/harness/verdict-lib.sh.

THE RECEIPT: {"schema": 2, "build": <tag>, "built_from": <build commit>, "modules": {<name>: {class, harness, ...}},
"suites": [pass + product-fail]  (what RAN and MEASURED - Jev 2026-10-13 receipt_product_fail_covered =
covered-with-fail-flag 0.94: a product failure is covered, and the cut is refused by the acceptance RECORD),
"product_fail": [...], "instrument_fail": [...] (NOT in suites - uncovered), "not_run": [...], "result": pass|fail, ...}.
Exit 0 receipt written; 2 the campaign dir, an argument, or the receipt on disk is unusable (no receipt - missing
data fails; a receipt that names ANOTHER build is never written over).
"""
from __future__ import annotations
import argparse, json, os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import acceptance_json  # noqa: E402 - the one reader of a campaign's JSON; this file reads no log text

# THE UNGRADED VOCABULARY, for a FEATURE TEST'S LEDGER only (ledger_class below). Matrix cells are not classed by
# token any more: their class is a field of the matrix's own rows, read through tools/acceptance_json.py.
INSTRUMENT_TOKENS = ("INVALID", "INSTRUMENT", "INCONCLUSIVE", "BLOCKED", "SKIPPED")
# A SWEEP DECLARES "I COULD NOT MEASURE" IN ITS STATUS, NOT IN A TOKEN THIS LIST HOLDS. MEASURED
# 2026-11-07, campaign 42400226595 at 4b55d0a46510: supervision-gate's ONLY failing row was
# `FAIL  [SW] the sweep finds nothing new or breached -- LOGSWEEP-RESULT ... rc=3 status=DATA`,
# and template-update failed twice on "missing data fails". Neither text carries one of the five
# tokens above, so BOTH were recorded as product regressions - the one thing a blind instrument
# cannot tell you - while every graded product cell passed (matrix 8/8 CLEAN, 0 breaches, 0 P1).
# mgmt/harness/verdict-lib.sh:11 states the invariant that broke: "missing data is
# INVALID-INSTRUMENT, never FAIL, never a default", and this file's own docstring already named
# "sweep DATA/INCOMPLETE" as instrument per plan section 6 - only the vocabulary never got it.
# ANCHORED ON `status=`, NOT THE BARE WORD: "DATA" is a substring of METADATA and of any prose that
# mentions data, so a bare token would silently reclassify real product FAILs. The predicate has to
# BE the declaration, not a word that co-occurs with it.
UNGRADED_STATUS_RE = re.compile(r"\bstatus=(?:DATA|INCOMPLETE)\b")
CLASSES = ("pass", "product-fail", "instrument-fail", "not-run")
MEASURED = ("pass", "product-fail")   # a VERDICT about the product; the other two classes measured nothing
BUILD_TAG_RE = re.compile(r"^build-\d+\.\d+\.\d+\.\d+$")


def instrument_line(text: str) -> bool:
    """True when a FAIL text DECLARES it could not measure, wherever in the text that sits."""
    return any(t in text for t in INSTRUMENT_TOKENS) or bool(UNGRADED_STATUS_RE.search(text))


def ledger_class(path: str) -> str:
    """pass | product-fail | instrument-fail, or "" when there is no usable ledger.

    THE CLASS IS DECLARED PER ROW AND THE COLUMN IS NOT FIXED. tools/gate-remainder.sh:92 reads
    column 3, which is right for the failproof ledgers (c3=INVALID-INSTRUMENT) and WRONG for
    supervision-e2e's (c1=SW, c2=FAIL, c3=the claim, c4=LOGSWEEP-RESULT ... status=DATA): there it
    reads the claim text, finds no token, returns NONE and the caller falls back to the exit code -
    which is exactly the defect this fixes. So scan the WHOLE row. Worst wins: one product FAIL
    outranks every gap. A missing, empty or unreadable ledger returns "" so the caller keeps its
    old behaviour - "no row" must never read as "not a failure".
    """
    try:
        rows = [ln for ln in open(path, encoding="utf-8", errors="replace").read().splitlines() if ln.strip()]
    except OSError:
        return ""
    if not rows:
        return ""
    worst = "pass"
    for ln in rows:
        fields = [f.strip() for f in ln.split("\t")]
        if not any(f == "FAIL" or any(f.startswith(t) for t in INSTRUMENT_TOKENS) for f in fields):
            continue
        if instrument_line(ln):
            if worst != "product-fail":
                worst = "instrument-fail"
        else:
            worst = "product-fail"
    return worst


def merge_module(old: dict | None, new: dict) -> tuple[dict, str]:
    """THE MERGE RULE (docs/ADR-acceptance.md section 7) - the one place it lives. -> (the entry kept, why).

    `old` is what the receipt holds for this module, `new` is what this run says. A class in MEASURED is a verdict
    about the product; instrument-fail and not-run are the absence of one. The harness sha decides between two
    measured verdicts: a different checkout ran the suite, so its verdict supersedes; the same checkout cannot
    change a verdict by running again.
    """
    if not old:
        return new, "recorded %s" % new.get("class")
    oc, nc = old.get("class"), new.get("class")
    if nc not in MEASURED:
        if oc in MEASURED:
            return old, "kept measured %s: a %s does not replace a measured verdict" % (oc, nc)
        return new, "replaced %s with %s (neither measured)" % (oc, nc)
    if oc not in MEASURED:
        return new, "replaced %s with measured %s" % (oc, nc)
    oh, nh = old.get("harness") or "", new.get("harness") or ""
    if nh and nh != oh:
        return new, "replaced measured %s with measured %s: a different harness ran it (%s -> %s)" % (
            oc, nc, oh[:12] or "?", nh[:12])
    return old, "kept measured %s: the same harness %s ran it again and said %s - a re-run with no change cannot alter a measured verdict" % (
        oc, oh[:12] or "?", nc)


def recompute(rec: dict) -> dict:
    """The top-level lists every existing reader knows, derived from the module map - never written directly."""
    mods = rec.get("modules") or {}
    cls = {n: (m.get("class") or "not-run") for n, m in mods.items()}
    rec["suites"] = sorted(n for n, c in cls.items() if c in MEASURED)      # an instrument-fail suite is NOT covered
    rec["product_fail"] = sorted(n for n, c in cls.items() if c == "product-fail")
    rec["instrument_fail"] = sorted(n for n, c in cls.items() if c == "instrument-fail")
    rec["not_run"] = sorted(n for n, c in cls.items() if c == "not-run")
    rec["result"] = "pass" if cls and all(c == "pass" for c in cls.values()) else "fail"
    rec["classes"] = {n: dict({"class": cls[n]}, **(mods[n].get("detail") or {})) for n in sorted(mods)}
    return rec


def merge_receipt(existing: dict, modules: dict[str, dict], top: dict) -> tuple[dict, list[str]]:
    """This run's module entries merged into the receipt on disk through merge_module(); `top` overwrites the
    identity and bookkeeping fields. A module this run did not name keeps what the receipt held."""
    rec = dict(existing)
    old = rec.get("modules") or {}
    merged, notes = {}, []
    for n in sorted(set(old) | set(modules)):
        if n not in modules:
            merged[n] = old[n]
            continue
        kept, why = merge_module(old.get(n), modules[n])
        merged[n] = kept
        notes.append("%s: %s" % (n, why))
    rec["modules"] = merged
    rec.update(top)
    return recompute(rec), notes


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--build", required=True, help="the build tag build-<version>.<run number>: the receipt's identity (tools/build-tag.sh)")
    ap.add_argument("--package-run", required=True, help="the release-package run the build tag names")
    ap.add_argument("--campaign", default="", help="the campaign dir whose matrix rows class the cells in --cells")
    ap.add_argument("--cells", default="")
    ap.add_argument("--feature", action="append", default=[], help="<name>=<rc> (repeatable)")
    ap.add_argument("--feature-ledger", action="append", default=[],
                    help="<name>=<path to the suite's verdicts.tsv> (repeatable); its DECLARED class "
                         "beats the exit code, which cannot carry the distinction")
    ap.add_argument("--package-verify-rc", type=int)
    ap.add_argument("--module", action="append", default=[],
                    help="<name>=<pass|product-fail|instrument-fail|not-run> (repeatable): a module its caller classed from the suite's own ledger")
    ap.add_argument("--fi-module", action="append", default=[], help="a module that ran on the fault-injection package; --fi-run is recorded on it")
    ap.add_argument("--fi-run", default="", help="the fault-injection release-package run the --fi-module entries ran on")
    ap.add_argument("--built-from", default="", help="the build commit (default: what the build tag points at; both given must agree)")
    ap.add_argument("--range", default="", help="<previous release tag>..<build commit>, the PACKAGE's diff")
    ap.add_argument("--harness", default="", help="full sha of the checkout that ran these modules (default: HEAD here) - provenance, never identity")
    ap.add_argument("--run", default="", help="the evidence dir these verdicts live in (default: --campaign)")
    ap.add_argument("--attempt", default="")
    ap.add_argument("--narrowed", default="", help="the one module a --only invocation ran; listed under narrowed_runs when it measured")
    a = ap.parse_args(argv)

    def refuse(msg: str) -> int:
        print("coverage-receipt: %s - no receipt (missing data fails)" % msg, file=sys.stderr)
        return 2

    def git(*args: str) -> str:
        p = subprocess.run(["git", *args], capture_output=True, text=True)
        return p.stdout.strip() if p.returncode == 0 else ""

    if not BUILD_TAG_RE.match(a.build):
        return refuse("'%s' is not a build tag (build-<version>.<run number>)" % a.build)
    tag_commit = git("rev-parse", "--verify", "--quiet", "refs/tags/%s^{commit}" % a.build)
    built_from = a.built_from or tag_commit
    if not built_from:
        return refuse("tag %s is not in this repo and no --built-from was given" % a.build)
    if tag_commit and a.built_from and tag_commit != a.built_from:
        return refuse("tag %s points at %s but --built-from says %s" % (a.build, tag_commit[:12], a.built_from[:12]))
    head = git("rev-parse", "HEAD")
    harness = a.harness or head
    # A dirty checkout has no commit for its state, so its sha alone would let an uncommitted change masquerade as
    # the recorded harness; the flag is recorded so a reader can see it. The rule compares shas: commit the fix.
    harness_dirty = harness == head and subprocess.run(["git", "diff", "--quiet", "HEAD"], capture_output=True).returncode == 1

    # ---- this run's verdicts: (class, detail, on the FI package?) per module ---------------------------------------
    classed: dict[str, tuple[str, dict | None, bool]] = {}
    notes: list[str] = []
    source = ""
    if a.campaign:
        if not os.path.isdir(a.campaign):
            return refuse("no campaign dir %s" % a.campaign)
        matrix = acceptance_json.read_matrix(a.campaign)
        classes, notes = acceptance_json.cell_classes(matrix, a.cells.split())
        source = "rows" if matrix["present"] else "none"
        for c, info in classes.items():
            classed[c] = (info["class"], {k: v for k, v in info.items() if k != "class"}, False)
    elif a.cells.strip():
        return refuse("--cells without --campaign: cells are classed from the campaign's own rows and nowhere else")
    ledgers: dict[str, str] = {}
    for fl in a.feature_ledger:
        name, _, path = fl.partition("=")
        if not name or not path:
            return refuse("bad --feature-ledger %r (want name=path)" % fl)
        ledgers[name] = path
    for f in a.feature:
        name, _, rc = f.partition("=")
        if not name or not rc.lstrip("-").isdigit():
            return refuse("bad --feature %r (want name=rc)" % f)
        rc_i = int(rc)
        by_exit = "pass" if rc_i == 0 else ("instrument-fail" if rc_i == 2 else "product-fail")
        # AN EXIT CODE CANNOT CARRY THIS DISTINCTION, and the reason is recorded in
        # tools/gate-remainder.sh:82-87: two conventions exist in this apparatus and they are
        # INVERTED - verdict-lib.sh reads 1 as EXECUTED-WITH-GAPS and 2 as BROKEN, while
        # release-acceptance.sh's logvol arm reads 2 as INVALID-RIG and every other non-zero as a
        # product FAIL. That gate fixed it for the two suites whose ledger it can find and said so;
        # the feature-test path never inherited the fix (the standing rule: a copied idiom needs
        # EVERY site of that operation). The suites ALREADY declare the class per row - read that.
        declared = ledger_class(ledgers[name]) if name in ledgers else ""
        # A LEDGER MAY NEVER TURN A NON-ZERO EXIT INTO A PASS. The ledger is written DURING the run,
        # so a suite that died after its last row would otherwise read as green on its own stale
        # evidence - a verifier reading its own bookkeeping. Downgrading product-fail to
        # instrument-fail is the whole point and is safe: `covered` excludes instrument-fail,
        # so the suite leaves `suites`, gate-scope.py check still refuses the cut on coverage, and
        # `result` stays "fail" for any non-pass class. The CLASS the operator is told changes;
        # no gate decision does.
        if declared and not (rc_i != 0 and declared == "pass"):
            classed[name] = (declared, None, False)
            if declared != by_exit:
                notes.append("%s: class %s DECLARED by %s (exit %d alone would have said %s)"
                             % (name, declared, ledgers[name], rc_i, by_exit))
        else:
            classed[name] = (by_exit, None, False)
            if declared == "pass" and rc_i != 0:
                notes.append("%s: ledger %s declares every row passing but the suite exited %d - "
                             "kept %s; a ledger cannot outrank a non-zero exit"
                             % (name, ledgers[name], rc_i, by_exit))
    if a.package_verify_rc is not None:
        classed["package-verify"] = ("pass" if a.package_verify_rc == 0 else "product-fail", None, False)
    for mw in a.module:
        name, _, cls = mw.partition("=")
        if not name or cls not in CLASSES:
            return refuse("bad --module %r (want name=%s)" % (mw, "|".join(CLASSES)))
        classed[name] = (cls, None, name in a.fi_module)
    if not classed:
        return refuse("no module to record: give --campaign/--cells, --feature, --package-verify-rc or --module")

    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    modules: dict[str, dict] = {}
    for name, (cls, detail, on_fi) in classed.items():
        e = {"class": cls, "harness": harness, "run": a.run or a.campaign, "at": now, "package_run": a.package_run}
        if harness_dirty:
            e["harness_dirty"] = True
        if a.attempt:
            e["attempt"] = a.attempt
        if on_fi and a.fi_run:
            e["fi_run"] = a.fi_run
        if detail:
            e["detail"] = detail
        modules[name] = e

    # ---- the receipt on disk, which must be THIS build's ----------------------------------------------------------
    existing: dict = {}
    if os.path.exists(a.out):
        try:
            existing = json.load(open(a.out, encoding="utf-8"))
        except (OSError, ValueError) as e:
            return refuse("the receipt at %s does not read (%s) and is not written over" % (a.out, e))
        if not isinstance(existing, dict):
            return refuse("the receipt at %s is not a JSON object" % a.out)
        if existing.get("build") and existing.get("build") != a.build:
            return refuse("the receipt at %s is %s's, not %s's" % (a.out, existing.get("build"), a.build))
        if existing.get("built_from") and existing.get("built_from") != built_from:
            return refuse("the receipt at %s was built from %s, this build from %s" % (a.out, existing["built_from"][:12], built_from[:12]))
        if "modules" not in existing:
            notes.append("the receipt on disk had no module map (schema 1): its lists are replaced by this run's modules")
    top = {"schema": 2, "build": a.build, "built_from": built_from, "package_run": a.package_run, "generated_utc": now,
           "note": "written by tools/coverage-receipt.py: one receipt per build tag, a verdict per module merged through "
                   "merge_module() (docs/ADR-acceptance.md section 7); `suites` names what RAN and MEASURED (pass + "
                   "product-fail), instrument-fail is uncovered and refuses the cut (plan section 6); cell_verdict_source "
                   "rows = the matrix's checks.jsonl through tools/acceptance_json.py, none = no matrix result"}
    if a.fi_run:
        top["fi_run"] = a.fi_run
    if a.range:
        top["range"] = a.range
    if source:
        top["cell_verdict_source"] = source
    rec, merge_notes = merge_receipt(existing, modules, top)
    if a.narrowed and rec["modules"].get(a.narrowed, {}).get("class") in MEASURED:
        rec["narrowed_runs"] = sorted(set(rec.get("narrowed_runs") or []) | {a.narrowed})
    rec["notes"] = notes + merge_notes
    os.makedirs(os.path.dirname(os.path.abspath(a.out)) or ".", exist_ok=True)
    with open(a.out + ".tmp", "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=1)
        fh.write("\n")
    os.replace(a.out + ".tmp", a.out)
    for n in merge_notes:
        print("  " + n)
    print("RECEIPT %s: covered=%d product_fail=%s instrument_fail=%s not_run=%s result=%s -> %s" % (
        a.build, len(rec["suites"]), rec["product_fail"] or "-", rec["instrument_fail"] or "-", rec["not_run"] or "-",
        rec["result"], a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
