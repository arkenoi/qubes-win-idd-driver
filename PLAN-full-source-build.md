# PLAN — full source build of Qubes Windows Tools with our agent

Status: ready to execute in a fresh session. Written 2026-08-01 after the clean-room
rebuild showed the limits of the overlay approach. Read `FINDINGS.md` (2026-08-01
entries) first; this file assumes that context.

## Why

Today our agent reaches the guest as an **overlay**: `install-qwt-improved.ps1` stops the
watchdog and swaps `bin\gui-agent.exe` inside an existing stock QWT 4.2.2, keeping a
`.orig`. Consequences we actually hit:

- the guest runs **our agent inside someone else's install** — `gui-watchdog.exe` and
  every registry default come from the stock MSI, so a defect can never be cleanly
  attributed;
- the QWT install itself is unverified by us: the missing **PV network driver**
  (`xenvif` stopped, traffic on an emulated RTL8139, guest unusable with a netvm) is a
  packaging problem an overlay cannot fix;
- it is not how a user would ever receive this, so "it works" proves less than it should.

Goal: produce a signed QWT installer containing our agent, install it on a wiped guest
from the unattended payload, and validate with nothing hand-swapped.

## What we already have (the expensive parts are done)

- CI with the WDK/EWDK toolchain, staged Qubes dependencies (`core-vchan-xen`,
  `windows-utils`, `core-qubesdb`, `qubes-gui-common`), and **working test-signing certs**
  (`.github/workflows/build.yml`; see `ci-notes/packaging.md`).
- Our agent fork building green as `qwt-improved` packages.
- An unattended ISO builder (`mgmt/build-unattended-iso.sh`) whose payload already
  installs QWT via `guest/install-qwt.cmd` (`msiexec /i installer.msi /qn ADDLOCAL=…`).
- A reproducible clean-guest recipe (retail Win10 22H2, `losetup` + `--cdrom=…:loopN`).

## Steps

### 1. Inventory the upstream build (half a session)
- Clone `QubesOS/qubes-windows-tools` (the meta-repo) and read its build orchestration:
  which component repos it pulls, how `qubes-gui-agent-windows` is wired in, how the WiX
  bundle (`qubes-tools-<ver>.exe`) and `installer.msi` are produced, and which features
  map to which drivers (this also answers the PV-network `ADDLOCAL` question directly).
- Record in `ci-notes/packaging.md`: component list, required toolchain versions, signing
  inputs, and the exact artifacts we must reproduce.

### 2. Decide the integration point
Two candidates — pick after step 1, prefer (a) if the meta-build allows a submodule
override:
- **(a) Submodule override**: point the meta-repo's gui-agent submodule at
  `arkenoi/qubes-gui-agent-windows@perwindow` and build the whole tools set.
- **(b) Post-build substitution**: build stock QWT, then replace `gui-agent.exe` inside
  the MSI/cab and re-sign. Cheaper, but reintroduces a seam — treat as fallback.

### 3. CI workflow (`.github/workflows/qwt-full.yml`)
- Separate workflow from the current agent build; runs on demand + on `perwindow` pushes.
- Reuse the existing dependency-staging and cert steps verbatim (they are proven).
- Build drivers + services + agent, produce `installer.msi` and the WiX bundle, test-sign
  everything with the throwaway cert the guest already trusts.
- Publish as artifact `qwt-full-package` with a MANIFEST recording component commits.
- Expected friction (budget for it): driver signing attributes, WiX toolset version, the
  Burn bundle needing `vc_redist`, and EWDK acquisition time — cache aggressively.

### 4. Guest install from the unattended payload
- Extend `mgmt/build-unattended-iso.sh` payload staging to take **our** installer instead
  of the stock one (`~/win-iso/qwt-payload/installer.msi`), keeping the hash check.
- Update `guest/install-qwt.cmd` ADDLOCAL to include the PV network feature (from step 1)
  so `xenvif` binds and the guest is usable with a netvm.
- Rebuild the unattended ISO, wipe `win-idd-test`, install. No overlay, no `.orig`.

### 5. End-to-end acceptance on the pristine guest
Run every check VM-scoped (`tools/qtest shot`; `fullshot` shows other qubes and has
already produced two false findings):
1. `xenvif=Running`, PV adapter carries the IP, netvm attached, guest stays responsive.
2. Windows activated (`slmgr /ato`), no watermark.
3. Composite synthesis: Notepad File menu = one dom0 window, menu composited, verify the
   menu is still open at capture time.
4. Work-area sync: maximized window fits the dom0 client area exactly.
5. Edge: first-run overlay renders (ULW/NRB path), popups correct, no daemon disconnects.
6. **MS Office / Word** — the real exam: Backstage, ribbon dropdowns, Styles gallery,
   task panes, tooltips. This is what the whole synthesis design targets.
7. Drag/scroll latency vs the recorded baseline (`instrumentation/`), to confirm no
   regression from the composite paths.

## Known hazards
- **Concurrent sessions**: another session is committing to `agent/perwindow`
  (`SYNTH_OVERHANG_MAX` changed under us mid-edit). Agree branch ownership before
  pinning a commit for the package.
- **Uncommitted fix pending**: periodic full re-copy of synthesized children (200 ms
  tick, `SynthLastFullPatch` on the owner) — menus can composite mid-draw without it.
  Land this before cutting a package.
- `qvm-block` is broken under Python 3.14 (patched locally, upstream
  QubesOS/qubes-issues#11029); media attach goes through `sudo losetup` +
  `qvm-start --cdrom=win-idd-mgmt:loopN`.
- The unattend must match the media language (`en-GB` for the English International ISO).
