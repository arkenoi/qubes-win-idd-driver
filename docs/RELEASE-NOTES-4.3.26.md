# QWT-NG 4.3.26

The secondary error-notification route has never delivered a notification, in any release, until
this one. It reported success the whole time. Everything else in these notes exists because that
was possible.

## The error-notify route now reaches the screen

`Send-QwtError` returns `send` as soon as `notifhost.exe` is *launched* — it deliberately does not
wait. `notifhost` then reaches dom0 by spawning a relay through `qrexec-client-vm`, passing
`GetUserNameW()` as the local-user field. Run as **SYSTEM**, that field is `SYSTEM`, the relay
never connects back, and the send fails with `relay never connected` — while the caller has already
been told `send`.

Every real caller is SYSTEM: `gui-agent` is a service, and `activate-idd.ps1` / `deactivate-idd.ps1`
run from the installer. So the route was inert in the only context it ships in, and its test suite
was fully green over it.

`notifhost` now detects that it is not running as the console user and re-runs itself in that user's
session via the Task Scheduler — the mechanism the agent already uses for `wgcbroker.exe`, 8.3 short
path included, because `schtasks` parses `/tr` by whitespace and the long path has spaces.

Measured on one guest, same binary, same minute, the account being the only variable:

| caller | `bridge.log` | screen |
|---|---|---|
| SYSTEM | `relay never connected` | nothing |
| console user | `connected` → `FWD_RTT ok=1` → `sent ok=1` | bubble photographed |

**A first diagnosis of this was wrong and is worth recording.** The two arms originally compared
differed in *both* session and account, and the difference was attributed to the session. The
resulting fix compared sessions — and qrexec-agent runs guest commands as SYSTEM *in* the
interactive session, so the sessions match, the handoff no-opped, and delivery still failed. The
account is the discriminator.

## Errors survive a fast reboot

Boot identity was `wall_clock - uptime` compared with a ±120 s tolerance. Consecutive boot stamps
differ by the previous boot's uptime plus its downtime, so a guest that reboots soon after booting
mints stamps only tens of seconds apart — and the tolerance then called two real boots one,
suppressing the second boot's ACTION error as a duplicate and carrying the per-boot cap across.

Measured: a real reboot **73 s** apart collided and swallowed the error; one **373 s** apart did not.
73 s is not a corner case — it is the chained Windows-update reboot, the situation this route exists
to report on.

Boot identity is now an opaque token minted once per boot in a **volatile registry key** — the
kernel discards it at shutdown, so the key's existence *is* the boot. No clock arithmetic, so
nothing drifts and nothing moves when the host clock is pushed into the guest. Comparison is exact.
`HKLM\SYSTEM\CurrentControlSet\Control\Windows\BootId` was the obvious candidate and is **missing**
on Win11 — checked on a guest before designing on it.

Both twins address the key through the 64-bit view: `HKLM\SOFTWARE` is WOW64-redirected, and a
32-bit PowerShell host would otherwise mint its own token under `Wow6432Node` while the x64 agent
used the native key — two ideas of "this boot", with no symptom.

## Toasts and menus are cropped before they are shown

`CROP_BEFORE_SHOW_TIMEOUT_MS` was a flat 400 ms while one UIA operation was allowed 500 ms, so a slow
crop could never make the budget and the window was mapped uncropped — shadow strip visible, then
snapping. The budget is now **derived** from `TOAST_CROP_UIA_TIMEOUT_MS`, so the invariant "the
budget outlasts one UIA operation" cannot be broken by editing one file.

The fallback also fired **silently**: only `held_ms` encoded it, indirectly. It now logs
`QGACROPLATE` naming the window and the class, so an uncropped map is greppable instead of inferred.

## The installer flushes before it powers off

> **RETRACTED 2026-09-10 — the measurement that motivated this section was void, and this
> section previously published it as fact.** It reported "unclean 3/3" under load in both arms.
> That reading came from a probe windowed as
> `StartTime = LastBootUpTime.AddMinutes(-20)` with no end bound and no timestamps recorded,
> while rounds ran four to five minutes apart and a deliberate hard-kill injection — which
> writes exactly one Kernel-Power 41 and one 6008 — had run two minutes before the first round.
> The probe printed the ids of *every* match, and all six loaded rounds printed exactly
> `events:41,6008`: two events. A round that had produced its own marker would have shown four
> ids, then six. The count never grew, so **zero of the six loaded shutdowns logged a new
> marker**. Re-measured with each round scoped to a stamp taken from the guest's own clock:
> **0 of 6 loaded shutdowns unclean** (two load shapes, including a writer verified still growing
> at 1.7–2.7 GB per 10 s at the instant of shutdown), 0 of 6 idle, and no boot-disk storage
> complaint in any round. There is also an architectural reason it could not have been what was
> claimed: a write xenvbd has acknowledged cannot be lost while dom0 stays up, because blkback
> responds only after the bio has completed and that data is then in dom0's block stack, which
> outlives the guest.
>
> **What still stands:** a guest *hard-killed or destroyed* mid-write genuinely does come back
> unclean — that is what the injection shows, and it is why every wedge specimen that was killed
> came back into Startup Repair.
>
> **The change itself is kept and is not being reverted.** Flushing the system volume and waiting
> for the disk to go quiet before signalling S5 is cheap and defensible on its own terms. But it is
> a precaution against an **unconfirmed** defect, not a fix for a demonstrated one, and it should
> never have been published as the latter.

The inter-stage transition is a power-off, and a Qubes HVM is `on_poweroff=destroy`, so the installer
flushes the system volume and waits for the disk to go quiet before signalling S5.

## What now notices these classes of failure

- `prev_shutdown_orderly` — Kernel-Power 41/6008 plus the NTFS dirty bit, asserted every run.
  **Correction 2026-09-10:** "proven by injection" was false of *this* check — the instrument the
  injection validated was `shutdown-cleanliness.sh`'s own probe, which windowed differently. This
  check queried `EndTime = LastBootUpTime`, a window that *ends* at boot, while 41/6008 are written
  early in the **current** boot — so it could never fire, and had been passing for something it was
  structurally incapable of detecting. Fixed to start 30 s before boot with no end bound (30 s and
  not minutes, because a reboot cycle here is 45–60 s and a wider window would report the previous
  boot's markers as this cycle's). It now also records each event's offset from boot and reads
  Kernel-Power 41's `BugcheckCode` **by name**, which separates a shutdown-phase crash from a power
  cut — the two are otherwise indistinguishable from dom0 under `on_reboot=destroy`.
  The NTFS dirty-bit half remains a check that cannot fail on its own: on a genuinely unclean boot
  `fsutil` still read `NOT Dirty`. The per-mount NTFS volume-health verdict (event 98) was added
  alongside it as the one signal here that positively asserts a clean volume and can still say
  otherwise.
- A **dom0 render witness** — the notify suite now ends on a photographed bubble and cannot pass on
  an ack. It took three corrections to get right: whole-screen density (ambient churn on a busy
  desktop matches a bubble), persistence (a bubble auto-dismisses), and finally region-local ambient
  with an *asserted* notification-free baseline.
- The campaign's post-install reboot is now **driven**, not inferred from "something answered", and
  the one-guest-at-a-time guard polls instead of giving up early and continuing anyway.

## Verified

Full acceptance on the published ISO: **8 cells** — clean, reinstall, upgrade and appvm on both
Win10 and Win11 — `product-FAIL=0`, `INVALID=0`, plus the two feature suites (notify-errors 11/0
including the render witness, crop-before-map 2/0).
