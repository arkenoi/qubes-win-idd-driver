# Start menu in seamless mode — disabled in the shipped build, and what it would take

Status 2026-08-13 (user decision): **the Start menu is not presented in seamless mode.**
"we disable it in seamless mode entirely and ship like that. making it work again is on
long term plan, too."

- Agent: `ShouldAcceptWindow` rejects the Start surface when `g_SeamlessMode` is set.
  Knob `SeamlessStart` (DWORD, default 0). Set it to 1 to work on the problem again.
- The Super/Windows key is already dropped in seamless (`BlockMenuKey`, default on), so the
  usual way to summon Start is closed too — the two decisions are consistent.
- The installer no longer publishes the "Start Menu" appmenus entry; a menu item that opens
  nothing is worse than no item. `guest/install-start-shortcut.ps1` still creates the opener
  for whoever restores this.
- **Toasts are unaffected and still work**: cropped to the visible card, corner-anchored,
  clickable. Only the Start surface is withheld.

## Why it was disabled (all measured on win11-fresh, 25H2, 5120×1440)

The 25H2 Start surface never rendered acceptably through the seamless path, in four
distinct ways, each proven with guest-side screenshots (the guest's own framebuffer, so the
question "is this our copy or the guest?" was answered, not assumed):

1. **Phantom while closed.** StartMenuExperienceHost keeps a top-level surface alive with
   Start closed, and Windows **parks it off the desktop** — measured announced at x=6063 on
   a 5120-wide screen. Mapping it put a menu-less window at a random position that then
   vanished: the user's "maximized window, then dead" and "window at random position".
   Mitigated by the card gate + parked-rect rejection, but only by hiding a symptom.
2. **Wallpaper contents when WM-managed.** Shell surfaces are slice-fed from the composited
   desktop at the window's rect. A DirectComposition Start keeps painting its card at its
   NATURAL anchor, so a moved window slices bare desktop — the user's "a peek into the
   underlying desktop". Freezing the guest anchor and letting dom0 own placement was
   implemented (`ShellManaged=2`, frozen anchor) and still produced a maximized/garbled
   window in practice.
3. **No alternative capture path.** PrintWindow/WGC of the XAML host is blank from the
   agent's context (documented in `perwindow.c` / `wincapture.cpp`), so there is nothing to
   fall back to when the slice is wrong.
4. **Size morphing.** The same hwnd alternates between a card-sized (858×874) and a
   workarea-sized (5120×1384) surface; the crop cache is keyed (hwnd, size), so the
   workarea-size key regularly resolves with no card and the window maps uncropped — an
   opaque near-fullscreen white window over the whole dom0 screen.

The corner override-redirect configuration (`ShellManaged=0`) is the only one that ever
rendered Start correctly, and even it depends on a UIA card measurement that fails
intermittently. Rather than ship a menu that is sometimes a white rectangle, sometimes
wallpaper and sometimes off-screen, it is withheld.

## What would actually fix it (for the long-term plan)

- **Per-window capture that works for DirectComposition surfaces.** This is the root issue:
  the agent has no way to obtain the Start card's pixels except the composited desktop at
  the surface's natural anchor. Windows.Graphics.Capture per window would solve the whole
  class (CLAUDE.md Phase 2/#6 notes it also kills the duplicate-window artefacts), but the
  activation currently fails under the agent's SYSTEM/session-1 context — that is the thing
  to solve first.
- **A reliable "is this surface presenting a menu" signal** that does not depend on a UIA
  card measurement: the current gate needs the card to be measured before it will map, and
  the measurement is racy against the open animation.
- If per-window capture lands, revisit in this order: present at the natural anchor
  (override-redirect, no movement) → confirm stable rendering across open/close/morph →
  only then consider movability, which needs dom0 to own placement while the guest keeps
  its anchor (`ShellManaged=2`, already implemented).

## Do not repeat

- Judging Start's rendering from a dom0 screenshot alone. Every wrong conclusion here came
  from that; `guest/guest-eyes.ps1` (guest-side pixels) settled each one in seconds.
- `qtest fullshot` takes ~50 s and any qrexec call flashes a console that dismisses the
  menu. Use `guest/capture-start-render.ps1` — it samples inside the guest and is retrieved
  afterwards.
- The opener must be windowless end to end (wscript → hidden powershell → keybd_event). A
  scheduled `powershell -WindowStyle Hidden` still flashes a conhost window that closes the
  very menu it just opened.
