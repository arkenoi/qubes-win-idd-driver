#!/usr/bin/env python3
"""acceptance-plan.py - THE SINGLE ENTRY POINT (PLAN-acceptance-optimization section 1): what the gate must run for
this diff, as exact harness invocations with their expected exits and cheapest probes, and whether a secondary log
volume is required. Claude executes the plan and feeds every non-PASS exit to the collector and the verdict wrapper;
it never chooses cells or invents procedures.

    tools/acceptance-plan.py [--range <base>..<head>] [--out acceptance-plan.json] [--package-run <id>] [--fi-run <id>]
                             [--setup <dir>] [--vm10 <vm>] [--vm11 <vm>] [--os11 <label>]
                             [--g10 <img>] [--g11 <img>] [--b10 <golden>] [--b11 <golden>] [--f11 <label>]

WHERE THE PLAN COMES FROM: `tools/gate-scope.py required <range> --json` (the suites and why - the scoped gate, the
always-run core, the floor, unmapped paths), mgmt/gate-ledger.json (the last full gate and the releases since) and
mgmt/gate-scope.json (the full set). NOTHING here guesses a target: a cell whose subject, golden, fixture or run id
was not given is written with `targets_missing` and the plan says `ready: false` - there is no default target
(tools/lint-harness.py L10, owner 2026-09-21).

THE INVOCATIONS ARE THE COMMITTED ONES, verbatim - the same drivers the hooks and the receipt already know:
  package-verify         tools/verify-release-package.sh --tree <setup> --commit <head>
  the install cells and  tools/release-acceptance.sh --run <id> --cells "<only the required cells>" (its feature tests
  the feature tests      run as part of it; --skip-features when none is required)
  the six remainder      tools/gate-remainder.sh --run <id> --vm10 --vm11 --os11 [--fi-run] (it computes `need` from
  suites                 gate-scope itself and merges only suites seen to pass)
Unplanned matrix.sh / prime-run.sh is refused by tools/hooks/committed-procedure-gate.sh; a plan is the Jev-quoted
procedure for those commands.

THE SECONDARY LOG VOLUME (section 3) is required whenever a cell boots a guest; the plan records whether the chosen
harness attaches one yet (none does in this pass - section 8 step 2 is the retrofit) so a reader cannot mistake
"required" for "present".

EXIT: 0 the plan was written (read `ready`); 2 the plan could not be decided (gate-scope exit 2, unreadable ledger or
map) - never "nothing required". Self-test: tools/tests/acceptance-plan-selftest.sh (fixture repository via
GATE_SCOPE_ROOT, scoped vs full-floor, the knobs).
"""
from __future__ import annotations
import argparse, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ROOT = os.path.abspath(os.environ.get("GATE_SCOPE_ROOT") or REPO)   # the self-test's fixture root, like gate-scope.py
GATE_SCOPE = os.path.join(HERE, "gate-scope.py")

MATRIX_CELLS = ["win10-clean", "win10-reinstall", "win10-upgrade", "win10-appvm",
                "win11-clean", "win11-reinstall", "win11-upgrade", "win11-appvm"]
FEATURE_TESTS = ["notify-errors-guest-test", "crop-before-map", "template-update"]
REMAINDER = ["gate-preflight", "p3a-etw-gate", "toast-hold-test", "log-sweep", "failproof-gates", "failproof-faultinject"]
FI_SUITES = ["failproof-gates", "failproof-faultinject"]
GUEST_DRIVING = set(MATRIX_CELLS) | set(FEATURE_TESTS) | set(REMAINDER)

EXITS_RELEASE_ACCEPTANCE = {"0": "COMPLETE - every cell and feature test passed and the receipt satisfies the diff",
                            "1": "INCOMPLETE/FAILED - read the campaign's FAIL lines: an INVALID-* line is instrument-fail (ungraded), "
                                 "any other FAIL line is product-fail; the receipt separates them",
                            "2": "refused before any guest was touched (usage, a missing fixture, a stray harness, /tmp too full)"}
EXITS_GATE_REMAINDER = {"0": "every required remainder suite passed and was merged into the receipt",
                        "1": "at least one suite failed (its .out under $HOME/qwt-accept/remainder-<head>/work names it; "
                             "exit 2/3 inside a suite is INSTRUMENT, exit 1 is FAIL)",
                        "2": "usage or a refused download - nothing ran"}
EXITS_PACKAGE_VERIFY = {"0": "the package's identity, sums and provenance verify", "other": "FAIL - nothing downstream is meaningful"}


def die(msg: str) -> int:
    print("acceptance-plan: " + msg, file=sys.stderr)
    return 2


def git(*args: str) -> str:
    p = subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else ""


def gate_required(rng: str) -> dict | None:
    env = dict(os.environ)
    env["GATE_SCOPE_ROOT"] = ROOT
    p = subprocess.run([sys.executable, GATE_SCOPE, "required", rng, "--json"], capture_output=True, text=True, env=env)
    # A FAILED gate-scope is NO requirement, never an EMPTY one (exit 2 = it could not decide).
    out = p.stdout if p.returncode == 0 else ""   # GUARD:gatescope2 DEFECT: out = p.stdout or '{"suites": [], "full": false, "why": {}}'
    if not out.strip():
        print("acceptance-plan: gate-scope.py required exited %d: %s" % (p.returncode, (p.stderr or p.stdout).strip()[:300]), file=sys.stderr)
        return None
    try:
        return json.loads(out)
    except ValueError as e:
        print("acceptance-plan: gate-scope.py printed no JSON (%s)" % e, file=sys.stderr)
        return None


def ledger_summary() -> dict | None:
    try:
        led = json.load(open(os.path.join(ROOT, "mgmt", "gate-ledger.json"), encoding="utf-8"))
    except (OSError, ValueError) as e:
        print("acceptance-plan: the ledger is unreadable (%s)" % e, file=sys.stderr)
        return None
    rel = [r for r in led.get("releases", []) if isinstance(r, dict)]
    fulls = [r for r in rel if r.get("full") and r.get("result") == "pass"]
    last = fulls[-1] if fulls else None
    since = [r for r in rel if last and r.get("date", "") > last.get("date", "")]
    return {"releases_on_record": len(rel),
            "last_full_gate": {"version": last.get("version"), "date": last.get("date")} if last else None,
            "releases_since_last_full": len(since) if last else len(rel)}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--range", help="base..head (default: the newest v-tag that is an ancestor of HEAD, to HEAD)")
    ap.add_argument("--out", default="acceptance-plan.json")
    ap.add_argument("--package-run", help="the release-package workflow run id the cells install from")
    ap.add_argument("--fi-run", help="a release-package run dispatched with fault_injection=true (the FI suites need it)")
    ap.add_argument("--setup", help="the downloaded qwt-improved-setup tree (default: $HOME/qwt-accept/rel-<run>/dl/qwt-improved-setup)")
    for t in ("vm10", "vm11", "os11", "g10", "g11", "b10", "b11", "f11"):
        ap.add_argument("--" + t)
    a = ap.parse_args(argv)

    head = git("rev-parse", "HEAD")
    if not head:
        return die("not a git repository: %s" % ROOT)
    rng = a.range
    if not rng:
        base = git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD^") or git("rev-list", "--max-parents=0", "HEAD")
        rng = "%s..%s" % (base, head)
    req = gate_required(rng)
    if req is None:
        return die("the gate's requirement could not be computed for %s - a plan cannot be written from nothing" % rng)
    try:
        m = json.load(open(os.path.join(ROOT, "mgmt", "gate-scope.json"), encoding="utf-8"))
    except (OSError, ValueError) as e:
        return die("the scope map is unreadable (%s)" % e)
    led = ledger_summary()
    if led is None:
        return die("no ledger, no plan - the floor is never assumed not to have tripped")

    required = list(req.get("suites") or [])    # gate-scope already expands a FULL gate to the whole set
    if req.get("full") and set(m.get("full", {}).get("suites") or []) - set(required):
        return die("gate-scope says FULL but its suite list is not the map's full set - the two tools disagree; refusing to plan")
    why = req.get("why") or {}
    setup = a.setup or (os.path.join(os.path.expanduser("~"), "qwt-accept", "rel-%s" % a.package_run, "dl", "qwt-improved-setup") if a.package_run else None)
    cells: list[dict] = []
    blocked: list[str] = []
    order = 0

    def cell(cid: str, suites: list[str], harness: str, cmd: str, exits: dict, probes: list[str], missing: list[str], note: str = "", logvol: bool = False) -> None:
        nonlocal order
        order += 1
        cells.append({"order": order, "id": cid, "suites": suites, "harness": harness, "command": cmd, "expected_exits": exits,
                      "cheapest_probes": probes, "targets_missing": missing, "note": note,
                      "logvol": {"required": logvol, "id": "%s-%s" % (cid, head[:8]) if logvol else None,
                                 "image": "$LOGVOL_DIR/logs-%s-%s.img" % (cid, head[:8]) if logvol else None},
                      "on_non_pass": "mgmt/harness/collect-failure.sh <vm> <outdir> \"<reason>\" --since <start> [--logvol <image>|none] --harness-cmd \"<this command>\"; "
                                     "then tools/verdict-jev.py --sweep <report.json>... --snapshot <outdir>/activity-snapshot.json --errors <harness FAIL lines>"})
        blocked.extend("%s: needs %s" % (cid, t) for t in missing)

    # 1. the package's identity, before any guest is touched
    if "package-verify" in required:
        missing = [t for t, v in (("--package-run or --setup", setup),) if not v]
        cell("package-verify", ["package-verify"], "tools/verify-release-package.sh",
             "bash tools/verify-release-package.sh --tree %s --commit %s" % (setup or "<setup>", head), EXITS_PACKAGE_VERIFY,
             ["test -s %s/MANIFEST.json" % (setup or "<setup>"), "test -s %s/install.cmd" % (setup or "<setup>"),
              "python3 tools/ci-state.py %s" % head[:12]], missing)

    # 2. the install cells and the feature tests: ONE release-acceptance.sh invocation over exactly the required cells
    mcells = [c for c in MATRIX_CELLS if c in required]
    feats = [f for f in FEATURE_TESTS if f in required]
    if mcells or feats:
        need10 = any(c.startswith("win10") for c in mcells)
        need11 = any(c.startswith("win11") for c in mcells)
        missing = []
        if not a.package_run: missing.append("--package-run")
        if need10 and not (a.g10 and a.b10): missing.append("--g10/--b10 (win10 entry image + base golden)")
        if need11 and not (a.g11 and a.b11): missing.append("--g11/--b11 (win11 entry image + base golden)")
        if feats and not a.f11: missing.append("--f11 (the golden family the feature tests quick-upgrade)")
        env = " ".join("%s=%s" % (k, v) for k, v in (("G10", a.g10), ("G11", a.g11), ("B10", a.b10), ("B11", a.b11), ("F11", a.f11)) if v)
        cmd = "%s tools/release-acceptance.sh --run %s --cells \"%s\"%s" % (env, a.package_run or "<release-package-run-id>", " ".join(mcells) or "<none>",
                                                                        "" if feats else " --skip-features")
        probes = ["python3 tools/gate-scope.py floor"]
        for g in (a.g10, a.g11, a.b10, a.b11):
            if g: probes.append("qvm-check %s" % g)
        for g in (a.g10, a.g11):
            if g: probes.append("test -f mgmt/fixtures/%s.json" % g)
        for b in (a.b10, a.b11):
            if b: probes.append("mgmt/golden.sh verify %s" % b)
        if a.f11: probes.append("qvm-check %s-qwt" % a.f11)
        note = ("the feature tests %s run inside this invocation (release-acceptance.sh runs all three: %s); the receipt names only what ran"
                % (", ".join(feats), ", ".join(FEATURE_TESTS))) if feats else "no feature test is required: --skip-features (say so in the report)"
        if not mcells:
            note += "; no install cell is required, so run only the feature tests: the driver needs at least one cell - run win11-clean (the core's) or the feature harnesses directly"
        cell("install-and-feature-cells", mcells + feats, "tools/release-acceptance.sh", cmd.strip(), EXITS_RELEASE_ACCEPTANCE, probes, missing, note, logvol=True)

    # 3. the remainder suites, through the driver that computes `need` itself
    rem = [s for s in REMAINDER if s in required]
    if rem:
        missing = [t for t, v in (("--package-run", a.package_run), ("--vm10", a.vm10), ("--vm11", a.vm11), ("--os11", a.os11)) if not v]
        fi = [s for s in rem if s in FI_SUITES]
        # The FI suites need an INSTALLED injector build: a release-package run dispatched with fault_injection=true.
        # On an ordinary package both come back green for the wrong reason (gate-remainder.sh refuses them), so a plan
        # without --fi-run is not ready.
        if fi and not a.fi_run:   # GUARD:fiblock DEFECT: if False:
            missing.append("--fi-run (release-package dispatched with -f fault_injection=true; %s cannot run on an ordinary package)" % ", ".join(fi))
        cmd = "tools/gate-remainder.sh --run %s --vm10 %s --vm11 %s --os11 %s%s" % (a.package_run or "<run>", a.vm10 or "<vm10>", a.vm11 or "<vm11>", a.os11 or "<os11>",
                                                                                    " --fi-run %s" % a.fi_run if a.fi_run else "")
        probes = [cmd + " --dry", "test -f mgmt/harness/log-sweep-baseline.json"]
        cell("remainder-suites", rem, "tools/gate-remainder.sh", cmd, EXITS_GATE_REMAINDER, probes, missing,
             "runs the suites gate-scope requires and merges only the ones seen to pass; log-sweep runs LAST over the subject", logvol=True)

    logvol_required = any(s in GUEST_DRIVING for s in required)   # GUARD:logvol DEFECT: logvol_required = False
    plan = {"version": 1, "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "range": rng, "head": head,
            "gate": {"full": bool(req.get("full")), "floor": req.get("floor") or "", "unmapped": req.get("unmapped") or [],
                     "changed": req.get("changed") or [], "closure_added": req.get("closure_added") or [],
                     "required": required, "why": {s: (why.get(s) or ["(the full set)"])[:3] for s in required}, "ledger": led},
            "logvol": {"required": logvol_required,
                       "why": "a cell boots a guest; its module logs must survive a wedge or a kill and be readable without the guest (plan section 3)"
                              if logvol_required else "no required suite boots a guest",
                       "harness_support": "NOT YET: no harness attaches one (section 8 step 2 is the retrofit of matrix.sh, quick-upgrade.sh and prime-run.sh "
                                          "with mgmt/harness/logvol-lib.sh); until then the collector is called with --logvol none and the package records the gap"},
            "cells": cells, "ready": not blocked, "blocked": blocked,
            "procedure": {"unplanned_heavy_paths": "matrix.sh / prime-run.sh / reprovision-usb.sh outside this plan are refused by tools/hooks/committed-procedure-gate.sh",
                          "serial": "one VM-mutating job at a time (mgmt/harness/vmlock.sh); the plan's cells run in `order`",
                          "verdict": "every non-PASS exit -> mgmt/harness/collect-failure.sh -> tools/verdict-jev.py; Claude only when it exits 1",
                          "skill": ".claude/skills/acceptance/SKILL.md"}}
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    json.dump(plan, open(a.out, "w", encoding="utf-8"), indent=1)
    print("PLAN %s: %s - %d suite(s) required, %d cell(s), logvol_required=%s, ready=%s%s -> %s" % (
        rng, "FULL" if plan["gate"]["full"] else "SCOPED", len(required), len(cells), logvol_required, plan["ready"],
        "" if plan["ready"] else " (blocked: %s)" % "; ".join(blocked), a.out))
    for c in cells:
        print("  %d. %-26s %s" % (c["order"], c["id"], c["command"][:150]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
