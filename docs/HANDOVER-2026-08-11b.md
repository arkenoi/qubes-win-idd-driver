# Handover — 2026-08-11 (evening) — shell-popup crop + stability overhaul

Supersedes nothing; continues `HANDOVER-2026-08-11.md`. Trust `git log` + `FINDINGS.md` (which
contains several same-day RETRACTIONS) over any prose summary, including this one.

## VM state RIGHT NOW

| VM | build | agent | state |
|---|---|---|---|
| **win11-fresh** | Win11 **25H2** 26200.8875 | **CI build `d342e93a`** (geometric crop + crash fix) — deployed, hash-verified, crash-loop check PASSED (PID stable 75 s, log count static) | Running, display healthy, Start + a persistent OneDrive toast on screen |
| **win11-24h2** | Win11 24H2 26100.8875 (clone, pre-eKB) | CI build `5b80f2e1` with `ToastCropDisable=1` (= behaves like shipped) | **Halted** (shut down so two guests' windows stop overlapping) |

- Clone gotcha: `qvm-clone` copies `qemu-extra-args` pointing at `/dev/xvdi`; the clone will not
  boot until `qvm-features --unset <vm> qemu-extra-args`.
- NEVER poll a halted VM with `qtest run` — qrexec auto-starts it and you get a start-fail storm.
- Guest clock: the RTC is re-derived from dom0 LOCAL time at every domain start and guest RTC
  writes are discarded, so **run `tools/qtest synctime` after every start** (accurate to ~0.01 s).
  No in-guest setting survives; the dom0 fix (`qvm-sync-clock`) is blocked because clockvm
  sys-whonix is not running.

## What is committed and pushed (all CI-green)

1. **Stability overhaul ranks 1-3** (`agent` 16deed5 and earlier): fault-injection module
   (`QGA_FAULT_INJECTION`, off in release), bounded/atomic/liveness-checked vchan send, wire
   geometry sanitizer + CREATE-once-per-HWND. Three blocking review findings fixed before commit.
   **Validated: nothing.** No FI flag has ever been fired.
2. **Shell-popup crop** (`agent` HEAD): finds the visible card GEOMETRICALLY (largest descendant
   fully inside the window and strictly smaller in both dimensions) instead of by XAML class name,
   and covers ShellExperienceHost / StartMenuExperienceHost / SearchHost.

## S1a IS FIXED AND CONFIRMED (2026-08-11 late)

With `d342e93a` on win11-fresh, dom0 announces:
    Start           544,219  **832x736**   (was 531,142 858x890; measured card left/width 544/832)
    New notification 1540,730 **364x289**  (was 1524,700 396x332)
Both now equal the drawn card. **The user confirms "menu looks fine".** This is GWeck's S1a
resolved on the surface he reported it on. Not yet done: a cold-boot repeat, and the same check on
24H2 to prove no regression there (24H2's Start has no margin, so its announce must stay 858x890).

## The bug that matters most tomorrow

The crop build **crash-looped the agent on win11-fresh**: unhandled `c0000005` at address 0, a new
agent log every ~6 s, every window of the qube gone from dom0. Cause: when the class-name search
was replaced by `TcFindCardRect`, the old `get_CurrentBoundingRectangle(card)` call was left behind
and `card` is never assigned any more. **Fixed and pushed (not yet rebuilt/redeployed).**
Lesson recorded: it compiled clean and CI was green. An artefact is not working until it has run on
a guest.

## Measured facts (do not re-derive)

- **GWeck S1b root cause PROVEN**: dom0 guid log says `Verify failed: (int) untrusted_crt.width >= 0
  && ... height >= 0` = `xside.c:2937`. Causality is **H2**: the modal dialog appeared ~6.5 s
  BEFORE the vchan flood and capture death, so the dialog stops the daemon draining ⇒ any single
  suspicious message is a guest display DoS. Rank 3 closes the trigger in code; unproven.
- **GWeck S1a IS REPRODUCED, on 25H2**: the Start menu is announced **858x890** while its drawn
  card is **832x874** (margin 13/3/13/13), and dom0 borders the whole rect with composited desktop
  inside it. On **24H2 the same menu has NO margin** (858x890 announced, card fills it) — the
  shadow appeared between builds. This is what the user has been describing as "thin border with
  extra stuff within rectangle".
- **Toast, same defect class**: announced 396x332, card 364x289 (16/30/16/13). The crop was
  verified CORRECT on win11-24h2 by overlaying the UIA rect on the guest's own framebuffer.
- **UIA tree of the toast** (by handle, since our EnumWindows cannot see shell surfaces):
  window 396x332 > ScrollViewer 396x314 (full width!) > FlexibleToastView 364x289 = the card.
  The full-width ScrollViewer is why the rule requires strictly-smaller in BOTH dimensions.

## Instrument rules learned the hard way (each cost a wrong conclusion today)

1. A qrexec-launched process **steals focus and closes the Start menu**; it also **cannot see shell
   surfaces at all** (EnumWindows misses toasts/Start; `SetThreadDesktop` fails even from a fresh
   windowless thread). Use `guest/render-watch.ps1` (resident sampler, decouples sampling from
   retrieval) and judge "is it displayed" from **pixels**, never from a window list.
2. `qtest shot` is per-window and **cannot show override-redirect windows**. Any claim about what
   dom0 displays must come from `qtest fullshot` (its `geometry.txt` has the override_redirect and
   mapped columns).
3. `geometry.txt` filters by `_QUBES_VMNAME`. With two guests running, a second VM's window at the
   same coordinates looks exactly like a ghost — **check the other VM before crying ghost**.
4. Screenshots taken seconds after an agent restart show mid-recomposition state; wait and re-shoot.

## Retractions made today (do not resurrect)

- "dom0 keeps ghost windows the guest closed" — WRONG, instrument artefacts (1) and (3).
- "the crop overcrops and clips the toast header" — WRONG, that render was mid-recomposition; the
  crop rect is correct.
- "the outer border is stale unrepainted pixels" — WRONG, it was win11-fresh's own uncropped toast.
- "my clock jumps broke the Start menu" — WEAKENED; the clean clone behaved identically.

## Next actions, in order

1. **Rebuild + redeploy the crop fix** (crash fix is pushed but unbuilt). Deploy to win11-fresh,
   confirm the agent is STABLE (same PID after 60 s, log not rotating) before anything else.
2. **Verify S1a is fixed**: the user opens Start on 25H2 by hand (automated input does NOT open it
   — keybd_event, mouse click and WM_COMMAND all fail), then `qtest fullshot` immediately and check
   the border equals the card (expect ~832x874 announced instead of 858x890).
3. **Then toasts** on the same build (the user's stated order).
4. Open GWeck items still untouched: **S2** (mouse ~1 cm low — rank 5, `resolution.c` adopt-applied
   size, reproducible on 24H2 without 25H2) and **S4** (re-release from a tag containing 80f8d97 +
   README fix; no code).
5. Ranks 4-7 of `docs/PLAN-stability-overhaul.md`, and fire the FI flags so ranks 2-3 stop being
   unproven.

## Open user requirements — RECORDED ONLY, user said do NOT implement yet

All stated by the user on 2026-08-11 after seeing the fixed rendering. None are designed.

1. **Start menu should be a NORMAL window, not override_redirect.** It is currently announced
   `or=1` (a popup: no WM frame, guest-positioned, no focus). The user wants it WM-managed.
   Consequences to think through before touching: `IsPopup` decides this (main.c ~826); the daemon
   re-latches override_redirect at each MSG_MAP and MSG_CONFIGURE can never turn it back on
   (xside.c:2104); Linux-parity says menus ARE override-redirect, so this deviates from the Linux
   agent deliberately and needs a reasoned justification before it goes upstream.
2. **Start should also be reachable as a regular app-menu item** (a launcher entry for the qube),
   which is the Qubes-native way to expose it.
3. **The Win key must NOT work from a seamless app.** Confirmed by the user that the agent does not
   suppress it today. In seamless mode a stray Win press opens unmanaged guest UI mid-desktop.
4. **Toasts: still not clickable.** The crop fixed the geometry, not the interaction. Note the
   already-verified fact in docs/TOAST-fix-plan.md: HandleButton's dx/dy are ignored because
   dwFlags never includes MOUSEEVENTF_ABSOLUTE|MOUSEEVENTF_MOVE, so clicks land wherever
   HandleMotion last put the cursor — that is the first thing to check, not the crop.
5. **Toasts: wrongly positioned.** The guest runs 1920x1080 inside a 5120x1440 dom0 screen, so a
   guest-bottom-right toast lands mid-dom0-screen. The agent DOES drive the guest to the dom0
   viewport in fullscreen mode (log: `RESAPPLIED 5120x1440`), so measure which mode the guest is in
   before designing anything - this may be mode/config, not an agent change. Beware the standing
   rule: the dom0 window is the source of truth and the guest must never be resized on its behalf.
6. **Multiple toasts must stack relatively**, not overlap.
7. **Toasts should be draggable.** Today they are override_redirect, so the dom0 WM does not move
   them; making them draggable interacts directly with requirement 1 (same OR question) and with
   the HandleConfigure suppression the crop added for cropped windows.
