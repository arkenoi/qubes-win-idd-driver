# QWT-NG 4.3

Qubes Windows Tools, next generation — for Qubes OS 4.3.

A reworked GUI agent, a Xen PV network driver that actually binds, and an IddCx display
driver that becomes the guest's real display. Validated on clean end-to-end installs of
Windows 10 22H2 and Windows 11 24H2.

### On the name and version

Upstream Qubes Windows Tools has **no 4.3-versioned build**. Verified against
`QubesOS/qubes-installer-qubes-os-windows-tools`: the highest tag is `v4.2.2-1`, there are no
published GitHub releases, and `qubes-gui-agent-windows` likewise tops out at `v4.2.2`.
`qvm-create-windows-qube` says the same thing independently — on 4.3 it refuses to proceed
with *"Qubes OS does not currently offer an official build of Qubes Windows Tools for 4.3"*.

Anywhere this README says "stock", it means unmodified upstream QWT 4.2.2 as shipped for Qubes.

---

## Download

Release **[v4.3.9-agent33f3109](https://github.com/arkenoi/qubes-win-idd-driver/releases/tag/v4.3.9-agent33f3109)** — agent `33f3109`, package `4.3.9+agent.33f31091ef2d`.

| file | use it for |
|---|---|
| [`qubes-windows-tools-ng-4.3.9-1.agent33f31091ef2d.noarch.rpm`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.9-agent33f3109/qubes-windows-tools-ng-4.3.9-1.agent33f31091ef2d.noarch.rpm) | **dom0** — installs the ISO at `/usr/lib/qubes/qubes-windows-tools.iso`, auto-patches `qvm-create-windows-qube` to use it, and installs `qvm-windows-update` and `qwt-ng-prepare-qube` |
| [`qwt-ng-4.3.9-agent33f3109.iso`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.9-agent33f3109/qwt-ng-4.3.9-agent33f3109.iso) | attach to a running Windows qube as a CD and run `install.cmd` elevated |
| [`qwt-ng-4.3.9-agent33f3109-setup.tar.gz`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.9-agent33f3109/qwt-ng-4.3.9-agent33f3109-setup.tar.gz) | the same installer tree, if you would rather copy files in than mount a CD |
| [`SHA256SUMS.txt`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.9-agent33f3109/SHA256SUMS.txt) | checksums for all three |

The dom0 RPM is unsigned, so `qubes-dom0-update` will refuse it; install it directly:

```
sudo rpm -i qubes-windows-tools-ng-4.3.9-1.agent33f31091ef2d.noarch.rpm
```

Upgrading a guest that already runs stock QWT or an older build of this package is a
plain in-place upgrade — run the installer, it detects the older version and lets the
MSI replace it in one transaction (validated end to end; see the release notes).

**Hand-created qube?** Run `qvm-features <qube> vmexec 1` and `qvm-prefs <qube> qrexec_timeout 1800`
in dom0 (on the template; AppVMs inherit), or the Qubes Update tool fails against it.

**What changed in 4.3.9:** the withdrawn 4.3.8's regression is fixed, mechanism confirmed: the
build stamped the INF version with the *build time*, and a display driver version's first field
is — per Microsoft's spec — a WDDM model declaration. Versions ≥ 21 declare WDDM 2.1+, which
this IddCx driver isn't, and Windows punishes the over-claim (measured: a perfect works/breaks
step at exactly 21 across 14 code-identical packages). Evening builds broke; the version is now
pinned to 4.3.x.y. Carried over from
4.3.8: the black-fullscreen-window fix (field confirmation wanted), reliable updater-relay
deploys, and a window-filter diagnostic switch. Full story in the
[release notes](https://github.com/arkenoi/qubes-win-idd-driver/releases/tag/v4.3.9-agent33f3109).

**Provenance.** Every asset above is built by GitHub Actions from this repository at the tagged
commit; the agent is `33f3109` on
[arkenoi/qubes-gui-agent-windows](https://github.com/arkenoi/qubes-gui-agent-windows). The
Windows build is not timestamp-reproducible, so binary hashes differ across rebuilds of identical
source; `MANIFEST.json` inside each asset records the exact source commits the build came from.

---
## Read this first

**The binaries are TEST-SIGNED.** The installer runs `bcdedit /set testsigning on`, which
weakens driver-signature enforcement for the whole guest until you turn it off. Stock QWT
ships production-signed binaries and does not do this. It is inherent to an unofficial build,
not a defect — but it is a real change to your guest's security posture, so decide about it
deliberately.

**If you install onto an existing qube, check the private volume size first.** Windows Tools
has always placed user data on `Q:\Users` on the private image — that is stock behaviour, not
a change here. But the Qubes default private volume is 2 GiB and a bare Windows profile
already uses ~550 MB, so it is worth extending before it fills:

```
qvm-volume extend <vm>:private 40GiB
```

---

## What you will actually notice

### Dragging a window stops tearing itself apart

On stock QWT, dragging a window in seamless mode leaves visible artifacts — smeared or
stale regions that persist until something forces a repaint. It is **worse on Windows 11**
than on Windows 10. Stock also shows a **z-order dependency**: whether a window repaints
correctly during a drag depends on where it sits in the stacking order, so the same drag
looks fine on a top window and broken on one underneath.

This build's per-window capture removes that artifact class structurally, and each item
was verified against the stock baseline on the same guest (evidence in `FINDINGS.md`):

- **No overlap corruption / occlusion bleed** — every window has its own buffer, so an
  overlapped window renders complete instead of showing debris from whatever covered it.
  Stock's z-order dependency disappears with it.
- **No tearing** — content is byte-fed per window, never sliced out of a half-updated
  composited frame.
- **No wobble** — window content no longer drifts against the frame during a drag
  (scripted 10 s drag: 2 of 219 damage events with any origin drift, max 5 px).
- **No stray border rectangles or double titles** on compound windows (see the Office
  item below).

### Lower CPU cost than stock — measured

The agent costs less CPU than stock on typing (~20 % below), drag (~30 %) and scroll
(~20 %), and its working set stays flat where stock's grows ~87 MB per workload. Numbers
and caveats: "Performance" below.

### One mouse cursor instead of two

Stock Windows Tools shows a doubled mouse cursor — dom0 draws its own pointer over the guest
window while the guest also paints one into the captured frame, in every mode. This build
blanks the guest-side cursor so only dom0's is visible.

### No black flash while Windows boots, shuts down or switches sessions

Windows renders its login, lock, "shutting down" and initial-desktop screens through a single
full-screen `LogonUI` window. Mapping it produced a black or blue frame that took over the qube's
window at every boot and shutdown. It is now denied outright — and permanently: the Windows
**secure desktop is never presented to dom0**, which is a deliberate security decision, not a
cosmetic one. A guest that reaches a *visible* Windows login screen is a misconfiguration to fix
(autologon), not something this build will render for you.

### The Start menu works again

Earlier builds blocked the Windows key in seamless mode. In seamless the taskbar window is never
mapped, so that key is the only way into any Start menu — including third-party shells. The block
is now **opt-in**; nothing to do unless you want it back.

### A qube built from a Windows template boots the first time

Attaching a netvm to a Windows guest used to make its first boot install the PV network drivers and
then reboot itself. Where the root volume persists that is one surprising restart with a black
window for ~30 s; where the root volume is a **discarded CoW overlay — every app qube** — the same
work is redone on every boot, so the qube never finishes starting. Priming now happens once, in the
template, with no network attached at any point. App qubes built from a primed template reach a
logged-in desktop with a netvm attached and no restarts.

### Office windows render as one window

Post-2013 Office surrounds its frame with layered, click-through shadow HWNDs. The agent
used to map each as a separate window, so dom0 drew a border around every fragment. Measured
on real Office in seamless mode: **8 visible Word windows in the guest, 4 in dom0** — the
three real document frames plus a genuine dialog. All four shadow strips dropped, no real
window lost.

### Windows updates work from the Qubes Update GUI, like any other qube

The qube reports available updates through `qubes.NotifyUpdates`, so it appears in the Qubes
Update tool with the same "updates available" marker as a Fedora or Debian template, and
updating it is the same click. No separate command, and no networking for the guest: update
traffic goes over `qubes.UpdatesProxy`, and the proxy is raised only for the duration of a
pass. Windows' own automatic updates are turned **off** — dom0 decides when the qube updates,
exactly as it does for Linux qubes.

This needed work on our side because dom0's updater does not call an agent in the guest, it
*injects* a Python one per run — which is why every Linux qube is updatable with nothing
preinstalled, and why Windows never could be. The guest now answers dom0's own command
sequence and runs the Windows updater where dom0 expects its injected agent. Details, the
replay harness and every measurement behind it are in `FINDINGS.md`.

Two things to know. **Two settings live in dom0** and cannot come from the guest — the dom0
package applies them on install, and `qwt-ng-prepare-qube <qube>` applies them to a qube created
later: the `vmexec` feature (or dom0's update commands arrive as shell text at `cmd.exe` and the
run aborts) and a raised `qrexec_timeout` (a Windows boot *applying* an update took 259 s to
answer qrexec, against a 60 s default). And **the qube shuts down after installing an update** —
that is not a failure: Qubes destroys a domain on a guest-initiated reboot, and Windows finishes
the update during its next boot, which happens by itself the next time the qube is started or
updated. For a template, that boot is exactly what commits the update to the template root.

### Networking runs over the PV path

Stock QWT 4.2.2 silently falls back to an emulated Realtek NIC (see below). This build binds
the Xen PV network device properly and the emulated NIC is unplugged.

### Attaching a netvm no longer needs a reboot

QWT applies the qubesdb-driven static IP only at boot, so attaching a netvm to a running
guest left it on an APIPA address. A SYSTEM task triggered by "network connected" re-runs the
network setup when an interface arrives. Verified: detach then attach restored the address by
itself in 15 s.

### Upgrading from an earlier build of this package?

Three defects that earlier builds of *this package* introduced — PV disk drivers dropped, a
double cursor, and user profiles left on the root volume — are fixed. Stock QWT never had
any of them, so they are not improvements over stock and are not listed here as such; see
"Three regressions this package had introduced against stock" below.

### A real display driver, which stock does not have at all

Stock Windows Tools ships **no display driver**. The guest runs on the emulated Basic Display
Adapter, whose mode list is fixed — so an arbitrary size like 2566x1022 is simply never
offered, and matching the guest resolution to a dom0 window is unreachable by construction.

This package installs and **activates the Qubes IddCx display driver by default** — an IddCx
monitor becomes the guest's **sole active output** and the emulated VGA is disabled, so the
guest resolution follows the dom0 window with no fixed-mode snapping. (If activation ever
fails the install still completes so the guest is usable, and the failure is flagged loudly in
the install log for retry.)

It can be turned off. Arbitrary resolutions are the only thing that depends on it, so a guest
on the Basic Display Adapter is a reduced configuration, not a broken one — and on hardware or
a Windows build where the IDD misbehaves, being able to say so beats a guest with no display:

- `install.cmd /noidd` — fresh install, never activate it;
- `install.cmd /iddoff` — a guest that already has it: back to the Basic Display Adapter and
  reboot. This is also the **recovery** path when a guest comes up with a black, unresponsive
  window, and it works over qrexec with no usable display in the guest;
- `install.cmd /iddonly` — (re)activate it later.

Two things are worth knowing about how it behaves, because they are not obvious:

- An IddCx monitor arrives **connected but INACTIVE**. It is not attached to the desktop
  until something performs a display-topology apply naming its path. The agent does this at
  startup, in the interactive session — the installer cannot, because its boot-resume task
  runs as SYSTEM in session 0 where the apply returns `ERROR_ACCESS_DENIED`. (Windows 11
  happens to perform an apply on its own; Windows 10 does not. The driver itself has no
  OS-build branch. An earlier build of this package shipped without that apply, so `/idd`
  worked on 11 and silently did nothing on 10.)
- Every other display is **detached**, not merely deprioritised. An additional active display
  enlarges the desktop bounding box the agent maps as the screen, which lets Windows place
  windows in a region dom0 never sees and breaks seamless coordinates.

---

## Upstream defect: PV networking could never bind

This is the one genuine defect in stock Windows Tools that this build fixes. Everything else
below is either a capability stock does not have at all, or a regression this package had
introduced against stock and has since corrected.

QWT 4.2.2 ships a Xen PV network stack that **cannot bind**. Its `xenvif` publishes VIF
interface revision `0x09000004` at most, while its own `xennet` requires `0x09000005`. No
hardware ID intersects, the `XENVIF\…&DEV_NET` child sits at code 28
(`CM_PROB_FAILED_INSTALL`), and Windows silently falls back to the QEMU-emulated Realtek NIC.
Networking *works*, which is why it went unnoticed — but never over the PV path.

Upstream `xennet` raised its requirement in July 2024; upstream `xenvif` only gained revision
5 in June 2025. The pin Qubes carries sits in that eleven-month window, identically on `main`,
`release4.3` and `v4.2.0-1`. This build ships `xenvif` built from xenbits master.

```
before:  Realtek RTL8139C+ Fast Ethernet NIC   (emulated)
after:   Xen PV Network Device #0              (emulated NIC UNPLUGGED)
         10.137.0.70 -> gateway reachable
```

---

## Performance

gui-agent CPU, % of one core (agent `09b643e`, 2026-08-10; stock = hash-verified
reference, same guest and harness):

| workload | stock 4.2.2 | this build |
|---|---:|---:|
| typing | 2.02–2.19 | **1.71** |
| drag   | 12.31 | **8.67** |
| scroll | 4.37 | **3.51** |
| idle   | 0.57 | 0.83 |

Working set stays flat over a workload where stock's grows ~87 MB. Idle is the one phase
still marginally above stock.

An earlier build carried an idle burn that made typing cost 2× stock; it was found by a
single-variable comparison, fixed, and verified by an A/B with the defect deliberately
re-introduced as control. Windows 10 cross-install numbers (large margins, but not
single-variable), methodology, caveats and every retraction:
[docs/BENCHMARKS.md](docs/BENCHMARKS.md).

---

## Windows updates

dom0 drives every pass (Qube Manager); the guest never installs on its own (`NoAutoUpdate=1`).
Packages come from the Microsoft Update Catalog over a qrexec relay with a host allowlist —
no netvm, no general egress. WU still DISCOVERS updates (its COM searcher, online through the
proxy); only its download/install path was dropped — that path needs egress for DoSvc, can't be
told which package to install, and crawled at 120–150 KB/s (never root-caused).

The proxy is **template-only**: an app qube, a disposable or a standalone never acquires a proxy
and never starts the relay. A standalone with real internet turns the proxy updater off *and*
lifts `NoAutoUpdate`, so it is not left with updates disabled and nobody driving them.

Three failure modes that made this unreliable are fixed in 4.3.3: `0x80072F8F` (schannel could not
fetch Microsoft's certificate trust lists on a guest with no direct route — the CTLs are now
mirrored through the relay); a truncated response being served to Windows as a success (the relay
now answers `502` rather than hand over a short body); and the tail of a long command's output
being lost when the qrexec channel closed. Updates that genuinely cannot be installed — post-EOS
packages, express-only packages with no route, WU-client blobs DISM will not take — are now
reported as informational rather than counted as failures.

The catalog returns every file bundled with an update. For KB5121003 it also returned superseded
KB5043080 — DISM rejects it (rc=552), poisoning CBS so the cumulative rolled back at boot
(`0x80070490`). Filtering by KB before download fixes it; bandwidth is secondary.

Measured (KB5121003, 26100.8875 → 9168): offered 5,376 MB, transferred 4,867 MB — 509 MB (9.5%)
avoided — at 12.8 MB/s, ~45 min end to end. The catalog ships full cumulatives, not deltas:
5,029 of 9,036 payload packages are inapplicable (86.7% language variants of server FoDs)
≈ 24% of bytes, the price of a closed egress surface.

---

## Configuration

Everything optional is a Qubes feature, set from dom0 and read by the guest — nothing to edit
inside Windows. The full reference, including precedence, defaults and the guest-local registry
overrides, is [docs/QVM-FEATURES.md](docs/QVM-FEATURES.md). The short version:

| set in dom0 | what it does |
|---|---|
| `qvm-features <vm> service.enableWinKey 1` | let the Windows key through, so Start (or a third-party shell) opens. Default: blocked in seamless mode |
| `qvm-features <vm> service.gui-fullscreen 1` | allow a **borderless** true-fullscreen window (game, video, presentation). A maximized app with a title bar is always allowed; the boot/shutdown screen is never allowed, feature or not |

Both are ordinary Qubes service features — any non-empty value enables, `qvm-features --unset`
turns them off — and both are read **once, when the agent starts**, so restart the qube after
changing one.

Two settings are required rather than optional, and the dom0 RPM applies them for you
(`qwt-ng-prepare-qube <vm>` applies them to a qube created later): the `vmexec` feature, without
which dom0's update commands arrive at `cmd.exe` as shell text and the run aborts, and a raised
`qrexec_timeout`, because a Windows boot that is *applying* an update can take minutes to answer
qrexec against a 60 s default.

## Known limitations

- **qrexec runs in the interactive user session.** A logged-off guest loses clipboard and
  file-copy until someone logs in. This is how QWT is built, not something this build changed.
- **`XENBUS\…&DEV_CONS` sits at code 28** — QWT ships no `xencons`. It is the PV console
  (`xl console`), a debugging convenience; no display, disk, network or GUI path uses it.
- **mirage-firewall as netvm hangs Windows HVM domain creation** (dom0/mirage side — the
  guest never starts). Use `core-net`, or install offline.
- **Audio is emulated, not paravirtualised.** The guest gets QEMU's Intel HD Audio device
  (`PCI\VEN_8086&DEV_2668&SUBSYS_11001AF4`, i.e. Red Hat/QEMU) driven by an inbox Windows
  driver, with Speakers and Line In endpoints present and `err=0`; Qubes routes it via the
  qube's `audiovm`. Windows Tools contains no audio component because it does not need one —
  the path is entirely QEMU-side. Nothing here changes that, and there is no PV audio driver
  in Xen's Windows family to move to.

---

## Test status

Clean end-to-end installs of both platforms from **untouched vendor ISOs**. Each run destroys
and recreates the qube, installs, **cold boots**, and then asserts — a live restart would hide
faults that only a cold boot exposes.

Both platforms pass **14/14 with nothing skipped**: agent binary hash vs manifest, agent
running, Qubes services, IDD device bound, desktop on the IDD, IDD mode loop, PnP sweep clean,
agent log healthy, PV drivers bound with the emulated NIC gone, guest cursor hidden, user data
on the private volume, PV disk bound, network carrying traffic, clipboard round-trip.
