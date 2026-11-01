# Graphics: explanations

This document explains the graphics path for a reader. The precise decisions are in `docs/ADR-graphics.md`.

## Why the IddCx driver

Stock Qubes Windows Tools ships no display driver. The guest runs on the emulated Basic Display Adapter, whose mode list is fixed at 29 resolutions. A dom0 window of arbitrary size can never be matched.

This package ships and activates an IddCx indirect display driver by default. It becomes the guest's only active output, the emulated adapter is disabled, and the guest resolution follows the dom0 window exactly. Arbitrary sizes exist only because the driver publishes them.

The IDD can be switched off. Switching it off is also the recovery path for a black window, usable from dom0 without a working display.

## Difference from legacy QWT

| | legacy QWT | this package |
|---|---|---|
| display | emulated adapter, 29 fixed modes | IddCx, arbitrary modes, sole active output |
| resolution | cannot match dom0 window | follows dom0 window exactly |
| capture | PrintWindow or desktop slices | WGC broker on 26100+, PrintWindow below |
| toasts | guest-drawn banners | forwarded to dom0 by default |
| fullscreen | no guest control | Mode 2 requires dom0 opt-in |
| secure desktop | mapped as free-standing windows | never mapped in seamless |

## Capture on modern systems (25H2 / build 26100+)

The agent latches the WGC broker at start.

- Ordinary windows, UWP frames, toasts, Terminal, layered windows: WGC session in the user-session broker. Windows pushes a frame only when the window changes. At rest nothing runs.
- Override-redirect menus and popups: broker PrintWindow slot, rendered only on damage or input. First frame is retried at 0/50/100/200/400 ms.
- Desktop duplication is not a window source.

Liveness is checked only on input. A session that delivers nothing after one recreate is declared deaf, once per application per boot, at most 8 notices.

## Support for legacy systems (below 26100)

The broker is ineligible. Capture falls back to the PrintWindow engine: unoccluded windows are established once and copied from the desktop; partly covered windows are painted whole on each change of their own visible pixels. A window's change is a change of its own uncovered pixels. The engine treats its own PrintWindow as a possible cause of damage. No timed PrintWindow.

## Secure desktop and non-seamless

In seamless mode the secure desktop is never mapped. A freeze is logged `QGADESKSTUCK` after 30 s. In non-seamless the secure desktop is shown inside the one bounded window. UAC prompts are drawn on the normal desktop (`PromptOnSecureDesktop=0`).

Non-seamless window 0 is shrunk to 1280x800 on entry and is refused at host size unless the size came from dom0. The host size is published in the IDD mode set only while seamless is active, so a guest cannot select its way to fullscreen.

## Where to read more

| topic | explanation | decisions |
|---|---|---|
| classification, crop, synthesis | `DESIGN-window-surfaces.md` | `ADR-windows.md` |
| pixel source, rest-zero, liveness | this file | `ADR-capture.md` |
| display and modes | this file | `ADR-display.md` |
| toasts | this file | `ADR-toasts.md` |
| geometry | this file | `ADR-gui.md` |
