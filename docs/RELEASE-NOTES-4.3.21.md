# QWT-NG 4.3.21

An audit release. The headline is not a feature: it is that a class of defect this project keeps
paying for — *a fix that compiles, passes CI, and reaches no guest* — now has three independent
guards against it, and one long-standing P1 was root-caused and actually shipped.

## The qrexec P1: diagnosed, and this time delivered

`findings/install.md` has carried "qrexec can go missing for good after a clean install" with
**THE TRIGGER IS STILL UNIDENTIFIED** for days. It is identified:

- `QdbDaemon` reports RUNNING immediately but can spend up to **five minutes** in `VchanInitClient`
  waiting for xeniface.
- `QrexecAgent` waited **60 s** for qubesdb, gave up, and returned **`ERROR_SUCCESS`**.
- So the SCM saw a clean stop, logged an informational 7036, and **never ran the failure actions** —
  which is why `Set-QubesServiceRecovery`, added on 2026-09-06 for exactly this failure, was inert
  against it. The dependency orders process *start*, not *readiness*, and the waiter's timeout was
  5× shorter than the thing it waits for.

The fix is in `qrexec-agent.c`, and for the first time that binary **ships from the fork**.
Previously `qrexec-agent.exe` was built and then withheld by recorded policy, so the fix would have
reached no guest at all.

## Undefined states removed

Every item here is a transient that was reported as a permanent defect, a permanent failure
reported as nothing, or a recovery that happened silently.

- **Broker lifecycle.** "Eligible but not ready yet" had no defined meaning: a normal toast arriving
  during agent startup was classified as a *display fault*, incremented a defect counter, logged
  `THIS IS A BUG TO FIX`, and spawned a helper into a session that was itself still coming up.
  There are now four defined states, and the young ones are bounded from both entries so they always
  resolve to READY or DOWN.
- **Broker death was invisible — and self-concealing.** A relaunch reset only the agent's *local*
  heartbeat copy while the dead broker's last heartbeat sat in shared memory, non-zero, for ever. The
  next pass compared stale-non-zero against zero, read it as "the heartbeat advanced", and
  re-certified a corpse as alive — every 8 seconds, indefinitely. The recovery machinery was
  suppressing the failure detection it exists to support.
- **Broker failures are now loud**: death, recovery (with downtime), failed launch, and a missing
  `wgcbroker.exe` named immediately rather than 30 s later.
- **A withheld window that dies unpainted is reported.** A toast auto-dismisses in about six seconds;
  without this, a dead broker silently swallowed every toast.
- **The agent no longer runs during its own installation.** The MSI starts the watchdog, so the agent
  and its capture broker were live while stage 2 still had to install xenvif/xencons, create the IDD
  device and disable the adapter the desktop was running on.

## Install

- **The autologon password no longer rides on a command line.** It moves through an environment
  channel scrubbed before any child can inherit it, and the UAC relaunch refuses with a named cause
  rather than re-quoting the secret into an elevated argv.
- **Install reboots are ~30 s shorter.** The resume task's blanket 60 s delay is gone now that PnP
  settle and Windows Installer idle are waited on *by name*.
- **The feature manifest is generated** from the installer's own table instead of a hand-typed list
  that already contradicted README and MANIFEST.
- `relocate-dir` and `advertise-tools` now build and ship. `relocate-dir` was excluded from the build
  for want of the WDK — a gap in one workflow file, recorded as though it were a property of the
  source. The BootExecute step that moves `C:\Users` onto the private volume could not receive a fix
  at all.

## Verification

- **Full acceptance: 6/6 cell-groups clean** — win11-clean, win10-clean, win11-upgrade,
  win11-clean+win11-reinstall, win11-appvm, win10-appvm.
- **Package content is proven, not assumed.** Each fork binary is located *inside the MSI* by a
  build-identity marker a stock binary cannot contain, in both ASCII and UTF-16LE. `ours-wins` proves
  staging at build time; this proves delivery into the installed artifact.
- **Boot-to-qrexec is now measured** on every cold boot (n=10: 20–38 s, median ~28 s). Previously the
  harness only recorded "desktop shell up", which is autologon + profile + explorer and says nothing
  about when dom0 can talk to the qube.

## Known open

- **Boot-to-qrexec is ~10 s slower on non-clean guests** (clean 20 s vs upgrade/AppVM 28–38 s,
  disjoint). Not a regression against any baseline — no prior measurement existed. Tracked in
  `findings/issues.md` with the instrument named (`Diagnostics-Performance` events 100/101–109).
- Two audit findings live in `upstream/ro/**`, a read-only reference checkout with no tracked files,
  and cannot be fixed here. One of them explains why service recovery actions are inert: the shared
  service harness reports `SERVICE_STOPPED / NO_ERROR` when a worker fails. The reachable half is
  fixed in `core-agent`.
- **Two stale lines in the ISO's `README.txt`.** The body still says an already-installed QWT is
  removed first and that the removal can cost an extra reboot. That has not been true since the
  4.3.0 version bump: an older or equal QWT is an in-place MajorUpgrade (or a same-version repair),
  and removal happens only on a genuine downgrade. The **header** — the line carrying the 0x7B
  hazard, and the one a user reads before touching an existing install — is correct in this
  package. The body lines are fixed in the tree and will ship in the next package; they were not
  worth invalidating an acceptance run for.
- **Watchdog lifetime fixes are not in this release.** Token handle leaks, an unbounded `ServiceMain`
  join and PRESHUTDOWN reporting STOPPED with the respawn loop still live are fixed on the branch
  `watchdog-lifetime-4322` (agent `550e1da`). Agent commit `a195692`'s message describes all three;
  `git show --stat` says it touched `gui-agent/main.c` only, so they were never staged and sat
  uncommitted while this package was built, verified and put through acceptance. Caught by reading
  `git status` before the release commit, not by any guard. They land next, after CI compiles the
  file for the first time and a cold shutdown is re-checked for Event 7043 — the PRESHUTDOWN change
  reverses b51a09f, which was rig-verified against exactly that event.
- `health-check` now hard-fails a guest whose `QdbDaemon`/`QrexecAgent` lack the armed recovery
  configuration. On a guest installed from a package older than 2026-09-06 and never upgraded, that
  is the intended finding, not noise.
