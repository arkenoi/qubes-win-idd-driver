# ADR — logging: one destination, and not one file per call

## CURRENT STATE

**Decision (2026-10-07, superseding the OS-sink decision taken earlier the same day): per-line guest
logging stays TEXT, as ONE FILE PER MODULE PER DAY, opened append-only and shared for writing, each
line composed and written in a SINGLE `WriteFile`.** Jev `sink` **0.79** (conf 0.72),
`append_atomic_single_write` **0.84**, `earlier_answer_superseded` **0.72**; the event-log option fell
to **0.01** once the facts below were in the brief.

Shipped as `patches/windows-utils-one-log-per-module.patch`, applied unconditionally by both
workflows with marker assertions, guarded by `tools/tests/one-log-per-module-selftest.sh` (18 checks).

**Decision (2026-10-25): the acceptance log volume's DEVICE SET has one owner and four named
phases** — `priming` / `graded` / `answer` / `none` — composed whole by
`mgmt/harness/logvol-lib.sh`, applied only at a domain boundary through a writer that refuses a live
domain, and enforced by `lint-harness.py` L31 across `mgmt/harness/*.sh`, `tools/*.sh` and
`mgmt/*.sh`. Two campaigns aborted on hand-composed copies of that value; the detail is below under
"The device set has ONE owner". The bind itself is now smoke-tested ahead of every campaign, both
arms, with no off switch — MEASURED on the rig 2026-10-25, PASS in 3m01 and a refusal in 2m09.

### What was wrong, measured

German Windows 11 25H2 guest, one install + three boots:

| | |
|---|---|
| log files in the QWT log directory | **386** |
| of which `qrexec-wrapper-*.log` | **368** — one per qrexec call |
| logs written OUTSIDE the common log directory | **12** |
| of those, collected by nothing before 2026-10-07 | **8** |

The sweep that feeds the release gate caps at 60 files by priority. The 368 wrapper logs won that
contest, so `qwt-deaths.log` — the record of the death the owner saw on his screen — was skipped.
And "read the log for this module" was not a thing you could do.

Owner: *"one log per call is nonsense"*, *"keep logs in single place, sweep them together"*,
*"NOTHING should write log outside"*, *"just make sure file writes do not collide"*, *"use known
logging framework, do not invent"*, *"fix logging, this mess is unacceptable"*.

### The fix

The primitive is upstream `qubes-windows-utils` `src/log.c`, cloned fresh at build time; we already
patch that repo, now four times, each with a marker check that fails the build on a no-op.

1. **One file per module per day.** `LogInit`'s format string carried module, date, time and pid.
   The **date stays**: `PurgeOldLogs` deletes by `ftCreationTime`, so a dateless name keeps its first
   creation time for ever and the retention sweep would delete the *live* log.
2. **Append-only, shared for writing.** `FILE_APPEND_DATA` *without* `FILE_WRITE_DATA`,
   `FILE_SHARE_READ | FILE_SHARE_WRITE`. The old open was exclusive-write, which is why the name had
   to be unique.
3. **One `WriteFile` per line.** The old code wrote prefix, body and newline as three calls, which
   two processes would interleave *inside* a line. Same bytes, fewer calls.

Part 3 is what makes part 2 sound and is what reversed the earlier decision: the `append_is_safe`
0.37 below was scored against a patch that kept the three calls. That also closes the tension this
ADR used to record as open — `BLog` has used the same shape since 2026-09-05 and is sound *because*
it writes one line per call.

### Three defects found in review, all fixed here

* **A BOM race.** `OPEN_ALWAYS` plus "if length is zero write the BOM" lets two simultaneous starters
  both write one, leaving a doubled BOM and one unparseable line. `CREATE_NEW` now decides it.
* **The pid was lost.** It lived in the file NAME and nowhere else; the line prefix carries the
  *thread* id. A shared file whose lines do not name their process is unreadable, so the prefix is
  `pid:tid` and `tools/log-sweep.py` accepts both shapes (guests still hold old logs).
* **Safe flush became a silent no-op.** `g_SafeFlush` exists so a line is on disk before a crash and
  was serviced by `FlushFileBuffers`, which wants `GENERIC_WRITE` that an append-only handle does not
  have — and the return value was ignored. A safe-flush log is now opened `FILE_FLAG_WRITE_THROUGH`,
  and `LogFlush` reports a refusal once.

Two pre-existing defects rode along in the same lines: log text passed as a printf **format string**
to `fwprintf` twice, and an empty message reading `g_BufferUtf8[-1]`.

### Rejected, with the numbers

| option | Jev | why not |
|---|---|---|
| every line to the Application event log via `ReportEvent` | **0.01** | one RPC per line into a shared, size-capped, circular OS log every other product uses. That source is already written for notable *events* (deaths, 4001-4004, `agent/include/deathevent.h`) — the right instrument for events, the wrong one for per-line tracing. |
| a private ETW provider with a boot-time autologger | 0.07 | ETW keeps nothing without a running session, so the lines the gate reads would simply be gone (`data_loss_risk` 0.66, the worst option). Plus a compiled manifest and an `.etl` reader we do not have. |
| one file per module keeping the three writes | 0.13 | superseded, not wrong: see `append_is_safe` 0.37. |
| spdlog | 0.00 | not multi-process safe for one file by its own docs — the measured problem exactly; and the worst offenders are C. |
| text files serialised by a named OS mutex | 0.04 | a hand-built logger plus a lock to get wrong, where the OS already offers atomicity. |

### The numbers that do NOT favour this decision

* **`meets_owner_constraints` chose the event log, 0.61 at confidence 0.48**, against this at 0.22,
  because a **bespoke logger survives this fix** — which is what *"do not invent"* was aimed at. What
  the fix does is make it smaller: the per-process naming and the three-write line are gone, and
  rotation/purge is the upstream mechanism, untouched.
* **`missing_measurement = total-line-volume-per-boot`, confidence 1.00.** Now instrumented rather
  than argued: the collector reports `LSW INVENTORY` / `LSW INVMODULE` for the log directory itself,
  independent of the collection cap, and the analyzer names it in the summary (41aae917). The number
  itself arrives with the next rig run.

### Knock-ons, which are part of this fix

A shared file means no new file on restart, and a previous instance's lines in the file the new one
writes to. Anything that identified a process by its log's name, trusted the *first* `process ID:`
header, or took *any* matching line as the current instance's, is now wrong:

* `guest/restart-gui-agent.ps1` did all three. Identity is now the **last** init record, its line
  timestamp must be at or after the service start, the pid's age is bounded by that line rather than
  the file's creation time, and the serving marker must appear after it. `log-pid-mismatch` and
  `no-new-log` are replaced by `no-new-init`, `no-init-record`, `init-timestamp-unreadable`.
* Four harness reads were satisfiable by an earlier instance; fixed, with lint `L20` catching the
  class per read site and naming 6 remaining (b5e5b6a1).
* `core-agent/src/qubes-rpc-services/log.ps1` named per pid too. Now one file per script per day, and
  since PowerShell has no atomic-append primitive the append retries a bounded number of times on a
  sharing collision and then **says the line was lost** on stderr.

### The log volume is an instrument, and it does not decide where the product logs

A removable FAT volume (label `DIAG`, frontend `xvdj`) is attached to every acceptance subject. It
exists for ONE purpose: reading a WEDGED guest's logs from the host with mtools, without the guest's
cooperation and without detaching anything. That part works and is kept.

What it must NOT do by default is redirect the product's own `LogDir` onto itself. Two reasons, and
the second is measured:

* **It substitutes test conditions.** An acceptance run is supposed to measure the configuration we
  ship. Pointing `LogDir` at a test stick measures a configuration no user has. On a guest that is
  not wedged there is nothing to recover anyway — qrexec reads the logs.
* **`LogInit` does not wait for a USB volume.** Every module reads `LogDir` once, when it starts.
  The volume is a USB device behind an emulated xHCI controller and enumerates on its own schedule,
  so a module that starts first opens no log at all — and never retries. Measured 2026-10-15 with
  the drive letter already pinned and verified: the bind reported `drive=Z: found=E: letter=pinned
  copied=21`, the volume was mounted at `Z:`, 23 files were readable on it from the host — and
  nothing was written to it after the cell's park/restore. `agent_log_healthy` returned
  `any_agent_log_held_open: false` while the agent was alive; the IDD check found no line to read;
  the console-window check reported `INVALID-INSTRUMENT`.

The control settles it: the `WIN10-clean` accept battery PASSED in the two campaigns before this
redirect was wired into that cell and failed in every campaign after.

So `LOGVOL_BIND` defaults to 0. `LOGVOL_BIND=1` is for hunting a wedge. The stick stays attached
either way, because it also carries the installer's own diagnostic markers, which a stalled install
needs whether or not logs are redirected.

**The mistake worth remembering is not the race, it is the override.** The comment above that gate
already carried the measurement — "need not be mounted when a service starts" — and, in the same
paragraph, "ON BY DEFAULT now that the letter is resolved by label and PINNED". Pinning the letter
was a real fix for a real defect; it simply had nothing to do with whether the volume is mounted
before the agent's `LogInit`. "Mounted at a stable letter" and "mounted in time" are different
claims, and a theory about the first was allowed to overrule a measurement about the second.

### The device set has ONE owner and named phases, applied at a domain boundary

`qemu-extra-args` is a SINGLE feature value and it is read at DOMAIN CREATION, nowhere else. Writing
it while a domain is up changes nothing the running guest can see while making every later reader
believe the device set it describes is in force.

Four places composed that value independently: `prime-run.sh` wrote the answer stick's fragment
literally and let `logvol_attach` compose ours onto it, `matrix.sh` carried a pattern to STRIP the
priming fragments mid-cell, `logvol-smoke.sh` composed its own, and `provision-recipe.sh` held a
fifth copy with no caller at all. `mgmt/prime-selftest.sh` and `mgmt/reprovision-usb.sh` each held a
literal copy too. Nothing declared what the set IS for a given phase; the lifecycle existed only as
a convention spread across those files.

**What it cost, measured twice.** Campaign 40134888669: `matrix.sh` rewrote the args at 22:12:18 to
drop the priming sticks against a RUNNING `win10-acc`; eight seconds later the bind refused with
`no_volume_labelled_DIAG_with_LOGVOL.TAG` and the guest, asked directly, reported the 256 MB image
as `XENSRC PVDISK bus=SCSI ... parts=0` with no USB disk device at all. The campaign aborted on its
first cell, 11 minutes in, having spent 10 of them installing. Campaign 1024-2333, after the writer
was made to refuse a live domain: the bind SUCCEEDED, the nonce round trip PROVED
(`LVPROOF-20261024T234505Z`), the install parked — and the first judged boot reported `t+60s
qvm=Halted`. The domain was never created, because the refusal left `file=/dev/xvdi` in the recorded
value for a loop the matrix had just UNASSIGNED. A policy change in one file broke a lifecycle kept
in another.

Owner's diagnosis, which is the level above both bugs: *"that because you organically cannot keep
matrix and smoke test configurations in sync."*

So one declaration, four named phases, composed WHOLE and never edited as a string:

| phase | devices | used by |
|---|---|---|
| `priming` | controller + answer stick (readonly, `bootindex=99`) + evidence volume | `prime-run.sh`, `reprovision-usb.sh` with its marker volume |
| `graded` | controller + evidence volume | `matrix.sh` at the park/halt boundary, `logvol-smoke.sh` before first boot |
| `answer` | controller + answer stick | `prime-selftest.sh`, `reprovision-usb.sh` without one |
| `none` | nothing | `seal-qwt-golden.sh`, `rebuild-rig.sh`, `provision_disarm` — each BELOW its halt |

`logvol_devices_apply <vm> <phase>` is the only way a harness sets it, it goes through the one
writer, and that writer refuses a live domain. `lint-harness.py` L31 refuses any other writer across
`mgmt/harness/*.sh`, `tools/*.sh` and `mgmt/*.sh`, in both argument orders, with a READ of the
feature left silent. Jev: phase-function 0.98, swap after-park-halt 0.80, lifecycle placement 0.99.

**A blanket `--unset` is not a teardown primitive, it is the `none` phase.** It deletes our drive,
our `usb-storage` device AND the `nec-usb-xhci` controller they ride on. Three teardown paths did it
directly, and two of them did it ABOVE their own shutdown — where the one writer's refusal would be
swallowed and a golden SEALED carrying a provisioning rig, inherited by every clone taken from it.

**And the bind is smoke-tested before a campaign spends a cell.** `mgmt/harness/logvol-smoke.sh`
clones the QWT golden, applies `graded` before first boot, binds, and reads a nonce back off the
image with mtools and no guest; `--no-attach` runs the identical sequence with nothing attached and
the bind MUST refuse. Both arms run ahead of the matrix, refutation first, with no off switch.
MEASURED on the rig 2026-10-25: `graded` applied → `boot wait exit: up` → `bind ok mode=registry
drive=Z: found=D: letter=pinned copied=72 safeflush=1 modules=12` → nonce read back, PASS in 3m01;
`--no-attach` REFUSED with 40134888669's own signature, PASS in 2m09. That cell binds deliberately,
which is not a contradiction of `LOGVOL_BIND=0` above: the bind is its subject, not its method.

### Not done

* Nothing has run on a guest: every file-count claim is a prediction until then.
* No concurrent-append test on local NTFS — atomicity rests on the documented `FILE_APPEND_DATA`
  contract, not on a measurement of ours.
* `QubesPvNic.log`, `QubesNetSetup.log`, `QubesIDD-diag.log`, the updater's
  `C:\ProgramData\Qubes\wu\*.log` and the `C:\` root setup logs still write OUTSIDE the common
  directory, against a direct instruction.
* Within one day a module's file has no size bound, only the age-based purge. Total bytes logged are
  unchanged; the maximum size of one file is what grew.

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

### 2026-10-07 — the OS sink was chosen, then superseded the same day

The first decision was `approach = os-event-log-or-etw` **0.82** (conf 0.77), with one file per
module at 0.13 and `append_is_safe` 0.37. That brief lacked three facts, two against it: the
Application log is a shared size-capped OS log and `ReportEvent` is one RPC per line; ETW keeps
nothing without a session; and the 0.37 was scored against a line written in three calls. Re-asked
with those facts, event log came back 0.01 and this option 0.79, with
`earlier_answer_superseded` 0.72. The 0.82 stands here as the record of a judgment made on a
one-sided brief.
