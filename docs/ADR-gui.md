# ADR - gui: window geometry between the guest and dom0

Decisions about how the agent and dom0's gui-daemon agree on where a window is. One section per decision, newest last.

## 1. A re-created window keeps its guest position; dom0's frame placement is answered, not obeyed — ACCEPTED (Jev), 2026-10-01

**Decided:** windows the agent re-creates in a bulk pass (its own start; seamless re-entry) are marked; the first configure dom0
sends for such a window within 2 s that only MOVES it is ACKed by byte-echo as every configure is, and then answered with the
guest's own position instead of being applied to the guest window. Everything else - an echo, a resize, a later move, a dom0 that
answers with the offset again - takes the existing path. Agent 05492e5 (`RestartPlacementTick`, `QGAPLACEKEEP`); for a window held
for its first frame the 2 s start at its map, where dom0's WM places it (b4c4fda, Jev 0.85).

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

## 2. A dom0 resize lands once and settles: sizes gated like moves, held while landing, converted — ACCEPTED (Jev), 2026-10-02

**Decided:** for every window dom0 resizes (owner: "all windows"), (a) a size-only post is in flight like a move: at most one
async SetWindowPos per window until the window TAKES it - its rect moves away from where it was when posted, or it already sits on
the target - bounded by the existing 200 ms; (b) every geometry announce, size included, is held while dom0 streams configures or
while its last geometry is pending or landing, and the resting geometry is then announced once, only where it differs from dom0's
(a size the window refused); override-redirect changes are not held; (c) the dictated size gets the window's invisible-border
delta back (GetWindowRect minus DWM bounds, measured with the origin delta, 0..64 px). Agent 001b525.

**Why:** the owner: "resize and settle its contents if we do resize at all, not iterative self-driven border changes". Their traced
drag of Settings (2026-10-02 00:00): 650 dom0 configures became 519 size-only posts, none gated (the 2026-08-12 latest-wins gate
compared only the origin), so the window - ~90 ms to re-lay out a step - lagged p50 1.9 s, max 9.9 s and replayed for 3.6 s after
release; 444 of its lagging sizes were announced back during the drag and 45 after it, each applied by the daemon; and 392 + 45 of
them were dom0's size minus 14x7, because SetWindowPos received announce-space sizes. Taking the post (not reaching the exact
target) is the gate so a window that snaps or clamps its size still follows a drag.

**Superseded before commit:** holding a UWP frame's resize until the configures stop and applying it once (Jev 0.72 at the time).
It rested on "the app's content stayed at 502x1141", which was FALSE - WGC's last arrival was 897x728, the window had resized; the
stale picture was the capture path publishing nothing after the resize (a separate defect, under reproduction). On the corrected
facts Jev chose the root causes 0.93; review before commit: at most one post waits behind a slow layout 0.84, snapping windows
follow 0.91, a refused size reaches dom0 once 0.86, conversion right 0.80, commit 0.62.

**Cost:** a guest-initiated change is announced up to 200 ms late while a lone dom0 configure lands. **Seen to fail:** the
drag-replay metric (ACKs paired by order) on settings-drag-1, build rz21 - 392 own announces during the drag (391 of them dom0's
size minus 14x7) and 45 after it over 3.61 s, final 897x728 against dom0's 911x735. **Pass (2026-10-02 01:03, build rz23 =
001b525, the owner's own drag, owner: "all perfect"):** 310 configures -> 54 posts; 2 own announces during the drag, 3 in the
0.41 s after it, the last one dom0's final 1087x850; none dom0-minus-14x7; the capture settled at the final size (published
frame = request). **On an ordinary window** (resize-ab-1, dom0's local.WinResize on the largest Win32 window, CTL rz21 / NEW
rz23 interleaved, 3 rounds of shrink + restore): CTL 6 of 6 resizes ended 12x6 short (the window drifted 3802 -> 3766 wide over
the rounds), NEW 6 of 6 exact. **Residual:** the 3 announces after release - Settings took more than 200 ms per resize at
~1100x860, so the in-flight bound expired, two more posts queued, and an older post landing read as the newest taken; the
border stepped by up to 10 px for 54 ms, 0.35 s after release, then held. Remedy if it is ever seen: a longer in-flight bound for
size posts (the bound only guards a window that never changes).
