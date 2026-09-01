# protocol — findings (the instrumented acceptance protocol)

## CURRENT STATE

AUTHORITATIVE. Supersedes everything under History below.

- The acceptance protocol is COMPILED: `protocol/run.py` (runner: scheduling, verdicts V1-V7,
  guest custody G-0/G-0b as state transitions, arithmetic close via `tools/campaign-verdict.sh`,
  vmlock-compatible live locking) + step data under `protocol/steps/` + defect-armed dry-run
  fixtures under `protocol/scenarios/`. The prose doc remains reference; the runner is the
  executable form. [verified 2026-09-01]
- FALSIFIABILITY IS A LOAD-TIME GATE (owner rule 2026-09-01: decisive and falsifiable over
  probable): a check without a declared `defect` and a `falsified_by` scenario refuses to load;
  the pre-commit hook runs the same gate on any `protocol/` change. `protocol/failproofs.json`
  is EARNED by `protocol/selftest.sh` observing each check fail on its defect fixture — never
  hand-written. Plain PASS in live mode still requires a live-grade proof. [verified 2026-09-01]
- SONNET OPERATES IT WITHOUT DEVIATIONS: 4 eval rounds x 12 blind operator runs (one per
  scenario, mechanical grading: runner-state-vs-truth + full transcript command audit).
  Round 1: 12/12 correct walks, 1 off-card action (root cause: `verdicts` exited 1 on a valid
  EXECUTED-WITH-GAPS — a verdict dressed as a crash; fixed in the runner). Round 2: 12/12
  correct walks, 1 pre-card orientation `find` (fixed structurally: the assignment embeds the
  card, no pre-card window). Rounds 3 AND 4 (unchanged artifacts): ZERO deviations, 24/24 clean.
  Every fix was to the artifacts, never added prose. [verified 2026-09-01]
- The judgement surface is CLOSED: operators answer fixed tokens over named evidence files
  (e.g. precondition-line authority: ALL_MATCH / MISMATCH / LINE_ABSENT). Arms that cannot run
  unattended are `declare` rows (ATTENDED-PENDING) — and `campaign-verdict.sh` now prints those
  on BOTH branches (before 2026-09-01 an otherwise-clean campaign said COMPLETE and silently
  omitted every owner-required arm). [verified 2026-09-01]
- Mechanizability accounting from the full-doc extraction (476 records): 165 already SCRIPTED,
  247 SCRIPTABLE, 40 CLOSED_JUDGEMENT, 24 NOT_MECHANISABLE (quarantined visibly in
  `protocol/not-mechanisable.json`, never assumed covered). [verified 2026-09-01]
- Parts P0/golden, P2-P5 compiled to step data by fan-out from the extraction records.
  UNVERIFIED until the integrated selftest and an operator eval round cover them.
- Dry-run fail-proofs prove the CHECK LOGIC fails on its defect; they do not prove the live
  instrument fails on a real guest defect. Live-grade proofs (diag build, 0.13b) remain the bar
  for live campaigns. [verified 2026-09-01]

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

## 2026-09-01 — the protocol compiled to code, and Sonnet ran it deviation-free

Owner directive: the prose protocol (measured ~60% adherence by its own author; "cannot be
followed without another Fable-level model at execution") is to be made fully instrumentable —
scripts wherever possible, mechanic judgement where not — then dry-run with Sonnet until it
executes without deviations, clarifying until fixed. Mid-turn addition: every test decisive and
falsifiable against a probable or known defect.

Built: `protocol/run.py` + `grade.py` + `selftest.sh` + `eval/audit-transcript.py`; campaign
spine as data with 11 checks over the real incidents (f777bec provenance, scratch-guest golden,
vacuous ASHA, unset-CELLS zero-cell footer, c1f4312 precondition mismatch...). Selftest: loader
refusal proven on a planted unfalsifiable check; 11 defect scenarios + green all match ground
truth; green reaches COMPLETE only after the defect walks harvest the fail-proofs (V1 end to
end).

Eval: 48 blind Sonnet operator runs over 4 rounds. Two artifact defects found by the eval and
fixed (verdicts exit code; pre-card orientation window). Two consecutive clean rounds on
unchanged artifacts closed the acceptance. Full extraction of the 1877-line doc (5 agents,
476 records) feeds the part compilation.
