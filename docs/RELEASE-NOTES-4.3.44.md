# QWT-NG 4.3.44 — an uninstall leaves a guest that boots, and dialogs show on a slow Windows 11

## The shape of this release

Most of it answers one field reporter's posts (docs/GWECK-STATUS.md). Removing QWT from Control Panel no
longer leaves a PV-booted guest unbootable, and no longer leaves a service that dies into dom0 notices
(section 1). On Windows 11 24H2 and later, a dialog that is resized right after it opens - the Open-Shell
installer's - is no longer withheld from dom0, Explorer is no longer declared deaf because a busy guest
painted it late, and "a window could not be shown" is sent only for a definitive fault (section 2). A file
drag no longer draws a black box in dom0 (section 3). The installer's restart notice is sent at last, and a
manual upgrade that leaves the guest without a display path powers it off after saying so (section 4). The
updater stops counting Defender definitions in what dom0 is told, and stops asking for a restart that did
not help (section 5). Section 6 lists the rest.

The package changes the agent, the capture helper, the installer and its MSI, the updater, the boot guards
and core-agent.

---

## 1. Uninstalling from Control Panel

**The guest boots after the removal.** Stock QWT's driver step, inherited unchanged, removed the Xen PV
drivers while Xen was still set to unplug the emulated disk at the next boot, so a PV-booted guest died with
INACCESSIBLE_BOOT_DEVICE (reproduced on a German 25H2 clone: `msiexec /x` returned 3010, the next two boots
died 59 and 65 s in). The removal now keeps the PV drivers when that unplug is armed; install and repair are
unchanged. Measured with Control Panel's uninstall on a fresh clone of the reporter's German 25H2 environment
(test build 4.3.44.1319): "Removal completed successfully", return code 3010, no product left registered, and
the next boot came up on the PV disk. An earlier build of the fix returned 1603 for a removal that had
succeeded, from the driver step's cleanup action; that action now carries the same condition.

**No service left to die.** The removal now stops and deletes `QwtngNetSetup`, which the installer creates
after the MSI and which outlived the library it logs to. On 4.3.43 the same uninstall left it registered and
it died twice within 6 s (System 7031, .NET 1026), each death reported to dom0. On two fresh clones of this
build the service was gone at the uninstall and minutes into the next boot, nothing died, and the guest
booted.

---

## 2. Seamless mode on Windows 11 24H2 and later: windows that were withheld

On build 26100 and later the capture helper (the broker) supplies window pixels.

- **A dialog resized right after it opens is shown.** The broker drops a frame whose size no longer matches
  its buffer, and a static dialog then sends no other. Both forms are handled: a frame dropped for size gets
  one fresh capture once the size has held for 150 ms, and a frame whose surface is still smaller than its
  content counts as such a drop.
- **Explorer is not declared deaf for painting late.** A capture that delivered no first frame within 2 s was
  recreated and then held as deaf, input or not. That check now applies only after an unanswered key or click,
  as designed. At 95% CPU steal no capture was recreated and Explorer's first frame arrived after 12.6 s.
- **"A window could not be shown"** goes to dom0 only for a definitive fault, not for a window still waiting.

Measured at 67% CPU steal on German 25H2 clones: 4.3.43 withheld the Open-Shell installer's dialog in 5 of 10
runs and held Explorer deaf in 5 of 10, on two subjects; the fixed builds did neither in 10 of 10, on three.
This counts runs; it is not a proof of cause.

---

## 3. A file drag no longer draws a black box

While the broker is active, the shell's drag image is no longer announced to dom0 as a window of its own. Its
pixels are 71-78% fully transparent, black underneath, and the window below it already shows the image
blended. Measured with dom0's own captures over a 40 s Explorer drag: on 4.3.43, 3 of 6 captures held the
drag image as a black-backed window; on this build none did, and Explorer showed the thumbnail blended.

---

## 4. The installer

- **The restart notice is sent.** Under the installer's strict mode the notice library threw before sending,
  so a manual install with a restart pending told nobody (the reporter's log: `Die Variable
  "$script:QwtNotifyStateDir" kann nicht abgerufen werden`). It was broken in 4.3.41 to 4.3.43, whose notes
  said otherwise. Measured on a German 25H2 clone installed by hand: 4.3.43 logged that failure, a test
  build of this release sent the notice.
- **A manual upgrade that leaves no display path powers the guest off.** When the GUI agent cannot be
  restarted because a reboot is pending, the guest maps no windows until its next start. The installer now
  tells dom0 the qube is shutting down and to start it again, then powers it off.
- **A StandaloneVM made from a template without its private volume** (`qvm-create --class StandaloneVM
  --template`) has no `Q:`, so its user gets a temporary profile and Explorer dies. The boot guard now tells
  dom0 so once per boot and names `qvm-clone --class StandaloneVM` as the way to make one.

---

## 5. Updates

- **Defender definitions are not counted** in the number dom0 is told, as the owner decided. They are still
  offered, installed and recorded. Windows Update's classification alone decides, which also covers the
  Defender and Windows Security platform updates. On a template or AppVM they install with the next pass dom0
  runs for another reason.
- **A restart that did not clear 0x8024402C is said, and not requested again.** The pass requested the same
  restart on every boot. It now remembers the request and, if the error survives it, says the restart did not
  clear it on this guest.

---

## 6. Also in the package

- **Agent:** a crash in the permit worker (an access violation in a field report) is fixed; with
  `service.enableWinKey 1` and no Start replacement, the Windows key no longer opens an invisible Start that
  takes the user's clicks.
- **Boot guards:** the autologon and quiet-desktop tasks get the 2-hour limit the update tasks have. At 95%
  CPU steal both ran past 5 minutes, were stopped by Task Scheduler and reported to dom0 as hung.
- **core-agent:** a dom0 call's ring that falls due in the first 60 s after logon is released 60 s later, one
  at a time. In an A/B on the Windows 11 golden, 9 and 10 such releases in that minute without it, none with
  it. A shutdown inside that minute still releases them together.
- **Death reports:** a capture helper killed with exit code 0xFFFFFFFF is reported with that code.

---

## Verification

One full acceptance of this build, 2026-11-15 18:00 to 22:44 UTC (the failproof suites run its
fault-injection twin, built from the same commit), then one module re-run on a later harness commit, 22:58
to 23:14 UTC.

| what | result |
|---|---|
| build | `build-4.3.44.1322` = release-package run 43739669019 at `889c21aa`, agent `f08d65295dc7`, version 4.3.44 |
| package | `verify-release-package`: PACKAGE COMPLETE (version 4.3.44.1322), 14 gates passed, 0 skipped |
| CI at the build commit | build 43739668987, test 43739669264, qwt-full 43739669070, release-package 43739669019, fault-injection package 43739751459: all succeeded; the three path-filtered workflows are inherited green from `512c2952` |
| install matrix | all 8 cells - clean install, reinstall, in-place MSI upgrade from 4.3.35, and an AppVM from a template carrying this release, each on Windows 10 and Windows 11 - **89 checks PASS, 0 FAIL, 0 INVALID** (matrix run `20261115T180335Z-1016853`); every cell's log sweep CLEAN, 0 breaches |
| feature tests | all 6 PASS. **updater-component**: 8 gates passed on the reporter's German 25H2 environment. **notify-errors-guest-test**: 12 passed, 0 failed, the notice photographed on dom0's desktop. **crop-before-map**: nothing mapped uncropped, 2 crop measurements. **template-update**: all 8 gates, then 3 dom0-driven rounds, last round PASS. **supervision-gate**: 6 cells PASS, 0 FAIL, among them a death during a shutdown reported exactly once at the next boot. **uac-on**: 8 PASS, 0 FAIL, 0 INVALID |
| remainder suites | **gate-preflight**, **p3a-etw-gate** (status CLEAN, 0 product FAIL), **log-sweep** (CLEAN), **failproof-gates** and **failproof-faultinject** PASS. **toast-hold-test** failed one row in the full run, S3iii-2 "LOST": the grader carried a destroyed banner's frame gate into the next window given the same handle, and the toast had been shown (the agent logged its show on a mapped, ungated banner). The grader was fixed (`cf349ca6`) and the module re-run on this build: 21 rows, 0 FAIL, status CLEAN |
| record and gate | the coverage receipt: 21 modules, all pass, none product-fail, none instrument-fail, none not run; the toast-hold failure is replaced by the re-run from a different harness commit (docs/ADR-acceptance.md section 7). `gate-scope.py check` over `v4.3.43-agent414cbd1..889c21aa`: satisfied, 19 required, 21 covered |
| full release gate | `cut-release.sh` runs both checks again on this build and refuses to publish if either fails; it is cut with no override |

**Open items.** Not proven: the cause of the withheld dialogs and the deaf Explorer (section 2 counts runs).
Not witnessed: when Windows swaps a queued toast into the banner with no window event, nothing records dom0
receiving its pixels; a fix that forces the repaint is on a test build, not in this release. Still open: a
helper that dies stays down until the GUI agent next starts.

---

## Upgrading

In-place MSI major upgrade from an earlier 4.3.x. Windows' automatic updates remain **off** on templates and
AppVMs, where dom0 drives every install; on a StandaloneVM with direct internet they stay on, without
automatic restarts while a user is signed in.
