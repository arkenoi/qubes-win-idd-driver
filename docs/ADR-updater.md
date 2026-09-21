# ADR — the Windows updater (Track C)

**Status: accepted.**

This file records DECISIONS: how the Windows update path is built, and how it is tested.
It is not a status report. It does not say what works today, what is broken, or what any
guest measured. Those belong in:

| record | content |
|---|---|
| `findings/updates.md` | standing facts about the update path, and retracted approaches |
| `findings/issues.md` | the open issue register (P1/P2/P3), maintained in place |
| `findings/rig.md` | rig and harness behaviour, including instrument traps |
| `findings/install.md` | getting a build onto a guest |

Rule for editing this file: add a section only when the WAY WE WORK changes. If a sentence
would go stale once a guest is fixed, it is an observation and belongs in `findings/`.

Each section states **the decision**, then **why**.

---

## 1. dom0 owns updates; the guest never installs on its own

Guest auto-update is off (`NoAutoUpdate=1`). dom0 drives every install. The guest reports
availability to dom0 over `qubes.NotifyUpdates`. A guest with no netvm reaches Windows Update
only through `qubes.UpdatesProxy`, and only while a pass is running.

**Why:** this is the Qubes model. The admin decides when a template changes, and a template with
no netvm cannot be left to update itself.

## 2. The invariant: dom0's reported state must be true

dom0 must never be told that a template is up to date when it is not, and must never be held at
"updates available" by an item this path can never install.

Rules that follow:

- "Offered" and "actionable" are different numbers. dom0 is told the actionable one.
- An item that cannot be installed on this path is reported as `severity=info` with a reason and
  left out of the count — but only when that classification is correct for that item.
- The invariant can break in two directions: too little (silence about a pending update) and too
  much (a count that can never clear). They are one defect class. Fixing one direction does not
  close the other, and the open direction may not be re-filed at a lower priority in order to call
  the work done.

**Why:** dom0's reported state is the product. Every other rule here exists to keep it true.

## 3. Verify by effect, never by exit code

- If an installer's effect can be measured, `rc=0` without that effect is not success.
- A probe that ran and measured no change is a NEGATIVE RESULT, not missing data. It means the
  install failed. It does not mean there was nothing to do.
- A probe must measure the artefact the installer actually changes, and must be proven on a
  known-good install before a negative from it is believed.
- Where no probe exists the row says `probe=none`. It never implies verification.

**Why:** an installer that returns 0 and changes nothing is the exact shape of a silent failure.
It reaches dom0 either as "pending forever" or as "nothing to do", and both break §2.

## 4. Sanctioned paths hard-fail; never a timeout instead of an answer

The relay serves a sanctioned host, or refuses with a final 403. Never a reset, a 5xx, or a hang.

**Why:** a transient answer sends Windows Update into its "network is not connected" wait, which
parks a synchronous search until something kills the pass. A refusal is an answer; a timeout is not.

## 5. Routeless by construction

A guest with no netvm has no default route, so Delivery Optimization and BITS cannot work. The
updater fetches content itself through the proxy: a catalog `.msu`, or a self-contained static URL.
A path that needs DO/BITS is classified, not retried.

**Why:** the guest is offline by design, and that is not going to change. Consequence to hold in
mind: some offers are structurally uninstallable here and must be classified under §2.

## 6. Structured data only; no title parsing

Match rows by key, KB content by filename family, and an offer by its identity
(`UpdateID` + `RevisionNumber`). Never on displayed title text.

**Why:** the catalog's response language is not deterministic — one KB comes back German, English
or French — and the reporter's environment is German. Any logic keyed on a title is a defect
waiting for a locale to expose it. A version number inside a title is an exception only because
digits are language-free.

## 7. A field report is reproduced on the reporter's measured environment

The reporter's environment is data: `mgmt/reporters/<name>.json`. `mgmt/harness/env-assert.sh`
measures a guest against it and exits non-zero on any mismatch, and on any fact it could not
measure. "Diagnostically similar" is not an environment. If the environment does not exist on the
rig, building it is the first task.

## 8. Reboots are counted: performed must equal requested

- No speculative reboots. Every power cycle must trace to a request: the guest powered itself off,
  or `update-status.json` said `reboot_needed=true`.
- A reboot counts as PERFORMED only when the guest has gone down and come back with qrexec
  answering. An issued command is not a cycle.
- If `reboot_needed` cannot be read it is UNKNOWN, and missing data fails. It is never read as
  false.
- The harness fails the run on a mismatch in either direction: an extra cycle nobody asked for, or
  a requested cycle skipped.

**Why:** rebooting until things settle is unfalsifiable — reboot often enough and something
eventually works — and it conceals the defect that needed the extra cycle. It also stops
reproducing what a user gets, because a user reboots when Windows asks.

## 9. The test is the product

- Passes are judged by code, not read by eye: `tools/wu-pass-judge.py` at workflow level (did the
  pass tell dom0 the truth) and `tools/wu-log-judge.py` at engine level (did the search enter the
  transient wait). `mgmt/harness/wu-e2e.sh` drives repeated passes through dom0's own
  `qubes-vm-update` sequence and judges every one.
- Before grading, prove the artefact under test is the one on the guest: compare the installed file
  against the package by byte count and guard markers. An installer's own success message is not
  evidence.
- A wait must key on a property that DISTINGUISHES the new artefact from the old one. A marker both
  builds carry is not a wait.
- An excluded item is an open question until it is judged individually, against evidence measured
  outside the updater. The updater's own reason string is not evidence for itself. `wu-e2e.sh`
  exit codes: **0** every round passed and every excluded item is positively judged (or nothing was
  excluded); **3** a round failed; **4** rounds passed but exclusions are unjudged. A verdict file
  must cover every excluded item; one that omits an item says nothing about that item.
- Missing data fails. A check that cannot fail is not a check: every gate here must have been seen
  to FAIL on a build with the defect put back.

**Why:** every wrong verdict in this track came from an instrument, not from the code under test.
Known instrument traps are recorded in `findings/rig.md` and `findings/updates.md`, and are kept
out of this file on purpose — they are observations, and they change.
