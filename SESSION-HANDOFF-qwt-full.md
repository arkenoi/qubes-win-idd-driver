# HANDOFF — full source build of QWT (session 6, 2026-08-01 ~22:30)

Pick up here. Read this, then `FINDINGS.md` 2026-08-01 entries (esp. session 6) and
`ci-notes/qwt-full-build.md`. `PLAN-full-source-build.md` steps 1–3 are DONE; step 4 is
running; step 5 is the remaining work.

## What is done (all committed and pushed)

1. **Lost synthesis fix re-implemented** — agent `382fa05` on `perwindow`: 200 ms
   `SynthLastFullPatch` tick re-copies synthesized children's FULL rects in
   `ProcessNewFrame`, so a menu captured mid-draw self-heals. Submodule bumped on `main`.
2. **Upstream inventory** (plan step 1) — `ci-notes/qwt-full-build.md`. Key corrections:
   there is NO `qubes-windows-tools` meta-repo (404) and NO gui-agent submodule; QWT 4.2.2
   is qubes-builderv2 + `qubes-installer-qubes-os-windows-tools` (WiX v4.0.5, tag
   v4.2.2-1 = `14c189e`). Clones under `upstream/ro/`.
3. **PV-network diagnosis CORRECTED** — never a packaging gap. `ADDLOCAL` always included
   `PvDriversNetwork` and it staged fine (DifX). `xenvif` binds only once a netvm-provided
   VIF is enumerated, and unplugging the emulated RTL8139 is a **two-boot dance**
   (`Services\XEN\Unplug` armed on first PV start → reboot → `xen.sys` unplugs; vetoed
   until a VIF appeared once). Remedy is operational: attach netvm, reboot twice.
4. **Integration decision** (step 2) — rebuild the genuine `installer.msi` + Burn bundle
   from pinned upstream WiX sources in CI, staging `QUBES_REPO` with OUR signed agent and
   everything else bit-identical from the vendored, GPG-verified stock MSI
   (`vendor/qwt-4.2.2/`, ITL signatures kept). Full builderv2 needs Windows-worker/EWDK
   infra we lack; cab-patching is unnecessary.
5. **`.github/workflows/qwt-full.yml`** (step 3) — GREEN first run (`30709868361`, ~2.5 min).
   Artifact `qwt-full-package` → local copy `artifacts/qwt-full/`:
   - `installer.msi` sha256 `ff89da3c6077bb8fb9b7ff2a9c84249c2d03daed4fbced3009dc4a0198364316`
   - `gui-agent.exe` sha256 `654de8ebde3713daccd743c6bfa2a8cbba9b083836174b59d15ff8960599a386`
   - `gui-watchdog.exe` `d6196059fd3564f948a1e33cb5fa790b1367c857e5bb2d571c7ec0db7ea279cd`
   - `MANIFEST.json` pins agent `382fa05`, installer `14c189e`, stock MSI hash.
   Verified locally: the MSI's embedded cab carries those exact bytes, and our
   guest-trusted cert is embedded in both signed exes.
   Helper: `packaging/stage-qwt-repo.ps1` (parses the .wxs `QUBES_REPO` refs, stages from
   the `msiexec /a` admin image, fails loudly on missing/ambiguous/identical-to-stock).
   **USER DIRECTIVE: build remotely on GitHub whenever possible** — never locally.

## IN FLIGHT (step 4): clean reinstall of win-idd-test with OUR MSI

ISO `~/win-iso/win-idd-unattended.iso` rebuilt with `QWT_MSI=`/`QWT_MSI_SHA256=` staging
our installer (hash checked at stage time AND re-checked in-guest by `install-qwt.cmd`
before msiexec). Loop-attached as `/dev/loop1`; install running, two phase boundaries
passed as of 22:30. Watcher: `mgmt/win-install-watch.sh win-idd-test <dir>` (monitor task
in the old session; **re-arm it in the new session** — it restarts the qube at each Setup
reboot and reports console-phase changes / stalls / QREXEC UP).
Expected remaining chain: OOBE → first logon stage 1 (cert + testsigning + reboot) →
stage 2 (`msiexec` our MSI, `ADDLOCAL=PvDriversCore,Core,Gui,PvDriversNetwork`) → reboot →
qrexec answers.

## Hard-won operational rules (session 6 — do NOT relearn these)

- **Reinstalling over an existing Windows qube: clear guest-advertised features first.**
  `gui=1`/`qrexec=1` are set by QWT and SURVIVE a disk wipe (qube metadata, not disk). With
  `gui=1` dom0 never attaches the emulated console → the whole install runs blind. Do:
  `qvm-features --unset <vm> qrexec`; `qvm-features <vm> gui ''`;
  `qvm-features <vm> gui-emulated 1`. This was the root cause of a long blackbox episode.
- **Console geometry is a progress signal**: 720x400 = BIOS/CD load (black, ~0 cpu, can
  last minutes — NOT a hang), 1024x768 = Setup GUI.
- **Remove `boot/bootfix.bin`** from repacked media (done in `build-unattended-iso.sh`):
  otherwise the "press any key to boot from CD" prompt times out and the OLD disk install
  boots. Tell: qrexec ANSWERS during what should be Setup.
- `qvm-ls` shows **Transient** for the whole install (state flips to Running only when the
  qrexec handshake lands); read cputime deltas, not the state label.
- No `qvm-remove`/`sudo` in this session: wipe via the unattend `WillWipeDisk`; attach ISOs
  with `udisksctl loop-setup --read-only --file <iso>` (no sudo) and re-check
  `/sys/block/loopN/size` after any ISO rebuild. If `qvm-start --cdrom` says "already
  assigned", unassign via `admin.vm.device.block.Unassign+win-idd-mgmt+loop1`.
- Guest reboots destroy the Qubes domain — something must restart the qube at each phase.

## NEXT (step 5 acceptance, on the pristine guest)

1. `C:\qubes-win-idd-setup.log` + `C:\qwt-install.log` — both stages OK, `QWT_INSTALL_OK`.
2. **Decisive**: `certutil -hashfile "C:\Program Files\Qubes Tools\bin\gui-agent.exe"
   SHA256` == `654de8eb…` → OUR source-built QWT installed, no overlay, no `.orig`.
3. `bcdedit | findstr testsigning`; `Get-Service` Qubes* running; record the
   `QubesIncoming` path; clean `shutdown`/`start` survival (boot path matters).
4. Display checks VM-scoped (`tools/qtest shot`; fullshot only for dom0 geometry):
   Notepad File menu composited into ONE window **with the menu still open at capture
   time**, maximized window fits the dom0 client area, Edge first-run ULW/NRB, no daemon
   disconnects, drag/scroll vs the `instrumentation/` baseline.
5. **PING THE USER for the netvm** (they attach it; this qube cannot). Then reboot TWICE
   and verify `xenvif=Running` + a `Xen PV Network Class` adapter carrying the IP instead
   of the Realtek. Then activation (`slmgr /ato`) and the MS Office/Word render test — the
   real exam for composite synthesis.

## Open items carried over

- Synthesis flap during drags; `WorkAreaCreateListener 0x5`; `GetRealWindowRect 0x80070006`
  bursts; Win10 regression pass for the five win11-line fixes.
- Upstream PR still gated on explicit user approval of the exact diff.
