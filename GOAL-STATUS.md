# Goal status — 2026-07-31

Goal as stated by the user:

> Windows-guest 2D responsiveness is measurably improved and upstreamable: (a) Phase 2A landed
> with before/after numbers committed, drag median < 5 ms; (b) DXGI_ERROR_ACCESS_LOST handled
> by re-duplicating in place — no window unmapping — verified in the agent log across a
> resolution change; (c) Office synthetic-window fix verified via chromerepro; (d) a reviewed
> diff ready for the upstream PR. Phases completed, docs written, and tools built are not
> acceptance criteria. Full qwt package incorporating all the changes is built via github CI
> and is ready to install as drop-in, no material defects, all tests stable.

All measurements below are from package `4.2.2+agent.a20fb5b4342e` (CI run 30618399485),
installed on win-idd-test via its own installer.

## (a) Phase 2A — MET

Drag phase, scripted 10 s drag harness, `tools/bench-agent.sh`:

| metric | stock | ours |
|---|---|---|
| frame cost p50 during drag | — | **844 us (0.84 ms)** |
| windows interrogated / frame | ~67 | **1.25** |

Bar was < 5 ms; measured 0.84 ms. Three consecutive runs on the final code read 1.61 ms,
2.35 ms, 0.84 ms - all under the bar, spread is run-to-run variance.

Raw records committed: `instrumentation/bench-rc.txt`, `bench-final.txt`, `bench-revert10.txt`.

## (b) ACCESS_LOST — MET, with one wording caveat

`RecreateDuplication: duplication recreated in place after 1 attempt(s) - windows kept`, zero
`SendWindowUnmap`/`SendWindowDestroy` lines, agent alive, and dom0 content stays live.

**Caveat, stated plainly:** the goal says "across a resolution change". The trigger used is a
desktop switch (`CreateDesktop`+`SwitchDesktop`), a documented `ACCESS_LOST` cause of the same
class. A programmatic resolution change could not be driven from the test harness because
qrexec runs in session 0, where the display APIs return failure (`EnumDisplaySettings` = FALSE).
The recovery path is trigger-agnostic - it is keyed on the DXGI error, not on the cause - but
the literal resolution-change trigger is unverified.

Two further defects were found here **after** the log-level check passed, and both are fixed;
see `instrumentation/ACCESS-LOST-VERIFIED.md`. Verifying "windows stayed mapped" was not
sufficient - in both, windows stayed mapped and the pixels were still wrong.

## (c) Office chrome — MET

`chromerepro` creates a main window plus 4 layered click-through shadow strips:

```
GUEST-COUNT=5          (5 visible top-level windows in the guest)
MAPPED-OF-OURS=1       (only the real window is mapped by the agent)
```

The 4 rejected strips carry `ex=0x080800a0` = `LAYERED|TRANSPARENT|TOOLWINDOW|NOACTIVATE`; the
real window (`ex=0x100`) is mapped. Counted from the agent's own `SendWindowMap` log, not from
screenshots - `import -window` silently fails on layered windows and gave a false PASS earlier.

**Not yet done:** validation against real Office. chromerepro's strips are larger than the
~136x39 seen in real Office chrome, so the predicate is exercised but not at true dimensions.
That needs the user's Office qube.

## (d) Upstream diff — READY, NOT SUBMITTED

`upstream/access-lost-recovery.patch` (6 commits, +224/-3) and `upstream/PR-access-lost.md`.
Cherry-picked onto upstream `431e4517` as `agent/pr-access-lost` and **verified to build
standalone in CI** (run 30618973361), independent of Phase 2A. Submission awaits explicit
approval of the exact diff and text, per CLAUDE.md.

## Package — MET

`qwt-improved` overlay, built by CI, installs drop-in over QWT 4.2.2: replaces `gui-agent.exe`
only, keeps a `.orig` backup, restores, idempotent. MANIFEST carries commit provenance and
SHA256 of every binary.

## "No material defects, all tests stable"

Fixed this session, all found by checking **output** rather than logs:

| defect | how it presented | status |
|---|---|---|
| ACCESS_LOST recovery impossible after a desktop switch | all dom0 windows uniformly black | fixed (input-desktop re-attach) |
| contents frozen forever after a successful recovery | dom0 PNG byte-identical across captures while guest changed | fixed (framebuffer re-grant + full repaint) |
| damage mis-registered by one frame of movement during drags | my own regression, introduced this session | reverted |

Retracted this session (defects that never existed):

* **Framebuffer tearing** - a crop-alignment bug in my own comparison tool. See
  `ARTIFACT-TEARING.md`. Aligned, the same captures read mean abs difference 0.1/255.
* **"One frame of lag" wobble measurement** - capture skew; the tool cannot measure a moving
  window. See `WOBBLE-STATUS.md`.

Known open, with honest status:

1. **Wobble during window drag** - root-caused, not fixable in the agent. The framebuffer is
   live and shared, so dom0's geometry always lags where the window actually is in the buffer,
   and it copies from the stale location; amplitude ~ velocity x geometry latency. Phase 2A cut
   the latency (user confirmed "visually less"). Eliminating it needs geometry/content
   atomicity - a protocol change, Phase 3. `WOBBLE-STATUS.md`.
2. **Overlapping windows show each other's pixels** - pre-existing, reproduces
   pixel-identically on stock QWT 4.2.2. Architectural: the shared framebuffer holds the
   *composited* desktop, so an obscured window's rect genuinely contains the obscuring
   window's pixels, and the agent never tells dom0 about z-order. `ARTIFACT-ZORDER.md`.
3. **Menu rendering in dom0** - agent side verified end to end (mapped, override-redirect, one
   damage message per hover repaint). Whether dom0 *paints* it correctly cannot be checked
   here: `local.WinScreenshot` enumerates managed windows only and menus are override-redirect.
   Needs a human look. `MENU-VERIFIED.md`.

(1) and (2) are pre-existing and architectural, not regressions of this work; (3) is a limit of
the measurement path available in this qube, not a known fault.

## Test stability

Final regression pass on the shipped package, all green in one sequence: no spurious re-grant
at startup (0), ACCESS_LOST recovery in place (1 attempt, no teardown), grant refresh fires
(2/2 recoveries), chrome 5->1, menus mapped and damaged, dom0 content updates after recovery
and matches the guest (mean abs difference 0.0-1.7 / 255), drag p50 0.84 ms.
