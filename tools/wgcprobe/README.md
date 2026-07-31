# wgcprobe — Windows.Graphics.Capture feasibility probes (Q4, Q3)

`wgcprobe check` — WGC support + API-presence probes (DirtyRegions / IsBorderRequired /
IsCursorCaptureEnabled), then captures a fully occluded static pattern window via WGC and
byte-compares the delivered frame against the exact pattern. Verdict line
`WGCPROBE-CHECK: occluded-content=MATCH|MISMATCH`; occlusion asserted via WindowFromPoint.

`wgcprobe bench <K> <seconds> [w h [tile]]` — K animated pattern windows on a DEDICATED
scene thread (capture polling cannot be starved by painting), all captured concurrently for
a fixed duration; per-frame staging-copy+Map+**full readback** cost (p50/p95 µs — the honest
price of feeding the grant transport), per-window and aggregate fps, probe CPU AND
system-wide busy seconds (WGC's work happens in dwm.exe, invisible to GetProcessTimes).
`tile` bounds per-tick damage (default 128; 0 = invalidate the whole window each tick), so
K-scaling can be measured at constant damage and damage-scaling at constant K.
Run K = 1, 4, 10, 30 interleaved with a ddaprobe DDA control on the same guest.

`wgcprobe benchstatic <K> <seconds> [w h [tile]]` — same scene, windows NOT animated:
separates scales-with-count from scales-with-damage. Runs the full duration regardless of
how many frames arrive.

Output ends with `=== WGCPROBE JSON ===` + one single-line JSON, ddaprobe-style.

The staging copy + Map is measured deliberately: WGC surfaces are GPU-side, and the copy is
the honest per-frame price of feeding the existing grant-based (CPU memory) transport.
