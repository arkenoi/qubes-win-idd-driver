# QWT-NG 4.3.36 — no more notifications about what happened before the last shutdown

Everything in 4.3.35 is carried forward.

**The change you will actually notice: a restarted qube stops telling you about things that are
already over.** When something of ours died, the reporter notified you - and after a reboot it read
the *previous* boot's backlog and notified you about those deaths too. So restarting a Windows qube
produced a burst of notifications about failures that had happened before the shutdown, were no
longer true, and that you could do nothing about. Worse, the same death record could arrive twice -
five minutes and one reboot apart - each announcing itself as the first death of that boot.

The reporter now mints a token that lives only for the running boot and reports only what happened
in it; the previous boot's backlog is not read at all. It also asks Windows whether it is shutting
down instead of inferring that from a task result, and the live path records what it notified so the
boot catch-up pass starts after it - so a record is reported once, across a reboot included. This is
the largest single change in the release: `guest/qwt-report-death.ps1` is 787 lines added and 116
removed, and 4.3.35 had none of the boot-boundary machinery.

## Notifications about the previous boot are gone

See above - this is the headline. Two things made the old behaviour worse than noisy: the backlog
was read on every boot, so one real failure could be re-announced after every restart until the
record aged out; and because the catch-up pass and the live path did not share a watermark, a record
the live path had already shown you could be shown again by the catch-up.

## The guest clock follows dom0

Windows treats an unset `RealTimeIsUniversal` as "the hardware clock holds local time". 4.3.35 already
**diagnosed** this - its installer logged *"Cause: RealTimeIsUniversal is unset, so Windows reads the
hardware clock as LOCAL"* - and then set nothing: no timezone, no convention.

4.3.36 acts on it. The installer reads dom0's `/qubes-timezone` and sets the guest's zone to match
(`Set-GuestTimeZoneFromHost`, new in this release), and a new per-boot script
(`guest/sync-clock-from-dom0.ps1`) measures what the RTC actually holds against what dom0 reports and
sets the convention from that measurement. It does **not** predict the convention from the qube's
features, which an earlier draft did and which is removed. If you set a timezone in a qube yourself,
the installer reports the override to dom0 instead of overwriting it silently.

**Scoped honestly, because an earlier draft of these notes was not.** Two things in this area were
*not* product changes and are not claimed as such: giving a qube `timezone=localtime` at creation is
done by our acceptance harness, not by anything shipped here; and the repeated per-boot clock
correction seen during testing was substantially the harness itself writing `RealTimeIsUniversal=1`
onto its own subjects, which is recorded as the root cause of that symptom. A 4.3.35 user did not
necessarily see a clock hours out - what they had was an unset convention and no zone propagation,
which is what this release addresses.

Measured on the acceptance campaign: `clock_boot_correction_s` is 0 on every cell that creates a
guest. One path - restoring a parked template for the reinstall cell - still shows a correction of
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

## A guest death is reported once, and only if it is this boot's

The companion to the headline. The live reporting path now records the record it just notified, and
the boot catch-up pass starts after it, so the same death cannot be announced twice across a reboot.

As with the deferral below: the campaign produced **no deaths at all** (`death_events = 0` on the
cell that originally showed the double), so this is in the build but not independently re-measured.
What *is* measured is the boot boundary itself - the per-boot token is minted into a volatile
registry key the kernel drops at shutdown, which is what makes "this boot" decidable without
trusting a guest clock.

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

## Known issue, now explained

A scan-only Windows Update pass can flip dom0's updates-available back to "available" shortly after
it cleared. **Diagnosed 2026-10-16 and it is not a defect in this package.** The guest's own status
file from the scan that did it names what it found: `count=1 offered=1 actionable=1 remaining=1`,
and the one item is `KB2267602` - a Microsoft Defender Security Intelligence update, version
1.461.56.0, flagged actionable with a download URL. Microsoft republishes those several times a
day, so dom0 was told the truth: an update really had become available in the minute since the
previous pass.

What this does invalidate is our own check: the acceptance suite asserts dom0's view must not change
across a scan, which cannot hold on any guest that receives Defender definitions. That makes
`template-update` fail intermittently for a reason that has nothing to do with the product, and it
is tracked against the harness as `UPDATESAVAILABLEOSCILLATES` rather than against this release.
