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
