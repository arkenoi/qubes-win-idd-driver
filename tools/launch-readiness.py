#!/usr/bin/env python3
"""launch-readiness.py - may this campaign start? Facts computed by code, judged by Jev, bound by hash.

    tools/launch-readiness.py check  --plan <acceptance-plan.json>   # facts -> hard blocks -> Jev -> receipt
    tools/launch-readiness.py verify --run <release-package run>     # the procedure gate's half: recompute, compare
    tools/launch-readiness.py facts  --plan <acceptance-plan.json>   # print the facts, nothing else

WHY (owner, 2026-11-26: «what can we do to prevent you doing busywork campaigns ever», then «fix this. and wire
mandatory jev gate with unfalsifiable facts»). Three campaigns were launched that day and two were wasted:
- rel-45823201373 went out without the Update Orchestrator change the owner ordered on 2026-09-30, recorded in
  findings/updates.md as "GAP, fix not started" against qubes-windows-update.ps1 - the file that campaign changed.
- rel-45847660698 went out on b1f18a7d, whose own message said "Not run on a guest". The one suite that reaches that
  code, updater-component (8 min), runs AFTER the 90-min matrix; it showed a false ERROR 1 h 40 in. It still graded
  PASS, so an exit code alone would not have stopped it either.
Both permits were Jev calls, but on states the agent wrote, carrying only `procedure_is_committed`: the readiness
question asked until 2026-11-18 (`preconditions_met`) had been dropped, and the state rejected the short cycle on a
claim the facts contradicted. The register's own head already ordered «run SELECTIVELY first» (owner 2026-10-21).

WHAT IS COMPUTED, never written by hand: the plan's identity and readiness; every product path the range changes,
from tools/gate-scope.py's own map; for each, whether the driver's pre-matrix cell smoke (win11-clean) covers it or a
standalone precheck suite passed on THIS package with no ERROR line in its pass log; the product commits in the range;
the findings bullets that name a changed product file and carry an open marker and no closing one. Decidable failures
block here without a question. The rest goes to Jev under a FIXED rubric. The receipt holds the facts' sha256, and
`verify` recomputes them at launch, so a receipt survives only as long as every fact it was judged on.

NOT COMPUTED: whether a changed LINE is reached (only that a suite mapped to its file ran), and any branch no rig
subject can reach. A file on disk can still be forged; what this removes is the agent's wording and omissions.
"""
import argparse, hashlib, importlib.util, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ACCEPT = os.path.expanduser("~/qwt-accept")
OUTDIR = os.path.join(REPO, "scratchpad", "launch-readiness")
FLOOR = 0.70
SMOKE = "win11-clean"          # the driver's own cell smoke runs it alone before the matrix, and dies on a failure
# A suite that runs only after the matrix, runnable alone on a package before it. Add a row when a mapped suite has
# none: a path whose suites are all absent here and that the smoke does not cover blocks, and says so.
# THE PRECHECK HAS ITS OWN DIRECTORY. The driver's feature tests write <work>/<suite>.out and <work>/<suite>.d and move
# an earlier attempt's .d aside at launch (rel-45872740292: updater-component.d -> .d.attempt-20261126T185515Z-...), so
# evidence there is gone by the time `verify` runs again before plan cell 3.
PRECHECK = {
    "updater-component": {   # the driver's own invocation, with the paths under precheck/:
        # VM=win11de-uc PKG=<work>/dl/qwt-improved-setup FAMILY=win11de REPORTER=gweck LOG=<work>/precheck/updater-component.log \
        #   OUT=<work>/precheck/updater-component.d ./mgmt/harness/updater-component-test.sh 2>&1 | tee <work>/precheck/updater-component.out
        "out": "precheck/updater-component.out",
        "pass": r"VERDICT: PASS\b",
        "elog": "precheck/updater-component.d/agent.log",
    },
    "notify-errors-guest-test": {   # the driver's own invocation, with the paths under precheck/:
        # VM=win11-nfy PKG=<work>/dl/qwt-improved-setup OS_FAMILY=win11r LOG=<work>/precheck/notify-errors-guest-test.log \
        #   ./mgmt/harness/notify-errors-guest-test.sh 2>&1 | tee <work>/precheck/notify-errors-guest-test.out
        # It reads no product log of its own, so there is no pass log to scan: its verdict is its summary line alone.
        "out": "precheck/notify-errors-guest-test.out",
        "pass": r"=== notify-errors guest test: [1-9][0-9]* passed, 0 failed ===",
        "elog": None,
    },
}
E_LINE = re.compile(r"^\W*\[\d{8}\.\d{6}\.\d{3}-[0-9:]+-E\]")
OPEN_RE = re.compile(r"\b(GAP|FIX OWED|fix not started|NOT FIXED|OPEN)\b")
CLOSED_RE = re.compile(r"\b(FIX-LANDED|CLOSED|RETIRED|RETRACTED)\b")
OWNER_RE = re.compile(r"\b[Oo]wner\b|owner-ordered|«")
# WHAT BLOCKS IS THE OWNER'S RULE, quoted (2026-11-26): «only unaddressed owner orders block. defects don't (unless those
# are newly introduced or recurring defects caused by your previous action)».
RUBRIC = {"launch_ready": {
    "type": "choice",
    "question": "On these computed facts, may this full acceptance campaign start now?",
    "instructions": {
        "judge": "Every line is computed by code from the plan, the diff, the scope map, the package's own work dir and "
                 "the findings files. Apply the owner's rule, verbatim: «only unaddressed owner orders block. defects "
                 "don't (unless those are newly introduced or recurring defects caused by your previous action)». An open "
                 "record blocks only when it carries an owner order that no listed commit carries out and the order does "
                 "not itself put the work after this campaign or cut, or when it is a defect that is new in this range "
                 "or that recurs because of a listed commit. A changed product path not covered on this package blocks.",
        "context": "A campaign costs about four hours of rig time and locks the owner's screen. `quotes-owner` and "
                   "`new-in-range` are computed: the first from the record's text, the second by whether the record's key "
                   "is absent from the same findings file at the range's base."},
    "criteria": {
        "ready_to_launch": "every changed product path is covered on this package, and no listed record is an unaddressed "
                           "owner order or a defect new in the range or recurring because of a listed commit",
        "blocked": "a listed record is an owner order no listed commit carries out and not deferred past this campaign, "
                   "or a defect new in the range or recurring because of a listed commit, or a coverage line shows the "
                   "changed code failing",
        "insufficient_evidence": "the facts do not carry enough to decide"},
    "confidence_floor": FLOOR}}


def die(msg, rc=2):
    print("LAUNCH-READINESS %s" % msg, file=sys.stderr)
    sys.exit(rc)


def git(*a, cwd=REPO):
    p = subprocess.run(["git", *a], cwd=cwd, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr.strip()


def _gate_scope():
    spec = importlib.util.spec_from_file_location("gate_scope", os.path.join(HERE, "gate-scope.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _plan(path):
    try:
        raw = open(path, "rb").read()
        plan = json.loads(raw)
    except Exception as e:
        die("BLOCKED the plan %s does not load: %s" % (path, e))
    run = next((m.group(1) for c in plan.get("cells", []) for m in [re.search(r"--run\s+(\d+)", c.get("command", ""))] if m), None)
    if not run:
        die("BLOCKED the plan %s names no --run in any cell" % path)
    return plan, raw, run


def _submodule_files(rng):
    """Files a gitlink move changed, prefixed by the submodule path, and the gitlink paths themselves; a move this
    checkout cannot resolve is a fact."""
    out, notes, links = [], [], set()
    _, raw, _ = git("diff", "--raw", rng)
    for line in raw.splitlines():
        f = line.split()
        if len(f) >= 6 and f[0] == ":160000" and f[1] == "160000":
            old, new, sub = f[2], f[3], f[5]
            links.add(sub)
            rc, names, err = git("diff", "--name-only", old, new, cwd=os.path.join(REPO, sub))
            if rc == 0:
                out += ["%s/%s" % (sub, n) for n in names.split() if n]
                if not names.strip():
                    notes.append("%s %s..%s: the two trees are identical" % (sub, old[:8], new[:8]))
            else:
                notes.append("%s %s..%s: its files are not listed here (%s)" % (sub, old[:8], new[:8], err[:120]))
    return out, notes, links


def coverage_line(path, suites, work, run):
    """(text, ok) for one changed product path."""
    if suites is None or "full" in suites or SMOKE in suites:
        return "covered by the driver's pre-matrix cell smoke (%s)" % SMOKE, True
    for s in suites:
        p = PRECHECK.get(s)
        if not p:
            continue
        out = os.path.join(work, p["out"])
        elog = os.path.join(work, p["elog"]) if p["elog"] else None
        if not os.path.exists(out):
            return "NOT COVERED: precheck %s has no output at %s" % (s, out), False
        text = open(out, errors="replace").read()
        pkg = "rel-%s/dl/qwt-improved-setup" % run
        if pkg not in text:
            return "NOT COVERED: precheck %s output %s does not name this package (%s)" % (s, out, pkg), False
        if not re.search(p["pass"], text):
            return "FAILED: precheck %s output %s has no line matching /%s/" % (s, out, p["pass"]), False
        if elog is None:
            return "covered by precheck %s on this package: %s matches /%s/ (it reads no product log; none scanned)" % (
                s, out, p["pass"]), True
        if not os.path.exists(elog):
            return "NOT COVERED: precheck %s has no pass log at %s" % (s, elog), False
        el = [l.strip()[:200] for l in open(elog, errors="replace") if E_LINE.match(l)]
        if el:
            return "FAILED: precheck %s passed but its pass log %s holds %d ERROR line(s), first: %s" % (s, elog, len(el), el[0]), False
        return "covered by precheck %s on this package: %s matches /%s/, %s holds 0 ERROR lines (sha256 %s)" % (
            s, out, p["pass"], elog, hashlib.sha256(open(elog, "rb").read()).hexdigest()[:16]), True
    return "NOT COVERED: none of %s runs before the matrix and none has a standalone precheck in PRECHECK" % suites, False


def open_records(changed, base):
    """Top-level findings bullets naming a changed product file, with an open marker and no closing marker; each says
    whether it quotes the owner and whether its key is absent from that findings file at `base`."""
    _, ls, _ = git("ls-files")
    base_n = {}
    for f in ls.split():
        b = os.path.basename(f)
        base_n[b] = base_n.get(b, 0) + 1
    keys = sorted({c for c in changed} | {os.path.basename(c) for c in changed if base_n.get(os.path.basename(c)) == 1})
    hits = []
    fdir = os.path.join(REPO, "findings")
    for name in sorted(os.listdir(fdir)):
        if not name.endswith(".md") or name == "issues-closed.md":      # the closed register holds nothing open
            continue
        _, then, _ = git("show", "%s:findings/%s" % (base, name))
        for i, line in enumerate(open(os.path.join(fdir, name), errors="replace"), 1):
            if not line.startswith("- ") or not OPEN_RE.search(line) or CLOSED_RE.search(line):
                continue
            named = [k for k in keys if k in line]
            if named:
                t = line.rstrip()
                m = re.match(r"- (?:\*\*)?([A-Z0-9]{8,})\b", t)                 # a register id, else the opening words
                key = m.group(1) if m else t[2:80]
                # THE OWNER'S WORDS PAST THE CUT, with 200 characters either side, overlapping windows merged. The
                # rubric asks whether a record carries an owner order a listed commit leaves undone, and the 400-char
                # cut hid exactly that: on 2026-11-28 the four quotes-owner records read "the owner's capture" (a
                # window), "by the owner's hand", "owner's call" and an order the same record says holds - every
                # word of which was past the cut, and Jev called each a coin toss.
                spans = []
                for mm in OWNER_RE.finditer(t, 400):
                    a, b = max(0, mm.start() - 200), mm.end() + 200
                    if spans and a <= spans[-1][1]:
                        spans[-1][1] = b
                    else:
                        spans.append([a, b])
                past = " [owner words past the cut: %s]" % " | ".join(t[a:b] for a, b in spans) if spans else ""
                hits.append("findings/%s:%d [names %s] [quotes-owner %s] [new-in-range %s]: %s%s%s" % (
                    name, i, ", ".join(named), "yes" if OWNER_RE.search(t) else "no", "no" if key in then else "yes",
                    t[:400], " [+%d chars]" % (len(t) - 400) if len(t) > 400 else "", past))
    return hits


FIXSHA_RE = re.compile(r"\b(?:FIX-LANDED|FIX|[Ff]ixed in)\s+(?:(agent|winutils)\s+)?([0-9a-f]{7,40})\b")


def included_fixes(build, gs, m):
    """Owner 2026-11-26: «existing fixes MUST be included, not deferred». Decidable, so it blocks in code: a product commit
    on main after the package's build, or a fix a findings record cites by commit that the build (or its submodule
    pointer) does not contain. A cited sha this checkout cannot resolve is listed, not blocked."""
    lines, misses = [], []
    _, out, _ = git("diff", "--name-only", "%s..main" % build)
    ahead = [f for f in out.split() if gs.match(f, m)[0] != []]
    if ahead:
        _, log, _ = git("log", "--format=%h %s", "%s..main" % build, "--", *ahead)
        misses += ["main carries product commit %s after the package's build %s" % (l, build[:8]) for l in log.splitlines()]
    pointer = {s: git("rev-parse", "%s:%s" % (build, s))[1].strip() for s in ("agent", "winutils")}
    cited = {}
    fdir = os.path.join(REPO, "findings")
    for name in sorted(os.listdir(fdir)):
        if name.endswith(".md"):
            for i, line in enumerate(open(os.path.join(fdir, name), errors="replace"), 1):
                for sub, sha in FIXSHA_RE.findall(line):
                    cited.setdefault((sub, sha), "findings/%s:%d" % (name, i))
    held = 0
    for (sub, sha), where in sorted(cited.items()):
        # A record often cites a submodule commit bare (findings/install.md:44: "fixed in 71fa0a4", an agent commit), so a
        # bare sha is held when the build OR either submodule pointer contains it.
        homes = [(os.path.join(REPO, sub), pointer[sub], sub + " pointer")] if sub else \
                [(REPO, build, "build")] + [(os.path.join(REPO, s), pointer[s], s + " pointer") for s in ("agent", "winutils")]
        label = ("%s %s" % (sub, sha)) if sub else sha
        known = [h for h in homes if git("cat-file", "-e", sha + "^{commit}", cwd=h[0])[0] == 0]
        if not known:
            lines.append("  unresolvable here: fix %s cited at %s" % (label, where))
        elif any(git("merge-base", "--is-ancestor", sha, h[1], cwd=h[0])[0] == 0 for h in known):
            held += 1
        else:
            misses.append("fix %s cited at %s is not in the package (%s)" % (label, where, ", ".join("%s %s" % (h[2], h[1][:8]) for h in known)))
    lines.insert(0, "  %d fix commit(s) cited in findings/*.md are in the package; %d product commit(s) on main are not" % (held, len(ahead and log.splitlines())))
    return lines, misses


def build_facts(plan_path):
    plan, raw, run = _plan(plan_path)
    gs = _gate_scope()
    m = gs.load_map()
    rng = plan.get("range") or ""
    work = os.path.join(ACCEPT, "rel-%s" % run)
    files = gs.changed_files(rng)
    sub_files, sub_notes, links = _submodule_files(rng)
    product, harness, blocks, cov = [], 0, [], []
    for f in sorted(set(files) | set(sub_files)):
        suites, _ = gs.match(f, m)
        if suites == []:
            harness += 1
            continue
        product.append(f)
        text, ok = coverage_line(f, suites, work, run)
        cov.append("  %s -> suites=%s: %s" % (f, ",".join(suites) if suites is not None else "UNMAPPED", text))
        if not ok:
            blocks.append("%s: %s" % (f, text))
    if plan.get("ready") is not True:
        blocks.insert(0, "the plan says ready=%s blocked=%s" % (plan.get("ready"), json.dumps(plan.get("blocked"))))
    _, log, _ = git("log", "--format=%h %s", rng, "--", *[p for p in product if p in files] or ["."])
    recs = open_records([p for p in product if p not in links], rng.split("..")[0])   # a gitlink names no file
    fix_lines, fix_misses = included_fixes(plan.get("build") or rng.split("..")[-1], gs, m)
    blocks += fix_misses
    lines = ["LAUNCH-READINESS FACTS - every line computed by tools/launch-readiness.py; none is written by hand",
             "PLAN: %s sha256=%s range=%s package_run=%s ready=%s blocked=%s" % (
                 os.path.relpath(plan_path, REPO), hashlib.sha256(raw).hexdigest(), rng, run, plan.get("ready"),
                 json.dumps(plan.get("blocked"))),
             "CHANGED PRODUCT PATHS (%d, mapped by mgmt/gate-scope.json; %d harness-only paths not listed):" % (len(product), harness)]
    lines += cov or ["  none"]
    lines += ["  submodule: %s" % n for n in sub_notes]
    lines += ["PRODUCT COMMITS IN THE RANGE:"] + (["  " + l for l in log.splitlines()] or ["  none"])
    lines += ["OPEN RECORDS NAMING A CHANGED PRODUCT FILE (%d; findings/*.md top-level bullets with /%s/ and no /%s/):" % (
        len(recs), OPEN_RE.pattern, CLOSED_RE.pattern)] + (["  " + r for r in recs] or ["  none"])
    _, tags, _ = git("tag", "--sort=-creatordate", "--format=%(refname:short) %(creatordate:short)", "--list", "v*")
    lines += ["RELEASES CUT, newest first (an order put \"after this cut\" falls due at the next one):"] + \
             ["  " + t for t in tags.splitlines()[:3]]
    lines += ["EXISTING FIXES (owner: «existing fixes MUST be included, not deferred»; a miss blocks in code):"] + fix_lines
    lines += ["  MISSING: " + x for x in fix_misses]
    lines += ["NOT COMPUTED: whether a changed LINE is reached by a suite, only that a suite mapped to its file ran; "
              "any branch no rig subject can reach."]
    return "\n".join(lines) + "\n", blocks, run


def ask_jev(facts, run):
    os.makedirs(OUTDIR, exist_ok=True)
    rub, st, out = (os.path.join(OUTDIR, "%s-%s" % (run, s)) for s in ("rubric.json", "facts.txt", "jev.json"))
    json.dump(RUBRIC, open(rub, "w"), indent=1)
    open(st, "w").write(facts)
    env = dict(os.environ)
    env.setdefault("JEV_WIRE_LOG", os.path.join(REPO, "scratchpad", "jev-wire.jsonl"))
    p = subprocess.run([sys.executable, os.path.join(HERE, "jev.py"), rub, st, "--out", out], env=env, capture_output=True, text=True)
    print(p.stdout.strip())
    if p.returncode != 0:
        die("BLOCKED jev.py exited %d - the instrument did not run, which is never a verdict: %s" % (p.returncode, p.stderr.strip()[-300:]))
    a = json.load(open(out))["answers"]["launch_ready"]
    return a.get("choice"), float(a.get("confidence") or 0)


def cmd_check(plan_path):
    facts, blocks, run = build_facts(plan_path)
    sys.stdout.write(facts)
    if blocks:
        for b in blocks:
            print("BLOCKED %s" % b)
        die("BLOCKED %d decidable failure(s) - nothing was asked of Jev; no receipt" % len(blocks), 1)
    choice, conf = ask_jev(facts, run)
    rec = {"run": run, "plan": os.path.abspath(plan_path), "facts_sha256": hashlib.sha256(facts.encode()).hexdigest(),
           "choice": choice, "confidence": conf, "floor": FLOOR}
    json.dump(rec, open(os.path.join(OUTDIR, "%s.json" % run), "w"), indent=1)
    if choice != "ready_to_launch" or conf < FLOOR:
        die("BLOCKED Jev: %s at %.2f (floor %.2f) - the receipt records it and verify refuses it" % (choice, conf, FLOOR), 1)
    print("LAUNCH-READINESS READY run %s: Jev ready_to_launch %.2f; receipt %s" % (run, conf, os.path.join(OUTDIR, "%s.json" % run)))
    return 0


def cmd_verify(run):
    path = os.path.join(OUTDIR, "%s.json" % run)
    if not os.path.exists(path):
        die("BLOCKED no readiness receipt for package run %s. Run: tools/launch-readiness.py check --plan <its plan>" % run)
    rec = json.load(open(path))
    if rec.get("choice") != "ready_to_launch" or float(rec.get("confidence") or 0) < FLOOR:
        die("BLOCKED the readiness receipt for %s says %s at %s (floor %.2f)" % (run, rec.get("choice"), rec.get("confidence"), FLOOR))
    facts, blocks, prun = build_facts(rec["plan"])
    if prun != run:
        die("BLOCKED the receipt's plan is for package run %s, not %s" % (prun, run))
    if blocks or hashlib.sha256(facts.encode()).hexdigest() != rec.get("facts_sha256"):
        die("BLOCKED the facts changed since Jev judged them (%d decidable failure(s) now). Re-run: tools/launch-readiness.py "
            "check --plan %s" % (len(blocks), rec["plan"]))
    print("LAUNCH-READINESS VERIFIED run %s: the facts Jev judged ready (%.2f) still hold" % (run, rec["confidence"]))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("mode", choices=["check", "verify", "facts"])
    ap.add_argument("--plan")
    ap.add_argument("--run")
    a = ap.parse_args()
    if a.mode == "verify":
        return cmd_verify(a.run or die("verify needs --run"))
    if not a.plan:
        die("%s needs --plan" % a.mode)
    if a.mode == "facts":
        facts, blocks, _ = build_facts(a.plan)
        sys.stdout.write(facts + "".join("BLOCKED %s\n" % b for b in blocks))
        return 1 if blocks else 0
    return cmd_check(a.plan)


if __name__ == "__main__":
    sys.exit(main())
