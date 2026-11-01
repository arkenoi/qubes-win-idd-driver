# Design — Windows capture paths

Overview of the capture mechanisms Windows provides, which ones this agent uses, when, and why.

Precise decisions live in `docs/ADR-graphics.md`. This is the mechanism explanation.

## What Windows provides

| Mechanism | API | What it captures | Cost / constraints |
|-----------|-----|------------------|--------------------|
| Desktop Duplication (DDA) | `IDXGIOutputDuplication` | Whole monitor composite | Cheap for dirty rects; fixed cost if you re-enumerate. Stock path. Refused or expensive for layered / UWP / `NOREDIRECTIONBITMAP`. |
| Windows.Graphics.Capture (WGC) | `CreateForWindow` / `CreateForMonitor` | Per-window surface or whole monitor | Low once open; frames arrive only on change. Requires user-session token. `CreateForWindow` refuses or returns black on some shell CoreWindows. |
| PrintWindow | `PrintWindow` (+ `PW_RENDERFULLCONTENT`) | Whole window via GDI | Runs on the target app's UI thread (32–438 ms measured). Works on almost everything. Blocks the app. |
| BitBlt / GetDC | GDI | Client or window DC | Same class as PrintWindow. Older, less reliable with DWM. |
| Magnification API | `MagSetWindowSource` | Magnified view of a region | Not used. |

## What the agent actually does

| Path | Where it lives | When it is used | Why |
|------|----------------|-----------------|-----|
| DDA / screen-slice | agent `capture.c` (`IDXGIOutputDuplication`) | Default on Win10. Fallback on Win11 when broker is off or a window is topmost (toasts, o-r menus the agent does not register). | Stock path. Cheap when the window is unoccluded and not layered. Slicing bleeds whatever is on top. |
| WGC per-HWND | `tools/wgcbroker/wgcbroker.cpp` (user-session broker) | Win11 26100+ for ordinary app / UWP / NRB windows the agent registers. | Avoids PrintWindow tax and occlusion bleed. Frames arrive only when the window changes. |
| WGC + PrintWindow fallback | same broker | Override-redirect menus / popups that `CreateForWindow` rejects. | Broker comment: WGC CreateForWindow rejects override-redirect menus/popups; PrintWindow(PW_RENDERFULLCONTENT) captures them from the user session. |
| Monitor WGC + crop | broker (or agent slice) | Shell CoreWindows (Start / Search / toasts) where per-HWND WGC returns black or fails. | Per-HWND returns black; monitor capture sees the pixels; crop to card rect. |
| PrintWindow (agent-side) | agent PrintWindow engine | Below 26100, or when a window is not DDA-eligible (occluded, layered, moving). | Only path that works for those classes on older builds. Expensive (UI-thread). |

## Decision order (current)

1. Capabilities latched at start (G5). Broker eligible only on 26100+ unless switched off.
2. Agent decides per window class (`PwWindowClassify` / `ShouldAcceptWindow`).
3. Ordinary / UWP / NRB on 26100+ → register with broker → WGC `CreateForWindow`.
4. `CreateForWindow` fails (o-r menu) → broker switches that slot to polled PrintWindow.
5. Result is true-black (shell CoreWindow) → fall back to agent slice (DDA) or monitor crop.
6. Below 26100, or broker off → agent's own DDA + PrintWindow engine.
7. No timed PrintWindow (G4). Liveness from input + Windows events only (G19).

## Why Win10 still looks cheaper after the same removal

Win10 rarely hits the expensive PrintWindow path (fewer layered / UWP / shell CoreWindows). Win11 hits it more often on the old path; the broker removes that hit for the classes it can serve, which is why the broker wins on Win11 even though Win10's lighter old-path scene still looks cheaper overall.
