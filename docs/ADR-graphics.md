# ADR - graphics decisions

Precise decisions only. Explanations for the reader live in `docs/DESIGN-graphics.md` and `docs/DESIGN-window-surfaces.md`.

## Decisions

| id | decision | status |
|---|---|---|
| G1 | The IddCx driver ships on and is the guest's sole active output. The emulated adapter is disabled. | ACCEPTED |
| G2 | The agent is the sole writer of the mode list. Nothing ever snaps to a nearby resolution. | ACCEPTED |
| G3 | On build 26100+ the WGC broker is latched at agent start and is the pixel source for ordinary windows. | ACCEPTED |
| G4 | Below 26100 the PrintWindow engine remains. No timed PrintWindow on any build. | ACCEPTED |
| G5 | Capabilities are latched at start and never re-read. A component that stops is a failure, never a mode change. | ACCEPTED |
| G6 | No silent fallback and no silent recovery. | ACCEPTED |
| G7 | The IDD never feeds frames through its own grant path without the owner's approval. | ACCEPTED |
| G8 | Boot, logon and shutdown screens are never shown (Mode 1). Borderless true-fullscreen is shown only when dom0 opts in (Mode 2). | ACCEPTED |
| G9 | Chrome fragments are not windows. A contained popup may be synthesized onto its owner; one outside is its own override-redirect window. | ACCEPTED |
| G10 | A toast is cropped to its visible card before it is mapped. | ACCEPTED |
| G11 | A guest notification is forwarded to dom0 by default. Misrouting fails open. The banner is suppressed by not mapping it. | ACCEPTED |
| G12 | A re-created window keeps its guest position. A dom0 resize lands once and settles. | ACCEPTED |

Detailed evidence and open items for each decision remain in the topic ADRs (`ADR-display.md`, `ADR-capture.md`, `ADR-windows.md`, `ADR-toasts.md`, `ADR-gui.md`). This file is the index of the live decisions.
