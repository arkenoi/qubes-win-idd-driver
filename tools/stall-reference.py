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
    # PROVENANCE. The 2026-09-22 failure did not happen under a bare quick-upgrade: it happened
    # inside a feature test that calls quick-upgrade as its setup step. A reproduction that invokes
    # quick-upgrade directly has already deviated, which is what 16 A/B runs did without anyone
    # noticing. Detected, not assumed: the caller is the log that names this subject and window.
    "invoked_by": None,
    "unrecorded_at_reference_time": [],
}
subj = find(r"quick-upgrade\[(\S+?)\]")
if subj:
    for cand in glob.glob("/home/user/qwt-accept/*/*.log") + glob.glob("/home/user/qubes-win-idd-driver/scratchpad/*.log"):
        if os.path.basename(cand).startswith("quick-upgrade"):
            continue
        try:
            t = open(cand, errors="replace").read()
        except OSError:
            continue
        if subj in t and "quick-upgrade" in t:
            # Record the HARNESS that ran, not the log file it was found in: comparing
            # "notify-errors-guest-test.log" against "notify-errors-guest-test.sh" reads as a
            # mismatch to anything judging the two strings.
            prof["invoked_by"] = re.sub(r"\.log$", ".sh", os.path.basename(cand))
            break
prof["subject"] = subj

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

# WHAT THE SPECIMEN ACTUALLY KNOWS. The first version recorded twelve fields and left the gate to
# weigh "reference-unknowns" above every concrete match - correctly, because the profile was thin
# while the evidence directory was not. These are read from the artefacts, not asserted.
prof["failure_shape"] = {}
ev = sorted(glob.glob("/home/user/qubes-win-idd-driver/scratchpad/stall-win11nfy-*"))
if ev:
    d0 = ev[-1]
    prof["failure_shape"]["evidence_dir"] = d0
    vl = sorted(glob.glob(os.path.join(d0, "**", "vcpu-list-*.txt"), recursive=True))
    if len(vl) >= 2:
        def vcpus(f):
            out = []
            for ln in open(f, errors="replace"):
                m = re.match(r"\s*\S+\s+\d+\s+(\d+)\s+\d+\s+(\S+)\s+([\d.]+)", ln)
                if m:
                    out.append((int(m.group(1)), m.group(2), float(m.group(3))))
            return out
        a, b = vcpus(vl[0]), vcpus(vl[-1])
        if a and b and len(a) == len(b):
            prof["failure_shape"]["vcpu_cputime_delta_between_first_and_last_capture_s"] = [
                {"vcpu": x[0], "state": x[1], "delta_s": round(y[2] - x[2], 1)} for x, y in zip(a, b)]
    rips = sorted(glob.glob(os.path.join(d0, "**", "rip-d*.txt"), recursive=True))
    if rips:
        got = []
        for f in rips[:2]:
            got += re.findall(r"RIP:\s+(\S+):\[<([0-9a-f]+)>\]", open(f, errors="replace").read())
        prof["failure_shape"]["guest_rips"] = [f"{cs}:{a}" for cs, a in got if cs == "0010"]
    lb = glob.glob(os.path.join(d0, "loopback.txt"))
    if lb:
        t = open(lb[0], errors="replace").read()
        m = re.findall(r"(vbd-\S+)\s+->\s+domain\s+(\d+)\s+state=(\S+)", t)
        prof["failure_shape"]["block_backends_at_stall"] = [f"{x} dom{y} {z}" for x, y, z in m]

# The timeline that the 1:1 read established, in machine form.
prof["timeline"] = {
    "last_answered_call": "run-marker write",
    "last_answered_utc": prof.get("marker_written_utc"),
    "next_call": "cmd /c start \"\" /min <disc>:\\install.cmd /auto /autologon:qubes",
    "next_call_outcome": "did NOT return - 60s grun timeout",
    "next_call_timeout_utc": prof.get("launch_line_utc"),
    "installer_output_lines_produced": prof.get("installer_output_lines"),
    "window_seconds_between_the_two_calls": 60,
    "note": "the harness line saying install.cmd was launched is printed unconditionally and is not evidence the installer ran",
}

js = json.dumps(prof, indent=1)
print(js)
if out:
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w").write(js + "\n")
    print(f"\nwrote {out}", file=sys.stderr)
