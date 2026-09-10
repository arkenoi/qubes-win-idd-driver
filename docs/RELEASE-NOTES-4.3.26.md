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

The inter-stage transition is a power-off, and a Qubes HVM is `on_poweroff=destroy`. Measured with an
instrument first proven to fail (a hard kill mid-write reports Kernel-Power 41/6008):

| | idle | ~2 GB of writes in flight |
|---|---|---|
| `shutdown /s /f` | clean 3/3 | **unclean 3/3** |
| host ACPI (control) | clean 3/3 | **unclean 3/3** |

Both arms fail together, so this is **not** a property of choosing power-off over reboot — the
variable is in-flight writes, and the transition happens straight after an MSI has been writing. An
unclean shutdown there hands the next boot a volume to repair, and Startup Repair is where a guest
has no qrexec, no `xencons` and no mapped window.

The installer now flushes the system volume and waits for the disk to go quiet before signalling S5.
**Honest limit:** the measured load is heavier than an MSI's tail, so this is a demonstrated hazard,
not a demonstrated cause of the post-install-reboot stalls seen during this work. Those remain open.

## What now notices these classes of failure

- `prev_shutdown_orderly` — Kernel-Power 41/6008 plus the NTFS dirty bit, asserted every run.
  Proven by injection; that injection also corrected its design, because on a genuinely unclean boot
  `fsutil` still read `NOT Dirty` and an fsutil-only check could never have fired.
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
