# QWT-NG 4.3.45 — app menus say why they start nothing, a qube made from a template gets its profile, and disks grow

## The shape of this release

Most of it answers one field reporter's posts (docs/GWECK-STATUS.md rows 37, 47 and 54). When dom0's
`default_user` is not the account signed in to the guest, app menu entries still start nothing, as in stock
QWT, but dom0 is now told so and what to set (section 1). A StandaloneVM made from a template without its
private volume gets a working profile on a fresh `Q:` instead of a temporary profile, and a disk extended in
dom0 grows inside the guest, as on Linux (section 2). On a template the updates proxy now stays configured
between update passes, gated by process; in every other qube it is removed at boot (section 3). Every dom0
notice is rewritten short (section 4). Section 5 lists the rest.

The package changes the agent, the installer and its MSI, the updater and its relay, the boot guard, and
core-agent.

---

## 1. App menu entries and dom0's `default_user`

dom0 starts a menu entry only after `qubes.WaitForSession` returns, and it sends that service the qube's
`default_user`. The guest's wait returns only when that exact account is signed in. On a new qube whose
`default_user` was still Qubes' default `user` while the Windows account had another name, every entry
started nothing and nothing said why (reproduced on a German 26H2 template: the guest's own wait fed `user`
returned in 445 ms; fed the reporter's account name, it had not returned after 45 s).

- **The wait now reads `/default-user` from the qube's own QubesDB**, as Linux's `qubes.WaitForSession`
  does.
- **A mismatch is told to dom0.** When the signed-in account is not `default_user`, dom0 gets one notice per
  boot, "App menu entries start nothing in this qube", naming the fix: set `default_user` with `qvm-prefs`
  and restart the qube. A caller that sends a different name is logged and reported the same way.
- The matching rule itself is stock again: a short-lived test build that let any signed-in account end the
  wait is not in this release.

Measured on the reporter's pair (German 26H2 template, account `user`) with the CI build of this binary:
`user` returned in 494 ms; a foreign name did not return, logged a warning naming both accounts, and the
notice was graded RENDERED on dom0's pixels; a second mismatch in the same boot was suppressed as a
duplicate. Not run from here: a dom0 menu click end to end (this rig's policy does not let it call
`qubes.WaitForSession`).

---

## 2. A StandaloneVM made from a template, and disks that grow

**A working profile.** `qvm-create --class StandaloneVM --template` copies the template's root but gives the
qube a new, empty private volume, so the Windows profiles on `Q:` were missing: a temporary profile, Explorer
dying 31 s after logon, no desktop. The boot guard now acts as the Linux counterpart does. It creates the
profile store on that empty `Q:` from a seed the template keeps, signs the temporary session out and logs the
user back on. Walked on a German 25H2 standalone made that way: the user was logged on again 1 s after the
sign-out, with a loaded, non-temporary profile on `Q:` and Explorer running.

- **A private disk is written only when every byte reads zero**, as Linux's `setup-rwdev.sh` requires.
  Anything else stops the repair before the disk is touched, and the user gets the notice instead. A real
  AppVM private disk is never a candidate.
- **The seed is kept on templates only.** Only a template's seed is ever read; other qubes no longer copy
  2.5 MiB of profile data into their root on every boot. The qube class is read through QubesDB.

**`qvm-volume extend` grows the volume inside the guest**, through `qubes.ResizeDisk` for a running qube and
at boot for a halted one, for the private (`Q:`) and the root (`C:`) volume. Measured on that standalone: a
private volume extended while halted (2 to 3 GiB) filled `Q:` at boot; extended while running (5 to 6 GiB)
`Q:` grew in 30 s and `qvm-volume extend` returned 0. A partition between `C:` and the free space (usually
the recovery partition) is named in the log, not moved.

---

## 3. The updates proxy on a template (row 47)

Windows Update takes its proxy from the settings present when the user signs in, not from what an update pass
writes mid-session. A proxy that existed only while a pass ran could therefore miss Windows Update's
service lookup, and that pass ended with `0x8024402C`. On the rig, with the per-machine proxy policy present at
sign-in, the very first pass searched.

- **On a TemplateVM the proxy configuration now stays between passes** (WinHTTP, WinINET and the per-machine
  policy, all pointing at the local relay). A pass no longer resets WinHTTP or WinINET when it ends.
- **The relay serves only update processes**: a LocalSystem process whose image is under the Windows,
  Program Files or Defender platform folders, the Windows Update services, or an update pass registered by its
  process id and start time. Measured on a German 25H2 clone: the 4.3.44 relay served a renamed `curl`, a
  SYSTEM child PowerShell and the signed-in user's PowerShell; this relay refused all five non-update callers
  tried, and served the registered pass and a System32 image.
- **In every other qube the configuration is removed at boot**, so an AppVM made from such a template is not
  routed through a relay that is not running. Measured: a template kept all three across a restart; its AppVM
  had none of them and reached the network directly.

Not yet shown: that this clears `0x8024402C` on the reporter's own guest. On the rig, the template-update
acceptance (German 25H2 environment) passed.

---

## 4. dom0 notices are short

Every notice this package sends to dom0 has the same shape. It has a short title and one line saying what
happens next or what to do. The last line carries the facts: code, build and the log file to read. This
covers the gui-agent, the notification bridge, death reports, the installer, the updater, the display
driver's activation and the boot guard. Long explanations and cause sentences are gone; the logs keep them.

---

## 5. Also in the package

- **Toasts:** a toast that Windows swaps into a banner already on screen, with no window event, is now
  repainted to dom0. Before, nothing repainted it; in a test build's acceptance one such toast was lost.
- **Agent supervision:** the watchdog finds a running agent through the agent's own liveness mutex, not by
  process image name. A same-named process that has already exited no longer makes the launch path spin. A
  secure desktop (UAC, lock screen) is classified by who owns its windows.
- **Logs:** every PowerShell script of ours appends to its log append-only, shared with readers, as UTF-8.
  Measured on Windows PowerShell 5.1: the old writer denied readers and died at line 117 of 3000. With 8
  processes writing 300 lines each at once, the old writer tore 661 lines, and the new one kept 2400 of 2400
  intact. A log directory on a drive the qube lacks loses the line instead of ending the script.
- **core-agent:** the 60-second ring hold that 4.3.44 added after logon is removed: a dom0 call's ring is
  released when the call ends, as before 4.3.44. Every dom0 call, its child's end and each `qubes.StartApp`
  phase are logged. `start-app.ps1` makes no WMI lookup when it already runs as the signed-in user.

---

## Verification

One full acceptance of this build, 2026-11-18 15:50 to 20:47 UTC. The failproof suites ran on its
fault-injection twin, built from the same commit.

| what | result |
|---|---|
| build | `build-4.3.45.1366` = release-package run 44303078804 at `03517f30`, agent `728ddae1124a`, version 4.3.45 |
| package | `verify-release-package`: PACKAGE COMPLETE (version 4.3.45.1366), 14 gates passed, 0 skipped |
| CI at the build commit | build 44303078503, qwt-full 44303078794, release-package 44303078804, pv-xenvif 44303078423, pv-xencons 44303078396, fault-injection package 44303111586: all succeeded |
| install matrix | all 8 cells (clean install, reinstall, in-place MSI upgrade and an AppVM from a template carrying this release, each on Windows 10 and Windows 11): **89 checks PASS, 0 FAIL, 0 INVALID** (matrix run `20261118T161102Z-3255394`). Every cell's log sweep CLEAN, 0 breaches |
| feature tests | all 6 PASS. **updater-component**: 8 gates passed in the reporter's German 25H2 environment. **notify-errors-guest-test**: 12 passed, 0 failed. **crop-before-map**: 2 passed, 0 failed. **template-update**: all 8 gates, then 3 dom0-driven rounds, 0 failed, last round PASS. **supervision-gate**: 6 cells PASS, 0 FAIL. **uac-on**: 8 PASS, 0 FAIL, 0 INVALID |
| remainder suites | **gate-preflight**, **p3a-etw-gate**, **toast-hold-test**, **log-sweep**, **failproof-gates** and **failproof-faultinject**: PASS |
| record and gate | `gate-scope` over `v4.3.44-agentf08d652..03517f30`: satisfied, 19 suites required, all covered |
| full release gate | `cut-release.sh` re-runs both checks on this build and refuses to publish if either fails. This release is cut with no override |

**Open items.**
- Not shown on the reporter's guest: that section 3 clears `0x8024402C` there (row 47).
- Not run end to end: a dom0 menu click through `qubes.WaitForSession` (row 54).
- Twice before this build's clean run, the Windows 11 test guest hung at a shutdown in the clean-install cell
  of an acceptance: Windows completed its shutdown, and QEMU never reported the power-off. Each time, the
  guest's emulated USB disks had lost their media earlier in that boot. These are harness-attached sticks, not
  something a user's qube has. The cause is not established.
- The PV console stops answering after about 1.2 KB of input in one `qvm-console` login. It answered again
  only after the `xencons_monitor` service in the guest was restarted. Seen on this build's Windows 11 guest
  with the unpatched upstream xencons that QWT-NG has shipped since 4.3.16; its cause is not established.

---

## Upgrading

In-place MSI major upgrade from an earlier 4.3.x. Windows' automatic updates remain **off** on templates and
AppVMs, where dom0 drives every install; on a StandaloneVM with direct internet they stay on, without
automatic restarts while a user is signed in.

If an app menu entry of a Windows qube starts nothing after this upgrade and dom0 shows "App menu entries start
nothing in this qube", set the qube's `default_user` to the Windows account name in dom0 (`qvm-prefs <qube>
default_user <account>`) and restart the qube.
