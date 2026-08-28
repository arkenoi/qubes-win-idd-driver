---
name: experimenter
description: Rules for running any experiment against a VM or long-running system - baselines, single-variable changes, waits with real failure modes, and instruments proven before use. Load this before writing any test/probe/e2e script or any wait loop.
---

# Experimenter

Every rule here was paid for by a real failure in this project, most of them in one afternoon.
They are prohibitions, not advice. If a rule blocks the thing you were about to type, the thing
you were about to type was the mistake.

## The prohibitions

**1. Never re-run a failed experiment unchanged.**
If it failed, either the instrument or the hypothesis is wrong. Fix one, state which, then run.
"Maybe it won't happen this time" is not a hypothesis. (Cost: a chain re-run three times, each
producing a zero-byte log, before anyone asked why the log was empty.)

**2. Never run an experiment whose instrument cannot produce evidence.**
Before the run, answer: *if this fails, what will I be holding?* If the answer is "a log on a
guest that will no longer boot", the run is worthless - build the telemetry first. Stream or poll
the data OUT while the subject is still alive.

**3. The instrument must be validated before the run, twice over.**
   a. It produces data on a known-good subject.
   b. It can FAIL - demonstrate it on a known-bad subject or a synthetic one. A check never seen
      to fail is not evidence, it is decoration.

**4. Run the baseline control FIRST, and never skip it because it seems obvious.**
Before concluding "X broke it", prove the subject works without X. (Cost: a whole afternoon spent
on "the installer bricked the guest" without ever checking that a bare clone survives a reboot -
which took three minutes and would have framed everything correctly.)

**5. One variable per run, and injected defects must be switchable.**
If the harness seeds a defect, it needs an off switch, and both sides get run. A brick with the
seed ON and no seed-OFF control attributes nothing.

**6. Every wait has THREE exits, and says which one it took.**
   * the thing happened;
   * a TERMINAL state (the subject will never reach the goal - e.g. a guest on a recovery screen);
   * NO PROGRESS for N (stall), or the overall deadline.
   A wait with only a deadline is a hang. A wait that cannot detect "this will never happen" will
   burn its whole budget on a subject that died in the first minute.

**7. Match the wait budget to the EXPECTED timeline, especially on paths expected to fail.**
`for i in $(seq 1 25); do sleep 60` on an outcome expected within two minutes is indefensible.
Ask: how long should this take if it works? if it fails? Budget accordingly.

**8. Do not write polling watchers when the runtime already notifies you.**
Background tasks report completion. A sleep loop tailing their log duplicates that signal, wastes
wall-clock, and adds a second thing to get wrong. Poll only for genuine mid-run visibility, at a
cadence matched to the expected event.

**9. Never restart a subject that is in a known-terminal state.**
Classify first. Restarting a guest that is sitting in Automatic Repair produces another Automatic
Repair, plus false telemetry about "the guest never came back".

**10. Never kill a subject to hurry a wait along.**
A kill is permitted only when the state is already unrecoverable AND is about to be discarded
(e.g. its volumes are overwritten by the next clone). Otherwise a hard kill manufactures the very
corruption you will then misdiagnose.

**11. A transient must not fail the run, and must never be discarded silently.**
Retry with backoff, and log the error text. (A push failed once, one second after boot, with the
error thrown away - and took a whole cell with it. The error, kept, said rc=46: no session yet.)

**12. Check the premise before building on it.**
State what you believe about the subject, then verify it. Two premises here were false and shaped
days of work: "this image installs in two stages" (its testsigning was already ACTIVE) and "this
is a fresh install" (it already had QWT 4.3.2 on it).

**13. Trust counts, not streams.**
A streaming capture died silently at 28 lines while the source had 104. Any instrument that can
truncate must be cross-checked against a count read separately.

**14. Baseline accumulating state.**
Logs, screens and result files persist across runs. Delete or mark them, or a check will fire on
the previous run's failure.

**15. Beware self-matching process patterns.**
`pgrep -f 'win10'` matches the shell running it. Use `w[i]n10` or an explicit script path, or you
will kill your own run and report it as something else.

## Before you launch, write these five lines

    HYPOTHESIS: <what you expect, and what would refute it>
    BASELINE:   <the control that has already been run, and its result>
    VARIABLE:   <the single thing that differs>
    INSTRUMENT: <what data you will hold if it fails, and how it was validated>
    BUDGET:     <expected duration; deadline; terminal states; stall threshold>

If any line is blank, the experiment is not ready. This costs a minute and has repeatedly been
the difference between a result and a wasted hour.

## Wait primitives

Do not hand-roll wait loops. Use the ones with the failure modes already in them:
`.claude/skills/win-guest-e2e/e2e-lib.sh` plus the matrix harness's `e2e-wait.sh`
(`w_session`, `w_install`, `w_halt`, `w_screen`) - they implement rules 6, 7, 9 and 13.

For a guest with no session, `qtest shot` returns an EMPTY tar; use `qtest fullshot` plus
`tools/winshot.py <tar> <vm> --classify` (RECOVERY / BLACK / DESKTOP) - that is what makes
rule 9 enforceable.
