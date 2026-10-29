# ADR - gui: window geometry between the guest and dom0

Current path: `docs/ADR-graphics.md`.
This file keeps the detailed decisions. Section numbers are unchanged.

## In plain English

Placement after a restart. Each agent restart used to move every guest window 5 pixels right and 25 pixels down. A window the agent re-creates in bulk now keeps its guest position: dom0's first move-only placement is acknowledged and then answered with the guest's own position.

Resizing from dom0. Dragging produced hundreds of resize requests that the guest applied one by one. Now at most one resize is in flight per window until the window has taken it, the guest says nothing about geometry while dom0 is still dragging, and it announces its resting size once, only if that differs from what dom0 asked for. The invisible border is accounted for.

## The decisions at a glance

| § | decision | status |
|---|---|---|
| 1 | A re-created window keeps its guest position | ACCEPTED |
| 2 | A dom0 resize lands once and settles | ACCEPTED |

Detailed rules remain in this file. Status vocabulary: `docs/ADR-README.md`.
