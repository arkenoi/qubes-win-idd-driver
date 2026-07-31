# What the full-desktop dom0 capture showed

First time this project could photograph what dom0 actually renders: menus (override-redirect,
absent from `_NET_CLIENT_LIST`) and window decorations, neither of which `local.WinScreenshot`
can capture. Installed via `dom0/07-install-fullscreen-screenshot.sh`.

## Confirmed working

**Office chrome fix.** chromerepro's 4 layered shadow strips render on stock as solid blue/grey
rectangles surrounding the real window. With ours they are absent: dom0 window count 8 -> 4,
and `geometry.txt` no longer lists them. This is the defect the fix was written for, and it is
visibly fixed.

## Confirmed pre-existing (present on stock)

**The red rectangle around menus.** `menu-stock.png`: the menu renders with correct content and
a red border. That border is the Qubes VM-colour frame the daemon draws on every VM window
including override-redirect popups. It is stock behaviour, not a regression, and CLAUDE.md
forbids weakening daemon-side bordering.

**Stray window fragments.** Stock leaves a `Untitled - Notepad` title-bar fragment overlapping
another window's client area.

## Found and fixed: clipping against general z-order

`zorder-stale-band-ours.png`: with Notepad focused above chromerepro **in the guest** while
dom0 drew chromerepro on top, chromerepro showed a stale vertical band with its text visibly
torn. `zorder-corrected-after-guest-raise.png`: raising chromerepro in the guest, so both
stackings agreed, corrected it instantly.

Cause: the agent never tells the daemon about z-order, so dom0's stacking and the guest's
routinely disagree. The region clipping withholds from a window is then exactly the region dom0
draws on top - it renders stale. Narrowed to override-redirect popups only, which are on top in
both by construction. The general case needs the daemon to learn z-order: Phase 3.

## OPEN REGRESSION - ours is worse than stock

Controlled A/B, identical scene, no menu, only the agent binary differs:

| | first Notepad content | dom0 windows |
|---|---|---|
| stock (`3D2E6BCE`) | all 25 lines render (`ab-stock-notepad.png`) | 8 |
| ours (`f4695698af33`) | **lines 4-25 truncated, large stale region** (`ab-ours-notepad.png`) | 4 |

A large part of a window that stock renders correctly never receives damage. **Not root-caused.**
Stock is installed on win-idd-test.

Separately unresolved: on a cold boot ours produces continuous `EnumWindows` failures
(`0x80070006`) and 0 dom0 windows against stock's 3. Also not root-caused - the bisect that
would locate it was killed after three concurrent runs began rebooting the VM underneath each
other.
