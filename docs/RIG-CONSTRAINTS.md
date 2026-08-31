# Rig constraints and verdict semantics

Extraction, not design. Everything here was **measured** on this rig, most of it the hard way, and
each item names the incident that produced it. It exists so a test framework — written by anyone,
from scratch — does not rediscover these one bug at a time.

**Written to one standard: can something dumber than the author follow it?** Each item is a FACT,
a mechanically checkable CONSTRAINT, and a VERIFY command. Nothing here asks the reader to notice,
weigh, or interpret. The four items that genuinely cannot be mechanised are quarantined at the
bottom under NOT MECHANISABLE, so their unreliability is visible rather than assumed.

---

## 1. Guest access

**1.1 `qtest pushrun` silently returns NOTHING without a logged-on session.**
Filecopy targets the user's Documents; with no session the file never lands and the script never
runs. The caller reads empty output as "the probe found nothing".
*Incident: a subject was declared broken on this basis. Also 2026-08-31: `pvnic-latch-readback`
returned nothing on `win10-tpl` — `PROBE=False`, the file was never delivered.*
→ **CONSTRAINT:** any `pushrun` result that is empty is `INVALID-INSTRUMENT`, never a verdict.
→ **VERIFY:** before grading, assert the script exists guest-side:
`Test-Path 'C:\Users\user\Documents\QubesIncoming\<src>\<script>'`.

**1.2 PowerShell with quotes must go through `-EncodedCommand`.**
`cmd /c powershell -Command "... \"...\" ..."` is re-split at every hop (bash → qtest → cmd.exe →
powershell) and **fails silently** — cmd echoes the command, no output, no error.
*Incident: rnd8's keyed-mutex counter returned nothing; the empty values were compared numerically
and written out as a product FAIL.*
→ **CONSTRAINT:** no `-Command` with an escaped quote, anywhere.
→ **VERIFY:** `grep -rE 'powershell[^\n]*-Command\s+"[^\n]*\\"' mgmt/ tools/` → must be empty.
(Lint L3.)

**1.3 Guest scripts run as `NT AUTHORITY\SYSTEM` via qrexec on testbed-tagged qubes.**
Imposed by dom0 policy; the caller cannot request it. Session-0 blindness is **not** a thing here —
tested A/B, output was byte-identical.
→ **VERIFY:** `qtest run 'whoami'` → `nt authority\system`.

---

## 2. Guest state and persistence

**2.1 An AppVM's `C:` is VOLATILE.** Anything written to `C:\ProgramData` is gone after a reboot.
*Incident 2026-08-31: a release binary backed up to `C:\ProgramData\gui-agent.release.bak` on
`win10-app` was absent next boot; the restore then copied the diag build over itself and the
running hash never changed.*
→ **CONSTRAINT:** never park a restore artefact on an AppVM's `C:`. Use the private volume (`Q:`)
or keep it dom0-side.
→ **COROLLARY (useful):** a plain reboot is the cleanest restore for an AppVM — the volatile root
discards a swapped binary by itself.

**2.2 The user profile lives on the PRIVATE volume, behind a junction.**
`MoveUsers` is on by default; `relocate-dir.exe` leaves `C:\Users` as a reparse point onto `Q:`,
and `ProfilesDirectory` deliberately stays `C:\Users`. So profile state — including each profile's
`NTUSER.DAT`, its ACLs and owner SIDs — survives every template change.
→ **CONSTRAINT:** when a symptom differs between two qubes of the same template, the only
guest-side state that can differ is the private volume. Compare volumes, not directories: a
file-level copy skips `NTUSER.DAT` (locked) and reproduces neither ACLs nor reparse points.

**2.3 A binary swap can SILENTLY FAIL — `QubesGuiWatchdog` re-locks the file.**
*Incident: an entire comparison ran against the release build while reporting the diag hash.*
→ **CONSTRAINT:** stop the watchdog, stop the process, copy, restart — then assert the **running
image's** hash, not the file's.
→ **VERIFY:** `(Get-FileHash (Get-Process gui-agent).Path).Hash` equals the intended artefact.

**2.4 Cloning: create → tag → copy. A bare `qvm-clone` is REFUSED.**
Policy is tag-based and `qvm-clone` copies volumes before the tag exists.
→ **VERIFY:** `add_new_vm` → `qvm-tags <vm> add win-idd-testbed` → `dst.volumes[v].clone(...)`.
Measured at **1.8 s** for a full guest. Never reinstall Windows to obtain one.

---

## 3. What dom0 can and cannot see

**3.1 `qtest shot` is STRUCTURALLY BLIND to override-redirect windows.**
They are undecorated and never appear in that enumeration.
*Incident 2026-08-31: the agent logged `msg=MAP,hwnd=0x3601e6,ovr=1,w=1920,h=1080` — a full-screen
override-redirect window offered to dom0, the exact takeover the design forbids — and the shot
showed only the control. The check reported "not mapped".*
→ **CONSTRAINT:** a "nothing mapped" verdict requires **two witnesses**: no matching window in the
shot **and** no `msg=MAP` for that hwnd in the agent log.

**3.2 An empty shot tar ≠ no windows.** Check the target exists and is tagged, then the tool,
before concluding anything about the guest.

**3.3 A whole-window pixel hash is not evidence about a region.**
It moves for a caret blink, a clock digit, a cursor.
*Incident: the menu check reported "the owner's pixels changed" with `SYNTHPAINT 0` — not one
paint had occurred.*
→ **CONSTRAINT:** crop to the rect the agent reports painting (`SYNTHPAINT rx,ry,w,h`,
owner-relative) and compare only that.

**3.4 Frame liveness is `QGAPERF` `seq` advancing.** Not a log string.
*Incident: the capture-death counter grepped `/capture thread|…/`, and with the fault armed the
only match in the whole log was the fault injector's own message.*

---

## 4. Verdict semantics a framework must enforce

These are the rules the **writer** must enforce, so no check can express them wrongly.

| | rule |
|---|---|
| **V1** | `PASS` requires a recorded fail-proof for that check. Without one the verdict is `PASS-UNPROVEN`. The writer refuses `PASS` otherwise — it is not a convention. |
| **V2** | `INVALID-*` is never folded into `FAIL`. A broken instrument is not a product defect. |
| **V3** | Missing data is `INVALID-INSTRUMENT`, never `FAIL` and never a default. `${x:-0}` on an unanswered query is forbidden. |
| **V4** | Every check must have at least one reachable non-PASS branch. A check that cannot fail does not load. (Lint L4 finds 9 today.) |
| **V5** | A verdict needs a vacuity guard proving the stimulus existed **and** evidence the stimulus reached the code under test. |
| **V6** | A fail-proof covers the **subject class it ran on**, not every row sharing the code. |
| **V7** | The registry is keyed by CHECK, not by row: one proof closes every row citing that check. |

**Framework obligations** (so harnesses cannot get them wrong): verdict emission, per-VM locking,
running-image hash assertion, containment re-establishment after any agent restart, and restore +
proof of restore are the **runner's** job. Today each of eleven harnesses hand-rolls these, which
is why 7 lack the lock and 9 have no FAIL branch.

---

## 5. Fault injection

`QGA_FAULT_INJECTION=1` (msbuild `-p:QgaFaultInjection=1`) compiles in `FI_*`; every fault is off
until an explicit registry value, so the unarmed fault build is behaviourally identical to release
— **both sides of a proof come from one artifact.** Release builds contain none of it.

→ **CONSTRAINT:** a fault's log message must not contain any string the checks grep for.
→ **VERIFY:** lint L5 intersects injector log literals with harness `Select-String` patterns.
→ **CONSTRAINT:** before spending a prove cycle (28 min, measured), run `gate-preflight.sh <vm>
<bits>` (3 min): if the harness cannot see its own control with the bit armed, the proof is
impossible through that harness.

---

## 6. NOT MECHANISABLE

Stated plainly so nobody assumes coverage:

1. **Does the stimulus reach the code under test?** Needs a run and a log read. chromerepro's
   shadow strips exist and are counted, and are rejected upstream by `GetRealWindowRect` as
   degenerate geometry before any chrome predicate runs — so the 2A-chrome cell greens without
   ever exercising the filter it names.
2. **Is this check worth having?** Triage by how loud the failure would be: a vacuous check for a
   silent failure is dangerous, for a loud one nearly harmless.
3. **Is the assertion the right assertion?** Only reading the code under test answers it.
4. **Is a "defence in depth" explanation true?** When a bypass does not move a cell, read the log
   for which clause actually rejected the stimulus. The honest answer may be "the test never got
   there".
