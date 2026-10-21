#!/usr/bin/env python3
"""Put audit findings to Jev as ONE call, one question per finding, and apply its verdict.

WHY THIS IS A SCRIPT AND NOT A FLEET OF AGENTS. Deciding whether a finding holds assigns the
finding to a class, and in this project a classifier belongs to Jev, not to a hand call or to a
subagent's opinion (owner, 2026-09-21). The matching and counting around it is code: a fleet of
agents doing the same job once cost 1.5M tokens for a worse answer.

WHY ONE CALL AND NOT ONE PER FINDING. The verdicts have to be comparable. N separate calls give N
differently-anchored judgements, and the cheap failure mode is a flat 0.50 across the board, which
means the premise never reached Jev - check input_tokens on the receipt, not just the numbers.

The artifact carries the finding AND the code it points at, because a verdict on a diff Jev never
received looks exactly like a real one.

Usage:
    jev-verify-findings.py FINDINGS.json [--out verdicts.json] [--threshold 0.5]

FINDINGS.json: a list of objects, or {"findings": [...]}, each with at least
    title, file, claim, failure_scenario    (register_tag, line, severity, how_to_disprove optional)

Exit status: 0 if at least one finding survived, 1 if all were refuted, 2 on an input or Jev error.
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONTEXT_LINES = 60


def excerpt(rel, line):
    """The code the finding points at, so the verdict is about the real text."""
    p = ROOT / rel
    if not p.is_file():
        return "(%s is not a file in the repo - the finding names a path that does not exist)" % rel
    try:
        src = p.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as e:
        return "(could not read %s: %s)" % (rel, e)
    if not line:
        head = src[:CONTEXT_LINES]
        return "%s, first %d lines:\n%s" % (rel, len(head), "\n".join(head))
    a = max(0, line - 1 - CONTEXT_LINES // 2)
    b = min(len(src), a + CONTEXT_LINES)
    return "%s:%d (lines %d-%d):\n%s" % (
        rel, line, a + 1, b,
        "\n".join("%5d  %s" % (a + i + 1, s) for i, s in enumerate(src[a:b])))


def qid(i, f):
    tag = re.sub(r"[^A-Za-z0-9]", "", str(f.get("register_tag") or "NEW"))[:24] or "NEW"
    return "f%02d_%s" % (i, tag)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("findings")
    ap.add_argument("--out", default="scratchpad/jev-verify-out.json")
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--artifact", default="scratchpad/jev-verify-artifact.md")
    ap.add_argument("--rubric", default="scratchpad/jev-verify-rubric.json")
    args = ap.parse_args()

    data = json.load(open(args.findings, encoding="utf-8"))
    if isinstance(data, dict):
        data = data.get("findings", data.get("confirmed", []))
    if not isinstance(data, list) or not data:
        print("jev-verify-findings: no findings in %s" % args.findings, file=sys.stderr)
        return 2

    secs, qs = [], {}
    for i, f in enumerate(data):
        q = qid(i, f)
        secs.append(
            "## %s\n\n"
            "- claimed defect: %s\n- file: %s%s\n- register tag: %s\n- severity claimed: %s\n"
            "- the claim: %s\n- failure scenario: %s\n- author's own disproof route: %s\n\n"
            "```\n%s\n```\n" % (
                q, f.get("title", "(no title)"), f.get("file", "?"),
                (":%s" % f["line"]) if f.get("line") else "",
                f.get("register_tag", "NEW"), f.get("severity", "?"),
                f.get("claim", ""), f.get("failure_scenario", ""),
                f.get("how_to_disprove", "(none given)"),
                excerpt(f.get("file", ""), f.get("line"))))
        qs[q] = {
            "type": "noul",
            "instructions": {"judge":
                "Section %s of the attached audit: a claimed defect in the Windows-guest acceptance "
                "harness, with the code it points at quoted beneath it. One 8-cell, ~10 hour release "
                "acceptance campaign is about to be spent, and it gates cutting a release. Decide "
                "whether this defect is REAL AND WOULD MATTER TO THAT CAMPAIGN: would it fail the "
                "run, or let a failure happen that cannot afterwards be diagnosed? Judge the quoted "
                "code, not the claim's confidence. This harness's history is full of checks that "
                "read correctly and were inert - a regex whose trailing alternation matched "
                "everything, a predicate fed a constant at its call site, a rule keyed on wording "
                "that was then reworded - so a claim that the quoted code does not actually support "
                "is false, however plausible it sounds." % q},
            "criteria": {
                "true": "Real, and it would fail the campaign or leave a failure undiagnosable.",
                "false": "Not real, already guarded upstream, unreachable, or harmless to the campaign.",
            },
        }

    pathlib.Path(args.artifact).write_text(
        "# Audit findings put to Jev\n\n"
        "Each section is one claimed harness defect and the code it names.\n\n" + "\n".join(secs),
        encoding="utf-8")
    json.dump({"questions": qs}, open(args.rubric, "w"), indent=0)

    env = dict(os.environ, JEV_ARTIFACT_OUT=args.out)
    r = subprocess.run(["tools/jev-artifact.sh", args.rubric, args.artifact],
                       cwd=str(ROOT), env=env, capture_output=True, text=True)
    sys.stderr.write(r.stderr)
    print(r.stdout, end="")
    if r.returncode != 0 or not pathlib.Path(ROOT / args.out).exists():
        print("jev-verify-findings: Jev call failed (rc=%d) - no verdicts, so nothing is confirmed"
              % r.returncode, file=sys.stderr)
        return 2

    raw = pathlib.Path(ROOT / args.out).read_text(encoding="utf-8")
    V = {m.group(1): float(m.group(2)) for m in re.finditer(
        r'"(f\d+_[A-Za-z0-9]+)"\s*:\s*\{[^{}]*?"(?:noul|probability|p)"\s*:\s*([0-9.]+)', raw, re.S)}
    missing = [qid(i, f) for i, f in enumerate(data) if qid(i, f) not in V]

    # A FLAT RESULT MEANS THE PREMISE DID NOT ARRIVE. Every question answering within a hair of 0.5,
    # or every question answering the same value, is the shape of a call that judged nothing. Say so
    # rather than reporting it as a verdict.
    vals = sorted(V.values())
    flat = len(vals) > 2 and (vals[-1] - vals[0]) < 0.02
    print()
    print("=== JEV VERDICTS (threshold %.2f) ===" % args.threshold)
    held = []
    for i, f in enumerate(data):
        q = qid(i, f)
        p = V.get(q)
        if p is None:
            print("  %-28s NO VERDICT   %s" % (q, f.get("title", "")[:70]))
            continue
        keep = p >= args.threshold
        if keep:
            held.append(dict(f, jev=p))
        print("  %-28s %.2f %-9s %s" % (q, p, "HOLDS" if keep else "refuted",
                                        f.get("title", "")[:70]))
    print()
    if flat:
        print("REFUSING THIS RESULT: every verdict is within 0.02 of the others, which is what a call "
              "that never received its premise looks like. Check input_tokens on %s." % args.out)
        return 2
    if missing:
        print("%d question(s) came back without a verdict: %s" % (len(missing), ", ".join(missing)))
    print("%d of %d findings hold." % (len(held), len(data)))
    json.dump(held, open("scratchpad/jev-verified-findings.json", "w"), indent=1)
    print("survivors -> scratchpad/jev-verified-findings.json")
    return 0 if held else 1


if __name__ == "__main__":
    sys.exit(main())
