# ADR — logging: one destination, and not one file per call

## CURRENT STATE

**Decision (2026-10-07, superseding the OS-sink decision taken earlier the same day): per-line guest
logging stays TEXT, as ONE FILE PER MODULE PER DAY, opened append-only and shared for writing, each
line composed and written in a SINGLE `WriteFile`.** Jev `sink` **0.79** (conf 0.72),
`append_atomic_single_write` **0.84**, `earlier_answer_superseded` **0.72**; the event-log option fell
to **0.01** once the facts below were in the brief.

Shipped as `patches/windows-utils-one-log-per-module.patch`, applied unconditionally by both
workflows with marker assertions, guarded by `tools/tests/one-log-per-module-selftest.sh` (18 checks).

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
