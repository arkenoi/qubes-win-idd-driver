# Workflow planning prompt

Answer every item below in `scratchpad/workflow-plan-<name>.md` BEFORE one line of script exists.
The launch names it: `// WORKFLOW-PLAN: scratchpad/workflow-plan-<name>.md`. The gate
(`tools/hooks/jev-first-gate.sh`) checks the script's `JEV-JUDGE:` and `MODEL-PLAN:` lines exist,
that `agent(` is never unpinned, and that every QUOTED LITERAL tier the script pins and every LITERAL
phase name - whether passed to `phase('X')` or set as `phase: 'X'` in an agent's options - appears in
this plan. Computed values (`model: d.tier`, `phase(d.key)`,
template literals) are not checked. Everything else here is checked by a reader against your own
words, so write what you will do, not what is good to do. Items are ordered so the most expensive
mistake comes first. Each carries its REFUSAL: if the refusal holds, the plan is incomplete and the
launch does not go out.

## 1. Is there a workflow at all

Name the cheapest instrument that would settle the task: a grep, one script, or a few Jev calls.
State what it would return and why that return is not the answer.
REFUSAL: you cannot name the cheaper instrument, or its stated shortfall is "it would miss things"
without naming one thing it misses. Fanning out for what a grep settles is the dearest mistake available.

## 2. The question, in freeform, with the owner's words as premise

Write the task overview in prose: the owner's requirement VERBATIM, then the question you will answer
in your own words, then the answer you expect. The overview is binding on the plan below - every
phase in item 9 must trace to one sentence here, so later items cannot drift from it.
REFUSAL: the owner's constraint appears as an option to weigh rather than as the premise; or the
question is worded so that any outcome confirms the plan.

## 3. What would disconfirm the plan

Name the fact, present in the repo or producible by one Jev call, that would make this plan wrong -
the wrong question, the wrong fork, or a fan-out over a settled matter. Say where it would be found.
REFUSAL: nothing listed, or the disconfirming fact is one the planned stages never read. A plan that
cannot be disconfirmed is fitting, not planning.

## 4. The entry fork to Jev

Write the rubric id by id: `type`, options including an insufficient-evidence option, floor 0.70.
Add a RELEVANCE question: does the question in item 2 ask what the owner asked, or a question
reshaped so the plan passes. The state fed must carry the disconfirming facts from item 3.
REFUSAL: no relevance question; the state carries only supporting facts; or the plan proceeds on a
leading option that is under floor. Under floor is NO verdict. A re-ask is licensed only by new
evidence in the STATE - name it - never by new wording.

## 5. Stage table and placement

One row per stage: name, job verb, tier. Apply the test: deterministic (enumerate, split, extract,
count, join, template, call, merge, diff, format, tabulate, `file:line` says what was claimed) is
CODE; a verdict, score, classification, ranking, "is this real", "does this hold" is JEV; MODEL only
for prose a person reads, code too wide for a grep, or the ONE high-stakes re-read beside Jev.
REFUSAL: a model row whose verb is on the CODE list; a verify stage made of models (agreement, not
verification); a model asked a judgement Jev could score.

## 6. What Jev judges inside the run

State what `JEV-JUDGE:` will say: which artifact each stage returns and which rubric question runs
over that artifact in code. If NONE, say why no step in the run is a judgement.
REFUSAL: Jev judges a stage's prose rather than its artifact; "NONE" without a reason; a judgement
left to the main thread's reading of a report.

## 7. xerj and who writes

List every function, helper, parser, sink or tool a stage may SPECIFY, each with its
`xerj-check for <Name> "<plain words>"` done or scheduled before the stage names it. Agents specify
`file:line` plus the proposed change; the main thread writes, takes receipts once, feeds the diff once.
REFUSAL: a stage with write tools or `isolation: 'worktree'` without a stated parallel-mutation need;
a name a stage will coin that was never searched; an owner-named method weighed against alternatives.

## 8. Token plan per stage

For each stage: `model:` pin, `effort:`, `agentType:` (`Explore` for read-only), the exact inputs
handed over as `file:line` plus decided premises, the `schema:` of its output, and
`pipeline()` unless a barrier is earned - name the cross-item context (dedup over the set, early exit
on zero, item-against-items prompt). Name every cap, sample or no-retry and the `log()` that reports it.
REFUSAL: an unpinned `agent()`; a stage handed a tree or a directory; prose parsed where `schema:`
would validate; `parallel()` with no named barrier reason; a silent cap.

## 9. Wiring

For each stage: which upstream stage produces each input, which downstream stage or the main thread
consumes its output, and the phase name it runs under. Map each phase to its sentence in item 2.
REFUSAL: an output nobody consumes; an input nobody produces; a phase with no sentence in item 2; a
sentence in item 2 with no phase. The script must run as described here or the plan was not the plan.

## 10. Literals the gate will check

List, exactly as the script will spell them:
- `tiers:` every quoted literal `model:` value, e.g. `'haiku'`, `'sonnet'`, `'fable'`
- `phases:` every literal phase string, from `phase('X')` and from `phase: 'X'` in agent options
- `MODEL-PLAN:` the line as it will appear, `<stage>=<tier>` per stage, `write=main-thread` where so
REFUSAL: a tier or phase the script will pin that is absent here, or one listed here the script will
not use. Computed tiers and phases are exempt from the check and still belong in item 8 and 9.

## 11. Stop condition

Name the observable, visible in the first stage's output, that means the shape is wrong and the run
stops before the next agent spawns.
REFUSAL: the observable is one only a finished run shows.

## Closing

"I will see once it runs" is not an answer to any item. Every item is answerable now, from the repo
you can grep and the task you were given. An item you cannot answer now is a missing fact to go and
read, not a reason to launch.
