#!/usr/bin/env python3
"""Print the basename if log-sweep.py's decode meta.json records it as partial=1.

Called by tools/sweep-gate.sh. Separate file on purpose: inlining it as a heredoc inside the gate
put a `PY` terminator inside another `PY` heredoc while this was being written, which ended the
outer one and produced a syntax error in a shell script that had parsed a moment earlier.

A truncated pull is head + W/E/suspicious + tail and nothing else, so the gate cannot call such an
input clean: an error between those windows is simply absent from it. Missing data fails.
"""
import json
import os
import sys

if len(sys.argv) != 3:
    sys.exit(0)
meta_path, want = sys.argv[1], sys.argv[2]
try:
    with open(meta_path, encoding="utf-8") as fh:
        meta = json.load(fh)
except Exception:
    # UNREADABLE META IS NOT "NOT PARTIAL", but it is also not this tool's verdict to give: the
    # gate's own proof-of-life refuses an input it cannot read, and inventing a truncation here
    # would make every missing meta.json an INCONCLUSIVE.
    sys.exit(0)
for entry in (meta.get("files") or []):
    if os.path.basename(str(entry.get("local") or "")) == want and str(entry.get("partial", "0")) == "1":
        print(want)
        break
