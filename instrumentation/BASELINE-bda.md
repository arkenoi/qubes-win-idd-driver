> **PARTIALLY RETRACTED — see PHASE1A-RESULT.md.** The latency figures below
> ("~9 Hz ceiling", "median 82 ms") are artifacts of ddaprobe's own 100 ms
> `--timeout`, not properties of the adapter: with `--timeout 8` the block time is
> 16.2 ms and median acquire latency 5.3 ms. The DesktopImageInSystemMemory=TRUE
> and zero-move-rects findings STAND.

# Baseline measurement — Basic Display Adapter, win-idd-test (Win10 LTSC 2021, 19044.1288)

First real measurements of the QWT capture path, taken with `tools/ddaprobe` against the
stock emulated Basic Display Adapter (no IDD driver installed yet). This is the reference
every Track A/B change is measured against.

Method: `ddaprobe.exe <frames> <max_seconds>` run via qrexec in Console session 1 (no
elevation). Two runs — idle desktop, and desktop under continuous damage from
`instrumentation/activity-gen.ps1` (a form dragged in a circle at 60 Hz while repainting).
Raw JSON archived alongside this file's commit.

## Results

| metric | idle | under activity |
|---|---|---|
| output | Microsoft Basic Render Driver, `\\.\DISPLAY1`, 3440x1440, attached | same |
| **DesktopImageInSystemMemory** | **TRUE** | **TRUE** (never flipped) |
| MapDesktopSurface | OK, pitch 13760, non-null pBits | OK |
| loop iterations / acquired / timeouts | 136 / 1 / 135 | 247 / 49 / 198 |
| AcquireNextFrame latency (ms) | n=1: 216 | n=49: min 0.37, **mean 69, median 82, p95 96, max 102** |
| timeout block wait (ms) | mean 109, max 111 | mean 109, median 109, max 132 |
| dirty rects / frame | 1 (full-screen area) | **exactly 1**, ~101 kpx avg |
| **MOVE rects** | **0** | **0** (window dragged in a circle throughout) |
| errors / ACCESS_LOST | 0 / 0 | 0 / 0 |

## What this establishes (decision-relevant)

1. **Track B is Outcome A (per CLAUDE.md Phase 1B).** `DesktopImageInSystemMemory` is TRUE
   on the BDA and never flips across a full run. So an IddCx monitor can slide UNDER the
   existing capture path as incremental work — *provided the IDD-backed desktop keeps this
   flag TRUE*. That is now the single measurable acceptance gate for Track B: re-run
   ddaprobe with the IDD primary and confirm the flag stays TRUE (and that
   `agent_output_index`, adapter 0, is still the IDD or still valid).

2. **The BDA capture path is itself ~9 Hz-bound.** `AcquireNextFrame` returns a new frame
   at best every ~109 ms (the steady timeout-block interval); median acquire latency under
   load is 82 ms. This is a hard ceiling in the *duplication source*, before any agent
   enumeration/send cost — it means window-drag smoothness cannot exceed ~9 fps on the BDA
   no matter how well Track A optimises the agent. Strong argument that Track B (a real IDD
   monitor presenting at a proper refresh rate) is where the large 2D-responsiveness win
   lives, and re-ranks it UP relative to agent-only tuning. (Caveat: the emulated refresh
   reports as "unknown" (0xFFFFFFFE); the ~9 Hz is the *observed* delivery cadence, likely a
   QEMU stdvga / DDA-on-BDA property — worth confirming this ceiling lifts with a real IDD.)

3. **Move rects are always empty on the BDA — confirmed, not folklore.** Zero move rects
   across an idle run AND a run with a window dragged in circles for 25 s. The
   `capture.c:441` TODO's parenthetical ("they seem to always be empty when testing") is
   correct for this path. Track A's SetWinEventHook rework should NOT add move-rect
   forwarding for the BDA; damage always arrives as dirty rects (exactly one coarse rect
   per acquired frame here).

4. **Dirty granularity is coarse: 1 rect/frame.** DXGI coalesces all damage into a single
   dirty rect per frame on this path (16 bytes metadata = one RECT). So agent-side
   per-rect batching has little to coalesce here; the cost, if any, is in the *area*
   repainted, not rect count. Phase 1A instrumentation should confirm whether repaint/area
   or window-enumeration dominates — the ddaprobe numbers say the capture *source* is the
   dominant latency term regardless.

## Next measurements
- Re-run under the Phase 1A instrumented agent + `drag-harness.ps1` to split agent-side
  tracking/damage/send costs and correlate with these source-side numbers.
- Install the IDD sample (once it targets 19044 and the guest allows elevated install) and
  re-run ddaprobe with the IDD primary → the Outcome-A gate for Track B.

## Build status (2026-07-31)

Track A build chain **converged and green** — no EWDK, no WDK, pure user-mode v143.
Three CI iterations were needed, each fixing a real, verified defect:

1. `-t:libxenvchan` on the pvdrivers **.sln** still ran the sibling `pvdrivers.vcxproj`
   custom build (compiles the KMDF drivers via build.ps1) → MSB3073. Fix: build
   `vs2022/libxenvchan/libxenvchan.vcxproj` directly. Only pvdrivers bundles a driver
   project; core-vchan-xen / windows-utils / core-qubesdb solutions are user-mode only.
2. Building a .vcxproj directly roots `$(SolutionDir)`-based OutDirs at the PROJECT dir
   (`vs2022\libxenvchan\x64\Release\...`), not the solution dir. Fix: `Stage()` now
   locates each built .lib by filename under `x64\<cfg>`, newest wins.
3. (from review, pre-applied) `QUBES_INCLUDES`/`QUBES_LIBS` must be rebuilt after every
   Stage — libvchan and qubesdb-client resolve staged deps only through those vars.

Artifacts now produced by CI (`gui-agent-package`):
`gui-agent.exe`, `gui-watchdog.exe`, `dump-windows.exe` (+ PDBs).

**Instrumented agent built.** `agent/` submodule bumped to
`arkenoi/qubes-gui-agent-windows @ phase1a-instrumentation` (363b38a); the patch compiles
clean under the project's `/W4 /WX-ish /permissive- /std:c17` settings. Verified in the
shipped binary (UTF-16 strings): `PerfLog`, `QUBES_GUI_PERF`, `QGAPERF-HEADER`,
the per-frame `QGAPERF,v=..` record, and `QGAPERF-MOVERECTS`. Size 74240 → 79872 bytes.

Remaining to close Phase 1A: swap the instrumented binary in (guest/swap-agent.ps1, needs
the UAC-disabled VM currently reinstalling), run instrumentation/drag-harness.ps1, and feed
the log to instrumentation/analyze-perf.py for the tracking-vs-damage-vs-send decision.
