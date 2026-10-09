#!/usr/bin/env python3
"""prose-brief.py - emit one rewrite BRIEF per planned file, from its plan, in code.

A rewrite agent must not have to work out what to cut: that is already decided and recorded per
unit. This writes the brief (the cut list with line ranges, the hard constraints, the staging path)
so the model spends its tokens writing prose and nothing else.
"""
import json, os, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "scratchpad", "prose-audit2")
CUT = ("narrative", "closed", "rant", "redundant")

CONSTRAINTS = {
 "docs/ADR-": "ADR SECTION NUMBERS ARE STABLE. Never renumber, never delete a numbered section. A dead\n"
              "decision keeps its number and gets Status REJECTED / SUPERSEDED by N / RETIRED / WITHDRAWN.\n"
              "Status and Decision are mandatory in every section (docs/ADR-README.md is the contract).\n"
              "Compress hard INSIDE a section; the heading line itself is structure - keep it verbatim.",
 "findings/": "Every bullet under '## CURRENT STATE' must END with [verified YYYY-MM-DD] or contain\n"
              "UNVERIFIED (tools/lint-harness.py rule L8). Keep those tokens exactly as they are.\n"
              "In issues.md / issues-closed.md a FIELD-REPORTED entry may NOT be said to be closed by a\n"
              "release, and may not move to issues-closed.md, without the token REPORTER-CONFIRMED.",
 ".claude/skills/": "Keep the YAML frontmatter (name, description) byte-identical - the description is how\n"
              "the skill gets loaded at the right moment. Keep every command, path and flag verbatim.",
 "CLAUDE.md":  "THIS FILE IS BINDING. NO RULE MAY BE LOST OR WEAKENED. You may only shorten wording.\n"
              "If you believe a rule is redundant, LEAVE IT and say so in your report.",
}

def constraints_for(rel):
    out = []
    for k, v in CONSTRAINTS.items():
        if rel == k or rel.startswith(k):
            out.append(v)
    return "\n".join(out) or "No file-class constraint beyond the general rules."

def main():
    plans = json.load(open(os.path.join(OUT, "plans.json"), encoding="utf-8"))
    sel = sys.argv[1:] or None
    briefdir = os.path.join(OUT, "briefs"); os.makedirs(briefdir, exist_ok=True)
    index = []
    for p in plans:
        rel = os.path.relpath(p["file"], ROOT)
        if sel and rel not in sel:
            continue
        cuts = [r for r in p["rows"] if r["class"] in CUT]
        weak = [r for r in p["rows"] if r["class"] == "insufficient-evidence"]
        L = []
        L.append("REWRITE BRIEF: %s" % rel)
        L.append("=" * 78)
        L.append("Original: %s bytes, %d units. Classified per unit by Jev; the verdicts are decided." % (format(p["bytes"], ","), p["units"]))
        L.append("Write the rewrite to: scratchpad/prose-audit2/staged/%s" % rel)
        L.append("NEVER edit %s itself." % rel)
        L.append("")
        L.append("WHAT TO DO")
        L.append("  1. CUT the units listed below outright. They are history, closed matters, repetition or")
        L.append("     self-criticism; the rules they sit around live in OTHER units and must survive.")
        L.append("  2. COMPACT everything else: same facts, fewer and simpler sentences. Prefer short")
        L.append("     declaratives. Drop 'I/we discovered', dates that date nothing, who was annoyed, how")
        L.append("     long it took, and score-keeping. KEEP every rule, caveat, number, path, command,")
        L.append("     log tag, constant, flag, defect discriminator and cost.")
        L.append("  3. A historical reference STAYS only if it changes what someone would do.")
        L.append("  4. Do not invent, do not generalise, do not add advice that was not there.")
        L.append("  5. Keep the file's markdown shape: headings, tables and fenced blocks stay.")
        L.append("")
        L.append("HARD CONSTRAINTS FOR THIS FILE")
        for line in constraints_for(rel).splitlines():
            L.append("  " + line)
        L.append("")
        if cuts:
            L.append("CUT THESE %d UNIT(S) - line ranges in the ORIGINAL:" % len(cuts))
            for r in cuts:
                L.append("  lines %-12s %-10s %5dB  conf=%.2f" % ("%d-%d" % tuple(r["lines"]), r["class"], r["bytes"], r["conf"] or 0))
                L.append("      %s" % r["head"][:120])
        else:
            L.append("CUT LIST: empty - no unit was classified as removable. Compact wording only;")
            L.append("          removing content from this file is NOT authorised.")
        L.append("")
        if weak:
            L.append("%d unit(s) the judge could not classify even after a re-ask. LEAVE THEM AS THEY ARE" % len(weak))
            L.append("and name them in your report:")
            for r in weak:
                L.append("  lines %-12s %s" % ("%d-%d" % tuple(r["lines"]), r["head"][:110]))
            L.append("")
        L.append("WHEN DONE, report: bytes before/after, which units you cut, anything you were told to cut")
        L.append("but kept (with the reason), and anything you could not decide. Facts only.")
        bp = os.path.join(briefdir, rel.replace("/", "__") + ".brief.txt")
        with open(bp, "w", encoding="utf-8") as f:
            f.write("\n".join(L) + "\n")
        index.append({"file": rel, "brief": os.path.relpath(bp, ROOT), "bytes": p["bytes"],
                      "units": p["units"], "cuts": len(cuts), "cut_bytes": sum(r["bytes"] for r in cuts),
                      "high_stakes": p["high_stakes"]})
    with open(os.path.join(OUT, "briefs.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=1)
    print("%d brief(s) written to %s" % (len(index), os.path.relpath(briefdir, ROOT)))
    return 0

if __name__ == "__main__":
    sys.exit(main())
