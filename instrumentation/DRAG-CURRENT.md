# Drag frame cost on the current build — measured, and a problem

Build `f4695698af33`, running binary hash verified before the runs. Three runs, drag phase p50:

| run | drag p50 |
|---|---|
| 1 | 4900 us |
| 2 | 2983 us |
| 3 | 4374 us |

Under the 5 ms bar, but **run 1 is within 2% of it**, and this is a large regression against
earlier measurements of the same harness:

| build | drag p50 |
|---|---|
| `1245702` (before clipping / wobble work) | 917 us |
| `2a247ba` (wobble fix) | 1294 us |
| `f4695698` (current) | 2983-4900 us |

Roughly 4x slower than the Phase 2A result that criterion (a) was originally demonstrated on.

Likely contributors, not yet separated:
* `CollectZOrder` runs a bare `EnumWindows` every frame;
* the wobble fix calls `GetRealWindowRect` per watched window per frame, and that helper does
  `DwmGetWindowAttribute` + `GetMonitorInfo` + `EnumDisplaySettings`;
* region arithmetic for clipping, now only useful for popups after the z-order finding.

Since clipping was narrowed to override-redirect windows, the per-frame z-order pass and the
per-window rect refresh are being paid on every frame for a case that only applies when a popup
is on screen. That is the obvious place to look next.

Criterion (a) is met on these numbers but with no margin, and it should not be reported as
"0.9 ms" - that figure belongs to a build without these changes.

---

# The drag metric is not stable enough to use, and (a) is NOT met

Gating the two per-frame costs (z-order pass, per-window rect refresh) did not help:

| build | run 1 | run 2 | run 3 |
|---|---|---|---|
| `f4695698` | 4900 | 2983 | 4374 |
| `1aafdc9` (gated) | **7143** | 3657 | 4776 |

Three runs on ONE unchanged binary span 3657-7143 us. That is a 2x spread, so the harness
cannot distinguish these builds at all, and the earlier single-number quotes from it (917 us,
1294 us, 844 us) carry an unknown error bar - they are single samples of a metric never shown
to be stable.

**Criterion (a) is therefore not met.** A run exceeded 5 ms outright, and "median < 5 ms" cannot
be asserted from a measurement whose spread covers the bar.

Before any performance claim:
1. establish the drag harness's variance on one binary (>= 5 runs), and if it stays this wide,
   fix the harness - the scripted drag is probably racing window activation the same way the
   visual scene did before it was made to settle;
2. only then compare builds, interleaved, >= 3 runs each.

The optimisation itself is still justified on inspection (a full EnumWindows per frame for a
case active a second at a time, and a Dwm/monitor/display-settings query per window per frame),
but it has NOT been shown to help and must not be reported as an improvement.


---

# Resolved: the harness was contaminated, not the build

Clearing other app windows before measuring (see `drag-harness.ps1`) collapsed the spread:

| | runs | spread |
|---|---|---|
| contaminated harness, one binary | 3657 / 7143 / 4776 | 2.0x, one run OVER the 5 ms bar |
| fixed harness, one binary | 1817 / 2204 / 1753 | 1.26x |

So the earlier conclusion - that gating the per-frame z-order pass and rect refresh made things
worse - was wrong. `7143 us` was the bench dragging its Notepad across the two Notepads and
chromerepro the visual scene had left on screen; damage volume tracked window placement, not
the build.

## Criterion (a) on the fixed harness

Build `1aafdc9` (`EDD43F6F4784`), binary hash verified before every run, 6 runs:

`1817, 2204, 1753, 3616, 1447, 2230 us` -> **median ~2015 us, max 3616 us, none over 5 ms.**

## Stock cannot be the "before" side

`QGAPERF` is instrumentation added by this work, so stock QWT emits no records and the harness
measures nothing for it. Attempting a stock-vs-ours comparison on this harness silently
produced no stock numbers at all. The Phase 2A before/after is the Phase 1A instrumented build
vs Phase 2A - the committed `INTERROGATED/frame ~67 -> ~1` - not stock.
