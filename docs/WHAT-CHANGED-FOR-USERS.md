# What changed for users — this fork vs stock Qubes Windows Tools 4.2.2

Written 2026-08-06. This is a description of **observable behaviour**, not a changelog. Every
claim carries the measurement it rests on; where something is unmeasured or unfixed it says so.

## Measurement scope — read this before believing any number below

- Everything in section 1 was measured on **one guest**: `win-idd-test`, Windows 10 Pro
  **19045**, 4 vCPU, **no GPU** (WARP software renderer), Qubes OS 4.3 dom0.
- The **display/seamless** fixes (per-window capture, window tracking, Office chrome, popup
  handling) were additionally exercised on a **Windows 11 24H2 (26100)** guest, where one
  extra defect class (XAML windowed popups) was found and fixed.
- The **resolution-follows-the-window** feature and everything about the indirect display
  driver (IDD) were measured on **Win10 19045 only**. Windows 11 is **untested** for that
  path. The research verdict is that Win11 changes nothing structurally
  (`PLAN-smooth-resize-win11.md`), but that is research, not a measurement.
- No result here should be assumed to hold on a guest with a **real GPU or GPU passthrough**.
  The key capture property (below) is expected to fail there and was never tested there.

---

## 1. What is different when you use the qube

### 1.1 Each window is captured on its own — composited-desktop artifacts are gone

Stock QWT captures the whole desktop once per frame and slices per-window rectangles out of it
by screen coordinates. Every classic seamless artifact follows from that: debris left behind a
moving window, a menu corrupting the window it hovers over, mid-drag slicing, content wobbling
inside its frame, stale clip bands where windows overlap.

This fork gives each accepted window its **own granted framebuffer**, filled with
`PrintWindow(PW_RENDERFULLCONTENT)` and announced with a per-window `MSG_WINDOW_DUMP`. That is
the same model the Linux agent uses; **gui-daemon is unmodified** and no protocol change was
needed.

- Evidence: with two overlapping windows, the *back* window renders complete to its right edge
  in dom0 while the front window covers that region inside the guest
  (`instrumentation/perwin-overlap-{back,front}.png`).
- Evidence: content wobble during a scripted 10 s drag went from **52 % of damage events
  carrying a stale origin (dx up to 38 px)** to **0 %, dx max 0 px**.
- Note: this is on by default (`PerWindowCapture`, code default 1; nothing in the install path
  writes the value). It has one open defect — see 2.4.

### 1.2 Office-style compound windows render as one window

Post-2013 Office (and any app using the same trick) surrounds its frame with layered,
transparent, click-through "shadow strip" windows. Stock QWT maps each one as a separate qube
window and dom0 draws a coloured security border around each — visually broken. This fork
drops unmappable chrome in the window-acceptance predicate, and synthesises owner-contained
popups (menus, tooltips, bubbles) into their owner instead of announcing them.

- Evidence (synthetic): `tools/chromerepro` produces **5 top-level windows → 1 bordered dom0
  window**, no stray borders, no double title bar.
- Evidence (real Microsoft Office, Word): four real `MSO_BORDEREFFECT_WINDOW_CLASS` strips
  present on both sides; pre-fix build painted them into the frame's buffer (**731 SYNTHPAINT
  events**, a visible grey band around the document area — `scratchpad/shadow-ctl/win-0.png`),
  fixed build **0**. User confirmation: *"weird shadow is gone."*
- Evidence (Win11 24H2): `Xaml_WindowedPopupClass` popups (inbox Notepad context menus,
  Terminal flyouts) drew a heavy black frame over their owner on stock behaviour; now
  synthesised correctly.
- Real Office also reproduced a **gui-daemon kill** on the stock path; that chain is fixed
  (see 1.5).

### 1.3 Window tracking is event-driven, not a per-frame enumeration

Stock QWT re-enumerates every top-level window on every captured frame. This fork tracks
windows from `SetWinEventHook` events.

| metric, scripted drag | stock / pre-fix | this fork |
|---|---|---|
| per-frame cost, p50 | 17.2 ms | **613 µs** (clean install), 698 µs (settled re-run) |
| windows interrogated per frame | ~67 | **1.03** (1.39 on the settled run) |
| work-area re-assert applies, 120 s idle | 1460 (3.95 s CPU) | **0** (0.08 s CPU) |

Measured on a wiped-disk clean install of the package (no overlay on a stock QWT), against the
pre-fix build as control.

### 1.4 The guest resolution follows the dom0 window — at arbitrary sizes

Stock QWT is stuck with the Basic Display Adapter's fixed mode list: a size like 2566x1022
simply does not exist, so resizing the qube's window scales or clips a fixed desktop. This fork
ships a **Qubes IddCx indirect display driver** that publishes the sizes the agent asks for, and
the agent applies them.

What you observe:

- Drag the qube's window in dom0; when the gesture settles, the **guest desktop becomes exactly
  that size**. Never approximately, never "the nearest offered mode".
  - Evidence: **28/28 real dom0 WM resize cycles** (14 drag-like configure streams + 14 jumps,
    driven through gui-daemon) triple-converged — requested == dom0 window == guest resolution.
  - Evidence: acceptance soak **30/30** cycles including 10 agent restarts and 6 reboots, every
    size exact, sizes persisted across restart and reboot.
- **Habitual sizes are blink-free.** Maximize, half-screen tiles, and the last 4 sizes you used
  are pre-published, so applying them costs **one same-millisecond mode set, no monitor replug,
  no black flash, no device-plug sound** (`RESEXACT … replug=0`).
- **Novel sizes take about half a second.** Median **time-to-pixels 484 ms** (was 609 ms before
  the latency work), decomposed as mode-offered 109 ms → applied 187 ms → pixels ~484 ms. During
  that window the last clean frame is **held** rather than showing a half-converted desktop.
- **Near-miss snapping**: a request within **15 px** of a work-area-derived size (maximize, tile
  half) snaps to it, so tiling gestures land on the tile exactly. Anything further away is
  applied exactly. Verified: 2544x1374 → 2550x1379, borders visible; 20-px-off and arbitrary
  sizes correctly do **not** snap; window position preserved (4/4 regression battery).
- **Nonsense geometry is refused sensibly**: if a remembered window geometry's *frame* cannot
  fit dom0's work area, the largest published size that does fit is used instead
  (`RESFIT 5120x1440 does not fit work area 5110x1379 - snapping to 5110x1379`). This is what
  stops a WM-remembered oversize window from pushing its security border off-screen.
- The guest **never** resizes the dom0 window. dom0 is the only authority on size; if a size
  cannot be obtained the guest keeps its current resolution and says nothing.

The gating technical question for this whole feature — does Desktop Duplication still work when
an indirect display driver owns the desktop? — was answered formally: **3 interleaved rounds,
cold boot per side, IDD vs Basic Display Adapter control, 6/6 PASS.**
`DesktopImageInSystemMemory` stayed TRUE for every run, surface mapping worked with a **tight
pitch**, and there were **zero** `ACCESS_LOST` events and zero re-duplications across 146–172
acquired frames per IDD side. The IDD and the BDA control are indistinguishable on every
acceptance field. Scope: driver build D4v3 + stable EDID, WARP, 19045, solo topology.

### 1.5 The agent stays alive; it no longer takes the GUI down with it

Stock QWT treats a number of transient conditions as fatal, and a dead agent closes the vchan,
which frequently kills dom0's gui-daemon and with it every window of the qube.

- **A denied input injection is no longer fatal.** One real incident: the guest idle-locked, the
  lock screen took the input desktop, dom0 sent a mouse move, `SendInput` returned
  `ACCESS_DENIED (0x5)` — and the agent exited, taking gui-daemon with it. All six `SendInput`
  sites now log, re-attach to the input desktop best-effort, drop the event and continue. This
  class is trivially reachable in normal use (UAC secure desktop, idle lock, any desktop switch).
- **Capture hiccups retry instead of killing the process.** A transient `0x887A0026` during a
  mode switch used to fail capture init and exit; it is now retried (10 × 750 ms). In the stress
  run that retry saved the process **three times** (`A7RETRY=3`).
- **A full exit-path audit** ("never exit") converted every remaining avoidable fatal path to
  degraded-and-retry: capture-init exhaustion (vchan keeps being serviced, capture retries every
  5 s forever), seamless-mode failures, resolution failures, an out-of-memory `exit()`. What is
  still deliberately fatal: a dead vchan (nothing to serve) and a desynchronised vchan stream —
  the latter on purpose, because re-parsing a desynced stream could synthesise keyboard and
  mouse input, which is an input-integrity boundary, not a robustness trade-off.
- **Duplication recovery keeps your windows.** On `ACCESS_LOST` the duplication is recreated in
  place, windows kept, framebuffer re-granted and re-announced — and the check that counts is
  that dom0 pixels *update* afterwards, not that a log line says "recovered".

### 1.6 Grant lifecycle: one framebuffer grant for the agent's lifetime

Previously every resolution change re-granted the framebuffer and revoked the old grants. Under
churn this accumulated: a wedged guest was caught holding **~22,000 active grant entries still
mapped by dom0**, with an NMI kernel dump showing the guest kernel spinning forever inside the
Xen PV grant-revoke path (`xeniface → xenbus`, `MmUnlockPages`).

This fork grants **one max-size staging buffer once** and re-announces geometry over the same
grant. Old-grant handling is ack-gated with a timeout, and exit-path revokes are attempted only
when dom0 is provably gone — with a live daemon the grants are **leaked loudly by design**,
because a revoke that cannot succeed can only lose a kernel race.

- Evidence: after this change the grant-table condition is gone (9 frames of 2048; the 22 k
  pinned entries do not recur) and the revoke-spin livelock, NMI-proven earlier, **did not recur**.
- The underlying spin is a **Xen Windows PV driver defect**, not ours; a report is drafted
  (`docs/upstream-xen-pv-grant-revoke-spin.md`) and awaits the user's approval to send.

### 1.7 Cursor

- **No double cursor in fullscreen.** Fixed by using the stock `DisableCursor=1` mechanism (the
  fork's own provisioning had pre-seeded it to 0) plus a solo display topology, which makes the
  virtual screen exactly equal to the qube window and removes the input-coordinate skew.
- **The guest shadow cursor no longer comes back after resizes.** A mode change makes Windows
  reload the cursor scheme and undo the one-time blanking; the blanking is now re-applied after
  every applied mode change (exact, snapped, and externally-driven).
- **Device connect/disconnect sounds during resizes are silenced** (per-user `AppEvents`);
  `DeviceFail` is deliberately left audible as a canary.
- Not done: a **hardware cursor from the IDD**, which is the proper fix rather than blanking.

---

## 2. What is NOT fixed

### 2.1 dom0's gui-daemon can still die when the agent exits (dom0-side bug)

When the Windows agent exits — including a *graceful* stop, e.g. installing a new build —
dom0's gui-daemon sometimes dies with it and every window of the qube disappears until the qube
is restarted. This is a **gui-daemon bug in dom0, not in the guest**: `handle_vchan_error` never
consults `vchan_at_eof`, so a disconnect noticed on the write path skips the restart the daemon
otherwise implements (there is also a use-after-free if `execv` fails in `restart_guid`).

- Rate observed: **6/10** agent restarts in one soak, **4/10** after the agent's exit sequencing
  was cleaned up, **0/10** in the final drag soak. The agent-side changes narrow the race; they
  cannot close it.
- Analysis in `DESIGN-gui-daemon-restart-survival.md` §3; an upstream report is drafted and
  awaiting user approval. Until dom0 is patched, **treat "install a new agent build" as
  "restart the qube"**.

### 2.2 A rare whole-guest wedge under heavy display churn (Xen PV servicing)

Under **sustained** resize activity the guest can stop servicing its PV rings: qrexec goes deaf,
ACPI shutdown is not processed, the qube must be killed and restarted. Forensics on a caught
instance: **all four vCPUs idle in `HalProcessorIdle`**, event channels intact, grant table
healthy, gui-daemon and its window alive — the guest is not spinning, it is simply no longer
being asked to do anything. Suspected in the PV drivers' interrupt/DPC or vchan servicing path
after repeated display device churn; nothing logs, because the guest never notices.

- Mitigation shipped and measured: a **recent-size LRU** (last 4 sizes stay published) plus a
  2.5 s minimum interval between monitor reloads. A storm reproduction that wedged the previous
  build on the **first** storm now passes **6/6**, with replugs dropping from 4 to **0** per
  8-request storm after the first pass over a size pool.
- Honest residual: the sustained real-path drag soak still reached a wedge at **cycle 10**
  (9 gestures, 2 agent restarts, 1 reboot, all converged exactly, then qrexec died). Guest-side
  mitigation moved this from "first storm" to "~10 mixed cycles"; the remainder is dom0/PV side
  and is not fixed. Normal interactive use — a handful of habitual sizes — should approach zero
  monitor reloads in steady state.

### 2.3 Seamless-mode window-predicate work is incomplete

- **Toast notifications are untested.** Windows Action Center toasts use the same attributes
  (topmost + layered + often DWM-cloaked) that the chrome predicate uses to *drop* Office shadow
  strips. Whether notifications still appear after the predicate landed has **not been
  verified**. Treat "guest toasts appear" as unknown.
- **Double chrome remains** (the app draws its own title/tab bar, dom0's WM adds a frame). This
  is inherent to QWT seamless and identical on stock; it is a presentation decision, not a bug
  this fork fixed.
- The Win11 "double windows" artifact class was only partially explored; the tooling
  (`tools/winenum`) exists, the Win11 25H2 target does not.

### 2.4 One open per-window-capture artifact

Moving a **modal dialog** across another tracked window leaves debris that appears and
disappears behind it. Observed on real Office with per-window capture enabled (i.e. the default
configuration). Leading explanation: the agent does not emit damage for the region a moving
window *vacates*, so dom0 keeps showing stale pixels there until something else dirties them.
Confirmed **not** a slice-feeding problem (both windows are `PrintWindow`-captured). Not root
caused; the hybrid-capture design (T3) is the intended fix.

Workaround if it bothers you more than the artifacts it replaces: set
`HKLM\Software\Invisible Things Lab\Qubes Tools` → `PerWindowCapture` = 0 and **restart the
qube**. That reverts to the stock composited-slice model, with all of its own artifacts.

### 2.5 Networking

- The long-standing "Windows qube unusable with a netvm attached" blocker in this project was
  **root-caused to the netvm, not to Windows or to this fork**: with `qubes-mirage-firewall` as
  netvm, the Windows PV network frontend never completes its handshake — `xenvif` installs but
  never starts, the emulated NIC is never unplugged, ~2 cores burn in PnP retry and qrexec is
  starved out. Pointing the qube at a **conventional Linux netvm** releases it immediately.
- Nothing in this fork changes networking. The mirage-firewall interaction is unfixed and is not
  ours to fix.
- The development guest is deliberately **offline**; nothing here has been exercised with real
  network load.

### 2.6 Not submitted upstream

Per project policy, none of the agent work has been proposed to QubesOS. Three defects found in
components *outside* QWT (gui-daemon EOF/UAF, the Xen PV grant-revoke spin, an `xl console`
overflow) have upstream reports drafted, pending approval to send.

---

## 3. Requirements

| Requirement | Why |
|---|---|
| A working **Qubes Windows Tools 4.2.2** install in the guest | The package is an *overlay updater*: it replaces `gui-agent.exe` (and optionally `gui-watchdog.exe`) in place, reversibly, keeping a `.orig` backup. It is not a QWT installer and does not ship the Xen PV drivers. |
| **Windows 10 19045** for the resize feature | Everything in 1.4 was measured only there. Win11 untested. |
| **Test signing enabled** in the guest (`bcdedit /set testsigning on` + reboot) and the build certificate trusted | The IDD driver and the rebuilt agent are signed with a throwaway CI certificate, not a WHQL/EV one. `guest/firstboot-setup.ps1` does both. |
| **The Qubes IDD driver installed** (`root\qubesidd`, via `pnputil /add-driver` + `devcon install`; `guest/deploy-and-test.ps1` does it) | Only needed for section 1.4. Sections 1.1–1.3 and 1.5–1.7 work on the Basic Display Adapter alone. |
| **Display topology: the IDD as the sole active output** (`tools/modeprobe --solo`; Basic Display Adapter disabled) | An active second monitor enlarges the desktop bounding box and breaks seamless coordinates; it also causes the fullscreen cursor offset. The solo topology persists across reboot. |
| **dom0 helper: work-area watcher** (`dom0/09-install-workarea-watcher.sh`) | Mirrors dom0's usable work area and WM frame extents into the qube's QubesDB. Without it the agent cannot compute maximize/tile sizes, so the blink-free habitual sizes, the 15 px snap and the fit guard degrade or go missing. dom0-local + QubesDB only; **no gui-daemon change, no policy change**. |
| **dom0 helper: resize service** (`dom0/10-install-resize-service.sh`) — optional | *Testing only.* It lets a dev qube script dom0-side window resizes. Ordinary use needs nothing: dragging the qube window sends the same `MSG_CONFIGURE` naturally. Selection is by the unforgeable `_QUBES_VMNAME` X property; resize only, no move/focus/input. |
| Guest hygiene: no idle lock screen / display blanking | A guest whose input comes from dom0 should not take the input desktop away. Input failures are no longer fatal (1.5), but the lock screen still eats input while it is up. |
| No GPU / no GPU passthrough | The capture property in 1.4 was validated on WARP only and is expected to fail with a real GPU. |

Not required: any change to gui-daemon, the GUI protocol, qrexec policy, or the security model.
Guest window content still crosses to dom0 exactly as before — read-only grants plus dirty-rect
metadata — and dom0 still draws its security borders around every mapped window. The chrome fix
works by not presenting chrome fragments as windows; it never lets the guest opt out of borders.

---

## 4. How to try it

The supported route is now the **release package** (`qwt-improved-setup`, built by GitHub
Actions), not the older binary-overlay script. Copy the package folder into the guest and run
`install.cmd` — everything below happens inside it.

1. **Build.** Push to the repo; GitHub Actions produces `qwt-improved-setup` (the installer,
   the MSI, the signing certificates, the IDD driver, `MANIFEST.json`, `SHA256SUMS.txt`) and an
   ISO of the same tree. Download with `gh run download`.
2. **Run `install.cmd`** in the guest, as Administrator. Add `/auto` to let it reboot and resume
   by itself; without it, the script stops at each reboot point and tells you to run it again.
   It verifies every payload file against `SHA256SUMS.txt` before touching the system and
   refuses to install anything it cannot verify.
3. **What it does on a guest that already has Qubes Windows Tools.** Windows Installer will not
   replace a file whose version is not newer, so installing over an existing QWT used to leave
   the *old* `gui-agent.exe` in place — the install reported success and none of the changes in
   this document were actually running. The installer now stops the agent and its watchdog,
   uninstalls the existing QWT first, removes any binaries it left behind, and only then
   installs. Because that uninstall asks for a reboot, an upgrade takes **one reboot more** than
   a clean install; with `/auto` this is automatic, otherwise the script exits and asks you to
   re-run it after rebooting.
4. **The gate that decides success.** After installing, the script hashes the `gui-agent.exe` it
   finds on disk and compares it to `MANIFEST.json`. If they differ the install FAILS loudly
   rather than reporting success — so "it said OK" now means the binary in this package is the
   one that will run.
5. **Install the display driver** (only for resolution following): run
   `guest/deploy-and-test.ps1` from the driver package; it emits a `=== RESULT ===` JSON block.
   Then `tools/modeprobe --solo <W>x<H>` to make the IDD the only active output, and reboot to
   confirm the topology persists.
6. **Install the dom0 work-area watcher**: `dom0/09-install-workarea-watcher.sh` (dom0, once).
   Removal instructions are in the script header.
7. **Verify.** Confirm the binary actually running matches the manifest hash — a deploy that
   silently failed reports results for a build that was never running. Then: open two
   overlapping windows and drag one (no debris, no wobble); open an Office document (one bordered
   window, no shadow band); drag the qube window's edge (guest resolution follows on settle);
   maximize and half-tile it (instant, no blink).
8. If the qube goes deaf (no qrexec, no window updates), that is 2.2: kill and restart the qube.
   If every window vanishes right after an agent restart, that is 2.1: restart the qube.

---

## 5. What is not claimed

That the visual defects are *gone from your screen*. Their mechanisms were found, fixed, and the
fixes verified by measurement, screenshot and protocol trace — but "does it look right in daily
use" is a human check, and several claims here (shadow cursor persistence, the held-frame
resize visual, real Office in a real Office qube) rest on exactly one or two user confirmations.
Nothing here has run for weeks on a working desktop, and the two known stability defects (2.1,
2.2) are the ones most likely to be what you actually hit first.

---

## 4. Added 2026-08-07 (release-qualification round)

### 4.1 A clean install now ships the display driver — arbitrary resolutions out of the box

`install.cmd /auto /idd` (what the unattended media runs) now **installs and activates** the
Qubes IddCx display driver: the device is created, the installer waits until a display
adapter is demonstrably up, and only then disables the emulated VGA adapter, so the first
boot after install comes up with the IDD driving the desktop and the agent publishing its
mode list. Previously the driver was only copied to the driver store ("staged, never
activated") and a clean guest silently shipped on the Basic Display Adapter with a fixed
mode list — no arbitrary-resolution support at all, and the old acceptance gate (a file
hash) could not see the difference. The new gate (`guest/health-check.ps1`) fails a guest
whose desktop is not on the IDD; it was validated by running it against exactly such a
degraded guest. *Full clean-path acceptance on this build: in progress.*

### 4.2 Seamless mode works on the IDD configuration

The mode set the driver publishes now always contains the host screen size while seamless is
active, so `SeamlessMode=1` actually enters seamless instead of failing with
`DISP_CHANGE_BADMODE`. Verified on a cold boot: mode entered, host 5120x1440 applied, each
guest window rendered as its own bordered dom0 window. (This is what makes the Office
window-behaviour checks runnable at all on an IDD guest.)

### 4.3 Stable DPI across resolution changes

The IDD's EDID used to declare a fixed physical monitor size, so Windows recomputed its
*recommended display scale* per applied mode — entering seamless at 5120x1440 silently
flipped the guest to 150 % and text changed size between runs (user-reported). The EDID now
declares the image size as undefined, which pins the recommendation at 96 DPI for every
resolution; a manual scaling override still works and persists. *Verified in source +
checksum; live verification pending the next driver install.*

### 4.4 Maximized windows and the dom0 workspace — NOT FIXED (attempt withdrawn)

A maximized window can still overflow the dom0 workspace, most visibly in the first minutes
of a boot before dom0's work-area feed reaches the guest. An attempt to fix this by clamping
the reported window geometry to the work area was **made and withdrawn the same day**: the
window rectangle is also what the per-window capture crops against, so clamping it cut the
title bar and menu bar off the window's own content. The real fix belongs in the work-area
path — making the guest work area stick so Windows maximizes into the right rectangle — and
is not in this release.

### 4.5 Honest open items (this round)

- **PV network is not bound on the reference guest**: networking works, but over the
  emulated Realtek NIC — xenvif runs, yet xennet never binds its child device (code 28)
  despite being installed. Whether stock QWT behaves identically here is not yet
  established. Functional impact: throughput/latency, not availability.
- `XENBUS\VBD` and `XENBUS\CONS` sit driverless by design (PV disk driver deliberately
  now INSTALLED, as stock QWT does; QWT ships no console driver).
- The Explorer-vs-agent work-area tug (Explorer recomputes from its taskbar, the agent
  re-asserts every 2 s) converges but is noisy; tracked.
