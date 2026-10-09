#!/usr/bin/env python3
"""prose-audit.py - classify every unit of a prose file with Jev, in code, for a few thousand tokens.

WHY THIS IS A SCRIPT. The first attempt at this job was a 43-agent workflow: 14 topic buckets x
(assess -> rewrite -> verify) + synthesis. Measured when the owner asked where the money went:
754,144 tokens sent to Jev as state across 46 calls, and ~1.69M tokens of agents RE-READING the same
2.25 MB corpus three times, because each stage read the originals from disk. It was stopped at 6 of
14 buckets with 0 rewrites.

Owner, 2026-10-08: "why does feeding to jev require complex LLM in the loop? rewrite, yes, but the
rest?" and then "you do not need fable to RUN it, it is a script and it should conserve tokens". He
is right, and the rule was already on the books from a previous 1.5M-token incident: "differentials
are code, not agents - counting/matching goes in a script + ONE Jev call". Splitting markdown into
units, templating a rubric, batching, calling jev.py, diffing a rewrite and formatting a report are
all deterministic. Only WRITING the compacted prose needs a model.

THE DESIGN WAS PUT TO JEV BEFORE IT WAS BUILT, with the case against it in the state:
    design_choice = D2-script-plus-llm-verify-for-high-stakes 0.88 (conf 0.85)
                    - the fully-scripted variant proposed first scored 0.03
    splitter_risk_is_real          0.79   -> units never split mid-paragraph; context travels with them
    script_verification_sufficient 0.19   -> script verification ALONE is not enough; high-stakes
                                            files get a model verifier, and unmatched units escalate
    worst_thing_lost = gap-closing-re-ask 0.64 -> the re-ask loop is implemented HERE, in code
    prohibition_wording = forbid-when-computable 1.00 (conf 1.00)

WHICH STAGES ARE CODE AND WHICH NEED A MODEL
    split / batch / template / call / merge / diff / report   CODE      (this file)
    classify each unit, judge a whole file                    JEV       (the judgment instrument)
    WRITE the compacted prose                                 MODEL     (the caller, per file)
    re-read a high-stakes rewrite against its original        MODEL     (Jev's 0.19 demands it)
Nothing else gets a model. A step whose output a script can produce deterministically may not be
given to one.

TWO MODES, BUCKETED BY STAKES - because a 184 KB register of closed issues is one question, not 400:
    --mode units    every unit classified, with neighbour context and the re-ask loop.
                    For CLAUDE.md, findings/rules.md, the skills, the ADRs, the open register.
    --mode triage   ONE question per file (keep / compact / delete) from its outline, head and size,
                    batched many files per call. For release notes, spent research docs, closed
                    registers. Promote a file to `units` when triage says compact rather than delete.

    tools/prose-audit.py plan --mode units  <file>... [--out DIR] [--conf-floor 0.55] [--skip-done]
    tools/prose-audit.py plan --mode triage <file>... [--out DIR] [--batch 12]
    tools/prose-audit.py verify <file> --rewrite <path> [--plan DIR]
    tools/prose-audit.py report [--out DIR]
    tools/prose-audit.py cost   [--out DIR]

Exit 0 = it ran. Exit 2 = the instrument did not run (no files, jev.py exit 2, unreadable input) -
never confused with "nothing to cut", which is a RESULT.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, "scratchpad", "prose-audit2")

# A chunk is bounded so one rubric never carries hundreds of questions and one state never carries a
# whole 269 KB register. Without this, findings/issues.md went into a single call and the judge was
# asked ~500 questions at once.
MAX_UNITS_PER_CALL = 35
MAX_BYTES_PER_CALL = 30000
REASK_CONTEXT_CAP = 40000   # whole-file context for a re-ask, above which the outline stands in
JEV_ATTEMPTS = 4            # a transient judge error is retried, never swallowed
JEV_BACKOFF = 8             # seconds, multiplied by the attempt number

# Files whose loss would cost a rule: these get a MODEL verifier as well (Jev: script verification
# alone 0.19). Everything else is verified by this script and escalation.
HIGH_STAKES = (
    "CLAUDE.md", "findings/rules.md", "findings/issues.md", "findings/issues-closed.md",
    ".claude/skills/", "docs/ADR-", "README.md",
)

IDENT_KEEP_WORDS = {
    # ALLCAPS words that ARE load-bearing in this repo and must still be checked
    "UNVERIFIED", "REPORTER", "CONFIRMED", "FIELD", "ACCEPTED", "REJECTED", "RETIRED",
    "WITHDRAWN", "PROPOSED", "FATAL", "TERMINAL", "INVALID", "SYSTEM", "DEFAULT",
}
IDENT_STOP_WORDS = {
    # ALLCAPS used for emphasis, not as a name. Dropping these is not a loss.
    "COURSE", "FUCKING", "CORRECTED", "RETRACTED", "RESOLVED", "SUPERSEDED", "FEASIBILITY",
    "MEASURED", "REALLY", "NEVER", "ALWAYS", "NOTHING", "EVERY", "BECAUSE", "WITHOUT",
    "ALREADY", "INSTEAD", "ACTUALLY", "EXACTLY", "SHOULD", "CANNOT", "UNLESS", "BEFORE",
    "AFTER", "DURING", "WHICH", "THERE", "THESE", "THOSE", "WHOLE", "ENTIRE", "SINGLE",
    "ANYTHING", "SOMETHING", "EVERYTHING", "ANOTHER", "FURTHER", "HOWEVER", "THEREFORE",
    "RECORD", "REASON", "CLOSED", "PARKED", "OPTIONAL", "REQUIRED", "STANDING", "BINDING",
    "PRISTINE", "SEALED", "SERIAL", "SERIALLY", "PUBLIC", "PRIVATE", "SECOND", "FIRST",
}


def real_identifier(tok):
    """Is this token a NAME (path, tag, constant, command) rather than a capitalised English word?"""
    t = tok.strip("`").strip()
    if len(t) <= 4:
        return False
    if any(c in t for c in "._-/\\=:" ) or any(c.isdigit() for c in t) or " " in t:
        return True
    if t.isupper():
        # DEFAULT TO "IDENTIFIER" AND USE THE STOPLIST AS THE AUTHORITY. The first version required
        # an ALLCAPS token to be on a keep-list, which rejected QGADESLICEDOWN - a log tag, and
        # exactly the kind of thing whose loss matters. Reporting a false loss costs a look; hiding a
        # real one costs the rule.
        return t not in IDENT_STOP_WORDS
    return True


CLASSES = {
    "load-bearing": "a rule, caveat, specification, cost or fact that changes what someone would do",
    "redundant": "the same thing is stated elsewhere; the other place is the canonical one",
    "narrative": "history, journey, who found what when; no effect on anyone's behaviour",
    "closed": "an issue or decision that is settled and whose lesson is stated elsewhere",
    "rant": "emotional or self-critical content with no instruction in it",
    "insufficient-evidence": "the unit as given cannot be classified",
}

# THE SAME SIX DEFINITIONS, REPEATED ONCE PER QUESTION, WERE 809 KB OF RUBRIC ON THE FIRST 1037
# UNITS - about 200K input tokens of identical boilerplate. The definitions belong in the state,
# which is sent once per call; the rubric carries labels. Measured, not guessed: `cost.json`.
CLASSES_SHORT = {
    "load-bearing": "changes what someone would do",
    "redundant": "stated elsewhere; that place is canonical",
    "narrative": "history with no effect on behaviour",
    "closed": "settled; its lesson is stated elsewhere",
    "rant": "emotion or self-criticism, no instruction",
    "insufficient-evidence": "cannot be classified as given",
}

TRIAGE = {
    "keep-as-is": "already compact and load-bearing; rewriting it would only risk losing something",
    "compact": "it carries rules or caveats worth keeping, mixed with narrative to cut",
    "delete": "the whole file is spent: a record of a finished episode, or stated elsewhere",
    "insufficient-evidence": "the outline and head do not say which",
}

# The guidance goes in the STATE once, not into every question. Repeating it per question cost about
# 400 bytes x every unit in the corpus, for nothing.
JUDGE_GUIDANCE = """\
HOW TO CLASSIFY. Each unit is shown whole, with its neighbours as CONTEXT so a rule that leans on
its surroundings is not mistaken for a fragment. Classify the UNIT, not its neighbours.
KEEP a historical reference only if it changes what someone would do; cut it if it is narrative.
A cost, a measured number, a prohibition, a path, a command, a defect's discriminator: load-bearing.
An apology, a score, who was furious, how long something took: rant or narrative.
Prefer insufficient-evidence over a guess.

THE CLASSES IN FULL:
  load-bearing           a rule, caveat, specification, cost or fact that changes what someone would do
  redundant              the same thing is stated elsewhere; the other place is the canonical one
  narrative              history, journey, who found what when; no effect on anyone's behaviour
  closed                 an issue or decision that is settled and whose lesson is stated elsewhere
  rant                   emotional or self-critical content with no instruction in it
  insufficient-evidence  the unit as given cannot be classified"""


def is_high_stakes(path):
    rel = os.path.relpath(os.path.abspath(path), ROOT)
    return any(rel == h or rel.startswith(h) for h in HIGH_STAKES)


def split_units(text):
    """Markdown into units that NEVER cut a rule in half (Jev: splitter_risk_is_real 0.79).

    A unit is a whole heading section, a whole top-level list item including its continuation and
    nested lines, a whole table, or a whole fenced block. Paragraph boundaries inside such a unit are
    never split points: a rule that runs across two paragraphs stays one unit.
    """
    lines = text.splitlines()
    units, cur, start = [], [], 0
    kind = "prose"
    in_fence = False

    def flush(end, newkind, newstart):
        nonlocal kind, start
        if cur and any(l.strip() for l in cur):
            units.append({"kind": kind, "start": start + 1, "end": end,
                          "text": "\n".join(cur).rstrip()})
        del cur[:]
        kind, start = newkind, newstart

    i = 0
    while i < len(lines):
        l = lines[i]
        if l.lstrip().startswith("```"):
            in_fence = not in_fence
            cur.append(l)
            i += 1
            continue
        if in_fence:
            cur.append(l)
            i += 1
            continue
        if re.match(r"^#{1,6} ", l):                      # a heading starts a new unit
            flush(i, "section", i)
            cur.append(l)
        elif re.match(r"^[-*+] |^\d+\. ", l):             # a top-level list item, with its continuation
            flush(i, "bullet", i)
            cur.append(l)
            while i + 1 < len(lines):
                nxt = lines[i + 1]
                if nxt.lstrip().startswith("```"):
                    break
                if nxt.strip() == "" and (i + 2 >= len(lines) or re.match(r"^\S", lines[i + 2] or "")):
                    break
                if re.match(r"^[-*+] |^\d+\. |^#{1,6} ", nxt):
                    break
                cur.append(nxt)
                i += 1
        elif l.lstrip().startswith("|"):                  # a table stays whole
            if kind != "table":
                flush(i, "table", i)
            cur.append(l)
        else:
            # PROSE AFTER A TABLE IS NOT PART OF THE TABLE. Without this the unit kind stayed
            # "table" and every following paragraph was appended to it, so a table plus the three
            # paragraphs after it arrived at the judge as one mislabelled unit.
            if kind == "table" and l.strip():
                flush(i, "prose", i)
            cur.append(l)
        i += 1
    flush(len(lines), "prose", len(lines))
    out = [u for u in units if u["text"].strip()]
    for u in out:
        body = [l for l in u["text"].splitlines() if l.strip() and not re.match(r"^#{1,6} ", l)]
        if not body:
            u["kind"] = "heading"      # structure: excluded from classification, carried as context
    return out


def chunk(pairs):
    """Batch (n, unit) pairs so one call stays inside MAX_UNITS_PER_CALL / MAX_BYTES_PER_CALL.
    A single unit larger than the byte bound gets its own call rather than being split."""
    out, cur, b = [], [], 0
    for p in pairs:
        sz = len(p[1]["text"])
        if cur and (len(cur) >= MAX_UNITS_PER_CALL or b + sz > MAX_BYTES_PER_CALL):
            out.append(cur)
            cur, b = [], 0
        cur.append(p)
        b += sz
    if cur:
        out.append(cur)
    return out


def outline(text, units):
    """What a file IS, in a few hundred bytes: its headings, its size, its shape."""
    heads = [u["text"].splitlines()[0] for u in units if u["kind"] == "section"]
    return ("%d bytes, %d lines, %d units (%d sections, %d bullets, %d tables)\nHEADINGS:\n%s"
            % (len(text), len(text.splitlines()), len(units),
               sum(1 for u in units if u["kind"] == "section"),
               sum(1 for u in units if u["kind"] == "bullet"),
               sum(1 for u in units if u["kind"] == "table"),
               "\n".join("  " + h[:120] for h in heads[:60]) or "  (none)"))


def classifiable(pairs):
    """Headings are structure. Asking whether a bare heading is load-bearing wastes a question and
    invites a verdict that would delete it."""
    return [(n, u) for n, u in pairs if u["kind"] != "heading"]


def build_rubric(pairs, path, extra=None):
    """Terse per-question instructions; the guidance lives once in the state."""
    q = {}
    for n, _u in classifiable(pairs):
        q["u%d" % n] = {
            "type": "choice",
            "instructions": {"judge": "Classify UNIT u%d of %s per the state's guidance." % (n, path)},
            "criteria": dict(CLASSES_SHORT),
        }
    if extra:
        q.update(extra)
    return {"questions": q}


def build_state(pairs, path, all_units, note=""):
    L = ["FILE: %s" % path, "UNITS IN THIS BATCH: %d of %d" % (len(pairs), len(all_units)), ""]
    if note:
        L += [note, ""]
    L += [JUDGE_GUIDANCE, ""]
    for n, u in pairs:
        prev = all_units[n - 2]["text"].strip().splitlines()[:2] if n > 1 else []
        nxt = all_units[n]["text"].strip().splitlines()[:2] if n < len(all_units) else []
        L.append("UNIT u%d  (lines %d-%d, %s, %d bytes)" % (n, u["start"], u["end"], u["kind"], len(u["text"])))
        if prev:
            L.append("  CONTEXT-BEFORE: " + " / ".join(x.strip()[:110] for x in prev))
        L.append("  ---8<---")
        for line in u["text"].splitlines():
            L.append("  " + line)
        L.append("  --->8---")
        if nxt:
            L.append("  CONTEXT-AFTER: " + " / ".join(x.strip()[:110] for x in nxt))
        L.append("")
    return "\n".join(L)


USAGE = {"calls": 0, "input_tokens": 0, "output_tokens": 0, "state_bytes": 0, "rubric_bytes": 0}


def call_jev(rubric, state, workdir, tag):
    os.makedirs(workdir, exist_ok=True)
    rp = os.path.join(workdir, "rubric-%s.json" % tag)
    sp = os.path.join(workdir, "state-%s.txt" % tag)
    ap = os.path.join(workdir, "answers-%s.json" % tag)
    with open(rp, "w", encoding="utf-8") as f:
        json.dump(rubric, f, indent=1)
    with open(sp, "w", encoding="utf-8") as f:
        f.write(state)
    USAGE["state_bytes"] += len(state.encode())
    USAGE["rubric_bytes"] += os.path.getsize(rp)
    # A TRANSIENT IS RETRIED, LOUDLY; A TERMINAL FAILURE STILL ABORTS. One HTTP 520 killed a 61-file
    # run at file 2 - and the experimenter rule is that a transient must not fail the run and must
    # never be discarded silently. Retry with backoff and log the text; exhausting the retries, or
    # any non-transient failure (no key, malformed rubric, a 4xx), is still exit 2.
    for attempt in range(1, JEV_ATTEMPTS + 1):
        p = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "jev.py"), rp, sp, "--out", ap],
                           capture_output=True, text=True)
        if p.returncode == 0:
            break
        err = (p.stdout or "") + (p.stderr or "")
        transient = bool(re.search(r"HTTP 5\d\d|timed? ?out|timeout|connection|temporarily|"
                                   r"rate.?limit|429|Remote end closed", err, re.I))
        sys.stderr.write("jev exit %d for %s (attempt %d/%d, %s)\n%s\n"
                         % (p.returncode, tag, attempt, JEV_ATTEMPTS,
                            "TRANSIENT - retrying" if transient and attempt < JEV_ATTEMPTS
                            else "not retried", err.strip()[:400]))
        if not transient or attempt == JEV_ATTEMPTS:
            return None
        time.sleep(JEV_BACKOFF * attempt)
    else:
        return None
    with open(ap, encoding="utf-8") as f:
        d = json.load(f)
    u = d.get("usage") or {}
    USAGE["calls"] += 1
    USAGE["input_tokens"] += int(u.get("input_tokens") or 0)
    USAGE["output_tokens"] += int(u.get("output_tokens") or 0)
    return d


def verdict_line(qid, ans):
    """Quote it as printed - identical to jev.py's own fmt(). The first attempt reformatted verdicts
    into prose, which the jev skill forbids and which made its receipts unverifiable at a glance."""
    t = ans.get("type")
    if t == "noul":
        return "%s noul=%.2f" % (qid, ans.get("noul", -1))
    if t == "choice":
        pr = ans.get("probabilities") or {}
        dist = " ".join("%s=%.2f" % (k, v) for k, v in sorted(pr.items(), key=lambda kv: -kv[1]))
        return "%s choice=%s conf=%.2f [%s]" % (qid, ans.get("choice"), ans.get("confidence", -1), dist)
    if t == "score":
        return "%s score=%.2f conf=%.2f" % (qid, ans.get("score", -1), ans.get("confidence", -1))
    return "%s %s" % (qid, json.dumps(ans)[:160])


def tag_for(path):
    return re.sub(r"[^A-Za-z0-9]+", "_", os.path.relpath(path, ROOT))[:60]


def save_plans(out):
    plans = []
    for fn in sorted(os.listdir(out)):
        if fn.endswith(".plan.json"):
            try:
                plans.append(json.load(open(os.path.join(out, fn), encoding="utf-8")))
            except (OSError, ValueError):
                pass
    with open(os.path.join(out, "plans.json"), "w", encoding="utf-8") as f:
        json.dump(plans, f, indent=1)
    return plans


def plan_units(a, out, jevdir):
    done = 0
    for path in a.files:
        tag = tag_for(path)
        pp = os.path.join(out, tag + ".plan.json")
        if a.skip_done and os.path.exists(pp):
            print("%-52s SKIP (plan exists)" % os.path.relpath(path, ROOT))
            continue
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError as e:
            print("prose-audit: cannot read %s: %s" % (path, e))
            return 2
        units = split_units(text)
        if not units:
            print("prose-audit: %s split into 0 units - nothing ran" % path)
            return 2
        pairs = list(enumerate(units, 1))

        answers = {}
        for ci, batch in enumerate(chunk(classifiable(pairs)), 1):
            extra = None
            if ci == 1:
                extra = {"file_contributes": {
                    "type": "noul",
                    "instructions": {"judge":
                        "From the OUTLINE below, does %s still contribute to development at all, or "
                        "is the whole file a deletion candidate? true = keep it in some form." % path},
                    "criteria": {"true": "keep the file, in some form",
                                 "false": "the whole file is spent or stated elsewhere"}}}
            note = ("FILE OUTLINE (for file_contributes):\n" + outline(text, units)) if ci == 1 else ""
            d = call_jev(build_rubric(batch, path, extra), build_state(batch, path, units, note),
                         jevdir, "%s_c%d" % (tag, ci))
            if d is None:
                print("prose-audit: the judge did not answer for %s batch %d - no verdict, and this "
                      "is not a pass" % (path, ci))
                return 2
            answers.update(d.get("answers", {}))

        # THE RE-ASK LOOP, IN CODE. Jev named this the thing most lost in a scripted design
        # (worst_thing_lost = gap-closing-re-ask 0.64): a human assessor notices a weak verdict,
        # closes the gap and asks again. That is deterministic control flow around a judgment, so it
        # belongs here rather than in a model. Any unit under the floor is re-asked ONCE with the
        # whole file as context instead of its neighbours.
        idx = {("u%d" % n): (n, u) for n, u in pairs}
        weak = [qid for qid, v in answers.items()
                if qid in idx and idx[qid][1]["kind"] != "heading"
                and float(v.get("confidence", 1)) < a.conf_floor]
        weak.sort(key=lambda q: idx[q][0])
        reasked = {}
        if weak:
            note = ("RE-ASK. These units were classified below confidence %.2f on the first pass, so "
                    "each is shown again with its NEIGHBOURING UNITS IN FULL (not just their first "
                    "lines) and the file's outline - a weak verdict usually means the unit could not "
                    "be read without its surroundings." % a.conf_floor)
            for ci, batch in enumerate(chunk([idx[q] for q in weak]), 1):
                wide = []
                for n, _u in batch:
                    for m in range(max(1, n - 2), min(len(units), n + 2) + 1):
                        if m not in [x[0] for x in wide]:
                            wide.append((m, units[m - 1]))
                wide.sort()
                st = (build_state(wide, path, units, note)
                      + "\n\nFILE OUTLINE:\n" + outline(text, units)
                      + "\n\nCLASSIFY ONLY THESE UNITS: " + " ".join(q for q in
                        ["u%d" % n for n, _ in batch]))
                d = call_jev(build_rubric(batch, path), st, jevdir, "%s_reask%d" % (tag, ci))
                if d is None:
                    print("prose-audit: the re-ask did not run for %s" % path)
                    return 2
                for qid, v in d.get("answers", {}).items():
                    if qid in idx:
                        reasked[qid] = v

        rows = []
        for n, u in pairs:
            qid = "u%d" % n
            if u["kind"] == "heading":
                rows.append({"unit": qid, "lines": [u["start"], u["end"]], "kind": "heading",
                             "bytes": len(u["text"]), "class": "structure", "conf": None,
                             "first_pass": "(not asked: structure)", "final": "(not asked: structure)",
                             "reasked": False, "head": u["text"].strip().splitlines()[0][:150]})
                continue
            first = answers.get(qid, {})
            final = reasked.get(qid, first)
            rows.append({"unit": qid, "lines": [u["start"], u["end"]], "kind": u["kind"],
                         "bytes": len(u["text"].encode("utf-8")),
                         "class": final.get("choice"), "conf": final.get("confidence"),
                         "first_pass": verdict_line(qid, first),
                         "final": verdict_line(qid, final),
                         "reasked": qid in reasked,
                         "head": u["text"].strip().splitlines()[0][:150]})

        fc = answers.get("file_contributes", {})
        keep = [r for r in rows if r["class"] == "load-bearing"]
        cut = [r for r in rows if r["class"] in ("narrative", "closed", "rant")]
        unclassified = [r for r in rows if not r["class"]]
        structure = [r for r in rows if r["class"] == "structure"]
        plan = {"file": path, "mode": "units", "bytes": len(text.encode("utf-8")),
                "chars": len(text), "units": len(units),
                "high_stakes": is_high_stakes(path),
                "file_contributes": verdict_line("file_contributes", fc),
                "file_contributes_noul": fc.get("noul"),
                "reasked": len(reasked), "unclassified": len(unclassified),
                "structure": len(structure), "rows": rows,
                "keep_bytes": sum(r["bytes"] for r in keep),
                "cut_bytes": sum(r["bytes"] for r in cut)}
        with open(pp, "w", encoding="utf-8") as f:
            json.dump(plan, f, indent=1)
        save_plans(out)
        print("%-52s %4d units  keep %-4d cut %-4d  re-asked %-3d %s%s"
              % (os.path.relpath(path, ROOT), len(units), len(keep), len(cut), len(reasked),
                 "HIGH-STAKES " if plan["high_stakes"] else "",
                 ("UNCLASSIFIED %d" % len(unclassified)) if unclassified else ""))
        done += 1
    print("\nunits mode: %d file(s) planned" % done)
    return 0


def plan_triage(a, out, jevdir):
    """One question per file, batched. This is the stakes bucket for files that are deletion
    candidates: a register of closed issues is one question, not four hundred."""
    files = []
    for path in a.files:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError as e:
            print("prose-audit: cannot read %s: %s" % (path, e))
            return 2
        files.append((path, text, split_units(text)))

    rows = []
    for bi in range(0, len(files), a.batch):
        group = files[bi:bi + a.batch]
        q, L = {}, [JUDGE_GUIDANCE, "",
                    "TRIAGE. For each FILE below you are given its outline and its first 1200 bytes.",
                    "Answer one question per file. Do not classify individual units here.", ""]
        for k, (path, text, units) in enumerate(group, 1):
            qid = "f%d" % k
            q[qid] = {"type": "choice",
                      "instructions": {"judge": "Verdict for FILE %s (%s)." % (qid, path)},
                      "criteria": dict(TRIAGE)}
            L.append("FILE %s: %s" % (qid, os.path.relpath(path, ROOT)))
            L.append(outline(text, units))
            L.append("  HEAD ---8<---")
            for line in text[:1200].splitlines():
                L.append("  " + line)
            L.append("  --->8---")
            L.append("")
        d = call_jev({"questions": q}, "\n".join(L), jevdir, "triage_%d" % (bi // a.batch + 1))
        if d is None:
            print("prose-audit: the judge did not answer the triage batch - no verdict")
            return 2
        ans = d.get("answers", {})
        for k, (path, text, units) in enumerate(group, 1):
            v = ans.get("f%d" % k, {})
            rows.append({"file": path, "mode": "triage", "bytes": len(text), "units": len(units),
                         "high_stakes": is_high_stakes(path),
                         "verdict": v.get("choice"), "conf": v.get("confidence"),
                         "line": verdict_line(os.path.relpath(path, ROOT), v)})
            print("%-52s %-14s %s" % (os.path.relpath(path, ROOT), v.get("choice"),
                                      verdict_line("", v).strip()))
    with open(os.path.join(out, "triage.json"), "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=1)
    byv = {}
    for r in rows:
        byv.setdefault(r["verdict"], []).append(r)
    print("\ntriage: " + "  ".join("%s=%d" % (k, len(v)) for k, v in sorted(byv.items(), key=lambda kv: -len(kv[1]))))
    print("promote every `compact` file to --mode units; `delete` goes to the report's delete list")
    return 0


def cmd_plan(a):
    out = a.out or DEFAULT_OUT
    os.makedirs(out, exist_ok=True)
    jevdir = os.path.join(out, "jev")
    rc = (plan_triage if a.mode == "triage" else plan_units)(a, out, jevdir)
    print_cost(out)
    return rc


def print_cost(out):
    tot = dict(USAGE)
    cp = os.path.join(out, "cost.json")
    if os.path.exists(cp):
        try:
            prev = json.load(open(cp, encoding="utf-8"))
            for k in tot:
                tot[k] = prev.get(k, 0) + USAGE[k]
        except (OSError, ValueError):
            pass
    with open(cp, "w", encoding="utf-8") as f:
        json.dump(tot, f, indent=1)
    print("COST this run: %d jev call(s), %s input tokens, %s output tokens "
          "(state %s bytes, rubric %s bytes).  Cumulative in %s: %s input tokens, %d calls."
          % (USAGE["calls"], format(USAGE["input_tokens"], ","), format(USAGE["output_tokens"], ","),
             format(USAGE["state_bytes"], ","), format(USAGE["rubric_bytes"], ","),
             os.path.relpath(cp, ROOT), format(tot["input_tokens"], ","), tot["calls"]))


def cmd_cost(a):
    out = a.out or DEFAULT_OUT
    try:
        tot = json.load(open(os.path.join(out, "cost.json"), encoding="utf-8"))
    except OSError as e:
        print("prose-audit cost: nothing recorded (%s)" % e)
        return 2
    print(json.dumps(tot, indent=1))
    return 0


def cmd_verify(a):
    """Script verification + escalation. Jev: script verification ALONE is not sufficient (0.19), so
    this reports what it cannot match rather than declaring the rewrite clean, and a high-stakes file
    additionally needs a model verifier - which this prints as a required next step rather than
    pretending to have done."""
    out = a.plan or DEFAULT_OUT
    pp = os.path.join(out, tag_for(a.file) + ".plan.json")
    try:
        plan = json.load(open(pp, encoding="utf-8"))
        new = open(a.rewrite, encoding="utf-8", errors="replace").read()
        old = open(a.file, encoding="utf-8", errors="replace").read()
    except OSError as e:
        print("prose-audit verify: cannot run (%s)" % e)
        return 2
    if plan.get("mode") != "units":
        print("prose-audit verify: %s has no unit plan (mode=%s) - run --mode units first"
              % (os.path.relpath(a.file, ROOT), plan.get("mode")))
        return 2

    def norm(s):
        return re.sub(r"\s+", " ", s).strip().lower()

    newn = norm(new)
    # identifiers are what make a rule actionable: paths, log tags, commands, constants
    ident = re.compile(r"[A-Za-z_][A-Za-z0-9_\-/\\.]*\.(?:ps1|py|sh|c|cpp|h|md|json|exe|cmd)"
                       r"|\b[A-Z][A-Z0-9_]{5,}\b|`[^`\n]+`")
    lost, kept, unmatched = [], 0, []
    units = split_units(old)
    idx = {("u%d" % n): u for n, u in enumerate(units, 1)}
    for r in plan["rows"]:
        if r["class"] != "load-bearing":
            continue
        u = idx.get(r["unit"])
        if not u:
            continue
        ids = [i.strip("`") for i in ident.findall(u["text"])]
        ids = [i for i in ids if len(i) > 4][:6]
        if ids and all(norm(i) in newn for i in ids):
            kept += 1
        elif ids:
            lost.append({"unit": r["unit"], "lines": r["lines"],
                         "missing": [i for i in ids if norm(i) not in newn], "head": r["head"]})
        else:
            unmatched.append({"unit": r["unit"], "lines": r["lines"], "head": r["head"]})

    nlb = len([r for r in plan["rows"] if r["class"] == "load-bearing"])
    print("VERIFY %s -> %s" % (os.path.relpath(a.file, ROOT), os.path.relpath(a.rewrite, ROOT)))
    print("  %d -> %d bytes (%.0f%% of original)" % (len(old), len(new), 100.0 * len(new) / max(1, len(old))))
    print("  load-bearing units: %d   identifiers present: %d   identifiers MISSING: %d   "
          "no identifier to check: %d" % (nlb, kept, len(lost), len(unmatched)))
    for x in lost[:25]:
        print("  LOST? %s (lines %s) missing %s | %s" % (x["unit"], x["lines"], x["missing"][:4], x["head"][:80]))
    if unmatched:
        print("  %d unit(s) carry no identifier, so this script cannot judge them - they ESCALATE "
              "to the judge." % len(unmatched))
        for x in unmatched[:15]:
            print("    ESCALATE %s (lines %s) | %s" % (x["unit"], x["lines"], x["head"][:80]))
    if plan.get("high_stakes"):
        print("  HIGH-STAKES FILE: a model verifier is REQUIRED as well (Jev: script verification "
              "alone 0.19).")
    return 0 if not lost else 1



def sections(text, lv=None):
    """Split into (heading, body) at heading level `lv`. Alignment material, not units.

    The level is chosen from the ORIGINAL and then forced on the rewrite: BENCHMARKS.md dropped a
    duplicate H1, so the original split at `#` (2 sections) and the rewrite at `##` (11), and nothing
    aligned - 2 reported dropped and 11 orphaned on a rewrite that lost no section at all."""
    lines = text.splitlines()
    # SPLIT AT THE SHALLOWEST LEVEL THAT ACTUALLY DIVIDES THE FILE. Taking the shallowest heading
    # present put every ADR under its single `#` title - one section - and the drop check was blind:
    # removing section 27 outright was reported as nothing dropped.
    counts = {}
    for l in lines:
        m = re.match(r"^(#{1,6}) ", l)
        if m:
            counts[len(m.group(1))] = counts.get(len(m.group(1)), 0) + 1
    if not counts:
        return [("(whole file)", text)]
    if lv is None:
        lv = next((k for k in sorted(counts) if counts[k] >= 2), max(counts))
    out, head, buf = [], "(preamble)", []
    pat = re.compile(r"^#{%d} " % lv)
    for l in lines:
        if pat.match(l):
            if buf or head != "(preamble)":
                out.append((head, "\n".join(buf)))
            head, buf = l.strip(), []
        else:
            buf.append(l)
    out.append((head, "\n".join(buf)))
    return [(h, b) for h, b in out if b.strip() or h != "(preamble)"]


def split_level(text):
    """The heading level sections() would pick for this text."""
    counts = {}
    for l in text.splitlines():
        m = re.match(r"^(#{1,6}) ", l)
        if m:
            counts[len(m.group(1))] = counts.get(len(m.group(1)), 0) + 1
    if not counts:
        return None
    return next((k for k in sorted(counts) if counts[k] >= 2), max(counts))


def align(old_secs, new_secs):
    """Match sections old->new: exact heading, then normalised, then by leading ADR number."""
    def norm(h):
        return re.sub(r"\s+", " ", h).strip().lower()

    def num(h):
        m = re.match(r"^#+\s*(\d+)[.)]", h)
        return m.group(1) if m else None

    by_exact = {h: i for i, (h, _) in enumerate(new_secs)}
    by_norm = {norm(h): i for i, (h, _) in enumerate(new_secs)}
    by_num = {}
    for i, (h, _) in enumerate(new_secs):
        n = num(h)
        if n and n not in by_num:
            by_num[n] = i
    pairs, used = [], set()
    for (h, b) in old_secs:
        j = by_exact.get(h)
        if j is None:
            j = by_norm.get(norm(h))
        if j is None and num(h):
            j = by_num.get(num(h))
        if j is None or j in used:
            pairs.append(((h, b), None))
        else:
            used.add(j)
            pairs.append(((h, b), new_secs[j]))

    # A RENAMED HEADING IS NOT A DROPPED SECTION. Shortening a heading is explicitly allowed, and
    # without this every shortened heading showed up as one dropped section plus one orphan - three
    # false losses on findings/windowing.md alone. Recover the pairing from BODY similarity, which is
    # exact measurement over tokens, and label it a rename so it is never read as a loss.
    def toks(x):
        return set(re.findall(r"[A-Za-z_][A-Za-z0-9_]{3,}", x.lower()))

    free = [i for i in range(len(new_secs)) if i not in used]
    renamed = []
    for k, ((h, b), m) in enumerate(pairs):
        if m is not None or not free:
            continue
        ob = toks(b)
        if not ob:
            continue
        best, score = None, 0.0
        for i in free:
            nb = toks(new_secs[i][1])
            if not nb:
                continue
            r = len(ob & nb) / float(len(ob | nb))
            if r > score:
                best, score = i, r
        if best is not None and score >= 0.45:
            used.add(best)
            free.remove(best)
            pairs[k] = ((h, b), new_secs[best])
            renamed.append((h, new_secs[best][0], round(score, 2)))
    orphans = [new_secs[i] for i in range(len(new_secs)) if i not in used]
    return pairs, orphans, renamed


def cmd_judge(a):
    """JEV EVALUATES THE REWRITE, SECTION BY SECTION.

    The first version of this asked whether anything was lost while showing Jev only the FIRST LINE of
    each load-bearing unit. A faithful rewrite that rewords a heading then reads as a loss, and
    "nothing added" is not answerable at all without the original's text - so it scored
    nothing_lost 0.11 on a rewrite whose own report, and the identifier check, said two identifiers
    were missing. The verdict was about my state, not about the rewrite.

    So: alignment is done HERE, by heading (exact -> normalised -> ADR number), which also answers
    deterministically whether a section was dropped; and each aligned pair is judged with BOTH texts
    present, which is the only state in which the question is answerable."""
    out = a.plan or DEFAULT_OUT
    rel = os.path.relpath(os.path.abspath(a.file), ROOT)
    try:
        old = open(a.file, encoding="utf-8", errors="replace").read()
        new = open(a.rewrite, encoding="utf-8", errors="replace").read()
    except OSError as e:
        print("prose-audit judge: cannot run (%s)" % e)
        return 2

    def norm(x):
        return re.sub(r"\s+", " ", x).strip().lower()

    ident = re.compile(r"[A-Za-z_][A-Za-z0-9_\-/\\.]*\.(?:ps1|py|sh|c|cpp|h|md|json|exe|cmd)"
                       r"|\b[A-Z][A-Z0-9_]{5,}\b|`[^`\n]+`")
    newn = norm(new)
    missing = sorted({i.strip("`") for i in ident.findall(old)
                      if real_identifier(i) and norm(i.strip("`")) not in newn})

    lv = split_level(old)
    pairs, orphans, renamed = align(sections(old, lv), sections(new, lv))
    dropped = [h for (h, _), m in pairs if m is None]

    # A SECTION CAN BE THE WHOLE FILE. findings/*.md is routinely a title plus one "## CURRENT
    # STATE" heading over dozens of bullets (CLAUDE.md L8: one bullet is one rule). Sending that
    # whole pair as a single call blew the instrument's request budget outright
    # (findings/wedge.md, 164KB combined -> HTTP 400 max_tokens_exceeded, not transient, not
    # retried, never judged). A bullet is already a unit that must never be cut in half
    # (split_units), so an oversized section is re-split at the bullet boundary and ALIGNED THE
    # SAME WAY as sections are - recursively, never silently dropped.
    def subunits(body):
        out = []
        for u in split_units(body):
            if u["kind"] == "heading":
                continue
            t = u["text"].strip("\n")
            first = next((ln for ln in t.splitlines() if ln.strip()), t[:200])
            out.append((first[:200], t))
        return out

    work, extra_dropped, extra_orphans = [], [], []
    for (o, m) in pairs:
        if m is None:
            continue
        oh, ob = o
        nh, nb = m
        if len(ob) + len(nb) <= MAX_BYTES_PER_CALL:
            work.append((o, m))
            continue
        subo, subn = subunits(ob), subunits(nb)
        if not subo or not subn:
            work.append((o, m))          # nothing finer to cut at; send whole (may still overflow)
            continue
        sp, sorph, _ = align(subo, subn)
        for (sh, sb), sm in sp:
            if sm is None:
                extra_dropped.append("%s :: %s" % (oh, sh[:70]))
            else:
                work.append((
                    (("%s :: %s" % (oh, sh))[:160], sb),
                    (("%s :: %s" % (nh, sm[0]))[:160], sm[1]),
                ))
        for sh, _sb in sorph:
            extra_orphans.append("%s :: %s" % (nh, sh[:70]))

    # batch the aligned pairs so one call carries both texts but stays bounded
    batches, cur, sz = [], [], 0
    for (o, m) in work:
        b = len(o[1]) + len(m[1])
        if cur and sz + b > MAX_BYTES_PER_CALL:
            batches.append(cur); cur, sz = [], 0
        cur.append((o, m)); sz += b
    if cur:
        batches.append(cur)

    rows = []
    for ci, batch in enumerate(batches, 1):
        q, L = {}, []
        L += ["FILE: %s" % rel,
              "Each PAIR below is one section of the ORIGINAL and the SAME section of the REWRITE.",
              "Judge only that pair.",
              "",
              "THE REWRITE WAS AUTHORISED TO REMOVE THESE, SO THEIR ABSENCE IS NOT A LOSS:",
              "  - dates and times that only record WHEN something was done or decided",
              "    (a date is load-bearing only if acting on it depends on the date: an expiry, a",
              "     Windows build or release date, an ordering that changes a conclusion);",
              "  - per-run identifiers: CI run ids, package hashes, per-cell pass/fail tallies;",
              "  - who said or found something, who was annoyed, how long it took, how many attempts;",
              "  - quotes kept only for tone, and profanity;",
              "  - judge/review scores that decided nothing;",
              "  - a retelling of an incident, where the RULE it produced survives;",
              "  - repetition of something stated elsewhere in the same file.",
              "",
              "A LOSS is: a rule, prohibition, caveat, threshold, constant, measured result, path,",
              "command, flag, API or class name, log tag, error code, defect discriminator or cost",
              "that is gone and is not implied by what remains. Shorter wording is NOT a loss.",
              "An ADDITION is a claim, advice or generalisation not on the ORIGINAL side, or a",
              "prohibition made weaker or conditional.", ""]
        if missing:
            L += ["A script checked every identifier in the whole original against the whole rewrite.",
                  "MISSING IDENTIFIERS (measured fact, %d): %s" % (len(missing), ", ".join(missing[:40])), ""]
        for k, ((oh, ob), (nh, nb)) in enumerate(batch, 1):
            qid = "s%d" % k
            q[qid + "_lost"] = {"type": "noul", "instructions": {"judge":
                "PAIR %s (%s): judged against the authorised-removal list in the state, is anything "
                "LOAD-BEARING from the ORIGINAL side missing from the REWRITE side? true = nothing "
                "load-bearing was lost." % (qid, oh[:80])},
                "criteria": {"true": "nothing load-bearing lost", "false": "something material is gone"}}
            q[qid + "_added"] = {"type": "noul", "instructions": {"judge":
                "PAIR %s: does the REWRITE side avoid adding any claim, advice or generalisation that "
                "is not on the ORIGINAL side, and avoid softening any prohibition?" % qid},
                "criteria": {"true": "nothing invented or softened", "false": "it adds or weakens something"}}
            L += ["=" * 70, "PAIR %s" % qid,
                  "--- ORIGINAL SECTION: %s" % oh, ob, "",
                  "--- REWRITE SECTION: %s" % nh, nb, ""]
        d = call_jev({"questions": q}, "\n".join(L), os.path.join(out, "jev"),
                     "judge_%s_c%d" % (tag_for(a.file), ci))
        if d is None:
            print("prose-audit judge: the judge did not answer for %s batch %d" % (rel, ci))
            return 2
        ans = d.get("answers", {})
        for k, ((oh, _), (nh, _)) in enumerate(batch, 1):
            lost = ans.get("s%d_lost" % k, {})
            add = ans.get("s%d_added" % k, {})
            rows.append({"section": oh, "rewrite_section": nh,
                         "lost_noul": lost.get("noul"), "added_noul": add.get("noul"),
                         "lost_line": verdict_line("lost", lost), "added_line": verdict_line("added", add)})

    bad = [r for r in rows if (r["lost_noul"] or 1) < 0.5]
    addp = [r for r in rows if (r["added_noul"] or 1) < 0.5]
    rec = {"file": rel, "rewrite": os.path.relpath(a.rewrite, ROOT),
           "old_bytes": len(old.encode("utf-8")), "new_bytes": len(new.encode("utf-8")),
           "sections": len(rows), "dropped_sections": dropped,
           "orphan_sections": [h for h, _ in orphans],
           "renamed_sections": [{"from": a_, "to": b_, "similarity": r} for a_, b_, r in renamed],
           "dropped_subunits": extra_dropped, "orphan_subunits": extra_orphans,
           "missing_identifiers": missing, "rows": rows,
           "sections_with_loss": [r["section"] for r in bad],
           "sections_with_addition": [r["section"] for r in addp]}
    jd = os.path.join(out, "judged"); os.makedirs(jd, exist_ok=True)
    with open(os.path.join(jd, tag_for(a.file) + ".judged.json"), "w", encoding="utf-8") as f:
        json.dump(rec, f, indent=1)

    print("JUDGE %-44s %7d -> %-7d (%3.0f%%)  %d section pair(s)"
          % (rel, rec["old_bytes"], rec["new_bytes"],
             100.0 * rec["new_bytes"] / max(1, rec["old_bytes"]), len(rows)))
    if dropped:
        print("  SECTION(S) DROPPED ENTIRELY (%d): %s" % (len(dropped), "; ".join(d[:60] for d in dropped[:6])))
    if renamed:
        print("  SECTION(S) RENAMED (%d, matched on body overlap - not a loss):" % len(renamed))
        for a_, b_, r in renamed[:8]:
            print("     %.2f  %s" % (r, a_[:46]))
            print("           -> %s" % b_[:70])
    if orphans:
        print("  SECTION(S) ONLY IN THE REWRITE (%d): %s" % (len(orphans), "; ".join(h[:60] for h, _ in orphans[:6])))
    if extra_dropped:
        print("  SUBUNIT(S) (bullet/paragraph) DROPPED WITHIN A SECTION (%d): %s"
              % (len(extra_dropped), "; ".join(d[:70] for d in extra_dropped[:6])))
    if extra_orphans:
        print("  SUBUNIT(S) ONLY IN THE REWRITE, WITHIN A SECTION (%d): %s"
              % (len(extra_orphans), "; ".join(d[:70] for d in extra_orphans[:6])))
    if missing:
        print("  MISSING IDENTIFIERS (%d): %s" % (len(missing), ", ".join(missing[:12])))
    print("  sections judged to LOSE something: %d    to ADD something: %d" % (len(bad), len(addp)))
    for r in bad[:10]:
        print("     LOSS  %-58s %s" % (r["section"][:58], r["lost_line"]))
    for r in addp[:10]:
        print("     ADDED %-58s %s" % (r["section"][:58], r["added_line"]))
    return 0 if not (bad or addp or dropped or missing or extra_dropped) else 1


def cmd_report(a):
    out = a.out or DEFAULT_OUT
    plans = save_plans(out)
    triage = []
    tp = os.path.join(out, "triage.json")
    if os.path.exists(tp):
        try:
            triage = json.load(open(tp, encoding="utf-8"))
        except (OSError, ValueError):
            pass
    if not plans and not triage:
        print("prose-audit report: no plans to report")
        return 2
    tot = {"files": len(plans), "bytes": 0, "units": 0, "keep": 0, "cut": 0, "redundant": 0,
           "reasked": 0, "unclassified": 0, "keep_bytes": 0, "cut_bytes": 0}
    delete = []
    for p in plans:
        tot["bytes"] += p["bytes"]; tot["units"] += p["units"]; tot["reasked"] += p["reasked"]
        tot["unclassified"] += p.get("unclassified", 0)
        tot["keep_bytes"] += p.get("keep_bytes", 0); tot["cut_bytes"] += p.get("cut_bytes", 0)
        tot["keep"] += sum(1 for r in p["rows"] if r["class"] == "load-bearing")
        tot["cut"] += sum(1 for r in p["rows"] if r["class"] in ("narrative", "closed", "rant"))
        tot["redundant"] += sum(1 for r in p["rows"] if r["class"] == "redundant")
        n = p.get("file_contributes_noul")
        if n is not None and n < 0.35:
            delete.append((p["file"], p["file_contributes"]))
    print("PROSE AUDIT, units mode: %(files)d files, %(bytes)s bytes, %(units)d units\n"
          "  load-bearing %(keep)d (%(keep_bytes)s bytes)   to cut %(cut)d (%(cut_bytes)s bytes)   "
          "redundant %(redundant)d   re-asked %(reasked)d   unclassified %(unclassified)d"
          % dict(tot, bytes=format(tot["bytes"], ","), keep_bytes=format(tot["keep_bytes"], ","),
                 cut_bytes=format(tot["cut_bytes"], ",")))
    if tot["unclassified"]:
        print("  UNCLASSIFIED UNITS EXIST - missing data fails; re-run those files before rewriting.")
    if delete:
        print("\nWHOLE-FILE DELETION CANDIDATES (file_contributes below 0.35):")
        for f, v in delete:
            print("  %-54s %s" % (os.path.relpath(f, ROOT), v))
    if triage:
        byv = {}
        for r in triage:
            byv.setdefault(r["verdict"], []).append(r)
        print("\nTRIAGE, %d files: %s" % (len(triage),
              "  ".join("%s=%d" % (k, len(v)) for k, v in sorted(byv.items(), key=lambda kv: -len(kv[1])))))
        for v in ("delete", "compact", "keep-as-is", "insufficient-evidence", None):
            for r in byv.get(v, []):
                print("  %-10s %-48s %s" % (v, os.path.relpath(r["file"], ROOT), r["line"]))
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p1 = sub.add_parser("plan"); p1.add_argument("files", nargs="+")
    p1.add_argument("--mode", choices=("units", "triage"), default="units")
    p1.add_argument("--out"); p1.add_argument("--conf-floor", type=float, default=0.55)
    p1.add_argument("--batch", type=int, default=12)
    p1.add_argument("--skip-done", action="store_true")
    p2 = sub.add_parser("verify"); p2.add_argument("file"); p2.add_argument("--rewrite", required=True)
    p2.add_argument("--plan")
    p3 = sub.add_parser("report"); p3.add_argument("--out")
    p5 = sub.add_parser("judge"); p5.add_argument("file"); p5.add_argument("--rewrite", required=True)
    p5.add_argument("--plan")
    p4 = sub.add_parser("cost"); p4.add_argument("--out")
    a = ap.parse_args()
    return {"plan": cmd_plan, "verify": cmd_verify, "report": cmd_report, "cost": cmd_cost,
            "judge": cmd_judge}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
