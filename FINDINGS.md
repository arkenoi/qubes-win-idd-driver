# FINDINGS.md — dated session findings (append-only)

Mandated by CLAUDE.md; created 2026-07-31 (earlier sessions logged into per-topic files under
`instrumentation/` instead — see GOAL-STATUS.md for the index of those).

---

## 2026-07-31 — per-window capture feasibility session (SESSION-PLAN-per-window-capture.md)

Session start state:
- win-idd-test: Running, stock QWT 4.2.2 installed (our agent build withheld — cold-boot
  enumeration failure, GOAL-STATUS.md).
- Plan: Gate 0 (pwprobe occlusion premise check), Q1 daemon reading, wgcprobe (Q4), capture
  scaling (Q3), grantprobe (Q2), then design writeup for user review.

Findings appended below as steps complete.

### Step 1 / Q1 — VERDICT A: per-window framebuffers are ALREADY the protocol's mainline path

Read read-only clones under `upstream/ro/` (no upstream contact), pinned at:
- qubes-gui-daemon `f66fb34c90d3400772df7e11dfea47331c08407f`
- qubes-gui-common `66b879e36d6cd2a01271fc8d4c2c0f3be85d0029`
- qubes-gui-agent-linux `bc845212eb427db6bd5c41bb5c100ef1221f1ff1`

Evidence chain:
1. **Dispatch is per-window.** `xside.c` `handle_message` resolves `untrusted_hdr.window`
   via `remote2local` and passes the resolved `vm_window` to `handle_window_dump`
   (xside.c:4025-4028). Nothing special-cases window 0 on this path.
2. **The dump attaches to THAT window.** `handle_window_dump` stores
   `image_width/image_height` on `vm_window` and `qubes_xcb_send_xen_fd(g, vm_window, ...)`
   sets `vm_window->shmseg` (xside.c:3869-3916, 3634).
3. **Composition has a native dual path.** `do_shm_update` (xside.c:2277-2292): if
   `vm_window->shmseg != QUBES_NO_SHM_SEGMENT`, damage coords are WINDOW-RELATIVE against
   the window's own image; `else if (g->screen_window)` it slices the screen image offset
   by `vm_window->x/y` (xside.c:2455-2462) — today's Windows-agent model, as the fallback.
4. **`screen_window` is just window id 0.** `FULLSCREEN_WINDOW_ID 0` (xside.h:69); a window
   becomes `g->screen_window` only by being created with remote id 0 (xside.c:455-457).
5. **The Linux agent uses the per-window path today.** vmside.c: every window map sets
   `window_dump_pending = True` (vmside.c:610); the next damage notification calls
   `send_pixmap_grant_refs(g, window)` → `MSG_WINDOW_DUMP` with `hdr.window = <that
   window>` (vmside.c:379-381, 691-695), followed by window-relative `MSG_SHMIMAGE`.

Consequences:
- Per-window capture on Windows needs **no protocol change and no daemon change**. It
  converges the Windows agent with what the Linux agent already does.
- **Q5 largely answered structurally:** mixed mode is native and per-window — any subset of
  windows can carry their own buffer (shmseg set) while the rest fall back to screen-slicing.
  Incremental migration is the daemon's existing behavior, not a feature to build.
- **Q6 reframed:** placement ownership does NOT need to move for the artifact class to die.
  With per-window buffers, content is occlusion- and position-independent; dom0 keeps
  mirroring guest geometry exactly as today (`MSG_CONFIGURE` both directions already exists).
  Host-owned placement becomes an optional later optimization (Phase 3 discussion), not a
  prerequisite.
- Protocol bound relevant to Q2: `MAX_GRANT_REFS_COUNT = NUM_PAGES(16384*6144*4)` ≈ 98k
  pages per dump (qubes-gui-protocol.h:102-121) — the protocol does not constrain realistic
  window sizes; the practical grant budget (Step 4) is the real question.
- `MSG_WINDOW_DUMP_ACK` exists from protocol 0x00010007 (qubes-gui-protocol.h:83-84):
  the daemon acks dump processing so the agent knows when the old buffer is safe to release
  — exactly the resize/re-grant handshake per-window capture needs.
- Caveat: read at gui-daemon master; the user's dom0 runs the R4.3 daemon. Verify the same
  paths in the R4.3 branch before the design writeup goes out (expected identical — the
  dual path predates 4.3).

### Gate 0 — PASSED: occluded-window content IS retrievable (premise holds)

pwprobe `6C9EC6A1…F0872` (hash echoed from the guest each run, matches the CI artifact),
3/3 runs on win-idd-test, stock QWT, interactive session via pushrun:

| arm | expectation | result (3/3 identical) |
|---|---|---|
| baseline (visible, flags=0) | MATCH | MATCH pct=100.0 |
| fullcontent (occluded, PW_RENDERFULLCONTENT) | the question | **MATCH pct=100.0** |
| plain (occluded, flags=0) | negative candidate | MATCH pct=100.0 — see note |
| screen-DC BitBlt of occluded rect | must MISMATCH | MISMATCH pct=0.0 |

Occlusion asserted in-scene every run (`WindowFromPoint` at A's center returned B).
The screen-DC arm is the proof the comparator can fail: same comparator, provably-wrong
pixels, 0.0% match. The flags=0 arm matching is itself a finding: under DWM every
top-level window keeps a redirection surface, so even legacy PrintWindow returns the
window's own content while occluded. Two independent working retrieval paths — the
premise of DESIGN-QUESTIONS §2 is verified, document not void.

### Q1 adversarial verification — all three claims SURVIVED (3 independent skeptics)

Each claim was handed to a skeptic agent instructed to refute from source. None refuted;
all high confidence. Corrections adopted:
- `window_dump_pending` is set on MAP at vmside.c:1032 (my earlier :610 citation was the
  init-to-False site); dumps are also sent on configure-of-mapped (vmside.c:1178-1181) and
  reconnect re-enumeration (vmside.c:1677) — i.e. the resize re-grant path already exists
  agent-side on Linux.
- Per-window dumps require MSG_CREATE first (daemon exits on dump-without-create,
  xside.c:3951-3957) — fine, the Windows agent already creates windows.
- The screen fallback also requires screen_window->shmseg valid (xside.c:2454); Linux
  feeds per-window pixmaps from XComposite redirection (vmside.c:2737-2742,
  xf86-input-mfndev qubes.c:594-681 GetWindowPixmap grant refs).

**R4.3 check: gui-daemon xside.c/xside.h are BYTE-IDENTICAL between master and
release4.3** (git diff empty, same blob hashes; only pulse/mic code differs). The Q1
verdict applies to the user's dom0 daemon as-is.

### Step 2 / Q4 (qualitative) — WGC works and is occlusion-independent on this guest

wgcprobe `2ddc8b8c…ebd4` (guest hash verified via certutil), 3/3 check runs on
win-idd-test (os build 10.0.19044):
- `wgc-supported=1`; occluded static window captured with `content-pct=100.0` →
  `occluded-content=MATCH` 3/3 (occlusion asserted per run).
- `dirty-regions-api=0`: WGC provides NO dirty rects on this build. Per-window damage
  must come from elsewhere (in-guest diffing, or accept full-window damage per frame).
- `border-api=0`: `IsBorderRequired` not settable → the system capture border around
  captured windows cannot be disabled on 19044. Irrelevant in pure per-window mode
  (nothing captures the screen), but a mixed DDA+WGC mode would show yellow borders in
  the screen capture. Design must note it.
- `cursor-api=1`: cursor can be excluded from per-window captures.

Probe-code adversarial review found 1 blocker + 3 major defects in wgcprobe's BENCH mode
(scene/capture on one starved thread; benchstatic arg conflation; mapUs omitting the
full readback; procCpu blind to dwm.exe). All fixed before any Q3 numbers were produced;
check-mode verdicts above are unaffected (full readback path was always used there).
Bench numbers below come only from the fixed binary.
