# Design handoff — per-window capture for QWT seamless mode

Prepared for a follow-on design session. Everything below is either measured in this repo or
flagged explicitly as unverified. Nothing here has been proposed upstream.

---

## 1. The problem, stated once

The guest captures **one composited desktop** (DXGI Desktop Duplication) and the agent slices
per-window rectangles out of it using **screen coordinates**. Every hard defect in this project
is a consequence of that single choice:

| symptom | evidence in repo |
|---|---|
| menu hover corrupts its host window | `ACCEPTANCE-PROTOCOL.md` - same damage rect sent to menu AND window beneath, 10x in one scenario |
| debris when dragging one window over another | `ARTIFACT-ZORDER.md` - reproduces identically on stock 4.2.2 |
| window text sliced away mid-drag | `visual/overlap-in-motion.png` - dom0 draws chromerepro on top, guest has Notepad on top |
| contents wobble within the frame | `DRAG-CURRENT.md`, `WOBBLE-STATUS.md` - damage registered against a position that has moved |
| stale bands when clipping IS applied | `OVERLAP-IN-MOTION.md` - band vanished when guest stacking was forced to agree with dom0's |

Clipping cannot fix this. Two independent stacking orders exist (guest's and dom0's) and the
agent controls neither. Withholding damage produces stale regions; not withholding it produces
bleed. Both were built and measured here.

## 2. Proposed direction

Guest supplies **per-window content**; dom0 owns placement. The guest stops needing to know
where a window is on screen, or what is on top of it.

Windows offers occlusion-independent per-window capture:
* `Windows.Graphics.Capture` (1803+), DWM-backed, per-HWND;
* `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)`;
* DWM thumbnails (coarser).

This is how VMware Unity, VirtualBox seamless and RDP RemoteApp work, and it is why they do not
exhibit these artefacts.

---

## 3. Questions that need decisions

### Q1 — Does the protocol already allow a per-window framebuffer grant?
`SendScreenGrants()` sends `MSG_WINDOW_DUMP` with `header.window = 0`, commented "screen". Is
`MSG_WINDOW_DUMP` defined for a non-zero window id, and does the **daemon** honour it as that
window's backing store? If yes, per-window capture needs no protocol change at all - this is
the single highest-value question and it is answerable by reading gui-daemon.

### Q2 — Grant budget
One grant per window instead of one for the desktop. What is the practical ceiling on
`XcGnttabPermitForeignAccess2` grants for a busy desktop (30+ windows), and what is the
re-grant cost when a window resizes? A 4K window is ~33 MB; today's model grants that once,
per-window grants it per window.

### Q3 — Capture cost
DDA gives one GPU-side capture for the whole desktop. WGC gives one capture item per window.
Does N-window capture cost more than one desktop capture, and does it scale with window count
or with total damaged area? Measure before committing.

### Q4 — What happens to `DesktopImageInSystemMemory`?
`capture.c:176-183` hard-fails when that flag is FALSE (CLAUDE.md fact 2). Does WGC give a
CPU-mappable surface at all, or does per-window capture require a staging copy per window per
frame - and does that erase the zero-copy property the current transport is built on?

### Q5 — Incremental or replacement?
Can per-window capture coexist with the composited path (e.g. per-window for normal windows,
composited fallback for fullscreen), or is it all-or-nothing? A migration that can be enabled
per-window is far more reviewable upstream than a flag day.

### Q6 — What does dom0 owning placement mean for the guest?
If dom0 owns window position, `MSG_CONFIGURE` becomes advisory or reverses direction. What
tells the guest to resize a window when the user resizes it in dom0? This is the part that
touches the protocol most and needs upstream agreement before any code.

### Q7 — Security review
Per-window grants mean dom0 maps more, smaller guest buffers. Does that change the attack
surface versus one large read-only desktop grant? Anything that weakens isolation is out of
scope, per CLAUDE.md.

---

## 4. Cheap checks to run first, in order

1. **Q1 by reading gui-daemon** - no VM time, decides whether this is a protocol change at all.
2. **`PrintWindow(PW_RENDERFULLCONTENT)` on an occluded window** in the test VM: does it return
   correct content while another window covers it? One small tool, minutes to answer, and it
   validates the whole premise.
3. **WGC availability** on the Win10 22H2 test guest, and whether its surface is CPU-mappable
   (Q4).

If (2) fails, the premise is wrong and this document is void.

---

## 5. What already works and should not be disturbed

Verified in this repo, all agent-side, all inside the current model:
* event-driven window tracking (`SetWinEventHook`) - interrogations/frame ~67 -> ~1;
* compound-window chrome rejection - dom0 windows 8 -> 4, shadow strips 4 -> 0, 3 runs per side,
  binary hash verified;
* input-desktop follow - fixes an intermittent cold-boot failure where the agent stayed on the
  Winlogon desktop and never saw the user's windows;
* two `CloseDesktop` API-contract violations removed, one of them in stock upstream code.

`upstream/phase2a-chrome.patch` is a 3-commit series on upstream `431e4517`, verified to build
standalone in CI. Not submitted.

## 6. Method notes for whoever picks this up

Three separate metrics in this project looked trustworthy and turned out to be noise (see
`RETRACTIONS.md`). The rules that catch it are in CLAUDE.md; the short version:
* characterise any instrument on ONE unchanged binary, >= 3 runs, before comparing anything;
* verify the binary under test is actually installed (hash against the manifest);
* a check that has never been seen to FAIL on a build containing the defect is not evidence;
* judge output, not logs - `RecreateDuplication: recovered - windows kept` was logged while
  every dom0 window was frozen;
* test the cold-boot path; restarting the agent in a live session hides at least one real bug.
