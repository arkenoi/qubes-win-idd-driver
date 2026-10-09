#!/usr/bin/env python3
"""prose-xref.py - find every LINE-NUMBER citation that points into a file we are rewriting.

Why: batch 06 reported that at least eleven files - including C headers, a test, a harness script and
another design doc - cite docs/DESIGN-toast-bridge.md by line range (`:165-177`). A rewrite silently
invalidates every one of them, and several were ALREADY stale. This is exact matching over the tree,
so it belongs in a script, and it has to run before any rewrite is applied.

    tools/prose-xref.py [--staged DIR] [file ...]
"""
import argparse, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "scratchpad", "prose-audit2")
SKIP_DIRS = {".git", "scratchpad", "evidence", "__pycache__", "node_modules", "protocol/state"}

def tracked():
    p = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True)
    return [f for f in p.stdout.splitlines()
            if not any(f == d or f.startswith(d + "/") for d in SKIP_DIRS)]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--staged", default=os.path.join(OUT, "staged"))
    ap.add_argument("--fix", action="store_true",
                    help="replace each broken LINE citation with the SECTION reference it resolves to")
    a = ap.parse_args()

    targets = a.files
    if not targets:
        try:
            targets = [b["file"] for b in json.load(open(os.path.join(OUT, "briefs.json"), encoding="utf-8"))]
        except OSError:
            print("prose-xref: no file list and no briefs.json"); return 2
    tset = {os.path.basename(t): t for t in targets}

    # A citation is <name><sep><line>[-<line>], where sep is ':' or ' line(s) '.
    pat = re.compile(r"(?P<name>[A-Za-z0-9._\-/]+\.(?:md|ps1|py|sh|c|cpp|h|json|cmd))"
                     r"(?::|\s+lines?\s+)(?P<a>\d{1,6})(?:\s*[-–]\s*(?P<b>\d{1,6}))?")
    hits = []
    for f in tracked():
        p = os.path.join(ROOT, f)
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                for n, line in enumerate(fh, 1):
                    for m in pat.finditer(line):
                        cited_path = m.group("name")
                        base = os.path.basename(cited_path)
                        if base not in tset:
                            continue
                        if "/" in cited_path and not (
                                tset[base] == cited_path or tset[base].endswith("/" + cited_path)):
                            continue
                        if True:
                            hits.append({"citing_file": f, "citing_line": n,
                                         "target": tset[base], "cited_as": m.group(0),
                                         "from": int(m.group("a")),
                                         "to": int(m.group("b") or m.group("a")),
                                         "self": os.path.basename(f) == base})
        except (OSError, UnicodeDecodeError):
            continue

    ext = [h for h in hits if not h["self"]]
    # Which of them point past the end of the STAGED rewrite - i.e. certainly broken by it?
    def lines_of(path):
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()

    def norm(x):
        return re.sub(r"\s+", " ", x).strip().lower()

    def enclosing_section(ls, n):
        """The heading that owns line n in the ORIGINAL - the durable replacement for a line number."""
        for i in range(min(n, len(ls)) - 1, -1, -1):
            if re.match(r"^#{1,6} ", ls[i]):
                return ls[i].lstrip("# ").strip()
        return None

    for h in ext:
        sp = os.path.join(a.staged, h["target"])
        op = os.path.join(ROOT, h["target"])
        h["staged_exists"] = os.path.exists(sp)
        try:
            ol = lines_of(op)
        except OSError:
            ol = []
        h["section"] = enclosing_section(ol, h["from"]) if ol else None
        cited = norm(" ".join(ol[h["from"] - 1:h["to"]])) if ol else ""
        h["cited_text_head"] = cited[:110]
        if h["staged_exists"]:
            nl = lines_of(sp)
            h["staged_lines"] = len(nl)
            h["past_end"] = h["to"] > len(nl)
            # A CITATION THAT IS STILL IN RANGE CAN STILL BE WRONG. The real question is whether the
            # SAME line range in the rewrite still carries the text that was cited. "past end" only
            # catches the blatant cases, and 0 of 39 were blatant.
            same = norm(" ".join(nl[h["from"] - 1:h["to"]]))
            h["same_text_at_range"] = bool(cited) and (cited == same)
            h["broken"] = not h["same_text_at_range"]
            # does the cited text survive ANYWHERE in the rewrite?
            h["text_survives_somewhere"] = bool(cited) and cited[:80] in norm(" ".join(nl))
        else:
            h["staged_lines"] = None
            h["past_end"] = None
            h["same_text_at_range"] = None
            h["broken"] = None
            h["text_survives_somewhere"] = None

    by_t = {}
    for h in ext:
        by_t.setdefault(h["target"], []).append(h)
    print("LINE-NUMBER CITATIONS INTO FILES BEING REWRITTEN")
    print("  %d citation(s) from %d distinct file(s) into %d rewritten target(s)"
          % (len(ext), len({h["citing_file"] for h in ext}), len(by_t)))
    for t in sorted(by_t, key=lambda x: -len(by_t[x])):
        hs = by_t[t]
        staged = hs[0]["staged_exists"]
        past = sum(1 for h in hs if h["past_end"])
        print("\n  %s  <- %d citation(s)%s" % (t, len(hs),
              ("   [staged rewrite is %d lines; %d citation(s) now point PAST ITS END]"
               % (hs[0]["staged_lines"], past)) if staged else "   [not yet rewritten]"))
        for h in sorted(hs, key=lambda x: (x["citing_file"], x["citing_line"]))[:40]:
            flag = ""
            if h["broken"]:
                flag = "  BROKEN" + ("" if h["text_survives_somewhere"] else " (text gone too)")
            elif h["broken"] is False:
                flag = "  intact"
            print("      %-50s :%-5d %-28s%s" % (h["citing_file"], h["citing_line"], h["cited_as"], flag))
            if h["broken"] and h["section"]:
                print("          -> cite as: %s \u00a7 %s" % (h["target"], h["section"][:70]))
    with open(os.path.join(OUT, "xref.json"), "w", encoding="utf-8") as f:
        json.dump(ext, f, indent=1)
    print("\nwritten: %s" % os.path.relpath(os.path.join(OUT, "xref.json"), ROOT))
    br = [h for h in ext if h["broken"]]
    gone = [h for h in br if not h["text_survives_somewhere"]]
    print("\nBROKEN BY THE STAGED REWRITES: %d of %d citation(s) no longer find their text at the "
          "cited range." % (len(br), len([h for h in ext if h["staged_exists"]])))
    if gone:
        print("  %d of those cite text that is not in the rewrite AT ALL - check those for a real loss:"
              % len(gone))
        for h in gone[:20]:
            print("     %s:%d -> %s | %s" % (h["citing_file"], h["citing_line"], h["cited_as"],
                                             h["cited_text_head"][:70]))
    if a.fix:
        # Mechanical substitution of a computed replacement - code's job, not a model's.
        edits = {}
        for h in br:
            if not h["section"]:
                continue
            new_ref = "%s \u00a7 %s" % (h["target"], h["section"])
            edits.setdefault(h["citing_file"], []).append((h["cited_as"], new_ref))
        changed = 0
        for f, subs in sorted(edits.items()):
            fp = os.path.join(ROOT, f)
            try:
                txt = open(fp, encoding="utf-8").read()
            except (OSError, UnicodeDecodeError) as e:
                print("  SKIP %s (%s)" % (f, e)); continue
            n = 0
            for old_ref, new_ref in subs:
                if old_ref in txt:
                    txt = txt.replace(old_ref, new_ref)
                    n += 1
            if n:
                open(fp, "w", encoding="utf-8").write(txt)
                changed += n
                print("  fixed %2d citation(s) in %s" % (n, f))
        print("\n%d citation(s) rewritten to section references." % changed)
    else:
        print("A line citation into a rewritten file is broken by the rewrite. Re-run with --fix to "
              "replace each with the SECTION reference printed above, which a rewrite cannot invalidate.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
