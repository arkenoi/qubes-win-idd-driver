# QWT-NG 4.3.30 — notifications reach dom0, toasts stop showing seams, and windows stop blinking black

Everything in 4.3.29 — the faster, cleanly rendered menus — is carried forward unchanged. This
release is mostly about three things a user actually sees: guest notifications arriving in dom0,
toast cards that no longer show black seams between them, and windows that no longer blink black
when their buffer is rebuilt.

## Guest notifications now reach dom0 — the bridge is ON

The notification bridge forwards a guest application's toast to dom0's own notification service and
suppresses the in-guest banner. It was built in 4.3.26, given a full acceptance harness, and then
shipped **switched off by a default nobody had decided** — so it never ran for any user. It is on
by default now, together with two other gates in the same state:

- `NotifyBridge` — forward guest notifications to dom0 (per-application, fail-open: an app that is
  not listed keeps today's window path untouched).
- `NotifyErrors` — the agent reports its own error conditions to dom0 rather than only to its log.
- `NoScreenGrant` — in seamless mode dom0 draws from per-window grants, and the whole-desktop grant
  is not taken at all.

Each is still overridable: a registry value in the agent's config key, or `qvm-features <vm>
service.notify-bridge|notify-errors|gui-fullscreen`, with dom0 winning. All three are read once at
agent start.

## Toasts render as one surface

Stacked notification cards were composed from separate surfaces, and the transparent gap between
them arrived as **black bars**. The gap is now filled from the card's own body row, including the
antialiased seam at each card's edge, so a stack of toasts looks like a stack of toasts.

## Windows no longer blink black when their buffer is rebuilt

When a window's capture buffer had to be rebuilt — a resize, a mode change — the newly exposed area
was painted black for a frame or two. The agent now carries the previous pixels across the rebuild
and paints newly exposed area with the surface's own background. The same defect had a second form,
a disjoint rebuild, which produced the brief black flash people reported on window resize; both are
fixed.

A crop warm-up fix that had been removed on a diagnosis that later proved wrong is restored.

## Windows Update on netvm-less guests

Substantial work on the dom0-driven update path, which installs updates on guests that have no
network of their own:

- A pass that cannot search now reports that a **restart is required** instead of dying at
  `0x8024402C`, and when that state does occur dom0 is told the measured reason and a remedy.
- Driver offers the catalog holds **without a KB number** are now installed rather than skipped.
- A Defender signature that is already current says so instead of reporting a failure.
- Update-restart state is reported honestly: a matching stamp means the restart has **not happened
  yet**, which is different from a restart that failed.

Two candidate fixes in this area were measured and **reverted** rather than shipped on a plausible
story: a service-restart arm that turned out never to cycle `cryptsvc`, and a session-scoped
workaround for `0x8024402C` that measurement showed does nothing — only a reboot clears that state.

## What was verified for this build

The full acceptance matrix ran against **this exact package** (`4.3.30+agent.ddb9dd3de991`, CI run
35775113404, commit 44939ef):

- 8 cell-groups — clean install, same-version reinstall, in-place major upgrade from 4.3.28, and
  template→AppVM derivation with three cold boots — on **both Windows 10 and Windows 11**.
- 90 checks passed, 0 failed, 0 cells ungraded.
- Build identity verified on each guest: the installed agent binary's hash equals the package's own
  reference copy.
- Feature tests: guest notifications photographed on the dom0 desktop, and the crop-before-map path.

## Known issues

- **An intermittent stall during in-place upgrade.** Three occurrences in ten days, never
  reproducible on demand, and it did not occur in this release's acceptance (8 cells plus 3
  additional upgrade runs). When it happens the guest stops answering during the install and does
  not recover; the cause is not known. Recovery is to power-cycle the qube and re-run the upgrade.
  Instrumentation added in this cycle means the next occurrence will be diagnosable rather than just
  observable.
- **Windows 10 22H2 ESU items are reported as informational**, by design: that release is
  end-of-life and its remaining updates need an ESU entitlement, which is a licensing decision
  rather than a defect.
