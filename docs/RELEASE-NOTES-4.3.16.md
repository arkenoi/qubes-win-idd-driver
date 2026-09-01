# QWT-NG 4.3.16

Built from `6022427bd0ab` (agent `4f1c1865351e`). MSI ProductVersion **4.3.16** — a real bump over
4.3.14, so an in-place MajorUpgrade lands on an existing guest without an uninstall.

## What changed since 4.3.14

**System dialogs no longer arrive without a dom0 border.** `IsPopup()` treated any caption-less
window as an override-redirect popup unless it carried `WS_SYSMENU` *and* `WS_EX_APPWINDOW`. Windows
Update's dialog (`MusNotificationUx`, class `Shell_SystemDialogProxy`) sets `WS_EX_APPWINDOW` but not
`WS_SYSMENU`, so a full system dialog reached the display undecorated — no trust border. A
taskbar-declaring, activatable, non-toolwindow top-level window is now treated as a real window.
Inline app popups are untouched: dropdowns, context menus and tooltips never request a taskbar
button, verified against every window on a live guest (`Net UI Tool Window` `0x00000088`,
`SCENIC_DROPSHADOW_WINDOW_CLASS` `0x08180028`, and others — none carries `WS_EX_APPWINDOW`).

**dom0 focus is honoured under foreground lock.** `HandleFocus` called `SetForegroundWindow` and
ignored its result. That call silently fails when another process owns the foreground, so dom0 could
ask for focus and the guest would quietly refuse — which looked like a modal dialog blocking the
desktop, though nothing was `WS_DISABLED`. It now attaches to the foreground thread's input queue,
retries, always detaches, and logs when focus still cannot be taken.

**`MSG_CROSSING` (127) is handled.** Every pointer enter/leave previously hit the dispatcher's
default branch and wrote a warning — file I/O on the input path at roughly ten lines per second. It
also releases a drag latch that could otherwise stick if a button release was lost.

> **RETRACTED 2026-09-01 — the second sentence describes a DEFECT, not a feature.** Releasing the
> drag latch on a `LeaveNotify` tears down the guest-native drag mid-gesture: measured on a hand
> drag, 569 ms into a 5.0 s drag a genuine `NotifyNormal` crossing dropped the latch and the
> following 489 of 490 motion events fell back to the live-origin translation, i.e. the gain-1
> oscillator, with window-path reversals going 8 % → 20 % and announced positions swinging
> ~1600 px at 15 Hz. That is the drag wobble. The latch release was never requested, was not
> measured, and closed a hole `INPUT_DRAG_STUCK_MS` had already closed 17 days earlier. It is
> deleted in **4.3.17**; the log-flood half of this item stands. See `docs/RELEASE-NOTES-4.3.17.md`
> and the 2026-09-01 entries in `findings/drag.md`.

**The PV console (xencons) ships and binds.** `XENBUS\VEN_XP0001&DEV_CONS` sat at CM code 28 on every
guest because QWT vendored no xencons at all. It is now built from a pinned xenbits commit,
test-signed with the rest of the package, and installed — giving dom0 an out-of-band channel into a
guest whose qrexec, window capture and event log have all stopped.

**xenvif is pinned.** The build cloned xenbits `master`, so the kernel-mode PV NIC driver in a
release was chosen by the wall clock and two builds of "the same" version could carry different
driver code. Pinned to `0c61248`, with the rev-5 assertion still guarding a future bump.

**Installer and packaging:** all MSI driver catalogs are signed and verified at build time (four of
five were shipping unsigned, which is what turned an install into a 27.9-minute hang); the PV NIC
priming latch is seeded unconditionally, StandaloneVMs included; the network "discoverable setup"
prompt is suppressed; a same-version reinstall that leaves no gui-agent is recovered with an
ADDLOCAL-only retry; and the watchdog reports `SERVICE_STOPPED` on `PRESHUTDOWN` instead of stalling
every clean shutdown for about three minutes.

## What was actually tested — and what was not

Campaign `20260830-062519`, **36 checks, 0 failures**, on this exact artifact, from sealed goldens
checked before and after, with one Windows guest running at a time:

> **Correction (2026-08-30), and it weakens the sentence above.** Those golden checks compared
> volume *size* and qube *properties* only. `mgmt/golden.sh` read the revision list — the signal
> that actually detects a golden having been booted — by shelling out to `qvm-volume revisions`,
> a subcommand that does not exist in this client; the failure was swallowed and every seal
> recorded `revisions: []`. So "verified intact" could not have caught a boot, which is the exact
> modification the tool exists to catch. Fixed and re-proved on real revision data. Nothing here
> is known to have been contaminated — but the custody evidence for this campaign is weaker than
> this document originally claimed, and that is stated rather than quietly repaired.

| Path | Result |
|---|---|
| Same-version reinstall, Win10 + Win11 | 7/7 each — agent hash == release, no reboot dialog (watcher proved it sampled), PV console bound, autologon armed, `xenbus_monitor` disabled and not running |
| Seeded pending-reboot condition, Win10 + Win11 | 8/8 each — monitor armed to auto-start and a reboot Request written mid-MSI; both guests returned, suppressor held |
| AppVM cold boot, Win10 + Win11 | 3/3 boots each, windows mapped, none fullscreen-sized |
| Clean install (two-stage), Win10 | graded 9/0 separately on pristine media — both stages, two run ids, `testsigning_active:false` precondition, CONS/IFACE/VBD bound |
| Network | 25 MB transferred on both AppVMs, each adapter's own RX counter accounting for it, PV NIC the only adapter present |

**NOT tested, stated plainly:**

- **Upgrade over a previous QWT-NG release.** The goldens were built from this same release, so those
  cells took the same-version-reinstall branch rather than a major upgrade. The in-place upgrade path
  is unverified for this build.
- **Upgrade over stock QWT 4.2.2.** Not demonstrated.
- **Clean install on Windows 11.** Only Win10 was graded on pristine media.

Ship it on that basis: it is better than 4.3.14 on every path that was measured, and two upgrade
paths are unmeasured.
