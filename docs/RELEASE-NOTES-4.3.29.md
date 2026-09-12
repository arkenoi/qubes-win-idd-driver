# QWT-NG 4.3.29 — menus appear faster and render clean

This release is about how menus look and how quickly they appear. Everything from 4.3.28 — the
PV bus driver freeze fix and Windows Update working on guests whose account is not named `user` —
is carried forward unchanged.

## Menus appear roughly twice as fast

A menu used to be held back for about 0.7 s before it was shown, and it hit that limit almost every
time. It now appears in roughly 0.35–0.5 s, and the delay is real work rather than a timer.

Three separate defects were behind it, none of them obvious:

- The cache that remembers a menu's shape was keyed on the window's identity, but Windows creates a
  **brand-new window for every menu**, so the cache never once matched and every menu paid for a
  fresh measurement.
- A menu waiting to be shown was only re-checked when the 0.7 s limit expired, so one that was ready
  in 30 ms still waited out the full limit.
- Applying the measurement changed the window's size, which was part of the cache key — so a
  measured menu could no longer find its own cache entry.

## Menus no longer flash black or show black edges

- **No black frame inside the parent window.** When a menu overlaps the window it belongs to, its
  drop shadow is a transparent margin that was being copied in as solid black. The parent's own
  content now shows through, which is what a shadow should do.
- **No black corners.** Windows 11 rounds menu corners, and the rounded-off area arrived as black.
  It is handled by the same change.
- **No black flash when a menu opens.** The guest was telling dom0 to *show* the menu before telling
  it there was anything to draw. The content is announced first now.

## Under the hood

The display capture helper gained a direct way to tell the agent a frame is ready, instead of the
agent noticing on its next full-screen pass — which also closes a case where a freshly drawn window
could go unnoticed on an otherwise still screen. Two smaller fixes in that helper: the check that
stops capture while a secure screen (sign-in, consent prompt) is up is now made at the moment of
publishing rather than up to a quarter-second earlier, and the helper refuses to start if it cannot
open the channel the agent wakes it on, instead of running half-deaf and making everything slow.

## Acceptance

Full end-to-end acceptance **passed COMPLETE**: all eight install, upgrade and AppVM cells across
Windows 10 and 11 green (72 checks, 0 failures), both feature tests green, verdict recorded.

**Known cosmetic issue:** on a menu that is partly drawn into its parent window, a brief flash can
still be seen at the moment it opens. It is reduced from earlier builds but not gone.
