#!/usr/bin/env python3
"""Grade a protocol dry-run against its scenario's ground truth, mechanically.

This is the deviation instrument for operator evaluation AND the assertion engine for
protocol/selftest.sh. It never judges prose: it diffs the runner's recorded state against the
scenario's `expect` block and prints one line per deviation.

  protocol/grade.py <campaign-id> [--harvest]

Exit 0 = no deviations. 1 = deviations (each printed). 2 = unusable input.

--harvest: for every step whose `falsified_by` names this campaign's scenario and which went RED
with a FAIL/INVALID verdict, record a dry-grade fail-proof in protocol/failproofs.json. This is
how V1's registry is EARNED rather than hand-written: a check gets its entry only by being
observed to fail on its defect-armed fixture. Dry-grade proofs upgrade dry-mode PASS only; a
live campaign still demands a live-grade proof (diag build / real defect).
"""
from __future__ import annotations
import json, re, sys, time
from pathlib import Path

PROTO = Path(__file__).resolve().parent
FAILPROOFS = PROTO / "failproofs.json"


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    harvest = "--harvest" in sys.argv
    if len(args) != 1:
        print(__doc__)
        return 2
    cdir = PROTO / "state" / args[0]
    state_p = cdir / "state.json"
    if not state_p.exists():
        print(f"UNUSABLE: no state at {state_p}")
        return 2
    st = json.loads(state_p.read_text())
    if st["mode"] != "dry" or not st.get("scenario"):
        print("UNUSABLE: grading applies to dry-run campaigns with a scenario")
        return 2
    scen = json.loads((Path(st["scenario"]) / "truth.json").read_text())
    expect = scen.get("expect") or {}
    dev: list[str] = []

    # step order, from the same files the runner loaded
    order: list[dict] = []
    for f in st["steps_files"]:
        order += json.loads(Path(f).read_text()).get("steps", [])
    by_id = {s["id"]: s for s in order}

    # 1. final state
    want_final = expect.get("final")
    halted = st.get("halted")
    got_final = "HALTED" if halted else "DONE"
    if want_final and got_final != want_final:
        dev.append(f"final state: expected {want_final}, got {got_final}"
                   + (f" (halted at {halted['at']}: {halted['why']})" if halted else ""))
    if expect.get("halted_at") and (not halted or halted["at"] != expect["halted_at"]):
        dev.append(f"halt point: expected {expect['halted_at']}, got "
                   f"{halted['at'] if halted else 'no halt'}")

    # 2. nothing ran past the expected halt point. "Past" is judged on the TRACE, not on file
    #    order alone: a step that does not require the halted one legitimately completes BEFORE
    #    the halt occurs (s2-golden-* run while s1-download is still retrying), and file order
    #    alone called that "ran after the halt". The trace is the execution record, in order.
    trace_events = []
    tp = cdir / "trace.jsonl"
    if tp.exists():
        for line in tp.read_text().splitlines():
            if not line.strip():
                continue
            try:
                trace_events.append(json.loads(line))
            except ValueError:
                pass
    if expect.get("halted_at") and halted and halted["at"] == expect["halted_at"]:
        halt_ix = max((i for i, e in enumerate(trace_events)
                       if e.get("event") == "step" and e.get("step") == expect["halted_at"]),
                      default=len(trace_events))
        for i, e in enumerate(trace_events):
            if i > halt_ix and e.get("event") == "step" and e.get("status") == "GREEN":
                dev.append(f"step {e['step']} ran GREEN after the campaign should have halted")

    # 2a. HOW the campaign ended, not only where. The attempt-budget scenario is graded on this:
    #     a bounded retry ends through the step's own on_fail.exhausted route, while a broken
    #     accounting ends through the runner's RUNNER-ERROR invariant at the same step id. Halt
    #     POINT alone cannot tell those apart - and the whole point of the fixture is to tell
    #     them apart.
    if expect.get("halted_verdict"):
        got_hv = (halted or {}).get("verdict", "")
        if not re.fullmatch(expect["halted_verdict"], got_hv or ""):
            dev.append(f"halt verdict: expected /{expect['halted_verdict']}/, got "
                       f"{got_hv or 'no halt'}")
    if expect.get("halted_why_re"):
        got_w = (halted or {}).get("why", "")
        if not re.search(expect["halted_why_re"], got_w or ""):
            dev.append(f"halt reason: expected /{expect['halted_why_re']}/, got {got_w!r}")

    # 2b. the attempt budget is BOUNDED: a step under RETRY is executed retries+1 times, no more.
    #     An unbounded retry never reaches a verdict at all, which is worse than a wrong one.
    for sid, want_n in (expect.get("attempts") or {}).items():
        got_n = sum(1 for e in trace_events
                    if e.get("event") == "step" and e.get("step") == sid)
        if got_n != int(want_n):
            dev.append(f"attempts: step {sid} was executed {got_n} time(s), expected {want_n}")

    # 3. ledger rows: every expected check present with the expected verdict (regex)
    ledger = []
    lp = cdir / "verdicts.tsv"
    if lp.exists():
        for i, line in enumerate(lp.read_text().splitlines()):
            if i == 0 or not line.strip():
                continue
            f = line.split("\t")
            if len(f) >= 3:
                ledger.append({"cell": f[0], "check": f[1], "verdict": f[2]})
    for want in expect.get("ledger", []):
        hits = [r for r in ledger if r["check"] == want["check"]]
        if not hits:
            dev.append(f"ledger: no row for check {want['check']}")
        elif not any(re.fullmatch(want["verdict"], r["verdict"]) for r in hits):
            dev.append(f"ledger: check {want['check']} expected verdict /{want['verdict']}/, "
                       f"got {[r['verdict'] for r in hits]}")
    for want in expect.get("ledger_absent", []):
        if any(r["check"] == want for r in ledger):
            dev.append(f"ledger: check {want} must be ABSENT but has a row")

    # 4. judgement answers vs ground truth
    for sid, truth in (scen.get("truth") or {}).items():
        got = (st["steps"].get(sid) or {}).get("answer")
        if got is None:
            if (st["steps"].get(sid) or {}).get("status") not in (None, "PENDING", "BLOCKED"):
                dev.append(f"judgement {sid}: resolved without an answer")
            elif not expect.get("halted_at"):
                dev.append(f"judgement {sid}: never answered")
        elif got.split(":", 1)[0] != truth:
            dev.append(f"judgement {sid}: answered {got}, ground truth {truth}")

    # 5. harvest dry-grade fail-proofs (V1, earned not hand-written)
    if harvest:
        scen_name = Path(st["scenario"]).name
        fps = json.loads(FAILPROOFS.read_text()) if FAILPROOFS.exists() else {}
        n = 0
        for s in order:
            if s.get("falsified_by") != scen_name or not (s.get("check") or s["kind"] != "action"):
                continue
            rec = st["steps"].get(s["id"]) or {}
            verdict = rec.get("verdict", "")
            if rec.get("status") == "RED" and verdict.startswith(("FAIL", "INVALID")):
                check = s.get("check") or s["id"]
                if fps.get(check, {}).get("grade") == "live":
                    continue          # never downgrade a live proof
                fps[check] = {"grade": "dry", "scenario": scen_name, "campaign": args[0],
                              "observed_verdict": verdict,
                              "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
                n += 1
        FAILPROOFS.write_text(json.dumps(fps, indent=1, sort_keys=True))
        print(f"harvested {n} dry-grade fail-proof(s) into {FAILPROOFS.name}")

    if dev:
        print(f"DEVIATIONS: {len(dev)}")
        for d in dev:
            print(f"  - {d}")
        return 1
    print("NO DEVIATIONS: the walk matches the scenario's ground truth")
    return 0


if __name__ == "__main__":
    sys.exit(main())
