# Handover 2026-08-12b — 25H2 Start/toasts DONE; drag replay UNSOLVED (evidence inside)

## STATE: what is deployed
win11-fresh: agent build `6AF90FDC` (agent commit `4b47e0e`-ish, branch `bisect-return`),
`ShellManaged=0`. Start + toasts: headerless, corner-anchored, non-resizeable, natively
stacked, and **clickable (user-confirmed)**. That is the user's spec, MET.
`mgmt/autounattend.xml`: UAC-disable reverted (Win10 = installer-based e2e, no hotswaps).
Win10 e2e: deferred by the user to a final regression pass. See docs/PLAN-win10-e2e-installer.md.

## THE OPEN BUG: post-drag trajectory replay (NOT solved)
User drags a normal window (Notepad) by its dom0 title bar; on release the window **jumps back
to the drag start and replays the whole path**, repeatedly. Still reproduces on `6AF90FDC`.

### Facts established (do NOT re-derive)
1. **Pre-existing.** Bisect: session-start build `e6f7503` already replays. Not caused by any
   2026-08-12 commit. Introduced by the earlier QWT-NG rework (per-window capture `6515cd4`,
   sync prefill `f9db26a`, DDA `e97edb8`) - all ancestors of `e6f7503`.
2. **Daemon sends NO configures during the drag.** At LogLevel=5 (VERBOSE, which captures
   HandleConfigure's LogDebug) there are **zero HandleConfigure lines**. The drag is
   guest-native: dom0 forwards MSG_MOTION -> HandleMotion -> SendInput -> Windows moves it.
3. **The agent announces a WALKING position while the window is STATIC.** guest/pos-sampler.ps1
   (GetWindowRect + DWMWA_EXTENDED_FRAME_BOUNDS every 25 ms) showed the real window settling
   static after a drag, while the ProtoTrace showed SendWindowConfigure streaming a moving
   trajectory (285->313->341->429->757->878->905->911->914, then repeating).
   **This contradiction is the crux and is NOT yet explained.**
4. **A scripted SendInput drag does NOT replay**; only a real dom0-forwarded drag does.
5. Two fixes landed and were MEASURED but did NOT cure it:
   - drain vchan input before each frame (`DrainVchanInput`, main.c) - removes input backlog;
   - `g_InputDragWindow` latch: no PrintWindow recapture while dragging. **Measured: damage
     phase max 45,422 us -> 310 us (~150x less work per drag frame).** Keep both: they are
     correct and remove real waste, they just are not the replay's cause.
6. REVERTED as wrong: coordinate-space conversion + settle (`95492ed`, reverted in `d0daf8a`) -
   it added 3 DWM/display calls per configure and made things worse.

### The next experiment (do this FIRST)
Instrument ONE build to log, at the same instant and for the same hwnd:
  (a) GetRealWindowRect() result, (b) entry->X/Y, (c) the value passed to SendWindowConfigure,
  (d) which code path wrote entry->X/Y (frame path main.c:~4090 vs UpdateWindowData ~2407/2566).
Then one real user drag. That pins which writer feeds the walking values while the window is
static. Prime suspect: a STALE position source (DWM composited bounds lagging, or the frame
path re-applying an old rect) - not an echo loop, since the daemon sends nothing.
Coalescing (design in workflow wf_de6e4fac-9a1 synthesis, /tmp task w9r3irkhc output) is
defense-in-depth and should land AFTER the cause is known.

## Process lessons from this session (the user was right about these)
- Verify the deployed hash matches what you intend to test, EVERY time (a `.orig` "4.2.2"
  backup turned out to be 4.3.1).
- Bisect EARLY when told a symptom is new; three speculative fixes cost hours.
- Do not call an interactive behavior fixed from static screenshots.
