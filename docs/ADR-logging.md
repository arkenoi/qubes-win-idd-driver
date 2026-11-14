# ADR — logging: one destination, and not one file per call

## CURRENT STATE

**Decision (2026-10-07, superseding the OS-sink decision taken earlier the same day): per-line guest
logging stays TEXT, as ONE FILE PER MODULE PER DAY, opened append-only and shared for writing, each
line composed and written in a SINGLE `WriteFile`.** Jev `sink` **0.79** (conf 0.72),
`append_atomic_single_write` **0.84**, `earlier_answer_superseded` **0.72**; the event-log option fell
to **0.01** once the facts below were in the brief.

Shipped in `winutils/src/log.c`; until 2026-11-07 as `patches/windows-utils-one-log-per-module.patch`,
applied unconditionally by both workflows with marker assertions. The patch stack has since become
commit `e25cbc1` of the `winutils` submodule (`ADR-upstream` §4). Guarded by
`tools/tests/one-log-per-module-selftest.sh`, which read the patch (18 checks) and now reads
`winutils/src/log.c` itself.

**Decision (2026-11-01): EVERY log a component of ours writes goes into the ONE directory, and every
line in that directory is accounted for by the sweep.** Owner, 2026-11-01: *"fix all logs locations,
MAKE SURE ALL LINES THERE ARE ACCOUNTED FOR IN SWEEP"*; 2026-10-07: *"NOTHING should write log
outside"*. The bullet that sat under "Not done" since 2026-10-07 is this decision's reason.

1. **The directory** is log.c's rule, for every writer: registry `LogDir` at the root key, else
   `<SystemDrive>\Qubes Logs`.
2. **The line** is the windows-utils shape `[yyyyMMdd.HHmmss.fff-PID[:TID]-L] msg`, one file per
   module per day: `<module>-<yyyyMMdd>.log` for native and C# writers, `<script>.ps1-<yyyyMMdd>.log`
   for PowerShell. Kept in their own declared shapes and matched by name: `bridge.log` and
   `etw-proxy.log` (BLog), `qwt-deaths.log` (`yyyy-MM-dd HH:mm:ss [LEVEL]`, UTC), the bind-dirs logs,
   and DISM's own log, `dism-<yyyyMMdd>.log` (the vendor's shape, a sweep family of its own).
3. **The PowerShell sink is the framework we already ship**, `core-agent/src/qubes-rpc-services/log.ps1`
   (*"use known logging framework, do not invent"*). It gains one primitive, `Write-QwtLogLine
   <E|W|I|D|V> <msg>`, which returns whether the line was written; `LogError`..`LogVerbose` call it
   directly; the file is staged into `bin` beside the scripts that use it. Each script keeps its own
   `Log` wrapper and every call site; the updater keeps its loss accounting (`QWTUPDLOGLOST`) on the
   primitive's return. The two C# writers, the updates relay and the netsetup service, write through
   the library every Qubes Tools program already logs through, `windows-utils.dll` (System32, MSI-installed,
   our `winutils/src/log.c`), by DllImport of `LogStart` / `LogInit` / `LogInitDefault` / `_LogFormat`: the relay
   `LogStart` on the file the updater names, else `LogInit(<--log>, "qubes-updates-relay")`; each handler
   `LogInit(<--log>, "relay-handler")`; the netsetup service no init at all, because its qubesdb client has
   already initialised the library in that process. A hand-written C# sink was specified first and
   withdrawn (owner, 2026-11-02: the order was "use known logging framework, do not invent"; it overwrote
   lines under concurrency, which the library had solved). Jev: helper H1 **0.98**; updater keeps its own
   Log, new path and prefix **1.00**.
4. **Moved**, each with every reader in the same commit, including the two texts a user reads that name
   a moved file (the death reporter's PV NIC impact line, activate-idd's "Evidence:" line):

   | writer | was | now |
   |---|---|---|
   | updater (`qubes-windows-update.ps1`) | `C:\ProgramData\Qubes\wu\agent.log`, cumulative | `qubes-windows-update.ps1-<d>.log` |
   | updater's DISM calls | `wu\dism.log` | `dism-<d>.log` |
   | updates relay and its handlers | `wu\qubes-updates-relay.log`, `wu\relay-handler.log` | `qubes-updates-relay-<d>.log`, `relay-handler-<d>.log` |
   | `vmupdate-shim.ps1` | `C:\ProgramData\Qubes\vmupdate-shim.log` | `vmupdate-shim.ps1-<d>.log` |
   | PV NIC per-boot payload (`bin\pvnic-boot.ps1`, written by `pvnic-selfprime.ps1`) | `C:\ProgramData\QubesPvNic.log` | `pvnic-boot.ps1-<d>.log` |
   | netsetup service | `C:\ProgramData\QubesNetSetup.log`, `Q:\qwtng-netsetup.log` | `qwtng-netsetup-<d>.log` |
   | `activate-idd.ps1`, `deactivate-idd.ps1` | `C:\qwt-idd-activate.log`, `C:\qwt-idd-deactivate.log` | `activate-idd.ps1-<d>.log`, `deactivate-idd.ps1-<d>.log` |
   | reboot-cause recorder | `reboot-audit.log` (second fallback `C:\Users\Public\Documents\Qubes Logs`) | `record-reboot-cause.ps1-<d>.log` |
   | `ensure-autologon.ps1`, `quiet-desktop.ps1` (SYSTEM tasks) | nowhere: console output only | `ensure-autologon.ps1-<d>.log`, `quiet-desktop.ps1-<d>.log` |

   Two files in the directory carry no writer of ours by name: `qwtng-netsetup-<d>.log` and
   `powershell-<d>.log` open with the library's own `LogInit: Log started, module name: ...` line, so
   the windows-utils library writes them under the name of the process that loaded it. The netsetup
   service's own lines join the first: one process, one file, appends shared for writing.
5. **Not logs, so out of the directory:** `qwt-death-watermark.json` and `reboot-audit.last` go to
   `C:\ProgramData\Qubes`; `record-reboot-cause.ps1`, a script, goes to `bin`.
6. **Declared exceptions.** (a) The installer: `C:\qwt-improved-install.log` stays the primary, because
   a clean install's first lines precede the directory, and is mirrored into it from the line it
   exists (b47325e5); msiexec's verbose logs stay `C:\qwt-install.log` / `C:\qwt-uninstall.log`
   (Jev `msi_to_logdir` **0.30**). (b) `C:\ProgramData\QubesIDD-diag.log`, written by the UMDF
   display driver as LocalService: a driver-track item, queued (Jev **0.88**). (c) State and
   instrument records are not logs: `update-status.json`, `update-refusal.json`, `notify-errors\`,
   the PV NIC marker files, the installer's stage flag `C:\qwt-improved-stage1.json`,
   `reboot-dialog-watch.jsonl`.
   (d) `relocate-dir.exe` is a native boot-time program (BootExecute, before the Win32 subsystem and
   before the private volume is reliably mounted): it keeps `C:\relocate-dir-<d>-<t>.log` and
   `C:\relocate-dir-result.txt`, read by the collector. (e) `C:\qubes-win-idd-setup.log` and
   `C:\qubes-de-firstlogon.log` are written by the harness's own payloads (mgmt/payload-setup*.cmd,
   the prime jobs' onboot.cmd), not by anything that ships.
7. **Accounted** is one decidable property of the sweep (Jev **0.71**), computed per file:
   * **Scope.** Every file in the directory, any extension, subdirectories included; the declared
     exceptions of item 6 that are logs, at their fixed paths: the installer's three C: logs,
     `QubesIDD-diag.log`, relocate-dir's `.log` and the two harness payload logs (records such as
     `relocate-dir-result.txt` and `qwt-improved-stage1.json` are not); and every file at an OLD
     PATH, the "was" column of item 4's table: `C:\ProgramData\Qubes\wu\` `agent.log`, `dism.log`,
     `qubes-updates-relay.log`, `relay-handler.log`; `C:\ProgramData\Qubes\vmupdate-shim.log`;
     `C:\ProgramData\QubesPvNic.log`; `C:\ProgramData\QubesNetSetup.log`; `Q:\qwtng-netsetup.log`;
     `C:\qwt-idd-activate.log`; `C:\qwt-idd-deactivate.log`; `reboot-audit.log` in the directory and
     in `C:\Users\Public\Documents\Qubes Logs`. An old path inside the directory takes the legacy
     kind. The collector lists each file with its path, last write time and line count.
   * **Kind.** The file's NAME matches exactly one declared rule in `tools/log-sweep.py`: a product
     log family, a state file, a harness artefact, a legacy per-process name, or one of the declared
     exceptions above. A family found by sniffing the content, or the `plain` fallback, does not
     account for a file. No match, or two, is `unaccounted-file`.
   * **Lines.** A file whose kind holds log lines and whose last write is inside the window
     (`--since`) has `total = parsed + continuation + not_pulled + unparsed`, where `total` is the
     collector's count and a continuation is a line its family's parser attaches to the record above.
     A state file, a harness artefact, or a file last written before the window is checked for its
     kind only. The collector (PowerShell) and the sweep (Python) count lines by one rule, because the
     identity compares their numbers: decode by the byte-order mark (UTF-16 LE/BE, or UTF-8 with the
     mark dropped), else as UTF-8; split on LF; drop one trailing CR from each piece; drop the empty
     piece after a final LF. Every other piece, an empty one included, is a line.
   * **Verdict.** Accounted means no problem. The problems, each named with the file and its counts
     and each P2 (the instrument's class): `unaccounted-file`; `unaccounted-lines` (unparsed > 0);
     `unpulled-lines` (not_pulled > 0, a capped pull); `ledger-mismatch` (a row that does not add
     up); `stray` (a file at an OLD PATH last written inside the window and not before the install
     anchor: something of the build under test still writes there). The install anchor is the
     sweep's own "when the build under test first ran" (`install_anchor`); an old path carries no
     version, and on an upgrade cell the predecessor boots inside the window and writes its old
     paths, so a file last written before the anchor is reported as the predecessor's, never as a
     problem (Jev **0.99**). The same test answers for an EMPTY legacy per-process log: last written
     before the anchor it is the predecessor's, listed by name as expected-empty and not graded as
     missing data (Jev **0.83**; that the rule can hide an empty log of the build under test: 0.30,
     no verdict); with no anchor, or written at or after it, it stays the data problem `empty`.
     A declared exception is never `stray`. For a file the ledger checks,
     `unpulled-lines` and `unaccounted-lines` replace the older per-file `partial` and `unparseable`
     (one problem per fact, Jev **1.00**); files outside the scope keep those.

Measured before the decision, 2026-11-01. Per-file accounting over GWeck's own folder (forum
bundle, build 4.3.37.1096) and campaign bafe660f's collection. Of GWeck's 20 files, 7 were not
accounted: 6 had no name rule or were state, a script or levelless, and one, qrexec-wrapper's, held a
line of two raw bytes (`0x0F 0x02`). The campaign's collection showed `reboot-audit.log` and the
harness's `module-bases.txt` levelless as well, and three files from outside the directory:
`QubesIDD-diag.log` levelless, `QubesNetSetup.log` and `QubesPvNic.log` matched only by sniffing.
The directory's ACL on win10-tup: SYSTEM and Administrators full control, Authenticated Users modify,
inherited from `Q:\`; every scheduled task and service of ours runs as SYSTEM, so no ACL changes
(Jev `acl_settled` **0.84**). The legacy names come from a census of every file name in the log sets
collected under `~/qwt-accept` and in GWeck's folder.

Measured off the guest, 2026-11-02 (apparatus commit b6e5cc15): the collector, run under pwsh 7
over a copy of a smoke run's real guest directory (66 files, 46 of them old per-process logs),
accounts for 66 of 66 files and 1740 of 1740 lines; each of the 12716 file names in the guest log
directories this project's run collections hold matches exactly one rule. Two gaps were found by it:
the collector's pull priority still named the old files, and the installer mirror's header line was
undeclared. For the guest's PowerShell 5.1 the collector is clean by
tools/ps-compat-check.ps1 and by PSScriptAnalyzer's compatible-commands and compatible-types rules against
the Windows 10 / PowerShell 5.1 profile (0 findings each). The guest run - the fixed paths, the old paths and
`stray` against the anchor - is measured by the full campaign at the final HEAD, whose sweep reads
every cell's directory.

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
**CORRECTED 2026-11-07:** it is not upstream - nothing outside QWT consumes that library
(`ADR-upstream` §4) - and it is no longer cloned or patched: `winutils/src/log.c` is ours, carried
as the `winutils` submodule.

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
  rotation/purge is the mechanism v4.2.2 shipped, untouched.
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
* `QubesIDD-diag.log` still writes outside the common directory: the declared driver-track exception of
  the 2026-11-01 decision. The other writers this bullet named moved with that decision.
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
