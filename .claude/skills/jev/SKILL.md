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

## The state is evidence, never interpretation (owner 2026-11-18)
Jev judges what it is shown. A state that is pre-shaped toward an answer gets that answer back,
and the confidence number then measures the author's framing, not the specimen.
1. **Facts only, each with its source.** Every line names where it came from (`file:line`, a
   command and its output, a log line quoted). A value is copied as it was read (`RFLAGS 0x40297`),
   and a derived bit is shown next to it with the arithmetic (`-> IF=1`), never instead of it.
2. **A reference is QUOTED, never paraphrased.** A recorded signature, a definition, an ADR or
   owner rule goes in verbatim, in quotes, with its source. No summary, no "in practice it shows
   as ...", no detail added from elsewhere to make it line up with what was measured.
3. **No conclusion of the author's in the state.** Not "this matches", "consistent with", "so it is",
   "likely", nor a harness classifier's verdict passed off as a fact - a classifier's line is quoted
   as that classifier's output, attributed.
4. **The rubric's criteria hold no measured claim.** An option describes a class; it must not assert
   a property (e.g. "interrupts off") that the state has not measured or that the record contradicts.
   A rubric copied from an earlier case is re-read against THIS case's evidence before the call.
5. **Name what was NOT measured**, under its own heading, and include every measured fact that cuts
   against the leading answer - not only the ones that support it.
6. **Measure before asking.** If a fact the question turns on is in the bundle, read it and put it in;
   an unread field is a gap in the state, not a neutral omission.
7. **A verdict from a state that broke these rules is withdrawn, not quoted.** Re-ask with the corrected
   state and say both numbers. Correcting a misquote or adding a measured fact is not reshaping;
   rewording to move the number is.
Measured 2026-11-18: one wedge state paraphrased the named-wedge signature to fit the specimen and
used a criterion saying "interrupts off" while IF=1 sat unread in the bundle -> 0.74; the same
evidence with the signature quoted verbatim and IF=1 added -> 0.58.

## Designing the workflow around a call

Who runs after Jev, how to size a fork, how to brief Fable with a decided premise, and the floor
and schema traps: the **`jev-workflow`** skill. Read it before spawning any Fable agent or
Workflow - `tools/hooks/jev-first-gate.sh` will refuse the launch without a named `--out` receipt.

## Default rubric shape
root_cause (choice) + chain_established (noul) + missing_measurement (choice).
