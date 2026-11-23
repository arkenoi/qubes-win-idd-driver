# QWT-NG 4.3.46 — no key pokes and no desktop duplication in seamless mode, Start as a dom0 menu entry, windows open at dom0's size

## The shape of this release

On Windows 11 25H2 and later, seamless mode now captures every window through the capture broker alone. The
key pokes, the PrintWindow route, the relay and the seamless desktop duplication path are gone (section 1).
That is what fixes Explorer's "Window stopped updating" after the Windows key (docs/GWECK-STATUS.md rows 44
and 55). The native Start menu is a regular dom0 app-menu entry, shown as a normal window (row 29, section 2).
Windows no longer open maximized over the whole guest screen, and Edge's first-run overlay no longer becomes a
black screen-sized window (section 3). On templates, the first update scan no longer fails `0x8024402C`, and
command-line winget works (row 47, section 4). Section 5 lists the rest.

**One known defect ships in this release; see "Open items".** When Windows swaps a second toast into a banner
that is already on screen, dom0 was seen to show a black rectangle in place of the second toast.

The package changes the agent, the capture broker, the installer, the updater and its relay, the network
setup service, the boot guard, the PV console's tty and the service runtime (windows-utils). core-agent is
unchanged.

---

## 1. Capture: no key pokes, no desktop duplication in seamless mode

- **The capture broker's floor is Windows 11 25H2** (ADR-capture 36). Older Windows keeps the legacy path.
  The broker's PrintWindow route, the relay and every key poke are gone. A window the broker cannot open
  fails loudly; nothing falls back silently. A key the agent drops, and a key release, no longer ask the
  broker for a frame.
- **No desktop duplication in seamless mode on 25H2 and later** (ADR-capture 33). Desktop duplication is now
  only the engine of the non-seamless desktop window, created when you enter that mode. The broker's monitor
  slot and the capture opt-outs (`WgcBroker=0`, the `wgc-broker` service) are retired. A window that has no
  capture buffer of its own is withheld from dom0. The notice for it says what you see, and that it is our
  defect.
- **Rows 44 and 55: Explorer "stopped updating" after a key.** The poke, the liveness test and the capture
  re-creation no longer exist, so no key (dropped, released or typed) can re-create Explorer's capture or
  mark it "stopped updating". This was measured on the reporter's environment (German 25H2, TemplateVM,
  2 vCPU with CPU steal), on an earlier form of this fix:
  - on 4.3.45, 7 keys that changed nothing gave 4 re-creations, "Window stopped updating" and the dom0
    notice, and dom0's picture of Explorer stayed unchanged while a file appeared in it;
  - on the fix build, on two cold boots with 12 keys each, there were no re-creations and no notice, and the
    new file showed in dom0.

  The key sent was a letter, because the rig cannot send the Windows key. The shipped form was not measured
  on that pair.

---

## 2. Start as a dom0 app-menu entry (row 29)

Owner order: the native Start menu becomes a regular dom0 app-menu entry, on Windows 10 and 11, shown as a
normal window.

- **The installer publishes a "Start Menu" entry** that dom0's app menu lists. It does this at install and at
  upgrade. On a guest whose own shell takes the Windows key (`service.enableWinKey`), it removes the entry
  instead, so set that feature before installing or upgrading.
- **Through the entry, Start is one normal dom0 window with focus.** A second call closes it, and so does
  dom0's close button, together with the search view. `SeamlessStart` now defaults to 1.
- **Typing turns Start into the search view.** The search view is a normal framed window too, so dom0's keys
  reach it, on Windows 11 and on Windows 10 (`SearchApp.exe`). A second call while the search view is up
  leaves Start alone, and the next key brings the search view back with fresh results.
- **Fixed while Start opens:** on Windows 11 the search view has no black border and logs no error at each
  opening, and the 26H2 crop keeps the search box and the account bar. On Windows 10, Start no longer shows
  inside the window beneath it, and the search box no longer jumps.
- **The agent's main loop no longer spins while Start is open.** No spin has been seen on the rig since.

These changes were proven on fresh 25H2 installs, on 26300, and on Windows 10 upgrades. The border, error
and Windows 10 fixes were also proven in a full acceptance of an earlier 4.3.46 build.

---

## 3. Windows open at the size dom0 gives them (ADR-windows 17)

- **Nothing opens maximized by default.** A window that opens maximized is shown normal, inside the work area,
  at once. An explicit maximize no longer overhangs the screen, because the work area is taken only from
  dom0's own placements.
- **A popup that a window arrived under** (Edge's overlay) is kept on the client area of the window the agent
  showed normal. It stays there when the app shows it after the restore, and after a minimize and restore.
- **Edge's first-run overlay** is never announced to dom0 at screen size. It is held while it lies mostly over
  its owner, or when only dom0's window manager could place it. When it arrives before its owner is shown,
  it is never created in dom0 (ADR-capture 37). Before, it could put up a black screen-sized managed window.
- **An app's captionless popup inside its owner** is shown through the owner's capture, not as a black second
  window.
- **Popups that become windows:** a popup that flips into a managed window, or that moves, is re-created in
  dom0. Its map waits until dom0 holds its size.
- **A window Windows restores from minimized** is unmapped and mapped again. A restore that dom0 starts is not
  measured.
- **Row 56, the UAC prompt.** `consent.exe` first creates its prompt window at work-area size, and dom0 was told
  that size for about 65 ms (measured on Windows 10). That window is now withheld until Windows shows it at
  dialog size, and dom0 gets one ordinary dialog (measured on Windows 10 and German 25H2). The lasting
  full-screen state in the report was not reproduced.

---

## 4. Templates and updates (row 47)

- **A template gets its updates proxy at install**, so its first update scan no longer fails `0x8024402C`.
  Windows Update reads that proxy from the policy present at sign-in. Until now, the only writer of the
  policy was the first update pass, which runs after sign-in. Measured on unmodified 4.3.45 (Tiny11 26300
  TemplateVM): the first scan failed `0x8024402C`. With the configuration written before the template's first
  boot, the first contact found 6 offers.
- **A qube made from a template drops the template's proxy before it gets an address.** The network setup
  service removes it before giving the adapter its address. Before, a page fetch 44 s after boot resolved the
  dead proxy on `127.0.0.1:8082` and failed.
- **A conversion between qube classes is picked up at the next update pass**, for auto-update and for the
  template's proxy.
- **A failed scheduled scan stays in the guest's log.** Only a pass that dom0 started notifies dom0. This is
  not yet measured on the rig.
- **Defender's cloud hosts bypass the template's proxy.** A never-run binary's first start on a template no
  longer waits on the dead port. Measured on one German 25H2 TemplateVM with Smart App Control in evaluation
  mode: 8146 ms before, 65-75 ms with the bypass.
- **Command-line winget works on a template.**
  - The relay serves winget when both its real image path (under `WindowsApps`, written only by the AppX
    deployment service) and its package family name identify it, to any host.
  - The template's policy turns WinINet's certificate revocation check off and points winget's
    `DefaultProxy` at the relay. Both values are removed in every other class.
  - Measured on a German 25H2 TemplateVM with no network adapter: before, winget failed after 122 s with
    `0x80072f19` (revocation) and installed no package; with both values, the download took 1 s and the
    install 5 s.
- **A template install no longer deletes the values in the Internet Settings policy key.**
- **Every installed executable carries its cached signing level before the install boot ends**, so an AppVM
  does not re-verify each one at its first start in every boot. Measured in an AppVM: first starts of 32-75 ms,
  against 460-1160 ms for untouched copies. Where Smart App Control is off, Windows refuses this for our
  unsigned executables (open).

---

## 5. Also in the package

- **Autologon for an account with no password.** Windows answers a blank password with 1327 for such an
  account, and the installer refused every non-zero answer, so autologon was never set up. It is now set up
  for that account. Every refusal names its Win32 code and a cause keyed on it. Measured on Windows 10 with
  the default blank-password policy: the account signed in by itself after a reboot.
- **PV console:** the console's tty opens the monitor pipe once, read and write, instead of twice. The second,
  never-read connection is what stopped input after about 1 KB in one login (4.3.45 open item). The xencons
  driver package itself is upstream's, byte for byte. Built by CI only; not yet measured on a guest.
- **Shutdown and teardown freezes.** Stock xenbus has a pre-existing freeze when two users of one event-channel
  bucket run on two CPUs. Measured with an event-channel storm: spread over the CPUs, it froze a 4.3.35 guest
  within about 2 s; with every worker on CPU 0 it ran 10.6 million pairs cleanly. This release works around
  it in three places:
  - the gui-agent's exit sends nothing in flight before closing its channel while dom0's daemon is alive, and
    the agent opens and closes that channel on the lowest CPU;
  - qubesdb-daemon runs on the lowest CPU, as qrexec-agent already did;
  - before the installer stops the running QWT runtime, it pins those processes and their children to CPU 0.
    An upgrade from an older release, whose agent still runs its old exit, then closes its channels on one CPU.

  The cause in xenbus itself is not changed, and no freeze rate is claimed for these changes.

---

## Verification

One full acceptance of this build, 2026-11-22 23:28 to 2026-11-23 02:45 UTC. The failproof suites ran on its
fault-injection twin, built from the same commit.

| what | result |
|---|---|
| build | `build-4.3.46.1455` = release-package run 45079168781 at `240c4cc5`, agent `a16865a67f35`, version 4.3.46 |
| package | `verify-release-package`: PACKAGE COMPLETE (version 4.3.46.1455), 14 gates passed, 0 skipped |
| CI at the build commit | build 45079168611, test 45079168673, release-package 45079168781, fault-injection package 45080940388: all succeeded; qwt-full, pv-xencons, pv-xenvif and winenum inherited green from the last commit that touched their paths |
| install matrix | all 8 cells (clean install, reinstall, in-place MSI upgrade and an AppVM from a template carrying this release, each on Windows 10 and Windows 11): **89 checks PASS, 0 FAIL, 0 INVALID** (matrix run `20261122T234846Z-2851422`); every cell's report CLEAN, 0 P1 |
| feature tests | **updater-component**, **notify-errors-guest-test**, **crop-before-map**, **template-update**, **supervision-gate** and **uac-on**: PASS |
| remainder suites | **gate-preflight**, **p3a-etw-gate**, **log-sweep**, **failproof-gates** and **toast-hold-test**: PASS |
| record and gate | `gate-scope` over `v4.3.45-agent728ddae..240c4cc5`: satisfied, 18 suites required, 20 covered |
| full release gate | `cut-release.sh` re-runs both checks on this build and refuses to publish if either fails. This release is cut with no override |

**toast-hold-test took five runs, none of which changed the product.**
- The first run lost its agent log on the harness's log volume.
- The second and third left one row ungraded each. In both, the harness cleared the notification history
  while a second toast was still queued behind the first one's banner.
- The harness was then fixed to give every toast that is owed a banner its turn before clearing, and to grade
  a toast that never gets one as LOST. The fourth run aborted on a defect in that harness fix.
- The fifth run passed: 19 rows PASS, 0 FAIL, 0 ungraded. Its one attended row, which a person grades by
  reading dom0's screenshots, is the first open item below.

**Open items.**
- **A toast swapped into a banner already on screen was seen black in dom0.** In the fifth toast-hold run,
  Windows reused the first toast's banner window for the second toast, with no window event.
  - The agent re-attached the window's capture buffer twice at the swap, rejected two frames whose size no
    longer matched, and then logged that it had repainted dom0 with the new toast.
  - dom0's screenshot, taken at least 0.2 s after that log line, shows a black rectangle in the banner's place.
    No capture shows the second toast.
  - This is the first dom0 capture of this path on any build. The same scenario with a fresh banner window
    showed the second toast correctly.
  - How long the black lasts, and whether 4.3.45 shows it too, is not measured. The toast-hold code is
    unchanged since 4.3.45; the capture code beneath it changed (section 1).
  - The owner decided to ship 4.3.46 with this named, and to fix it in the next release.
- Not shown on the reporter's guest: that section 4 clears `0x8024402C` there (row 47).
- Not run end to end: a dom0 menu click through `qubes.WaitForSession` (row 54, from 4.3.45).
- The PV console fix (section 5) is not yet measured on a guest.

---

## Upgrading

In-place MSI major upgrade from an earlier 4.3.x. Windows' automatic updates remain **off** on templates and
AppVMs, where dom0 drives every install; on a StandaloneVM with direct internet they stay on, without
automatic restarts while a user is signed in.

The "Start Menu" app-menu entry is published at install and upgrade. If the guest's own shell takes the Windows
key, set `service.enableWinKey` before upgrading, and no entry is published.
