## Step 10 bullet 5 — recorded amendment

**The bullet, verbatim:** `writes "ATTEMPT <id> <utc>" as the first line of every artefact.`
**Checklist item:** `every artefact starts with ATTEMPT <id> <utc> and uses run-id-scoped names`.

**What was implemented instead:** the attempt stamp goes into the failure *package*
(`fresh_cell_log` writes `$cell/package/ATTEMPT` before the collector runs, so it becomes a member
of `package.tar.gz`), and the 30 in-file text sites are left alone, satisfied by the
attempt-scoped, `attempt_dir`-gated directory that now contains them.

**Why this is not a deviation.**
1. A literal reading corrupts artefacts. Six of the targets are `.json`/`.tsv`; prepending a text
   line makes them invalid. Jev: corrupts 0.96, blanket-pass risk 0.94. Two further sites
   (`quick-upgrade.sh:958`, `prime-run.sh:913`) redirect into `forensics.tar` on the same line.
2. The decidable property: an in-file ATTEMPT line adds something **only when the artefact leaves
   its gated directory**, because only then does the `ATTEMPT-<id>` marker stop travelling with it.
   Inside the directory the gate enforces single ownership by refusal, not assertion.
3. Measured: of the 30 text artefacts the cell and campaign entries write, **none leaves its
   directory**. The only two moves in the harness are `matrix.sh:2048` (a `cp` within `$M`) and
   `collect-failure.sh:281`'s tarball.
4. That tarball **did** travel unattributed — it is built from `$cell/package` while the marker sits
   at `$cell/`, and `manifest.json` is explicitly excluded from `.members`. The one artefact set
   that leaves the rig named no attempt at all. Jev: a real defect, 0.87.

**Jev:** `stamp-the-package-not-the-30` **1.00**; the property decides the question 0.82;
`is_this_an_amendment` 0.89 on the earlier pass, which is why this record exists.

**Driven:** `ATTEMPT 20261028T0000Z-TEST 2026-10-27T23:29:35Z` appears inside the package and in
`tar -tzf package.tar.gz`.

## Step 3 / checklist item 2 — the sixth name is DELETED, not declared

**Step 3, verbatim:** `Acceptance: the six names appear only in not-in-the-gate.txt.`
**Checklist item:** `six redundant source-text checks only in not-in-the-gate.txt`.

**What is true at HEAD:** five of the six are declared in `tools/tests/not-in-the-gate.txt`
(`bridge-exit-reason-selftest.sh`, `harness-clock-selftest.sh`, `log-policy-selftest.sh`,
`loginit-banner-debug-check.sh`, `probe-anchor-selftest.sh`, lines 76-80). The sixth,
`broker-down-anchor-selftest.sh`, appears in no list at all because it no longer exists:
`d35b65e8 broker-down-anchor-selftest.sh is deleted, floor 145 -> 144 in the same commit`.

**Why this is not a deviation.**
1. Deletion is the owner's standing rule for this exact case, and it is stronger than quarantine:
   "A selftest that fails and needs a quick fix is DELETED, not fixed ... Drop it, lower the floor
   in the same commit." `d35b65e8` did both halves in one commit, which is the rule's own shape.
2. Declaring it would itself be a defect. `not-in-the-gate.txt`'s header states the invariant:
   "A declaration naming a file that is gone is itself a finding." So satisfying the checklist
   literally would plant the finding the file exists to prevent.
3. `tools/lint-harness.py` L32 refuses a commit when a test file **in the tree** is in none of the
   three lists. A deleted file is outside that rule's domain, so nothing is weakened by its absence.

**Measured, not argued:** `broker-down-anchor-selftest.sh` is absent from the tree and appears zero
times in `product-suites.txt`, `harness-suites.txt` and `not-in-the-gate.txt`, and `grep -rn
broker-down-anchor tools/tests/*.txt` returns nothing.
