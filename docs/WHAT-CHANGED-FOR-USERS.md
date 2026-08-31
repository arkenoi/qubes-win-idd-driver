# What changed, from a user's point of view

QWT-NG 4.3 — Qubes Windows Tools built from upstream QWT 4.2.2 sources with an improved GUI agent.
Everything below is measured on clean end-to-end installs of Windows 10 22H2 and
Windows 11 24H2, not inferred.

## Read this first

**The binaries are TEST-SIGNED.** The installer runs `bcdedit /set testsigning on`, which
weakens driver-signature enforcement for the whole guest until you turn it off. Stock QWT
signs with its own self-signed "Qubes Windows Tools" certificates, trusted only because its
installer puts them in the guest's Root store. It is inherent to an unofficial
build, not a defect - but it is a real change to your guest's security posture and you
should decide about it deliberately.

## Things that were broken and now work

### PV networking actually binds

QWT 4.2.2 ships a Xen PV network stack that **cannot bind**. Its `xenvif` publishes VIF
interface revision `0x09000004` at most, while its own `xennet` requires `0x09000005`. No
hardware ID intersects, the `XENVIF\…&DEV_NET` child sits at code 28
(`CM_PROB_FAILED_INSTALL`), and Windows silently falls back to the QEMU-emulated Realtek
NIC. Networking *works*, which is why nobody noticed - but never over the PV path.

Upstream `xennet` raised its requirement in July 2024; upstream `xenvif` only gained
revision 5 in June 2025. The pin Qubes carries sits in that eleven-month window, identically
on `main`, `release4.3` and `v4.2.0-1`. Stock QWT 4.2.2 is affected the same way.

Measured on a clean guest, before and after:

    before:  Realtek RTL8139C+ Fast Ethernet NIC   (emulated)
    after:   Xen PV Network Device #0              (emulated NIC UNPLUGGED)
             10.137.0.70 -> gateway reachable

### Disk I/O is no longer emulated IDE

Earlier builds of *this* package dropped the PV disk drivers, so every byte of guest disk
I/O went through emulated IDE. That was a regression against stock, which installs them by
default. They are back:

    before:  disk0/1/2  BusType=ATA    (emulated IDE)
    after:   disk0/1/2  BusType=SCSI   (Xen PV block, via StorPort)

### The display is driven by a real indirect display driver

With `/idd`, an IddCx driver becomes the guest's **sole active output** and the emulated VGA
is disabled. This is what makes arbitrary resolutions possible at all - the Basic Display
Adapter offers a fixed mode list, so a size like 2566x1022 is simply never available.

This previously worked only on Windows 11. On Windows 10 the driver bound but never drove
the desktop, because nothing in the package performed a display-topology apply: an IddCx
monitor arrives *connected but inactive* and stays that way until something attaches it. The
agent now performs that apply at startup, and it works on both platforms.

### Your user data lives on the private volume

`C:\Users` is redirected to `Q:\Users` on the Qubes private image, as stock QWT does. An
earlier build of this package omitted that, which left profiles on the **root** volume -
where a `qvm-volume revert` of root would have destroyed them.

**If you install this on an existing qube, check your private volume size.** All user data
lands there — as it always has under stock Windows Tools — the Qubes default private volume
is 2 GiB, and a bare Windows profile already uses about 550 MB. Extend it before you fill it:

    qvm-volume extend <vm>:private 40GiB

### One mouse cursor instead of two

dom0 draws the cursor over the guest window. An earlier build of this package also let the
guest paint its own cursor into the captured frame, so you saw two. Fixed.

### Office windows render as one window

Post-2013 Office surrounds its frame with layered, click-through shadow HWNDs. The agent
used to map each of them as a separate window, so dom0 drew a border around every fragment.
Measured on real Office in seamless mode: **8 visible Word windows in the guest, 4 in dom0** -
the three real document frames plus a genuine dialog. All four shadow strips dropped, no
real window lost.

### Attaching a netvm no longer needs a reboot

QWT applies the qubesdb-driven static IP only at boot, so attaching a netvm to a running
guest left it on an APIPA address. A SYSTEM task triggered by "network connected" now
re-runs the network setup when an interface arrives. Verified: detach then attach restored
the address by itself in 15 s.

### Seamless mode works on an IDD-equipped guest

The published mode set now always contains the host size while seamless is active, so
`SeamlessMode=1` no longer fails with `DISP_CHANGE_BADMODE`.

## Things that are deliberately different from stock

- **Autologon is NOT installed.** Upstream's own description warns: *"randomized password …
  Don't enable if you use NTFS-encrypted files (EFS), access to them WILL BE LOST! All
  existing stored credentials will be invalidated."* Silently rotating your account password
  is destructive, so this package leaves it out. You log in normally.
- **Seamless mode is on by default** (stock defaults to off, with the upstream comment
  "TODO enable after polishing").
- **Logs go to `Q:\Qubes Logs`** on the private volume.

## Known limitations

- **qrexec needs a logged-in session.** dom0→guest RPC - including clipboard and file copy -
  runs in the interactive user session. If the guest is logged off, those stop working until
  someone logs in. This is how QWT is built, not something this package changed.
- **The Xen PV console now works — but you must ask for it by name.** We ship `xencons`, so
  `XENBUS\…&DEV_CONS` binds and the guest runs an interactive `cmd.exe` on the PV console
  ring. Use `qvm-console <vm>` or `sudo xl console -t pv <vm>`, and **press Enter** — a fresh
  attach shows a blank screen because a pty has no scrollback. Plain `sudo xl console <vm>`
  fails on any Qubes HVM (no emulated serial exists for it to attach to).
- **mirage-firewall as netvm hangs domain creation** for Windows HVMs. This is dom0/mirage
  side - the guest never starts. Use `core-net`, or install offline.
- **No audio.** QWT 4.2.2 contains no audio component at all (verified by scanning the MSI in
  both ASCII and UTF-16), and Xen's Windows PV family has no audio driver. Not a regression;
  simply absent.
- **Known upgrade issue: stock QWT with an active PV boot disk.** Upgrading over stock QWT
  removes it first, which can revert the boot disk toward emulated IDE and bugcheck 0x7B
  INACCESSIBLE BOOT DEVICE at the intermediate reboot (reported in the field). The installer
  detects this and aborts unless `/acceptpvdiskupgrade` is passed; the recovery recipe is in
  the installer's README.txt, section "UPGRADING FROM STOCK QWT".

## Test status

Clean end-to-end installs of both platforms, from **untouched vendor ISOs** - the answer file
and payload are delivered on a small emulated USB stick, so the install media is provably
unmodified. Each run destroys and recreates the qube, installs, **cold boots**, and then
asserts.

Both platforms pass **14/14 with nothing skipped**: agent binary hash vs manifest, agent
running, Qubes services, IDD device bound, desktop on the IDD, IDD mode loop, PnP sweep
clean, agent log healthy, PV drivers bound with the emulated NIC gone, guest cursor hidden,
user data on the private volume, PV disk bound, network carrying traffic, clipboard.

**Benchmark against stock QWT: in progress at time of writing.** It runs two clean installs
whose only difference is the binaries under test, with repetitions interleaved stock/ours and
the running agent hash re-verified before each one. Numbers are published once the control is
confirmed genuinely stock and installed by the identical route.
