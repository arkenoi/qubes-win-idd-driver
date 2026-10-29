# ADR - graphics: the current path

## Why the IddCx driver

Stock Qubes Windows Tools ships no display driver. The guest runs on the emulated Basic Display Adapter, whose mode list is fixed at 29 resolutions. A dom0 window of arbitrary size can never be matched. `CDS_TEST` returns `DISP_CHANGE_BADMODE` for anything outside that list.

This package ships and activates an IddCx indirect display driver by default. It becomes the guest's only active output, the emulated adapter is disabled, and the guest resolution follows the dom0 window exactly. Arbitrary sizes exist only because the driver publishes them; no shortcut exists in the OS.

The IDD can be switched off. Switching it off is also the recovery path for a black window, usable from dom0 without a working display (`/iddoff`, `NoTopologyApply=1`).

## Difference from legacy QWT

| | legacy QWT | this package |
|---|---|---|
| display | emulated adapter, 29 fixed modes | IddCx, arbitrary modes, sole active output |
| resolution | cannot match dom0 window | follows dom0 window exactly |
| capture | PrintWindow or desktop slices | WGC broker on 26100+, PrintWindow below |
| toasts | guest-drawn banners | forwarded to dom0 by default |
| fullscreen | no guest control | Mode 2 requires dom0 opt-in |
| secure desktop | mapped as free-standing windows | never mapped in seamless |

Legacy QWT is the stock upstream path. This package replaces the display and capture layers and adds the toast bridge and window filters. The IDD is the foundation: without it, seamless geometry cannot track an arbitrary dom0 window.

## Capture paths on modern systems (25H2 / build 26100+)

On build 26100 and later the agent latches the WGC broker at start and never re-reads the capability.

- Ordinary windows, UWP frames, toasts, Terminal, layered windows: WGC session in the user-session broker, on the window itself. Windows pushes a frame only when the window changes. At rest nothing runs.
- Override-redirect menus and popups (WGC refuses `CreateForWindow`): broker PrintWindow slot, rendered only on damage whose pixels changed or on input.
- Desktop duplication is not a window source. It remains only as a damage signal, and is a target for removal (ADR-capture §33).

Liveness is checked only on input (a key or click is a promise of change). A session that delivers nothing after one recreate is declared deaf; the user is told in dom0 to close and reopen the window. No damage-comparison detector, no timed PrintWindow, no heartbeat.

## Support for legacy systems (below 26100)

The broker is ineligible. Capture falls back to the PrintWindow engine:

- Unoccluded ordinary window: one PrintWindow to establish the buffer, then copies from the composited desktop.
- Partly covered window: whole-window PrintWindow on each change of its own visible pixels.
- Popups, `NOREDIRECTIONBITMAP`, layered: slices of the composited desktop.

No timed PrintWindow. Capabilities are still latched at start. A broker that was working and stops is a failure, never a silent mode change.

## Cross-cutting rules (live)

- Capabilities decided at start, never re-read.
- No silent fallback, no silent recovery.
- Never a timeout as a fix; every wait is an observed condition.
- A window nobody can reach is not a window.
- The IDD never feeds frames through its own grant path without the owner's approval.

## Where the detailed decisions live

| topic | record |
|---|---|
| pixel source, WGC, rest-zero, liveness | `ADR-capture.md` |
| which surfaces become dom0 windows | `ADR-windows.md` |
| IDD, mode list, sole output | `ADR-display.md` |
| placement and resize | `ADR-gui.md` |
| toast bridge | `ADR-toasts.md` |

Status vocabulary and section format: `ADR-README.md`.
