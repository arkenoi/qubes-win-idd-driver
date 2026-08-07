# Qubes Windows Tools 4.2.2 — improved GUI agent

A **full QWT install**, not an overlay: the upstream WiX MSI rebuilt from source with our
`gui-agent.exe`, plus certs, the VC++ runtime, an IddCx display driver payload, a fixed Xen
PV network driver, and a two-stage install script.

## Install

    install.cmd            two stages, you reboot between them
    install.cmd /auto      reboots and resumes by itself
    install.cmd /nonet     omit the PV network drivers (see below)
    install.cmd /idd       ALSO activate the IddCx display driver — read the caveat first

Binaries are TEST-SIGNED, so the installer enables testsigning and reboots once before the
MSI runs. Read `README.txt` in the package first.

## Headline: PV networking actually works

**QWT 4.2.2 ships a Xen PV network stack that cannot bind.** Its `xenvif` publishes VIF
interface revision `0x09000004` at most, while its own `xennet` requires `0x09000005`, so no
hardware ID intersects, the `XENVIF\…&DEV_NET` child sits at code 28
(`CM_PROB_FAILED_INSTALL`), and Windows silently falls back to the QEMU-emulated Realtek NIC.
Networking *works*, which is why this went unnoticed — but never over the PV path.

Cause: upstream `xennet` bumped its requirement in **July 2024**; upstream `xenvif` only
provided rev 5 in **June 2025** (commit `4608bc1`, "Use UNPLUG v3"). The pin Qubes carries
(identical on `main`, `release4.3` and `v4.2.0-1`) sits in that eleven-month window. Stock
QWT 4.2.2 is affected identically — our PV binaries were byte-identical to stock's.

This package ships a `xenvif` built from xenbits `master`, which has rev 5, and installs it
after the MSI. Measured on a clean guest:

    before:  Realtek RTL8139C+ Fast Ethernet NIC   (emulated)
    after:   Xen PV Network Device #0              (emulated NIC UNPLUGGED)
             10.137.0.70 → gateway reachable

## Also new

**netvm hotplug works without a reboot.** QWT applies the qubesdb-driven static IP only at
boot, so attaching a netvm to a running guest left it on APIPA. A SYSTEM task triggered by
"network connected" re-runs `network-setup.exe` on interface arrival. Verified: detach →
attach restored the address by itself in 15 s.

**Seamless mode works on an IDD-equipped guest** — the published mode set now always contains
the host size while seamless is active, so `SeamlessMode=1` no longer fails with
`DISP_CHANGE_BADMODE`.

**Office compound windows render as one window.** Measured on real Office in seamless mode:
8 visible Word windows in the guest, 4 in dom0 — the 3 real document frames plus a genuine
dialog; all 4 shadow-strip windows dropped, no frame lost.

For the full behaviour list and measured numbers see `docs/WHAT-CHANGED-FOR-USERS.md`.

## Test status

Clean-install acceptance on Windows 10 22H2, from media built off the untouched vendor ISO,
on a guest whose only driver source was this installer — **10/10 checks, nothing skipped**:

    agent binary hash == manifest, agent running, Qubes services, IDD device bound,
    IDD mode loop, PnP sweep clean, agent log healthy, clipboard round-trip,
    PV drivers bound (emulated NIC gone), network carries traffic (gateway reachable)

Windows 11 24H2 clean install also passes, including the full IDD assertion.

## Known issues

- **`/idd` on Windows 10 is opt-in and incomplete.** Activation runs correctly and the VGA
  disable persists, but after the reboot Windows drives the desktop through the
  `ROOT\BASICDISPLAY` fallback while the IDD stays offline — an IddCx monitor arrives
  inactive and needs a display-topology apply the installer does not yet perform. **It works
  on Windows 11 24H2.** Not enabled by the unattended media. If you use it on Win10 and lose
  the display, recover over qrexec with the `idd_recovery` command in the installer's RESULT
  JSON.
- **Maximized windows can overflow the dom0 workspace**, most visibly in the first minutes of
  a boot before dom0's work-area feed reaches the guest. A geometry-clamp fix was attempted
  and withdrawn — it cropped windows' own title and menu bars, because the reported rectangle
  is also what the per-window capture crops against.
- **Toast notifications map as borderless (override-redirect) windows** over whatever they
  cover, rather than as bordered windows the way Linux qubes show notifications. Undecided.
- **mirage-firewall as netvm hangs domain creation** for Windows HVMs (`qvm-start` blocks,
  domain stuck `Transient`). This is dom0/mirage side — the guest never starts — and is
  reported upstream. Use `core-net`, or install offline.
- **Benchmark against stock QWT is not included.** It needs two clean installs with
  interleaved reps to be meaningful, and an unvalidated number is worse than none.
