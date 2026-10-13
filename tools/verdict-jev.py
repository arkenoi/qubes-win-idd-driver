#!/usr/bin/env python3
"""verdict-jev.py - EVERY ERROR IS EVALUATED (PLAN-acceptance-optimization section 5): the complete set of error
signatures from a run plus its activity snapshot go to Jev under one fixed rubric, and the answer decides whether an
expensive model is needed at all.

    tools/verdict-jev.py --sweep <report.json>... --snapshot <activity-snapshot.json> [--errors <file>]...
                         [--declare-error <regex> <why>]... [--hints <file>] [--out verdict.json]
                         [--label <s>] [--jev-cmd <cmd>] [--jev-max N] [--confidence-floor F]

WHAT GOES IN - the COMPLETE set, no pre-filter by known failure class:
  * every breach, NEW, ROSE and out-of-context item of each log-sweep report (tools/log-sweep.py's own verdict on
    each travels as context, never as a filter);
  * every E/W-level signature of the report whatever its baseline status (known-defect, expected, unsettled...),
    and every known-defect-present entry - a catalogued class is a HINT, it never suppresses an item;
  * every non-empty line of each --errors file (the harness's own FAIL/ERROR lines);
  * the activity snapshot (mgmt/harness/collect-failure.sh's activity-snapshot.json): power state, liveness, the
    last qrexec pair, the last window event, clock skew, the power timeline, the harness command, each module's tail.
THE SOLE EXEMPTION: --declare-error <regex> <why> names a stimulus the run caused on purpose; an item it matches is
recorded as declared with that text and is not sent to the judge (Jev 2026-10-13 declared_items_sent_to_jev =
exempt-not-sent 0.53 vs insufficient-evidence 0.41 - a LOW-confidence verdict, so declared items are kept verbatim
in verdict.json for a reader to overrule). A declaration that matches NOTHING fails the run: it is a stimulus that
did not happen, or a standing allowlist, and neither is allowed.

THE RUBRIC, fixed: per item a choice known-class / novel / insufficient-evidence against the KNOWN-CLASS CATALOGUE
(the issue register's tags in findings/issues.md plus the sweep baseline's known-defect patterns - optional context
only), and one overall noul "does any item need further analysis?". Code derives the same overall from the per-item
answers (any novel, any insufficient-evidence, any known-class under --confidence-floor) and the final answer is the
OR of the two - the judge's overall can only ADD a reason to look, never remove one.

EXIT CODES: 0 no item needs further analysis (every item known-class at or above the floor, the judge's overall
agrees); 1 further analysis needed (Claude is invoked on the items named in verdict.json); 2 the instrument did not
run - jev.py exited 2, an input is unreadable, or a sweep report says DATA/INCOMPLETE (never a pass); 3 a declaration
matched nothing (the run fails). The last line is always:
    VERDICT label=<s> rc=<n> items=<n> known=<n> novel=<n> insufficient=<n> declared=<n> needs_analysis=<0|1>
Jev's wire log (tools/jev.py) is the receipt. Self-test: tools/tests/verdict-jev-selftest.sh.
"""
from __future__ import annotations
import argparse, json, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TAG_RE = re.compile(r"^- ([A-Z][A-Z0-9-]{3,}) \[([^\]]*)\] (?:\[verified [^\]]*\] )?\**(.{0,160})")
CRITERIA = {"known-class": "the evidence is an instance of a class in the KNOWN-CLASS CATALOGUE by MECHANISM (the same component, "
                           "the same failure shape, the same chain), not merely by a shared word",
            "novel": "no catalogued class accounts for this evidence",
            "insufficient-evidence": "the facts under this item cannot settle it"}


def die(msg: str, rc: int = 2) -> int:
    print("INSTRUMENT: " + msg)
    return rc


def load_json(path: str):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def issue_register_hints(path: str) -> list[dict]:
    out = []
    try:
        for ln in open(path, encoding="utf-8", errors="replace"):
            m = TAG_RE.match(ln)
            if m:
                out.append({"tag": m.group(1), "scope": m.group(2), "title": m.group(3).strip().rstrip("*")})
    except OSError:
        pass
    return out


def baseline_hints(reports: list[dict]) -> list[dict]:
    out, seen = [], set()
    for r in reports:
        for s in (r.get("signatures") or {}).values():
            b = s.get("baseline") or {}
            if b.get("status") == "known-defect" and b.get("issue") and b["issue"] not in seen:
                seen.add(b["issue"])
                out.append({"tag": b["issue"], "scope": "sweep baseline known-defect", "title": (b.get("reason") or "")[:160]})
    return out


def sig_item(kind: str, s: dict, src: str) -> dict:
    b = s.get("baseline") or {}
    return {"kind": kind, "source": src, "key": s.get("key", ""), "family": s.get("family"), "level": s.get("level"),
            "count": s.get("count"), "max_per_boot": s.get("max_per_boot"), "first": s.get("first"), "last": s.get("last"),
            "examples": (s.get("examples") or [])[:3], "context": (s.get("context") or [])[:3],
            "hint": {"baseline_status": b.get("status"), "issue": b.get("issue"), "reason": (b.get("reason") or "")[:200]} if b else None,
            "sweep_jev": s.get("jev")}


def collect_items(reports: list[tuple[str, dict]], error_files: list[str]) -> tuple[list[dict], list[str]]:
    items: list[dict] = []
    seen: set[str] = set()
    problems: list[str] = []

    def add(it: dict) -> None:
        # ONE item per signature: a NEW signature is also in the report's full signature table, and a breach's
        # metric name never collides with a signature key - so the key alone is the identity.
        k = it["key"]
        if k in seen:
            return
        seen.add(k)
        it["id"] = "i%03d" % (len(items) + 1)
        items.append(it)

    for src, r in reports:
        st = r.get("status")
        if st in ("DATA", "INCOMPLETE"):
            problems.append("%s: sweep status %s (rc %s) - the set is not complete, nothing here can be judged complete" % (src, st, r.get("rc")))
        judged = set(r.get("judged_defects") or [])
        for b in r.get("breaches") or []:
            add({"kind": "breach", "source": src, "key": b.get("metric", ""), "value": b.get("value"), "max": b.get("max"),
                 "severity": b.get("severity"), "why": b.get("why"), "sweep_jev": b.get("jev"), "hint": None,
                 "examples": [], "context": []})
        for kind in ("new", "rose", "out_of_context"):
            for s in r.get(kind) or []:
                add(sig_item(kind, s, src))
        for s in r.get("known_defects_present") or []:
            if isinstance(s, dict):
                add(sig_item("known-defect-present", s, src))
        # EVERY E/W signature, whatever the baseline says: a catalogued class is a hint, not a filter.
        for key, s in (r.get("signatures") or {}).items():   # GUARD:prefilter DEFECT: for key, s in {k: v for k, v in (r.get("signatures") or {}).items() if not (v.get("baseline") or {}).get("status")}.items():
            if s.get("level") in ("E", "W"):
                s = dict(s); s.setdefault("key", key)
                add(sig_item("signature", s, src))
        for it in items:
            if it["source"] == src and ("%s" % it.get("sweep_id", "")) in judged:
                it["sweep_judged_defect"] = True
    for ef in error_files:
        try:
            for n, ln in enumerate(open(ef, encoding="utf-8", errors="replace"), 1):
                ln = ln.rstrip("\r\n")
                if ln.strip():
                    add({"kind": "harness-error", "source": "%s:%d" % (os.path.basename(ef), n), "key": ln[:400],
                         "examples": [], "context": [], "hint": None})
        except OSError as e:
            problems.append("errors file unreadable: %s (%s)" % (ef, e))
    return items, problems


def apply_declarations(items: list[dict], decls: list[tuple[str, str]]) -> list[dict]:
    out = []
    for pat, why in decls:
        try:
            rx = re.compile(pat)
        except re.error as e:
            out.append({"pattern": pat, "why": why, "matched": 0, "error": str(e)})
            continue
        n = 0
        for it in items:
            if it.get("declared"):
                continue
            hay = [it["key"]] + list(it.get("examples") or []) + [str(it.get("why") or "")]
            if any(rx.search(h) for h in hay):
                it["declared"] = why
                n += 1
        out.append({"pattern": pat, "why": why, "matched": n})
    return out


def snapshot_text(s: dict) -> list[str]:
    L = ["ACTIVITY SNAPSHOT (mgmt/harness/collect-failure.sh): vm=%s reason=%s power_state=%s" % (s.get("vm"), s.get("reason"), s.get("power_state_at_collection"))]
    L.append("  harness command (%s): %s" % ((s.get("harness_cmd") or {}).get("source"), (s.get("harness_cmd") or {}).get("cmd")))
    q = s.get("last_qrexec_pair")
    if q:
        L.append("  last qrexec pair: request %s %s -> outcome %s" % (q.get("request_ts"), q.get("request"), (q.get("outcome") or {}).get("line")))
    else:
        L.append("  last qrexec pair: NONE in any log")
    w = s.get("last_window")
    L.append("  last window/focus: %s" % (w.get("line") if w else "NONE in any gui-agent log"))
    c = s.get("clock_skew")
    L.append("  clock skew: %s" % ("%s s (guest %s)" % (c.get("skew_s"), c.get("guest_utc")) if c else "NOT MEASURED"))
    L.append("  power timeline: " + "; ".join("%s %s (%s)" % (t.get("utc"), t.get("state"), t.get("source")) for t in (s.get("power_timeline") or [])[-12:]))
    for name, m in sorted((s.get("module_logs") or {}).items()):
        L.append("  module %s (%s, %s lines, last %s):" % (name, m.get("family"), m.get("lines"), m.get("last_ts")))
        for ln in (m.get("tail") or [])[-6:]:
            L.append("      " + ln[:300])
    if s.get("missing"):
        L.append("  snapshot fields MISSING: " + "; ".join(s["missing"]))
    return L


def item_text(it: dict) -> list[str]:
    L = ["=== ITEM %s (%s from %s) ===" % (it["id"], it["kind"], it["source"])]
    if it["kind"] == "breach":
        L.append("metric %s = %s, threshold max %s, severity %s. Rule: %s" % (it["key"], it.get("value"), it.get("max"), it.get("severity"), it.get("why")))
    elif it["kind"] == "harness-error":
        L.append("harness line: " + it["key"])
    else:
        L.append("family=%s level=%s count=%s max_per_boot=%s first=%s last=%s" % (it.get("family"), it.get("level"), it.get("count"), it.get("max_per_boot"), it.get("first"), it.get("last")))
        L.append("signature: " + it["key"])
    h = it.get("hint")
    if h:
        L.append("hint (context only, never a filter): baseline status=%s issue=%s reason=%s" % (h.get("baseline_status"), h.get("issue"), h.get("reason")))
    sj = it.get("sweep_jev")
    if sj:
        L.append("the sweep's own judge said: %s (confidence %s) - context, not a verdict here" % (sj.get("choice"), sj.get("confidence")))
    for e in it.get("examples") or []:
        L.append("  example: " + str(e)[:300])
    for c in it.get("context") or []:
        L.append("  context: " + str(c)[:300])
    return L


def state_text(label: str, items: list[dict], snap: dict, hints: list[dict]) -> str:
    L = ["RUN %s. Every item below is an error signature, breach or harness error line from this run; the judge decides for each "
         "whether it is an instance of a catalogued failure class, novel, or undecidable. A catalogued class is context only: an item "
         "is never dropped for matching one, and matching a WORD is not matching a class." % label, ""]
    L += snapshot_text(snap)
    L.append("")
    L.append("KNOWN-CLASS CATALOGUE (%d entries; the issue register's tags and the sweep baseline's known defects):" % len(hints))
    for h in hints:
        L.append("  %s [%s] %s" % (h["tag"], h["scope"], h["title"]))
    L.append("")
    for it in items:
        L += item_text(it)
        L.append("")
    return "\n".join(L)


def rubric(items: list[dict], with_overall: bool) -> dict:
    q = {}
    for it in items:
        q[it["id"]] = {"type": "choice",
                       "instructions": {"judge": "Item %s (%s): from the state under 'ITEM %s' and the KNOWN-CLASS CATALOGUE only - is this an instance of a catalogued class, novel, or undecidable?" % (it["id"], it["kind"], it["id"])},
                       "criteria": dict(CRITERIA)}
    if with_overall:
        q["needs_further_analysis"] = {"type": "noul",
                                       "instructions": {"judge": "Considering every item and the activity snapshot: does ANY item need further analysis by a person or an expensive model - a novel item, an undecidable one, or a catalogued-class item whose evidence here differs from its catalogue entry or whose class is still open?"},
                                       "criteria": {"true": "at least one item needs further analysis", "false": "every item is a settled instance of a catalogued class and nothing in the snapshot contradicts that"}}
    return {"questions": q}


def run_jev(items: list[dict], snap: dict, hints: list[dict], label: str, workdir: str, jev_cmd: list[str], chunk: int):
    os.makedirs(workdir, exist_ok=True)
    answers: dict = {}
    calls: list[dict] = []
    queue = [items[i:i + chunk] for i in range(0, len(items), chunk)] or [[]]
    first = True
    while queue:
        part = queue.pop(0)
        n = len(calls) + 1
        rub = rubric(part, with_overall=first)
        rp, sp, ap = (os.path.join(workdir, "jev-%s-%d.%s" % (k, n, ext)) for k, ext in (("rubric", "json"), ("state", "txt"), ("answers", "json")))
        json.dump(rub, open(rp, "w", encoding="utf-8"), indent=1)
        open(sp, "w", encoding="utf-8").write(state_text(label, part if part else items, snap, hints))
        t0 = time.time()
        try:
            p = subprocess.run(jev_cmd + [rp, sp, "--out", ap], capture_output=True, text=True, timeout=900)
            rc, out = p.returncode, (p.stdout + p.stderr)[-4000:]
        except Exception as e:
            rc, out = 2, "%s: %s" % (type(e).__name__, e)
        calls.append({"rubric": rp, "state": sp, "answers": ap, "questions": len(rub["questions"]), "rc": rc, "seconds": round(time.time() - t0, 1), "tail": out[-1500:]})
        if rc != 0:
            if "max_tokens_exceeded" in out and len(part) > 1:
                half = len(part) // 2
                queue[0:0] = [part[:half], part[half:]]
                calls[-1]["split"] = True
                continue
            return answers, calls, rc, "jev.py exited %s on call %d: %s" % (rc, n, out.strip().splitlines()[-1] if out.strip() else "no output")
        try:
            a = json.load(open(ap, encoding="utf-8")).get("answers", {})
        except (OSError, ValueError) as e:
            return answers, calls, 2, "jev answers unreadable: %s" % e
        for qid in rub["questions"]:
            if qid not in a:
                return answers, calls, 2, "no answer for %s" % qid
            answers[qid] = a[qid]
        first = False
    return answers, calls, 0, None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sweep", action="append", default=[], help="a log-sweep report.json (repeatable)")
    ap.add_argument("--snapshot", required=True, help="the collector's activity-snapshot.json")
    ap.add_argument("--errors", action="append", default=[], help="a file of harness error lines, one per line (repeatable)")
    ap.add_argument("--declare-error", nargs=2, action="append", default=[], metavar=("REGEX", "WHY"))
    ap.add_argument("--hints", help="a JSON list of {tag,scope,title} (default: findings/issues.md tags + baseline known-defects)")
    ap.add_argument("--out", default="verdict.json")
    ap.add_argument("--label", default="run")
    ap.add_argument("--jev-cmd", help="override the judge command (tests use a stub)")
    ap.add_argument("--jev-max", type=int, default=25)
    ap.add_argument("--confidence-floor", type=float, default=0.6)
    ap.add_argument("--workdir")
    a = ap.parse_args(argv)
    if not a.sweep and not a.errors:
        return die("nothing to judge was given (no --sweep and no --errors)")
    reports: list[tuple[str, dict]] = []
    for p in a.sweep:
        try:
            reports.append((os.path.basename(os.path.dirname(os.path.abspath(p))) + "/" + os.path.basename(p), load_json(p)))
        except (OSError, ValueError) as e:
            return die("sweep report unreadable: %s (%s)" % (p, e))
    try:
        snap = load_json(a.snapshot)
    except (OSError, ValueError) as e:
        return die("activity snapshot unreadable: %s (%s) - the set is not complete without it" % (a.snapshot, e))
    if a.hints:
        try:
            hints = load_json(a.hints)
        except (OSError, ValueError) as e:
            return die("hints unreadable: %s (%s)" % (a.hints, e))
    else:
        hints = issue_register_hints(os.path.join(ROOT, "findings", "issues.md")) + baseline_hints([r for _, r in reports])
    items, problems = collect_items(reports, a.errors)
    decls = apply_declarations(items, [(p, w) for p, w in a.declare_error])
    workdir = a.workdir or os.path.join(os.path.dirname(os.path.abspath(a.out)), "verdict-work")
    verdict = {"version": 1, "label": a.label, "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "inputs": {"sweeps": a.sweep, "snapshot": a.snapshot, "errors": a.errors, "hints": len(hints)},
               "sweep_status": [{"source": s, "status": r.get("status"), "rc": r.get("rc")} for s, r in reports],
               "problems": problems, "declarations": decls, "items": items, "counts": {}, "overall": {}, "jev": {}, "rc": None}

    def finish(rc: int, why: str) -> int:
        verdict["rc"] = rc
        verdict["why"] = why
        c = verdict["counts"]
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        json.dump(verdict, open(a.out, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
        print("VERDICT label=%s rc=%d items=%d known=%d novel=%d insufficient=%d declared=%d needs_analysis=%d  %s" % (
            a.label, rc, len(items), c.get("known-class", 0), c.get("novel", 0), c.get("insufficient-evidence", 0),
            c.get("declared", 0), 1 if verdict["overall"].get("needs_further_analysis") else 0, why))
        return rc

    counts = {"declared": sum(1 for it in items if it.get("declared"))}
    verdict["counts"] = counts
    unmatched = [d for d in decls if d["matched"] == 0]
    if problems:   # GUARD:dataispass DEFECT: if False:
        return finish(2, "instrument: " + "; ".join(problems))
    if unmatched:   # GUARD:declunmatched DEFECT: if False:
        return finish(3, "declaration matched nothing: " + "; ".join("%r (%s)" % (d["pattern"], d["why"]) for d in unmatched))
    judge = [it for it in items if not it.get("declared")]
    if not judge:
        verdict["overall"] = {"needs_further_analysis": False, "code_says": False, "jev_noul": None, "reason": "no item to judge"}
        verdict["jev"] = {"calls": [], "rc": 0, "note": "not called: nothing to judge"}
        return finish(0, "no item to judge")
    jev_cmd = a.jev_cmd.split() if a.jev_cmd else [sys.executable, os.path.join(ROOT, "tools", "jev.py")]
    answers, calls, jrc, jreason = run_jev(judge, snap, hints, a.label, workdir, jev_cmd, a.jev_max)
    verdict["jev"] = {"calls": calls, "rc": jrc, "reason": jreason, "questions": sum(c["questions"] for c in calls)}
    if jrc != 0:   # GUARD:jev2 DEFECT: if False:
        return finish(2, "the judge did not run: %s" % jreason)
    need_code = False
    for it in judge:
        ans = answers.get(it["id"]) or {}
        it["jev"] = {"choice": ans.get("choice"), "confidence": ans.get("confidence"), "probabilities": ans.get("probabilities")}
        ch = ans.get("choice")
        counts[ch] = counts.get(ch, 0) + 1
        low = ch == "known-class" and (ans.get("confidence") or 0) < a.confidence_floor   # GUARD:conffloor DEFECT: low = False
        it["needs_analysis"] = ch in ("novel", "insufficient-evidence") or low
        if low:
            it["needs_analysis_why"] = "known-class below the confidence floor %.2f" % a.confidence_floor
        need_code = need_code or it["needs_analysis"]
    noul = (answers.get("needs_further_analysis") or {}).get("noul")
    need_jev = noul is not None and noul >= 0.5
    need = need_code or need_jev   # GUARD:overallor DEFECT: need = need_code
    verdict["overall"] = {"needs_further_analysis": need, "code_says": need_code, "jev_noul": noul,
                          "items_needing_analysis": [it["id"] for it in judge if it.get("needs_analysis")]}
    return finish(1 if need else 0, "further analysis needed" if need else "every item is a settled known class")


if __name__ == "__main__":
    sys.exit(main())
