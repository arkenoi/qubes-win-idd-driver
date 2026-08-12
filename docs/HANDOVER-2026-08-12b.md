# Handover 2026-08-12b — PRIMARY GOAL: fix the window-drag replay regression

This handover exists so the regression below gets FIXED. It is the job, not context.
Do not report it as "pre-existing" or "introduced earlier" — it is ours, it is open, fix it.
Everything else in this file is reference material subordinate to that goal.

---

# PRIMARY: the drag replay regression (OPEN)

## Symptom (user, reproducible every time)
Drag a normal window (Notepad) by its dom0 title bar along some path and release. The window
**jumps back to the start of the path and replays the whole trajectory**, repeatedly. Earlier
in the session it was a large fly-around; after the fixes below it is a smaller but still
clearly visible oscillation. It has NEVER been absent on any build the user tested.

## Acceptance (do not declare done on anything less)
User drags a window, releases, and it **stays exactly where it was dropped** — no jump-back,
no replay, no visible settle wander. Verified by the USER on a hash-verified deployed build,
plus a cold boot. Static screenshots do NOT count (that mistake was made twice this session).

### THE FIX MUST NOT COST THE UX ALREADY WON (hard constraint)
The drag fix is not allowed to trade away anything below. Re-verify each after any drag work:
 1. **Start menu + toasts (25H2)**: headerless, corner-anchored, non-resizeable, cropped to
    the visible card, CLICKABLE, multiple toasts stacked. `ShellManaged=0` stays the default.
 2. **No capture-reset storm**: dragging must not destroy/re-announce the qube's windows
    (`reset-census.ps1`: cap_timeout must stay 0; window IDs stable across a drag).
 3. **Drag CPU stays low**: the PrintWindow-during-drag suppression must remain — damage phase
    max ~310 us, NOT the old 45,422 us (`drag-measure.ps1` + QGAPERF).
 4. **Correct resolution/geometry**: guest desktop matches dom0 (5120x1440 here), no
    SPI_SETWORKAREA 0x57 spam, A3CHECK g == ctx.
 5. **Clicks land where dom0 aimed** (ButtonAbsolute) — toasts and normal windows alike.
 6. **No content staleness / occlusion bleed**: a window that stops moving must repaint
    (the settle recapture must still fire), and windows must not show each other's pixels.
A drag fix that regresses any of 1-6 is not a fix. If a tradeoff looks unavoidable, STOP and
put the choice to the user rather than silently spending one of these.

## Deployed right now
win11-fresh: build `172A72B1` (branch `bisect-return`, tip `c9481cb`), `ShellManaged=0`.
**The newest fix (outbound configure rate limit) is deployed but NOT yet user-tested.**
That test is step 1 for the next session.

## What is established (hard evidence — do not re-derive, do re-verify if suspicious)
1. **The daemon sends NO MSG_CONFIGURE during the drag.** At LogLevel=5 (VERBOSE, which does
   capture HandleConfigure's LogDebug) there are ZERO HandleConfigure lines during a drag.
   The drag is guest-native: dom0 forwards MSG_MOTION -> HandleMotion -> SendInput -> Windows
   moves the window. **So any theory based on an inbound echo/feedback loop is dead.**
2. **The guest window is STATIC while the agent still announces motion.** `guest/pos-sampler.ps1`
   (GetWindowRect + DWMWA_EXTENDED_FRAME_BOUNDS every 25 ms) shows the real window at rest
   after release, while the ProtoTrace shows SendWindowConfigure streaming a walking path
   (285->313->341->429->757->878->905->911->914, then the sequence REPEATS).
   **A repeating sequence of stale positions is the signature — this is a QUEUE being drained,
   not a computation drifting.**
3. A scripted SendInput drag inside the guest does NOT replay; only a real dom0-forwarded drag
   does. (Scripted = fewer/slower messages, so it never builds the queue.)
4. The window's own move is clean: winrect and DWM bounds track together, 7 px apart
   (invisible border), and settle immediately.

## Current best hypothesis (fix just landed, UNTESTED)
Producer/consumer mismatch on the **OUTBOUND** path: the agent announced every input-rate
position step; the daemon drains slower; the vchan ring becomes a queue of stale positions;
after release dom0 walks the whole path. Fits every fact in 1-4, especially the repeating
sequence and the static-window contradiction.
Landed in `c9481cb`: latest-wins rate limit, max one position-only MSG_CONFIGURE per window
per `CFG_POS_MIN_INTERVAL_MS` (16 ms), withheld coords remembered, `CfgFlushPendingMove()`
sends the final resting position when the window goes quiet. Size/override changes are never
delayed. **Step 1 next session: user drags on `172A72B1` and reports.**

## If the rate limit does NOT fix it — the decisive experiment
Instrument ONE build to log, at the same instant for the same hwnd:
 (a) `GetRealWindowRect()` result, (b) `entry->X/Y`, (c) the value handed to
 `SendWindowConfigure`, (d) WHICH writer set `entry->X/Y` — frame path (`main.c` ~4090,
 re-reads the rect on damaged frames) vs `UpdateWindowData` (~2407/2566) vs HandleConfigure.
Then one real user drag. That pins whether the walking values are (i) genuinely produced live
and queued, or (ii) a stale source being re-read. Do this BEFORE any further speculative fix.
Also worth checking on the dom0 side: whether gui-daemon itself buffers/animates window moves.

## Fixes already landed for this bug (keep them — measured, correct, but NOT sufficient alone)
- `DrainVchanInput()` (main.c): apply queued vchan input before each frame. The pump is ONE
  thread and WaitForMultipleObjects prefers the frame event, so a slow frame used to block all
  input; now input latency is bounded to one frame. Correct, keep.
- `g_InputDragWindow` latch (set in HandleButton on left-press, cleared on release): suppresses
  per-window PrintWindow recapture while a window is dragged. **Measured: damage phase max
  45,422 us -> 310 us (~150x less work per drag frame).** This is the CPU waste the user
  called out. Correct, keep.
- REVERTED and must stay reverted: `95492ed` (coordinate-space conversion + settle) — it added
  three DWM/display calls per configure and made the symptom worse.

## Planned next layer (only after the cause is confirmed)
Inbound motion coalescing in the drain loop: keep one PENDING motion slot; a newer motion for
the same hwnd overwrites the older; any non-motion message flushes pending first; flush at
ring-empty. Never drops a button/keypress or the final motion (motion is ABSOLUTE, so
latest-wins introduces no positional error). Full design: workflow `wf_de6e4fac-9a1` synthesis,
`/tmp/.../tasks/w9r3irkhc.output`.

## Instruments (all in guest/, use these — they work)
`pos-sampler.ps1` (ground truth window position, 25 ms), `pull-both.ps1` (in+out configures),
`pull-configures.ps1`, `pull-motion.ps1`, `set-prototrace.ps1`, `set-loglevel.ps1` (5=VERBOSE),
`drag-measure.ps1` (scripted drag + QGAPERF window), `reset-census.ps1`, `defect-evidence.ps1`,
`deploy-drag.ps1` (deploy + ShellManaged=1), `set-shellmanaged.ps1`, `fire-toast.ps1`,
`open-start.ps1` (Win key via interactive scheduled task — works), `hint-check.ps1`.
Deploy = push exe + `deploy-drag.ps1`, run it, then `set-shellmanaged.ps1 -Value 0`.
**ALWAYS compare the deployed hash to what you built** — a `.orig` "4.2.2" backup turned out
to be 4.3.1 this session and would have invalidated a whole comparison.

---

# SECONDARY (reference only — done, do not regress)

## Start menu + toasts on 25H2 — MEETS SPEC, user-confirmed
Spec (user, 2026-08-12): "stays in the corner, no window header, non-resizeable but clickable."
Delivered with `ShellManaged=0`: override-redirect popups — headerless, corner-anchored,
non-resizeable — cropped to the visible card, and **clickable (user-confirmed)**. Windows
stacks multiple toasts natively (verified: three cards stacked bottom-up in one window).
Keep `ShellManaged=0` as the shipped default. `ShellManaged=1` (WM-managed/draggable) was
tried and rejected — it gave a resize border, desktop bleed on resize, and its own drag loop.

## Other fixes this session (all deployed, keep)
- Capture: a slow main loop is no longer fatal (15 s wedge budget). Killed the reset storm
  that destroyed and re-announced every window mid-drag (was ~1 per drag, census 6/25 min).
- Re-announce bottom-first so stacking survives a reset; foreground re-raise after the pass.
- Resolution: adopt the APPLIED mode, `ResolutionAdoptCurrent()`/RESDRIFT on WM_DISPLAYCHANGE
  and the 2 s tick, A3CHECK self-heal. Fixed skewed pointer coords, SPI_SETWORKAREA 0x57 every
  30 s, and the grant/context size mismatch.
- Toastcrop on a worker thread (never on the input path); attempts counted on completed
  measurements; oversize shell hosts cropped (25H2 Start was mapping as a fullscreen white
  window at 5120x1440).
- HandleButton: clicks carry their own absolute position (fixes unclickable toasts).

## Win10 — deferred by the user to a final regression pass
Installer-based only: provision a clean guest, install the shipped QWT package (which bundles
the patched agent), validate read-only. NO hot-swaps, UAC stays ON — `mgmt/autounattend.xml`
must NOT set EnableLUA=0 (that experiment is reverted). Plan: `docs/PLAN-win10-e2e-installer.md`.
Provisioning runs from the `win-idd-mgmt` qube; this dev qube lacks VM-create/cdrom rights.

## Process rules earned the hard way this session
- Bisect IMMEDIATELY when a symptom is called new. Three speculative fixes cost hours.
- Never call interactive behavior fixed from a static screenshot.
- Verify the deployed binary hash every single time.
- Don't explain a bug away by its age. Fix it.
