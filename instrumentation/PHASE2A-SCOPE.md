# Phase 2A scope — three requirements that must not fall out

Raised by the user during Phase 2A implementation. All three touch the same code the
`SetWinEventHook` rework touches, so they belong in this phase, not "later".

## 1. Cursor

State found on the live guest:
- `g_DisableCursor` defaults to **TRUE** (`util.c:36`), and `main.c` sets it TRUE again if
  the registry read fails — i.e. **the guest cursor is hidden by default** and `HideCursors()`
  swaps in a blank cursor.
- Our provisioning pre-seeds `DisableCursor=0`, so on win-idd-test the cursor IS shown
  (verified: `cursor_disabled=0`).

Open questions to answer with the instrumented agent (NOT yet measured):
- Does a **mouse-only** frame (DXGI `LastMouseUpdateTime` set, no dirty rects) still drive
  the full window pass? If yes, simply moving the mouse costs the same ~24-43 ms/frame as
  dragging, which would be a large and easily-missed latency source. `ddaprobe` already
  reports `mouse_only_frames` and `pointer_shape_updates` separately, and the agent's
  QGAPERF record has `skip` (frames dropped for zero dirty rects) — add a mouse-only
  discriminator so the two cases are distinguishable.
- With the cursor shown, is the pointer composited into the captured framebuffer (costing
  damage every time it moves), or drawn by dom0? Phase 2B's "hardware cursor enablement"
  presumes the latter.

## 2. Non-seamless (fullscreen) mode

**Code-verified**: `ProcessNewFrame` takes an early `if (!g_SeamlessMode)` branch that does
damage only and skips the entire window-tracking block; `WinEventProc` likewise returns
immediately in fullscreen ("the watched window list isn't used in fullscreen mode",
`main.c:277`). So fullscreen is **architecturally immune** to the 24-43 ms/frame cost — the
bottleneck is seamless-only.

Not yet confirmed empirically. Attempting to switch by writing `SeamlessMode=0` and
restarting did **not** switch the live mode — all 2196 records still logged `mode=s`. The
registry value is only the startup default; the live mode is driven from dom0 via the
`QUBES_GUI_AGENT_FULLSCREEN_ON/OFF` named events, whose supported entry point is
**`C:\Program Files\Qubes Tools\qubes-rpc-services\set-gui-mode.exe`** (note: `qubes-rpc-services\`,
NOT `bin\`). Use that to measure fullscreen, and confirm `mode=f` appears in the records
before trusting any fullscreen numbers.

Phase 2A must not regress fullscreen: the hook is registered/unregistered across mode
switches, and `SetSeamlessMode()` + the "Reinitialize watched windows" path
(`main.c:1134`) must leave the reject cache and the hook in a consistent state. A
switch seamless -> fullscreen -> seamless is a required test.

## 3. Post-2013 Office "synthetic" windows (2A-chrome)

Office 2013+ creates shadow-strip HWNDs (`WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_TOOLWINDOW`,
click-through, owned) around the main frame. The agent maps each one, and the daemon draws a
qube border around each, so a single Office window appears as several bordered fragments.

This belongs in **`ShouldAcceptWindow()`** — the exact predicate the reject-cache work
changes — so it must be implemented together with the hook rework, not bolted on after:
1. Reject layered+transparent+noactivate owned chrome; reject alpha==0
   (`GetLayeredWindowAttributes`); reject DWM-cloaked (`DwmGetWindowAttribute(DWMWA_CLOAKED)` —
   already queried in `GetWindowData`, so this is nearly free).
2. Verify popups/tooltips (`WS_POPUP`, toolwindows) are sent with `override_redirect`, as the
   Linux agent does for menus; fix the classification if not.
3. Test WITHOUT Office via `tools/chromerepro` (a small Win32 app: main window + 4 layered
   transparent "shadow" HWNDs + a popup). Acceptance via `qtest shot`:
   before = 5 bordered windows, after = 1 bordered window (+1px-bordered popup when open).
4. **Never** weaken daemon-side bordering. The fix is to stop presenting chrome fragments as
   windows — not to let the guest opt out of borders.

Note the synergy: every window rejected by the improved predicate also becomes a *cached*
reject under Phase 2A, so the chrome fix and the performance fix compound.
