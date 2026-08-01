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

## Starvation/respawn defect — diagnosed; candidate fix REJECTED by review

Symptom (measured): with the qube's `gui` feature absent, dom0 runs no gui-daemon, the guest
burns ~2.8/4 vCPUs indefinitely and qrexec stops answering until the VM is killed. Setting
`gui 1` + reboot restores everything (qrexec in 60 s).

Diagnosis (3 independent source lenses, workflow `wf_c984e960-ae2`):
- The agent's connect/wait path is **NOT** a busy-poll — every pre-connection wait is a
  blocking INFINITE wait and the DDA capture thread is only created on the connect edge.
- The real mechanism is a **respawn loop**: the agent hard-fails/exits when it cannot resolve
  the GUI domain id, and `QgaWatchdog` relaunches it **once per second**, unconditionally.
  Each start does real work (grants, enumeration), so the cost is sustained and multi-core.
- Upstream Linux handles this by NOT RUNNING the agent at all when there is no daemon
  (a systemd condition); the Windows port never implemented that gate — so daemon-absent is
  unhandled in upstream QWT *and* in our fork, at different layers.
- Operator discriminator (from lens B): the logger creates a NEW log file per process start,
  so a census of `gui-agent-*.log` files distinguishes "one process spinning" from
  "respawn loop" with no live process needed.

**Candidate fix `53056d5` on branch `spin-backoff` (agent submodule) — DO NOT MERGE.**
Three adversarial reviewers returned BROKEN / NEEDS_WORK. Blockers found:
1. The new idle wait in `wincapture.cpp:264-266` removes the capture thread's only
   unconditional throttle: a `WcShutdown` join timeout turns it into a 100%-core busy loop
   on a closed handle/freed memory — strictly worse than the bug being fixed.
2. The `/qubes-gui-enabled` park (`main.c:3701-3709`) permanently removes the vchan SERVER,
   and the gui-daemon connects exactly ONCE with no retry → one misread qubesdb key yields an
   unrecoverable no-GUI qube. It is also decided once at startup, never re-checked, and a
   parked process still satisfies `IsProcessRunning`, so the watchdog can never heal it.
3. The watchdog backoff counts launches that never happened (`StartTargetProcess` returns
   ERROR_SUCCESS without launching when there is no active console session), so backoff
   inflates on ordinary session transitions.
4. Neither new gate is shown to engage in the MEASURED scenario — the exit path we have
   evidence for is untouched, so the patch's effect on the 2.8-core burn may be zero.
Next attempt should target the evidenced exit path, keep the vchan server always listening,
add backoff in the WATCHDOG keyed on actual launches, and must not touch the capture-thread
throttle. Full verdicts: workflow journal `wf_c984e960-ae2`.

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

## STEP 4 — NOT ACCEPTED. The resulting QWT is NON-FUNCTIONAL for networked use.

**Read this before the green table below.** The build installs, renders, and passes every
display check — and it is still NOT a usable Qubes Windows Tools install, because attaching
a netvm makes the guest unusable (see BLOCKER). A Windows qube that cannot have a netvm is
not a working qube. Do not report step 4 as done, do not deploy this to any real qube, and
do not open any upstream PR on the strength of the table below. The correct status is:
**installs and renders correctly; networking broken; cause not yet attributed to us or
upstream.** (Corrected 2026-08-01 after the author initially wrote "STEP 4 COMPLETE /
acceptance results" — that framing declared success on the checks that happened to pass and
is exactly the pattern CLAUDE.md forbids.)

### What DOES pass (display/install only — measured 2026-08-01 22:45–23:20)

| check | result |
|---|---|
| `gui-agent.exe` sha256 | `654de8eb…` = CI MANIFEST, size 126712 — **OUR build** |
| `gui-watchdog.exe` sha256 | `d6196059…` = CI MANIFEST |
| `.orig` backups in bin\ | **0** — installed by MSI, never overlaid |
| stage 2 log | `installer.msi sha256 OK: ff89da3c…`, `QWT_INSTALL_OK rc=3010` |
| ARP entry | `Qubes Windows Tools v4.2.2.0` (real MSI product) |
| testsigning | Yes; OS = Win10 Pro 19045 (retail) |
| services | QdbDaemon / QrexecAgent / QubesGuiWatchdog / xenagent / xenbus_monitor Running |
| cold boot | survived twice; qrexec in ~60 s |
| seamless | Notepad = own dom0 window 2566x1022, desktop window separate |
| **menu synthesis** | **PASS on Win10, evidenced twice**: dom0 list has NO menu window, PNG shows the File dropdown painted inside Notepad; guest log 4x `msg=SYNTH`, 24x `SYNTHPAINT`, **0 skips**, 0 vchan errors. Repeat paints of the same rect ~3 min after menu open = the new 200 ms tick (`382fa05`) working. |

Not yet run: work-area/maximize check, Edge ULW first-run, drag/scroll vs baseline,
Win10 regression pass for the five win11-line fixes (XAML-specific paths can only be
validated on win11-idd-test).

## BLOCKER — netvm attach still starves the guest (NOT fixed, NOT ours-vs-stock proven)

Measured this session on the from-source install:
- netvm `fw-net` attached **while halted** (so no live session was frozen), then booted:
  boot 1 ran >7 min, no qrexec, **~1.95 cores burned**; forced reboot with netvm still
  attached; boot 2 identical — no unplug, no qrexec. Detaching netvm → CPU drops to
  ~0.05 cores immediately.
- So the predicted "two-boot dance" (arm `Services\XEN\Unplug`, reboot, `xen.sys` unplugs
  the emulated NIC) did **not** complete. xenvif/xennet remain absent as services.
- **RETRACTED**: my earlier "guest bugchecks on attach" hypothesis. The user confirmed the
  guest does not crash — it freezes and recovers the instant the netvm is removed.
- **Also weak and explicitly rejected by the user**: the argument "our PV drivers are
  byte-identical to stock, therefore stock behaves the same". Byte identity is not
  behavioural proof. **This must be settled by experiment (see plan below).**
- User's point, correct and load-bearing: **stock QWT supported netvm hotplug**. A working
  PV stack does not require any of this. So the real defect is "xenvif never binds", and
  10–20 min of frozen guest is a FAILED user experience, not a procedure to accept.

### EVIDENCE GATHERED (healthy boot, netvm detached, 23:35) — narrows it sharply
| probe | result | meaning |
|---|---|---|
| `Enum\XENBUS` children | `DEV_CONS`, `DEV_IFACE`, `DEV_VBD`, **`DEV_VIF`** | the VIF PDO **was** enumerated |
| `Get-PnpDevice` VIF | `Xen PV Network Class` = **Unknown** | driver present, device never started |
| `setupapi.dev.log` 22:51:34 | selects `xenvif.inf` (oem4), `Created new service 'xenvif'`, hardlinks `xenvif.sys`, then `Start:` | **install SUCCEEDED** — publisher-trust/driver-store cause is ELIMINATED |
| `xenvif` service | Stopped, Start=3 (demand) | started on demand only, never came up |
| `Services\XEN\Unplug` | **no NICS value** | unplug never armed, or armed and lost |
| `xennet.sys` / service | ABSENT (but `xennet.inf` IS in driver store, oem5) | correctly blocked behind xenvif — xennet binds a child of a STARTED xenvif |
| System log | `Kernel-Power id=41` (unclean shutdowns) | **self-inflicted, see below** |

**Procedural error to correct first (mine):** between the two attached boots I used
`qtest kill` = domain DESTROY, not a graceful shutdown. Upstream's flow is: xenvif's
PdoStartDevice arms `Services\XEN\Unplug\NICS`, calls DriverRequestReboot and fails the
start with STATUS_PNP_REBOOT_REQUIRED; the NEXT clean boot lets `xen.sys` consume the value
and unplug the emulated NIC. A hard destroy can lose that registry write before it is
flushed, so every attempt restarted from zero. **The two-boot dance has NOT had a fair
test.** Redo with `qtest shutdown` (ACPI, Windows flushes) or an in-guest
`shutdown /r` — never `kill` — even though the starved guest is slow to respond to ACPI.

### Evidence still to gather (script is written and ready)
`scratchpad/netforensics.ps1` (recreate from this doc if the scratchpad is gone) collects,
from a HEALTHY boot with the netvm DETACHED — i.e. no starvation, qrexec works:
`Enum\XENBUS` children (did a VIF PDO ever appear?), `Services\XEN\Unplug` values (was the
unplug ever armed?), xenvif/xennet service+Start values, `pnputil /enum-drivers` (is the
package in the driver store?), `Get-PnpDevice` status/problem codes, `setupapi.dev.log`
lines for xenvif/xennet/`XENBUS\VEN`, driver-file hashes, and System event errors.
This discriminates: (a) VIF never enumerated, (b) enumerated but driver install failed
(trust/driver-store), (c) installed but never started/armed, (d) armed but unplug vetoed.

### MANDATORY next experiment — stock-QWT control (user-directed)
Prove behaviour, don't argue from byte identity. On a wiped guest install **stock QWT
4.2.2** (`vendor/qwt-4.2.2/installer.msi`, sha256 `70493221…`) via the same unattended ISO
with `QWT_MSI` unset, then attach `fw-net` the same way and measure the same numbers
(time to qrexec, cores burned, xenvif state after two boots).
- If stock ALSO starves → the defect is upstream/environmental (PV drivers vs this Xen /
  Qubes 4.3 combination), we are cleared, and it is an upstream issue worth filing.
- If stock works → the defect IS ours, and the prime suspect is the agent's CPU cost under
  emulated-NIC load (our per-window PrintWindow capture is far heavier than stock's
  full-desktop path), plus the watchdog respawn loop found this session.
Keep the two installs comparable: same ISO, same ADDLOCAL, same vCPU/memory, netvm attached
while halted, two boots each, and record cputime deltas — not impressions.

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
