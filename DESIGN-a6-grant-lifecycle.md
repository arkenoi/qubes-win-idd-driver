# DESIGN A6 — screen-grant lifecycle: in-place resize, ack-gated revoke, leak-free exit

Status: **design for user review — no code until approved** (CLAUDE.md Phase 3; PLAN-trackb-t2-modes.md §6.2).
Written 2026-08-04, after the graceful-exit source verification (FINDINGS same date). Every
file:line below was read this session, not recalled.

## 1. The three defects this design covers (one mechanism underneath)

All three are the same underlying gap: **the agent revokes or abandons grants without any
handshake telling it dom0 has released its mappings.**

1. **Resolution change destroys every window.** `RecreateDuplication` returns FALSE when the
   new desc's geometry differs (`capture.c:272-280`), so the one event T2 generates
   continuously (mode change → `DXGI_ERROR_ACCESS_LOST`) always takes the teardown path:
   `StopFrameProcessing` → unmap+destroy all windows → recreate (`main.c:3716-3721`,
   `:3422-3441`). The protocol does not require this: `handle_window_dump` releases the old
   mapping first (`xside.c:3875`) and `MSG_WINDOW_DUMP_ACK` exists (`xside.c:3692-3694`).
2. **Revoke-before-notify inversion.** In recovery, the agent revokes the old screen grant
   (`capture.c:244-252`) *before* dom0 has been told anything; dom0 still maps the pages, so
   the revoke can fail (in-code admission `main.c:3742-3743`). Rare today (recovery only);
   T2 would make it per-resize steady state — that promotion is why this needs design review.
3. **Exit leaks grants even on a graceful stop** (verified 2026-08-04): exit order is
   `PwShutdown` → `libvchan_close` → `StopFrameProcessing` → `CaptureTeardown`
   (`main.c:3768-3781`). There is **no detach-all loop on the exit path** (the only one,
   `ResetWatch` at `main.c:1797`, is called solely from `SetSeamlessMode`), so every
   still-attached per-window buffer (~4838 pages each at 3440x1440) leaks silently; and the
   screen revoke runs after the vchan is closed, so dom0 may still map those pages too.

## 2. Design

### 2.1 Ack-gated double-buffered screen re-grant (fixes 1 + 2)

On a geometry-changed `ACCESS_LOST` (and, later, on an intentional T2 resize):

```
1. duplicate the output at the new geometry; update ctx->width/height from the NEW desc
2. allocate + grant the NEW framebuffer (old grant still live — two live grants, transiently)
3. send MSG_WINDOW_DUMP for window 0 at the new geometry
   -> dom0: handle_window_dump releases the OLD mapping first (xside.c:3875), maps the new
4. send MSG_CONFIGURE for window 0 with the new size (daemon adopts it; window 0 is exempt
   from configure flow-control, xside.c:2063-2069)
5. on MSG_WINDOW_DUMP_ACK for window 0: revoke the OLD grant
   (mirror of the per-window PwRevokeTick pattern, vchan-handlers.c:698-702)
6. fallback: if no ack within T (proposal: 5 s) or the vchan dies, queue the old grant on the
   existing pending-revoke retry queue instead of leaking it silently; log loudly either way
```

- No window is unmapped or destroyed; dom0 keeps every window. This is D5 acceptance
  criterion 4 ("zero window-0 destroy/create during resize").
- Transient cost: two framebuffer grants live at once (~10k pages at 3440x1440) — well
  inside the grant table, and bounded by the ack timeout.
- **Hard prerequisite: A3** (page count + header geometry derived from `ctx->width/height`,
  one writer). Without it the re-dump can send a mismatched page count, and a short count is
  `exit(1)` in the daemon (`xside.c:3903-3913`). A3 lands first as its own branch with its
  assertion seen firing on the pre-fix build.

### 2.2 Leak-free (best-effort) exit (fixes 3)

Reorder the exit path so notification precedes revocation, all bounded:

```
1. detach-all: for each tracked window, PwDetachWindow (queue revoke) + send MSG_UNMAP /
   MSG_DESTROY while the vchan is STILL OPEN  (today: never happens)
2. send screen MSG_UNMAP/MSG_DESTROY (today: sent after g_VchanClientConnected=FALSE, i.e.
   silently dropped, send.c:440-441)
3. bounded drain: pump acks/revoke ticks for up to T_exit (proposal: 2 s total)
4. libvchan_close; CaptureTeardown (screen revoke — now likely to succeed, daemon released)
5. exit regardless of drain success — a dead daemon must not stall shutdown. All sends on
   this path must respect the existing g_VchanClientConnected gate; note VchanSendBuffer's
   unbounded spin on a full ring (vchan-common.c:100) — the drain loop must use a
   space-checked send or skip when the ring is full, never block.
```

### 2.3 Explicitly out of scope here

- Per-window WGC/PrintWindow capture redesign; protocol changes (no new message types — this
  design uses only `MSG_WINDOW_DUMP`, `MSG_WINDOW_DUMP_ACK`, `MSG_CONFIGURE`, `MSG_UNMAP`,
  `MSG_DESTROY`, all existing and already handled on both sides).
- The daemon-side EOF bugs (separate, `DESIGN-gui-daemon-restart-survival.md` §3).
- Stride/pitch (protocol gap; separate design if exp 1/D2 shows pitch != width*4).

## 3. Measurement plan (controls that can fail)

| claim | instrument | control that fails |
|---|---|---|
| zero window-0 destroy/create across a resize | count `SendWindowUnmap/Destroy(NULL)` log lines + daemon window count | A1 build: destroy count MUST be nonzero on the same resize |
| old grant actually revoked after ack | grant-accounting recipe (FINDINGS 2026-08-04: LogLevel=4 for screen lines) + new INFO line on ack-revoke | pre-fix build: revoke fails (win_perror at capture.c:253) or never runs |
| exit leaks gone | per-window attach/detach INFO-line balance at LogLevel=3 across a graceful stop | HEAD build: attached > detached by exactly the live-window count |
| no stall on dead daemon | graceful stop with gui-daemon killed first completes < T_exit+5 s | design-less build: can hang forever (vchan spin) |

## 4. What needs the user

- **Approval of this design** before any A6/exit-path code (Phase 3 rule).
- No dom0 or daemon changes are required for any of it.
