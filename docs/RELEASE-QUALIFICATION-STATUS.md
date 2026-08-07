# Release qualification status — 2026-08-07

Goal (user): E2E install test Win10+Win11, regression, networked qube / Windows Update,
Office behaviour, benchmark vs stock QWT, user-facing write-up, installable package (+ISO)
on GitHub, then feature freeze.

Every line below is measured. Where something is unproven or was retracted it says so.

## PROVEN

| item | evidence |
|---|---|
| **Win11 24H2 clean E2E: PASS** | `win11-fresh`, build 26100, unattended install from the UNTOUCHED vendor eval ISO (`755a90d4…`), guest never had QWT. `ok:true`, agent hash == manifest (`b758dd92…`), qrexec after 2009 s. Health gate **8/8 with the FULL IDD assertion**: `desktop_on_idd` PASS — IddSampleDriver Device is the ONLY active controller, BDA offline. Agent: `mode=s`, 4 window maps, frames at seq 7032, popup synthesis live. |
| **Seamless on the IDD config (Gate B)** | `win-idd-test` cold boot: `SetSeamlessMode: 1`, `M6SEAMLESS host 5120x1440 added to set`, **zero BADMODE**, 5120x1440 applied, per-window bordered dom0 windows, one agent instance. Merged to main. |
| **Clean-path install mechanics** | Answer file read off the media (Setup skips the locale picker), `diskprep.cmd` selects the install disk BY SIZE, our package delivers qrexec on a guest with no prior QWT (`existing_qwt: []`), 20/20 payload files verified. |
| **`/idd` activation sequence itself** | devcon device create → adapter presence gate → VGA disable; disable PERSISTS across reboot (`err=22`, `ConfigFlags=1`). Works end to end on Win11. |
| **Health gate is real** | `guest/health-check.ps1` validated BOTH ways: FAILS the degraded no-IDD guest, PASSES the intended state. It then caught two genuine defects on its first real runs (below). |
| **Chrome assertion is real** | `tools/check-chrome.py` seen to FAIL on the exact build that cropped window menus (`top_band_colours=2`, exit 1) before being trusted. |
| **Package + ISO build** | CI `release-package` green on main; MSI carries our agent; ISO produced. |
| **Networking + Windows Update** | verified earlier on `core-net`, zero issues — but see the PV caveat below. |

## FOUND, NOT SHIPPING

**`/idd` is OUT of the default payload — opt-in only.** On **Win10 19045** the installer's
activation leaves the IDD bound but NOT driving the desktop: after reboot Windows runs the
`ROOT\BASICDISPLAY` fallback at 3440x1440 while `ROOT\DISPLAY\0000` is offline
(`Availability=8`). That guest then wedged (zero active grants; **causation unproven** — the
wedge class predates the IDD). Shipping it on by default would make every Win10 clean install
worse than the plain BDA build.

Correction worth stating: I first called this platform-independent. **It is not** — the same
installer passes fully on Win11. And `win-idd-test` (also Win10 19045) DOES run IDD-primary,
but reached that state through the 2026-08-05 manual sequence, not the installer. So Win10
can do it and the installer omits the activating step (topology apply). Tracked as task #11.

## NOT PROVEN

- **Win10 default-config clean E2E** — running now on `win10-noidd.iso` with
  `HEALTH_ARGS=-NoIddExpected`. The earlier Win10 run failed on `desktop_on_idd` only.
- **Win11 visual acceptance — UNPROVEN BY TOOLING, not a failure.** `local.WinScreenshot+win11-fresh`
  returns 0 bytes because the dom0 screenshot service's allowlist does not include
  `win11-fresh` (`fullshot` gives it away by returning win-idd-test's windows).
  **Needs one dom0 action:** add `win11-fresh` to the allowlist, or reinstall the service with
  the tag-based policy so any `win-idd-testbed`-tagged qube is served.
- **PV networking is not bound** on the reference guest: traffic runs over the EMULATED
  Realtek NIC; `XENVIF\…&DEV_NET` sits at code 28 while xennet never binds, despite
  `ADDLOCAL=…,PvDriversNetwork`. Whether stock QWT behaves the same here is not established.
  The earlier "networking + WU zero issues" result stands as FUNCTIONAL, over the emulated NIC.
- **Office window behaviour** — not run in seamless mode yet.
- **Regression suite / valid benchmark** — not run; benchmark still needs an
  interactive-session scene generator.
- **Toast classification** — a toast maps borderless (override-redirect) over the window it
  covers. CLAUDE.md 2A-chrome 3c says that is intended; its own note says Linux qubes show
  notifications as normal BORDERED windows, and the user's report sides with bordered.
  Undecided pending one live toast captured with the attribute probe.

## RETRACTED THIS SESSION

1. **The work-area maximize clamp** — claimed fixed, actually cropped each window's title and
   menu bar (the window rect is also the capture crop). Reverted; write-up corrected.
2. **"The two-disc clean-room route works"** (2026-08-06) — it does not. `qvm-device block
   assign --option devtype=cdrom` creates a PV device: SeaBIOS reports `No bootable device`
   and WinPE cannot see it. The original claim rested only on the dom0 command being accepted.
3. **"The IDD activation gap is platform-independent"** — Win11 passes; it is Win10-specific.

## INSTALL MEDIA POLICY

The two-disc route being impossible, media is a **minimal, auditable repack**: `bootfix.bin`
kept (vendor file, untouched timestamp), the only vendor change is the lossless
`install.wim` → `.swm` split (`wimlib-imagex verify`d, forced by ISO9660's 4 GiB limit
without UDF), and every build emits `<iso>.vendor-delta.txt` recording the source ISO's
SHA256 and exactly what was added or changed.

## FEATURE FREEZE

Code is effectively frozen. Everything this session is test infrastructure, installer
correctness, one agent fix (seamless host mode), one agent revert, and documentation.
