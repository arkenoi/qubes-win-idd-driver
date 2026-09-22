#!/usr/bin/env python3
"""Field-by-field comparison of a candidate run against a reference failure. CODE MEASURES.

Handing two json documents to a judge and asking "do these match" invites it to weigh everything at
once - which is how a candidate matching every recorded field still scored 0.57, dragged down by
the reference's unknowns. The comparison is arithmetic; it belongs here. The judge then answers one
enumerable question: is any line marked DIFFERS.

    tools/compare-run-to-reference.py <reference.json> <candidate.json>
"""
import json, sys

FIELDS = ("golden", "entry_qwt", "entry_agent", "package", "read_from", "cd_boot", "invoked_by", "subject")

ref = json.load(open(sys.argv[1]))
try:
    cand = json.load(open(sys.argv[2]))
except Exception:
    cand = {}

diffs = 0
for k in FIELDS:
    r, c = ref.get(k), cand.get(k)
    if r is None:
        print(f"  {k}: UNKNOWN-IN-REFERENCE (candidate={c})")
    elif str(r) == str(c):
        print(f"  {k}: MATCH ({r})")
    else:
        print(f"  {k}: DIFFERS  reference={r}  candidate={c}")
        diffs += 1
print(f"  --- {diffs} field(s) marked DIFFERS out of {len(FIELDS)} compared")
