---
name: jev
description: Delegate semantic judgments to tools/jev.py. Exact matching stays in code.
---

# Jev

Every semantic judgment → tools/jev.py. Deterministic facts stay in code, then become state.

## Division
| To Jev | In code |
|--------|---------|
| Failure class, final vs transient, screen type, which cause, load-bearing | Counts, exact match, timestamps, hashes |

## Call
```bash
python3 tools/jev.py RUBRIC.json STATE [--out answers.json]
```
Exit 2 = instrument did not run. Never paper over it.

## Rules
1. State = measured facts + disconfirming facts.
2. Always offer insufficient-evidence on choice questions.
3. Low confidence is a finding. Do not re-ask with leading state.
4. Wire log is the receipt. No matching entry = false claim.
5. For procedure questions: state must contain the exact command and the committed alternative. Generic rephrasing fails the committed-procedure gate.

## Designing the workflow around a call

Who runs after Jev, how to size a fork, how to brief Fable with a decided premise, and the floor
and schema traps: the **`jev-workflow`** skill. Read it before spawning any Fable agent or
Workflow - `tools/hooks/jev-first-gate.sh` will refuse the launch without a named `--out` receipt.

## Default rubric shape
root_cause (choice) + chain_established (noul) + missing_measurement (choice).
