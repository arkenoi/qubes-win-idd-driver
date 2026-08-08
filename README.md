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

### Everything is markedly cheaper on Windows 10

Dragging costs **2.6× less CPU**, scrolling **5.4× less**, typing **7.4× less**. The guest
renders 2.6× more frames per second with median frame delay down from 2.91 ms to 0.86 ms.
Idle memory drops by a third. Numbers below.

### Office windows render as one window

Post-2013 Office surrounds its frame with layered, click-through shadow HWNDs. The agent
used to map each as a separate window, so dom0 drew a border around every fragment. Measured
on real Office in seamless mode: **8 visible Word windows in the guest, 4 in dom0** — the
three real document frames plus a genuine dialog. All four shadow strips dropped, no real
window lost.

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

### The IddCx display driver works on both platforms

With `/idd`, an IddCx monitor becomes the guest's sole active output and the emulated VGA is
disabled. This is what makes arbitrary guest resolutions reachable at all — the Basic Display
Adapter offers a fixed mode list, so a size like 2566x1022 is simply never available.

---

## What was actually wrong

### PV networking could never bind

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

### The IddCx monitor was never attached to the desktop

An IddCx monitor arrives **connected but INACTIVE**. It is not attached to the desktop until
something performs a display-topology apply naming its path. Nothing in the package ever did.
On Windows 10 the driver bound, the VGA was disabled, and the desktop stayed on the emulated
VGA anyway — which keeps driving video at full resolution even while its devnode reports
`CM_PROB_DISABLED`. Windows 11 performs the apply itself, which is the entire Win10/Win11
difference; the driver has no OS-build branch at all.

The agent now performs the apply at startup, in the interactive session (the installer's
boot-resume task runs as SYSTEM in session 0, where the apply returns `ERROR_ACCESS_DENIED`).
Every other display is *detached* rather than deprioritised, because an extra active display
enlarges the desktop bounding box the agent maps as the screen and breaks seamless
coordinates.

### Three regressions this package had introduced against stock

Found by auditing every default the packaging commit changed:

- **PV disk drivers were dropped** citing a "documented BSOD risk" that has no source.
  Upstream's own description is *"Xen PV disk drivers for increased performance"*, and no
  feature in `Package.wxs` sets a `Level` attribute — WiX defaults them all to `Level=1`, so
  stock installs it. Every guest was doing all disk I/O over emulated IDE.
- **`DisableCursor` was seeded `0`**, so the guest painted its own cursor on top of dom0's.
  Stock's default is `1`. The name reads backwards: `HideCursors()` returns early *unless*
  the flag is set.
- **`MoveUsers` was omitted**, leaving profiles on the root volume.

`Autologon` remains deliberately omitted, and here the divergence from stock is intentional:
upstream's own description warns that it uses a *"randomized password"* and that *"access to
EFS files WILL BE LOST"* and stored credentials are invalidated.

---

## Benchmark

Four clean installs, two platforms × two builds, differing **only in the MSI** — both sides
installed by the identical installer through the identical clean-room path (untouched vendor
ISO, answer file and payload on a small emulated USB stick).

Protocol: 3 repetitions per cell, **interleaved** across all four cells rather than run in
blocks, one guest running at a time, and the running agent binary hash verified before every
repetition. All 12 cells valid; none discarded.

```
stock  win10   agent 3D2E6BCEC9F5BD89      ours  win10   agent CBBD02069A01E047
stock  win11   agent 3D2E6BCEC9F5BD89      ours  win11   agent CBBD02069A01E047
```

### gui-agent CPU (% of one core, median of 3)

| workload | stock win10 | ours win10 | stock win11 | ours win11 |
|---|---:|---:|---:|---:|
| drag    | 33.09 | **12.96** | 12.33 | 16.11 |
| scroll  | 47.83 | **8.91**  |  4.06 | 13.93 |
| typing  | 32.61 | **4.38**  |  3.13 | 14.99 |
| idle    |  0.105|  0.027    |  0.000|  0.240 |

### In-guest renderer — no dependency on our instrumentation, so genuinely comparable

| metric | stock win10 | ours win10 | stock win11 | ours win11 |
|---|---:|---:|---:|---:|
| fps, moving rect       | 314.6 | **806.5** |  937.7 | 1090.2 |
| fps, full repaint      | 804.2 | 910.2     | 1172.6 | 1307.2 |
| frame delay p50, move  |  2.91 | **0.86**  |   0.63 |   0.57 |
| frame delay p95, move  |  5.03 | 3.03      |   3.00 |   2.75 |
| frame delay p99, move  |  8.76 | 4.76      |   5.54 |   5.44 |
| idle working set (MB)  | 108.5 | 68.2      |   99.7 |   54.1 |

### How to read this

**Windows 10 is a clear, consistent win** across every dimension measured: CPU, throughput,
latency and memory.

**On Windows 11 our build costs more CPU than stock** — 16.1 vs 12.3 on drag, 13.9 vs 4.1 on
scroll, 15.0 vs 3.1 on typing. This is stated plainly rather than omitted. It is *not*
established as a regression, because the two Windows 11 rows do not differ only in the agent:
ours runs the desktop on the IddCx driver and stock has no IDD at all, so the display stack
differs too. Our Win11 row still shows higher throughput, lower frame delay and roughly half
the idle working set. The CPU direction is reproducible across all three repetitions and
deserves a dedicated experiment — IDD vs BDA on the *same* agent — before anyone claims
either result.

**The artifact and z-order defects above are not in this table.** The harness measures cost
and latency, not whether the painted result is correct. A build can be cheap and still draw
garbage; stock's seamless drag artifacts and its z-order dependency are exactly that kind of
defect, and they were found by looking at the screen, not by measuring it.

### What is deliberately absent

- **dom0-side pixel metrics.** Sampling dom0 is the slowest element in the whole path
  (~5 s per full-desktop capture), so it cannot resolve frame rate; and a full-desktop
  sampler reports ~100 % changed frames on every side because the dom0 desktop itself
  changes — two consecutive *static* captures already produced different hashes. A dedicated
  dom0-side sensor is the right tool and is not built yet.
- **Per-frame agent cost (QGAPERF).** Ours-only by construction — stock emits no per-frame
  instrumentation — and currently unreported even for our rows because the benchmark's log
  reader still points at the pre-`Q:\Qubes Logs` path. A harness gap, not a property of the
  build.
- **Whole-VM CPU under load.** Reported `n/a`: cputime was unavailable, which is not zero.

---

## Known limitations

- **qrexec runs in the interactive user session.** A logged-off guest loses clipboard and
  file-copy until someone logs in. This is how QWT is built, not something this build changed.
- **`XENBUS\…&DEV_CONS` sits at code 28** — QWT ships no `xencons`. It is the PV console
  (`xl console`), a debugging convenience; no display, disk, network or GUI path uses it.
- **mirage-firewall as netvm hangs Windows HVM domain creation** (dom0/mirage side — the
  guest never starts). Use `core-net`, or install offline.
- **No audio.** QWT 4.2.2 contains no audio component at all, and Xen's Windows PV family has
  no audio driver.

---

## Test status

Clean end-to-end installs of both platforms from **untouched vendor ISOs**. Each run destroys
and recreates the qube, installs, **cold boots**, and then asserts — a live restart would hide
faults that only a cold boot exposes.

Both platforms pass **14/14 with nothing skipped**: agent binary hash vs manifest, agent
running, Qubes services, IDD device bound, desktop on the IDD, IDD mode loop, PnP sweep clean,
agent log healthy, PV drivers bound with the emulated NIC gone, guest cursor hidden, user data
on the private volume, PV disk bound, network carrying traffic, clipboard round-trip.
