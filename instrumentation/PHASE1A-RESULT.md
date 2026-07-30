# Phase 1A decision point — ANSWERED: window enumeration dominates, overwhelmingly

Measured on win-idd-test (Win10 Enterprise LTSC 2021, 19044.1288, 4 vCPU, 8 GB) with the
instrumented `gui-agent.exe` built from `arkenoi/qubes-gui-agent-windows @
phase1a-instrumentation`, driven by `instrumentation/drag-harness.ps1`
(idle → 10 s window drag → idle → 10 s scroll → idle → 10 s typing → idle).
499 per-frame records, 75.3 s span. Raw log: `phase1a-perf-raw.txt`.

## Result

```
                       mean_us      p50      p95      p99      max    share
  enu  (EnumWindows)    31838    23070    80984   110133   177444    97.5%
  upd  (UpdateWindowData)  577      374     1788     2964     5626     1.8%
  snd  (vchan send)         92       58      222      517     1497     0.3%
  drq  (GetFrameDirtyRects) 52       36       81      145     2135     0.2%
  dmg  (damage processing)  32       20       78      184      653     0.1%
  mrq  (GetFrameMoveRects)  22       15       45       95      673     0.1%
  rem  (window removal)      6        5       11       31       80     0.0%
  tot  (ProcessNewFrame)  32596    23607    81854   110711   180720

  tracking (upd+enu+rem)   99.2% of wall     achieved 6.6 fps
  damage   (drq+dmg)        0.3% of wall     dirty rects/frame 2.49
  send     (snd)            0.3% of wall     sends/frame 3.61
  instrumentation self-cost   92 us/frame    (qpc_cost_ns = 5284)
```

**Per-frame `EnumWindows` costs a mean of 32 ms and up to 177 ms — 97.5% of all frame
time.** Damage extraction and vchan send together are 0.6%. The agent achieved only
**6.6 frames/sec** during the harness, and essentially all of that time is spent
enumerating windows, not moving pixels.

This settles the question CLAUDE.md flagged as UNVERIFIED ("Causality of drag lag is
UNVERIFIED ... instrument before implementing"). The `main.c` "use window hooks" TODO is
not a micro-optimisation; it is *the* bottleneck. omeg's #1045 blamed input simulation —
on this configuration the dominant cost is enumeration.

⇒ **Phase 2A scope is confirmed as written**: replace per-frame `EnumWindows` with
`SetWinEventHook` (`EVENT_OBJECT_LOCATIONCHANGE/CREATE/DESTROY/...`) window tracking.
Damage coalescing is NOT worth doing first — there is almost nothing to win there.

## CORRECTION: it is not the `EnumWindows` syscall — it is uncached REJECTS

"enu = EnumWindows is slow" was the wrong label. `EnumWindows` itself is cheap. The bracket
measures `AddAllWindows()`, and the cost is inside the per-window callback:

`AddWindowsProc()` early-outs **only** for windows already in the watched list
(`FindWindowByHandle`). Every **rejected** window falls through to `GetWindowData()` +
`ShouldAcceptWindow()` again on **every frame, forever** — rejects are never cached.
`GetWindowData()` does, per window: `malloc`, **`GetWindowText`** (a synchronous
CROSS-PROCESS `WM_GETTEXT` for windows owned by other processes), `GetClassName`,
`IsWindowVisible`, and **`DwmGetWindowAttribute(DWMWA_CLOAKED)`** (an RPC to DWM).

Measured on the guest: **68 top-level windows, exactly 1 accepted → 67 re-interrogated every
frame**, at ~340 us each (23 ms median / 67). `enu` never falls below 14 ms in 499 frames,
which is what made the "EnumWindows" label implausible and led to finding this.

This sharpens Phase 2A: the win is not merely "call EnumWindows less often", it is "stop
re-interrogating windows you already rejected", which SetWinEventHook delivers by
construction — plus a reject cache with correct invalidation, since a rejected window can
later become eligible (shown, uncloaked, renamed, moved on-screen).

## Move rects: dead end, confirmed twice

`max GetFrameMoveRects count seen = 0` across all 499 frames, including a 10 s window drag.
Independently, `ddaprobe` saw zero move rects in a separate 25 s drag. The parenthetical at
`capture.c:441` ("they seem to always be empty when testing") is correct on the Basic
Display Adapter. **Do not implement move-rect forwarding for this path.**

## CORRECTIONS to the earlier BDA baseline (BASELINE-bda.md)

Two numbers in the first baseline were measurement artifacts of `ddaprobe`'s own
`--timeout` parameter (default 100 ms), NOT properties of the adapter. Retracted:

| claim | status |
|---|---|
| "BDA Desktop Duplication is ~9 Hz-bound; ~109 ms between frames" | **RETRACTED.** 109 ms ≈ the 100 ms `AcquireNextFrame` timeout + overhead. Re-run with `--timeout 8`: block time drops to **16.2 ms** mean. The 109 ms was self-inflicted. |
| "AcquireNextFrame median latency 82 ms under load" | **RETRACTED.** Same cause — the call blocks up to the timeout waiting for damage. With `--timeout 8` the median acquire latency is **5.3 ms**. |
| "DesktopImageInSystemMemory = TRUE, stable" | **STANDS** — reproduced in every run, agent running and stopped. Track B remains Outcome A. |
| "dirty damage arrives as ~1 coarse rect/frame" | **STANDS**, refined: the agent measures 2.49 dirty rects/frame under the harness. |

Control experiment for the retraction: ddaprobe re-run with the gui-agent **stopped** gave
a timeout block of 109.31 ms vs 109.10 ms with it running — i.e. the agent's enumeration
storm was not causing the cadence; the timeout parameter was. Lowering the timeout to 8 ms
moved it to 16.2 ms, which is the direct proof.

**Consequence:** the earlier inference "the capture source caps responsiveness, so Track B
outranks Track A" is **withdrawn**. The evidence now points the other way: the source is
fast (5 ms acquires), and the agent's own per-frame `EnumWindows` is burning 32 ms/frame.
Track A's `SetWinEventHook` rework is the high-value work, exactly as CLAUDE.md ordered it.

## Method note (why the harness's own numbers are not used)

`drag-harness.ps1` drives input at a *chosen* 60 Hz; that is a stimulus rate, not a
measurement. Its "jitter" figure samples the schedule error *before* the wait, so it
reports ≈ period − work (~16 ms at 60 Hz) and goes *down* under load — it is not a valid
load indicator and is not used in any conclusion here. (Known defect, flagged in review.)
All figures above come from `QueryPerformanceCounter` inside the agent, with the
instrumentation's own cost measured (92 µs/frame) and reported separately.
