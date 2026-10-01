# ADR - gui: window geometry between the guest and dom0

Decisions about how the agent and dom0's gui-daemon agree on where a window is. One section per decision, newest last.

## 1. A re-created window keeps its guest position; dom0's frame placement is answered, not obeyed — ACCEPTED (Jev), 2026-10-01

**Decided:** windows the agent re-creates in a bulk pass (its own start; seamless re-entry) are marked; the first configure dom0
sends for such a window within 2 s that only MOVES it is ACKed by byte-echo as every configure is, and then answered with the
guest's own position instead of being applied to the guest window. Everything else - an echo, a resize, a later move, a dom0 that
answers with the offset again - takes the existing path. Agent 05492e5 (`RestartPlacementTick`, `QGAPLACEKEEP`).

**Why:** measured 2026-10-01: nine consecutive agent restarts moved every guest window by (+5,+25) each - dom0's window-manager
border and title bar (owner). From the daemon's source: a created window is placed with size hints only (`mkwindow`: PSize, no
frame compensation), so the WM puts its FRAME at the guest position and reports the client one frame-size down-right, which the
agent then applied to the guest window; while the daemon awaits the ACK of its own configure it ignores any other geometry
(`have_queued_configure`), and once acked it applies an agent configure with `_NET_FRAME_EXTENTS` subtracted
(`moveresize_vm_window`) - so the answer has to follow the ACK, and then the client lands where the guest says. Owner: P3, "try a
cheap fix and drop it if it is complicated"; Jev 0.84 for this candidate over dropping it 0.16; review: correct 0.70,
ping-pong 0.22, still cheap 0.71.

**Cost:** one extra configure per re-created window. A new window (not a bulk re-creation) is placed by dom0 as before.
**Not done:** the daemon-side fix (a position hint or StaticGravity on created windows) - outside this repo, upstream only with
the owner's approval of the exact text. **Seen to fail / pass:** the nine-restart creep on rz17/rz18; on rz21 owed.
