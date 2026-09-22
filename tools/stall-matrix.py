#!/usr/bin/env python3
"""Build the stalled-vs-clean run matrix from the artefacts on disk. CODE MEASURES.

Every run of the QWT install/upgrade class leaves a log. This reads them, extracts the fields that
can be read deterministically, and prints one row per run plus a presence table. It decides NOTHING:
the judgment - is a factor necessary, does its absence explain the failed reproductions - goes to
Jev in a single call, which is what tools/jev.py is for.

Written 2026-09-22 after the differential was handed to a fleet of reasoning agents, which is the
inversion the jev skill warns about: counting and matching stay in code.

    tools/stall-matrix.py [--json out.json]
"""
import json, re, sys, os, glob

ROOTS = [
    "/home/user/qwt-quick-upgrade",
    "/home/user/qwt-accept",
    "/home/user/qubes-win-idd-driver/scratchpad",
    "/home/user/qubes-win-idd-driver/evidence",
]

# A run is any log that carries the installer launch line; the outcome is read from the same log.
LAUNCH = re.compile(r"install\.cmd /auto launched from (\S+)")
STALL  = re.compile(r"TERMINAL: install STALLED|STALLED \(SPINNING\)|STALLED \(FROZEN\)")
RESULT = re.compile(r"install reported a RESULT|RESULT trailer|summary: \d+ passed")
FIELDS = {
    "entry":     re.compile(r"entry: QWT products=\d+ versions=(\S+) agent=(\S+)"),
    "package":   re.compile(r"package: version (\S+)"),
    "golden":    re.compile(r"golden (\S+): VERIFIED"),
    "branch":    re.compile(r"installer branch = (\S+)"),
    "staged":    re.compile(r"staged to C:\\qwtstage"),
    "cdboot":    re.compile(r"booting \S+ with the release ISO as CD"),
    "modbases":  re.compile(r"module-base recorder armed"),
    "subject":   re.compile(r"quick-upgrade\[(\S+?)\]"),
    "ordering":  re.compile(r"ordering: package (\S+) > golden (\S+)"),
}

def scan(path):
    try:
        with open(path, errors="replace") as fh:
            txt = fh.read()
    except OSError:
        return None
    m = LAUNCH.search(txt)
    if not m:
        return None
    row = {"log": path, "read_from": m.group(1)}
    row["outcome"] = "STALLED" if STALL.search(txt) else ("RESULT" if RESULT.search(txt) else "UNKNOWN")
    for k, rx in FIELDS.items():
        mm = rx.search(txt)
        if not mm:
            row[k] = None
        elif rx.groups == 0:
            row[k] = True
        elif rx.groups == 1:
            row[k] = mm.group(1)
        else:
            row[k] = "/".join(mm.groups())
    ts = re.search(r"^(\d\d:\d\d:\d\d)", txt, re.M)
    row["first_ts"] = ts.group(1) if ts else None
    row["bytes"] = len(txt)
    return row

rows = []
seen = set()
for root in ROOTS:
    for path in glob.glob(root + "/**/*.log", recursive=True):
        rp = os.path.realpath(path)
        if rp in seen:
            continue
        seen.add(rp)
        r = scan(path)
        if r:
            rows.append(r)

rows.sort(key=lambda r: r["log"])
stalled = [r for r in rows if r["outcome"] == "STALLED"]
clean   = [r for r in rows if r["outcome"] == "RESULT"]
unknown = [r for r in rows if r["outcome"] == "UNKNOWN"]

print(f"runs found: {len(rows)}  (STALLED {len(stalled)} / RESULT {len(clean)} / UNKNOWN {len(unknown)})")
print()
KEYS = ["read_from", "entry", "package", "golden", "branch", "staged", "cdboot", "modbases", "ordering"]
print("=== presence per field, by outcome (counts, not impressions) ===")
for k in KEYS:
    vs = {}
    for label, group in (("STALLED", stalled), ("RESULT", clean)):
        tally = {}
        for r in group:
            tally[str(r.get(k))] = tally.get(str(r.get(k)), 0) + 1
        vs[label] = tally
    print(f"\n{k}:")
    for label in ("STALLED", "RESULT"):
        items = sorted(vs[label].items(), key=lambda kv: -kv[1])
        print(f"  {label:8s} " + ", ".join(f"{v}={n}" for v, n in items) or f"  {label}: none")

print("\n=== the stalled rows in full ===")
for r in stalled:
    print(" ", json.dumps(r))

if "--json" in sys.argv:
    out = sys.argv[sys.argv.index("--json") + 1]
    with open(out, "w") as fh:
        json.dump({"rows": rows, "stalled": stalled, "clean": clean, "unknown": unknown}, fh, indent=1)
    print(f"\nwrote {out}")
