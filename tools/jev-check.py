#!/usr/bin/env python3
"""Put an arbitrary set of claims to Jev as ONE call and print comparable verdicts.

For checking an INTERMEDIATE RESULT - a stage's output, before the next stage spends anything on it.
Owner, 2026-10-21: "double check with Jev EVERY intermediate result", and Jev goes BEFORE the
expensive model stage, not after it, so the cheap comparable judgement is what filters the list.

One call, not one per claim: N separate calls give N differently-anchored numbers that cannot be
compared. The receipt is kept so the verdict is auditable, and a result where every answer lands on
the same value is refused rather than reported - that is the shape of a call whose premise never
arrived (see jev-has-no-attach-check-input-tokens).

SPEC.json:
    {
      "artifact": "markdown the judge reads - the evidence, quoted, not described",
      "artifact_files": ["path", ...],          # optional, appended to the artifact
      "questions": {
        "<id>": {"judge": "...", "true": "...", "false": "..."},
        ...
      }
    }

Usage:
    jev-check.py SPEC.json [--out scratchpad/jev-check-out.json] [--threshold 0.5]

Exit status: 0 if every question answered, 1 if some answered below threshold, 2 on error or on a
flat result that cannot be believed.
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("spec")
    ap.add_argument("--out", default="scratchpad/jev-check-out.json")
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--tag", default="check")
    args = ap.parse_args()

    spec = json.load(open(args.spec, encoding="utf-8"))
    qs_in = spec.get("questions") or {}
    if not qs_in:
        print("jev-check: SPEC has no questions", file=sys.stderr)
        return 2

    body = [spec.get("artifact", "")]
    for rel in spec.get("artifact_files", []):
        p = ROOT / rel
        if p.is_file():
            body.append("\n\n## %s\n\n```\n%s\n```\n"
                        % (rel, p.read_text(encoding="utf-8", errors="replace")))
        else:
            body.append("\n\n## %s\n\n(not a file in the repo)\n" % rel)

    art = "scratchpad/jev-%s-artifact.md" % args.tag
    rub = "scratchpad/jev-%s-rubric.json" % args.tag
    (ROOT / art).write_text("".join(body), encoding="utf-8")
    json.dump({"questions": {
        qid: {"type": "noul",
              "instructions": {"judge": q["judge"]},
              "criteria": {"true": q["true"], "false": q["false"]}}
        for qid, q in qs_in.items()}}, open(ROOT / rub, "w"), indent=0)

    env = dict(os.environ, JEV_ARTIFACT_OUT=args.out)
    r = subprocess.run(["tools/jev-artifact.sh", rub, art],
                       cwd=str(ROOT), env=env, capture_output=True, text=True)
    sys.stderr.write(r.stderr)
    print(r.stdout, end="")
    if r.returncode != 0 or not (ROOT / args.out).exists():
        print("jev-check: the Jev call failed (rc=%d). No verdict, so nothing downstream may claim "
              "one." % r.returncode, file=sys.stderr)
        return 2

    raw = (ROOT / args.out).read_text(encoding="utf-8")
    V = {m.group(1): float(m.group(2)) for m in re.finditer(
        r'"([A-Za-z0-9_]+)"\s*:\s*\{[^{}]*?"(?:noul|probability|p)"\s*:\s*([0-9.]+)', raw, re.S)}
    V = {k: v for k, v in V.items() if k in qs_in}

    vals = sorted(V.values())
    if len(vals) > 2 and (vals[-1] - vals[0]) < 0.02:
        print("\nREFUSING THIS RESULT: all %d verdicts land within 0.02 of each other, which is what "
              "a call that never received its premise looks like. Check input_tokens in %s."
              % (len(vals), args.out))
        return 2

    print("\n=== JEV (threshold %.2f) ===" % args.threshold)
    low = []
    for qid in qs_in:
        p = V.get(qid)
        if p is None:
            print("  %-34s NO VERDICT" % qid)
            low.append(qid)
            continue
        print("  %-34s %.2f %s" % (qid, p, "ok" if p >= args.threshold else "BELOW"))
        if p < args.threshold:
            low.append(qid)
    json.dump(V, open(ROOT / ("scratchpad/jev-%s-verdicts.json" % args.tag), "w"), indent=1)
    print("receipt: %s   verdicts: scratchpad/jev-%s-verdicts.json" % (args.out, args.tag))
    return 1 if low else 0


if __name__ == "__main__":
    sys.exit(main())
