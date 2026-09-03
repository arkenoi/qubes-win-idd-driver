# QWT gui-agent stability overhaul — ranked plan (2026-08-11)

Produced by a 10-agent design workflow (6 subsystem readers → 3 competing designs → adversarial
judge). Full machine-readable verdict: the workflow task output; this file is the working plan.

Scope rule: **agent-side only.** No daemon or protocol changes, no weakening of any dom0-side
check. The daemon is read as a CONTRACT to satisfy, never edited.

## What "stable" means here (user's definition, 2026-08-11)

Three gates, all required. A fix that passes one and regresses another is not done.

1. **No wedge** — the agent never blocks forever, never dies silently, always degrades loudly.
2. **Correct rendering** — dom0's PIXELS match the guest's screen. Absence of a crash is not
   stability; a frozen or missing window is a failure even when every log line says "recovered".
   Instrument: `tools/rendercheck` (below).
3. **No performance regression** — see the performance gate below.

## Evidence this plan is built on (all measured, this repo)

- S1b root cause PROVEN: `Verify failed: (int) untrusted_crt.width >= 0 && ...` =
  `xside.c:2937`, from dom0's guid log.
- Causality PROVEN = **H2**: the dialog (18:19:35.7) preceded the vchan flood (18:19:42.2) and
  capture death (18:19:43.3) by ~6.5 s. A modal dialog stops the daemon draining the vchan ⇒
  **any single suspicious message is a guest display DoS.**
- Blocking mechanism: `VchanSendBuffer` spins `while (VchanGetWriteBufferSize < size) Sleep(1);`
  with no deadline and no `libvchan_is_open` check — `upstream/ro/qubes-windows-utils/src/
  vchan-common.c:96-102` (vendored, read-only) — while the caller holds `g_VchanCriticalSection`.
- Repro honesty: 4 post-reboot ProtoTrace storm runs produced ZERO natural negative geometry.
  The storm probe is a validated reproducer for flip churn, **not** for S1b. Hence rank 1.

## Ranked fixes (prerequisites first)

| # | Fix | Files | Why here |
|---|---|---|---|
| 1 | **Fault-injection module** (`FI_NEG_CREATE`, `FI_RING_STALL`, `FI_PUMP_STALL`, `FI_CAPTURE_EXIT`, `FI_DUP_CREATE`, …), test builds only | `agent/gui-agent/faultinject.{c,h}` | Nothing below can be *proven* without a defect-reintroduced toggle; the natural repro is unreliable. Each flag must reproduce its historical signature before the matching fix's PASS counts. |
| 2 | **Bounded, atomic, liveness-checked vchan send** — reserve-before-write with ~10 s deadline in the agent wrapper (`VchanSendTimed`/`VchanSendMessage`), never in the vendored lib; chunked oversize; on expiry log once, drop `g_VchanClientConnected`, distinct DEAD vs UNRESPONSIVE | `vchan.{c,h}`, `send.c` | Containment for the whole H2 class. Atomicity is mandatory: a partial header/body write permanently desyncs the daemon. |
| 3 | **Wire-choke-point geometry sanitizer** — clamp what the daemon clamps, drop what it dialogs on, byte-matching `xside.c:2939-2946`; CREATE-once-per-HWND; don't mark CreateSent on a dropped CREATE so dependents self-quarantine | `send.c`, `main.c`, `perwindow.c` | Makes the proven 25H2 trigger unreachable, and fixes the duplicate-CREATE defect found today. |
| 4 | **Capture-thread survival + de-gated restart** (timeout as backpressure, not death) | `capture.c`, `main.c` | The thread currently dies on a 1 s wait and never returns. |
| 5 | **S2 adopt-applied-size** on RESAPPLIED-MISMATCH + `SDC_FORCE_MODE_ENUMERATION` | `resolution.c` | GWeck's mouse-offset bug; needs a stable agent to measure against. |
| 6 | **Flip-storm damping at the source** — grant reuse with headroom, sticky popup demotion, region-blink debounce, bounded rebuild valve | `perwindow.c`, `main.c`, `wincapture.cpp` | Removes the pressure instead of surviving it. **Highest perf risk** (see gate). |
| 7 | **Stuck-not-dead watchdog** — heartbeats, capture liveness, ring-stuck signature | `watchdog.{c,h}`, `main.c` | Backstop for unknown-unknowns; thresholds must dominate every deadline above, so it lands last. |

Rejected by the judge (do not resurrect): a dedicated writer thread + coalescing queue (largest
regression surface for a case fixes 2-4 already downgrade to "degraded"); draining reads inside
the send wait (its premise, a write-write deadlock, is refuted by the daemon's contract);
coalescing UNMAP/MAP at the send layer (wrong layer — it's IsPopup flapping, rank 6's job);
patching `vchan-common.c` directly (vendored, shared by other QWT components); clamping at
ingestion rather than at the wire (would move the per-window capture crop origin).

## Performance gate (added at the user's request, 2026-08-11)

Every fix must show **no regression** on the existing instrumentation before it counts as landed.

- **Metric source**: the agent's own `QGAPERF` frame line (perf.c, PerfEmitFrame) — use `tot`, `snd`,
  `dmg`, `enu`, and frame interval; report p50/p95/p99, never means alone.
- **Protocol**: ≥3 runs per side, **interleaved** with the control build, same scene, binary hash
  verified against the manifest before each run, cold boot included. (CLAUDE.md validation rules —
  a bimodal metric already voided one whole bisect here.)
- **Scenarios**: scripted window drag, scroll, typing cadence (the Phase-1A harness), plus the
  Start storm and an idle desktop.
- **Pass condition**: p95 frame `tot` and end-to-end latency within noise of control (define noise
  from the 3 control runs, don't eyeball), and no increase in `frdrop`.
- **Known risk points**: rank 6's debounce can ADD latency to LEGITIMATE resizes — that is the one
  place where the fix could be user-visible. It must be measured against a live corner-drag, and
  the standing rule holds: the dom0 window is the source of truth and the guest must never snap.
  Rank 2 adds one size check per send; rank 3 adds per-message integer comparisons; rank 7 adds a
  low-frequency background thread. All expected to be noise, all still measured.

## Rendering gate — `tools/rendercheck` (built and working, 2026-08-11)

Compares **guest truth** (`guest/render-truth.ps1`: full-desktop PNG + every visible top-level
window with DWM extended-frame bounds) against **dom0's render** (`qtest shot` per-window PNGs),
matching by size and reporting per-window %differing pixels, plus MISSING and EXTRA windows.
Verified working: Notepad matched at 0.41% differing.

Two real findings from its first runs:
1. Guest-truth geometry must use `DWMWA_EXTENDED_FRAME_BOUNDS`, not `GetWindowRect` — Win11's
   ~7 px invisible border made every window look size-mismatched (1440x753 vs 1426x746).
2. ~~With the Start menu open, dom0 has NO window for it.~~ **RETRACTED same day.** That
   conclusion came from `qtest shot`, which is PER-WINDOW and by design cannot show
   override-redirect windows (qtest's own comment says exactly that) — and the Start menu is
   override-redirect. The user confirmed dom0 *does* render it: "thin border, with some extra
   stuff within rectangle". `rendercheck` now takes `qtest fullshot` as the authoritative dom0
   window list (`geometry.txt` includes the `override_redirect` column) and reports it in every
   run. **Standing rule: any claim about what dom0 shows must come from fullshot, never from
   per-window shots.** Still open: characterising the "extra stuff within the rectangle" — that
   is the real S1a garbled-Start artifact and needs a fullshot captured while Start is held open
   (ordinary qrexec calls steal focus and dismiss it; drive the press and the capture
   concurrently).

Known limitation (documented in the tool): guest truth is a composited-desktop crop while dom0's
is a per-window image, so an overlapping window reports as a difference (Start over Notepad read
53%). Next iteration: capture guest truth per-window via `PrintWindow` (as
`guest/pixel-equality.ps1` does) or mask occluded regions.

## Open questions the plan needs answered

- Which WINDOW_DATA field went negative on 25H2 — unreproduced in 4 storm runs; likely a
  first-logon/post-servicing shell surface. Rank 3 makes it harmless either way, and its
  GEOMDROP log will finally capture it when it recurs.
- Duplicate-CREATE: the daemon is documented to `exit(1)` on an already-tracked id
  (`xside.c:3943-3948`), yet 13 duplicate CREATEs were observed without daemon death. Resolve
  before rank 3 relies on the assumption.
- Does the daemon resume reading after Ignore is clicked (is the H2 wedge user-recoverable today)?
- GUI protocol version negotiated by this fork (decides whether CHECK_LEN mismatches are fatal).
