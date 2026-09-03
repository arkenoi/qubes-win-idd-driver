#!/usr/bin/env python3
"""Compose scenarios/green-whole-campaign/ — the RELEASE-ACCEPTANCE dry walk of the WHOLE
campaign (spine + P2 + P3 + P4 + P5) — from the five per-part green scenarios.

WHY GENERATED, not hand-written: the whole-campaign fixture must stay byte-coherent with the
per-part greens (same results, same evidence, same truths); a hand-copied fork would drift the
first time a part green is touched. Re-run this after changing any source green and commit the
output. The composition itself is mechanical and REFUSES every ambiguity: a duplicated step
result, a conflicting var, or an evidence-basename collision (dry-mode evidence resolution is
by basename, so a collision would silently hand one judgement another part's file).

WHAT THE COMPOSED SCENARIO PROVES (protocol/selftest.sh section 5): a full release-acceptance
campaign — all mechanical steps AND all seven judgement points — runs to a campaign verdict
with ZERO operator input and WITHOUT --auto-answer-truth, because every judgement in the
release path now carries a deterministic scorer. st0-screen (golden.json) is deliberately NOT
here: it is a golden-SEALING judgement (reads a provisioning PNG), belongs to the rarely-run
golden-build part, and is not part of release acceptance.

ACCEPT_OUT is deliberately unified (the per-part greens each used their own dir): a combined
campaign has ONE vars dict, and every part's evidence basenames are disjoint by construction —
verified here by the collision check.
"""
import json
import shutil
import sys
from pathlib import Path

SCEN = Path(__file__).resolve().parent.parent / "scenarios"
PARTS = ["green", "green-p2-network", "green-p3-updates",
         "green-p4-rendering", "green-p5-safeguards"]
OUT = SCEN / "green-whole-campaign"
ACCEPT_OUT = "/home/user/qwt-accept/AP-WHOLE/evidence"


def main():
    steps, vars_, results = [], {}, {}
    truth, ledger, ledger_absent = {}, [], []
    evidence = {}
    for name in PARTS:
        s = json.loads((SCEN / name / "scenario.json").read_text())
        t = json.loads((SCEN / name / "truth.json").read_text())
        for f in s.get("steps", []):
            if f not in steps:
                steps.append(f)
        for k, v in (s.get("vars") or {}).items():
            if k == "ACCEPT_OUT":
                continue                      # unified below
            if k in vars_ and vars_[k] != v:
                sys.exit(f"REFUSE: var {k} conflicts across greens ({vars_[k]!r} vs {v!r})")
            vars_[k] = v
        dup = set(results) & set(s.get("results") or {})
        if dup:
            sys.exit(f"REFUSE: duplicate step results across greens: {sorted(dup)}")
        results.update(s.get("results") or {})
        for sid, ans in (t.get("truth") or {}).items():
            if sid in truth:
                sys.exit(f"REFUSE: duplicate judgement truth {sid}")
            truth[sid] = ans
        ledger += t.get("expect", {}).get("ledger", [])
        for x in t.get("expect", {}).get("ledger_absent", []):
            if x not in ledger_absent:
                ledger_absent.append(x)
        ev = SCEN / name / "evidence"
        if ev.is_dir():
            for f in sorted(ev.iterdir()):
                if f.name in evidence:
                    sys.exit(f"REFUSE: evidence basename collision {f.name} "
                             f"({evidence[f.name]} vs {name}) - dry resolution is by basename")
                evidence[f.name] = name
    vars_["ACCEPT_OUT"] = ACCEPT_OUT
    named_in_rows = {w["check"] for w in ledger}
    clash = named_in_rows & set(ledger_absent)
    if clash:
        sys.exit(f"REFUSE: checks both expected and forbidden: {sorted(clash)}")

    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "evidence").mkdir(parents=True)
    for fname, src in evidence.items():
        shutil.copy2(SCEN / src / "evidence" / fname, OUT / "evidence" / fname)
    scenario = {
        "comment": ("GREEN WHOLE-CAMPAIGN walk (spine + P2 + P3 + P4 + P5), composed by "
                    "protocol/tests/gen-whole-campaign.py from the per-part greens - regenerate "
                    "there, never edit by hand. Proves the release campaign is judge-free end to "
                    "end: every judgement carries a scorer, so the walk reaches its campaign "
                    "verdict with no operator input and no --auto-answer-truth (selftest section "
                    "5 runs it exactly that way). Ground truth: DONE; the campaign verdict is "
                    "EXECUTED WITH GAPS by design (the honest BLOCKED/ATTENDED-PENDING declares "
                    "- the autonomous ceiling), never COMPLETE."),
        "steps": steps,
        "vars": vars_,
        "results": results,
    }
    truth_doc = {
        "truth": truth,
        "expect": {"final": "DONE", "ledger": ledger, "ledger_absent": ledger_absent},
    }
    (OUT / "scenario.json").write_text(json.dumps(scenario, indent=1) + "\n")
    (OUT / "truth.json").write_text(json.dumps(truth_doc, indent=1) + "\n")
    print(f"composed {OUT.name}: {len(steps)} step files, {len(results)} results, "
          f"{len(truth)} judgement truths, {len(evidence)} evidence files")


if __name__ == "__main__":
    main()
