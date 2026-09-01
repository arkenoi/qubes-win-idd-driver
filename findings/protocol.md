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
- Parts golden + P2-P5 compiled to step data (138 steps, 79 falsifiable checks, 8 judgement
  points, 35 declare rows; 34 defect scenarios arming the real incidents). Integrated selftest
  ALL GREEN (every check seen to fail; 37 fail-proofs harvested), and eval round 5 - 12 blind
  Sonnet operators over the part scenarios - was NO-DEVIATIONS on the first attempt, including
  the screen-PNG judgement (operator overrode the advisory VERDICT=DESKTOP log against the
  Setup-error image) and the second-boot timestamp witness. Cumulative: 60 blind operator runs
  over 5 rounds; rounds 3-5 (36 runs) fully clean. [verified 2026-09-01]
- Dry-run fail-proofs prove the CHECK LOGIC fails on its defect; they do not prove the live
  instrument fails on a real guest defect. Live-grade proofs (diag build, 0.13b) remain the bar
  for live campaigns. [verified 2026-09-01]
- RESTORES ARE SECONDS, NOT REPROVISIONS (owner directive): `mgmt/harness/checkpoint.sh` —
  park/unpark (thin volume clone, 2.8-3.8 s, exact + durable) and undo-session (2 s revert to
  the last completed session's ENTRY state; depth 2, dom0-fixed). Proven by marker round-trip
  with a validated probe and a no-revert control; all refusal branches seen firing (golden,
  running, missing park, park-exists). R3 reprovision only for install-at-first-logon cells.
  The runner's OUT_OF_SERVICE message and the matrix FAIL step prescribe this path.
  [verified 2026-09-01]

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

## 2026-09-01 — checkpoint/revert proven; reprovision demoted to one cell class

Owner: "avoid unnecessary long reprovisioning, save snapshots as checkpoints and revert."
Experiment on ckpt-probe (throwaway, cloned 1.6-1.9 s from win10-tpl): validated marker probe
(seen ABSENT before write = its fail-proof), no-revert persistence control, then single-variable
revert — `qvm-volume revert` root+private in 2 s: post-checkpoint marker GONE, pre-checkpoint
marker KEPT. Traps measured: `-back` revisions hold the session's ENTRY state (a naive
"checkpoint now" verb recorded one-session-ago and was redesigned away); `revisions_to_keep=2`,
`qvm-volume config` policy-refused; a first probe against a win10-base clone waited 360 s for
qrexec that ST0 cannot have (screen showed a healthy pristine desktop — premise error, not a
boot failure). Shipped `mgmt/harness/checkpoint.sh` (park/unpark/undo-session/list), every
branch proven including refusals. rig-capabilities snapshot note retracted; memory
`checkpoints-over-reprovision` written.
