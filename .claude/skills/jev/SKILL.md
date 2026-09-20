---
name: jev
description: Delegate SEMANTIC judgments to Jev (TypeSafe System One) via tools/jev.py instead of deciding them by hand - which known failure class a console excerpt shows, whether a client treated an error as final or transient, what a screen actually is, which of several candidate causes the evidence supports, whether a draft rule is load-bearing. Owner's standing instruction: "delegate to jev everything when feasible" and "use jev for judgement on candidates - it is better than you in that". Load this BEFORE grading candidate explanations, classifying a guest state or log excerpt, or writing your own verdict into findings; exact matching, counting and timestamp joins stay in code.
---

# Jev — the judgment instrument

**Why this exists.** `tools/jev.py` has been in this repo since 2026-09-18 with, as of 2026-09-20,
**zero callers anywhere outside itself**. The helper was built and then not used: sessions kept
making semantic calls by hand and writing the verdict straight into `findings/`. Jev itself graded
that gap as the single most essential missing piece of this project's environment knowledge
(`missing_entry = jev-helper`, confidence 0.88).

## The division of labour — this is the whole rule

| Send to Jev | Keep in code |
|---|---|
| Which known failure class does this console excerpt show? | Counting dirs, processes, bytes |
| Did this client treat the error as FINAL or TRANSIENT? | Exact string and regex matching |
| Is this screen a desktop, a recovery prompt or an installer? | Timestamp joins and ordering |
| Which of these candidate causes does the evidence support? | Hash comparison, diffing |
| Is this draft rule load-bearing, or filler? | Anything with a deterministic answer |

If a question has a deterministic answer, computing it and *then* handing the computed facts to
Jev as `state` is the correct shape. Jev judges; it does not measure.

## How to call it

```bash
python3 tools/jev.py RUBRIC.json STATE_FILE [--json-state] [--out answers.json]
```

`RUBRIC.json` is a `{"questions": {...}}` map. Three question types:

- **noul** — a yes/no with a probability. `{"type":"noul","instructions":{"judge":"..."},
  "criteria":{"true":"...","false":"..."}}`
- **choice** — one option plus a full distribution and a confidence.
  `{"type":"choice","instructions":{"judge":"..."},"criteria":{"opt-a":"...","opt-b":"..."}}`
- **score** — a level on a scale, with a legend.

Exit 0 means it answered; **exit 2 means the instrument did not run** (no key, HTTP error,
malformed rubric) — that is deliberate, so a caller can never mistake "the judge did not run" for
an answer. Never paper over a 2.

## Rules that make the answer worth having

1. **Write the state as measured facts, and say so.** State what was counted, how, and when.
   Include the facts that *do not* support your favourite reading — a judgment built on a
   one-sided brief is worthless.
2. **Always offer an `insufficient-evidence` option** on a choice. If Jev cannot pick it, it
   cannot tell you that your evidence is thin.
3. **A low-confidence answer is a FINDING, not noise.** It names what still has to be measured.
   Do not round it up in the report, and do not re-ask with a leading state until it agrees.
4. **Close the gap, then re-ask.** A `chain_established` of 0.56 on 2026-09-20 was answered by
   building a controlled reproduction; re-asking with that evidence moved it to 0.76 and named
   the one remaining unobtainable fact. A `load_bearing` of 0.32 on a settings draft was answered
   by cutting the filler; re-asking moved it to 0.66. That loop *is* the method.
5. **The wire log is the receipt.** Every request and response is appended verbatim to
   `$JEV_WIRE_LOG` (default `scratchpad/jev-wire.jsonl`, gitignored). **A claim about a Jev result
   that has no matching wire entry is false.** Quote the numbers as printed.
6. Rubrics and states are working material: they go in `scratchpad/`, never a tracked path.

## Worked shape

```bash
cat > scratchpad/jev-<topic>-state.txt <<'EOF'
<measured facts, with dates and counts; then the facts that cut against the obvious reading>
EOF
cat > scratchpad/jev-<topic>-rubric.json <<'EOF'
{"questions":{
  "root_cause":{"type":"choice",
    "instructions":{"judge":"Which candidate is the ROOT CAUSE? Judge only from `state`; do not
      prefer a candidate merely because it is described in most detail."},
    "criteria":{"cand-a":"...","cand-b":"...","insufficient-evidence":"..."}},
  "chain_established":{"type":"noul",
    "instructions":{"judge":"Is the causal chain ESTABLISHED by the evidence, as opposed to
      merely plausible or correlated in time?"},
    "criteria":{"true":"mechanism shown, not just timing","false":"rests on coincidence"}},
  "missing_measurement":{"type":"choice",
    "instructions":{"judge":"Which single unmeasured fact would most change the verdict?"},
    "criteria":{"...":"...","nothing-material":"..."}}}}
EOF
python3 tools/jev.py scratchpad/jev-<topic>-rubric.json scratchpad/jev-<topic>-state.txt \
  --out scratchpad/jev-<topic>-answers.json
```

That triple — **what is it / is the chain established / what is still missing** — is the default
rubric for any causal question here. Record the verdict in `findings/` as
`root_cause=<x> conf <n>, chain_established <n>`, with the residual named.

## Key

`~/.config/qwt-secrets/typesafe.key`, or `TYPESAFE_API_KEY`. Never printed, never logged, never
committed.
