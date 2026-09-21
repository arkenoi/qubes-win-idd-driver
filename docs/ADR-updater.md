# ADR — the Windows updater (Track C)

**Status: accepted, and incomplete — see "Open" at the end.** Written 2026-09-20, after a day in
which the updater was declared "fixed and tested end to end" while dom0 was still reporting an
untrue update state. There was no design record for Track C; its decisions lived in commit
messages, `findings/updates.md`, `findings/issues.md` and inline comments, which is how the same
class of mistake kept arriving in new clothes. This is that record.

Every decision below is written as: **the rule**, then **why**, then **what it cost to learn**.

---

## 1. dom0 owns updates; the guest never installs on its own

Guest auto-update is off (`NoAutoUpdate=1`); dom0 drives every install; the guest reports
availability to dom0 over `qubes.NotifyUpdates`. A netvm-less template reaches Windows Update only
through `qubes.UpdatesProxy`.

**Why:** it is the Qubes model — the admin decides when a template changes, and a template with no
netvm cannot be left to update itself.

## 2. THE INVARIANT: dom0's reported state must be TRUE

This is the one that matters, and the one that has been broken in both directions.

- Broken saying **too little**: after any reboot-pending pass dom0 was told `0`, and the boot scan
  meant to correct it was debounced away. A template four months behind showed as up to date.
  (`GUARD:rowkey`, `GUARD:bootconfirm`.)
- Broken saying **too much**: after the September cumulative was fully applied, three items were
  re-offered and all counted actionable on every pass, so `updates-available` could never clear and
  Qube Manager could never show the template as up to date.

**Both are the same defect class** — dom0 misreporting this template's update state — and a fix for
one does not close the other. *Recording the second as a separate lower-priority issue in order to
call the first "done" is not allowed.* That is precisely what happened on 2026-09-20; Jev graded
`goal_met` at **0.04**.

**Corollary:** "offered" and "actionable" are different numbers. dom0 gets the actionable one. An
item the guest can never install on this path must not hold dom0 permanently at "updates
available" — the `severity=info` concept exists for exactly this and must be applied to every such
item, not only the post-end-of-support ones it was first written for.

## 3. Verify BY EFFECT, never by exit code

An installer that returns 0 has read as success on a no-op more than once.

**The rule, sharpened 2026-09-20 (`GUARD:effectprobe`):**
- If we know how to measure an executable's effect, **rc=0 without that effect is NOT success.**
- A probe that ran and saw nothing is a **negative result**, not a missing one.
- Where no probe exists, the row says so (`probe=none`) rather than implying verification.

**What it cost:** `securityhealthsetup.exe` (the Windows Security platform offer) returned rc=0 on
every pass while nothing moved. There was no probe for it, so `$eff` was structurally false and
`rc -eq 0` alone set `ok=$true`. dom0 was told "offered, still pending" forever instead of "this
update is failing" — the field report's untruth, in a new place.

**And a trap inside the trap:** the first probe written for it measured
`SecurityHealthService.exe` in System32. The file describes itself as *"Windows Security app
**undocked** setup"* — it updates the `SecHealthUI` **appx package**. A probe aimed at the wrong
artefact reports a false FAILURE for a correct install, which is the same sin inverted. Probe what
the installer actually changes, and prove the probe on a known-good install before trusting a
negative from it.

## 4. Sanctioned paths hard-fail; no timeouts standing in for answers

The relay serves a sanctioned host or refuses with a **final** 403 — never a transient answer, a
reset, or a hang. A transient answer sends Windows Update into its NLA/"network is not connected"
wait, which parks a synchronous search. (Owner rule; `tools/wu-log-judge.py` exists to detect the
wait having happened at all.)

## 5. Routeless by construction

A netvm-less guest has no default route, so Delivery Optimization and BITS cannot work. Content is
fetched through the proxy by the updater itself (catalog `.msu`, or a self-contained static URL);
the native Windows Update installer is deliberately **skipped as informational** where it would
need DO/BITS. Consequence to hold in mind: some offers are structurally uninstallable on this path
and must be classified accordingly (see §2).

## 6. Structured data only — no title parsing, no locale dependence

Rows are matched by key (`Test-RowKey`), KBs by filename family, never by a localised title. The
reporter environment is German; a title match on "Cumulative Update" is unreachable there and was a
latent defect on a German Windows 10.

**What it cost:** result rows are `[ordered]@{...}`, i.e. `OrderedDictionary`, whose
`PSObject.Properties.Name` yields `Count, IsReadOnly, Keys, …` and **never the keys**. The
outstanding-KB filter therefore matched nothing and `remaining` was 0 on every reboot-pending pass.

## 7. A field report is reproduced on the reporter's measured environment

`mgmt/reporters/<name>.json` holds the asserted facts; `mgmt/harness/env-assert.sh` measures a
guest against them and any mismatch or unmeasured fact is a non-zero exit. "Diagnostically similar"
is not an environment.

## 8. Reboots are COUNTED: performed must equal requested

**No speculative reboots. Ever.** Owner, 2026-09-20: *"there should be no forced reboots in 'hope
to settle'. amount of reboots performed must match amount of reboots requested."*

Every power cycle a harness performs must trace to a request — either the guest powered **itself**
off (an `/auto` stage transition is the guest asking), or `update-status.json` said
`reboot_needed=true`. `mgmt/harness/wu-e2e.sh` counts both sides and **fails the run on a
mismatch**, in either direction: an extra cycle nobody asked for, or a requested one skipped.

**Why:** a harness that reboots until things settle is unfalsifiable — reboot often enough and
something eventually works — and every state that needed an unrequested reboot is a real defect it
just concealed. It also stops reproducing what the user gets, since a user reboots when Windows
asks, not three times hoping.

**And `unknown` is not `false`.** If `update-status.json` cannot be read, `reboot_needed` is
UNKNOWN, and missing data fails. Treating it as "no reboot needed" silently converts a requested
cycle into none — which is the same accounting lie from the other end.

**A reboot is a COMPLETED CYCLE, not an issued command.** The first implementation of this very
rule counted `performed` the moment `qvm-shutdown` returned — so a shutdown that *failed* still
incremented the counter, and a guest left powered off counted a whole cycle for half a one. It was
caught by its own ledger reading "1 performed" while the guest was Running. Count it only once the
guest has gone down **and** come back with qrexec answering; anything else is a failure.

**What it cost:** an ad-hoc install driver written the same day looped
`for r in 1 2 3; do ... qvm-shutdown; qvm-start; done`, rebooting three times to "complete the
handover" with nothing having asked for any of them.

## 9. The test is the product

Passes are judged, not read: `tools/wu-pass-judge.py` (workflow level — did each pass tell dom0 the
truth) and `tools/wu-log-judge.py` (engine level — did the search ever enter the transient wait).
`mgmt/harness/wu-e2e.sh` drives repeated passes through dom0's *own* `qubes-vm-update` sequence and
judges every one.

**THE ARTEFACT UNDER TEST IS NOT WHAT THE INSTALLER SAYS IT IS.** Three times on 2026-09-20 a run
was about to be graded against code that was not on the guest, and every time `install.cmd`
reported success:

1. the sealed golden's updater simply **predated the fix** — a pass on it would have graded the old
   code and been reported as a green end-to-end;
2. an install was **truncated** when the installer restarted the gui-agent and killed its own qrexec
   parent — the MSI half succeeded, the script half never ran;
3. `qvm-copy-to-vm` **silently refuses to overwrite an existing name** in QubesIncoming, so the
   installer ran the PREVIOUS tree and still printed `INSTALL COMPLETE`.

The only thing that caught all three was comparing the **installed file** against the package —
byte count and guard markers — before running anything. So: never grade a run without that
comparison; delete the target before a push (`tools/qtest push` does, a bare `qvm-copy-to-vm` does
not); run `install.cmd` detached via a SYSTEM scheduled task so it survives the agent restart; and
never send a copy's output to `/dev/null`.

**A WAIT WHOSE EXIT CONDITION THE OLD ARTEFACT ALREADY SATISFIES IS NOT A WAIT.** Fourth instance, 2026-09-20, on `win11de-fresh`: the install loop polled for a GUARD MARKER and broke the moment it saw one — but the previous build contains that marker too, so it broke at the first poll, 30 s after launching an installer that needs minutes, logged `GUARD INSTALLED`, and the byte assertion immediately below then failed the run for an install that had simply not happened yet. The installer was still running its `/auto` stages, unwatched, while the harness reported a refusal. Wait for the thing that DISTINGUISHES the new artefact from the old one — here, the byte count — never for a property both share.

**And an exit code read after a command substitution is the SUBSTITUTION's.** The same run printed `win11de-fresh exit=0` for a leg that had just refused to grade, because `$?` was read after `$(date ...)` had run. A harness that reports success for its own failure is the instrument trap in its purest form.

**And the checker can lie too.** Two of my own probes manufactured a false green in the same hour:
one matched the literal marker text inside the command `qtest` **echoes back**, declaring success
30 s after launch; the other used `|` as a field separator, which cmd read as a **pipe**, so the
probe errored and returned empty — and an empty result was being treated as "not yet" rather than
"the check did not run". Probe output must exclude the echoed command, avoid shell metacharacters,
and distinguish *empty* from *negative*.

**Instrument traps already paid for — do not re-learn them:**
- dom0's `updates-available` is a **flag**, not a count. Compare presence, not numbers.
- `replay-dom0-update.py` reports each step's rc but **exits 0 regardless**. Grep its own
  `<-- UNEXPECTED` markers.
- the guest's `wu\agent.log` is **cumulative** — judge only a round's delta.
- `update-status.json` carries a **UTF-8 BOM** (`utf-8-sig`), and lives in `C:\ProgramData\Qubes\`,
  not the `wu\` subdirectory.
- the updates proxy in the dev qube **dies and nothing restarts it**; prove egress before a run or
  a network failure will read as a guest defect.

---

## Open

- **§2 is not satisfied today.** Three items are re-offered on every pass after a full update and
  all count actionable, so dom0 never clears. One of them is a genuine silent install failure
  (§3), one is perpetual by nature (Defender signatures), one is skipped for having no KB and the
  reason never reaches dom0.
- `GUARD:effectprobe` **has now fired on a guest** (win11de-ctlb, 2026-09-20, KB5007651): the probe
  ran, saw nothing move, and wrote `verified_by_effect=false`. But the guard then drew the WRONG
  CONCLUSION from its own negative. It classifies rc=0 + no effect as `severity=info`, reason
  "nothing to do on this image" — and the offered installer, fetched through the proxy and unpacked
  in the dev qube, is an APPX payload declaring `Microsoft.SecHealthUI` version **1000.29628.1000.0**
  while the guest's probe logged the installed package at **1000.26100.8036.0**: same scheme, lower
  build. The installer carries something NEWER than the image has and changes nothing. Jev:
  concealed-failure 0.65, correct-exclusion 0.01, `reason_fits` 0.20. This inverts §3 — a negative
  probe read as "nothing to do" instead of "this update is failing". The measurement that decides
  WHICH fix is right, whether `Get-AppxProvisionedPackage` moved while `Get-AppxPackage -AllUsers`
  (what the probe reads) did not, is still outstanding.
- **The aggregate bar cannot answer the exclusion question by itself.** Jev graded the two-control
  design's ability to discriminate correct exclusion from genuine failure at **0.24**, naming the
  reason at 0.93: it grades dom0's flag and never checks WHICH reason was applied to WHICH item.
  `tools/wu-exclusion-audit.py` is the missing half — per-item judgment, with the updater's own
  reason string refused as evidence for itself. **WIRED 2026-09-21.** The harness still never calls
  Jev (it must finish without an external API), but it no longer exits 0 on an unjudged run. The
  contract is now: **0** = every round passed and either nothing was excluded or a supplied verdict
  positively judged every excluded item; **3** = a round failed; **4** = every round passed but
  exclusions are UNJUDGED — an open question, not a pass. To grade them, run
  `tools/wu-exclusion-audit.py <run-dir> --out answers.json` (optionally `--evidence` with facts
  measured on the guest outside the updater) and re-run with `WU_EXCLUSION_VERDICT=answers.json`;
  the harness replays that file through the audit's own gate in pure local code and requires it to
  cover **every** item in `excluded-items.tsv` — a verdict that omits an item says nothing about it.
  The gate fails a run on a concealed failure, on `insufficient-evidence` (missing data fails), and
  on a benign class resting on a reason Jev judged not to fit the item. It is driven with each of
  those defects present by `tools/tests/wu-exclusion-gate-selftest.py`.
- The release **disc** path is untested since `qvm-start --cdrom` broke on this rig
  (`findings/rig.md`); the reporter installs from the published ISO. **That is one command being
  broken, not the disc path being impossible:** `udisksctl loop-setup -r -f <iso>` (root-free) plus
  `qvm-device block attach --ro --option devtype=cdrom <running-vm> win-idd-mgmt:loopN`, or
  `assign --required` before start, both work from here — see the block-device capability table in
  `CLAUDE.md`. Test it that way before recording the path as unavailable.
