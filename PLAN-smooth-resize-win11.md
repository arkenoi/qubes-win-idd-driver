# PLAN — smooth window-resize-follows-dom0 on a Windows 11 guest (Win11 ONLY)

Written 2026-08-05. Planning only — no VM was touched and no code written for this document.
Target guest: Windows 11 23H2/24H2+ (assume 24H2 = build 26100, IddCx 1.10 build 0x1A80
"GERMANIUM", WDDM 3.2; 25H2 = IddCx 1.11 "SELENIUM", feature-gated). This plan supersedes
nothing: `PLAN-trackb-t2-modes.md` remains the Win10 plan; this is the Win11 delta plan.

Inputs: FINDINGS.md 2026-08-04/05 (Outcome A, D2 negative, D3 negative, D4 v1 working,
A6/A7/ackrepaint stress-passed, livelock trapped), `PLAN-trackb-t2-modes.md` §1.6/§5,
`docs/RESEARCH-hypervisor-resize.md`, `BOOTSTRAP-win11.md` (the Win11 24H2 test VM exists),
and two web-research passes done for this plan (2026-08-05): one over Microsoft's IddCx
1.8–1.11 documentation and the shipped headers, one over community/field evidence. Sources
are cited inline; every claim is labeled **[FACT]** (Microsoft docs/headers or our own
measurement), **[EVIDENCE]** (community source code / issue reports, unconfirmed by MS),
or **[SPECULATION]**.

## HARD USER RULES (restated; every mechanism below must satisfy them)

1. **Never resize-to-viewport.** The dom0 window is the single source of truth. The guest
   never imposes a size back on dom0. The driver publishes only sizes the agent was told
   by dom0; the agent applies only dom0-requested geometry.
2. **The published mode list tracks the current dom0 window / work area.** Host-screen-size
   modes are not offered unless the dom0 window is actually fullscreen. No dense
   "autofit anything" grid parked in the mode list.
3. **No chaotic jumps during drags.** Ideal is per-frame smooth follow (VirtualBox/QXL
   custom-slot mutation). §3 assesses honestly how close Win11 console IddCx can get,
   including the expected blackout per resize while replug remains required.

---

## 1. RESEARCH VERDICT — what Win11 actually permits a console IDD to do

### 1.1 The mode-update DDI surface, per version

**[FACT]** IddCx per build (learn.microsoft.com/…/display/iddcx-versions): Win10
19041–19045 = **1.5**; Win11 21H2 = 1.8 (WDDM 3.0); 22H2 = 1.9 (WDDM 3.1); 22H2
Sept-update & 23H2 = **1.10** (0x1A00); **24H2 = 1.10 (0x1A80 GERMANIUM, WDDM 3.2)**;
1.11 = 0x1B00 SELENIUM (≈25H2-era), explicitly feature-gated — "multiple OS versions can
report support for IddCx 1.11 … but possibly only some of the features will be available";
a 1.11 driver must call `IddCxCheckOsFeatureSupport` before `IddCxAdapterInitAsync`.

**[FACT]** `IddCxMonitorUpdateModes2` (1.10) is the HDR-capable variant of
`IddCxMonitorUpdateModes` and nothing more. `IDARG_IN_UPDATEMODES2` = `{Reason,
TargetModeCount, pTargetModes}` — **target modes only, no monitor modes**, same as v1.
The documented semantic is one sentence: the OS "update[s] the mode list previously
reported for a monitor." Nothing says the OS re-intersects, re-queries monitor modes, or
applies anything. `IDDCX_UPDATE_REASON` values (POWER_CONSTRAINTS, HOST_LINK_BANDWIDTH,
DISPLAY_LINK_BANDWIDTH, CONFIGURATION_CONSTRAINTS, OTHER) are advisory; none triggers an
apply. If the driver reports `IDDCX_ADAPTER_FLAGS_CAN_PROCESS_FP16` it must use v2; else
v1. No console/remote restriction is documented on UpdateModes(2) itself.

**[FACT]** The **apply half is remote-only, both versions**.
`IddCxAdapterDisplayConfigUpdate` — "A remote driver can call…";
`IddCxAdapterDisplayConfigUpdate2` (1.10) — "**Only remote drivers are able to call this
function.**" The documented runtime-resize flow ("Scenario 4", now on the *IddCx 1.4
Updates for Remote IDDs* page, which opens "apply to remote indirect display drivers
only") is exactly `IddCxMonitorUpdateModes(new list)` **+** `IddCxDisplayConfigUpdate()`
— publish, then apply. A console driver gets the first verb only. In remote sessions the
docs additionally note `ChangeDisplaySettings` "returns success for application
compatibility reasons, but ignores the call" — the whole runtime-resize machinery is an
RDP-session code path.

**[FACT]** The flag Microsoft describes as "for example, based on a client window size
rather than a monitor size" — our use case verbatim — is
`IDDCX_ADAPTER_FLAGS_REMOTE_ALL_TARGET_MODES_MONITOR_COMPATIBLE` (0x80, IddCx 1.10).
The doc prose sometimes drops the `REMOTE_` prefix ("IDDCX_ADAPTER_FLAGS_ALL_TARGET_MODES
_MONITOR_COMPATIBLE"), but the header (verified in the real 1.10/1.11 iddcx.h via WDK
mirrors: KNSoft/WinSDK-Diff, microsoft/wdkmetadata) defines **one flag, one bit, with the
REMOTE prefix**, comment "It is only valid for remote drivers to set this flag"; docs:
"**Only remote drivers can set this flag.**" When set, the OS skips
`EvtIddCxParseMonitorDescription2` / `GetDefaultDescriptionModes` entirely and trusts the
target list. So it is *not* merely "described as" remote — header and docs both restrict
it. **[SPECULATION]** The enforcement point is not documented (unlike
`REMOTE_ALL_CURSOR_POSITION`, where `IddCxAdapterInitAsync` failure is explicit); expect
InitAsync rejection for a console driver, as it already rejects
`REMOTE_SESSION_DRIVER` on non-RDP devices. Nobody has published a bypass.

**[FACT]** Nothing in the 1.9 / 1.10 / 1.11 what's-new pages touches console mode-list
plumbing. 1.9 = realtime-GPU-priority + UMDF process-pooling ban; 1.10 = HDR10/SDR-WCG +
the remote-only flag above; 1.11 = feature query, D3D12 swapchains, atomic I2C,
DisplayID-only descriptors, runtime reencode-count. The *2 monitor callbacks
(`ParseMonitorDescription2` etc.) are HDR format extensions fired at the same points
(arrival/parse) — not a new re-query trigger.

**[FACT, header-only]** `IDDCX_VERSION_COBALT_UPDATEMODE_FIX 0x1801` exists in shipped
headers — an undocumented Win11-21H2 servicing revision literally named "update-mode
fix". Proves the UpdateModes plumbing was patched at least once; nothing says what it
fixed. **[SPECULATION]** Consistent with runtime mode update being an RDP-tested path
that gets little console coverage.

### 1.2 Field evidence — Win11 console behavior

- **[EVIDENCE, strongest]** Looking Glass LGIdd (`idd/LGIdd/CIndirectDeviceContext.cpp`,
  ~line 946), a console IDD compiled against IddCx 1.10 with UpdateModes2
  capability-checked, in-source: *"IddCxMonitorUpdateModes[2] does not invalidate
  Windows' cached mode list, so the only reliable way to apply a new mode is to depart
  and re-arrive the monitor."* They ship `ReplugMonitor()`.
- **[EVIDENCE]** Every examined shipping console virtual display resizes by
  replug/reconnect, none replug-free: parsec-vdd (registry modes read before connect;
  docs say re-plug to apply; also documents the Win10 unplug-latest-first registry
  quirk), virtual-display-rs (its "runtime mode change" IPC calls
  `IddCxMonitorDeparture`+re-arrival, never UpdateModes), MikeTheTech
  VirtualDrivers/Virtual-Display-Driver (XML mode list; no UpdateModes call sites),
  SudoVDA/Apollo (fresh monitor per streaming client, **stable per-client EDID serial**
  so Windows' own registry cache restores layout), ge9/roshkins IddSampleDriver forks
  (option.txt at start), spacedesk (vendor manual: disconnect-change-reconnect).
- **[EVIDENCE, the two "yes" datapoints — both weak]** (i) Windows-driver-samples#1184
  (UpdateModes' MonitorObject ignored; closed 2025 with no MS fix): OP comments the same
  call "can modify the display Settings" on Win11 but "still fails on win10"; a commenter
  claims builds >19044 work. No code shown, contradicts our own 19045 measurement (D3
  negative with valid control), scenario only partially comparable. (ii)
  VirtualDrivers#471: a console VDI IDD doing IOCTL-driven arbitrary runtime resolutions
  reports it "works correctly on Windows 10 and Windows 11 **23H2**".
- **[EVIDENCE, and it cuts against our target OS]** The same #471 reports **24H2/25H2
  broke it**: after a dynamic mode update, `ChangeDisplaySettingsEx` to the new mode
  always fails — "Active signal mode" changes but "Desktop mode" sticks at the old
  resolution — until a *manual* refresh-rate poke in Settings snaps it in. Open,
  unanswered. So the best-attested console runtime-update flow **regressed on exactly
  the build we target**.
- **[FACT]** MS Q&A 5924412 (console IDD, dynamic resolution; monitor blinks black on
  UpdateModes, mode never appears; hotplug pollutes the registry until "random
  resolutions") remains unanswered by Microsoft. OSR community has no thread on console
  UpdateModes at all.
- **[EVIDENCE]** Win11 replug arrival latency is real and variable: Apollo issues
  #1531/#1532 show arrival→active-in-CCD-topology exceeding their polling deadline on
  some systems. Budget generous arrival deadlines.

### 1.3 Bottom line

**[FACT + EVIDENCE]** Windows 11, any current build, offers a console IDD **no
documented or community-proven way to make a runtime mode-list change applicable without
a monitor replug**. The publish verb exists (UpdateModes/2); the apply verb is remote-only;
the skip-monitor-modes flag is remote-only. Win11 24H2 additionally *regressed* the one
community flow that half-worked on 23H2. The mechanism of record for Win11 remains what
the Win10 work already proved: **stable-EDID monitor replug with the requested size
published at arrival, applied by the session-side agent.** One cheap spike (§6 W2) is
retained to settle the two weak counter-claims on our exact build, with driver-side
logging this time; its expected result is negative.

---

## 2. WHAT WIN11 UNIQUELY ENABLES vs THE WIN10 PLAN — and what it does not

Gains (each labeled):

| # | Item | Status | Value for this feature |
|---|---|---|---|
| G1 | `IDDCX_ADAPTER_FLAGS_PREFER_PRECISE_PRESENT_REGIONS` (1.8+) | [FACT] available ≥21H2, console-legal | Better dirty rects out of the swapchain if we ever feed frames from the IDD (Track B stage 3); irrelevant to the resize mechanism itself but free to set. |
| G2 | UpdateModes**2** + `IDDCX_TARGET_MODE2` | [FACT] | Only matters if we ever report FP16/HDR — we won't (BGRA8 pipeline). No resize gain. |
| G3 | IddCx 1.11 DisplayID-only descriptors (25H2) | [FACT, prerelease] | Alternative monitor identity; not needed — our EDID is driver-parsed so mode lists are unconstrained by EDID timing-field limits anyway. Do not target 1.11 (feature-gated, prerelease). |
| G4 | A second chance at the UpdateModes spike | [EVIDENCE, weak] | #1184-OP/"23H2 works" claims justify exactly one instrumented re-spike on 24H2 (W2). Expected negative (LGIdd comment + #471's 24H2 regression). |
| G5 | Win11 D2 re-probe (virtual-mode composition) | [SPECULATION] | DWM/composition changed across WDDM 3.x; D2 (OS serves arbitrary desktop sizes without a mode change) was NEGATIVE on Win10. Re-measuring costs ~0 on top of W1. Expected negative again. |

Non-gains, stated so nobody re-derives them:

- **No new apply verb for console.** §1.1. The Win10 plan's architecture (agent applies;
  driver publishes; replug is the refresh) is unchanged on Win11.
- **No smoothness primitive.** Nothing approaching VirtualBox's `pfnAddMode` or QXL's
  connect-only `IndicateChildStatus` re-assert surfaced in 1.8–1.11. IddCx still hides
  raw DXGK verbs.
- **New hazard instead:** the 24H2 half-apply regression (#471) means even our
  *arrival-published* modes must be re-validated on 24H2, and the apply step needs the
  `SDC_FORCE_MODE_ENUMERATION` fallback (§4.3) from day one.

---

## 3. SMOOTHNESS MODEL — how close Win11 gets to VirtualBox/QXL, honestly

The VirtualBox/QXL ideal (per-frame follow) = mutate a custom mode slot in place, no
replug, agent applies; latency ≈ one mode-set (~100–300 ms) or less, no monitor
departure. **[FACT]** That rests on DXGK facilities IddCx does not expose, on Win10 *and*
Win11 (§1). Therefore:

- **Per-frame follow: unreachable on console IddCx, any current Windows.** The only
  Microsoft-built path with that shape is the RDP remote-session driver model, and a
  remote driver cannot serve console monitors ("a console session driver cannot support
  remote session monitors" and vice versa) — [FACT].
- **Best reachable cadence: one mode change per settled gesture** (the debounced
  latest-wins commit the Win10 work already ships), with these Win11-specific numbers to
  be measured in W1:
  - Blackout per resize = monitor departure → arrival → agent apply → framebuffer
    re-grant → `MSG_WINDOW_DUMP` → dom0 remap. Win10 measured: **2–3 s dom0-follow
    latency per replugged resize** (FINDINGS 2026-08-05). Win11: unknown; Apollo
    evidence says arrival can be slower/variable — treat 2–3 s as the *floor* until
    measured, and set the arrival deadline ≥10 s with loud failure.
  - During the drag the guest desktop stays at the pre-drag size; dom0 shows the stale
    framebuffer cropped (shrink) or with undefined margin (grow) until commit. Same as
    Win10; Win11 changes nothing here.
- **The one real smoothing lever that exists inside the rules:** modes already published
  at arrival ARE applicable by `ChangeDisplaySettingsEx`/`SetDisplayConfig` without
  replug ([FACT] — our own D3 control proved arrival-published modes apply; that is how
  D4 works). So the *number of replugs per interaction* can be reduced by publishing, at
  each commit, a small **window-tracking mode set** (§4.2) — e.g. the settled size plus
  a few nearby steps bounded by the current work area. A follow-up adjustment that lands
  on an already-published size costs a mode-set (~sub-second blink, no departure)
  instead of a replug. This is a bounded, rule-2-compatible optimization **only if** the
  set is small, derived from the current window/work area, and never contains
  host-screen sizes while windowed. It is staged as W6b and needs explicit user sign-off
  on the exact set policy, because rule 2 draws the line the user owns.
- **Expected end state on Win11, plainly:** drag → free dom0 resize with stale content
  visible → on settle (≈1.2 s debounce), one replug or one mode-set → 1–3 s to live
  pixels at the exact size. Smooth per-frame follow does not happen. If the user wants
  closer-to-smooth than that, the honest engineering answers are outside the console
  IddCx model entirely (protocol/daemon-side scaling of the stale frame during the
  gap — a Phase 3 gui-daemon discussion, not a driver capability).

---

## 4. DRIVER MODE-LIST POLICY (Win11 build)

### 4.1 Identity — stable EDID, one monitor

- One monitor, stable EDID identity: fixed vendor/product/serial across every replug and
  boot **[FACT: Win10 D4 v1's per-replug identity churn reached `\\.\DISPLAY29` and is
  the exact "runaway registry / random resolutions" failure both MS Q&A 5924412 and the
  hypervisor survey warn about; EVIDENCE: SudoVDA ships stable serials for precisely
  this]**. D4v2 (stable EDID) is already in flight on Win10 with a known monitor-arrival
  regression; its fix is a prerequisite here (W0 dependency).
- EDID is identity only. Mode lists come from our `EvtIddCxParseMonitorDescription(2)`
  implementation, which is driver code and may return any modes regardless of EDID
  timing fields — so no 4095-px EDID-DTD ceiling applies. (Matters: dom0 host is
  5120x1440; a true-fullscreen mode can exceed EDID DTD limits.)

### 4.2 Published list = f(current dom0 window, work area) — rule 2 as code

At every arrival the driver publishes exactly, and only:

1. **The requested size** (from the agent via IOCTL/registry, originating from dom0
   `MSG_CONFIGURE` on window 0) — as the preferred mode.
2. **The last-applied size** (continuity: lets the agent step back without a replug if
   dom0 reverts within one gesture).
3. **One boot-fallback** (e.g. 1024x768) so a cold boot with no stored request is never
   modeless.
4. *(W6b, only with user sign-off)* a small tracking set around the requested size,
   bounded by the current work area, never including host-screen size while windowed.

Constraints on every entry (adopted from MS-RDPEDISP, already in the Win10 plan): width
even, both dimensions 200–8192, and ≤ current work area unless the agent has flagged
"dom0 window is fullscreen" — the *only* state in which a host-screen-size mode may
appear (rule 2). The fullscreen flag is set by the agent from dom0-provided state, never
inferred by the driver (rule 1: the driver has no opinion about sizes).

**Never**: dense static grids, host-size modes while windowed, guest-side size invention,
per-resolution EDIDs, monitor count >1 (protocol carries one rectangle — unchanged).

### 4.3 Apply path (agent-side, session 1)

`SetDisplayConfig(SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE)`
with a retry ladder, **plus `SDC_FORCE_MODE_ENUMERATION` on retry** — this is the QXL
stack's flag (survey §2) and is the programmatic equivalent of the "manual Settings poke"
that un-sticks #471's 24H2 half-apply. CDS_TEST first; readback via
`EnumDisplaySettings(ENUM_CURRENT_SETTINGS)` is the only success criterion (A2 readback
rule). The Win10 A-series agent behavior (A1 logging, A2 readback-authoritative, A3
single-source framebuffer size, A6 ack-gated grant lifecycle, A7 init-retry, ack-repaint)
carries over verbatim — none of it is OS-version-specific.

---

## 5. DRAG-TIME STATE MACHINE (agent-native; retires resize-sync.ps1)

States (per gesture; single-threaded, one in-flight commit max, serialized with a
minimum inter-replug interval as the livelock guard — the Win10 wedge family was
triggered by rapid topology churn and is not known fixed):

```
IDLE
  └─ MSG_CONFIGURE(w0) arrives → TRACKING
TRACKING   (dom0 owns the size; guest does nothing visible)
  - rolling debounce (current: 1200 ms, tunable), latest-wins
  - mid-drag requests only update the pending target; never applied (rule 3)
  - if pending target == current applied size → IDLE (no-op, logged)
  └─ debounce expires with stable target → COMMIT
COMMIT
  1. clamp/normalize target (even width, 200–8192, ≤ work area unless fullscreen flag)
  2. if target ∈ currently-published mode list → fast path: skip to step 5
  3. IOCTL driver: set mode list per §4.2 → driver replugs (departure+arrival)
  4. await arrival (deadline ≥10 s; on timeout: loud failure, re-arm, stay at old mode)
  5. CDS_TEST → SetDisplayConfig apply (§4.3, FORCE_MODE_ENUMERATION on retry)
  6. readback; mismatch → one retry cycle, then FAIL loudly (never silently snap — rule 1)
  7. capture path rides the change (A6): re-grant, re-dump, ack-repaint
  └─ readback == target → CONVERGE
CONVERGE
  - absorb the daemon's stale MSG_CONFIGURE echoes during the outage (measured real on
    Win10) and any dom0-WM adjustment; if a NEW stable size differs from applied →
    back to TRACKING (bounded: max N=3 loops per 10 s, then hold + log oscillation)
  └─ quiet for one debounce window → IDLE
```

Failure edges: arrival timeout (Win11-specific risk, Apollo evidence); 24H2 half-apply
(detected by readback, cured by FORCE_MODE_ENUMERATION retry; if that fails, the W1 gate
finding escalates to the user); agent crash mid-commit (A4 preference-vs-cache split must
be landed so a respawn re-applies the *pending dom0 target*, not the stale
`FullscreenWidth` cache — the exact amplification observed in the Win10 stress).

Fullscreen handling: dom0 signals fullscreen (window == host screen). Only then may the
published list contain the host-screen size; leaving fullscreen removes it at the next
commit (rule 2 both directions).

---

## 6. MILESTONES — ordered, with effort and feasibility

Effort in person-days (pd). CI-only build loop ≈ 20 min/iteration; estimates include the
historical 3–8 CI iterations per driver change and cold-boot-per-side measurement costs.
Feasibility: **proven** (demonstrated in this repo or by Microsoft docs), **likely**
(strong evidence, not yet demonstrated on Win11), **risky-unproven** (no public success;
evidence quality stated).

| # | Milestone | What/acceptance | Effort | Feasibility |
|---|---|---|---|---|
| W0 | **Preconditions.** D4v2 stable-EDID arrival regression fixed on Win10 (in flight); A4 preference/cache split landed; win11-idd-test state audit (QWT build, testsigning, IddCx version via `IddCxGetVersion` probe, netvm detached). | 2–3 pd (D4v2 is the unknown) | proven-path (all components exist) |
| W1 | **Win11 gating re-measurement.** D0/D4v2 driver on 24H2: install, single stable monitor arrives; ddaprobe 3× interleaved vs BDA control, cold boot per side: `DesktopImageInSystemMemory`, pitch==w*4 (incl. an 8-byte-aligned width), `agent_capture_would_work`, adapter-0 placement; replug cycle timing (departure→arrival→apply→readback); **the #471 check**: apply an arrival-published mode via CDS and via SDC, verify desktop mode (not just signal mode) switches; D2 re-probe piggybacked (CDS_TEST arbitrary sizes: expected BADMODE). Outcome A was scoped to 19045/WARP — it must be re-earned, not ported. | 3–4 pd | likely (WARP renderer argument transfers; [SPECULATION] until measured) |
| W2 | **UpdateModes2 spike on 24H2** (throwaway, driver-side logging this time so "API returned error" vs "OS ignored" is distinguished — the Win10 spike could not). Control: arrival-published mode applies. Expected negative per LGIdd + #471-regression; positive would delete the replug from the state machine and is worth the day. | 1–2 pd | risky-unproven ([EVIDENCE] 2 weak positives, 3 strong negatives) |
| W3 | **Agent-native resize path**: IOCTL client in the agent (replacing resize-sync.ps1's registry+devcon prototype), driver `EvtIddCxDeviceIoControl` + device interface (SYSTEM/Admin SDDL), driver-initiated replug. Acceptance: settled-sync E2E on Win11 equal to the Win10 demo (exact size, live pixels, readback match). | 3–5 pd | proven mechanism (Win10 E2E demonstrated), new plumbing |
| W4 | **State machine + rules enforcement** (§5): debounce/latest-wins in-agent, convergence loop, fullscreen flag, clamps, oscillation bound, loud-fail paths. Acceptance: scripted MSG_CONFIGURE streams (incl. mid-drag hesitations) produce ≤1 replug per gesture, zero mid-drag applies, zero guest-initiated sizes (log audit). | 2–3 pd | proven-path (Win10 debounced loop validated; moving it in-process) |
| W5 | **Stability gates on Win11**: the 16-cycle mixed stress (control: the Win10 A1-agent failure mode), 100-cycle soak, cold-boot acceptance, livelock trap re-armed (wedge-telemetry). Win11 numbers recorded: per-resize blackout distribution, arrival latency distribution. | 2–3 pd | proven harness; unknown OS behavior |
| W6 | **E2E with real dom0 drags**: needs the dom0 resize service (`dom0/10-install-resize-service.sh`, `qtest resize`) — **user install, still the standing blocker** — then D5-style acceptance: external-witness readback, pitch per size, fiducial pixel check, zero window-0 destroy/create, cold-boot persistence. | 1–2 pd + user action | proven criteria |
| W6b | *(optional, user sign-off on rule-2 interpretation)* **Tracking mode set** (§4.2 item 4): publish a small work-area-bounded neighborhood at each commit; measure how many follow-up adjustments become replug-free mode-sets and their blink duration vs full replug. | 1–2 pd | likely (arrival-published modes provably apply) |
| W7 | **Migration hygiene** (§7): Win11 agent issues that intersect T2 (work-area listener 0x5 → ceiling source), winenum baseline for the 25H2 double-windows predicate, seamless-mode regression pass on the Win11 guest with the T2 stack installed. | 2–3 pd | proven-path |

Total to a demonstrated Win11 E2E: **~16–25 pd**, dominated by W1/W3/W5 measurement
discipline (cold boots, interleaved controls), not code volume. Everything after W1 is
gated on W1's Outcome-A-on-Win11 verdict; if W1 returns FALSE on the flag, the B1
fallback (persistent staging texture in `capture.c`, ~150 lines, Win10 plan §2.4) slots
in before W3 at +2–3 pd — same driver plan, different capture read path.

---

## 7. MIGRATION STORY — this fork targets a Win10 guest today; what changes for Win11

- **The Win11 guest exists**: `win11-idd-test`, Win11 Enterprise Eval 24H2 26100.1742,
  offline, testsigning on, working deploy loop and dom0 policy (BOOTSTRAP-win11.md).
  Not a hypothetical. It currently belongs to the per-window/seamless session line —
  **coordinate before taking it for driver work**; driver install + BDA disable +
  replug churn is exactly the kind of VM mutation that must run serially with any other
  session's use.
- **Driver build**: same source tree, two build configs. Win10 ships IDDCX_VERSION
  targeting 1.5; the Win11 config compiles against the current WDK with 1.10 as the
  declared version. Do **not** target 1.11 (prerelease, feature-gated, requires
  `IddCxCheckOsFeatureSupport` plumbing for zero resize gain). CI: add a matrix leg;
  same ~20 min loop.
- **Capture verdict does not port**: Outcome A, pitch tightness, and the WARP-renderer
  hypothesis were measured on 19045. W1 re-earns them on 26100. Ditto every baseline
  number (the 19044→19045 re-baseline already showed a 2.6× acquire-latency shift
  between SKUs — Win11 will differ again).
- **Agent**: mechanics identical (the whole A-stack is OS-agnostic). Known Win11-specific
  agent defects that intersect this feature: `WorkAreaCreateListener` fails 0x5 on Win11
  (BOOTSTRAP #3) — the work-area machinery feeds the §4.2 ceiling, so this gets fixed in
  W7, with the A5 rule (no fabricated ceiling; return none when no source) enforced.
- **Seamless-mode artifacts are orthogonal but travel together**: T2 is a non-seamless
  feature, so the Win11 shell's `WS_EX_NOREDIRECTIONBITMAP` popup class and the **Win11
  25H2 "double windows" artifact** (CLAUDE.md 2A-chrome §3b) don't block it — but a
  Win11 guest qube will run seamless too, so the migration checklist includes: one
  `winenum` run on 25H2 while duplicates are visible to identify the distinguishing
  attribute, extend the acceptance predicate, and re-run the Win10 regression pass that
  BOOTSTRAP #5 records as outstanding. No 25H2 VM exists yet; that item waits for one
  (25H2 also moves to IddCx 1.11-era plumbing — re-run W1's gates when a 25H2 target
  appears, given 24H2 already demonstrated Microsoft will tighten mode validation in a
  point release).
- **Networking blocker unchanged** (GOAL-STATUS): a Win11 guest qube as a *product*
  still needs the xenvif issue resolved; out of scope here, listed so the plan doesn't
  imply otherwise.

---

## 8. WHAT REMAINS IMPOSSIBLE EVEN ON WIN11 — and why

1. **Per-frame smooth follow (the VirtualBox/QXL ideal).** Requires in-place mode-slot
   mutation + immediate applicability. IddCx exposes no `pfnAddMode`, no
   `IndicateChildStatus`, and its only console verb (`UpdateModes/2`) is publish-only
   with no documented apply semantics — [FACT], unchanged 1.5→1.11.
2. **Replug-free runtime mode application on console.** The apply half
   (`IddCxAdapterDisplayConfigUpdate/2`) is remote-only [FACT]; the
   skip-monitor-modes flag is remote-only [FACT]; the strongest field engineering
   (Looking Glass, on 1.10) concluded replug is "the only reliable way" [EVIDENCE];
   24H2 regressed the half-working community flow [EVIDENCE]. W2 is the paid-up
   falsification attempt; plan on it failing.
3. **Becoming a remote-session driver to get the good verbs.** A remote IDD cannot
   serve console-session monitors [FACT] — the RDP model is structurally a different
   session type, not a flag we can borrow.
4. **Zero-blink resize.** Replug = monitor departure + arrival; some black interval is
   intrinsic. The measurable goals are bounding it (W5 distributions) and minimizing
   occurrences (debounce; W6b fast path), not eliminating it.
5. **Multi-monitor.** Protocol carries one rectangle (`msg_xconf`/`MSG_CONFIGURE`);
   unchanged by guest OS. Driver stays at one monitor.
6. **Guest-driven sizing.** Forbidden by rule 1 regardless of capability.

---

## 9. USER GATES / OPEN QUESTIONS

1. **W6 dom0 resize service install** — standing blocker, needed before any real-drag
   acceptance (same as Win10 plan §6.3).
2. **W6b tracking-set policy** — rule 2 interpretation: is a small work-area-bounded
   neighborhood around the settled size acceptable in the published list? (Reduces
   replugs; slightly widens the offered set beyond the exact window size.)
3. **win11-idd-test custody** — shared with the seamless session line; serialize.
4. **If W1 fails Outcome A on Win11** — B1 staging-copy fallback gets built before W3;
   flag to the user at that point per the Win10 plan's escalation rule.
5. **25H2 target VM** — needed eventually for the double-windows predicate and the
   IddCx 1.11-era re-gate; not needed to start.
