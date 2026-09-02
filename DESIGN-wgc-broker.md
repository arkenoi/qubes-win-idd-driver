# DESIGN: WGC capture broker (Win11 24H2+ per-window capture for occluded NRB windows)

Status: IMPLEMENTED + tested end-to-end 2026-09-02 on win11-p2 (build 26100). Experimental,
feature-gated OFF by default. Branch `p2-noscreengrant` (agent branch `p2/noscreengrant`).
Clean pre-broker base tagged `p2-baseline`.

## What it is

The SYSTEM gui-agent cannot activate Windows.Graphics.Capture (IsSupported → 0x80070424 from a
service token — proven). A small **user-session broker** (`tools/wgcbroker`) can. It captures the
window classes the agent's PrintWindow engine cannot — occluded NRB / DirectComposition app
windows (UWP, Windows Terminal) — via per-HWND WGC and streams frames to the agent over a
cross-session shared section. The agent copies them into the existing per-window granted buffer,
replacing the composited-desktop *slice* source for those windows. Everything else is unchanged.

**Scope (adversary-corrected):** the broker serves ONLY occluded NRB app windows — where the
composited slice bleeds the occluder and per-HWND WGC is occlusion-independent. It does NOT serve
toasts / shell CoreWindows (CreateForWindow returns E_INVALIDARG on them — measured) or o-r menus
(topmost, slice-correct, short-lived). Toasts are handled by the separate notification interceptor
(render as normal in-guest windows — the Linux model). Win10 / pre-24H2 keep the PrintWindow+DDA
hybrid untouched (WGC border unremovable on 19045).

## Architecture

```
  user session (medium IL)                         SYSTEM (gui-agent)
  ┌───────────────────────┐   Global\ shared section  ┌────────────────────────┐
  │ wgcbroker.exe         │   (SYSTEM-created, SDDL:  │ agent frame loop        │
  │  WGC CreateForWindow  │    SY full, IU r/w, ME NW)│  BrokerFreshFrame()      │
  │  per registered HWND   │  ┌────────────────────┐  │   - seqlock read         │
  │  FrameArrived ────────►│  │ header + N slots + │◄─┼── - BOUNDS-CHECK every   │
  │  staging copy → arena  │  │ pixel arena        │  │     broker-written field │
  │  per-slot seqlock write│  │ (double-buffered)  │  │  → PwSliceCopyAndDamageSrc│
  └───────────────────────┘  └────────────────────┘  │  → granted per-window buf │
        ▲ spawned via SpawnHelperAsUser token-borrow  │  → MSG_SHMIMAGE → dom0    │
        │ ~1Hz supervise: heartbeat, relaunch          └────────────────────────┘
```

- **IPC** (`agent/gui-agent/wgcbroker_ipc.h`): 128-byte header (magic/abi/heartbeats/pids/
  arena/producing/shutdown) + 32 slots (control: agent-writes hwnd/size/state; status+data:
  broker-writes ackstate/dims/stride/activebuffer/seqlock/frameid) + a pixel arena the agent
  bump-allocates (128 MB budget). Section is SYSTEM-created (only SYSTEM can make Global\ objects,
  so a user process can only OPEN it), DACL grants the interactive user r/w, Medium-IL no-write-up.
- **Seqlock**: broker writes the spare ring buffer, bumps Seq odd→publish→even; the agent reads
  Seq (retry while odd), snapshots, copies, re-reads Seq, retries on mismatch (≤4, then slice).
  Per-slot CRITICAL_SECTION in the broker serializes racing free-threaded FrameArrived callbacks.
- **Security** (adversary (b)): the control section is user-writable, so the agent bounds-checks
  EVERY broker-written field before use — ActiveBuffer in range, dims==slab exactly, arena region
  fully in-bounds, secure-desktop freshness — so a hostile user-IL process cannot drive an OOB
  read into the granted slab. The broker only ever sees the interactive user's own windows (pixels
  that user could already WGC-scrape); NOT an isolation-boundary change.
- **Lifecycle**: agent creates the section + spawns the broker (shell-token borrow, keeps the
  process handle) + supervises at ~1 Hz (main-loop wait capped to 1 s while active so the heartbeat
  stays fresh during idle); relaunch on death/session-change; broker exits on Shutdown / agent
  process death / agent-pid mismatch (stale broker) / session change / 10 s heartbeat stall.
- **Fallback**: any broker miss (down, no fresh frame, secure desktop, torn read, dim mismatch)
  falls through to the exact composited-desktop slice — a broker-fed window is NEVER blank.
- **Gate**: `g_OsBuild >= 26100` AND registry `WgcBroker`/qubesdb `/qubes-service/wgc-broker`
  (default 0, experimental).

## Test result (win11-p2, 26100, 2026-09-02)

- **Stage 2a** (section+spawn+supervise): broker launches once, heartbeats, stays stable across a
  90 s idle window (churn fixed), rendering unaffected. PASS.
- **Stage 2b** (consumer): opened Calculator (NRB `ApplicationFrameWindow`). Agent logged
  `BROKERFRAME first WGC frame consumed hwnd 0x201fc slot 0 1202x934` — the broker path engaged
  (not slice-fallback). Calculator's dom0 window rendered its full live UWP content (typed "78"
  visible) — DirectComposition content PrintWindow cannot capture. PASS.

## Owed / follow-ons

- Occlusion A/B DONE 2026-09-02 (win11-p2): Calculator occluded by Notepad in the guest. Broker ON
  -> Calculator renders CLEAN (WGC occlusion-independent). Broker OFF (control) -> Notepad bleeds
  into Calculator's window from the composited slice. Disjoint, seen-to-fail on the control - the
  broker's value-over-slice is proven.
- Cold-boot acceptance (the guest test currently uses a live agent restart — Win11 flaky-autologon
  cold boots stalled the heavy harness; verified live instead). Re-run through a clean cold boot.
- The dim-match requirement (FrameWidth==entry->Width) means a window whose WGC ContentSize differs
  from the agent's DWM-visible bound falls back to the slice; refine with cropX/Y if needed.
- DirtyRegions (24H2) not yet consumed (whole-window frames today); MinUpdateInterval not set.
- Toast interceptor (separate component) + o-r-menu WGC probe — decide whether the slicer retires
  FULLY (north star).
