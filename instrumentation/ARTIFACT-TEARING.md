> **CONTROL RESULT — this is NOT a Phase 2A regression.** The identical test on the
> STOCK shipped agent (`gui-agent.exe.orig`, restored via `swap-agent.ps1 -Restore`)
> reproduces the same class of corruption, arguably worse: missing title bar, clipped menu
> bar ("ile Edit Format View Help"), and a stale `line 1` row above `line 501...`.
> Evidence: `artifact-tearing-STOCK-agent.png` vs `artifact-tearing-phase2a.png`.
> The "Phase 2A removed accidental pacing and exposed the race" theory below is therefore
> WRONG as stated — the corruption happens at 6.6 fps too. Phase 2A does not block on this.
> It is a pre-existing bug in the shipped QWT, worth fixing and worth an upstream issue.
>
> Also corrected: MSG_WINDOW_DUMP_ACK (149) is NOT usable as per-frame flow control. The
> protocol header states it exists so the agent knows "when it can safely unmap a window's
> grants" — it acknowledges MSG_WINDOW_DUMP, not per-frame damage. Candidate fix (1) is out.
>
> Additional confirmed property: the corruption is **persistent, not transient**. Three
> seconds after scrolling stops the stale band is still there, because nothing damages that
> region again so dom0 never re-reads it. It does not self-heal.

# Visible artifact after Phase 2A: stale scanline bands (framebuffer read race)

Reported by the user ("i have seen a visible artifact ... not very bad but worth catching")
and reproduced under the drag/scroll harness. Evidence: `artifact-tearing-after-2a.png`.

## What it looks like
In a scrolling Notepad window, captured from dom0 while the harness ran:
- a **stale band at the top of the client area** still showing `line 1` while the rest of
  the window shows the scrolled position (`line 370`+);
- the **status bar row at the bottom torn/clipped**.
i.e. horizontal bands of the window show pixels from an older composition than the rest.

## Why Phase 2A exposed it (it did not create it)

Frame lifecycle in the agent (`capture.c` CaptureThread):
1. `GetFrame` -> `AcquireNextFrame` + `MapDesktopSurface`
2. `SetEvent(frame_event)` -> main loop sends `MSG_SHMIMAGE` (dirty rects)
3. wait for `ready_event` (main loop signals *after* sending)
4. `ReleaseFrame` -> `UnMapDesktopSurface` + `ReleaseFrame`, loop

The agent/daemon handshake covers only step 2->3, i.e. that the *message* was sent. But the
framebuffer itself is granted to dom0 **once** and read **asynchronously**: dom0 copies from
that shared memory after it receives the message. Once the agent releases the frame and
acquires the next one, DXGI writes new content into the same system-memory desktop image —
**while dom0 may still be copying**. There is no producer/consumer synchronisation on the
shared buffer at all.

Before Phase 2A the per-frame window enumeration took ~25 ms, which accidentally acted as a
pacing delay: dom0 essentially always finished copying before the next update landed. Phase
2A cut frame processing to ~0.57 ms (44x), removing that accidental head start and making
the pre-existing race observable. **This is a latent protocol-level bug, not a regression
introduced by the tracking rework** — but it is now user-visible, so it must be fixed as
part of shipping Phase 2A.

Corroborating: the artifact appears in a *scroll* workload (large, full-width damage per
frame = the longest copy for dom0), which is where the race window is widest.

## The lever that already exists: MSG_WINDOW_DUMP_ACK (149)

The gui-agent log has been printing, since before any of our changes:

    HandleServerData: got unknown msg type 149, ignoring

149 is `MSG_WINDOW_DUMP_ACK` — the daemon acknowledging it has consumed the window dump.
The agent parses and discards it. That is precisely the backpressure signal needed: the
agent should not overwrite the shared framebuffer until dom0 has acknowledged consuming the
previous image.

## Candidate fixes, cheapest first
1. **Honour MSG_WINDOW_DUMP_ACK as flow control** — do not release/re-acquire the frame
   until the ack for the previous damage arrives (with a timeout so a slow or absent daemon
   cannot wedge capture). Zero copies, uses an existing protocol message. Needs a check of
   what the daemon actually acks and how often; if it only acks full dumps, not per-damage,
   this is insufficient alone.
2. **Pace the capture loop** — cap frame delivery (e.g. 60 Hz) so dom0 keeps a copy budget.
   Trivially safe, but a heuristic, and it gives back some of the win.
3. **Stage the dirty rects** — copy only the damaged regions into a stable buffer that is
   what dom0 has been granted, so DXGI's next write cannot race the read. Preserves
   correctness exactly; costs a memcpy proportional to damage (not to screen area), which
   the measurements say is small (1.28-2.49 rects/frame). This breaks the strict
   "zero-copy, grant once" property recorded in CLAUDE.md fact #1, so it needs sign-off.

Recommended: investigate (1) first since the message is already on the wire, fall back to
(3) scoped to dirty rects. Do NOT ship Phase 2A upstream without resolving this — the
performance win is real (drag 44.9 ms -> 1.33 ms/frame) but it trades a latency problem for
a correctness one if left as is.
