# drag-fix v2 — commit d64bca6 on branch `drag-fix-v2` (agent repo)

Date: 2026-08-02. Branch pushed to the agent repo (`git fetch` in
`/home/user/qubes-win-idd-driver/agent` sees `drag-fix-v2`); based on `perwindow`
@ 382fa05. Files touched: `gui-agent/main.c`, `gui-agent/main.h`,
`gui-agent/perwindow.c` (+177/-7). NOT built, NOT benched — see acceptance runs
below, they are mandatory before deploy.

## What v2 is (shape kept from v1)

Move-only suppression of the `WcMarkDirty` trigger for PrintWindow-fed windows
(`ProcessNewFrame` non-slice branch), settle recapture when motion ends, 150 ms
mid-motion throttle (`PW_MOVE_RECAPTURE_MS`), engine's 250 ms sweep untouched as
the independent staleness bound. Slice-fed and synth-patch paths untouched.
SynthUpdateMask redundant-push elimination. State reset on channel attach/detach.

## Changes vs v1, blocker by blocker

### Blocker 1 — v1 diff was hand-authored and corrupt
Fixed by construction: v2 is real edits in a clone, committed as d64bca6.
Verified: `git diff HEAD~1..HEAD --check` clean; `git format-patch -1` output
passes `git apply --check` against a pristine 382fa05 checkout (APPLY-CHECK-OK).

### Blocker 2 — SynthUpdateMask memo fails in menu-over-drag
v1's per-owner memo assumed a joint owner+child move computes an identical mask
at each call. False: owner and child positions are updated by SEPARATE
`UpdateWindowData` interrogations (owner pass main.c:2299-area, child pass
main.c:2080-area), so each tracking pass computes an intermediate mixed-state
mask and then its restore, and every `WcSetMask` forces `ch->dirty=true`.

Option (a) (compare at/inside WcSetMask against the channel's current mask) was
analyzed and REJECTED with evidence: whichever window is interrogated first
(batch order from the hook queue — both orders occur), the intermediate mask
differs from the channel's current mask AND the restore differs from the
intermediate, so BOTH pushes survive the compare, per pass, i.e. per frame at
input rate during a joint move. Rare only if owner and child events land in
different batches — they don't during a drag (both LOCATIONCHANGEs are queued
between drains).

Implemented option (b): the two per-frame geometry call sites now only set
`SynthMaskPending`; `TrackWindows` calls `SynthFlushMasks()` exactly once per
tracking pass, after the refresh + admit + remove phases, so every position is
from one consistent snapshot. `SynthUpdateMask` additionally keeps the
byte-identical memo (order-stable: `g_WatchedWindowsList` is InsertTailList-only,
never reordered in place — verified by grep, documented in main.h), so a pure
joint move computes a mask identical to the memo and pushes NOTHING.
`SynthActivate`/`SynthDeactivate` still push immediately (event-rate; the mask
must exist before an async capture could overwrite freshly patched child
pixels). Split-batch edge case degrades to at most one intermediate + one
restore push across two passes — occasional, not per-frame.

### Blocker 3 — empirical evidence path
QGAPERF fields/format untouched (perf.c not modified). New LogLevel-gated
LogDebug markers, machine-parseable in the established QGA* style:
- `QGADRAG,ev=suppress,hwnd=0x%x` — move-only frame, trigger skipped
- `QGADRAG,ev=refresh,hwnd=0x%x` — throttled mid-motion refresh fired
- `QGADRAG,ev=settle,hwnd=0x%x` — settle recapture fired after motion end
- `QGADRAG,ev=maskpush,hwnd=0x%x,n=%d` — a mask was ACTUALLY pushed to WcSetMask

## Non-blocking items, disposition

- **PwLastMoveCapTick reset on attach/detach**: done, in both `PwAttachWindow`
  and `PwDetachWindow`, together with `PwFrameXYValid`/`PwSettleDue`/
  `PwLastMoveTick` and the mask memo — the main.h "all reset" comment is now
  true. The stale-tick-fires-first-refresh behavior on a fresh drag is KEPT
  deliberately and documented in the code (it is what makes one-shot
  programmatic moves capture immediately).
- **Spurious settles on iwn=0 frames (~5% of drag frames)**: fixed by
  time-confirmed motion stop — new `PW_MOVE_SETTLE_MS` (150 ms) + per-window
  `PwLastMoveTick`; a window counts as moving until 150 ms pass with no
  observed position change, not until the first still frame. Trade (documented):
  content damage arriving within 150 ms after a one-shot move is deferred up to
  150 ms (settle then recaptures unconditionally); mid-drag staleness bound
  unchanged.
- **Memo order-sensitivity**: kept memcmp, documented why it is safe (list is
  insertion-ordered, never reordered; verified: only InsertTailList/
  RemoveEntryList touch `g_WatchedWindowsList`).
- **Memo written before a possibly-no-op WcSetMask**: documented at the memo;
  safe because `PwAttachWindow` is the only channel-creation path and clears it.

## Constraints check

- Locks: all new WINDOW_DATA state only under `g_csWatchedWindows` (frame loop
  holds it at the edit site; `TrackWindows` requires it; attach/detach callers
  hold it). `WcSetMask` hold time unchanged; total exclusive acquisitions
  strictly reduced. No change to the vchan send path, slice-fed path, synth
  patching, or the engine (wincapture.cpp untouched).
- Not built here (no toolchain, per environment rules): every hunk was re-read
  after writing; C_ASSERT pins `SynthMaskLast[8] == WC_MAX_MASK`; mid-block
  declarations match existing file style (C99 constructs already in use).

## Mandatory validation before ship (in order)

0. VM precondition: win-idd-test was found wedged 2026-08-02 (respawn storm) —
   `qtest kill` + `qtest start`, verify clean desktop + qrexec first.
1. CI build of `drag-fix-v2` (all builds in CI per standing directive); deploy
   with the usual service-stop/swap/`.orig` procedure.
2. **A/B drag bench**: `tools/bench-agent.sh` same harness/analyzer as
   bench-qwtfull-w10 (10 s Notepad drag). Bar: drag `tot` p50 <= 5 ms;
   prediction ~0.6–1.5 ms (falsification clause: if p50 only halves, the
   stall-mechanism inference was wrong — instrument GetWindowData sub-phases
   before iterating). `iwn` should stay ~2, `mr` 0. Scroll/type/idle phases must
   be within noise of 382fa05 (they bypass the new branch).
   Path-engagement proof (LogLevel >= debug): grep the run log —
   `QGADRAG,ev=suppress` at ~frame rate during the drag,
   `QGADRAG,ev=refresh` <= ~7/s, `QGADRAG,ev=settle` ~1 per drag stroke (NOT
   ~1.5/s continuous — that would mean the time-confirmed settle failed).
3. **OVERLAP-IN-MOTION** (drag over a second attached window): visual check for
   debris via qtest shot AND a perf A/B — the underlying window still gets
   per-frame empty-diff recaptures (known residual), so record its p50/p95
   separately instead of eyeballing.
4. **Menu-over-drag** (synthesis): open a menu on an owner, move owner+child
   jointly. Expect: child stays composited, no flicker, owner content correct
   after settle, and — the blocker-2 proof — `QGADRAG,ev=maskpush` ABSENT during
   the joint motion (only at menu open/close and genuine child geometry
   changes). Per-frame maskpush lines = the deferral failed, do not ship.
5. Staleness negative controls: (a) drag a window with a running animation —
   visible updates >= ~4 Hz mid-drag, correct on release; (b) release-and-freeze
   — end a drag and touch nothing: content must snap correct within
   settle/sweep bounds (<= 250 ms x live channels).

## Commit

- Branch: `drag-fix-v2`, commit `d64bca6316c3c053e75b4a92c305d3e0949e9b31`
  ("gui-agent: suppress per-window recapture during pure window moves"),
  parent 382fa05. Pushed to `/home/user/qubes-win-idd-driver/agent`.
