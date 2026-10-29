# ADR - window content capture: the PrintWindow engine, the WGC broker, and rest

Current path: `docs/ADR-graphics.md`.
Superseded and rejected sections live in `docs/archive/ADR-capture-history.md`.
Section numbers are unchanged.

## In plain English

Every guest window shown in dom0 needs a source of pixels. On build 26100 and later the agent latches the WGC broker at start. Ordinary windows are captured by a user-session helper; Windows pushes a frame only when the window changes. At rest nothing runs. Menus that WGC refuses are rendered on demand by a broker PrintWindow slot. Below 26100 the PrintWindow engine remains: unoccluded windows are established once and copied from the desktop; partly covered windows are painted whole on each change of their own visible pixels. No timed PrintWindow. A session that stops delivering is recreated once on input; if the fresh session is silent the window is declared deaf and the user is told in dom0.

## The decisions at a glance (live)

| § | decision | status |
|---|---|---|
| 1 | Pixel source chosen per window class; capabilities latched at start | ACCEPTED |
| 4 | No timed PrintWindow | ACCEPTED |
| 14 | At rest, zero work | ACCEPTED |
| 18 | Every window on 26100+ is WGC through the broker | ACCEPTED |
| 32 | Liveness from input and Windows' own events only | ACCEPTED |
| 33 | Desktop duplication is a window-0 engine, not the capture path | TARGET STATE |

Full table and superseded sections: `docs/archive/ADR-capture-history.md`.

## Live rules

**§1.** Every tracked window gets one pixel source, chosen by class and by capabilities latched once at agent Init. A broker that was working and stops is a failure, never a capability change.

**§4.** PrintWindow runs only because something happened to that window. Never because a timer fired.

**§14.** At rest, zero work: no timer, no PrintWindow, no heartbeat.

**§18.** On 26100+ every ordinary window is a WGC session in the user-session broker. The desktop image is not a window source.

**§32.** Liveness is checked only on input. A session that delivers nothing after one recreate is declared deaf. The damage-comparison detector is gone.

**§33.** Desktop duplication remains only as a damage signal and is a target for removal.

Status vocabulary: `docs/ADR-README.md`.
