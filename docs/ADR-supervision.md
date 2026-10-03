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
