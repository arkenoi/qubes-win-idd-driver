# Drag/scroll bench vs accepted baseline — from-source QWT on win-idd-test (Win10)

Date: 2026-08-01 ~23:53–23:56. Handoff step 5.4 ("drag/scroll vs the instrumentation/
baseline"). **VERDICT: FAIL** — drag frame cost p50 is 16.1–17.2 ms against a bar of
< 5 ms and an accepted baseline of 0.917 ms (17.6–18.8x regression). All other phases
improved; the failure is drag-specific and fully attributed (below).

## Setup

- Guest: win-idd-test, Win10 Pro 19045, pristine from-source QWT install
  (installer.msi `ff89da3c…`, gui-agent.exe `654de8eb…` = agent `382fa05` on `perwindow`
  — per-window PrintWindow capture + composite synthesis). Hash verification: see the
  step-4 acceptance table in `SESSION-HANDOFF-qwt-full.md`.
- Harness: `tools/bench-agent.sh` (unmodified), which drives
  `instrumentation/drag-harness.ps1` — the deterministic version (clears other app
  windows first; see `instrumentation/DRAG-CURRENT.md` for why that matters).
  Same dom0 screen as baseline (3440x1440), same Notepad size/position
  (800x600 at (1320,420)), same phase durations and input rates.
- Analysis: `instrumentation/analyze-perf.py --markers <harness-json>`, per-phase `tot`
  p50/p95 — verified to be the accepted method by re-running it on the baseline raw file
  `instrumentation/bench-e2e-final.txt` and reproducing the accepted figures exactly
  (drag p50 917 us, INTERROGATED/frame 1.03). Output: `analyze-baseline-e2e-final.txt`.
- PerfLog: compile-time default ON in this build (`QGA_PERF_DEFAULT 1`, emits at
  LOG_LEVEL_INFO), so no LogLevel change was needed or made.
- Two full runs (labels `qwtfull-w10`, `qwtfull-w10-r2`) to bound the harness variance
  documented in DRAG-CURRENT.md. Harness `ok=true`, SendInput verified, cadence on
  target in both.

## Results — per-phase frame cost `tot` (us), this build vs accepted baseline

Baseline = `bench-e2e-final.txt` (Phase 2A screen-slice build `1245702`, the build the
bars were set on).

| phase | baseline p50 | baseline p95 | run1 p50 | run1 p95 | run2 p50 | run2 p95 | p50 delta |
|---|---|---|---|---|---|---|---|
| idle-pre | 522 | 5969 | 99 | 24051 | 101 | 9266 | **0.19x (better)** |
| **drag** | **917** | 1790 | **17218** | 49538 | **16128** | 50973 | **17.6–18.8x (REGRESSION)** |
| scroll | 493 | 642 | 117 | 241 | 86 | 212 | **0.17–0.24x (better)** |
| type | 531 | 1313 | 114 | 1810 | 81 | 1834 | **0.15–0.21x (better)** |
| idle-post | 684 | 7372 | 103 | 7988 | 89 | 10781 | 0.13–0.15x (better) |

(Idle p95s in all columns come from <=10 records per phase — indicative only.)

| metric | bar | baseline | run1 | run2 | verdict |
|---|---|---|---|---|---|
| drag frame cost p50 | < 5 ms | 0.917 ms | 17.2 ms | 16.1 ms | **FAIL (3.2–3.4x over bar)** |
| INTERROGATED/frame (drag) | ~1 | 1.03 | 1.93 | 2.04 | **above bar (~2)** |
| no phase p50 regression > 2x | — | — | drag 18.8x | drag 17.6x | **FAIL (drag only)** |

Other drag-phase observations: achieved frame rate is HIGHER than baseline (23.7/24.3 fps
vs 16.4), scroll/type/idle p50s are all 4–6x BETTER than baseline, and wakeup latency
(`wak`) during drag averages 5.5 ms. Move-rects: max seen 0, both runs (unchanged verdict).

## Where the drag milliseconds go (attribution, run 1 drag phase)

```
tracking (upd+enu+rem)   20138 us/frame   98.8% of wall   (upd alone: p50 17060 us, 92.6%)
damage   (drq+dmg)         107 us/frame    0.5%
send     (snd)              14 us/frame    0.1%
```

`upd` (UpdateWindowData) is the per-window capture path: under the `perwindow`
architecture a dragged window is re-captured via `PrintWindow(PW_RENDERFULLCONTENT)`
and row-diffed into its granted buffer on every damaged frame. The entire regression sits
in that one field; damage extraction and vchan send remain microseconds. Scroll/type do
NOT pay this because scroll damage is throttled/diffed within a static window, while a
drag dirties the window's full extent (dirty_px/frame ~552k = ~800x600+chrome) every frame.

## Honest framing

1. The accepted baseline (917 us) was measured on the **screen-slice** architecture,
   which sent dirty-rect metadata over an already-granted full-desktop framebuffer
   (near-zero per-frame pixel work). The current `perwindow` architecture does real
   per-frame pixel capture+copy for the moving window. **This is the first drag/scroll
   bench ever recorded for the perwindow line** — nothing in `instrumentation/` or
   FINDINGS benchmarks ec55f39/be6cacf — so this measurement cannot distinguish "cost
   present since the architecture landed" from "regression introduced later on the
   branch". Either way the measured number is 3.2x over the accepted bar.
2. The two runs agree within 7% (17218/16128), so this is not the harness instability
   documented in DRAG-CURRENT.md (that was fixed; fixed-harness spread on one binary was
   1.26x, far too small to explain 18x).
3. `tot` is agent main-thread frame cost, not end-to-end perceived latency; dom0
   compositing cost is not measured here. Note the agent still ACHIEVED 23.7 fps during
   drag (records arrive per-damage-frame), so the user-visible effect of 17 ms/frame vs
   0.9 ms/frame needs a dom0-side or subjective check to quantify — but the bar as
   written is on frame cost, and it is not met.
4. `INTERROGATED/frame` ~2 during drag (vs 1.03 accepted): consistent with the desktop
   window + the dragged window both being touched per frame under perwindow; modestly
   above the "~1" bar, secondary to the drag cost.

## Evidence files (this directory)

- `bench-qwtfull-w10.txt(.harness)`, `bench-qwtfull-w10-r2.txt(.harness)` — raw QGAPERF
  records + harness transcripts (copies; originals also at `instrumentation/bench-qwtfull-w10*.txt`)
- `markers-qwtfull-w10*.json` — phase markers extracted from the harness RESULT JSON
- `analyze-qwtfull-w10.txt`, `analyze-qwtfull-w10-r2.txt` — full per-phase analyzer output
- `analyze-baseline-e2e-final.txt`, `markers-baseline-e2e-final.json` — baseline
  re-analysis proving the comparison method reproduces the accepted 917 us / 1.03 figures

Guest left clean: harness killed its Notepad, no chromerepro, gui-agent alive
(`STATE=agent:True,notepad:False,chromerepro:False`), LogLevel untouched.
