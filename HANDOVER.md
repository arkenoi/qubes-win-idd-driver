# Handover — 2026-08-09

## The result

**DDA-sourced capture is a large, measured win. Frame dropping is a net loss and is off.**

Four conditions, one binary, interleaved, 16 reps, classic Notepad, quiet guest:

| condition | typing | drag | scroll |
|---|---|---|---|
| D baseline (both off) | 12.427 | 14.697 | 10.041 |
| B frame-drop only | 14.765 **+19%** | 20.051 **+36%** | 10.159 +1% |
| **C DDA only** | **4.089 −67%** | **14.040 −4%** | **4.143 −59%** |
| A both on | 5.313 −57% | 16.408 +12% | 7.971 −21% |

`ddacap` 418–472 across all four C reps; D/C spreads 15%/42%. Only B was bimodal (one 34.16
outlier), and B is the path being discarded.

**What DDA does:** for an unoccluded foreground window, copy the damaged sub-rects out of the
composited desktop (`PwSliceCopyAndDamage`) instead of re-rendering the whole window with
`PrintWindow` (15–18 ms on WARP). Guarded by `PW_DDA_MOVE_QUIET_MS` (300 ms) so drags stay on
the old path — without that guard drag regressed +68%.

## Ship gate (task #22)

1. **Pixel equality — BLOCKER, not run.** `guest/pixel-equality.ps1` is written. It compares
   `PrintWindow` against the composited screen for the same window and reports *where* they
   differ. Interior differences = do not ship. This matters more since `establish-once`
   removed the flicker: a mismatch is now silent and permanent instead of visible.
2. Buffer race — **closed** (synchronous `WcPrefill` on DDA entry, no second writer).
3. Drag regression — **fixed** (move-quiet guard), confirmed at −4%.
4. Then: E2E on Win10+Win11, release build, README table.

## Stock comparison — NOT DONE

All existing stock numbers (typing 3.126 etc.) were measured against **Store Notepad**. The
DDA numbers use **classic Notepad** (Store one removed — its update banner sits inside the
measured window). Not comparable. `scratchpad/ours-vs-stock-one-guest.sh` is written and is the
right way: `win11-idd-test` has stock 4.2.2 with a `.orig` backup, so swap ours in, measure,
restore, interleave — one guest, one variable.

## Traps that cost hours — read before running anything

- **`wait_up` auto-restarts a Halted guest.** Every harness has
  `[ state = Halted ] && qvm-start`. A background script fighting a deliberate `qvm-kill` looks
  exactly like a wedged domain. Kill all scratchpad scripts before touching guest state.
- **`benchmark.sh` refuses if any other Windows qube is Running *or Transient*.** One stray
  guest silently returns zero reps.
- **`perf.txt` collection is unbounded** — each rep's file contains all earlier reps. Window
  by that rep's own `harness.txt` phase markers or difference consecutive reps.
- **Phase markers are `### PHASE-START <name> <ts>`** — the `###` prefix broke four analyzers.
- **Every QGAPERF counter must appear twice in `perf.c`** (header + format string) and
  specifiers must equal arguments. Three counters shipped incremented-but-never-printed.
- **Focus loss kills DDA**: `PwDdaEligible` requires the foreground window, so interacting with
  the host mid-run makes a rep read ~20 instead of ~5. `ddfg` now counts it.
- **`qvm-clone` needs a HALTED source** and does **not** inherit properties (clone came up
  400 MB / 2 vCPU vs 8192 / 4).
- **Elevation is available**: `guest/run-elevated.ps1` (scheduled task at highest run level).
  The marker-file switches and several "not elevated" refusals were unnecessary.

## State

- Agent branch `workarea-clamp-maximize`, HEAD `e6b65ed` (frame drop off by default).
- Guests all halted except `win11-fresh` (Transient, nothing restarting it now; it is expendable).
- `win11-idd-test` = stock QWT 4.2.2 reference, Store Notepad removed. **Do not reinstall it.**
- `win11-clonetest` = clone of a running VM, crash-state disk, delete it.
- Clone policy installed and working; test guests tagged `qwt-bench`.

## Next

1. Run pixel equality (needs our agent on a guest — use the elevated swap, ~2 min).
2. If clean: one-guest ours-vs-stock, then E2E, then publish as a performance bugfix.
3. Task #25 (elevated swap loop) removes the 45-min reinstall from every future iteration —
   do this first, everything else gets cheaper.
