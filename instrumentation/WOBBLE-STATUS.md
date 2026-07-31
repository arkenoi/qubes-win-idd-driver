# Wobble: root cause, one wrong fix reverted, and what is left

User report: "when i move a window, its contents also visually wobble within frame."
After Phase 2A: "the wobble is there, too... but visually less."

## Root cause

The transport is zero-copy by design (see CLAUDE.md fact 1): the agent grants the **whole
live desktop framebuffer** read-only, once. Per frame only dirty-rect metadata crosses the
vchan. So the gui-daemon paints a window by copying, out of that live buffer, the region

    (believed_x + rx, believed_y + ry)  ->  window pixmap at (rx, ry)

where `believed_x/y` is the position from the last `MSG_CONFIGURE` it processed, and `rx/ry`
are the window-relative coordinates in `MSG_SHMIMAGE`.

Two things are therefore required to be consistent, and only one of them can be:

1. **`rx/ry` vs `believed_x/y`** - the agent controls both, so this is a correctness
   invariant it can and must hold (see below).
2. **`believed_x/y` vs where the window actually sits in the framebuffer right now** - the
   agent does *not* control this. Windows moves and repaints the window in the shared buffer
   continuously; dom0 learns the new geometry only when the message arrives and is processed.
   dom0's geometry therefore always **lags** the framebuffer by the message+processing
   latency.

During a drag, that lag means dom0 copies from where the window *was* while the buffer holds
it where it *is*. The copied region is part window, part whatever the window has already
uncovered - and it lands in a frame drawn at the new position. That is the wobble.

**Amplitude is approximately `drag velocity x agent->dom0 geometry latency`.** This explains
the reported behaviour exactly, including why it got "visually less" but did not disappear
after Phase 2A: `SetWinEventHook` cut the geometry latency (position now goes out on the
input event rather than after the next capture+enumeration pass), which shrinks the product,
but nothing agent-side can drive it to zero.

Eliminating it requires geometry and content to be **atomic** - the daemon needs to know
which framebuffer state a given geometry belongs to (a frame/serial number carried on
`MSG_CONFIGURE` and `MSG_SHMIMAGE`, or damage in screen coordinates it can register itself).
That is a GUI-protocol change: **Phase 3**, design-writeup-and-upstream-review first, per
CLAUDE.md. It is not an agent bug and cannot be fixed inside the agent.

## A fix I attempted, shipped, and have now reverted

I believed I had found the mechanism: `ProcessNewFrame` intersects this frame's dirty rects
against each window's rect and converts to window-relative coordinates, but `TrackWindows()`
runs first and updates every window's position to *now*, while the dirty rects came from a
frame captured earlier. So I snapshotted each position before tracking (`WINDOW_DATA::FrameX/
FrameY`) and converted against the snapshot.

**This was wrong and made registration worse.** `TrackWindows()` does not merely update
positions - it calls `SendWindowConfigure(windowData->X, windowData->Y, ...)` (main.c ~1687).
So by the time the damage loop runs, dom0 has already been told the window is at `X/Y`, and
it will add `X/Y` back to whatever `rx/ry` we send. Converting against the pre-tracking
snapshot broke invariant (1): it mis-registered every dragged window by exactly one frame of
movement (~6 px at the ~360 px/s used in the drag harness) - which is itself a wobble
signature. Upstream's use of the current position was self-consistent and correct.

The invariant is now stated in the code so this is not re-attempted:

    // INVARIANT: the origin used to convert damage to window-relative coordinates must
    // be the same origin most recently sent in MSG_CONFIGURE ...

Note the intersection is still done against the current rect, which can clip a stale dirty
rect slightly at the edges during fast motion. That is a real but second-order effect, and
fixing it by moving the origin is exactly the error above.

## Retracted measurements

Two separate flaws in the rig each manufactured confident, specific, plausible numbers:

* **(12,-8) "about one frame of lag" during a drag** - `tools/viewcheck` captures guest and
  dom0 seconds apart. At ~360 px/s the window moves hundreds of pixels in between, so the
  correlation search was measuring capture skew. The post-"fix" reading of (-118,-118) sat
  exactly at the search-radius limit, the signature of skew rather than signal. The tool
  **cannot** measure a moving window and no drag verdict from it should be quoted.
* **Static "stale bands"** - a crop-alignment bug in `compare-views.py`; see
  `ARTIFACT-TEARING.md`, which retracts the tearing defect entirely.

## What is verified

* Static registration is correct: with the window stationary, dom0 matches the guest to
  within the DWM extended-frame-bounds offset ((-4,-4) / (0,-3)), content mean abs difference
  0.1-0.8 out of 255.
* The revert restores upstream's origin handling, so registration is no worse than stock.

## Status

**Wobble is understood, not fixed, and not fixable agent-side.** It is a Phase 3 protocol
item. Phase 2A's latency reduction is the whole of the improvement available without a
protocol change, and the user has confirmed that improvement is visible.
