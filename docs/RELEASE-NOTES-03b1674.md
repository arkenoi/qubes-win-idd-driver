# QWT 4.2.2 + improved GUI agent (03b1674) — disks, cursor, user data, Win10 display

**Ready to publish; not yet published.** Supersedes `v4.2.2-agent.a68d244-pvfix`, which is
currently tagged Latest and **carries known regressions** (listed below).

Package `4.2.2+agent.03b1674c731f`, from CI run `31202555740` @ `fcecaee`. Validated
**14/14 on Windows 10 22H2 and Windows 11 24H2** — clean installs from untouched vendor
ISOs, asserted after a cold boot, nothing skipped.

Publish with:

    gh release create v4.2.2-agent.03b1674 \
      --title "QWT 4.2.2 + improved GUI agent (03b1674)" \
      --notes-file docs/RELEASE-NOTES-03b1674.md

## Read this first

Binaries are **TEST-SIGNED**: the installer runs `bcdedit /set testsigning on`, weakening
driver-signature enforcement guest-wide. Stock QWT ships production-signed binaries and does
not do this. Inherent to an unofficial build, but a real change to your guest's posture.

**If you install onto an existing qube, extend the private volume first.** User data now
moves to `Q:\Users`, the Qubes default private volume is 2 GiB, and a bare Windows profile
already uses ~550 MB:

    qvm-volume extend <vm>:private 40GiB

## Fixed since the published release

Each of these was a regression *this package* introduced against stock QWT, not an upstream
defect:

- **PV disk drivers installed.** `PvDriversDisk` had been dropped citing a "documented BSOD
  risk" that has no source; upstream's own description is "Xen PV disk drivers for increased
  performance", and stock installs it by default. Every guest was doing all disk I/O over
  emulated IDE. Disks now report `BusType=SCSI` instead of `ATA`.
- **Double cursor gone.** `DisableCursor` had been seeded `0`, so the guest painted its own
  cursor into the captured frame on top of dom0's. Stock's default is `1`; ours now matches.
- **User data on the private volume.** `MoveUsers` restored, so `C:\Users` is a reparse point
  targeting `Q:\Users`. Previously profiles sat on the **root** volume, where a
  `qvm-volume revert` of root would have destroyed them. Logs follow to `Q:\Qubes Logs`.
- **`/idd` works on Windows 10.** An IddCx monitor arrives connected but INACTIVE, and
  nothing in the package ever performed a display-topology apply, so the desktop stayed on
  the emulated VGA. The agent now performs it at startup and the IDD is the sole active
  output on both platforms.

## Carried over

- **PV networking actually binds.** Stock QWT 4.2.2 ships `xenvif` at VIF revision
  `0x09000004` while its own `xennet` requires `0x09000005`, so the PV NIC never binds and
  Windows silently falls back to the emulated Realtek. This package ships `xenvif` built
  from xenbits master.
- **netvm hotplug without a reboot**, **seamless mode on an IDD-equipped guest**, and
  **Office compound windows rendering as one window** (8 guest windows → 4 in dom0).

## Verified

14/14 on both platforms, nothing skipped: agent hash vs manifest, agent running, Qubes
services, IDD device bound, desktop on the IDD, IDD mode loop, PnP sweep clean, agent log
healthy, PV drivers bound with the emulated NIC gone, guest cursor hidden, user data on the
private volume, PV disk bound, network carrying traffic, clipboard.

## Known limitations

- **qrexec runs in the interactive user session.** A logged-off guest loses clipboard and
  file-copy until someone logs in. This is how QWT is built, not something this package
  changed.
- **`XENBUS\…&DEV_CONS` sits at code 28** — QWT ships no `xencons`. Affects `xl console`
  debugging only; no display, disk, network or GUI path uses it.
- **mirage-firewall as netvm hangs Windows HVM domain creation** (dom0/mirage side). Use
  `core-net`, or install offline.
- **No audio.** QWT 4.2.2 contains no audio component at all, and Xen's Windows PV family has
  no audio driver.
- **Benchmark vs stock is not included.** It is running at time of writing; numbers will be
  added only once the control is confirmed genuinely stock and installed by an identical
  route. An unvalidated performance claim is worse than none.
