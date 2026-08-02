# Work-area / maximized-window check — pristine Win10 from-source install

Date: 2026-08-01 ~23:45. Handoff step 5.4 ("maximized window fits the dom0 client area").
Guest: win-idd-test, Win10 Pro 19045, from-source QWT (gui-agent 654de8eb… = agent 382fa05,
perwindow). No dom0 work-area watcher installed (by design of this check) → agent sources
limited to registry / qubesdb / inference. VM was NOT rebooted or agent-restarted for this
check; the running agent instance started 2026-08-01 23:30:22 (log
`gui-agent-20260801-233022-3356.log`).

## VERDICT: FAIL (both halves of the acceptance fail; data complete)

## The four rects

| rect | value | source |
|---|---|---|
| guest screen | 3440x1440 | SM_CXSCREEN/SM_CYSCREEN |
| guest work area (at check time) | (0,0)-(3440,1400) | SPI_GETWORKAREA, identical before launch and after maximize |
| guest maximized window rect | (-8,-8)-(3448,1408) outer; visible region (0,0)-(3440,1400) after the 8 px invisible resize borders | GetWindowRect, IsZoomed=True |
| dom0 window (Notepad client) | x=0 y=56 w=3440 h=1400 → bottom edge at **1456** | fullshot geometry.txt id 0x1c0018b |
| dom0 screen | 5120x1440 (dual-monitor span) | screen.png header |

(geometry.txt also lists the desktop window 0x1c00188 at 0,0 3440x1440.)

## Half 1 — "maximized window fits the dom0 client area": FAIL

Dom0 placement puts the client at y=56 (below the dom0 top panel + guid title bar — top
edge is fine, see notepad-top-edge.png), but 56+1400 = **1456 > 1440**: the bottom 16 px
of the maximized Notepad are off-screen. Visual confirmation in notepad-bottom-edge.png:
the horizontal scrollbar is the last fully visible strip and the status bar is cropped by
the screen edge. No right-edge overflow this time (window at x=0, width 3440, on a 5120
span). No absurd undersizing — dom0 size (3440x1400) exactly equals the guest visible
maximized region.

This is the same residue documented in FINDINGS session 2 ("bottom cropped by the screen
edge"): the guest maximizes to its own 3440x1440 screen minus only its taskbar, dom0
offsets the window below its panel, and the excess leaves the screen bottom.

## Half 2 — "guest maximized rect consistent with the work area the agent applied": FAIL

The agent DID apply a work area — once, at startup:

```
[20260801.233023.650-804-I] WorkAreaApply: guest work area set to (5,56)-(3435,1435)
```

**Source that engaged: inference** (source 3, daemon-dictated window origins → margins
5,56). Proof of elimination: registry `WorkArea` value absent in both
`HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools` and its `gui-agent` subkey; qubesdb
source unavailable (no dom0 watcher installed; no `qubesdb-read.exe` in the guest to probe
the key, but the watcher that writes it was never installed).

But at check time (23:46) SPI_GETWORKAREA returned **(0,0)-(3440,1400)** = Explorer's own
recompute (screen minus 40 px taskbar) — the agent's value had been overwritten sometime
in the intervening ~16 min and never re-asserted. The maximized rect (-8,-8)-(3448,1408)
is exactly a maximize against Explorer's work area, NOT against the agent's
(5,56)-(3435,1435) (which would have produced a 3430x1379 client at 5,56 — and, notably,
WOULD have fit dom0: bottom 56+1379=1435 < 1440).

### Why no re-assert: WorkAreaCreateListener 0x5 is NOT Win11-specific — it fails on Win10 too

```
[20260801.233023.055-3704-E] WorkAreaCreateListener: CreateWindowEx(workarea listener) failed with error 0x5: Access is denied.
[20260801.233023.197-3704-E] WorkAreaCreateListener: CreateWindowEx(workarea listener) failed with error 0x5: Access is denied.
[20260801.233032.496-3704-E] WorkAreaCreateListener: CreateWindowEx(workarea listener) failed with error 0x5: Access is denied.
```

Three failures at agent start on this pristine Win10 19045 install. FINDINGS open item #3
recorded this as a Win11 defect ("dead on Win11, needs its own look") — **status update:
it reproduces on Win10 on the from-source install**, so the event-driven re-assert
(WM_SETTINGCHANGE/WM_DISPLAYCHANGE listener, agent 826ad82 line) is dead on BOTH OSes and
the earlier partial Win10 validation of work-area sync (session 3, hand-swapped binary)
does not carry over. With the listener dead and no dom0 watcher, one Explorer recompute
permanently defeats the work-area sync until the next agent restart re-infers and
re-applies (and is then overwritten again).

Note the error thread (3704) differs from the applying thread (804); the failure repeats,
i.e. it is not a one-shot race at startup.

## Causal chain (all measured)

1. Agent starts → infers work area (5,56)-(3435,1435) from daemon origins → applies it (log).
2. WorkAreaCreateListener fails 0x5 → no WM_SETTINGCHANGE/WM_DISPLAYCHANGE re-assert.
3. Explorer recomputes the work area from its taskbar (asynchronous, unlogged — the very
   event the dead listener was built to catch) → (0,0)-(3440,1400).
4. Notepad maximizes against Explorer's value → guest visible rect 3440x1400 at (0,0).
5. Daemon places the dom0 window below its panel at y=56 → 3440x1400 client, bottom 1456,
   16 px cropped off a 1440-high screen.

## Evidence files (this directory)

- `workarea-check.ps1` — the guest harness (rerunnable via `tools/qtest pushrun`)
- `workarea-check-guest-output.txt` — raw VMShell output (all RESULT_*/WALINE markers)
- `workarea-fullshot.tar`, `fullshot/` — dom0 full-desktop capture + geometry.txt
- `notepad-top-edge.png` — top edge OK (panel, red guid frame, title, menu)
- `notepad-bottom-edge.png` — bottom 16 px crop (scrollbar visible, status bar cut)
- `notepad-right-edge.png` — right edge (no overflow; screen continues to 5120)

## State restored

Notepad (PID 3748) closed; no processes left running; LogLevel never raised (stayed 3);
no registry values written; agent not restarted (log census unaffected).
