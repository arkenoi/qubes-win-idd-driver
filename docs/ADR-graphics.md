# ADR - graphics: the index of decisions across the graphics ADRs

This file is an INDEX, not a second contract. Every row names the ADR section where the decision is
made, with its evidence and its status; if a row and its section ever disagree, the section is right
and this row is wrong. Explanations for the reader live in `docs/design/DESIGN-graphics.md`,
`docs/design/DESIGN-window-surfaces.md` and `docs/design/DESIGN-capture-paths.md`. Status words:
`docs/ADR-README.md`.

## Decisions

| id | decision | decided in | status |
|---|---|---|---|
| G1 | The IddCx driver ships on and is the guest's sole active output; the emulated adapter is disabled. | `ADR-display.md` §1 | ACCEPTED (owner) |
| G2 | The mode list is ours: the agent is the sole writer, and nothing ever snaps to a nearby resolution. | `ADR-display.md` §4 | ACCEPTED |
| G3 | On build 26100+ the WGC broker is latched at agent start and is the pixel source for every ordinary window. | `ADR-capture.md` §18 | ACCEPTED, measurement owed |
| G4 | Below 26100 the PrintWindow engine remains. No timed PrintWindow on any build. | `ADR-capture.md` §1, §4 | ACCEPTED |
| G5 | Capabilities are latched at start and never re-read; a component that was working and stops is a failure, never a mode change. | `ADR-capture.md` §1; `ADR-toasts.md` §7; `ADR-README.md`, cross-cutting rules | ACCEPTED |
| G6 | No silent fallback and no silent recovery: fail hard and visibly. | `ADR-windows.md` §8; `ADR-README.md`, cross-cutting rules | ACCEPTED (owner) |
| G7 | The IDD never feeds frames through its own grant path without the owner's approval. | `ADR-display.md` §6 | ACCEPTED (owner), a standing gate |
| G8 | Boot, logon and shutdown screens are never shown (Mode 1, unconditional). A borderless true-fullscreen window is shown only when dom0 opts in through `service.gui-fullscreen` (Mode 2). | `ADR-windows.md` §1, §2, §3 | ACCEPTED (owner) |
| G9 | Chrome fragments are not windows. Popups, tooltips and toasts are override-redirect windows; a contained menu is synthesized onto its owner. | `ADR-windows.md` §6, §7 | ACCEPTED (owner) |
| G10 | A toast maps as an override-redirect popup at its true position, cropped to its visible card by toastcrop before it is mapped. | `ADR-windows.md` §7 | ACCEPTED (owner) |
| G11 | A guest notification is dom0's to render; the route is decided per toast; misrouting fails open, never closed; when the classifier cannot trust its inputs it stops classifying; the guest banner is suppressed by not mapping it; a toast's buttons travel to dom0 as actions - all of them or none. | `ADR-toasts.md` §1, §2, §3, §8, §10, §11 | ACCEPTED (§10 and §11: owner) |
| G12 | A re-created window keeps its guest position; a dom0 resize lands once and settles. | `ADR-gui.md` §1, §2 | ACCEPTED (Jev) |
| G13 | The secure desktop is handled by mode - never mapped in seamless, shown inside the one bounded window in non-seamless - and UAC prompts are drawn on the normal desktop. | `ADR-windows.md` §4; `ADR-uac.md` §1 | ACCEPTED (owner) |
| G14 | Non-seamless window 0 is shrunk to 1280x800 on entry and refused at host size unless the size came from dom0; the host size is published in the mode set only while seamless is active. | `ADR-windows.md` §5 | ACCEPTED (owner) |
| G15 | No composite fallback on a direct-capable guest. | `ADR-windows.md` §8 | ACCEPTED (owner) |
| G16 | Autologon is enforced: a guest without a session is unreachable. | `ADR-windows.md` §10 | ACCEPTED (owner) |
| G17 | A window's change is a change of its OWN visible pixels; some applications repaint because they were asked to paint, and the engine treats its own PrintWindow as a possible cause of damage. | `ADR-capture.md` §5, §8 | ACCEPTED |
| G18 | Guest stacking follows dom0 only through focus. | `ADR-capture.md` §6 | ACCEPTED (a protocol fact) |
| G19 | Liveness is judged from input and Windows' own events only; a session that delivers nothing after one recreate is declared deaf, the notice is raised once per application per boot and at most 8 error notices per boot (`QERR_CAP_PER_BOOT`), and the user is told in dom0 to close and reopen the window. | `ADR-capture.md` §32 (item 5) | ACCEPTED (owner) |
| G20 | A required-kept toast is held back from mapping until its crop resolves, bounded by `CROP_BEFORE_SHOW_TIMEOUT_MS` = `TOAST_CROP_UIA_TIMEOUT_MS` (500 ms) + 200 ms = 700 ms (400 ms until 2026-09-09). | `ADR-windows.md` §7 for the crop; the budget is a constant in `agent/gui-agent/main.c` / `toastcrop.h` | ACCEPTED (owner) for the crop |
| G21 | Alt-nav key-tip badges are dropped fully: not shown in dom0, nothing spent on them. | `ADR-capture.md` §31 | ACCEPTED (owner, 2026-10-02) |
| G22 | A PrintWindow popup's first frame is retried at 0/50/100/200/400 ms after its open, then only its own pokes render it. | `ADR-capture.md` §19 (item 6) | ACCEPTED (Jev); built in the broker since c30cc77a (`WGCBRK_PW_FIRST_MS`, `tools/wgcbroker/wgcbroker.cpp`); MEASURED 2026-11-01 on 26300.9457: none of 13 popups entered it, so its premise is refuted on that build, and other window classes are not measured (`ADR-capture.md` §19 item 6) |

## Postponed and open

| id | item | tracked in | status |
|---|---|---|---|
| P1 | Covered-window refresh below 26100: WGC is unavailable there, so the sweep remains until a per-window change event exists or the owner decides otherwise. | `ADR-capture.md` §7 | OPEN below 26100; answered on 26100+ by §18 |
| P2 | The echo guard's main cost on the PrintWindow path is unmeasured; the guard stays, and widening or retiring it waits for the number. | `ADR-capture.md` §9 | ACCEPTED, PROVISIONAL |
| P3 | Non-seamless frame supply on later entries: the capture thread's departure is noticed (`QGACAPDEAD`); its root cause is open. | `ADR-windows.md` §5 | OPEN |

## Not a product path

Fault-injection bits (`FI_GATE_MODE1`, `SoloFaultInject` and their siblings) are harness instruments.
They exist so a suite can see a gate fail on one binary. They are not product behaviour and are not
listed as decisions. Their definition and use live in the harness (`tools/tests/`,
`agent/gui-agent/faultinject.c`).

## Corrections made when this index was merged (2026-11-01), and corrected again the same day

The draft carried four claims this index checked against the ADRs and the source when it was merged
(02:03); that check got two of them wrong, and the first re-check (same afternoon, after a Jev review the
merge itself had not had) got one of those wrong a second time. "At most 8 notices" IS the contract
(`ADR-capture.md` §32 item 5) and the source (`QERR_CAP_PER_BOOT` = 8, `notifyerr.h`): G19 names it. "Menu
first-frame retries 0/50/100/200/400 ms" IS the contract (`ADR-capture.md` §19 item 6, ACCEPTED (Jev)) AND
is in the source - the merge struck it as "no such ladder exists in the agent", and the re-check, having
searched only `agent/gui-agent/`, recorded it as ADR/source drift; the schedule is the broker's,
`WGCBRK_PW_FIRST_MS` in `tools/wgcbroker/wgcbroker.cpp` since c30cc77a; the agent process holds only the
companion, the slice map hold (`SliceContentReady`). Whether the schedule fires is not instrumented (the
broker has no log). G22 said exactly that until the 2026-11-01 measurement it now records. (This product's source is four trees: `agent/gui-agent/`,
`tools/wgcbroker/`, `tools/notifhost/`, `tools/notify-proxy/`; a claim about "the agent" must say which.)
"CROP_BEFORE_SHOW_TIMEOUT_MS = 400" was wrong (700 since 2026-09-09, `main.c:6202`). Alt-nav badges as
POSTPONED was wrong (§31 is owner-ACCEPTED, G21). Every other row was re-read against the Status line of
the section it cites on 2026-11-01: all agree.
