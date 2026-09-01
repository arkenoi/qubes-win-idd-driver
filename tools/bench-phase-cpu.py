#!/usr/bin/env python3
"""Join gui-agent CPU samples to workload phases and print %-of-one-core per phase.

Input: the stdout of guest/phase-cpu-bench.ps1, which emits three blocks —

    === META ===      one JSON line: agent_pid, bin_sha256, screen
    === SAMPLES ===   "yyyyMMdd.HHmmss.fff <cumulative CPU seconds>", every ~250 ms
    === HARNESS ===   the "### PHASE-START/END <name> <stamp>" markers plus cadence lines

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


def parse(text):
    meta, samples, phases = {}, [], []
    block = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("=== META"):
            block = "meta"; continue
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
        elif block == "samples":
            m = re.match(r"^(\d{8}\.\d{6}\.\d{3})\s+([0-9.]+)$", line)
            if m:
                samples.append((parse_stamp(m.group(1)), float(m.group(2))))
        elif block == "harness":
            m = re.match(r"^### PHASE-(START|END)\s+(\S+)\s+(\d{8}\.\d{6}\.\d{3})$", line)
            if m:
                phases.append((m.group(1), m.group(2), parse_stamp(m.group(3))))
    return meta, samples, phases


def windows(phases):
    open_, out = {}, []
    for kind, name, t in phases:
        if kind == "START":
            open_[name] = t
        elif name in open_:
            out.append((name, open_.pop(name), t))
    return out


def cpu_pct(samples, t0, t1):
    """% of one core over [t0,t1], from the cumulative CPU-seconds counter."""
    inside = [(t, c) for t, c in samples if t0 <= t <= t1]
    if len(inside) < MIN_SAMPLES:
        return None, len(inside)
    wall = (inside[-1][0] - inside[0][0]).total_seconds()
    if wall <= 0:
        return None, len(inside)
    burned = inside[-1][1] - inside[0][1]
    if burned < 0:                 # the agent restarted mid-phase: the counter reset
        return None, len(inside)
    return 100.0 * burned / wall, len(inside)


def main(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    meta, samples, phases = parse(text)
    w = windows(phases)
    result = {"bin_sha256": meta.get("bin_sha256"), "agent_pid": meta.get("agent_pid"),
              "samples": len(samples), "phases": {}, "valid": True, "why": []}
    if not w:
        result["valid"] = False
        result["why"].append("no phase markers - the workload harness did not run")
    if len(samples) < MIN_SAMPLES:
        result["valid"] = False
        result["why"].append(f"only {len(samples)} CPU samples - the sampler produced nothing usable")
    for name, t0, t1 in w:
        pct, n = cpu_pct(samples, t0, t1)
        result["phases"][name] = {"pct_core": None if pct is None else round(pct, 3),
                                  "samples": n,
                                  "wall_s": round((t1 - t0).total_seconds(), 2)}
        if pct is None:
            result["valid"] = False
            result["why"].append(f"phase {name}: {n} samples (< {MIN_SAMPLES}) - no number")
    print(json.dumps(result, indent=2))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
