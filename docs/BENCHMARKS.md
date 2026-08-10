# Benchmark history and analysis

Everything measured about this build's performance, in full: the four-install comparison
and its confounds, the single-variable stock comparison, the retractions, and the root-cause
analysis. The README carries only the current verdict; this document is the record of how it
was reached. Raw per-session data and the running lab notebook are in `FINDINGS.md`.

## Current state (2026-08-10) — read this before the history below

The sections that follow are the RECORD, kept verbatim, and several of their verdicts are
**superseded**: the "2× stock on typing" result was real for the build it measured, was
root-caused to a standing idle burn (the per-window engine's 250 ms sweep), and the fix
(`SweepDdaExempt`, default on) is verified. Post-fix numbers, one-binary A/B with the
defect deliberately re-introduced as control (agent `09b643e`, 2026-08-10):

| phase | with fix | defect re-enabled | stock reference | pre-fix |
|---|---:|---:|---:|---:|
| typing | **1.71** | 3.93 | 2.02–2.19 | 4.38 |
| idle | **0.83** | 2.86 | 0.57 | 3.04 |
| drag | **8.67** | 13.15 | 12.31 | ~11.6 |
| scroll | **3.51** | 5.51 | 4.37 | ~5.3 |

The agent now costs less than stock on typing, drag and scroll; idle is the one phase
still marginally above stock (+0.26 points). Caveat kept honest: the stock column is the
2026-08-09 run's reference (same guest, same harness, hash-verified), not a same-day
interleaved side. Everything below this line is history.

## The four-install comparison (early August 2026, superseded as evidence)

Four clean installs, two platforms × two builds, differing **only in the MSI** — both sides
installed by the identical installer through the identical clean-room path (untouched vendor
ISO, answer file and payload on a small emulated USB stick).

Protocol: 3 repetitions per cell, **interleaved** across all four cells rather than run in
blocks, one guest running at a time, and the running agent binary hash verified before every
repetition. All 12 cells valid; none discarded.

**Caveat (2026-08-09):** "differing only in the MSI" was never single-variable — the four
cells differ in install *and* display stack (ours runs the desktop on the IddCx driver; stock
has no display driver at all), not only in the agent. One condition alone — DDA-sourced
capture on vs off, same binary — swings our typing cost from 12.4 to 4.4, so cross-cell CPU
comparisons in this table cannot carry improvement claims on their own. The table stays as
historical data; the single-variable experiment below is the authoritative stock comparison.

```
stock  win10   agent 3D2E6BCEC9F5BD89      ours  win10   agent CBBD02069A01E047
stock  win11   agent 3D2E6BCEC9F5BD89      ours  win11   agent CBBD02069A01E047
```

## gui-agent CPU (% of one core, median of 3)

| workload | stock win10 | ours win10 | stock win11 | ours win11 |
|---|---:|---:|---:|---:|
| drag    | 33.09 | 12.96 | 12.33 | 16.11 |
| scroll  | 47.83 | 8.91  |  4.06 | 13.93 |
| typing  | 32.61 | 4.38  |  3.13 | 14.99 |
| idle    |  0.105|  0.027|  0.000|  0.240 |

(An earlier revision bolded the ours-win10 cells as wins; the emphasis is removed for the
same reason the "clear, consistent win" wording below is withdrawn — these cells cannot
carry a win claim.)

## In-guest renderer — instrumentation-independent, but still cross-install

| metric | stock win10 | ours win10 | stock win11 | ours win11 |
|---|---:|---:|---:|---:|
| fps, moving rect       | 314.6 | **806.5** |  937.7 | 1090.2 |
| fps, full repaint      | 804.2 | 910.2     | 1172.6 | 1307.2 |
| frame delay p50, move  |  2.91 | **0.86**  |   0.63 |   0.57 |
| frame delay p95, move  |  5.03 | 3.03      |   3.00 |   2.75 |
| frame delay p99, move  |  8.76 | 4.76      |   5.54 |   5.44 |
| idle working set (MB)  | 108.5 | 68.2      |   99.7 |   54.1 |

These numbers do not depend on our perf logging, but they inherit the same four-install
confound as the CPU table: the cells differ in install *and* display stack, and the display
stack affects renderer throughput and latency directly. Like the CPU cells, they are
historical data, not a demonstrated win.

## How to read this

**The Windows 10 cells favour this build on every dimension measured** — CPU, throughput,
latency and memory — but the table cannot prove a win, because those cells compare different
installs and display stacks, not just the agent. An earlier revision of this paragraph called
Windows 10 "a clear, consistent win"; that claim is withdrawn as stated. The fork's
self-introduced per-frame overhead (next subsection) is version-agnostic, and no
single-variable Windows 10 comparison has been run.

**On Windows 11 our build costs more CPU than stock** — 16.1 vs 12.3 on drag, 13.9 vs 4.1 on
scroll, 15.0 vs 3.1 on typing. An earlier revision of this paragraph said this was "*not*
established as a regression" because the two Win11 rows differed in display stack too, and
that it "deserves a dedicated experiment — IDD vs BDA on the *same* agent — before anyone
claims either result". That dedicated experiment has now run (next subsection) and settled
it: on typing the regression is real, +100 % vs stock with non-overlapping distributions;
drag and scroll remain inside noise. Our Win11 row here still shows higher throughput, lower
frame delay and roughly half the idle working set — but those cells carry the same
cross-install confound as everything else in this table and are not claimed as advantages.
(The single-variable run did independently confirm one of them: over a 110 s workload the
fork's working set stays flat while stock's grows ~87 MB.)

**The artifact and z-order defects above are not in this table.** The harness measures cost
and latency, not whether the painted result is correct. A build can be cheap and still draw
garbage; stock's seamless drag artifacts and its z-order dependency are exactly that kind of
defect, and they were found by looking at the screen, not by measuring it.

## The single-variable comparison: same guest, agent swapped in place (2026-08-09)

The dedicated experiment the paragraph above asked for — the first single-variable
ours-vs-stock measurement in this project's history. ONE guest (`win11-idd-test`), rebuilt
with genuine stock QWT 4.2.2 (MSI byte-identical to the vendor's), offline, classic
`notepad.exe` on both sides; our agent (build `51cc897`, a direct descendant of the released
`03b1674`) swapped in and out **in place** via an elevated scheduled task, the running
binary's hash verified before every repetition; 5 rounds interleaved. Gate: the DDA fast
path served **99.4 %** of captures (ddacap=2293, pwcap=13, zero refusals), so this is a
clean read of the capture feature working as designed, not a fallback measurement.

gui-agent CPU (% of one core, median):

| workload | stock 4.2.2 | ours (DDA on) | delta | verdict |
|---|---:|---:|---:|---|
| typing | **2.188** | **4.381** | **+100 %** | **REAL — distributions do not overlap** |
| drag   | 12.314 | 11.727 | −4.8 % | inside noise (spread 34.6 %) — no verdict |
| scroll | 4.369 | 5.158 | +18 % | inside noise (spread 42.5 %) — no verdict |

Typing is the one robust result: every ours repetition (min 3.042; n=4 because one
repetition's CPU sampler produced no samples and was emitted as `na`, not 0) is worse than
every stock repetition (max 2.651; n=5). **Our agent costs 2× stock on typing CPU.** Drag
and scroll differences are smaller than the run-to-run spread and prove nothing in either
direction — the harness's own "beats stock" tag on drag is not supported and is not claimed.

**Root cause (2026-08-09, later the same day; see FINDINGS.md).** Re-analysis of the same
traces per phase showed the gap is not in the typing path at all: it is a standing idle
burn (ours 3.04 % vs stock 0.57 % with one attached window and no input; the typing
*increment* over idle is equal on both sides, and drag is slightly cheaper than stock).
The burn is the per-window capture engine's 250 ms sweep, which kept running a full
`PrintWindow` + whole-buffer diff on the DDA-served window 4×/s. *(Superseded: the fix
landed and verified the same night — see "Current state" at the top. The 2×-on-typing
verdict now applies only to builds predating agent `e0cd9c4`.)*

**Retraction.** Project notes had earlier headlined DDA-sourced capture as "a large, measured
win: typing −67 %". That figure compared our binary against *itself* with DDA capture
disabled — never against stock. Lined up honestly:

```
ours, DDA off   12.427   (5.7× worse than stock)
ours, DDA on     4.381   (2.0× worse than stock)
stock 4.2.2      2.188
```

DDA removes most of an overhead the fork itself introduced; it does not make the fork faster
than what it forked.

Instrumentation is not the explanation. Our build writes a perf record every frame and stock
writes none, but from the same runs' data the logging costs 228 µs of a 2200 µs per-frame
total — about 10 %, a fraction of a CPU point, nowhere near the 2.2-point typing gap. The
gap is real code — the fork adds per-window capture on top of stock's whole-desktop
streaming — not the logger.

**Consequence (as written 2026-08-09, superseded the same night):** on typing that build
was a regression against stock and was not presented as a performance fix. The cost has
since been found, removed and re-verified — see "Current state" at the top of this
document. The correctness fixes and capabilities stand on their own either way.

## What is deliberately absent

- **dom0-side pixel metrics.** Sampling dom0 is the slowest element in the whole path
  (~5 s per full-desktop capture), so it cannot resolve frame rate; and a full-desktop
  sampler reports ~100 % changed frames on every side because the dom0 desktop itself
  changes — two consecutive *static* captures already produced different hashes. A dedicated
  dom0-side sensor is the right tool and is not built yet.
- **Per-frame agent cost (QGAPERF).** Ours-only by construction — stock emits no per-frame
  instrumentation — and currently unreported even for our rows because the benchmark's log
  reader still points at the pre-`Q:\Qubes Logs` path. A harness gap, not a property of the
  build.
- **Whole-VM CPU under load.** Reported `n/a`: cputime was unavailable, which is not zero.

