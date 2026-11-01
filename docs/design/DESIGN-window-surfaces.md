# Window surfaces: classification, crop, and synthesis

Detailed mechanism for which guest surfaces become dom0 windows, how they are cropped, and when they are synthesized onto an owner. Decisions that govern this live in `docs/ADR-windows.md` and `docs/ADR-graphics.md`. This file is the description, not the decision log.

## Classification

`ShouldAcceptWindow` decides whether a top-level guest window is mapped.

- Mode 1: a fullscreen-sized window is denied when its class contains `LogonUI`, while no shell window exists, while the input desktop is secure, or for `FS_BOOT_SETTLE_MS` after the secure desktop ends. Unconditional for override-redirect.
- Mode 2: a borderless window of >= ~99% of the guest screen is mapped only when `service.gui-fullscreen` is set. A maximized window with `WS_CAPTION` is always allowed.
- Chrome fragments are dropped: the shell window, shell furniture by attribute (`NOREDIRECTIONBITMAP + TOOLWINDOW + !TOPMOST`), click-through overlays, Office shadow strips by style and by class (`SCENIC_DROPSHADOW_WINDOW_CLASS`), alpha-0 layered windows, DWM-cloaked windows.
- Popups, tooltips and toasts are override-redirect. A popup contained in its owner is a candidate for synthesis; one rendering outside is its own window.

## Crop

- A toast is cropped to its visible card. The card is the union of every descendant fully inside the raw rect and strictly smaller in both dimensions. Crop resolves before the map (`MapDeferred`, bound `CROP_BEFORE_SHOW_TIMEOUT_MS` = 400). Residual rounded-corner black triangles are fundamental; dom0 windows are rectangular.
- A materialized WinUI menu (two `PopupWindowSiteBridge` windows) is captured per window through the broker and cropped to its true opaque bbox, measured by the broker on its full render. The crop resolves before the map.
- Escape hatch `ToastCropDisable=1`; forced insets `ToastCropL/T/R/B`.

## Synthesis

- Synthesis paints a popup into its owner's frame. It is used only for popups contained in the owner. `SYNTH_OVERHANG_MAX` stays 12.
- A popup rendering outside its owner is correct as its own override-redirect window (the Linux agent does the same for menus).
- Start is not presented in seamless mode (`SeamlessStart=0` default). On 25H2 it parks off-screen and its DirectComposition content cannot be captured faithfully. Open-Shell is the supported answer.
- A shell-host surface whose card measurement finished and found no card is not mapped; an in-flight measurement is never rejected.

## Where the decisions live

| topic | record |
|---|---|
| Mode 1 / Mode 2 / secure desktop | `ADR-windows.md` §1–§4 |
| chrome fragments | `ADR-windows.md` §6 |
| popups, toasts, synthesis | `ADR-windows.md` §7 |
| no composite fallback | `ADR-windows.md` §8 |
| current path overview | `ADR-graphics.md` |
