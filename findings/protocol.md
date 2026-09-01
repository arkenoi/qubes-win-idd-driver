# protocol — findings (the instrumented acceptance protocol)

## CURRENT STATE

AUTHORITATIVE — and the ONLY content of this file. The dated history log was amputated
2026-09-01 (owner call): the chronological format itself caused stale-first reads and
contaminated sessions. Maintain by editing bullets IN PLACE (add, correct, delete);
never append dated sections (the pre-commit hook refuses them). Every bullet carries
`[verified <date>]` or `UNVERIFIED`. Git history retains the old log for deliberate
forensics only — do not load it into context.

- The acceptance protocol is COMPILED: `protocol/run.py` (runner: scheduling, verdicts V1-V7, guest custody G-0/G-0b as state transitions, arithmetic close via `tools/campaign-verdict.sh`, vmlock-compatible live locking) + step data under `protocol/steps/` + defect-armed dry-run fixtures under `protocol/scenarios/`. The prose doc remains reference; the runner is the executable form. [verified 2026-09-01]
- FALSIFIABILITY IS A LOAD-TIME GATE (owner rule 2026-09-01: decisive and falsifiable over probable): a check without a declared `defect` and a `falsified_by` scenario refuses to load; the pre-commit hook runs the same gate on any `protocol/` change. `protocol/failproofs.json` is EARNED by `protocol/selftest.sh` observing each check fail on its defect fixture — never hand-written. Plain PASS in live mode still requires a live-grade proof. [verified 2026-09-01]
- SONNET OPERATES IT WITHOUT DEVIATIONS: 4 eval rounds x 12 blind operator runs (one per scenario, mechanical grading: runner-state-vs-truth + full transcript command audit). Round 1: 12/12 correct walks, 1 off-card action (root cause: `verdicts` exited 1 on a valid EXECUTED-WITH-GAPS — a verdict dressed as a crash; fixed in the runner). Round 2: 12/12 correct walks, 1 pre-card orientation `find` (fixed structurally: the assignment embeds the card, no pre-card window). Rounds 3 AND 4 (unchanged artifacts): ZERO deviations, 24/24 clean. Every fix was to the artifacts, never added prose. [verified 2026-09-01]
- The judgement surface is CLOSED: operators answer fixed tokens over named evidence files (e.g. precondition-line authority: ALL_MATCH / MISMATCH / LINE_ABSENT). Arms that cannot run unattended are `declare` rows (ATTENDED-PENDING) — and `campaign-verdict.sh` now prints those on BOTH branches (before 2026-09-01 an otherwise-clean campaign said COMPLETE and silently omitted every owner-required arm). [verified 2026-09-01]
- Mechanizability accounting from the full-doc extraction (476 records): 165 already SCRIPTED, 247 SCRIPTABLE, 40 CLOSED_JUDGEMENT, 24 NOT_MECHANISABLE (quarantined visibly in `protocol/not-mechanisable.json`, never assumed covered). [verified 2026-09-01]
- Parts golden + P2-P5 compiled to step data (138 steps, 79 falsifiable checks, 8 judgement points, 35 declare rows; 34 defect scenarios arming the real incidents). Integrated selftest ALL GREEN (every check seen to fail; 37 fail-proofs harvested), and eval round 5 - 12 blind Sonnet operators over the part scenarios - was NO-DEVIATIONS on the first attempt, including the screen-PNG judgement (operator overrode the advisory VERDICT=DESKTOP log against the Setup-error image) and the second-boot timestamp witness. Cumulative: 60 blind operator runs over 5 rounds; rounds 3-5 (36 runs) fully clean. [verified 2026-09-01]
- Dry-run fail-proofs prove the CHECK LOGIC fails on its defect; they do not prove the live instrument fails on a real guest defect. Live-grade proofs (diag build, 0.13b) remain the bar for live campaigns. [verified 2026-09-01]
- RESTORES ARE SECONDS, NOT REPROVISIONS (owner directive): `mgmt/harness/checkpoint.sh` — park/unpark (thin volume clone, 2.8-3.8 s, exact + durable) and undo-session (2 s revert to the last completed session's ENTRY state; depth 2, dom0-fixed). Proven by marker round-trip with a validated probe and a no-revert control; all refusal branches seen firing (golden, running, missing park, park-exists). R3 reprovision only for install-at-first-logon cells. The runner's OUT_OF_SERVICE message and the matrix FAIL step prescribe this path. [verified 2026-09-01]

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.
