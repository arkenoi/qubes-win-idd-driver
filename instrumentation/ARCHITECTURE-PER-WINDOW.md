# The radical fix: stop slicing a composited desktop

Every hard defect in this project is the same defect wearing different clothes.

| symptom | mechanism |
|---|---|
| menu items corrupt their host window on hover | dirty rect is in SCREEN coords, intersects both |
| debris when one window is dragged over another | same |
| text sliced off a window mid-drag | occluded region holds the occluder's pixels |
| contents wobble within the frame | damage registered against a position that has moved |
| stale bands when clipping IS applied | dom0 and guest disagree about z-order |

All of them exist because the guest captures **one composited desktop** and the agent slices
per-window rectangles out of it by screen coordinates. Anything that changes the relationship
between a window and its screen position - motion, occlusion, stacking - corrupts the slice.

## Why the guest should not know a window is being dragged

It currently does, and that is the root of it. Today the guest owns window position, dom0
mirrors it, and every move must be sent, re-registered, and re-sliced against a live
framebuffer. Wobble is literally the latency of that round trip.

In VMware Unity, VirtualBox seamless and RDP RemoteApp, the host owns placement. The guest
supplies **per-window content**; where that content is drawn on the host's screen is none of
the guest's business. Dragging a window on the host moves a host-side pixmap and the guest
never hears about it.

## What Windows already offers

Per-window capture that is unaffected by occlusion or stacking:

* **Windows.Graphics.Capture** (1803+) - per-HWND, DWM-backed, composited independently of
  what is on top;
* **`PrintWindow(..., PW_RENDERFULLCONTENT)`** - renders a window's full content even when
  occluded;
* DWM thumbnails, for a coarser version of the same idea.

With per-window content, occlusion clipping, z-order synchronisation, screen-coordinate damage
registration and the move-rect question all cease to exist - not "get fixed", cease to exist.

## What it would cost

The blocker is transport, not capture. Today one whole-desktop framebuffer is granted once
(`MSG_WINDOW_DUMP` with window 0) and only dirty-rect metadata crosses per frame. Per-window
capture needs a buffer and a grant per window.

`SendScreenGrants()` already sets `header.window = 0` and the protocol comment calls it
"screen", which strongly suggests `MSG_WINDOW_DUMP` is defined for a specific window id too. If
so, per-window grants may already be expressible - the daemon side would need checking, and
that is the first thing to establish.

CLAUDE.md says do not build transport replacements, and that instruction was right for the work
so far: the existing transport is genuinely zero-copy and fast. This is not a transport
replacement for speed, it is a change of what is captured, and it should not start without an
upstream design discussion (Phase 3, referencing qubes-issues #1861).

## Recommendation

The agent-side fixes in this repo are worth having and are verified: event-driven tracking,
the compound-window chrome fix, the input-desktop follow. They make the current model as good
as it can get.

They cannot make overlapping windows correct in motion, because the composited-desktop model
cannot express it. That needs per-window capture, and the honest next step is a design writeup
plus the daemon-side check above - not more clipping heuristics in the agent.
