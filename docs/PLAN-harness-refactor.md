# PLAN — harness refactor (owner, 2026-10-27)

PROVENANCE. This is the owner's plan, verbatim. It was given in chat and never committed, so for a
day it was followed from a conversation and then re-derived from the session transcript by hand —
which is exactly what this project's rules forbid of a procedure. Recovered verbatim from
`~/.claude/projects/-home-user-qubes-win-idd-driver/b5b7f408-*.jsonl` on 2026-10-27 and committed
here so every claim about "the checklist" can be checked against a file instead of a memory.

Steps 1–13 and the checklist below are one message. **There is no Step 14.** Step 15 was given
separately, later, and is reproduced in its own section with the same fidelity. Nothing in this file
is paraphrased; the only additions are this header and the two section markers.

---

## The plan, verbatim

Execute the following plan exactly. Do not improvise, do not add extra checks, do not create new selftests, and do not raise the floor except as specified. Each step has a binary acceptance criterion. If a criterion is not met, stop and report the exact criterion that failed. Do not invent a workaround.

Mechanization and Jev rules:
- No test, smoke test, or acceptance run may be started from a scratchpad script, a one-off prompt, or a prose description. Every run is a committed script with explicit parameters.
- Any failure is passed to Jev with raw evidence (exit code + last 30 lines + suite or script name) and classified into an existing failure mode listed in findings/wedge.md or findings/issues.md. Do not create a new mode.
- Call Jev only when the answer cannot be obtained by file listing, grep, or exit code. Issue the request directly; do not summarize first.
- If a fine-tuned run is required, add one flag to an existing committed runner. Do not create a new script or prose procedure.

Critical primitives (single implementation, no ad-hoc alternatives):
- fresh_cell_log: returns only the current cell's logs; never mixes previous cells or campaigns.
- query_diagnosis: takes the output of fresh_cell_log plus a signature/window; does not open files itself.
- clock_correct: the single synctime + skew-check entry point; every cell entry path calls it.
- toolstack_accept: records whether a qvm-shutdown / ACPI request was accepted by qubesd.
- package_identity: asserts the binary under test matches the commit just built.
- golden_recreate: parameterised script that reseals a golden from a pristine base.

Idempotency rules (apply to every harness and smoke script):
- Every artefact path includes the attempt/run-id. No shared $cell-*.out across attempts.
- At entry, if the target log directory or marker contains a different run-id, exit non-zero with "contaminated subject" before any work.
- Run-exactly-once scripts write a COMPLETE-<run-id> marker on success and exit 0 immediately if the marker already exists.
- Never blind-append to a cell or campaign log. Truncate at the start of a new run-id or write only to a run-id-scoped file.
- The first line of every artefact is "ATTEMPT <id> <utc>". Consumers refuse a file whose first line does not match the current attempt.

Step 1 — Two lists only
Create tools/tests/product-suites.txt and tools/tests/harness-suites.txt.
Move every line from tools/tests/offline-suites.txt into one of them.
Product list: executes product code or asserts an ADR invariant. Everything else: harness list.
Ambiguous cases: one direct Jev call with the first 20 lines.
Acceptance: run-offline-suites.sh exits non-zero if any suite is in both or neither.

Step 2 — Permanent quarantine
The five tests-for-tests remain in not-in-the-gate.txt with existing reasons and appear in neither list.
Acceptance: grep confirms they are absent from both new lists.

Step 3 — Quarantine redundant source-text checks
Move these to not-in-the-gate.txt with the one-line reasons; do not edit contents; do not place in either suite list:
broker-down-anchor-selftest.sh — redundant with deslice-anchor unit test; source-text only
probe-anchor-selftest.sh — source-text anchor check; overlaps lifecycle/deslice unit test
log-policy-selftest.sh — source-text log-level check; covered by sweep signatures
bridge-exit-reason-selftest.sh — source-text exit-reason check; redundant with wrapper/death-reporter tests
harness-clock-selftest.sh — overlaps sealed clock_correct primitive
loginit-banner-debug-check.sh — source-token check; CI patch apply is the gate; previously flaky
Acceptance: the six names appear only in not-in-the-gate.txt.

Step 4 — No new selftests
No new *selftest* or *check* files. Flaky suites are deleted (file absent + one-line note in issues-closed.md).
Acceptance: git status shows no new selftest/check files.

Step 5 — Floor read-only except product additions
Floor is a literal integer in run-offline-suites.sh. May rise only when product-suites.txt gains a line.
Acceptance: a harness-only commit that changes the floor is rejected by the runner.

Step 6 — Headers reduced
Every suite header ≤ 3 lines: assertion, command, pass exit code. No "why", "measured", "Jev", "verified".
Acceptance: head -n 5 of every listed suite meets the limit.

Step 7 — Temporary jobs die
Any CI job containing "probe" or "temporary" has "# REMOVE-BY: YYYY-MM-DD if <condition>".
Runner fails if the date has passed and the job remains.
Acceptance: workflow parses; runner exits non-zero on an expired probe job.

Step 8 — Eliminate manual / scratchpad runs
Replace every scratchpad or one-off launch with a parameterised call to a committed runner.
Acceptance: grep -r scratchpad/ tools/ .github/ mgmt/ returns no test-launch hits.

Step 9 — Seal the six primitives
fresh_cell_log, query_diagnosis, clock_correct, toolstack_accept, package_identity, golden_recreate each have exactly one definition. All callers use them. No other log walks, clock sets, or golden prose procedures.
Acceptance: grep for guestlogs|logvol- outside the fresh_cell_log definition returns nothing; synctime has one definition; package_identity fails on hash mismatch; golden_recreate.sh is the only recreate path.

Step 10 — Idempotent entry and clean-subject gates
Every script under mgmt/harness/, tools/, and tools/smoke/ that participates in a cell, campaign, or smoke run:
- checks pre-conditions and exits non-zero with a one-line reason if they fail;
- is idempotent (second run on unchanged subject exits 0 with no extra side effects, or exits non-zero "contaminated subject" / "already complete");
- refuses a log directory containing a prior run-id;
- uses run-id-scoped names or truncates; never blind-appends outside fresh_cell_log;
- writes "ATTEMPT <id> <utc>" as the first line of every artefact.
Acceptance: a planted previous-run line causes every cell-start and diagnosis script to exit non-zero before product work; grep shows no >> to cell-log paths outside fresh_cell_log; second invocation of any harness/smoke script is clean or refuses.

Step 11 — Redundancy cuts
Collapse wedge classification, log recovery, rise emission, PRODUCT_PATHS, and a0-toast helpers to the single primitives. Delete duplicate implementations.
Acceptance: the duplicate files or functions named in the redundancy audit no longer exist or are thin callers.

Step 12 — Smoke tests
tools/smoke/ contains only parameterised scripts that call the sealed primitives and exit 0 on their own acceptance criteria.
After the run, promote (move assertion to product-suites.txt) or delete within 14 days.
Acceptance: every smoke script calls fresh_cell_log; none launched from scratchpad; 14-day-old unpromoted script fails the runner.

Step 13 — Final verification
Product list exits 0 on HEAD.
Harness failures are instrument-fail only.
All primitives exist as single functions.
Idempotency gates refuse contaminated subjects.
No scratchpad launches, no new selftests, no expired probe jobs, no dual log walks, no blind appends.

Verifiable checklist (all must be true):
- [ ] product-suites.txt and harness-suites.txt exist; offline-suites.txt empty or deleted
- [ ] five tests-for-tests only in not-in-the-gate.txt
- [ ] six redundant source-text checks only in not-in-the-gate.txt
- [ ] no new *selftest*/*check* files
- [ ] floor changes only with a product-suite addition
- [ ] all suite headers ≤ 3 lines, no forbidden words
- [ ] every probe/temporary job has REMOVE-BY; runner rejects expired
- [ ] no scratchpad test launches
- [ ] six primitives each have exactly one definition
- [ ] no ad-hoc log walks, clock sets, or golden prose procedures
- [ ] every harness/smoke script checks pre-conditions and refuses contaminated or already-complete subject
- [ ] no blind >> to cell-log paths outside fresh_cell_log
- [ ] every artefact starts with ATTEMPT <id> <utc> and uses run-id-scoped names
- [ ] tools/smoke/ scripts are parameterised, call fresh_cell_log, 14-day promote-or-delete
- [ ] product list exit code = 0
- [ ] redundancy duplicates gone or reduced to callers

Stop and report the first failed checklist item. Do not continue and do not invent a substitute.

---

## Step 15, verbatim (given separately, later)

No early "unusable" verdict. Any path that declares a guest "no usable guest", "qrexec silent", or equivalent must first record: the last qrexec packet type received (or "none"), and the toolstack_accept result. If either value is missing, the script exits non-zero with "incomplete evidence" and does not emit the unusable verdict. Acceptance: `grep -n -E 'no usable guest|qrexec silent|QREXEC_SILENT|unusable' mgmt/harness/*.sh tools/*.sh` shows no match that is not preceded in the same function by a call that records the last packet type and a call to toolstack_accept.
