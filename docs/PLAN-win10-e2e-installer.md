# Win10 e2e — installer-based, no hot-swap, no UAC changes

Decision (user, 2026-08-12): Win10 is needed **only for e2e release testing**, and it is done by
**installing QWT the real way**, not by hot-swapping the agent binary. So:

- **No hot-swaps on Win10.** `swap-agent.ps1` / `run-elevated.ps1` / credentialed-task tricks are
  NOT used here. Those exist only for the Win11 rapid dev loop.
- **UAC stays ON.** The QWT payload installs during firstboot, which already runs elevated, so
  there is no filtered-token problem. `mgmt/autounattend.xml` deliberately does NOT set
  `EnableLUA=0` (the brief experiment that added it is reverted). This ends the UAC saga for Win10.
- **Coverage:** less thorough than Win11 (which hot-swaps and measures per-change), but sufficient
  — it validates that a clean install of the shipped package renders Start/toasts correctly.

## The package under test already contains the fix

CI job `package` (artifact `qwt-improved-package`) assembles the full QWT installer from the SAME
`gui-agent-package` artifact, so the release package built on a green run bundles whatever agent
that run built. Latest: run 31577559536 (push dc89104) → agent `1a2c9d58` (draggable-not-resizeable
shell surfaces + all the 2026-08-12 fixes). Any provision using this package tests the real thing.

## Procedure (runs from the `win-idd-mgmt` qube — it holds admin.vm.Create + cdrom export;
## the `win-idd-driver` dev qube does NOT and cannot do this, verified 2026-08-12: admin.vm.volume
## and Create refused)

1. Download the release package: `gh run download 31577559536 -n qwt-improved-package` → contains
   the installer/MSI/setup + the patched agent.
2. Pristine Win10 base: clone a clean Win10 22H2 VM (or build one from the vendor ISO in
   `~/win-iso/Win10_22H2_*.iso` via `mgmt/build-unattended-iso.sh` with the corrected
   `autounattend.xml` — UAC on, autologon, payload runs the QWT installer at firstboot).
3. Point the payload at the improved package (not stock QWT) so firstboot installs the patched
   build. Provision per `mgmt/CLAUDE.md` sequence (create VM → --cdrom install → monitor ~45 min).
4. After the desktop is up and qrexec answers, run the READ-ONLY validation (works fine from a
   filtered token — no elevation needed):
   - `guest/defect-evidence.ps1` — agent running, hash matches the packaged agent.
   - `guest/open-start.ps1` + `guest/fire-toast.ps1` + `tools/qtest fullshot` — Start/toast
     announce cropped, card-sized, `override_redirect=0`, size-locked.
   - `guest/drag-measure.ps1` + `guest/reset-census.ps1` — drag dt reasonable, zero cap_timeouts.
   - User (or a scripted SendInput drag) confirms the interactive drag/resize behavior, same as
     the Win11 acceptance.

## Obsolete (do not use for Win10)

`scratchpad/win10-complete.sh`, `guest/win10-elev-deploy.ps1`, `guest/elev-cred-probe.ps1` —
the hot-swap-via-elevation approach. Kept in git history only; superseded by the above.
