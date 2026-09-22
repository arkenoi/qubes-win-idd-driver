#!/usr/bin/env python3
"""Extract the reference profile of a stalled run from its own artefacts. CODE MEASURES.

A reproduction is only worth running if it matches the run it is trying to reproduce. This builds
the machine-readable profile of the reference failure; mgmt/harness/stall-repro-gate.sh measures a
candidate against it and asks Jev whether they are the same situation, BEFORE a pass is spent.

Honest by construction: fields the reference run never recorded are emitted as null with a reason,
because "unknown" is what makes a claimed 1:1 reproduction false.

    tools/stall-reference.py <run-dir> [--out mgmt/reference/<name>.json]
"""
import json, re, sys, os, glob

run = sys.argv[1].rstrip("/")
out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
log = os.path.join(run, "quick-upgrade.log")
txt = open(log, errors="replace").read() if os.path.exists(log) else ""

def find(rx, g=1):
    m = re.search(rx, txt, re.M)   # the log is line-oriented; ^ must anchor per line
    return m.group(g) if m else None

prof = {
    "reference_run": run,
    "outcome": "STALLED" if re.search(r"install STALLED|STALLED \(SPINNING\)|STALLED \(FROZEN\)", txt) else "NOT-STALLED",
    "golden": find(r"golden (\S+): VERIFIED"),
    "entry_qwt": find(r"entry: QWT products=\d+ versions=(\S+)"),
    "entry_agent": find(r"entry: QWT products=\d+ versions=\S+ agent=(\S+)"),
    "package": find(r"package: version (\S+)"),
    "read_from": find(r"install\.cmd /auto launch(?:ed| call)[^\n]*from (\S+)") or find(r"install\.cmd /auto launched from (\S+)"),
    "ordering": find(r"ordering: package (\S+ > golden \S+)"),
    "cd_boot": bool(re.search(r"booting \S+ with the release ISO as CD", txt)),
    "marker_written_utc": find(r"^(\d\d:\d\d:\d\d) .*run marker", 1) or None,
    "launch_line_utc": find(r"^(\d\d:\d\d:\d\d) .*install\.cmd /auto launch", 1) or None,
    "installer_output_lines": None,
    "last_answered_call": "run-marker write",
    "unrecorded_at_reference_time": [],
}
tail = os.path.join(run, "install.tail")
if os.path.exists(tail):
    prof["installer_output_lines"] = sum(1 for _ in open(tail, errors="replace"))

# What the reference run could NOT record, because the instrument did not exist yet. Naming these
# is the point: a candidate cannot be shown to match on a field the reference never captured.
for field, why in [
    ("guest_config_snapshot", "tools/guest-config-snapshot.sh was written after this run (2026-09-22)"),
    ("module_bases", "arm-module-bases was wired into quick-upgrade after this run (265440b)"),
    ("guest_side_install_log", "the guest was removed; C:\\qwt-improved-install.log did not survive"),
    ("event_channel_state_before_launch", "never captured by any harness"),
]:
    if not glob.glob(os.path.join(run, "*" + field.split("_")[0] + "*")):
        prof["unrecorded_at_reference_time"].append({"field": field, "why": why})

js = json.dumps(prof, indent=1)
print(js)
if out:
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w").write(js + "\n")
    print(f"\nwrote {out}", file=sys.stderr)
