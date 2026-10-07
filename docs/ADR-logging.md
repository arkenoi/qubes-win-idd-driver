# ADR — logging: one destination, and not one file per call

## CURRENT STATE

**Decision (2026-10-07): guest components log to the OS sink already present in this product — the
Windows Event Log source `Qubes Windows Tools` and ETW — rather than to per-process text files.
Jev `approach = os-event-log-or-etw` 0.82, confidence 0.77.** Implementation is incremental,
worst offender first; nothing has migrated yet.

### What is wrong today, measured

On a German Windows 11 25H2 guest after one install and three boots:

| | |
|---|---|
| log files in the QWT log directory | **386** |
| of which `qrexec-wrapper-*.log` | **368** — one file per qrexec call |
| logs written OUTSIDE the common log directory | **12** |
| of those 12, collected by nothing before 2026-10-07 | **8** |

Two consequences, both measured rather than argued:

* **The error gate dropped the death record.** The collector that feeds it caps at 60 files by
  priority; the 368 wrapper logs won that contest and `qwt-deaths.log` — the record of every death
  notified to dom0, including the one the owner saw on his screen — was skipped. Fixed for now by
  ranking (cefec046), but the cause is the file explosion.
* **"Read the log for this module" is not a thing you can do.** The module's lines are spread over
  hundreds of files named `<module>-<timestamp>-<pid>.log`.

Owner, 2026-10-07: *"one log per call is nonsense"*, *"keep logs in single place, sweep them
together"*, *"NOTHING should write log outside"*, *"use known logging framework, do not invent"*.

### Where the logging comes from

* The primitive is **upstream**: `qubes-windows-utils` `src/log.c` `LogInitDefault`, cloned fresh
  from `github.com/QubesOS/qubes-windows-utils` at build time. It names the file per process and
  opens it `GENERIC_WRITE | FILE_SHARE_READ`, so a second process cannot open it at all.
* We already patch that repo unconditionally, twice (interactive-logon token, service exit code),
  each with a post-apply marker check that fails the build if the patch no-ops. Patching it is an
  established route here.
* Our C++ components do not use it: `tools/notifhost/qtb_shared.h` has its own `BLog`.
* PowerShell uses `core-agent/src/qubes-rpc-services/log.ps1`, which also names a file per process.
* **Both OS sinks are already in the product**: `etwproxy.exe` (its own least-privileged account)
  and the Event Log source `Qubes Windows Tools` writing 4001-4004, which `qwt-report-death.ps1`
  already reads beside the Application, System, TaskScheduler and TerminalServices channels.

### Why the OS sink, and what was rejected

The OS serialises writers, so "one destination" is structural instead of conventional and
collisions cannot happen. Both sinks exist here and our tooling already reads event channels.

Rejected, with the numbers:

| option | Jev | why not |
|---|---|---|
| patch upstream to one file per module, opened append-shared | **0.13** | keeps a bespoke logger nobody audits, and adding append semantics, a prefix change and rotation by hand is the inventing the owner objected to |
| adopt a known C++ library (spdlog) | **0.00** | **not multi-process safe for a single file** by its own documentation, which is exactly the measured problem; and the worst offenders (`qrexec-wrapper`, `qrexec-agent`, `qubesdb`) are C, not C++ |
| keep text files, serialise with a named OS mutex | 0.04 | still a hand-built logger, with a lock to get wrong |

**A patch for the 0.13 option was written and then NOT shipped.** It applied cleanly and the build
step checked four markers, but its central mechanism — `FILE_APPEND_DATA` with
`FILE_SHARE_READ | FILE_SHARE_WRITE` — was scored `append_is_safe` **0.37**.

### The open tension, stated rather than buried

`append_is_safe` 0.37 **contradicts this product's own `BLog`**, which has used exactly that shape
since 2026-09-05, where it was adopted *because* two concurrent writers had collided in
`ERROR_SHARING_VIOLATION` and the losing line was silently dropped (ids 15/20/22 were forwarded and
acked but their `SENT` lines never landed). Either that shape is sound and 0.37 is wrong, or `BLog`
has a latent problem of the same kind it was meant to fix. **This is not resolved**, and it is a
reason to prefer the OS sink over any file-append scheme rather than a reason to dismiss either.

### What is done and what is not

* **Done**: `BLog` now writes to the common QWT log directory instead of the bridge's state
  directory (7e349bac); the collector gathers every log of ours outside `LogDir` and ranks
  `qwt-deaths.log` with the installer logs (cefec046); lint `L19` requires a guest-driving harness
  to sweep the log at all (762ca98b, pending with 30 named).
* **Not done**: no component has moved to the OS sink; `qrexec-wrapper` still writes one file per
  call; `QubesPvNic.log`, `QubesNetSetup.log`, `QubesIDD-diag.log`, the updater's
  `C:\ProgramData\Qubes\wu\*.log` and the `C:\` root setup logs still write outside the common
  directory.
* The rig's analyzer parses three text formats by regex (`WINUTILS_RE`, `BLOG_RE`,
  `INSTALLER_RE`); a migration has to give it an event-channel reader, and the collector already
  pulls event records, so that half exists.

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.
