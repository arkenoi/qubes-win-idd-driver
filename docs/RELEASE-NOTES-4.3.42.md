# QWT-NG 4.3.42 — a failure says why

## The shape of this release

Most of this release is about what a failure tells you. The reporter on the Qubes forum (thread 42717)
received "The Windows Update scan task failed - incorrect function" in dom0 at every boot of 4.3.37 and
4.3.38, and nothing in that notice pointed anywhere. 4.3.42 removes a cause of that same notice which
4.3.40 and 4.3.41 carry - not the reporter's, whose cause is still unknown (section 1) - and makes the
notice quote the error the update pass recorded when there is one, and give the exit code a plain meaning
when there is not (section 2). A refused notification listener now names the setting that refuses it, or
says that none of the settings it reads does. Two runtime fixes ship with them: on Windows 11 24H2 and later the
capture helper is no longer ended the first time it is slow to answer, only if it is still stuck 6 s
later (section 3), and a guest shut down before a
daylight-saving change and started after it has its clock set right at boot instead of running an hour
off (section 4; measured on a test build of the change, for the autumn change).

The code this release changes in the package is four guest-side scripts and programs, the agent and the
core agent. A scan of every line it adds finds new privileged calls in `bind-dirs` only (next sentence).
Everywhere else it adds no file or registry write and no pipe, service, qrexec or access-control call;
what it adds are reads: the death notice reads the updater's own status file, the notification bridge
reads four policy and consent values, and the health check reads a volume flag and event-log records by
ID. The one new privileged action is the daylight-saving
correction in `bind-dirs`: it opens the time-zone key for writing, sets the system clock at most once
per boot before any service starts, and writes the zone's `ActiveTimeBias` only if it still differs from
the corrected bias after that set (no measured boot has needed that write).

---

## 1. Updater: a clock correction no longer ends the pass

An update pass compares the wall clock with its own timer each time it saves its status, and logs a
warning (`QWTUPDCLOCKJUMP`) when the two disagree by 30 s or more. When that happened at the pass's
first save, the warning went to the wrong logging function, because the pass's own was defined further
down the script, and the call failed. Since 4.3.40 the script stops on such an error: the pass exited 1,
which Task Scheduler records as 0x80070001 and the death notice reports to dom0 as "The Windows Update
scan task failed", and no `update-status.json` was written. The pass's logging function is now defined before the first save; the
warning is logged and the pass goes on. A status file that cannot be written is now logged as well; it
used to be lost without a trace.

Only 4.3.40 and 4.3.41 end the pass this way: the clock check and the stop-on-error rule both arrived in
4.3.40. 4.3.37 to 4.3.39 had neither, so this cannot explain the reporter's 4.3.37/4.3.38 failures, whose
cause is still unknown. Section 2 is how the next one will name itself.

Measured on the updater's own code under PowerShell 7.6, with the wall clock forced 100 s ahead of the
pass's timer: the 4.3.41 order ended the pass with exit 1 and wrote no status; the new order logged the
warning, wrote the status (`clock_jump_s` 100.0) and exited 0. On guests the update tasks run under
Windows PowerShell 5.1, and there the moved code ran the passes of this release's two updater tests to
their end: the updater test passed all 8 of its gates on the reporter's German environment, and three
update passes on a template in that environment were each judged PASS (see Verification). The
clock-jump branch itself was driven only under PowerShell 7.6.

---

## 2. Notices that name their cause

**An update task's failure quotes the error its pass recorded.** When one of the three update tasks -
scan, full run, download - failed, the dom0 notice gave only a general cause for its exit code (for exit
code 1, "incorrect function" until this release; see below). The pass had usually written the reason a
few seconds earlier: a pass that ends on an error it
caught records it in `C:\ProgramData\Qubes\update-status.json` before it exits. The notice now says
"Cause: the pass recorded this error: ..." with that error cut to 160 characters, but only when the
record is this run's: its action is the failing task's own, its phase is an error, and it was written
between 120 s before and 5 s after Task Scheduler recorded the failure. Anything else keeps the general cause. The
notice's detail names the status file and the updater's log. An error text that the notice route would
redact is left out, so it cannot suppress the notice itself.

**0x80070001 no longer reads "incorrect function".** Task Scheduler records a script's exit code 1 as
0x80070001, and the notice gave that code its Windows text: every scan-task notice on the reporter's
4.3.37/4.3.38 said "Cause: incorrect function." Where no recorded error applies, it now reads as what it
is: "the script reported a failure or an unhandled error". A task that could not be started at all keeps its own meanings
(0x80070002 is still "the file was not found").

Both were checked by loading the reporter the way its render tests do, under PowerShell 7.6 and again
with the status stamp read as a string, as Windows PowerShell 5.1 reads it: the same run's error on the
scan task, and the run and download tasks over their own records, were named; a record 600 s old, a
finished phase, a missing file, another task, and the run task over a scan pass's error of the same
second kept the general cause. These were one-off probes: the reporter's committed suites still pass
(`death-reporter-test` 235 checks, `notify-render-test` 798 checks, none failed), but neither has a case
for either change.

**A refused notification listener names what refuses it.** The notification bridge reads the guest's
notifications through Windows' notification listener, which a policy or a privacy setting can deny; the
reporter's Windows 10 guest was refused at every boot, and no log said why. The notice blamed the user's
privacy setting for every refusal. The bridge now checks, in the order Windows applies them, group policy
and device-management policy (`LetAppsAccessNotifications` = Force Deny), then the device-wide and the
user's notification-access consent, and names the first that denies. If none does, the notice says so
and asks for a bug report. It is still one notice per boot, and the bridge's log line carries every value
it read. The four notice texts passed the agent's render test, run by hand (378 checks, none failed);
the refusal itself has not yet been driven on a guest with each setting set to Deny.

---

## 3. Windows 11: a slow capture helper is not a hung one

On Windows 11 build 26100 (24H2) and later, the capture helper (the broker) supplies the pixels of menus
and windows, and has two seconds to answer the agent. A broker that missed that deadline was ended at once and not restarted, and
the window kept showing stale pixels. Missing the deadline now raises one warning (`QGABROKERSLOW`) and
ends nothing. The broker is ended (`QGABROKERHUNG`) only if it has still not moved 6 s later, and a second
warning line records how long a slow broker took to answer (an upper bound, taken when the agent next
wakes). The cost is deliberate: a broker that really is hung is ended about 6 s later than before. A
broker ended as hung is still not restarted; that stays open.

Measured on our rig, A/B, by suspending the broker while an Explorer context menu opened: on an agent
with 4.3.41's broker code a 10 s suspension ended the broker at 2016 ms and left the menu as stale pixels; on this one, two
7 s suspensions were each seen moving again (2781 and 3031 ms after the warning), the broker was kept and
the menu was drawn in full; a 14 s suspension was ended at 8031 ms. What made the 2 s stall seen in the
field is still unknown; the new line measures it in the next field log.

---

## 4. The clock after a daylight-saving change

A guest shut down before a daylight-saving transition and started after it booted an hour off. The
qube's hardware clock holds dom0's local time; Windows converts it with the bias that was in force at
the last shutdown, and corrects the zone during its own start without moving the time. `bind-dirs`, which
already runs before any service starts, now checks for exactly that case - the zone was rewritten during
this boot and the bias at the last shutdown is one daylight-saving step away - and moves the system time
by that one step, once. It needs no `RealTimeIsUniversal`, no qrexec call and no vchan. Each boot records
what it did in `bind-dirs.log` and in `bind-dirs-result.txt`'s `clock=` field: `corrected`,
`already-correct`, `no-dst`, `refused` or `error`.

Measured on a test build of this change (not on this package's `bind-dirs.exe`), on a Windows 11 guest
whose clock was set into summer and then shut down: its next boot
corrected the time by 3600 s, 10.7 s after Windows set its time and 2.4 s before qrexec-agent started; a
clone of it did the same; the clone's second boot read `already-correct`. The opposite direction (shut
down in winter, started in summer) is the same code with the sign reversed and is covered by analysis
only, until the 2027-03-28 transition. Not corrected - each is logged and the clock is left alone: a
guest whose time zone differs from dom0's (a fixed offset, not a daylight-saving step), a hard kill
followed by a transition when the last clean shutdown was in the other season, a boot inside the repeated
autumn hour, and a Fast Startup resume (off on our guests).

---

## 5. Also in the package

`health-check.ps1` - the guest self-check that our test harness runs, copied into the setup tree and
never run by the installer - decides whether the previous shutdown was orderly from values that do not depend on the display
language: the volume's dirty bit as a boolean, event 98's `CorruptionActionState` field, and NTFS events
130/131 by ID. It used to match English sentences, so a German guest could never pass it.

---

## Verification

One full acceptance of this build, 2026-11-12 22:01 to 2026-11-13 02:34 UTC (the two failproof suites run
its fault-injection twin, built from the same commit). Every module passed on its first run. One half of
one suite did not run, blocked on our rig's dom0 resize service; it is named under Open items with what
else was not measured.

| what | result |
|---|---|
| build | `build-4.3.42.1280` = release-package run 43311615298 at `3cbc258d`, agent `32129613e337`, version 4.3.42 |
| package | `verify-release-package`: PACKAGE COMPLETE (version 4.3.42.1280), 14 gates passed, 0 skipped |
| CI at the build commit | every workflow run for `3cbc258d` succeeded: release-package 43311615298, build 43311615339, test 43311615455, and the fault-injection build 43311711795 that only the failproof suites use |
| install matrix | all 8 cells - clean install, reinstall, in-place MSI upgrade from 4.3.35, and an AppVM derived from a template that carries this release, each on Windows 10 and Windows 11 - **89 checks PASS, 0 FAIL, 0 INVALID**, no rows lost (matrix run `20261112T220504Z-2450470`, 22:05-23:10 UTC). Per cell: clean 16 + 16, reinstall 12 + 12, upgrade 13 + 13, AppVM 3 + 3 (Windows 10 + Windows 11), plus one campaign row: the cold dom0-caller path was measured for both families. The log sweep of every cell: CLEAN (8 sweeps, rc=0) |
| feature tests | all 6 exited 0. **updater-component** PASS: the German 25H2 guest of the reporter's environment upgraded 4.3.29 -> 4.3.42 from the release package (12 checks), then all 8 updater gates passed - the installed relay carries the shipped binary's marker, listens on 8082 and was started by the pass itself, the scan reported its count to dom0, and no update the guest had proven installed was counted to dom0 again. The install step's log check flagged one warning that the short-cycle check has no entry for: `QGAWGCITEMCLOSED`, "Windows closed the capture item, reopened at once (closures 1, sessions opened 1)" - the agent's designed reopen of a capture item Windows closes, which the release log sweep counts as normal and which tells the user nothing; the missing entry is a known gap in our check, not in the product. **notify-errors-guest-test** 12 passed, 0 failed. **crop-before-map** 2 passed, 0 failed: no window was shown before it was cropped, with 2 crop measurements proving the path ran. **supervision-gate** all 6 cells PASS: the package installs and the guest answers (13 checks); the install's supervision receipts are in place; two clean shutdown/boot cycles had one agent per boot, no death, no relaunch, no error during a requested stop and zero dom0 notifications; a death injected during a shutdown was reported at the next boot exactly once (one death row in dom0), and the window around it held no other death (one broker death, one death event); the log sweep found nothing new. **template-update** PASS on its first run: a TemplateVM cloned from the reporter's German 25H2 golden matched every asserted fact of the reporter's environment, was upgraded 4.3.29 -> 4.3.42 from the release package and passed all 8 updater gates; dom0 then drove three update passes the way Qube Manager does, each judged PASS, the guest's pending count went 2 -> 1 -> 0, the 3 restarts the passes asked for were performed, and a scan-only pass after the last left dom0's count empty. The one offer left out, "Microsoft Corporation AudioProcessingObject Driver Update (1.0.4.55794)", which has no KB number, was measured to be correctly left out, as in 4.3.41: the Catalog has no package for its title (a control title resolved in the same run), its content was not self-contained in any of the three rounds, and the template has no network of its own. Jev alone could not decide it (insufficient-evidence, 0.41); the measurement did. **uac-on** PASS, new in this acceptance: a clone of the reporter's German 25H2 golden, upgraded 4.3.29 -> 4.3.42 and run with UAC on (EnableLUA=1; the session user's token at the default run level read Medium, where it read High before UAC was turned on) - the notification bridge was still the same process 65 s after it started, on the first boot with UAC on after a run with UAC off and again on the boot after a shutdown with UAC on, with the agent retiring the previous boot's state files at start; the bridge task runs at priority 4; a notice from SYSTEM was handed to the session, read, deleted and sent once; `--severity info` arrived as an informational notice; a notice from an elevated process was delivered once. These are 4.3.41's notification and session-helper fixes, checked with UAC on |
| remainder suites | run by the remainder gate on win11-acc and its own subjects, 00:54-02:34 UTC, merged per module into the build's coverage receipt. **gate-preflight** PASS: the control window survives the gate bit (1 window before, 1 after), so a "nothing mapped" verdict means something. **p3a-etw-gate** PASS: 31 rows = 25 PASS + 3 PASS-DATUM (drills the product could not be made to fail) + 0 FAIL + 0 ungraded + 1 attended-pending + 2 untyped, status CLEAN; the attended row, the dom0 capture at the notice's forward, was read afterwards and shows the test's notice bubble. **toast-hold-test** PASS: 21 rows = 19 PASS + 0 FAIL + 0 ungraded + 2 untyped, status CLEAN, on the release package; its non-seamless cells are opt-in and did not run. **log-sweep** PASS: CLEAN on win11-acc over 6 boots, no breach. **failproof-gates** PASS: with every safeguard in force all four window-gate cells were green; bypassing the two full-screen gate clauses (modes 1 and 2) turned the cell they guard red, and with it a second cell that the suite declares as moving with that switch, while the other two stayed green; dropping captioned screen-sized windows turned only the cell that requires them to map red; with each safeguard restored, every cell was green. **failproof-faultinject** PASS: with nothing armed the capture checks were green; with the capture thread made to exit they went red (frames stopped); disarmed, they were green - and the capture thread itself, looked up independently in the agent's process, read alive, gone, alive across the three passes. Its dom0-driven resize half did not run: dom0's window-resize service on our rig answers "no window" even with windows present, so that half reports BLOCKED, as it did for 4.3.41 (the check is unchanged since) |
| record and gate | the acceptance record for these ISO bytes (sha256 `111e4da16c0e...`): `acceptance-record-check` rc=0, 7 cell-groups clean, 14 cells. The coverage receipt: 21 modules, all pass, none product-fail, none instrument-fail, none not run; `gate-scope.py check` over `v4.3.41-agent355e7fc..3cbc258d`: satisfied, 19 required, 21 covered. Every module is marked `harness_dirty` because the campaign itself rewrites `mgmt/campaign-space.json`, its record of free pool space (last written 23:05 UTC, mid-matrix); that is the only tracked file that differs from the build commit, and it is not harness code |
| full release gate | `cut-release.sh` runs both checks above again on this build and refuses to publish if either fails, unless it is given an override with a written reason, which it then prints at the top of the published notes. Both checks pass, so this release is cut with neither override |

**Open items.** No row in this acceptance names the product. Not measured: section 2's refusal names, which
are render-tested but have not been driven on a guest with each setting set to Deny; section 4's spring
direction, until 2027-03-28; section 1's clock-jump branch under Windows PowerShell 5.1 on a guest; the
notice deferral's drain (nothing was queued in this run, so the notify-errors test did not assert it);
and the dom0-driven half of the resize fault test, blocked on our rig's dom0 resize service (remainder
suites, above). Still open in the product: a broker ended as hung is not restarted, and what
stalls it for 2 s in the field is unknown (section 3); the cause of the reporter's 4.3.37/4.3.38 scan-task
failures is unknown (section 1).

---

## Upgrading

In-place MSI major upgrade from an earlier 4.3.x. This acceptance ran it from 4.3.35 (the two upgrade
cells) and from 4.3.29 (the three tests in the reporter's environment). Automatic updates
remain **off** in the guest by design; dom0 drives every install.
