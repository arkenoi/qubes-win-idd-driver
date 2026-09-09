# QWT-NG 4.3.21

An audit release. The headline is not a feature: it is that a class of defect this project keeps
paying for — *a fix that compiles, passes CI, and reaches no guest* — now has three independent
guards against it, and one long-standing P1 was root-caused and actually shipped.

## Downloads

**Install from `qwt-improved-setup.iso`** (attach it to the Windows qube as a CD), or from
`qubes-windows-tools-ng-*.noarch.rpm` in dom0, which installs that same ISO — byte-identical, checked —
at `/usr/lib/qubes/qubes-windows-tools.iso`, so `qvm-start <vm> --install-windows-tools` works the
way the official Qubes instructions describe.

`qubes-tools-4.3.21.exe` is **not** a standalone installer. It is the small bootstrap that already
lives inside the ISO, the CD entry point equivalent to stock's `qubes-tools-4.2.2.exe`; on its own,
away from the rest of the tree, it cannot install anything. It appears here because
`SHA256SUMS.txt` is the setup tree's own manifest — the file the installer verifies before it will
run — so the tree is published intact rather than pruned. Ignore it unless you know you want it.

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

- **Full acceptance: 6/6 cell-groups clean, 0 failures**, on a package built from this exact
  source — win11-clean 12/0, win10-clean 12/0, win11-upgrade 11/0, win11-clean+win11-reinstall
  22/0, win11-appvm 3/0, win10-appvm 3/0.
- **The installed binary is proven to be the packaged one**, not assumed: every cell recorded
  `installed_gui_agent_sha256 == expected_gui_agent_sha256`. A harness that proceeds on a failed
  install reports results for a build that was never running.
- **Package content is proven, not assumed.** Each fork binary is located *inside the MSI* by a
  build-identity marker a stock binary cannot contain, in both ASCII and UTF-16LE. `ours-wins` proves
  staging at build time; this proves delivery into the installed artifact.
- **Boot-to-qrexec is now measured** on every cold boot (n=22 across two campaigns: 15–38 s).
  A boot that never answers is recorded as `no-qrexec-within-600s` rather than omitted, so a guest
  that fails to come up cannot silently flatter the distribution. Previously the
  harness only recorded "desktop shell up", which is autologon + profile + explorer and says nothing
  about when dom0 can talk to the qube.

## Known open

- **Boot-to-qrexec varies 15–38 s and the cause is unknown.** An earlier reading of this — "~10 s
  slower on non-clean guests, the sets are disjoint" — was retracted while preparing this release:
  it was two samples against four from one campaign, and the fuller set (n=22) overlaps completely.
  A *clean* win11 install produced the slowest standalone number on record (33 s) and a clean win10
  the fastest (15 s); the spread within one unchanged configuration is as large as the difference
  the grouping was supposed to explain. Not a regression against any baseline — no prior
  boot-to-qrexec measurement existed, because the harness used to record only "desktop shell up",
  which is a different quantity. Next step is the noise floor (repeat boots of one guest) before any
  comparison, then attribution via `Diagnostics-Performance` events 100/101–109.
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
