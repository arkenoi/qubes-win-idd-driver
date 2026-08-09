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

Release **[v4.3.0-agent03b1674](https://github.com/arkenoi/qubes-win-idd-driver/releases/tag/v4.3.0-agent03b1674)** — agent `03b1674`, package `4.2.2+agent.03b1674c731f`.

| file | use it for |
|---|---|
| [`qubes-windows-tools-ng-4.3.0-1.agent03b1674c731f.noarch.rpm`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.0-agent03b1674/qubes-windows-tools-ng-4.3.0-1.agent03b1674c731f.noarch.rpm) | **dom0** — installs the ISO at `/usr/lib/qubes/qubes-windows-tools.iso`, where `qvm-create-windows-qube` looks for it |
| [`qwt-ng-4.3.0-agent03b1674.iso`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.0-agent03b1674/qwt-ng-4.3.0-agent03b1674.iso) | attach to a running Windows qube as a CD and run `install.cmd` elevated |
| [`qwt-ng-4.3.0-agent03b1674-setup.tar.gz`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.0-agent03b1674/qwt-ng-4.3.0-agent03b1674-setup.tar.gz) | the same installer tree, if you would rather copy files in than mount a CD |
| [`SHA256SUMS.txt`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.0-agent03b1674/SHA256SUMS.txt) | checksums for all three |

The dom0 RPM is unsigned, so `qubes-dom0-update` will refuse it; install it directly:

```
sudo rpm -i qubes-windows-tools-ng-4.3.0-1.agent03b1674c731f.noarch.rpm
```

**Provenance.** These assets are the build that was actually measured — the same binaries
that produced the 14/14 acceptance runs and every number in the four-install benchmark below
(`gui-agent.exe` sha256 prefix `CBBD02069A01E047`). A later CI run at the *same* agent commit
produces a *different* `gui-agent.exe` hash, because the Windows build is not reproducible
(the PE header carries a build timestamp). Rather than ship an untested-but-newer binary, the
release carries the tested one. The ISO and RPM were built from that exact setup tree.

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

### What this build is not: a performance fix

An earlier revision of this section was headlined "Everything is markedly cheaper on
Windows 10" — dragging 2.6× less CPU, scrolling 5.4× less, typing 7.4× less. Those figures
are real measurements, but they come from the four-install comparison below, where stock and
this build differed in more than the agent: different installs, different display stacks. The
controlled experiment that has since been run — same guest, agent swapped in place, benchmark
section below — settled the one metric it could resolve, and it went the other way: **typing
costs 2× stock CPU**; drag and scroll landed inside noise, no verdict either way. Until that
gap is found and removed, do not install this build expecting lower CPU cost. Install it for
the correctness fixes and capabilities on this page, which stand on their own.

### One mouse cursor instead of two

Stock Windows Tools shows a doubled mouse cursor — dom0 draws its own pointer over the guest
window while the guest also paints one into the captured frame, in every mode. This build
blanks the guest-side cursor so only dom0's is visible.

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

### A real display driver, which stock does not have at all

Stock Windows Tools ships **no display driver**. The guest runs on the emulated Basic Display
Adapter, whose mode list is fixed — so an arbitrary size like 2566x1022 is simply never
offered, and matching the guest resolution to a dom0 window is unreachable by construction.

With `/idd`, an IddCx monitor becomes the guest's **sole active output** and the emulated VGA
is disabled. 

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

## Benchmark

Four clean installs, two platforms × two builds, differing **only in the MSI** — both sides
installed by the identical installer through the identical clean-room path (untouched vendor
ISO, answer file and payload on a small emulated USB stick).

Protocol: 3 repetitions per cell, **interleaved** across all four cells rather than run in
blocks, one guest running at a time, and the running agent binary hash verified before every
repetition. All 12 cells valid; none discarded.

**Caveat (2026-08-09):** "differing only in the MSI" was never single-variable — the four
cells differ in install *and* display stack (ours runs the desktop on the IddCx driver; stock
has no display driver at all), not only in the agent. One condition alone — DDA-sourced
capture on vs off, same binary — swings our typing cost from 12.4 to 4.4, so cross-cell CPU
comparisons in this table cannot carry improvement claims on their own. The table stays as
historical data; the single-variable experiment below is the authoritative stock comparison.

```
stock  win10   agent 3D2E6BCEC9F5BD89      ours  win10   agent CBBD02069A01E047
stock  win11   agent 3D2E6BCEC9F5BD89      ours  win11   agent CBBD02069A01E047
```

### gui-agent CPU (% of one core, median of 3)

| workload | stock win10 | ours win10 | stock win11 | ours win11 |
|---|---:|---:|---:|---:|
| drag    | 33.09 | 12.96 | 12.33 | 16.11 |
| scroll  | 47.83 | 8.91  |  4.06 | 13.93 |
| typing  | 32.61 | 4.38  |  3.13 | 14.99 |
| idle    |  0.105|  0.027|  0.000|  0.240 |

(An earlier revision bolded the ours-win10 cells as wins; the emphasis is removed for the
same reason the "clear, consistent win" wording below is withdrawn — these cells cannot
carry a win claim.)

### In-guest renderer — instrumentation-independent, but still cross-install

| metric | stock win10 | ours win10 | stock win11 | ours win11 |
|---|---:|---:|---:|---:|
| fps, moving rect       | 314.6 | **806.5** |  937.7 | 1090.2 |
| fps, full repaint      | 804.2 | 910.2     | 1172.6 | 1307.2 |
| frame delay p50, move  |  2.91 | **0.86**  |   0.63 |   0.57 |
| frame delay p95, move  |  5.03 | 3.03      |   3.00 |   2.75 |
| frame delay p99, move  |  8.76 | 4.76      |   5.54 |   5.44 |
| idle working set (MB)  | 108.5 | 68.2      |   99.7 |   54.1 |

These numbers do not depend on our perf logging, but they inherit the same four-install
confound as the CPU table: the cells differ in install *and* display stack, and the display
stack affects renderer throughput and latency directly. Like the CPU cells, they are
historical data, not a demonstrated win.

### How to read this

**The Windows 10 cells favour this build on every dimension measured** — CPU, throughput,
latency and memory — but the table cannot prove a win, because those cells compare different
installs and display stacks, not just the agent. An earlier revision of this paragraph called
Windows 10 "a clear, consistent win"; that claim is withdrawn as stated. The fork's
self-introduced per-frame overhead (next subsection) is version-agnostic, and no
single-variable Windows 10 comparison has been run.

**On Windows 11 our build costs more CPU than stock** — 16.1 vs 12.3 on drag, 13.9 vs 4.1 on
scroll, 15.0 vs 3.1 on typing. An earlier revision of this paragraph said this was "*not*
established as a regression" because the two Win11 rows differed in display stack too, and
that it "deserves a dedicated experiment — IDD vs BDA on the *same* agent — before anyone
claims either result". That dedicated experiment has now run (next subsection) and settled
it: on typing the regression is real, +100 % vs stock with non-overlapping distributions;
drag and scroll remain inside noise. Our Win11 row here still shows higher throughput, lower
frame delay and roughly half the idle working set — but those cells carry the same
cross-install confound as everything else in this table and are not claimed as advantages.
(The single-variable run did independently confirm one of them: over a 110 s workload the
fork's working set stays flat while stock's grows ~87 MB.)

**The artifact and z-order defects above are not in this table.** The harness measures cost
and latency, not whether the painted result is correct. A build can be cheap and still draw
garbage; stock's seamless drag artifacts and its z-order dependency are exactly that kind of
defect, and they were found by looking at the screen, not by measuring it.

### The single-variable comparison: same guest, agent swapped in place (2026-08-09)

The dedicated experiment the paragraph above asked for — the first single-variable
ours-vs-stock measurement in this project's history. ONE guest (`win11-idd-test`), rebuilt
with genuine stock QWT 4.2.2 (MSI byte-identical to the vendor's), offline, classic
`notepad.exe` on both sides; our agent (build `51cc897`, a direct descendant of the released
`03b1674`) swapped in and out **in place** via an elevated scheduled task, the running
binary's hash verified before every repetition; 5 rounds interleaved. Gate: the DDA fast
path served **99.4 %** of captures (ddacap=2293, pwcap=13, zero refusals), so this is a
clean read of the capture feature working as designed, not a fallback measurement.

gui-agent CPU (% of one core, median):

| workload | stock 4.2.2 | ours (DDA on) | delta | verdict |
|---|---:|---:|---:|---|
| typing | **2.188** | **4.381** | **+100 %** | **REAL — distributions do not overlap** |
| drag   | 12.314 | 11.727 | −4.8 % | inside noise (spread 34.6 %) — no verdict |
| scroll | 4.369 | 5.158 | +18 % | inside noise (spread 42.5 %) — no verdict |

Typing is the one robust result: every ours repetition (min 3.042; n=4 because one
repetition's CPU sampler produced no samples and was emitted as `na`, not 0) is worse than
every stock repetition (max 2.651; n=5). **Our agent costs 2× stock on typing CPU.** Drag
and scroll differences are smaller than the run-to-run spread and prove nothing in either
direction — the harness's own "beats stock" tag on drag is not supported and is not claimed.

**Root cause (2026-08-09, later the same day; see FINDINGS.md).** Re-analysis of the same
traces per phase showed the gap is not in the typing path at all: it is a standing idle
burn (ours 3.04 % vs stock 0.57 % with one attached window and no input; the typing
*increment* over idle is equal on both sides, and drag is slightly cheaper than stock).
The burn is the per-window capture engine's 250 ms sweep, which kept running a full
`PrintWindow` + whole-buffer diff on the DDA-served window 4×/s. A fix (exempting
DDA-owned windows from the sweep, switchable via `SweepDdaExempt`) is committed and
awaiting a measured one-binary A/B; until that lands and is verified, the 2×-on-typing
verdict above stands for every released build.

**Retraction.** Project notes had earlier headlined DDA-sourced capture as "a large, measured
win: typing −67 %". That figure compared our binary against *itself* with DDA capture
disabled — never against stock. Lined up honestly:

```
ours, DDA off   12.427   (5.7× worse than stock)
ours, DDA on     4.381   (2.0× worse than stock)
stock 4.2.2      2.188
```

DDA removes most of an overhead the fork itself introduced; it does not make the fork faster
than what it forked.

Instrumentation is not the explanation. Our build writes a perf record every frame and stock
writes none, but from the same runs' data the logging costs 228 µs of a 2200 µs per-frame
total — about 10 %, a fraction of a CPU point, nowhere near the 2.2-point typing gap. The
gap is real code — the fork adds per-window capture on top of stock's whole-desktop
streaming — not the logger.

**Consequence:** on typing this build is a regression against stock, and it is not presented
— here or anywhere — as a performance fix until that cost is found and removed. The
correctness fixes and capabilities above stand on their own.

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
