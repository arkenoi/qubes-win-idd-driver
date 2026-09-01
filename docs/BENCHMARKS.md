# Benchmarks

## Addendum 2026-08-12 — the table below is guest-relative; agent verified regression-free

Re-validated on win11-fresh (25H2) at 1920x1080 with the identical phase harness after the
drag-replay fix (agent 857965a): the CURRENT agent and the EXACT binary behind the 09b643e
table cost the same on the same guest/scene (current slightly cheaper at drag, med 13.9%
vs 15.7%) — no agent-side regression. The absolute numbers differ from the table by
1.6-1.8x because the GUEST differs (win11-fresh/25H2 vs the 2026-08-10 win11-idd-test):
same binary, same harness, same resolution. Treat every CPU table here as guest-relative;
cross-guest deltas are platform, not agent. An on-screen toast was tested as a confound and
has no measurable effect. Raw data + method: FINDINGS.md 2026-08-12, guest/phase-cpu-bench.ps1.

# Benchmark history and analysis

Everything measured about this build's performance, in full: the four-install comparison
and its confounds, the single-variable stock comparison, the retractions, and the root-cause
analysis. The README carries only the current verdict; this document is the record of how it
was reached. Raw per-session data and the running lab notebook are in `FINDINGS.md`.

## Current state (2026-09-01) — single-variable stock vs ours, BOTH platforms

**On Windows 10 this build costs a fraction of stock on every workload. On Windows 11 nothing
is distinguishable from stock.** That is the whole result.

**RETRACTED, within this same section and the same day: an earlier revision reported "win11 drag
+59.9 %, REAL, ranges disjoint" and called it a regression.** It was an artifact of this harness.
The suite alternates stock and ours, so every repetition follows a swap between two DIFFERENT
agents, which forces a full re-establishment - re-enumeration, per-window capture channels,
buffers, grants - and our startup is heavier than stock's. The settle after the swap was 8 s.
Re-run at 45 s, with nothing else changed, drag went stock 12.203 -> 14.641 and ours
19.516 -> 16.967: BOTH sides moved, the gap collapsed from +59.9 % to +15.9 %, and it is now
inside the run-to-run spread with no verdict. An ablation session on the same guest and binary
had already read ours' drag at 13.3-16.3 against the suite's 18.3-21.7, which is what exposed
it: between-session variance larger than the within-session spread is exactly what a
disjoint-ranges verdict cannot survive. The settle is now 45 s and overridable via
`BENCH_SETTLE_S`.

Two consequences worth keeping:
- **The Windows 10 verdicts stand.** They were taken at the 8 s settle too, so their absolute
  figures carry the same inflation on BOTH sides - but the margins there are 2.3x to 13x, and a
  36 % transient cannot manufacture a 13x gap. The DIRECTION is safe; treat the absolute numbers
  as upper bounds until a re-run at 45 s replaces them.
- **The cross-time comparison is withdrawn too.** "Our drag went 8.67 (2026-08-10) -> 19.5,
  +125 %, against a stock control that did not move" was built on the same inflated figure, and
  its 2026-08-10 anchor is itself soft: that table's stock column was not measured that day (the
  section below says so), and ours' own drag read 11.727 on 08-09 and 8.67 on 08-10 - a 26 %
  swing on one binary across one day, which now looks like the same session variance rather than
  the `SweepDdaExempt` fix it was attributed to.

### Windows 11 (24H2, build 26100, `win11-app`, 5120x1440) - 45 s settle

| workload | stock 4.2.2 | ours (4.3.17) | delta | verdict |
|---|---:|---:|---:|---|
| drag   | 14.641 | 16.967 | +15.9 % | inside noise (spread 36 %) - no verdict |
| scroll |  2.965 |  3.046 |  +2.7 % | inside noise (spread 89 %) - no verdict |
| typing |  2.335 |  2.028 | -13.1 % | inside noise (spread 41 %) - no verdict |
| idle   |  0.000 |  0.331 | | one side read 0.000 in EVERY repetition - below the CPU counter's resolution over a 5 s window. That is the sampler failing to resolve the rate, not a measurement of no CPU, and it gets no verdict. The harness enforces this now rather than reporting "disjoint, REAL". |

```
drag     stock 13.117 14.641 18.512    ours 14.957 16.967 16.985
scroll   stock 2.025  2.965  4.378     ours 2.352  3.046  5.058
typing   stock 1.697  2.335  2.506     ours 1.819  2.028  2.643
```

**The old win11 regression was TYPING (+100 %, 2026-08-09) and it is gone** - typing is now
inside noise. That is consistent with the idle-burn root cause and its fix, and it is the one
cross-time claim here that survives, because it is a change from "every repetition of one side
worse than every repetition of the other" to "indistinguishable", not a shift in a median.

### Windows 10 (19045.6456, `win10-app`, 5120x1440) - 8 s settle, see the retraction above

| workload | stock 4.2.2 | ours (4.3.17) | delta | verdict |
|---|---:|---:|---:|---|
| idle   |  5.053 | **0.328** | −93.5 % | **REAL** — ranges disjoint |
| drag   | 32.251 | **14.064** | −56.4 % | **REAL** — ranges disjoint |
| scroll | 47.161 |  **3.577** | −92.4 % | **REAL** — ranges disjoint |
| typing | 26.115 |  **2.007** | −92.3 % | **REAL** — ranges disjoint |

```
idle     stock 4.252  5.053  5.547     ours 0.325  0.328  0.812
drag     stock 31.238 32.251 33.780    ours 11.885 14.064 14.935
scroll   stock 41.325 47.161 52.156    ours 3.337  3.577  3.703
typing   stock 22.286 26.115 27.550    ours 1.269  2.007  2.014
```

### Why the two platforms disagree — the mechanism

Both agents use the SAME Desktop Duplication capture and the SAME transport: the framebuffer is
granted once and only dirty-rect metadata crosses the vchan. So the difference is **per-frame
fixed cost, not pixels moved.**

Stock's `ProcessNewFrame` (`431e4517`) does this on EVERY captured frame, under its own TODO:

    // TODO: don't enumerate all windows every time, use window hooks to monitor for changes

- `UpdateWindowData()` for every tracked window — `GetWindowInfo`, `GetWindowRect`, DWM
  queries, class and caption reads;
- `AddAllWindows()` → a full `EnumWindows` over every top-level window in the session, each
  candidate interrogated;
- and there is no redundant-frame check anywhere in it (`grep -c redundant` on stock's main.c
  returns 0).

This fork replaced the first two with `SetWinEventHook` + a queued event drain, and added
`FrameRedundant()`, which drops a captured frame outright when its pixels are unchanged.

That predicts both results. Stock's cost is roughly (top-level window count x frame rate), so
where a session has many windows and the desktop is large, it is enormous and we recover almost
all of it — Windows 10 idle 15x, typing and scroll 13x, and drag only 2.3x because during a drag
the window genuinely moves and there is real work on both sides. Where stock's per-frame cost is
already low — Windows 11, whose measured stock cost is an order of magnitude below Windows 10's
on the identical workload and resolution — there is nothing left to recover, and our ADDED
machinery is what shows up. Hence the win11 drag regression.

**A cross-platform caveat that must not be skipped:** these are two different guests with
different window populations, and stock's cost scales with exactly that. win10-app has had a
Microsoft Store window open since earlier testing. So win10-vs-win11 absolute figures are NOT a
platform comparison; only stock-vs-ours WITHIN one guest is single-variable. `iwn` (windows
interrogated per frame) is in the QGAPERF record to measure this properly.

### Method and what was checked

### The measurement protocol, in code rather than in prose

Every rule below is enforced by `tools/bench-stock-vs-ours.sh` itself, because each was broken
here first and a rule that depends on being remembered is not a control:

1. **Settle at least 30 s after any binary swap** (default 45, `BENCH_SETTLE_S` to raise, clamped
   up if set lower). Swapping between two different agents forces a full re-establishment and our
   startup is heavier than stock's, so a short settle leaves startup work inside the measurement
   and biases the side just swapped in. 8 s produced a published-then-retracted "+59.9 % win11
   drag regression"; 45 s reproduced no such gap.
2. **`vm_lock`** - two harnesses on one guest interleave their probes and fabricate verdicts.
3. **Interleaved, with the starting side alternating per round** - guest drift must not land on
   one side.
4. **The RUNNING binary's hash read back off the guest every repetition** - a harness that
   proceeds on a failed swap reports numbers for a build that never ran.
5. **Missing data fails.** Too few CPU samples, no phase markers, or an unparseable run is
   recorded INVALID and excluded - never coerced to zero. A side that reads 0.000 in EVERY
   repetition is refused as below the counter's resolution, not reported as a disjoint result.
6. **The scene verified by PIXELS every repetition** - luminance stddev of the client area with
   the frame cropped. A wedged window survives agent restarts and binary swaps and nothing in the
   agent's own output can see it.
7. **A verdict only on DISJOINT ranges**, and only against variance that has actually been
   sampled. Within-session disjointness is not enough on its own: the retraction above happened
   because between-session variance was larger than the within-session spread and the suite had
   never measured it. When a result matters, re-run it in a separate session before publishing.

`tools/bench-stock-vs-ours.sh`, unattended. ONE guest per platform, ONE install, ONE display
stack; only `gui-agent.exe` is swapped, in place. Both binaries built by the SAME CI job, same
runner image, same pinned dependencies and same linker flags — stock from `431e4517`, this
fork's merge-base with QubesOS/qubes-gui-agent-windows (three upstream commits after `v4.2.2`),
ours from the released 4.3.17 source. So neither the compiler nor the install is a variable.
3 rounds per platform, interleaved, with the starting side alternating per round.

**12 repetitions across both platforms, 12 valid, 0 invalid.** Per repetition: the running
binary's hash was read back off the guest (`stock 464772F1630E47BF`, `ours 5CEF96155147CDC6`),
and the scene was verified by PIXELS — luminance stddev of the Notepad client area with the
frame cropped, so the wedged-window trap of 2026-08-12 is checked for rather than remembered.

"REAL" means the two sides' ranges are DISJOINT: every repetition of one side beat every
repetition of the other. Nothing else gets a verdict — the 2026-08-09 harness tagged drag "beats
stock" on a −4.8 % difference inside a 34.6 % spread, and this one prints the spread instead.

**What this does NOT measure, stated plainly:**
- **Frames delivered.** This is agent CPU cost for a fixed scripted workload. The scene was
  verified present and rendering in dom0 on both sides, so neither side is cheap because it drew
  nothing — but frame rate is not measured here, and a build can be cheap and still be wrong.
  Correctness defects (stock's seamless drag artifacts, its z-order dependency) were found by
  looking at the screen, not by this harness.
- **Stock being broken rather than merely expensive.** Checked: its log for a repetition was 22
  lines with 4 warnings, no error loop. It also logs LESS than ours (156 lines over the same
  workload), so instrumentation cost cannot explain the direction either.

Raw data: `instrumentation/bench-stock-vs-ours-20260901-091217/` (win10) and
`instrumentation/bench-stock-vs-ours-20260901-120938/` (win11).

## Superseded first draft of the above (win10 only) — kept for the record

**This supersedes every CPU number below it**, including the 2026-08-10 table and the
2026-08-09 "ours costs 2× stock on typing" headline. Both were measured on guests that no
longer exist; absolute CPU here is guest-relative (see the 2026-08-12 addendum at the top of
this file), so those tables cannot be compared against this one figure-for-figure. What CAN be
compared is the direction, and it has inverted.

Method: `tools/bench-stock-vs-ours.sh`, unattended. ONE guest (`win10-app`, Windows 10
19045.6456, 5120x1440), ONE install, ONE display stack; only `gui-agent.exe` is swapped, in
place. Both binaries built by the SAME CI job, same runner image, same pinned dependencies and
same linker flags — stock from `431e4517`, this fork's merge-base with
QubesOS/qubes-gui-agent-windows (three upstream commits after `v4.2.2`), ours from the released
4.3.17 source. So neither the compiler nor the install is a variable. 3 rounds, interleaved,
with the starting side alternating per round.

**6 repetitions, 6 valid, 0 invalid.** The running binary's hash was read back off the guest
every repetition (`stock 464772F1630E47BF`, `ours 5CEF96155147CDC6`), and the scene was verified
by PIXELS each time (luminance stddev of the Notepad client area with the frame cropped) — the
wedged-window trap of 2026-08-12 is checked for, not merely remembered.

| workload | stock 4.2.2 | ours (4.3.17) | delta | verdict |
|---|---:|---:|---:|---|
| idle   |  5.053 | **0.328** | −93.5 % | **REAL** — ranges disjoint |
| drag   | 32.251 | **14.064** | −56.4 % | **REAL** — ranges disjoint |
| scroll | 47.161 |  **3.577** | −92.4 % | **REAL** — ranges disjoint |
| typing | 26.115 |  **2.007** | −92.3 % | **REAL** — ranges disjoint |

gui-agent CPU, % of one core, median of 3. "Ranges disjoint" means every repetition of one side
beat every repetition of the other — the only condition under which this project reports a
verdict at all. Per-repetition values:

```
idle     stock 4.252  5.053  5.547        ours 0.325  0.328  0.812
drag     stock 31.238 32.251 33.780       ours 11.885 14.064 14.935
scroll   stock 41.325 47.161 52.156       ours 3.337  3.577  3.703
typing   stock 22.286 26.115 27.550       ours 1.269  2.007  2.014
```

The metric is stable on an unchanged binary, which is the precondition for any verdict: within a
side the spread is 10–13 % on ours' drag/scroll and 21–26 % on stock's, and the two sides are
separated by 2.3× to 13× — an order of magnitude outside that.

**Why the gap is this large, and why it is not a surprise.** The desktop here is 5120x1440 =
7.4 Mpx. Stock streams the whole framebuffer; this fork adds DDA-sourced capture, per-window
capture and dirty-rect-limited processing, all of which exist precisely to avoid that. The
effect therefore scales with screen area, and these numbers are for a large screen. On the small
guests the historical tables were measured on, expect a smaller margin.

**What this does NOT measure, stated plainly:**
- **Frames delivered.** This is agent CPU cost for a fixed scripted workload. The scene was
  verified present and rendering in dom0 on both sides by pixels, so neither side is cheap
  because it drew nothing — but frame rate is not measured here, and a build can be cheap and
  still be wrong. Correctness defects (stock's seamless drag artifacts, its z-order dependency)
  were found by looking at the screen, not by this harness.
- **Stock being broken rather than merely expensive.** Checked, because a stock agent stuck in
  an error loop would produce exactly this shape: its log for a repetition was 22 lines with 4
  warnings. It is behaving normally. It also logs LESS than ours — ours writes 156 lines over
  the same workload — so instrumentation cost cannot explain the direction either.
- **Anything about win11.** One guest, Windows 10. The historical win11 rows are not refreshed
  and remain what they were.

Raw data, per-repetition JSON, swap transcripts and the scene captures:
`instrumentation/bench-stock-vs-ours-20260901-091217/`.

## Current state (2026-08-10) — SUPERSEDED by the 2026-09-01 section above

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

