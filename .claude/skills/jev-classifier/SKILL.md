---
name: jev-classifier
description: How to build a classifier that judges many items with Jev - split, template, call, merge, re-ask, report - entirely in code, and the standing prohibition on using a language model as a feeder for Jev. Load this BEFORE classifying, auditing, triaging, diffing or scoring more than a handful of items, and before spawning any agent for an analysis. Reference implementation: tools/prose-audit.py.
---

# Jev classifiers — the judgment is Jev's, the pipeline is code

`.claude/skills/jev/SKILL.md` says what to send Jev. This says how to send a lot of it.

## The prohibition

**A model may not perform any step whose output a script could produce deterministically.**

Jev's wording for this rule, chosen over the alternatives at confidence 1.00
(`prohibition_wording = forbid-when-computable 1.00`).

The steps it forbids a model, by name: enumerate, split, extract, count, join, template, call,
merge, diff, format, tabulate. Writing prose and repairing what a judge flagged are not on that
list; everything else on a classification job is.

Before spawning any agent for an analysis, name what the agent will actually be doing. If the answer
is one of those verbs, write the script. **The burden is to show the cheap path impossible, not to
show the expensive path useful** - a good answer produced the expensive way still reads as a good
answer, which is exactly how this gets waved through.

Two measured failures, same cause:
- 2026-09-22, 1.5M tokens: a multi-agent workflow computed a differential (which factor separates
  the stalled runs from the clean ones). Rewritten as `tools/stall-matrix.py` + one Jev call, it ran
  in seconds and gave a sharper answer, and exposed two traps the agents had been about to sell as
  findings.
- 2026-10-08, 1.8M tokens: a 43-agent prose audit (14 topic buckets x assess/rewrite/verify). 754K
  tokens of Jev state, 1.69M of agents re-reading the same 2.25 MB corpus three times. Stopped at 6
  of 14 buckets with 0 rewrites. Rewritten as `tools/prose-audit.py`: 78 files triaged for 57.5K
  tokens. Only the rewrite needed a model.

## Who does what

| Stage | Owner | Note |
|---|---|---|
| enumerate the corpus, split into units, batch | CODE | a unit must never cut a rule in half |
| template the rubric, build the state | CODE | shared guidance goes in the state ONCE, not per question |
| call `tools/jev.py`, merge answers | CODE | one call per batch; exit 2 aborts, never degrades |
| classify a unit, judge a file | **JEV** | the irreducible cost: the judge must see the text |
| decide which verdicts are weak and re-ask | CODE | deterministic control flow around a judgment |
| diff a result, verify identifiers survived, report | CODE | counting and matching |
| WRITE new prose; repair a flagged loss | MODEL | the only two things a model is for |
| re-read a high-stakes result against its original | MODEL | script verification alone is not sufficient |

## The shape

1. **Split into units that never cut a rule in half.** Validate the splitter OFFLINE before spending
   anything: every non-blank source line must appear in exactly one unit (coverage delta 0), no unit
   may start mid-sentence, and no unit may exceed the batch byte bound. A splitter that drops lines
   silently drops rules.
2. **Give each unit its neighbours as context.** A rule that leans on its surroundings is otherwise
   classified as a fragment.
3. **Batch.** Bound every call by units AND bytes. One rubric carrying hundreds of questions, or one
   state carrying a whole 269 KB register, is not a call that can be trusted.
4. **Bucket by stakes, not by topic.** A binding rule file earns a per-unit pass; thirty files that
   are deletion candidates earn ONE question each from an outline. Pay for per-unit classification
   only on files a cheap pass says are worth it. On this corpus that was the difference between
   534K tokens and about 80K.
5. **Re-ask weak verdicts in code.** Anything under the confidence floor gets one more call with
   wider context. Jev named this the thing most easily lost when a human assessor is replaced
   (`worst_thing_lost = gap-closing-re-ask 0.64`), so it is implemented, not described.
6. **Keep the per-item score.** One aggregate verdict over a corpus is too coarse to act on - record
   the class, the confidence, the full distribution and the line range for every unit.
7. **Report the cost.** `answers.json` carries `usage.input_tokens`. A classifier that cannot say
   what it cost cannot be defended.

## Rules that make the output usable

- **Quote verdicts exactly as printed** - `noul=0.79`, `choice=x conf=0.85 [a=0.88 b=0.08]`. Use
  `jev.py`'s own `fmt()` wording. A verdict reformatted into prose cannot be checked against the wire
  log, and the wire log is the receipt.
- **Exit 2 is not an answer.** The instrument did not run. Abort; never let it read as "nothing
  found". Missing data fails.
- **Always offer `insufficient-evidence`** on a choice, and treat a low confidence as a finding that
  names what to measure next - not as noise to round up.
- **Close the gap with computed facts, then re-ask.** When a verdict is weak because the state was
  thin, the missing facts are usually computable (dates, counts, duplication, whether a tag exists).
  Compute them, re-ask, and say which facts moved it.
- **A verdict is about what was in the state.** Say what the state contained, not what the file
  contains.

## Reference implementation

`tools/prose-audit.py` - `plan --mode units|triage`, `verify`, `report`, `cost`. Its header carries
the design verdicts it was built to. Read it before writing another classifier; extend it rather than
starting a second one.
