#!/usr/bin/env python3
"""Join GUI CPU samples to workload phases and print %-of-one-core per phase.

Input: the stdout of guest/phase-cpu-bench.ps1, which emits these blocks —

    === META ===      one JSON line: agent_pid, bin_sha256, screen, sampler
    === FAMILY ===    one JSON line: every family process sampled (name:pid), and any whose CPU
                      counter could not be read (sampler family-v2 only)
    === SAMPLES ===   "yyyyMMdd.HHmmss.fff <cumulative CPU seconds>", every ~250 ms
    === HARNESS ===   the "### PHASE-START/END <name> <stamp>" markers plus cadence lines

TWO SAMPLE FORMATS. Before 2026-09-30 a sample carried ONE number, gui-agent's own CPU. The de-slice
moved capture into wgcbroker.exe, so that number stopped being our cost; sampler family-v2 carries
"<stamp> <family> <agent> <seen> <live> <dwm> <system>": the running total over gui-agent, wgcbroker,
notifhost and etwproxy; gui-agent's raw counter; how many family pids have been seen and how many
are alive; DWM's running total; whole-guest busy seconds (all CPUs). pct_core is the FAMILY on a v2
run and the agent on an old one, and the output says which ("metric") - the summariser refuses to
compare the two.

The metric is the one behind docs/BENCHMARKS.md: cumulative process CPU seconds consumed
inside a phase window, divided by that window's wall time, as a percentage of one core.
It needs no instrumentation inside the agent, which is what makes STOCK measurable at all —
stock emits no QGAPERF records, so any per-frame metric is ours-only by construction.

MISSING DATA FAILS. A phase with fewer than MIN_SAMPLES samples, or a run with no markers, is
reported INVALID and carries no number. A benchmark that silently prints 0.00 for a phase it
could not sample is worse than one that refuses: the 2026-08-09 run already lost a repetition
to a CPU sampler that produced nothing and was correctly emitted as `na`, not as zero.
"""
import json
import re
import sys
from datetime import datetime

MIN_SAMPLES = 4  # at 250 ms, four samples is ~1 s of window; below that the rate is noise


def parse_stamp(s):
    return datetime.strptime(s, "%Y%m%d.%H%M%S.%f")


SAMPLE = re.compile(r"^(\d{8}\.\d{6}\.\d{3})\s+([0-9.]+)"
                    r"(?:\s+([0-9.]+)\s+(\d+)\s+(\d+)\s+([0-9.]+)\s+(-?[0-9.]+))?$")


def parse(text):
    meta, family, samples, phases = {}, {}, [], []
    block = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("=== META"):
            block = "meta"; continue
        if line.startswith("=== FAMILY"):
            block = "family"; continue
        if line.startswith("=== SAMPLES"):
            block = "samples"; continue
        if line.startswith("=== HARNESS"):
            block = "harness"; continue
        if line.startswith("=== END"):
            block = None; continue
        if block == "meta" and line.startswith("{"):
            try:
                meta = json.loads(line)
            except json.JSONDecodeError:
                pass
        elif block == "family" and line.startswith("{"):
            try:
                family = json.loads(line)
            except json.JSONDecodeError:
                family = {"unparseable": line}
        elif block == "samples":
            m = SAMPLE.match(line)
            if m:
                # (stamp, family-or-agent, agent, seen, live, dwm, system); None past column 2 on an old run
                samples.append((parse_stamp(m.group(1)), float(m.group(2)))
                               + tuple(None if g is None else (int(g) if i in (1, 2) else float(g))
                                       for i, g in enumerate(m.groups()[2:])))
        elif block == "harness":
            m = re.match(r"^### PHASE-(START|END)\s+(\S+)\s+(\d{8}\.\d{6}\.\d{3})$", line)
            if m:
                phases.append((m.group(1), m.group(2), parse_stamp(m.group(3))))
    return meta, family, samples, phases


def windows(phases):
    open_, out = {}, []
    for kind, name, t in phases:
        if kind == "START":
            open_[name] = t
        elif name in open_:
            out.append((name, open_.pop(name), t))
    return out


def cpu_pct(samples, t0, t1, col=1):
    """% of one core over [t0,t1], from the cumulative CPU-seconds counter in column `col`."""
    inside = [s for s in samples if t0 <= s[0] <= t1]
    if len(inside) < MIN_SAMPLES:
        return None, len(inside)
    if inside[0][col] is None or inside[-1][col] is None or inside[0][col] < 0 or inside[-1][col] < 0:
        return None, len(inside)   # this run has no such column, or the guest could not read it
    wall = (inside[-1][0] - inside[0][0]).total_seconds()
    if wall <= 0:
        return None, len(inside)
    burned = inside[-1][col] - inside[0][col]
    if burned < 0:                 # a raw counter went back: the process restarted mid-phase
        return None, len(inside)
    return 100.0 * burned / wall, len(inside)


def family_changed(samples, t0, t1):
    """A family process started or exited inside the phase: it measured a transition, not the workload."""
    inside = [s for s in samples if t0 <= s[0] <= t1]
    if not inside or inside[0][3] is None:
        return False
    return inside[0][3] != inside[-1][3] or inside[0][4] != inside[-1][4]


def main(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    meta, family, samples, phases = parse(text)
    w = windows(phases)
    v2 = meta.get("sampler") == "family-v2"
    result = {"bin_sha256": meta.get("bin_sha256"), "agent_pid": meta.get("agent_pid"),
              "metric": "family" if v2 else "agent", "family": family.get("seen"),
              "samples": len(samples), "phases": {}, "valid": True, "why": []}
    if v2 and (not family or "unparseable" in family):
        result["valid"] = False
        result["why"].append("sampler family-v2 wrote no readable FAMILY block - which processes were counted is unknown")
    if family.get("unreadable"):
        result["valid"] = False
        result["why"].append(f"CPU counter unreadable for {family['unreadable']} - their cost is missing, not zero")
    if v2 and any(s[2] is None for s in samples):
        result["valid"] = False
        result["why"].append("sampler family-v2 but some samples carry one column - mixed or truncated output")
    if not w:
        result["valid"] = False
        result["why"].append("no phase markers - the workload harness did not run")
    if len(samples) < MIN_SAMPLES:
        result["valid"] = False
        result["why"].append(f"only {len(samples)} CPU samples - the sampler produced nothing usable")
    for name, t0, t1 in w:
        pct, n = cpu_pct(samples, t0, t1)
        ph = {"pct_core": None if pct is None else round(pct, 3), "samples": n,
              "wall_s": round((t1 - t0).total_seconds(), 2)}
        if pct is None:
            result["valid"] = False
            result["why"].append(f"phase {name}: {n} samples (< {MIN_SAMPLES}) - no number")
        if v2:
            for key, col in (("pct_core_agent", 2), ("pct_core_dwm", 5), ("pct_core_system", 6)):
                x, _ = cpu_pct(samples, t0, t1, col)
                ph[key] = None if x is None else round(x, 3)
                if x is None and pct is not None:
                    result["valid"] = False
                    result["why"].append(f"phase {name}: no {key} (a raw counter went back, or it was unreadable)")
            if family_changed(samples, t0, t1):
                result["valid"] = False
                result["why"].append(f"phase {name}: a family process started or exited inside it")
        result["phases"][name] = ph
    print(json.dumps(result, indent=2))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
