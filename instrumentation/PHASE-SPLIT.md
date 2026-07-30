# Drag vs scroll: the user's subjective report, quantified

User observation: *"scroll seems more or less fine. moving the window around is a disaster."*

Sliced the 499-frame instrumented run by harness phase (boundaries from the harness's own
`### PHASE-START/END` stamps, matched against the agent log's timestamps):

| phase | frames | `enu` median | `enu` p95 | `upd` med | `snd` med | frame total med |
|---|---|---|---|---|---|---|
| idle-pre  |   9 | 28.0 ms |  37.9 ms | 407 us |  54 us | 28.5 ms |
| **drag**  | 155 | **43.3 ms** | **102.9 ms** | 664 us | 116 us | **44.9 ms** |
| scroll    | 205 | 18.4 ms |  39.5 ms | 349 us |  44 us | 18.7 ms |
| type      | 106 | 17.4 ms |  35.4 ms | 333 us |  47 us | 17.9 ms |
| idle-post |   9 | 17.5 ms |  24.0 ms | 560 us |  42 us | 18.2 ms |

**Dragging costs 2.4x more per frame than scrolling** (43.3 vs 18.4 ms median) and 2.6x at
p95 (102.9 vs 39.5 ms) — i.e. ~10 fps worst case while dragging vs ~54 fps while scrolling.
That is exactly the reported experience, and it is measured, not inferred.

Why drag specifically: scrolling only dirties pixels inside a *static* window, so the
per-frame window pass stays at its floor cost. Dragging changes window position and z-order
continuously, which churns the state the agent re-derives for all 67 rejected top-level
windows every frame (see PHASE1A-RESULT.md) — so the pass gets slower precisely during the
interaction that feels worst. `upd` and `snd` also roughly double during drag, but they are
sub-millisecond and not the problem.

Phase 2A therefore targets the worst case directly: eliminating the per-frame re-interrogation
should compress the drag column toward the scroll column, and both toward the floor.
