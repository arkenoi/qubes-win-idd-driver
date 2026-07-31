# wgcprobe — Windows.Graphics.Capture feasibility probes (Q4, Q3)

`wgcprobe check` — WGC support + API-presence probes (DirtyRegions / IsBorderRequired /
IsCursorCaptureEnabled), then captures a fully occluded static pattern window via WGC and
byte-compares the delivered frame against the exact pattern. Verdict line
`WGCPROBE-CHECK: occluded-content=MATCH|MISMATCH`; occlusion asserted via WindowFromPoint.

`wgcprobe bench <K> <frames> [w h]` — K animated (16 ms invalidate) pattern windows, all
captured concurrently; per-frame staging-copy+Map cost (p50/p95 µs), aggregate fps, process
CPU seconds. Run K = 1, 4, 10, 30 interleaved with a ddaprobe DDA control on the same guest.

`wgcprobe benchstatic <K> <seconds> [w h]` — same scene, windows NOT animated: separates
scales-with-count from scales-with-damage.

Output ends with `=== WGCPROBE JSON ===` + one single-line JSON, ddaprobe-style.

The staging copy + Map is measured deliberately: WGC surfaces are GPU-side, and the copy is
the honest per-frame price of feeding the existing grant-based (CPU memory) transport.
