# Proposed upstream PR — event-driven window tracking, and don't map compound-window chrome

**NOT SUBMITTED.** Per CLAUDE.md, upstream contact needs explicit approval of the exact diff
and text. `upstream/phase2a-chrome.patch` is the exact diff: 3 commits, +1627/-69, cherry-picked
onto `431e4517` as branch `pr-phase2a` and **verified to build standalone in CI**
(run 30649461103) with no dependency on the rest of this fork.

## 1. Per-frame timing instrumentation (opt-in, off by default)

`QGAPERF` records per-frame cost split by phase (window tracking / dirty-rect extraction /
send), emitted to the agent log. Off unless the registry value `QubesGuiPerf` or env
`QUBES_GUI_PERF` is set; when off the only cost is a boolean test.

Included first because the rest of the series is justified by numbers this produces, and
because reviewing a performance change without the instrument that measured it is guesswork.
Drop this commit if upstream would rather not carry it - the other two do not depend on it.

## 2. Event-driven window tracking (`SetWinEventHook`)

The watched-window list was rebuilt by an `EnumWindows` pass **on every captured frame**, with
`GetWindowLong`/`GetWindowRect`/`GetWindowText` per window. The README already carried a "use
window hooks" TODO for this.

Replaced with `SetWinEventHook` (`EVENT_OBJECT_CREATE/DESTROY/SHOW/HIDE/LOCATIONCHANGE/...`)
feeding a queue the frame path drains, plus a cheap periodic resync as a backstop, and a cache
of windows already rejected so they are not re-interrogated every pass.

Measured with the instrumentation above, scripted 10 s circular drag:

| | windows interrogated per frame |
|---|---|
| before | ~67 |
| after | ~1 |

Drag-phase frame cost p50 measures ~2.0 ms on the test VM across 6 runs (max 3.6 ms). Absolute
numbers are hardware-specific; the interrogation count is the structural result.

## 3. Do not map compound-window chrome

Post-2013 Office creates shadow-strip HWNDs around its main frame -
`WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE`, owned, click-through, no
caption. The agent mapped each as a top-level window, so dom0 drew a bordered window per strip
around the real one.

The window-acceptance predicate now rejects owned click-through layered chrome. All five
conditions are required together, so ordinary layered windows (menus, tooltips, fading dialogs)
are unaffected - an earlier draft also rejected `alpha == 0` and that wrongly hid real menus,
so it was removed.

Verified with `tools/chromerepro` (in the driver repo), which creates 1 real window + 4 such
strips, measured from a full-desktop dom0 screenshot, 3 runs per side, agent binary hash
verified before each run:

| | windows delivered to dom0 | shadow strips in dom0 |
|---|---|---|
| stock 4.2.2 | 8, 8, 8 | **4, 4, 4** |
| with this series | 4, 4, 4 | **0, 0, 0** |

A per-window content measure was identical on both sides, so the chrome is removed without
affecting rendering of the real window.

## Not included

Changes in this fork that are **not** proposed here: `DXGI_ERROR_ACCESS_LOST` in-place recovery
(separate patch, `upstream/access-lost-recovery.patch`), damage clipping against override-
redirect popups, and the damage-registration refresh. Those need more soak time and, for the
clipping, a protocol change so the daemon learns z-order.
