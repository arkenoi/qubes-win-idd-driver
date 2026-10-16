# QWT-NG 4.3.36 — the guest's clock tells dom0's time, a notification with no route is kept instead of dropped, and a death is reported once

Everything in 4.3.35 is carried forward. The largest change in this release is the guest clock: a
Windows qube used to be pinned to UTC and so showed the wrong wall-clock time for anyone not living
on it, and our own clock puller then corrected the same three-hour error on every boot. The qube now
takes dom0's timezone and the hardware-clock convention that goes with it. The notification route
keeps a message that has no way out instead of discarding it, says plainly when one is lost, and no
longer reports the same guest death to you twice.

## The guest clock follows dom0

A Windows qube's clock was set from a hardware clock we declared to be UTC, while the zone inside
the guest was left as the image shipped it. On a machine three hours from UTC that showed the wrong
time in every application, and the per-boot clock task then "corrected" the guest by the same
10800 s after every start — a correction fighting a cause rather than removing it. Worse, each of
those corrections wrote the emulated RTC, and on Xen a guest's clock write is persisted as a
per-VM offset that survives a restart, so the error was being fed back into the next boot.

The qube is now created with `timezone=localtime`, the installer propagates dom0's zone into the
guest, and the convention is settled late in the install where qubesdb is actually readable. If you
have deliberately set a different timezone inside a qube, the install says so in
`C:\qwt-improved-install.log` rather than changing it silently.

Measured on the acceptance campaign: `clock_boot_correction_s` is 0 on every cell that creates a
guest. One path — restoring a parked template for the reinstall cell — still shows a correction of
960-1080 s and is recorded as open (`REINSTALLCLOCKPHASE`); the live clock on that guest is correct.

## A notification with no route is kept, not dropped

A message our code raises for you has to reach dom0 through a relay that runs in your logged-on
session. Raised in the gap between the session bridge stopping and a session existing — at shutdown,
most often — the message was simply discarded, and the log could not say which one. It is now
written to disk and sent by the first process that genuinely has a route, exactly once: the reader
deletes the queue file only on a successful send, so a deferral cannot become a duplicate.

Read this one honestly: the code path is in this build and its offline tests pass, but **the
condition never occurred during acceptance**, so nothing here is a field measurement of the fix.
Two deliberate attempts to produce the gap failed, and both are recorded — being the SYSTEM account
is not enough, and logging the console session off is not enough either, because the relay connects
back through a named pipe that does not cross a session boundary.

Separately, a delivered notification's log line now declares what it delivered rather than only
that the send worked, and a fallback firing declares itself a warning instead of passing silently.

## A guest death is reported once

The same death record could be shown to you twice, five minutes and one reboot apart, each time
announcing itself as the first death of that boot. The live reporting path now records the record it
just notified and the boot-catch-up pass starts after it, so a record is reported once across a
reboot. The reporter also asks Windows whether it is shutting down instead of inferring it from a
task result, and no longer reads the previous boot's backlog — which was both misleading and more
than it was ever asked to do.

As with the deferral: the campaign produced **no deaths at all** (`death_events = 0` on the cell
that originally showed the double), so this fix is in the build but not independently re-measured.

## Smaller, user-visible

* Notifications are given a display time by kind: errors stay until dismissed, warnings 60 s,
  informational 20 s.
* Toast actions: seven fixes to the buttons a forwarded notification carries.
* The installer ships `get-image-rgba` rather than assuming it is present, after a guard found the
  fix shipping nowhere.
* `clock-sync` no longer reports our own not-yet-started pipe as a refusal from dom0.

## What was verified, and what was not

Verified on the acceptance campaign (release-package run 38889297394, package
`4.3.36+agent.7603457c1da8`, commit `8fe8828a51f7`):

* Eight cells — Win10 and Win11 × clean, reinstall, upgrade, appvm — with **no P1 breach**. 24
  breaches, all P2, every one attributed to an instrument or a test condition rather than to the
  product.
* Both dom0 callers aligned on six cells: `dom0 caller channel aligned (stdout, stderr, exit code,
  grandchild)` and `start-menu caller aligned`, plus `start-menu caller aligned FROM A COLD QUBE`.
* A complete Windows Update pass on the reporter's German 25H2 **template**: dom0's
  updates-available went `1` → empty, five hotfixes installed (build 26200.9711), exactly one
  reboot requested and performed, nothing excluded from what dom0 was told.
* A notification photographed on the dom0 desktop (`WITNESS=RENDERED`).

Not verified, stated so it is not mistaken for coverage:

* The notification-deferral and death-dedup paths above — the conditions did not occur.
* The full acceptance gate computes 18 suites for this diff and **five of them could not produce a
  verdict**, for instrument reasons: a missing build artifact, a log-slice boundary, a gate counting
  the test's own notifications, and two baselines that refused to attribute a later failure. This
  release is cut on the `core` set by owner decision; see `docs/ADR-acceptance.md` section 6, which
  records it as an override rather than as the gate being met.

## Known issue

On a fully updated guest, a scan-only Windows Update pass can flip dom0's updates-available back to
"available" after it had cleared. The cause is not established — it may be a genuinely newly
applicable update, or our scan reporting work that is not actionable — and the instrument now
captures the guest's own counts at the moment it happens so the next run can say which.
Tracked as `UPDATESAVAILABLEOSCILLATES`.
