# Rest-zero, own-surface capture on 26100+ — staged implementation design

Decided by Jev first (four premise-framed calls, 2026-10-01), written by one Fable agent, validated by Jev: no decision
rejected; meets the owner's rules once S4 is done 0.75; reintroduces a 2026-09-02 concession 0.23; ready for S0 0.66;
biggest risk capacity 0.32 / typing latency 0.27 / lost wakeups 0.27. Two validation corrections are applied below
(S4 shutdown kick window rejected 0.66; decision I made strictly unchanged below 26100).

Inputs: `premise.txt` (R1–R4), `verdicts.txt` (Jev, one per key), `citations.txt` + `facts-agent.json` /
`facts-broker.json` (line evidence). Baselines: agent `301cf6f` (M = main.c, P = perwindow.c, C = capture.c,
W = wincapture.cpp, V = vchan-handlers.c, H = wgcbroker_ipc.h), broker `wgcbroker.cpp` on `rest-zero`/`deslice-uwp`
(B; byte-identical on both; `main`'s broker still carries `xprocTick`, so the deslice-uwp file is the base). The
rest-zero branch's agent pointer `2b47ae3` is NOT a baseline: it bundles the sweep removal with the desktop copy the
owner rejected (ADR §15). Everything below is gated on the existing start-time latch `DirectRequired()`
(M:3536-3539 = `g_WgcBroker && g_OsBuild >= 26100 && PwEnabled()`); builds below 26100 and the explicit
`WgcBroker=0` opt-out keep today's behaviour byte for byte (d6, d7).

Verdict rule applied: a key is DECIDED at confidence >= 0.5; below that it is OPEN (a3, c3, c4, d7) and only its
measurement is designed. c5 sits at 0.41 with no competing option (hold-loudly 0.71 vs insufficient-evidence 0.29):
adopted PROVISIONALLY, and c4's measurement is what raises or lowers it (section 4).

Rest = no window moving and no pixel changing on the guest desktop. A wakeup caused by the guest (a present DWM makes
because a guest pixel changed) is the guest's; every other wake, render, poll or heartbeat is ours and must be zero.

## 1. Decisions

### A. A broker frame reaches dom0 on the broker's event, by dirty region — a1 broker-event 0.96, a2 wgc-dirty-regions 0.84, d4 activity-only 0.86
**Decision.** The agent copies broker frames when the broker signals `g_WgcFrame` (M:307, created M:2591, in the wait
array M:10561-10565), not only inside `ProcessNewFrame`. The broker asks WGC for dirty regions
(`GraphicsCaptureSession.DirtyRegionMode` / `Direct3D11CaptureFrame.DirtyRegions`, 24H2) and publishes, per slot, the
regions accumulated since the frame the agent last consumed; the agent copies and damages only those, with a per-row
compare inside each region as the guard against over-reported regions. Pacing is latest-wins by construction: one
wake copies the newest FrameId of every slot, skipped frames are covered by the accumulated regions; no pacer timer.
**Why.** Today the copy happens only in the desktop frame walk (M:9087-9106), which needs a desktop frame with dirty
rects (C:1469-1473, M:8934-8944): a covered window's change waits for an unrelated desktop change — unbounded on a
static desktop. The handler at M:10819-10833 only re-arms the map-defer sweep. Whole-card copies cost three window
copies per keystroke on a maximized window (B:480-489 staging, B:403-464 arena, M:7585-7627 slab) plus a whole-window
damage message.
**Cost.** ABI bump (H) on both binaries; DirtyRegions availability must be latched at broker start and be LOUD if
absent on an eligible build. **Bound.** Per arrival: bytes copied = dirty area x 3, damage = dirty rects; zero at rest.

### B. Every ordinary window on 26100+ is a broker WGC session; the desktop image is a signal only — premise (decided earlier, 0.87), d6 unused-on-26100 0.86, d2 eliminated 0.99, d1 moot 0.92, d5 out-of-scope 0.91
**Decision.** `PwAttachWindowCarry` (P:501-745) routes PWC_ELIGIBLE windows to the broker when `DirectRequired()`
(today `sliceFed = !PwWindowEligible`, P:520, keeps them on the PrintWindow engine). On those guests, in seamless mode,
the desktop-duplication frame is never copied into the staging buffer (C:1072-1138 skipped, `g_FbBits` NULL): the
DDA-mode copy (M:9757-9835, ADR §2, gated today only by `DdaCaptureEnabled` M:8154-8160), the composite slices
(M:9280-9311), the drag slice (M:7715-7757, dead at defaults) and the synth composite arm (M:7818-7825) become
unreachable because the data does not exist, not because a gate says so. Dirty-rect METADATA still flows: it is the
poke/liveness signal (M:9005-9086) and the tracking tick. The engine (W) has zero channels on 26100+; its sweep and
echo guard stay untouched for builds below. No repair tick (a missed frame is a deaf session, E). No drag attribution
machinery (the own-change poke rule, E, keeps a mover's damage from poking windows beneath). Non-seamless window 0 IS
the desktop and is out of scope; the staging copy resumes when `qubes.SetGuiMode` plugs the desktop surface.
**Why.** R2. WGC hands over the window's own surface: nothing is asked to paint (no echo, ADR §8), a frame arrives
only when the window's content changed, covered windows stay live (ADR §7 closes on 26100+).
**Cost.** Capacity (F, c4 OPEN); windows WGC refuses (c3 OPEN); foreground typing latency (a3 OPEN).
**Bound.** No composite pixel on 26100+ in seamless, provable by a NULL source (M4).

### C. Zero wakeups at rest on both sides — b1 no-timeout-event-retry 0.99, b2 event-only 0.92, b3 handles-and-events 0.98, b5 event-driven 0.96, b6 remove 0.96, b7 handles-and-events 0.98
**Decision.** Every wait is INFINITE unless a deadline is pending for work that a request armed (D). Agent: capture
thread `AcquireNextFrame(INFINITE)` (C:36, C:1405), parked-grant retries on the events that release grants (dump
acks, destroys) with a one-shot deadline only while a grant is parked (never under the default staging grant,
C:499-509); engine worker waits INFINITE when nothing is marked or due (W:557-576; below 26100 the sweep arithmetic
is unchanged); main loop: the 1 s cap (M:10603-10612) goes, BrokerSupervise/NotifBridgeSupervise/EtwProxyPoke
(M:10811-10816) become exit-handle- and event-driven, MapDeferWakeSweep (M:4013-4066) becomes one ceiling deadline
per held window. Broker: `MsgWaitForMultipleObjects(INFINITE unless a deadline is pending)` (B:1462); Producing from
`EVENT_SYSTEM_DESKTOPSWITCH` with the live `OpenInputDesktop` check kept at every publish (B:390-399, B:768 — the
security gate, runs only when a frame exists); console session from `WTSRegisterSessionNotification`; no heartbeat
either way; the PrintWindow-route backstop render (B:1532-1533, B:1581-1607) is removed: a PW slot renders on open
and on its own pokes only, and `g_anyPw`'s 33 ms cadence (B:1462, B:1610) goes with it. Helpers: bridge and ETW proxy
by process handle + their own ready/handled signals; launch preconditions (console session, shell window) come from
the watchdog's `SERVICE_CONTROL_SESSIONCHANGE` (watchdog.c:46-48, 636-650) relayed to the agent and from the hook
thread's window events, not from a 5 s poke (etwproxy.c:1024-1055, M:3264-3443). The bridge's own 2 s heartbeat loop
(notifhost.cpp:31) is retired with the contract it served.
**Why.** R1; the code reader's inventory (facts WK0-WK8, WK15-WK17; broker WK0-WK11) shows every rest wake is a
timer whose only purpose an event or a request-deadline can serve.
**Cost.** A lost wakeup is no longer papered over by a timeout: every converted wait needs write-before-signal /
re-check-before-wait and a "signal before wait" fault-injection test (M8). Failure states keep bounded timers:
capture-degraded retry 5 s (M:10370, M:11431-11455), broker relaunch throttle 8 s (M:2945) and its down-warnings
(M:2899-2900), bridge relaunch 60 s — each armed only while the failure exists, and each is itself a loud state.
**Bound.** 0 context switches of any agent/broker thread over 60 s at rest (M1); 0 PrintWindow (M3).

### D. Hangs are detected by request deadlines, not heartbeats — b4 request-deadline 0.96
**Decision.** A one-shot deadline is armed when one side asks the other for something and disarmed by the answer;
unanswered = loud. Requests: (R1) register/retarget -> AckState leaves REQUESTED or FailHr set, 2 s (a hung broker
-> QGABROKERHUNG, today's TerminateProcess + relaunch M:2949-2971); (R2) open of a visible, non-iconic WGC-only
window -> first published frame, 700 ms (= `CROP_BEFORE_SHOW_TIMEOUT_MS`; WGC delivers the current surface on
StartCapture, so silence is refusal or deafness); (R3) own-change poke -> a frame within `WGCBRK_WGC_QUIET_MS`
(H:50, 2 s) — this IS the deafness deadline of E; (R4) unregister -> channel closed (the broker acks by writing
AckState FREE), 2 s — the arena region is reaped on that ack, replacing the 2 s deferred reap (M:323, M:3590-3612,
run from the 1 Hz supervisor M:2785); (R5) broker publish -> the agent's new `ConsumedFrameId` advances, 5 s while the
agent process is alive and Producing — a hung agent is logged by the broker and flagged in the header (a medium-IL
broker cannot terminate a SYSTEM agent; the remedy is the watchdog's, out of scope). Each side passes its earliest
pending deadline as its wait timeout; nothing pending -> INFINITE.
**Why.** R1 and R4 together: heartbeats are timers on both sides (M:2768, B:1454, B:1457) and detect only a HUNG peer;
exits are already handles (M:10765-10768, B:1449). **Cost.** A hang at rest surfaces at the next request, not
within 6-10 s. **Bound.** Nothing armed at rest; every deadline names its request and its slot in the log.

### E. Deafness: pokes only for a window's own change; recreate once, then loud — c1 poke-deadline-own-change-only 0.90, c2 recreate-then-loud 0.68
**Decision.** A damage rect pokes window W only if it lies inside W's rect shrunk by 2 px (M:9056) AND inside the
part of W visible both this pass and the previous one — visible = W minus the union of ALL opaque tracked windows
above it (today: only damage wholly inside ONE occluder is excluded, M:9057-9080; `PwCollectOpaqueOccluders`
M:8003-8027 already produces the list, cap 16 -> no exclusion beyond that stays). If W's visible region changed since
the previous pass (W or anything above it moved, appeared, vanished, resized), W gets no poke this pass: that damage is
reveal/occlusion, not W's change. Pokes on WGC slots remain liveness hints; on PW slots (o-r popups) they are the
render trigger. A poke unanswered for 2 s (R3) or a first frame missing (R2): the broker recreates the WGC session
once (today's first rung, `g_wgcReopened`, B:1334); if the new session is also deaf, the slot goes `WGCBRK_FAILED`
with a new `FailHr = WGCBRK_E_DEAF`, the agent holds last content and logs `QGAWGCDEAF` once (ERROR) + a harness flag.
The `g_forcePw` rung (B:1335) and `printwindow-route` remedy are gone on 26100+ (c2: 0.05).
**AMENDED 2026-10-01 (ADR-capture §19, measured):** "recreate once, then deaf" froze a healthy Notepad when its system
menu poked it after its one recreate was spent at startup. As built: a session that has delivered is recreated on
every unanswered-poke episode (loud, QGAWGCRECREATE); DEAF only when a fresh session delivers nothing at all; and for a
WGC slot's poke every window above counts as an occluder (a popup with a 24 px shadow margin). Jev: both 0.64.
**Why.** The 2026-09-30 field demotion of a healthy session came from reveal damage (jevC state); the ladder's last
rungs are the timed PrintWindow route (§C). **Cost.** A deaf session on a window that receives no own-change damage
and no input is not seen until it does (c1 accepts this: 0.92 over wgc-events-only 0.03). **Bound.** False
positives measurable as QuietReroutes on the Calculator-over-Store and reveal scenes (M7): must be 0.

### F. Registration failure and WGC refusal hold loudly — c5 hold-loudly 0.41 (provisional, see section 4), c3 OPEN
**Decision.** `BrokerRegister`'s silent FALSE (M:3638 no slot, M:3659 arena; ignored by P:716) becomes
`QGABROKERREGFAIL` (ERROR: hwnd, class, WxH, reason, slots used, arena used) + a published counter; the window stays
withheld (MapDeferred, released by its first painted frame) and `PwDirectSince` is set at registration for every
attached window (today only on the synth path, M:6601-6602, so `QGADIRECTSUPPRESS` M:7036-7054 is unreachable for
them): the 10 s grace becomes a request-deadline of the registration and the declaration fires. Retry is event
driven: on every `BrokerUnregister` (M:3812-3829) the agent re-registers the oldest withheld window. A WGC refusal at
open for a WGC-only class keeps its HRESULT (`WgcOpenHr`; today zeroed at B:1085), never falls to the PrintWindow
route, and holds loudly (`QGAWGCREFUSED`: hwnd, class, exstyle, hr). Whether a retry on a style/enabled change is
added is c3's probe. **Why.** R4; a withheld window with a loud line beats a composite or a timed render. **Cost.** A
window nobody can see until capacity or c3's answer. **Bound.** Zero silent holds: every held window has a line.

### G. The relay rung is skipped where its destination cannot open — c6 skip-where-it-cannot-open 0.81
**Decision.** At broker start (with the other capabilities, B:1373-1413) the broker creates one destination-shaped
window (`RelayOpenDest` styles, B:321) and tries `CreateForWindow` on it once; `RelayCapable` (H, B:1433) publishes
the RESULT, not the build. On 26100.1742 (E_INVALIDARG for that shape) the ladder is WGC -> fresh WGC -> loud hold; on
26200 the relay keeps its single re-open rung before the loud hold. `DwmQueryThumbnailSourceSize` per pass
(B:1218-1233) becomes `EVENT_OBJECT_LOCATIONCHANGE` on the source. **Why.** Today every ladder descent on the target
build pays a failing relay open (B:1083-1105). **Cost.** None on 26100.1742. **Bound.** RelayFail == 0 there.

### H. Menus stay synthesized, from the menu's own frame only — d3 keep-synthesis-own-frame-only 0.89
**Decision.** The synth child's pixels come only from its own broker frame (M:7803-7817); the composite arm
(M:7818-7825) is already gated `!DirectRequired()` and stays so for builds below. The patch is driven by the child's
FrameId + dirty regions on the broker event (today FrameId is ignored, M:7803-7804) and re-applied after any owner
copy that intersects the child; the per-desktop-frame re-patch and the 200 ms full re-patch (M:9871-9890,
`SYNTH_FULL_PATCH_MS` M:1920) are removed. The owner's WGC-frame copy skips the masked child rects (the engine's mask,
W:288-346, moves to the slab copy M:7585-7627). Until the child's first frame the owner shows through (the hold).
**Why.** R2 + owner decision 2026-08-16. **Cost.** A menu's first paint waits for its own frame (measured 109 ms
first content with one registration, main.h:302-306). **Bound.** Full-rect owner damage per 200 ms with a menu
open: 0.

### I. Below 26100 and the opt-out: unchanged — d6 unused-on-26100-kept-below 0.86, d7 owner-decision (OPEN)
The engine, its sweep, its echo guard, the composite slices and the 1 s loop cap stay exactly as they are where
`DirectRequired()` is false - no exception (Jev 2026-10-01 on the earlier draft, which let the engine wait without a
timeout at zero channels on every build: accept 0.48 / reject 0.25). The engine-at-zero-channels change applies only
where `DirectRequired()` holds; below 26100 is the owner's decision (d7).

## 2. Stages

Order change: an **S0** (instruments only) precedes S1, because the evidence rule requires every instrument to be
shown stable on one unchanged binary over >= 3 runs and seen to FAIL with the defect present before any verdict —
the candidate is that binary. S1-S5 follow the suggested order; S2 additionally needs c4's probe result (run during
S1) so the capacity constants it ships are measured, not guessed. Each stage is one commit series, Jev-reviewed
before commit, with its own acceptance cell.

### S0 — instruments, no product change
- `tools/restwatch.ps1` (new): per-thread context switches of gui-agent.exe, wgcbroker.exe, notifhost.exe,
  etwproxy.exe from the RAW `Win32_PerfRawData_PerfProc_Thread` counter (cumulative, exact), joined to thread roles
  by a `QGATHREAD <role> tid=` line each long-lived thread logs at start (agent: capture C:1370, engine W:404, hook
  M:983, toastcrop, main; broker: main, teardown; `SetThreadDescription` as well). 60 s window, 3 runs.
- Counters that must read 0 at rest, exposed through `guest/wgcbroker-peek.ps1` and one agent stats line:
  PrintWindow calls (engine W:225-402 + broker B:799 + B:585), composite copies (`QGACOMPOSITECOPY` at M:9280-9311,
  M:9800-9829, M:7715-7757, M:7818-7825), `SafetyPolls`, `QuietReroutes`, `RelayFail`, pokes per slot.
- `tools/wgcprobe` gains: `--target <hwnd|fixture>` creating fixture windows with WS_EX_TOOLWINDOW /
  WS_EX_NOACTIVATE / disabled (c3), `--dirty` printing DirtyRegions per arrival, `--arrivals` counting arrivals/s on a
  named window at rest (caret, progress bar) (open question: facts-broker OQ2), `--acquire-infinite` (b1 stop path).
- Typing/scroll latency join (`QGAPROTO` KEY/BUTTON receive tick -> first damage send for the focused window) and a
  fault-injection knob that delays the damage send by 50 ms so the instrument is seen to fail (`faultinject.c`).
- `frame-age.py` and the census's `brokerHB - captick` age lose their clock when heartbeats go: switch both to the
  peek script's own `GetTickCount64` at read time, and prove the switched instrument on the candidate first.
**At rest after S0:** unchanged (candidate). **Risk:** none to the product; the risk is an instrument that cannot
fail — each is run against the candidate and must show the known defect (M1 > 0, M3 > 0, M4 > 0, M6 > 250 ms).

### S1 — broker-event frame copy, dirty regions, persistent staging (ABI 19)
- H: `WGCBRK_ABI_VERSION` 19. Slot: `DirtyCount`, `Dirty[8]` (RectInt32, card-relative), `DirtyFull`; agent-written
  `ConsumedFrameId`; `WgcOpenHr`; `ReqRoute` (WGC_ONLY | PW_BY_RULE, used from S2/S3); header `CapFlags`
  (DirtyRegions present, border-off honoured, relay probe result) and `AgentHungSuspect`. `WGCBRK_MAX_SLOTS` becomes the
  compile-time maximum (256) and the header's `SlotCount` the value the agent created — one bump covers c4's outcome.
- B OpenChannel: `session.DirtyRegionMode(ReportAndRender)` after B:955; latch
  `ApiInformation::IsPropertyPresent(GraphicsCaptureSession, DirtyRegionMode)` at start next to B:1373-1413, publish
  in `CapFlags`; absent on an eligible build = ERROR line + harness FAIL, frames stay whole-card (`DirtyFull`=1).
  `IsBorderRequired(false)` failure (B:958, swallowed today) is published the same way.
- B FrameArrived/PublishFrame (B:977-1054, B:466-492): one persistent staging texture per channel, recreated on
  size change (today allocated per arrival, B:480-483); per arrival copy `dirty(N) ∪ pendingOther` into the spare
  ring buffer (the spare holds N-1, so N-1's regions must be applied too), then `pendingOther = dirty(N)`; publish
  the union of regions since `ConsumedFrameId` (merge to a bounding box past 8 rects; `DirtyFull` on the first frame
  after open, on Recreate and on overflow). Seqlock unchanged (B:444-458).
- M: extract M:9087-9243 into `BrokerConsumeWindow(entry)`; `BrokerFreshFrame` (M:3851-3920) also reads the dirty
  list under the seqlock; `PwSliceCopyAndDamageSrc` (M:7585-7627) takes a rect list and damages only rows whose
  memcmp against the slab differs; write `ConsumedFrameId`. New `BrokerConsumePass()` runs in the `g_WgcFrame`
  handler (M:10819-10833): under `g_csWatchedWindows`, every broker-sourced window with FrameId != PwBrokerLastId,
  skipped while `g_OnSecureDesktop` (mirrors M:8718-8776); then the existing MapDeferred poke (M:9241-9242). The
  frame walk keeps calling the same function.
**At rest after S1:** unchanged wake inventory (timers still present); a covered slice-fed window's change now
reaches dom0 without a desktop frame (M6 passes for NRB/toast classes). **Risk:** dirty regions over- or
under-reported by WGC on 26100.1742 (the row compare guards over-report; under-report is caught by M6's pixel check
against the fixture); the ring's two-frame bookkeeping (a fault-injection test writes a known pattern and checks
both buffers converge).

### S2 — ordinary windows through the broker; the desktop never copied on 26100+; loud registration failure
- P `PwAttachWindowCarry` (P:501-745): `sliceFed = DirectRequired() || !PwWindowEligible(entry)`; no `WcAddWindow`
  (P:544-560), no synchronous `WcPrefill` (P:606-611) and no first `WcMarkDirty` (P:734-735) for broker-fed windows;
  `BrokerRegister` (P:703-716) result checked; `ReqRoute = WGC_ONLY` for PWC_ELIGIBLE/NRB/ULW/COLORKEY, `PW_BY_RULE`
  for PWC_OR (saves the failing CreateForWindow per menu, B:1096-1101). `PwResizeWindow` (P:828-869) keeps
  `BrokerCanKeepSlot`/`BrokerRetarget` (M:3690-3710, M:3777-3810).
- M `BrokerRegister` (M:3621-3690): `QGABROKERREGFAIL` at M:3638/M:3659 with counts; `PwDirectSince = now` for every
  registration; event-driven retry in `BrokerUnregister` (M:3812-3829). Capacity per c4's probe: `SlotCount` from
  the measured census; arena either SEC_RESERVE + per-allocation commit (if the probe shows committed pages visible in
  the broker's view) or a larger SEC_COMMIT arena (M:2578-2603); the arena reap moves to R4's ack (M:3590-3612).
- C `StagingCopyFrame` (C:1072-1138) and the `StagingEnsure` grant/ungranted branches (C:706-822): in seamless on a
  DirectRequired guest no staging copy is made and `PwInvalidateFramebuffer()` keeps `g_FbBits` NULL; dirty rects
  still reach `ProcessNewFrame`. Non-seamless entry (M:5843-5875) re-enables the copy for window 0.
- M: DDA branch M:9757-9835 and `PwScreenUnchanged` M:9837-9867 gated `!DirectRequired()` (unreachable anyway with a
  NULL source and zero engine channels); `QGADIRECTLEGACY` (M:4544-4553) becomes a withhold, never the window-0 path.
- B OpenChannel (B:1071-1105): a WGC_ONLY refusal keeps `WgcOpenHr`, sets FAILED, no PW fallback; agent logs
  `QGAWGCREFUSED` and holds (F).
**At rest after S2:** ordinary windows produce no PrintWindow and no composite copy (M3, M4 = 0 for them); the
engine has zero channels; the timed wakes of C remain (this stage proves R2, not R1). **Risk:** a3 latency
regression on the foreground window (measured in this stage, M5, against the S0 baseline); a WGC arrival storm from
a self-animating window (caret, marquee) — measured (M-arrivals), bounded by dirty regions; capacity exhaustion on the
acceptance desktop if c4's probe was skipped (the loud line makes it visible, the retry keeps it from being permanent).

### S3 — own-change pokes, recreate-then-loud, relay skipped where it cannot open, PW backstop removed
- M damage poke (M:9005-9086): keep per-window `PwVisibleRgnPrev` from the same `CollectZOrder` pass (M:7440-7559);
  poke iff damage ∩ (visible_now ∩ visible_prev, inset 2 px) ≠ ∅ and visible_now == visible_prev (E). Input pokes
  (V:367, V:444, V:764) unchanged. `PokeLockMiss` stays a loud counter.
- B Reconcile (B:1235-1347): the quiet test keys on R2/R3 deadlines; rung 1 = one fresh WGC session (B:1334); rung 2
  = `WGCBRK_E_DEAF`, FAILED, no `g_forcePw` (B:1335) on WGC_ONLY slots; relay rungs (B:1339-1341) only when the
  start-time probe (G) succeeded; `RelaySrcDecides` (B:555-609) unchanged where the relay exists.
- B PW service (B:1505-1609): `stale`/backstop (B:1532-1533, B:1581-1607) and `pwFutile`/`pokeIv` (B:1546-1547)
  removed; a PW slot renders on open and on pokes only; `SafetyPolls` kept as a counter that must read 0.
- M: `QGAWGCDEAF` on FAILED+E_DEAF, hold; `QGAWGCREFUSED` with hr; the deadlines of D armed at registration (R1, R2)
  and at poke (R3), disarmed on AckState/FrameId change.
**At rest after S3:** no PrintWindow anywhere on 26100+ (menus render on pokes only); the timed loops still tick
(B:1462 250 ms, C:36 1 s, W 250 ms, M 1 s) but do nothing. **Risk:** a menu whose content changes without desktop
damage or input (the "HONEST CAVEAT" M:9027-9032) stays stale — o-r popups are topmost so their content IS desktop
damage; verified by M7's menu scene; reveal exclusion delays a legitimate poke by one pass (liveness only).

### S4 — zero-wakeup waits, request deadlines instead of heartbeats, helpers by handles and signals
- C: `GetFrame(capture, parkedDeadline ? remaining : INFINITE)` (C:1405, C:36); `StaleGrantSweep` on the releasing
  events (dump ack V:1612-1649, destroy) and on the parked deadline only (C:385-421). `CaptureStop` (C:1045-1058): NO kick window
  and no TerminateThread (Jev 2026-10-01: reject 0.66). Every caller of CaptureStop is enumerated and each must be
  shown to coincide with an event that already unblocks the acquire (mode/resolution change and secure-desktop switch
  return DXGI_ERROR_ACCESS_LOST) or with process exit (no wait needed); probe M9(a) proves it per caller. A caller
  that has no such event is put to Jev with the measurement before any mechanism is designed for it.
- W: `waitMs = INFINITE` when nothing is dirty and no sweep is due, only where `DirectRequired()` (W:563-576;
  below 26100 unchanged);
  quit signals `e.wake[id]` instead of relying on the bounded wait.
- M main loop (M:10590-10660): delete the 1 s cap; timeout = min(pending deadlines: capture-degraded retry,
  capture gate M:10624-10636, first-client M:10729-10760, daemon settle M:10638-10643, per-window map ceiling once,
  R1-R4 deadlines, broker/bridge relaunch throttles while down) else INFINITE. `MapDeferWakeSweep` (M:4013-4066): one
  ceiling deadline per held window, no 32/100 ms re-arm; release comes from `BrokerConsumePass` (S1) and window events.
  `BrokerSupervise` (M:2760-2987): no heartbeat write (M:2768), no 1 Hz body; exit by handle (M:2775-2783), session
  change by the watchdog-relayed session event (a named event set from watchdog.c:636-650 and by the hook thread on the
  shell window's `EVENT_OBJECT_CREATE`), ready by a `BrokerReady` event the broker sets after B:1441; the reap on
  R4's ack; relaunch (M:2945) and down-warnings (M:2899-2900) as failure-state deadlines. `NotifBridgeSupervise`
  (M:3264-3443): pid published once by the bridge + a ready event, validated handle in the wait array, no 5 s file
  read; `EtwProxyPoke` (etwproxy.c:1024-1055): launch and SID re-check on the session event only; the exit-wait
  (etwproxy.c:861-876) and the backoff timer (etwproxy.c:398-406, failure state) stay. QGACAPDEAD (M:11385): the
  capture thread's HANDLE joins the wait array (signalled on any exit). QGAFSSTALL 3 s: a deadline armed by the
  fullscreen repaint request; the 10 s QGACAPSTAT/QGAINPUT timeout logs are retired (diagnostics of a wake that no
  longer exists).
- B main loop (B:1446-1478): exit checks by handle/AgentPid/Shutdown only (B:1454 removed); `Producing` from a
  `SetWinEventHook(EVENT_SYSTEM_DESKTOPSWITCH)` on the pumped main thread (B:1456 removed, live check kept at
  B:390-399/B:768); `WTSRegisterSessionNotification` on a message-only window (B:1450 removed); `BrokerHeartbeat`
  write removed (B:1457; `BrokerStage` stays, it is written around calls); timeout = earliest pending deadline (R2,
  R3, R5, relay settle) else INFINITE; `FlushPendingSignatures` (B:732-758) signs lazily on the next wake or on an agent
  request, no 500 ms tail; the message pump stays (hook callbacks, WTS messages).
- notifhost.cpp:31: the 2 s heartbeat loop becomes a wait on its listener/stop events.
**At rest after S4:** agent — capture thread blocked in DXGI, main loop INFINITE on {shutdown, frame, fullscreen
on/off, vchan, capture error, window events, g_WgcFrame, broker/bridge/capture-thread handles, BrokerReady,
session event}, engine INFINITE (0 channels), hook thread INFINITE (M:1058), toastcrop INFINITE, watchdog INFINITE
(watchdog.c:281); broker — main loop INFINITE on {ctl, agent handle, messages}, no PW slot ticking, pool threads idle.
Residual wakes: none of ours; DWM presents only for guest pixel changes. **Risk:** lost wakeups (mitigated per C:
write-before-signal, re-check-before-wait, M8's signal-before-wait injections on every converted wait); a hang at rest
is invisible until the next request (accepted by b4).

### S5 — menus from their own frame only
- M `PwPatchSynthChildClipped` (M:7765-7915): patch on the child's FrameId/dirty regions from `BrokerConsumePass`
  (M:7803-7804 no longer ignores `cid`); re-patch after an owner copy intersecting the child; remove M:9871-9890 and
  `SYNTH_FULL_PATCH_MS` (M:1920) on DirectRequired guests; `SynthActivate` (M:2343-2374) keeps mask-first, paint-then.
- M `PwSliceCopyAndDamageSrc`: mask rects (from `SynthUpdateMask`, M:2290-2339) excluded from the owner's copy as
  row segments (pattern W:288-346). Child registration stays on the tracking pass (M:6566-6605).
**At rest after S5:** a static desktop with an open menu produces no owner damage and no copy (H's bound).
**Risk:** a menu that repaints its hover highlight produces child arrivals (guest activity, correct); a child frame
that never arrives leaves the owner showing through — loud via R2's deadline (`QGAWGCDEAF`/`QGAWGCREFUSED`).

## 3. Measurement plan
Every instrument is first run on the candidate (301cf6f + the rest-zero broker) and must FAIL there; then stable on
one unchanged binary over >= 3 runs; comparisons >= 3 per side, interleaved, binary hash vs manifest per run
(`tools/bench-stock-vs-ours.sh` rules); missing data FAILS. Semantic verdicts (which class a log line is, whether a
scene is at rest) go to `tools/jev.py`; counting and joins stay in code. Scene for M1-M4: win11-qwt (26100.1742),
two overlapping unfocused Notepads, Explorer, Settings, one dialog, one open menu, nobody touching the desktop, 60 s.
- **M1 wakeups** (`tools/restwatch.ps1`): context switches per named thread of gui-agent/wgcbroker/notifhost/etwproxy
  over 60 s. Candidate: >= 60 capture, >= 240 engine, >= 60 main, >= 240 broker (FAIL by construction). Target after
  S4: 0 on every thread, 3/3 runs. Also run once with the broker HUNG (fault injection): still 0 at rest.
- **M2 CPU vs the agent-stopped floor** (`guest/phase-cpu-bench.ps1` family-v2 + `tools/bench-phase-cpu.py`, rest
  phase): candidate > 0 (the sweep's PrintWindows and the Notepad echo burn, ADR §8/§14). Target: family CPU delta <= 2 scheduler quanta (31 ms)
  over 60 s and DWM within noise of the floor; the floor measured 3x interleaved with the design build.
- **M3 PrintWindow at rest** (S0 counters): candidate > 0 (engine sweep per channel <= 2 s, broker backstop 1 s on a
  PW slot). Target: 0 engine, 0 broker, `SafetyPolls` 0, over 60 s x 3.
- **M4 composite copies on 26100+** (`QGACOMPOSITECOPY`, driven scene: type into an unoccluded Notepad, open a menu,
  drag a window): candidate > 0 (DDA-mode copies M:9800-9829). Target after S2: 0, and `g_FbBits == NULL` asserted in
  the stats line for the whole run.
- **M5 typing latency** (S0 join, maximized Notepad, 200 keystrokes per run, p50/p90 KEY receive -> first damage
  send for that hwnd; dom0-side cross-check with `tools/frame-age.py` re-clocked): candidate vs S2 build, 3 runs per
  side interleaved; the instrument validated by the 50 ms injection. Bar: proposed p50 not worse than the candidate
  by more than 10 ms (owner to confirm, a3). Same for scroll (wheel -> damage) and scroll CPU via
  `tools/bench-stock-vs-ours.sh`'s scroll phase.
- **M6 covered-window update latency**: a fixture window advancing a counter every second while covered in the GUEST
  by `SetWindowPos` of another (dom0 stacking follows focus only, so dom0 still shows it); latency = fixture paint tick
  -> agent damage send tick for that hwnd, and the per-window `qtest shot` must show the new value. Candidate: 2-4 s
  (sweep + backoff) -> FAIL at a 250 ms bar. Target after S1+S2: p90 < 100 ms.
- **M7 deafness false positives** (`QuietReroutes`, pokes per slot): Calculator over Store + typing into
  Calculator; a window dragged off another (reveal); a menu opened over a window. Candidate: pokes on the revealed
  window (FAIL). Target: 0 pokes on covered/revealed windows, 0 reroutes; and a fault-injected deaf session (the
  broker drops arrivals for one slot) is recreated once and then logged `QGAWGCDEAF` within R2/R3's deadline.
- **M8 hang detection and lost wakeups** (`faultinject.c` pattern, test builds): broker stuck in Reconcile -> next
  registration logs QGABROKERHUNG within 2 s and the broker is relaunched; agent stuck -> broker flags
  `AgentHungSuspect` within 5 s of its next publish; with the deadline code disabled the same hang is silent (seen to
  fail). For every converted wait: signal-before-wait injection must not lose the event (the work is observed done).
- **M9 the S0 probes** (section 4) with pass/fail: (a) `AcquireNextFrame(INFINITE)` returns 0 times in 60 s on a
  static desktop with our agent stopped, and for every CaptureStop caller the acquire is released by that caller's own event
  (ACCESS_LOST on mode change / secure desktop) or the caller is process exit; (b) arrivals/s at rest on a focused Notepad
  (caret), a progress bar, Settings; bytes copied per arrival with dirty regions <= the caret/bar rect.
- **Ledger checks** at every stage: the wire log carries every Jev call; `QGADIRECTWAIT`/`QGADIRECTSUPPRESS` lines
  are counted and each has a matching cause line (`QGABROKERREGFAIL`, `QGAWGCREFUSED`, `QGAWGCDEAF`, `QGADESLICEDOWN`).

## 4. Open items and the probe that settles each
- **c3 — a window WGC refuses at open (hold-loudly 0.49 vs retry-on-state-change 0.40).** Probe (S0, `wgcprobe
  --target`): on 26100.1742 and 26200, `CreateForWindow` on a Win32 fixture that is (i) WS_EX_TOOLWINDOW, (ii)
  WS_EX_NOACTIVATE, (iii) disabled (`EnableWindow(FALSE)`), (iv) a session opened while enabled then disabled — record
  hr per case and whether (iv) keeps delivering. If nothing ordinary is refused as a TARGET, c3 is moot and S2's
  hold-loudly stands; if refusals exist and flip with state, retry-on-state-change is added to S3 (a WinEvent-driven
  retry, no timer); if refusals are static, hold-loudly stands and the class is documented. Also census the owner's
  real apps with `tools/winenum.cs` for those styles to know how many windows the answer touches.
- **c4 — capacity (insufficient-evidence 0.55).** Probe (during S1): (i) `winenum` census on the acceptance
  desktops and the owner's session: peak count of ordinary + slice-fed + synth-child windows and their WxH -> slots and
  arena bytes needed at 256 KiB classes (two buffers each); (ii) a two-process test: agent-side
  `CreateFileMapping(SEC_RESERVE)` + `VirtualAlloc(MEM_COMMIT)` per region, broker-side write/read of that region —
  pass = the broker's view sees and can write the committed pages and the commit charge grows per allocation only;
  (iii) broker-side memory per WGC slot at 1920x1080 and 5120x1440 after S1's persistent staging texture, and the
  single WARP context's cost per arrival with 8 and 16 sessions. Result -> `SlotCount` and the arena policy S2 ships
  (grow-reserve-commit-on-demand if (ii) passes, else grow-committed), and c5's confidence (the frequency of
  `QGABROKERREGFAIL` on the census desktops).
- **a3 — foreground typing/scroll latency (measure-first 0.44).** M5 is the probe: candidate (desktop copy for the
  unoccluded foreground window, ADR §2) vs S2 (WGC arrival + broker copy + agent dirty copy), 3 interleaved runs per
  side, p50/p90 for key -> damage and wheel -> damage, plus scroll CPU. No mitigation is designed until the numbers
  exist; if the bar is missed, the candidates are dirty-region tightening (already in S1) and `MinUpdateInterval` as
  a rate cap while frames flow (never a timer at rest), each put to Jev with the measurement.
- **d7 — builds below 26100 (owner-decision 0.60).** Question for the owner, with the facts: below 26100 there is no
  broker; ordinary windows use the engine with its 250 ms sweep and echo guard, and slice-fed classes the composite;
  Windows 11 below 26100 storms without the guard (Win11 Notepad). Options: (a) unchanged (this design's default);
  (b) unchanged pixel sources plus the free event waits (engine INFINITE at zero channels, the 1 s cap only while the
  bridge gate is on). Until answered, everything here is gated on `DirectRequired()` and (a) holds.
