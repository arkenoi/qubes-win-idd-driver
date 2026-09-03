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
- **Lifecycle**: agent creates the section + launches the broker **via the Task Scheduler**
  (`schtasks /create /tn Qubes-WgcBroker /tr "<8.3-short-path>\wgcbroker.exe --serve ..." /ru
  <interactive-user> /it /f` then `/run`) + supervises at ~1 Hz (main-loop wait capped to 1 s while
  active so the heartbeat stays fresh during idle). There is NO child process handle under Task
  Scheduler, so **liveness = the shared-memory BrokerHeartbeat advancing within ~6 s** (relaunch
  throttled to no more than once/8 s so a starting broker isn't re-fired). Broker exits on Shutdown /
  agent-pid mismatch (stale broker) / session change / 10 s heartbeat stall. The broker is built
  **Windows-subsystem** (`wmainCRTStartup`) so the Task-Scheduler /it launch shows no console window
  that the agent would map. WHY Task Scheduler and not CreateProcessAsUser: see the monitor-slice
  section — `CreateForMonitor` returns E_HANDLE from a CreateProcessAsUser-spawned broker regardless
  of token/environment, and succeeds only from a Task-Scheduler /it launch.
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

## Full slicer retirement — the monitor-slice (o-r / static windows)

The broker retires the SYSTEM agent's DDA slice for NRB app windows (stage 2b, per-HWND
`CreateForWindow`). But o-r / static windows — menus, tooltips, toasts (shell CoreWindows) — have
NO per-HWND WGC source (`CreateForWindow` fails E_INVALIDARG on CoreWindows; FrameArrived never
fires on static o-r windows). To retire the DDA slice for THOSE too, the broker opens ONE extra
slot with `Hwnd == WGCBRK_MONITOR_HWND`: a full-desktop `CreateForMonitor` capture. Under
`SliceRetire`, the agent slices each o-r window's screen rect out of that composited monitor frame
(screen-relative, origin 0,0) instead of the DDA framebuffer — `ProcessNewFrame` MONSLICE branch,
same bounds-checked copy as the per-HWND path. This is the user-session WGC replacement for the DDA
slice; with it, the agent's own Desktop-Duplication capture can be fully retired.

### Menus UNSLICED — broker PrintWindow fallback (2026-09-02)

The monitor-slice is still slicing (moved to the broker). To take o-r **menus** off the slice
entirely and onto a clean per-window source: WGC `CreateForWindow` rejects menu/popup HWNDs, but
`PrintWindow(PW_RENDERFULLCONTENT)` captures them from the broker's user session (proven — both
redirected WinForms/Win32 menus AND modern Win11 XAML menus `Microsoft.UI.Content.PopupWindowSiteBridge`
render their content; the SYSTEM agent can't be relied on for PrintWindow, but the broker's user
session can). So when a broker window channel fails WGC, it now falls back to **polled PrintWindow**
into a top-down 32bpp DIB, published through the same seqlock (`wgcbroker.cpp` PublishPrintWindow),
gated by a non-black check (CoreWindow/NRB/ULW that PrintWindow also can't do fall back to the slice)
and change-detection (no republish while static). The loop polls ~30 Hz while any PrintWindow channel
is live. No agent change — `BrokerRegister` already broadens to all sliceFed under `SliceRetire`, and
the consumer's per-HWND `BrokerFreshFrame` branch already precedes MONSLICE.

**VERIFIED (win11-p2/26100, cold boot, fresh arena):** a WinForms context menu logged
`BROKERFRAME first WGC frame consumed hwnd 0x5021c slot 2 187x158` and rendered all seven items
cleanly, per-window — off the slice. (It briefly MONSLICEs for one pass before the first PrintWindow
poll publishes, then the broker frame takes over.)

**The CreateForMonitor launch-context bug (RESOLVED 2026-09-02).** `CreateForMonitor` returned
`E_HANDLE (0x80070006)` from the broker for a long chase. Excluded, one at a time, each with the
monitor slot's `AckState/FailHr` as the instrument: the HMONITOR handle (`MonitorFromPoint` vs
`MonitorFromWindow` — both failed), the launch token (shell-borrow → **WTS session token**,
confirmed `WTS session 1`, still E_HANDLE), and the **user environment block** (`CreateEnvironmentBlock`,
still E_HANDLE) — all under `CreateProcessAsUser`. The control that broke it open: `wgcprobe mon`
launched via `schtasks /ru user /it` captured the monitor perfectly (`frameArrived=1 content=5120x1440
hr=0`). So the differentiator is the **launch mechanism**, not the token/env/handle: `CreateForMonitor`
(DWM interop) needs a Task-Scheduler-interactive launch context. `CreateForWindow` tolerates
CreateProcessAsUser, which is why stage 2b worked while the monitor slot did not. Fix = launch the
broker via Task Scheduler **and** use `MonitorFromPoint({0,0}, MONITOR_DEFAULTTOPRIMARY)` (the two
together — neither alone; wgcprobe used exactly both).

**Result (win11-p2, 26100, 2026-09-02, live-swap):** monitor slot `ack=2 fail=0x0 frameId=137
5120x1440` (was ack=3/E_HANDLE); consumer logs `MONSLICE ... monAvail=1` for every o-r/sliceFed
window; a real shell **toast rendered its full content** (title/body/buttons) via the monitor-slice,
NOT black; o-r popup-menu background renders (gray, red dom0 border), not black. The black-popup
regression under `SliceRetire` is FIXED. PASS.

## Owed / follow-ons

- **Composite-synthesis slice dependency — ELIMINATED 2026-09-02.** Synthesis (o-r popups painted
  into their owner's buffer instead of announced — `PwPatchSynthChildClipped`) copied from `g_FbBits`,
  the agent's DDA composited desktop, which full retirement removes — a retirement blocker. Now under
  `SliceRetire` it sources from the broker's `CreateForMonitor` frame (`BrokerMonitorFrame`; same
  composited desktop in screen coords, identical clip/copy), DDA-fb fallback otherwise. Keeps the
  DWM-composited blend synthesis relies on (a per-window opaque capture would lose the popup's shadow
  blend). VERIFIED: regedit's classic File menu synthesized into the regedit window (SynthActivate
  logged, no separate window, no "no composited source" warning) and rendered fully via the per-window
  shot. NOTE: the explorer XAML PopupHost menu still does NOT synthesize (untracked-`GW_OWNER` guard —
  Office shadow-ghost scar tissue) so it maps as a separate broker-PrintWindow window; relaxing that to
  synthesize-on-containment is a separate, riskier enhancement (and would also fix its shadow margin).
- **Arena free-list — DONE 2026-09-02.** `WgcArenaAlloc` was bump-only and never reclaimed, so
  high-churn menus exhausted the 128 MB arena within a session → new registrations failed → menus
  fell back to the slice. Now a best-fit free-list with coalescing (`WgcArenaFree`); each
  unregistered slot's two buffers are reclaimed, DEFERRED ~2 s (`WgcArenaFreeDeferred` /
  `WgcArenaReapPending` from BrokerSupervise) so a region is never reused while the broker could
  still publish to the just-closed slot. Agent-thread-only; reused offsets stay in-arena so the
  broker-frame bounds-checks are unaffected. VERIFIED: 350 back-to-back menu open/close cycles (would
  exhaust the old allocator at ~290) then a fresh menu still BROKERFRAMEd. CAVEAT: under a
  pathological burst (~7 opens/s) the 2 s deferral + 1 Hz reap lag, so burst-peak menus transiently
  MONSLICE; at human menu speed reclaim keeps up and there is no permanent exhaustion.
- **Drop the menu shadow companion.** A Win11 menu maps as TWO o-r windows: the content
  (PrintWindow-clean, now BROKERFRAMEd) and a slightly larger shadow/backdrop (still MONSLICEs).
  Drop the shadow in the window-acceptance predicate — same droppable-chrome class as the Office
  shadow-strip (2A-chrome) filter. (Owner 2026-09-02: "shadows and glows we just drop".)
- Occlusion A/B DONE 2026-09-02 (win11-p2): Calculator occluded by Notepad in the guest. Broker ON
  -> Calculator renders CLEAN (WGC occlusion-independent). Broker OFF (control) -> Notepad bleeds
  into Calculator's window from the composited slice. Disjoint, seen-to-fail on the control - the
  broker's value-over-slice is proven.
- Cold-boot acceptance: stage 2b + the monitor-slice were proven via live agent-swap; a clean
  cold-boot run (scratchpad/p2/run-coldboot.sh) confirms the Task-Scheduler launch path arms from
  boot (no live restart to lean on). [running / see results]
- The dim-match requirement (FrameWidth==entry->Width) means a window whose WGC ContentSize differs
  from the agent's DWM-visible bound falls back to the slice; refine with cropX/Y if needed.
- DirtyRegions (24H2) not yet consumed (whole-window frames today); MinUpdateInterval not set.
- Full slicer retirement: RESOLVED for the o-r/static class via the monitor-slice (above). The
  toast interceptor (notifhost) remains a complementary path that promotes toasts to normal windows.
- **Menu repaint-lag FIXED (2026-09-02, frame-chase).** The one-shot-full-copy + DDA-dirty-rect
  updates were keyed on the daemon's dirty_rects, but the DDA damage clock and the WGC monitor-frame
  clock are independent: a repaint the DDA reports can land in a WGC frame that arrives AFTER the
  damage, with no further DDA damage to trigger a re-copy — leaving a menu with stale pixels
  (a synthetic WinForms menu showed its background but lagged its item text; the black bottom band
  was the not-yet-arrived paint). Fix: `BrokerMonitorFrame` now returns the monitor `FrameId`, and
  after any damage over a monitor-sliced window the consumer CHASES fresh monitor frames for
  `WGC_MON_CHASE_MS` (250 ms) — re-copying the full window rect each time the FrameId advances,
  so the lagged WGC frame is picked up. Bounded to the post-damage window so a static o-r window
  near unrelated on-screen animation is not repeatedly re-copied. Per-window state:
  `PwMonLastId`/`PwMonRefreshUntil`/`PwMonLogged`. VERIFIED: the same WinForms menu now renders all
  seven items ("Open … Properties"), no black band. [live-swap PASS; cold-boot confirm in results]
- `MonitorFromPoint({0,0})` assumes the primary monitor origin at (0,0) — fine for the single guest
  monitor; revisit if multi-monitor is ever added.
