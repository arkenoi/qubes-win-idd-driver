# ADR — supervision: how our components are kept alive, and how their deaths are made loud

**Status: accepted 2026-10-03. Decided, not yet implemented** (tracked in `findings/issues.md`).

This file records DECISIONS. It does not say what works today. Each section states the decision, then why.

## 1. Anything of ours that dies unexpectedly is a major ERROR, and it is LOUD

The owner, 2026-10-03:
- "anything that dies unexpectedly should signal LOUD"
- "it is not fucking warning! it is a major error!"

Every unexpected death of one of our processes or services is:
- an **ERROR** in our own logs, never a warning;
- an **ACTION** notification to dom0, for **every** death, each one counted. A second death in the same boot is a second notification, never hidden by de-duplication. The existing per-boot storm cap (eight) still bounds a crash loop. Past the cap every death is still logged as an ERROR.

This applies to the GUI agent, to every helper a supervisor relaunches (broker, notification bridge, etwproxy), and to every service we install. Jev, 0.74, with the owner's rule as premise.

"Unexpected" means not requested by the component's owner. A service stop the service manager asked for, or a helper the agent shut down, is not a death.

A relaunch still follows where the GUI or a channel must come back. It is never a quiet recovery again.

**Why:**
- A relaunch that only writes a warning line hides the failure. That is the shape the rules forbid for fallbacks and for components that stop working.
- On 2026-10-03 a GUI agent crash (fast-fail `0xC0000409`) sat in Windows Error Reporting on a test guest. The watchdog's single warning line was the only other trace.

## 2. Detection uses the system's own records

The owner: "use system mechanisms, not ad hoc watchdog scripts".

| what died | the system already records it |
|---|---|
| any of our processes CRASHED | Windows Error Reporting; Application log event 1000 (faulting application and exception code) and 1001; `.NET Runtime` 1026 for managed ones |
| any of our services ended unexpectedly | System log 7031 / 7034; 7023 / 7024 when it ended with an error |
| a scheduled task's action failed | TaskScheduler/Operational 201 (non-zero return code), 203 (launch failed) |

The one death the system cannot see: a process a supervisor of ours started exits without crashing, and nobody asked it to. That supervisor writes an **Event Log entry** under our own registered event source; it writes nothing else. Today the supervisors are the GUI watchdog for the agent, and the agent for its broker, bridge and etwproxy.

Our services must make their failures visible to the service manager. A worker failure ends the service with a **non-zero exit** or a service-specific error, so 7023/7024 and the SCM's recovery fire. The standing finding is that QdbDaemon and QrexecAgent end with exit code 0 when their worker fails, which is invisible. Jev, 0.86.

**Why:**
- These records exist on every Windows install, cost nothing to keep and are already trusted by the platform's own tooling.
- Per-component reporting code is a second, partial, inconsistent copy of them.

## 3. ONE reporter, and the notification is ours

A single **event-triggered scheduled task** subscribes, with an XPath query, to every record in section 2, filtered to our components. Its action sends **our** dom0 notification: the error-notify route, `qubes.Notifications`, gated by `notify-errors`, with its per-boot cap.

The notification carries:
- what died;
- the exit or exception code, with its meaning when known;
- how long it had run;
- the death count this boot;
- where the evidence is (the WER report, the log).

No component sends its own death notification.

The owner: "notification that hits user screen should be ours ... for the rest, no kolkhoz solutions". The alternatives were weighed:
- a toast inside the guest is invisible in seamless mode;
- dom0 has no other per-qube health surface.

**Why:** one reporter gives one message format, one place to gate, cap and de-duplicate, and one thing to test. The trigger is the system's, not a poll.

## 4. Restarts use system recovery; a supervisor service only where nothing else can do the job

- **Every service of ours has SCM recovery actions**, with `failureflag` so that non-crash failures count too. That covers QdbDaemon, QrexecAgent, QubesGuiWatchdog and QwtngNetSetup. Today only the first two are armed.
- **Task-launched helpers** use Task Scheduler's restart settings where its restart interval fits the need. Where it does not (a helper that must be back in seconds, not after a minute), the agent's relaunch stays. It is bounded and ERROR-logged, and its deaths are reported through section 3.
- **The GUI agent stays under the QubesGuiWatchdog service.** That is the one job no system mechanism does: starting a SYSTEM-token process inside the user's interactive session. The watchdog service itself is SCM-recovered.
- **No ad hoc watchdog scripts, no polling loops, no kill loops** (see `docs/ADR-updater.md` 12.4 for process ownership). A state that must hold is configured at its source: a service start type, a policy, a task setting. It is not re-enforced by killing.

Jev, 0.99.

**Why:** the platform's recovery is documented and observable (7031 says which action it took), and survives our own bugs. Each hand-written relaunch loop is one more thing that can fail quietly.

---

## Implementation notes (2026-10-03; not decisions - what was built, and what the rig still has to show)

- **Section 2, our event source.** `Qubes Windows Tools` in the Application log, registered by the installer
  (`Register-QwtEventSource`, `reg.exe`, message file `%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\EventLogMessages.dll`:
  every message id renders `%1`, present on every Windows 10/11 as an OS component, the same file `New-EventLog` and the
  QubesPvNic/QubesNetSetup sources already use). The supervisors write ONE event per death with the agent's header-only
  `include/deathevent.h` (ids 4001 gui-agent by the watchdog, 4002 wgcbroker, 4003 notifhost, 4004 etwproxy; strings %2..%6 =
  exe, pid, exit code, run time, the supervisor's detail). Sites: `watchdog.c` at its death line; `main.c` QGABROKERDIED and
  QGANOTIFBRIDGEEXIT; `etwproxy.c` EtwProxyExitCb (every exit that reaches it; its three relaunch lines and the park line are
  ERROR now). UNCOMPILED here (gcc -fsyntax-only against stubs + the real windows-utils headers; CI builds it); the record's
  contract is pinned by `gui-agent/deathevent_test.c` via `tools/tests/deathevent-selftest.sh`.
- **Section 2, services visible.** The exit-0 swallow was not in the services but in windows-utils' `SvcMainLoop`
  (`SvcSetState` ignored its exit code; the wrapper of QrexecAgent and of the qubesdb daemon alike). Fixed by
  `patches/windows-utils-service-exit-code.patch`, applied by `build.yml` and `qwt-full.yml` like the interactive-logon patch;
  `tools/tests/svc-exitcode-selftest.sh` proves it against the exact ref CI clones (v4.2.2) and sees the unpatched file fail.
  qrexec-agent.c already returned the worker's Win32 code; the qubesdb daemon returns `ERROR_UNIDENTIFIED_ERROR` on a failed
  mainloop. A stop request stays exit 0.
- **Section 3, the reporter.** Task `QwtDeathReporter` (SYSTEM, EventTrigger, `Queue`, ValueQueries = channel + EventRecordID
  only), action `guest/qwt-report-death.ps1` in bin, route `qwt-notify-error.ps1` (gate, redaction, cap 8). The subscription is
  data in `Register-QwtDeathReporter` and is evaluated offline by `tools/tests/death-reporter-xpath-selftest.py`; the
  reporter's identity/count/text by `tools/tests/death-reporter-selftest.sh`; the registration by
  `tools/tests/supervision-install-selftest.sh`. Microsoft-Windows-TaskScheduler/Operational is enabled by the installer:
  client Windows ships it disabled, and 201/203 are never written otherwise.
- **Section 4, restarts.** `Set-QubesServiceRecovery` arms QdbDaemon, QrexecAgent, QubesGuiWatchdog; `pvnic-selfprime.ps1`
  arms QwtngNetSetup where it creates it; `health-check.ps1` 2b asserts all four (`tools/tests/health-recovery-selftest.sh`).
  Task-launched helpers: Task Scheduler's restart-on-failure interval is **1 minute at minimum** (`RestartOnFailure/Interval`,
  PT1M..P31D; count 1..999) and applies to an instance that ended with a non-zero result. The broker must be back in ~8 s
  (the agent's relaunch throttle; QGADESLICEDOWN escalates at 30 s): 60 s does not fit, the agent's bounded relaunch stays.
  The bridge's agent relaunch is already one per 60 s, numerically equal, but it re-validates the gate, restores the banners
  and ENDS any stale instance through `schtasks /create /f` - a second supervisor would race it - so the agent's relaunch
  stays for both, and their deaths are reported through 4002/4003 (and the task's 201).
- **Still owed on a guest (the release gate, win11 cell):** (1) `Register-QwtEventSource` + `Register-QwtDeathReporter` report
  `registered` in the RESULT; `schtasks /query /tn QwtDeathReporter /xml` shows the subscription; (2) a forced gui-agent.exe
  crash yields Application 1000 (+1001) and our 4001, exactly ONE notification `gui-agent.death-1` in dom0, one `DEATH #1 NEW`
  line in `qwt-deaths.log`, and `AGAIN` lines for the 1001/4001 records; a second forced crash yields `death-2`; (3) a forced
  `WaitForQdb` timeout (QrexecAgent) yields System 7023 with error 1460 and 7031 with the restart, and the SCM restart happens;
  (4) a clean boot and a clean shutdown produce ZERO notifications and no `DEATH` line (the negative control); (5) `wevtutil gl
  Microsoft-Windows-TaskScheduler/Operational` reads `enabled: true` after the install.
- **Review, 2026-10-03 (Jev per claim).** Found and fixed before commit:
  - A pid-less record (1001, 7031/7034, a helper task's 201) attached to any death of its executable within 600 s. A service that kept
    exiting without a crash record (7031 only, restarted at 5/15/60 s) was ONE notification for three deaths. Now one death holds at most
    one record of each type, and a pid match obeys the same rule, so a reused pid cannot hide a second crash.
  - A WER 1001 and a helper task's 201 only JOIN a death. A 1001 carries no path: a foreign same-named executable's 1001 opened a death
    of ours. A helper's 201 also follows an end the agent asked for, while its own 4002/4003 is the death record.
  - A .NET 1026 counts only for our two managed executables. Our install directory comes from the registry (`InstallDir`) or from the
    reporter's own folder, never from a hard-coded default that would refuse every crash of an install elsewhere.
  - The windows-utils patch keeps a REQUESTED stop clean. Both workers return success on the stop event: qrexec-agent sets
    ERROR_SUCCESS, and qubesdb's mainloop takes its stop branch because its pipe thread has no stop path (Jev 0.87).
- **Accepted residuals.**
  - Any guest process can write an Application-log record under our source name. The SYSTEM task then reports a death of a
    table executable: text only from the tables, parsed numbers, at most 8 notifications per boot (Jev: acceptable 0.69).
  - etwproxy's 4004 is written under its lock: a hung Event Log service could stall the agent's shutdown (Jev 0.60 "cannot wedge").
