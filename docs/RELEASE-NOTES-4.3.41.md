# QWT-NG 4.3.41 — a guest with UAC on

## The shape of this release

Every product fix here answers a report from the field (Qubes forum thread 42717), and almost all
of them share one cause: **the reporter runs Windows with UAC enabled, and every guest our test rig
builds has UAC disabled.**

With UAC on, Windows gives an administrator's logon two tokens. The desktop session runs on the
*filtered* one, which holds the Administrators group as deny-only; a process started "as
administrator" holds the *elevated* one. Our SYSTEM-side components and our session-side helpers
hand files and pipes to each other, and several of those handoffs silently assumed that the session
user could delete, replace or open what the other side had created. With UAC off that is true, so
no automated run ever met the failure. With UAC on it is false, and the result was a notification
bridge that vanished after the first reboot and dom0 notifications that arrived twice.

One access list changes in this release: the notice files a SYSTEM sender writes for the session
user (section 1) may now be deleted by the interactive user, because that delete is how the notice
is acknowledged. No pipe, no service and no other file is opened wider than before.

---

## 1. Notifications on a guest with UAC on

**Every notification sent from SYSTEM arrived twice.** A notice from a SYSTEM component is handed to
the logged-on user through a file in `%ProgramData%\qubes-toast-bridge`; the reader deletes the file
and that delete is the acknowledgement. The filtered token could read the file and could not delete
it, so the sender took the notice for unread and sent it again itself. In the reporter's logs that
was 33 of 33 handoffs. The handoff and deferred files are now created with an explicit descriptor —
SYSTEM full, Administrators full, INTERACTIVE read and delete — and the reader logs a delete that
fails.

**The notification bridge was gone from the second boot on.** The agent writes a `stop` file when it
exits, as SYSTEM, and the bridge used to delete a leftover one when it started — as the session
user, which with UAC on it cannot. So every bridge after the first boot read "stop requested" a few
seconds after starting and exited cleanly, and nothing said so. The agent now removes its own
leftover `stop` file at start.

**Turning UAC on later broke the bridge in a second way.** A guest that had run with UAC off left a
`heartbeat` file owned by the Administrators group; after UAC was turned on the new bridge could
read it and could not replace it, so the agent kept reading the previous boot's process id and
reported that no bridge had started — while one was running. `exit-reason` had the same shape. The
agent now retires all three leftover state files (`stop`, `heartbeat`, `exit-reason`) before it
launches the bridge. `service.uac-disable` is documented as reversible, so this is a path a user
reaches through the product.

**An informational notice arrived as an error.** The kind a caller gave (`--severity info`) was not
carried across the SYSTEM-to-session handoff, and a notice with no kind is shown as an error, which
stays on screen until dismissed. The one product caller is the notice that the Start menu was closed
in seamless mode. The kind now crosses the handoff.

**At every logon the bridge reported its notification source missing.** The bridge takes
notifications from an event-tracing proxy that the GUI agent launches a few seconds after logon. The
bridge allowed it one 2-second wait, then logged a warning that the source was absent and read
notifications through its fallback path until its next attempt, 5 s later (measured: 4 s on our rig,
11 s on a first boot after an upgrade). Our acceptance graded that warning as a failure. For its first
30 s, while the proxy has never connected, the bridge now treats a missing proxy as the normal startup
order: one informational line, and another attempt every 2 s, so it connects within 2 s of the proxy
appearing. After the first connection, or after 30 s, a missing proxy is a warning as before. The
extra attempts are at most 15 failed opens of a named pipe in those 30 s, each followed by a wait.

**A notice from an elevated process was not delivered until the next boot.** A process started "as
administrator" passed the test "am I the logged-on user, in the console session" and tried to send
directly; the relay that `qrexec-agent` starts for it runs on the session's filtered token and never
connected, so after 15 s the notice was queued for the next bridge start. That defeats the notice
section 2 adds, and every error notice of an install run by hand. A sender holding the elevated half
of a split token now takes the same session handoff a SYSTEM sender does, and the relay says why
when it cannot open a sender's pipe.

---

## 2. A manual install says that it has finished

When an install needs a restart, the installer does not restart the GUI agent, and by then the
emulated display adapter is already disabled: the qube shows a frozen window (fresh install) or no
windows at all (upgrade) until it is restarted. Run by hand, the installer's "INSTALL COMPLETE" went
to a console nobody could see. A run without `/auto` that ends this way now sends one dom0
notification — **"The tools install is complete - restart this qube"** — and logs an error if it
could not. README step 4 describes what you will see.

---

## 3. Session helpers

**The helpers ran at background priority.** The capture broker and the notification bridge were
registered with Task Scheduler's default priority 7, which is below-normal CPU with low I/O and
memory priority. They are registered at 4 (normal) now. On Windows 11 the broker supplies every
window's pixels and has to answer the agent within two seconds.

**"The capture helper is not running" was sent while the helper was still starting.** In the
reporter's logs the helper needed 16 to 58 s to become ready on a two-vCPU guest, and the 30 s
report went out in 6 of 10 boots, each time followed by the helper becoming ready by itself. A
helper that was launched, has never been ready, has no death on record and whose process exists is
now held once, with a warning, and reported at the next deadline if it is still not ready. A helper
with no process is reported at 30 s exactly as before. The ready line now records how long after
the launch ready came, the helper process's age and its CPU time.

---

## 4. Updater

The Microsoft Update Catalog answers a search in more shapes than "results" and "no results": it
also serves its own error page, and a results page with an empty container. Both were read as "the
Catalog has no package for this update", a class dom0 leaves out of the pending count it shows. Only
a page carrying the results table or the Catalog's own no-results element is believed now; anything
else leaves the update in the pending count and is asked again on the next pass.

---

## 5. Logging

dom0 and the guest are not synchronised, so dom0 can send focus or a resize for a window the guest
destroyed a moment earlier. That was logged with the same warning as a live window the tracker had
lost. A handle that is no longer a window is now informational; a live untracked window stays a
warning.

When the qubesdb service stops, its server disconnects every client itself, and a client's own thread
can ask for the same disconnect a moment later. That second request was logged as a warning
(`QpsDisconnectClientInternal: [N] not connected`); it changes nothing, and it is now informational.
Our acceptance found it on a reinstall, where it failed the cell's log check.

---

## 6. A notification queued behind another one

**A notification that arrived while another was on screen could be lost.** Windows shows its banners
in one window and paints a queued notification into that same window when the previous one's time
is up. The agent learns what a banner shows by reading it, and it read only when something prompted
it - the banner appearing, or Windows reporting that it moved or was renamed. At that in-place
repaint nothing reliably does. When the first notification had been forwarded to dom0, so the
guest's banner was hidden, a second one that belongs in the guest's own banner stayed hidden: it was
never seen. While a newer notification is queued behind a banner, the agent now reads the banner
again every half second, and decides for the new content exactly as it does for a new banner. It
stops when the queued notification has been decided or the banner is gone, and never reads while
nothing is queued. Windows' own display settings are neither read nor changed: notifications that
stay in the guest's banner keep the display time, order and persistence Windows gives them, and any
number of them queued behind each other is covered.

---

## 7. Component-death notifications after an install

**An install made within a few minutes of a boot could switch off the notifications that tell dom0 a
component of ours died.** Those notifications come from a task that runs a small script whenever
Windows records such a death; a second task runs the same script once, 90 seconds after every boot.
The installer replaces that script, and when the boot pass happened to be reading it at that moment
the copy failed and neither task was registered: from then on a crash of the GUI agent, a helper or
one of our services reached the guest's own log only, never dom0, until the next install. Our own
acceptance found it, on a reinstall. The installer now switches both tasks off, waits until neither
is running (at most 60 s), replaces the script and registers both again. If a run is still going
after 60 s, the install says so instead of copying anyway, and both tasks are switched back on in
every case. Installing this release re-registers both on a guest that lost them.

---

## Verification

| what | result |
|---|---|
| build | `build-4.3.41.1272` = release-package run 43099265433 at `721f26e7`, agent `355e7fca4960`, version 4.3.41 |
| package | `verify-release-package`: PACKAGE COMPLETE (version 4.3.41.1272), 14 gates passed, 0 skipped |
| CI at the build commit | every required workflow green for `721f26e7`: build.yml 43099265196, test.yml 43099265198. The runs sat queued for about ten minutes during GitHub's Actions incident of 2026-11-11 (20:48Z) and then ran unchanged; the fault-injection twin used only by the failproof suites is run 43099280974 |
| install matrix | all 8 cells - clean install, reinstall, in-place upgrade from the previous release, and an AppVM on an upgraded template, each on Windows 10 and Windows 11 - **89 checks PASS, 0 FAIL, 0 INVALID**, no rows lost (matrix run `20261112T002452Z`, 00:24-01:29 UTC). Per cell: clean 16 + 16, reinstall 12 + 12, upgrade 13 + 13, AppVM 3 + 3 (Windows 10 + Windows 11), plus one campaign row: the cold dom0-caller path was measured on both OS families. Both arms of the log-volume smoke passed first: with no volume the binder refuses, with one the guest sees it and a nonce written inside reaches the image read back with no guest |
| feature tests | **updater-component** PASS: the German 25H2 guest of the reporter's environment upgraded 4.3.29 -> 4.3.41 from the release disc (12 checks), then all 8 updater gates passed - the relay is the shipped binary, listens on 8082 and was started by the pass itself, the scan reported its count to dom0, and nothing the guest proved installed was offered to dom0 again. **notify-errors-guest-test** 12 passed, 0 failed: on by default and off when switched off, a healthy guest sends nothing, a duplicate in one boot is suppressed, a DEGRADED severity and a credential-shaped summary are refused, the same error is sent once more after a proven reboot, and the notification was photographed on the dom0 desktop. **crop-before-map** 2 passed, 0 failed: no window was shown before it was cropped, with 4 crop measurements proving the path ran. **supervision-gate** all 6 cells PASS: the package installs and the guest answers (13 checks); the install's supervision receipts are in place (event source, the one death reporter's subscription, the Task Scheduler log, running as SYSTEM); a clean boot and shutdown has one agent per boot, no death, no relaunch, no error during a requested stop and zero dom0 notifications; a death during a shutdown is reported at the next boot exactly once, and the window around it holds only that death; the log sweep finds nothing new. **template-update** PASS (re-run 08:37-09:48 UTC on the same package, after a harness fix, together with the win10-clean cell, which passed again): a TemplateVM cloned from the reporter's German 25H2 golden matched every recorded fact of the reporter's environment, was upgraded 4.3.29 -> 4.3.41 from the release disc and passed all 8 updater gates; dom0 then drove three update passes the way Qube Manager does, and every pass was judged PASS - KB5007651 and KB890830 installed in the first, KB4052623 installed and KB5132061 staged in the second and completed by the restart the guest asked for, and the guest's pending count went 2 -> 1 -> 0. The one offer the updater left out, "Microsoft Corporation AudioProcessingObject Driver Update (1.0.4.55794)", which has no KB number, was measured to be correctly left out: the Catalog has no package for its title, the update agent's offer for it carried no content in any of the three passes, and the template has no network route. The module's first two runs in this acceptance could not measure the middle fact, because after the restart that completed KB5132061 the update agent's offer list was empty when the harness read it; the harness now records each offer's revision and takes the same content-free offer from another pass's read, and on this run, with that read empty again, it measured it. |
| remainder suites | run by the remainder gate on win11-acc and its own subjects, 02:59-04:06 UTC, merged per module into the build's coverage receipt. **gate-preflight** PASS: the control window survives the gate bit (1 window before, 1 after), so a "nothing mapped" verdict means something. **p3a-etw-gate** PASS: 31 rows = 25 PASS + 3 PASS-DATUM (drills the product could not be made to fail) + 0 FAIL; the event-tracing notification source is primary and the database fallback keeps routing while it is down; the dom0 desktop captured at the forward was read by hand and carries the bridged notification ("A0T p3a-bridged"). **toast-hold-test** PASS: 19 PASS, 0 FAIL, on the release binary (identity proven against the reference); the whole-desktop round trip S5 is opt-in and was not run. **log-sweep** PASS: no breach, no new defect, no missing data. **failproof-gates** PASS (re-run alone 05:09-05:50 UTC on the fault-injection build of the same commit, after a harness fix to its precondition step): with every safeguard in force all four window-gate cells were green; bypassing the two full-screen gate clauses (modes 1 and 2) turned exactly the two cells they guard red - a screen-sized override-redirect window and a borderless one reached dom0 - while the other two stayed green; dropping captioned screen-sized windows turned exactly the cell that requires them to map red; each came back green with the safeguard restored. The checks that grade full-screen behaviour are proven able to fail, one clause at a time. **failproof-faultinject** PASS (re-run alone 06:02-06:17 UTC, after two harness fixes): with nothing armed the capture checks were green; with the capture thread made to exit they went red; disarmed, green again - and an independent witness, the capture thread itself looked up in the agent's process, read alive, gone, alive across the three passes, so the red is the condition and not a side effect of the check. The suite's earlier failure in this acceptance came from its old witness, not the product: it required dom0's view to stop changing after the capture thread exited, but a change that comes with a window event still reaches dom0 through the agent's main thread, so that witness could never be earned. |
| full release gate | enforced by the cut itself: `cut-release.sh` refuses to publish without a CLEAN acceptance record for these exact ISO bytes and a coverage receipt that satisfies `gate-scope.py` for this diff |

The install-race fix of section 7 was also proven on its own before the run: under our own boot pass
holding the script, the 4.3.40-era registration failed "being used by another process" and the fixed one
waited 19.9 s and registered; a hold longer than the 60 s limit was reported as a failure with both tasks
switched back on.

**Open items:** none. No FAIL or INVALID row in this acceptance names the product. Three modules were
measured a second time because the harness, not the product, could not measure them the first time -
failproof-gates, failproof-faultinject and template-update - each re-run on the same package after its
harness fix, as above; the acceptance record keeps template-update's first result beside the re-run that
superseded it.

---

## Upgrading

In-place MSI major upgrade from any 4.3.x; the acceptance's upgrade cells are that path. Automatic updates
remain **off** in the guest by design; dom0 drives every install. Installing this release re-registers the
component-death notifications on a guest that lost them (section 7).
