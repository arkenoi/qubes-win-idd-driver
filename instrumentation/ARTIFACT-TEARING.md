# RETRACTED: "framebuffer tearing" was a measurement artifact

**Status: the defect described in earlier revisions of this file does not exist.**
Retracted 2026-07-31 after fixing the measurement tool. Kept (rather than deleted) so the
error is not silently rewritten out of the record.

## What was claimed

That stationary windows showed 12-13 row "stale bands" in dom0 that never repaired, on both
the stock agent and ours, and that this was a real pre-existing QWT defect worth a Phase 3
protocol fix.

## Why it was wrong

`tools/compare-views.py` cropped the guest screenshot **centred** on the window rect:

    ox = wdef['x'] + (w - dw) // 2
    oy = wdef['y'] + (h - dh) // 2

The agent reports DWM **extended frame bounds**, which are smaller than `GetWindowRect` and
**not symmetric** about it. So the crop was off by ~4 rows. A 4-row vertical shift makes every
row of text in the window mismatch, and the run-length detector duly reported "bands".

The tool was diagnosing its own crop.

## Evidence

Same captures, same windows, only the alignment changed - the tool now calls `locate()` to
find the true offset before classifying:

| window | before (centred crop) | after (aligned crop) |
|---|---|---|
| Notepad 800x560 | STALE-BAND differing=4.5% mean=3.8 | **OK** differing=0.7% mean=0.1 |
| chromerepro 572x140 | STALE-BAND differing=14.3% mean=12.7 | **OK** differing=1.7% mean=0.3 |
| chromerepro 572x140 | STALE-BAND differing=14.5% mean=13.6 | CONTENT-DIFFERS differing=2.4% mean=0.8 |

Mean absolute difference of 12.7/255 dropping to 0.3/255 under a pure translation is
conclusive: the content was always correct, it was compared against the wrong rows. The true
alignments found were (-4,-4) and (0,-3) - exactly the extended-frame-bounds discrepancy.

The residual 2.4% at mean=0.8 is the Notepad caret blink, not a rendering fault.

## The tell I should have caught immediately

`mean=3.8` out of 255. Genuinely stale scanlines show whatever was there *before* - typically
a different window or background, i.e. a large difference. A mean difference of 1.5% is the
signature of **slightly misaligned identical content**, never of stale content. I reported a
defect whose own numbers argued against it.

## Consequences

* No tearing fix is needed. This is not a Phase 3 item.
* `instrumentation/artifact-tearing-*.png` are screenshots of correctly-rendered windows.
* Any earlier verdict from this tool that rested on crop alignment is suspect and must be
  re-run with the fixed version. See `WOBBLE-STATUS.md`, which independently retracts the
  (12,-8) drag reading for a different reason (capture skew on a moving window).

## Lesson

The rig had **two** independent flaws that both manufactured defects: wrong crop alignment
(this file) and multi-second skew between guest and dom0 captures (`WOBBLE-STATUS.md`). Both
produced confident, specific, plausible numbers. A measurement rig needs a null test - compare
a known-good static window against itself and require it to read OK - before any verdict from
it is trusted. That null test now exists implicitly: the aligned run above reads OK.
