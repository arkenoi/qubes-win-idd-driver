# Wobble: three attempts, one real bug fixed, cure UNVERIFIED

## What is established

* **Static registration is correct.** With the window stationary, dom0's content matches the
  guest at offset **(0, -4)** (the -4 is the DWM-border crop, not a defect). Measured with
  `tools/viewcheck`.
* **A genuine mis-registration bug existed and is fixed.** `ProcessNewFrame` called
  `TrackWindows()` first - updating every window's X/Y to *now* - and then converted *this
  frame's* dirty rects to window-relative coordinates by subtracting that new origin. The
  rects came from a frame captured *before* the update, so during motion the damage was
  mis-registered by exactly how far the window had moved. Fixed by snapshotting FrameX/FrameY
  before tracking and using it for both the intersection and the conversion. This is a real
  logic error independent of whether it is *the* wobble.
* **Tearing is independent of motion.** `STALE-BAND` (12-row bands) appears on *stationary*
  windows, so it is not drag-related. Pre-existing; see ARTIFACT-TEARING.md.

## What is NOT established, and why

**Whether the fix cures the visible wobble is UNVERIFIED.** `tools/viewcheck` cannot measure
a moving window: the guest capture and the dom0 capture are seconds apart, and at the test
drag speed (~360 px/s) the window travels hundreds of pixels in between, so the measured
offset is dominated by capture skew. The post-fix reading of (-118,-118) sat exactly at the
search-radius limit, which is the signature of skew rather than signal.

That also means the pre-fix reading of **(12,-8) was not reliable evidence** and should not
be cited as "the wobble measured at one frame of lag". It was consistent with that story,
but the method cannot distinguish it from where the window happened to be.

## Honest state of the three attempts

1. Emit geometry on the frame path instead of at input rate - **reverted**. Measured: drag
   frame rate rose to 23.3 fps with configure frame-synced, wobble unchanged. Timing was not
   the cause.
2. Freeze damage during an interactive drag, repaint on MOVESIZEEND - **reverted**. Did not
   fix the wobble AND introduced a worse failure: a missed MOVESIZEEND suppresses that
   window's damage *permanently* (user-reported: window partially blank, mouseover broken
   all over it).
3. Frame-registered damage - **kept**. Fixes a real logic error; static rendering verified
   unregressed; effect on the visible wobble needs a human, because the rig cannot see it.

## To close this properly
Either measure inside the guest (an agent-side log of the origin used per damage message vs
the window position at frame-capture time - fully autonomous, no capture skew), or accept a
human verdict. The former is the right next step and is cheap: the instrumentation already
emits a per-frame record; adding the origin delta to it would make the desync directly
observable in the QGAPERF log.
