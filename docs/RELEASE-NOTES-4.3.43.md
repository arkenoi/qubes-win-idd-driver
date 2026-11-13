# QWT-NG 4.3.43 — a stripped window is repaired, a StandaloneVM is told not to restart

## The shape of this release

Two changes a user can see. On Windows 11 24H2 and later, where a capture helper supplies window pixels, a window that stopped painting
right after QWT removed its Windows title bar could keep showing dom0 its picture from before, old title
bar included, shifted under a white band; the agent now repairs that itself, though the repair has not yet
been seen on a guest (section 1). On a StandaloneVM with its own internet route, Windows' own updates stay
on, but Windows is told not to restart the qube while a user is signed in, and the update pass warns, on any
kind of qube, if the policy in force would still let it (section 2). With them: the notification bridge starts nothing while the session is ending in seamless mode,
and in any mode stands down on an explicit Deny of notification access (section 3), the death notices for the capture
helper and the notification bridge no longer promise a restart that does not happen (section 4), and two
log lines lose a false warning level or a repeat (section 5).

The package changes the agent, the notification bridge, the updater script, the death reporter and the
updates relay.

---

## 1. Seamless mode: a stripped window that stops painting is repaired

On Windows 11 build 26100 (24H2) and later, the capture helper (the broker) supplies window pixels, and it
publishes a frame only at the size the agent last asked for. Removing a window's title bar changes that size.
The agent rejects a frame whose size no longer matches the window, and until this release it repaired such
a mismatch only when another rejected frame arrived more than 750 ms after the first; a window that stops
painting sends no second frame. Seen once, in pixels, on a German 25H2 guest: the window showed its pre-strip picture,
title bar shifted under a white band, and the agent's log shows no repair before the window was closed.

The agent no longer waits for that second frame. A tracking pass that finds the mismatch older than 750 ms
now flags it by itself, and the existing repair re-registers the window with the broker (`BROKERREREG`).
The first rejected frame arms one wake for the end of those 750 ms, which queues the window for such a
pass, so the repair runs even when nothing else on the desktop moves. A newly shown window whose broker slot still carries its previous window's size is treated as
waiting for its first frame, not as a mismatch, so it is not re-registered while it waits.

Measured on test builds of this release: on 4.3.43.1292 and 4.3.43.1293, a still window whose title bar was
removed showed correctly in both screenshots, with no repair line in the agent's log. On 4.3.43.1293 a
reused slot reported its previous window's size (3828x1017 for a 1115x628 window) 155 ms after that window
was registered, and the window showed live. **Not measured:** the repair itself. No run of a build that
carries it has held the condition - a frame cut for the old size, then no painting.

---

## 2. Windows Update on a StandaloneVM: on, without automatic restarts

The rule: on a StandaloneVM, Windows' own updates stay on and Windows must not restart the qube by itself;
on templates and AppVMs Windows' automatic updates stay off.

**On a StandaloneVM with direct internet, before turning automatic updates on**, the updater writes `AUOptions=4` and
`NoAutoRebootWithLoggedOnUsers=1`; if either write fails, automatic updates stay off and an ERROR is logged.
Templates and AppVMs keep `NoAutoUpdate=1`, as before.

**Then, on every kind of qube**, the update pass reads the Windows Update policy actually in force: the Group
Policy keys and device management's `PolicyManager\current\device\Update`. If it lets Windows install an
update and restart the qube by itself - Group Policy that installs without leaving the restart to the
signed-in user, device management's `AllowAutoUpdate` set to 1 to 4, an update deadline where updates are
not off, or no policy set anywhere (Windows' default) - the pass logs `WUAUTORESTART possible: <values>` at
ERROR and sends dom0 the notice "Windows may restart this qube by itself"; otherwise it logs
`WUAUTORESTART none`. An upgraded StandaloneVM that had already lost `NoAutoUpdate` warns while it boots
offline, until an online pass writes the two values; the warning is true, as a restart is possible once it
is online.

Measured on a test build of this release, on a retail Windows 11 26H2 StandaloneVM clone, offline: `none` as
installed; `possible` with device management's `AllowAutoUpdate=2` (an ERROR, one notice, acknowledged by
dom0's notification server); `none` again once that value was removed. **Not measured:** whether Windows
restarts a StandaloneVM by itself under these values. That needs a watch across Windows' overnight
maintenance window, and it is owed.

A scheduled scan that ends early - inside its 30-minute debounce, or yielding to a pass that holds the
updater's lock - now says so in the pass log. Task Scheduler discards console output, so these scans used to
leave no line at all, and a log could not tell them from a scan that never ran.

---

## 3. Notification bridge: nothing started into an ending session, and a Deny is obeyed

**In seamless mode, while the session is ending**, the bridge starts nothing of its own: a click on a notice
fails and says so, a relay reconnect waits for its next step, queued notices stay queued for the next start,
and the bridge's own notice is dropped. The agent likewise refuses its helper launches while the session is
ending, and skips its shadow-setting retry. Measured on test builds: at an ordinary seamless shutdown the bridge
declined to reconnect; under a cancelled session end sent to the agent by hand, a window opened 2.7 s in kept
its own title bar (the helper launch was refused), the cancel re-armed the helpers in 1 ms, and a window
opened after it was handled normally. No end that Windows itself cancels was driven.

**An explicit Deny of notification access now stands the bridge down.** On Windows 11 25H2, Windows granted
the bridge access over a user's or the device's Deny. The bridge now reads both before asking: on a Deny it
logs the refusal, sends that setting's notice once, records why it exited and exits, and the agent accepts
that and does not relaunch it. Measured on a clone of a German 25H2 template: a user Deny and a device Deny
each did exactly that, with no "not ready" error and no death record; a Group Policy or
device-management Deny refused as before, each with its 60 s ERROR; Allow armed the bridge. Turning either
toggle off in Settings writes the same Deny (measured through the Settings page itself).

---

## 4. Death notices that do not promise a restart

When the capture helper (`wgcbroker.exe`) or the notification bridge (`notifhost.exe`) died, the dom0 notice
said "Task Scheduler restarts it (up to three times)". Measured on 25H2, that never happens to a helper that
ran: Task Scheduler's restart-on-failure retries only a task that could not be launched. The notices now say
the helper is not relaunched until the GUI agent next starts, and that restarting the qube does that. The
agent's own notice texts, death records and log lines say the same.

---

## 5. Also in the package

- **Updates relay:** a connection cut at the end of a pass is logged at warning level only when it carried a
  request; an idle or discarded pooled connection is logged at info.
- **Agent:** a window whose desktop-composition bounds stay inverted is warned about once per window and
  rectangle, not once per polling pass.

---

## Verification

One full acceptance of this build, 2026-11-13 16:15 to 20:44 UTC (the two failproof suites run its
fault-injection twin, built from the same commit), then a re-run of three modules (and the package check) on a later
harness commit, 20:54 to 21:30 UTC. In the full run, two feature tests each lost a guest start - the guest did
not come back after a restart - while the storage pool's metadata stood near the limit at which new volumes
are refused; the start's own error was not kept, so the cause is not proven. In the same run the build being replaced
crashed in one upgrade cell. After the pool was cleaned and its metadata doubled, all three modules passed on
the re-run, and the acceptance record carries those results in place of the three failures, each failure
kept in it.

| what | result |
|---|---|
| build | `build-4.3.43.1294` = release-package run 43455532460 at `512c2952`, agent `414cbd1b87a0`, version 4.3.43 |
| package | `verify-release-package`: PACKAGE COMPLETE (version 4.3.43.1294), 14 gates passed, 0 skipped |
| CI at the build commit | every workflow run for `512c2952` succeeded: release-package 43455532460, build 43455532647, test 43455532241, qwt-full 43455532757, and the fault-injection build 43457189521 that only the failproof suites use |
| install matrix | all 8 cells - clean install, reinstall, in-place MSI upgrade from 4.3.35, and an AppVM derived from a template that carries this release, each on Windows 10 and Windows 11 - **89 checks PASS, 1 FAIL, 0 INVALID**, no rows lost (matrix run `20261113T161810Z-3045905`). The FAIL is the Windows 10 upgrade cell's log sweep, and it is the build being replaced: the 4.3.35 GUI agent crashed (exception 0xc0000409 in `ucrtbase.dll`) 1-2 s before the 4.3.43 installer's first log line, and dom0 was sent "The GUI agent crashed". That cell's other 13 checks passed, among them the installer's result (ok:true) and a check that the installed agent is the release binary. On the re-run (harness `67309b90`, matrix run `20261113T205753Z-3276654`, 20:57-21:05 UTC) the cell passed all 15 of its checks and its log sweep was CLEAN; 4.3.35 did not crash that time |
| feature tests | all 6 passed, supervision-gate and uac-on on the re-run. **updater-component** PASS: a clone of the reporter's German 25H2 golden was upgraded to the release package (12 checks passed) and matched every asserted fact of the reporter's environment; after one guest-side scan pass, all 8 updater gates passed. **notify-errors-guest-test** 12 passed, 0 failed. **crop-before-map** 2 passed, 0 failed: the agent mapped nothing uncropped, and 2 crop measurements prove the path ran. **template-update** PASS: a TemplateVM cloned from the reporter's German 25H2 golden matched every asserted fact of the reporter's environment and passed all 8 updater gates; dom0 then drove three update passes, each judged PASS, and the guest's pending count went 2 -> 1 -> 0. One offer was left out of all three, "Microsoft Corporation AudioProcessingObject Driver Update (1.0.4.55794)", and the suite measured that exclusion correct: its content was not self-contained in any of the three rounds, the Catalog has no package for its title (a control title resolved in the same run), and the template has no network route. **supervision-gate**: in the full run its guest did not come back from the first restart of the shutdown/boot cycles, and the three cells after it could not measure; on the re-run all 6 cells PASS - the package installs and the guest answers; the install's supervision receipts are in place; two clean shutdown/boot cycles had one agent per boot, no death or relaunch at a shutdown, no error during a requested stop, and zero dom0 notifications; a death injected during a shutdown was reported at the next boot exactly once, and the window around it held only that death; the log sweep found nothing new or breached. **uac-on**: in the full run its guest had no qrexec within 10 minutes of a cold restart; on the re-run 8 checks PASS, 0 FAIL, 0 INVALID - with UAC on (EnableLUA=1; the session user's token at the default run level read Medium, where it read High before the switch), the notification bridge was still the same process 65 s after it was ready, on the first boot with UAC on and on the boot after a shutdown with UAC on; the bridge task runs at Task Scheduler priority 4; a notice from SYSTEM was handed to the session, read, deleted and sent once; `--severity info` arrived as an informational notice; a notice sent from an elevated process was delivered once |
| remainder suites | run by the remainder gate on win11-acc and its own subjects, 19:05-20:44 UTC, merged per module into the build's coverage receipt. **gate-preflight** PASS: the control window survives the gate bit (1 window before, 1 after). **p3a-etw-gate** PASS: 31 rows = 25 PASS + 3 PASS-DATUM (drills the product could not be made to fail) + 0 FAIL + 0 ungraded + 1 attended + 2 untyped, status CLEAN; the attended row, the dom0 capture at the notice's forward, was read afterwards and shows the test's notice bubble. **toast-hold-test** PASS: 21 rows = 19 PASS + 0 FAIL + 0 ungraded + 2 untyped, status CLEAN; its non-seamless cells are opt-in and did not run. **log-sweep** PASS: CLEAN on win11-acc over 6 boots, no breach. **failproof-gates** PASS: with every safeguard in force all four window-gate cells were green; bypassing the two full-screen gate clauses (modes 1 and 2) turned the cell they guard red, and with it a second cell the suite declares as moving with that switch, while the other two stayed green; dropping captioned windows turned red only the cell that requires a screen-sized window with a title bar to be shown; with each safeguard restored, every cell was green. **failproof-faultinject** PASS: with nothing armed the capture checks were green; with the capture thread made to exit they went red; disarmed, they were green again - and the capture thread, looked up independently in the agent's process, read alive, gone, alive across the three passes |
| record and gate | the acceptance record for these ISO bytes (sha256 `176c3dd78579...`): `acceptance-record-check` rc=0, 7 cell-groups clean, 14 cells; it keeps the full run's three failures, each with the re-run campaign it passed in. The coverage receipt: 21 modules, all pass, none product-fail, none instrument-fail, none not run; `gate-scope.py check` over `v4.3.42-agent3212961..512c2952`: satisfied, 19 required, 21 covered. Every module carries `harness_dirty`: the harness checkout held an uncommitted change when its result was merged. Each time the checkout was read, at the re-run's launch and before this cut, the only uncommitted file was `mgmt/campaign-space.json`, which the campaign itself rewrites as its record of free pool space; it is not harness code |
| full release gate | `cut-release.sh` runs both checks above again on this build and refuses to publish if either fails, unless it is given an override with a written reason, which it then prints at the top of the published notes. Both checks pass, so this release is cut with neither override |

**Open items.** No FAIL or INVALID row in this acceptance names this build: the one FAIL was the 4.3.35 agent's crash, and the INVALID rows followed the two lost starts. Not measured: the stripped-window repair itself (section 1), and whether Windows restarts
a StandaloneVM by itself under the values this release writes (section 2). Still open in the product: a helper that dies stays down until the GUI
agent next starts (section 4). A Group Policy or device-management Deny of notification access is left to
the access check, and still logs its 60 s "not ready" ERROR (section 3).

---

## Upgrading

In-place MSI major upgrade from an earlier 4.3.x. Windows' automatic updates remain **off** on templates and
AppVMs, where dom0 drives every install; on a StandaloneVM with direct internet they stay on, and Windows is
told not to restart the qube while a user is signed in (section 2).

Upgrading from 4.3.35: in one of the three upgrades from 4.3.35 in this release's acceptance, on Windows
10, the 4.3.35 GUI agent crashed just before the installer started, and dom0 was sent "The GUI agent
crashed"; the upgrade then completed. What made it crash was not found.
