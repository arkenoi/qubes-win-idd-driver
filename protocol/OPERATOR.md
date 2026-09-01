# Operator card — the ONLY instructions an operator needs

This card is the whole job. Do not orient yourself first — no listing directories, no exploring
`protocol/`, no reading other files. There is no context you need that this card and the runner's
own output do not give you.

The protocol is code and data, not prose. `protocol/run.py` decides every step, runs every
command, and owns every verdict. Your job has exactly four verbs. Anything else is a deviation.

## The four verbs

1. **Start** the campaign you were assigned (the assignment gives you the exact command, of this
   shape — you never choose steps, vars, or scenarios yourself):

       python3 protocol/run.py start --campaign <id> --mode dry --scenario <name>

2. **Obey the block the runner prints.** Every stop ends with a line that says
   `The ONLY valid next command is: ...`. Run exactly that command. Nothing else.

3. **Answer** judgement prompts by (a) reading the file(s) the block names — completely,
   (b) choosing EXACTLY ONE listed token, (c) submitting it with the printed `answer` command.
   Choose from what the evidence says, not from what the campaign "should" show. If the evidence
   fits no token, use `OTHER:<one line>` only if OTHER is listed; otherwise pick the listed token
   that says the evidence is unusable.

4. **Report.** When the runner prints `state=DONE` or `state=HALTED`, it prints the one valid
   `verdicts` command. Run it and paste its output as the FIRST block of your report, verbatim;
   for a halted campaign include the halt block right after it. Then stop.

## The five prohibitions (each one voids the run)

- Never run a command the runner did not print. No qtest, no qvm-*, no harness scripts, no
  "quick checks". The runner runs commands; you do not.
- Never re-run a step, restart a halted campaign, or start a second campaign to "retry".
  A halt is a result, not an obstacle.
- Never edit anything under `protocol/` — steps, scenarios, state, this file.
- Never read files the runner did not name. In particular `scenario.json` and `truth.json` are
  fixture internals: opening them is answering from the answer key, and it voids the run exactly
  like `--auto-answer-truth` does. You read: this card, and the evidence files a runner block
  names. Nothing else.
- Never use `--auto-answer-truth`. It answers judgements from the answer key; it exists only for
  `protocol/selftest.sh`.
- Never soften a verdict in your report. `EXECUTED WITH GAPS` is reported as EXECUTED WITH GAPS,
  gaps first. A campaign that found a defect is successful AND incomplete — say both.

If the runner itself errors (`RUNNER-ERROR`, a Python traceback), stop and report the error
verbatim. Do not work around it.
