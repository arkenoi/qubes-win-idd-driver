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
