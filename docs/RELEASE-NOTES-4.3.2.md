# QWT-NG 4.3.2 — the IDD escape hatch, and 53 agent commits 4.3.1 never carried

Status: **notes written before publication.** The package builds green; the release itself is
not published until the user says so.

This release exists because of one field report. Dr. Gerhard Weck ran `v4.3.1-agentc7ccb45` on
Windows 10 22H2 and Windows 11 25H2 (forum thread 42717, posts 44-56) and found the previous
build, `09b643e`, clearly better. Two things are true about that, and both are addressed here:

1. He was right that he had no way out. 4.3.1 activates the IddCx display driver on every
   install, the README called running without it "a failure state, not an option", and there
   was no switch. A user whose display broke had nothing to try.
2. He was measuring a build that predates the fixes for most of what he reported. 4.3.1 was cut
   on 2026-08-10; the pointer-offset fix landed 2026-08-12, and the Windows 11 25H2 Start-menu
   work landed across 2026-08-11..13. `git log c7ccb459..` is 53 agent commits.

## New: the IDD can be turned off, and turned back on

    install.cmd /noidd     fresh install: do not activate the IddCx driver. The driver files
                           still ship, nothing touches the driver store, the emulated VGA
                           adapter stays enabled.
    install.cmd /iddoff    a guest that ALREADY has it: re-enable the VGA adapter, stop the
                           agent re-applying the IDD topology, remove the IDD device, reboot.
    install.cmd /iddonly   (re)activate it later.

`/iddoff` is also the **recovery** path. It never calls a display API, so it works over qrexec
from dom0 on a guest whose screen shows nothing:

    qvm-run -u SYSTEM <vm> "powershell -ExecutionPolicy Bypass -File C:\qwt-improved-setup\deactivate-idd.ps1"

What you lose with the IDD off: resolutions that follow the size of the qube's window in dom0.
The Basic Display Adapter offers a fixed mode list, so the desktop snaps to one of its sizes.
Everything else works. The README's "failure state, not an option" framing is withdrawn.

Verified on a live Win11 guest, by screenshot rather than by log line: `/iddoff` -> reboot ->
desktop renders on the Basic Display Adapter at 3440x1440; `/iddonly` -> reboot -> back to the
IDD as the sole display at 5120x1440.

## Fixed: `/iddonly` could not have worked in 4.3.1, for a reason nobody would guess

`%~dp0` ends with a backslash, so `-Root "%HERE%"` reached PowerShell as `-Root "C:\path\"`,
where `\"` is an escaped quote. The script received `C:\path"` and died with "Illegal characters
in path". A guest's own activation log had been recording it for three days:

    IDD ACTIVATION FAILED: C:\qwtc"\idd-driver holds 0 .inf files (expected exactly 1)

Every switch that hands a directory to a script was affected (`/iddonly`, `/iddoff`,
`/updatesonly`). Fixed.

Related: install.cmd now names the file a switch needs when it is missing from the medium,
instead of surfacing a raw PowerShell file-not-found. The shipped 4.3.1 medium genuinely has no
`activate-idd.ps1` - it was committed hours after those assets were uploaded.

## Fixed since 4.3.1, from the same thread

* **Pointer lands ~1 cm below where Windows thinks it is** (posts 44, 54). The agent stored the
  resolution it REQUESTED, not the one Windows APPLIED, and absolute input injection is
  normalised against that belief - so any divergence became a proportional vertical error.
  It now adopts the read-back size and re-checks for out-of-band mode reversions. (agent 8be83b8)
* **Windows 11 25H2 Start menu renders as garbage / produces an error** (posts 44, 45). 25H2
  rebuilt the Start menu as a work-area-sized host window around a small card; the agent
  measures and crops to the card, and treats shell surfaces as a class rather than by hardcoded
  XAML class names. A geometry sanitiser also stops the agent ever announcing an invalid window
  size, which is what raised dom0's "invalid or suspicious GUI request" dialog.
* **Windows key with a third-party shell** (posts 49, 55). `enableWinKey` lets the Windows key
  reach the guest when a shell like Open-Shell is providing the Start menu (seamless only,
  default off; set the feature on the qube).
* Drag latency and wobble work, and the stock Start entry no longer appears in the qube's
  application menu when the guest hides Start in seamless mode.

## Hardened: the agent will not attempt a display change the IDD cannot accept

An IddCx adapter is enumerated as soon as its device starts, but has no mode list until its
monitor arrives - and the agent is started very early by the watchdog service. The topology
apply now waits (up to 20 s) for the IDD to publish a mode before touching anything, and if an
apply ever ends with no display attached it restores exactly what it detached.

Honest limit: the rollback could not be falsified on Windows 11. With the failure injected
deliberately, Windows 11 26200 refused to detach the last attached display at all
(DISP_CHANGE_BADMODE), so the state the rollback exists for was unreachable there. Whether
Windows 10 19045 enforces the same rule is untested - we have no Win10 rig that can run an
elevated install. The readiness gate is justified independently; the rollback is defence in
depth with an unproven PASS, and is recorded as such.

## Not fixed, and not diagnosed

* **"Black inactive window" after the IDD-activation reboot on Windows 10 22H2** (post 54).
  Reproducing it needs a Windows 10 guest running an elevated install, which this testbed
  cannot currently provide. `/noidd` and `/iddoff` are the answer for now, not a diagnosis.
* **AppVMs based on a Windows 10 template shut down silently just after startup** (post 56).
  Untested path - every test here uses standalone qubes. No template/AppVM run has been made.
* **PV disk driver upgrade crashes the VM** (post 27). Upgrades from stock QWT remain untested.
* `control.exe` still reports 4.2.2.0 in the installed-apps list (post 33). Cosmetic.
