# PLAN — smooth window-resize-follows-dom0 on Windows 10 19045 (IddCx 1.5, console)

Status: plan only, no code. Written 2026-08-05 against the measured state of that date.
Supersedes nothing; extends PLAN-trackb-t2-modes.md past D5 into "smooth". Every claim below
is either cited to a measured FINDINGS entry / source file or explicitly marked unmeasured.

---

## 0. Evidence base this plan stands on (all measured this week — do not re-derive)

| Fact | Where |
|---|---|
| Runtime `IddCxMonitorUpdateModes` does NOTHING on console 19045 — D3 spike negative WITH a valid control (arrival-published mode enumerable, runtime-published mode never) | FINDINGS 08-05 cont 2 |
| The working mechanism is registry-declared modes + monitor replug (D4 v1 driver, `HKLM\SOFTWARE\QubesIDD\Modes` read at monitor arrival) | FINDINGS 08-05 |
| Blackout ≈ 2–3 s from resize request to full dom0 convergence, per replugged resize | FINDINGS 08-05 cont (cycles 3/6) and cont 3 (every checkpoint) |
| `DesktopImageInSystemMemory` stays TRUE on the IDD, pitch TIGHT at 3440, 1400/1024, and 2566 (8-byte-aligned width) — the stride killer is dead on this config | FINDINGS 08-04 close (D0), 08-05 (2566) |
| Agent has exact-follow: src=dom0 requests are applied exactly or not at all (`RESEXACT` / `RESKEEP`), never snapped | agent `8bd39a9`, branch t2/exact-follow |
| A6 stack survives geometry changes in place (park + ack-gated revoke + ack-repaint), 16/16 stress, 100-cycle soak clean | agent 67561e0/7b73bf8/57205f8/177ac32; FINDINGS 08-05 cont 3, cont 5 |
| A7-lite: transient 0x887A0026 during capture init is retried, not fatal (saved the process 3× in stress) | agent d256b51 |
| Rapid display churn is implicated in a rare WHOLE-GUEST livelock (qrexec dead, cputime slope ~1.9 vcpu-s/s, kill required); debounce avoids it, does not fix it; trap armed | FINDINGS 08-04 cont 6, 08-05 cont 4/5 |
| gui-daemon dies ~50% of agent restarts (dom0-side EOF/write-path bug + restart_guid UAF); fix pending upstream, user-approval-gated | DESIGN-gui-daemon-restart-survival.md §3; FINDINGS 08-04 end, 08-05 cont 4 |
| D3-class in-place mode injection is what every other hypervisor uses — via DXGK verbs IddCx hides. No console-IddCx blink-free path is publicly known | docs/RESEARCH-hypervisor-resize.md |
| D4v2 (stable EDID) is BROKEN as of writing — monitor never arrives; D4 v1 (identity churn per replug, session-scoped, resets on boot) is the working driver | FINDINGS 08-05 cont 3/5 |
| A4 (preference vs LastApplied cache split) is designed (PLAN-trackb §3-A4) but NOT landed — respawn-applies-stale-cache is a live defect | FINDINGS 08-05 cont (stress defect 2); agent log has no A4 commit |
| Current follow loop is a PowerShell harness (`guest/resize-sync.ps1`, debounced latest-wins); production home is the agent | FINDINGS 08-05, cont 4 |
| Non-seamless daemon window SHOWS A CROPPED framebuffer when the window is smaller than the guest desktop (1384 of 1440 rows observed) | FINDINGS 08-04 cont 2, exp 2 |

---

## 1. Hard rules and their design consequences

**R1 — NEVER resize-to-viewport.** The dom0 window size is the single source of truth; the
guest never imposes a size on the dom0 window.
- Consequence: the agent may send `MSG_CONFIGURE` for window 0 **only** echoing a size dom0
  itself requested (or at initial session establishment, when dom0 has no size yet). On
  `RESKEEP` (mode unobtainable) the agent sends **nothing** — the dom0 window stays at the
  user's size and the guest desktop is temporarily mismatched (see §5 mismatch rendering).
- Consequence: exact-follow's never-snap is load-bearing and must never regress. The A1
  `RESSNAP … SNAPPED` marker on a src=dom0 request becomes a hard test FAILURE, not a log line.
- Consequence for boot/respawn: the boot mode is chosen with no dom0 window to consult, so it
  may only come from the last *dom0-requested* size (A4's LastApplied, rewritten to be
  dom0-source-only) — and when the daemon connects and sends its first `MSG_CONFIGURE`, that
  wins unconditionally.

**R2 — the published mode list tracks the current window/work area; no accumulation.**
Host-screen-size modes (e.g. 3440x1440 on a 3440x1440 host) must not be offered unless the
dom0 window actually is fullscreen.
- Consequence: the driver's mode list is not a cache of history. Policy in §4.

**R3 — no chaotic jumps during drags; "smooth" is the deliverable.** The user's view during
and immediately after a drag must be calm. State machine in §5.

---

## 2. Architecture — who does what

### Driver (QubesIDD, D4 lineage) — dumb mode publisher
- Publishes exactly the mode set the agent hands it (registry today; IOCTL in M5). Applies
  no policy of its own beyond input validation (RDP constraints: width even, 200–8192;
  height 200–8192).
- Stable EDID identity across replugs (D4v2 — must be fixed first; the alternative, D4 v1's
  per-replug identity churn, is session-bounded but is exactly the "runaway registry /
  random resolutions" failure the hypervisor survey documents).
- Later (M5): device interface + IOCTL so a mode change is a **monitor-level**
  departure/arrival executed by the driver in place, instead of a full device restart from
  outside.
- The driver never applies a mode. The agent is the session-side applier (console IddCx has
  no other option — survey §5/§6, D3 negative).

### Agent — single owner of resize policy (all of §4–§7 lives here)
- Consumes `MSG_CONFIGURE` w0 (src=dom0), runs the gesture state machine (§5), the
  exact-follow obtain/apply path (exists, `8bd39a9`), the mode-list hygiene writes (§4), the
  churn rate limiter (§7), and the boot/respawn policy (A4 rework).
- Absorbs and retires `resize-sync.ps1` — the PS loop is a harness, not a product.
- A6/A7/ack-repaint machinery is the transition engine: old grant held until dom0's dump
  ack, full repaint on ack, init retries on transient ACCESS_LOST.

### gui-daemon (dom0) — Phase-3-gated; every item here needs a design writeup + user review
- Nothing daemon-side is REQUIRED for the MVP: "hold last frame during transition" already
  falls out of the protocol (the daemon keeps rendering the old mapped framebuffer until a
  new `MSG_WINDOW_DUMP` arrives — this is what the A6 ack-repaint already exploits).
- Optional, only if §5 measurement shows the grow-case is ugly: letterbox/clear paint for
  the window-larger-than-framebuffer mismatch (today's behavior for that case is UNMEASURED;
  the shrink case is known-good cropping).
- Independent but adjacent: the EOF restart-survival fixes (§0 last row) go upstream on
  their own track. They matter here only as failure-mode context (§6).

---

## 3. What "smooth" can and cannot mean on this platform — the ceiling, stated first

**Cannot be had on console IddCx 1.5 (evidence-backed, not pessimism):**
- **Live mid-drag resolution tracking** (guest resolution following every mouse delta, as
  VBox/virtio do). Their mechanism is an in-place custom-mode-slot rewrite via raw DXGK
  verbs (`pfnAddMode`, `DxgkCbIndicateChildStatus(Connected=TRUE)` re-assert) that IddCx
  does not expose; our only in-place verb, `IddCxMonitorUpdateModes`, is measured dead on
  console 19045 (D3, negative with control). Every mode change we can make involves a
  monitor departure/arrival. This is a platform ceiling, not an engineering gap.
- **Flicker-free guest-side mode switch.** The guest's own screen blanks across
  departure/arrival + mode apply. We can hide it from the dom0 viewer (held frame), not
  from the guest (a full-screen app inside the guest sees a real mode change).
- **Zero-latency convergence.** The floor is monitor arrival + OS mode apply + DWM
  re-layout + capture re-init + re-grant + re-dump + repaint. Unmeasured decomposition
  (M0), but the irreducible OS parts (arrival + apply + DWM) are plausibly 300–700 ms.
  Target after M5: **≤1 s** release-to-live. The 2–3 s measured today includes a full
  UMDF device restart, which is the part we can attack.

**Can be had (and is the plan):** a drag during which the dom0 window resizes freely while
the content stays a calm, frozen-or-cropped last frame; exactly ONE mode change per gesture,
at release; a single clean repaint at the exact requested size; sub-second blackout if M5
delivers; no accumulated modes; no livelock in normal use.

---

## 4. Driver mode-list policy (implements R2)

Published set at any moment = **at most three modes, all derived from current state**:

1. **Current applied size** (so the OS never finds itself on a mode the monitor no longer
   offers — removing the current mode out from under the OS forces an unrequested switch,
   which would violate R1).
2. **Pending requested size** (during a transition only; becomes #1 on apply).
3. **Safety fallback 1024x768** (compiled into the driver; the recovery size if the
   registry is empty/corrupt — never removed, never preferred).

Explicitly NOT published:
- Any historical size. The agent **replaces** the registry value on every write (the
  exact-follow `WriteRequestedIddMode` already writes a single-entry REG_MULTI_SZ — keep
  that contract; the driver must treat the value as the whole list, not append to prior
  state). Verify the D4 driver's compiled base list is trimmed to the fallback only —
  D4 v1 inherited sample-era entries; trimming it is part of M2.
- The host screen size, unless dom0 requests exactly it (i.e. the window really is
  fullscreen) — then it enters as #2→#1 like any other size and **leaves** the list when
  the window leaves fullscreen and the next size is applied.
- Work-area size, EXCEPT under the M6 pre-publish option (§5, option C), where it is
  explicitly permitted by R2's own text ("track the current window/work area") — it is a
  predicted next size, refreshed when the work area changes, not an accumulated one.

Persistence hygiene: apply WITHOUT `CDS_UPDATEREGISTRY`/`SDC_SAVE_TO_DATABASE` for
intermediate sizes; persist only on a settled size that survives N seconds (proposal: 10 s),
so the GraphicsDrivers Configuration database doesn't collect one entry per drag. (With
stable EDID there is one monitor path; the database dedups per path — but the per-path
mode cache can still override arrival-preferred modes; the agent's explicit apply is what
makes this moot. Verify with modeprobe in M2 acceptance.)

Boot policy (A4 rework, R1-compliant): boot mode = last **dom0-sourced** applied size
(new registry value written ONLY on `RESEXACT src=dom0` success — never by seamless-force,
never by xconf). Respawn after a crash re-reads the same value — which is correct now,
because it can only contain a dom0-requested size, killing the stress-observed
"respawn applies FullscreenWidth cache" defect by construction.

---

## 5. Drag-time UX state machine (implements R3)

### Options evaluated (the ask):

**A. Keep resolution fixed during the drag; dom0 crops/letterboxes until release.** This is
the chosen baseline behavior — and it is mostly free. The daemon renders the old framebuffer
into whatever window the WM gives it: window smaller ⇒ crop (measured working — the
1384/1440 clipped-band observation); window larger ⇒ UNMEASURED (the old framebuffer covers
part of the window; what paints the rest?). M4 measures the grow case; if it shows garbage,
the daemon-side letterbox paint becomes a Phase-3 design item (small, but daemon = design
review first). No guest-side action during TRACKING at all — maximum calm by doing nothing.

**B. One exact mode change on release (current behavior), blackout masked by held frame.**
Chosen. The masking is already 80% real: the daemon holds the last dumped frame until the
new `MSG_WINDOW_DUMP` arrives, and the A6 ack-repaint guarantees the first post-switch
frame is a single clean generation (validated: interleaved-generations defect fixed by
177ac32). What remains is to make the agent **strictly silent** toward dom0 during
OBTAIN/APPLY: no intermediate dumps, no `MSG_CONFIGURE`, no damage messages for the dying
surface (a partial teardown that emits unmap/destroy would blank the dom0 window — exactly
what A6 exists to prevent; keep it that way under churn). Result as seen from dom0: frozen
content in a freely-resizing window, then one repaint at the exact size. That IS calm.

**C. Pre-publish the work-area size.** Worth having as an optimization, not a foundation:
publish {current, work-area} so a maximize/snap-to-edge gesture finds its target already
offered ⇒ exact-follow's `replug=0` path (CDS_TEST succeeds immediately, apply with **no
replug at all** — measured path, it exists in `8bd39a9`). Blackout for the single most
common big-resize gesture drops from ~2–3 s to just mode-apply + re-grant (unmeasured,
likely well under 1 s). Gated on a **verified** work-area source: the qubesdb work-area
watcher was measured absent on this guest (A5 control: source=none), so this lands only
with a proven source, and the A5 accessor must return FALSE/none rather than inventing a
number. R2-compliant per its own text; the pre-published entry is refreshed on work-area
change and dropped if stale.

**D. (rejected) Micro-stepped resolution during the drag** — replug per intermediate size.
Rejected: this is the v0 loop that produced the user-reported sheared-generations breakage,
is the fastest known route to the livelock, and accumulates registry entries. Killed by
measurement, not taste.

### The state machine (agent, resolution thread):

```
IDLE
  └─ MSG_CONFIGURE w0, size != current  →  TRACKING
TRACKING   (drag in progress)
  - do NOTHING guest-side: no mode ops, no dumps beyond normal frame flow,
    framebuffer stays at pre-drag size (dom0 crops / letterboxes)
  - latest-wins: remember only the newest size
  - exit when the newest size is stable for the quiet period
    (currently 1200 ms rolling debounce, agent 5969284; keep tunable)
  └─ stable & differs from current        →  OBTAIN
  └─ stable & equals current (drag returned home)  →  IDLE
OBTAIN
  - rate limiter check (§7): if a topology change ran < T_min ago, wait out the remainder
  - CDS_TEST exact  → hit: APPLY (replug=0)
  - miss: write mode list {current, requested} → trigger replug
    (M5: IOCTL monitor-replug; today: SetupAPI device restart) → poll CDS_TEST
  - SILENT toward dom0 for the whole state (option B)
  - new MSG_CONFIGURE arrives mid-OBTAIN: note it (latest-wins slot), finish or
    abort-before-apply, then re-enter TRACKING with it — never queue >1
  └─ mode appears  →  APPLY
  └─ timeout (12 s today; retune from M0 data)  →  KEEP
APPLY
  - ChangeDisplaySettings exact, readback-verify (A2 discipline: adopt the readback)
  - A6 rides the ACCESS_LOST: new grant, window-0 re-dump at new geometry,
    MSG_CONFIGURE w0 echoing the dom0-requested size (R1: echo only), ack → repaint
  └─ readback == requested  →  SETTLED
  └─ apply failed / readback mismatch  →  KEEP (never snap, never retry a different size)
SETTLED
  - log RESEXACT + latency breakdown (M0 instrumentation lives here)
  - after 10 s stable: persist as LastApplied (dom0-sourced only), trim mode list to
    {current} (+fallback)
  └─ →  IDLE
KEEP   (RESKEEP — obtain or apply failed)
  - apply NOTHING, send NOTHING (R1); dom0 window stays user-sized over a mismatched
    framebuffer (crop/letterbox)
  - schedule ONE retry after T_retry (proposal 5 s); second failure → stay in KEEP,
    log loudly, stop retrying until the next dom0 request
  └─ →  IDLE
```

Interaction with the daemon's stale-echo: during the replug outage the daemon can re-send
the pre-resize `MSG_CONFIGURE` (measured, handled in the PS loop today). The state machine
treats any incoming size equal to the in-flight target as confirmation and any other as a
new TRACKING entry — convergence logic moves from resize-sync.ps1 into the agent verbatim.

---

## 6. Failure and recovery behavior

- **Replug fails / monitor never arrives** (D4v2's current bug class): KEEP state, loud
  `RESKEEP reason=`, bounded retry as above. The desktop stays on the current mode — never
  headless, because the current mode is always still published (§4 rule 1) and the safety
  fallback exists.
- **Agent crash mid-transition:** watchdog respawns in ≤1 s (measured). Respawn reads the
  dom0-sourced LastApplied (§4 boot policy) — worst case the guest returns to the last
  settled size, and the daemon's next `MSG_CONFIGURE` re-drives the correct one. The A6
  exit drain is bounded (2 s) and ring-guarded, so a dying agent cannot stall on a dead
  daemon.
- **gui-daemon death (the ~50% restart coin-flip, dom0 EOF bug):** out of our tree; fix
  pending upstream (user-approval-gated text, DESIGN-gui-daemon-restart-survival §3). Our
  mitigation: minimize agent restarts (A7 retries instead of dying; graceful installs), and
  the state machine must survive a vchan reconnect: on reconnect, re-dump at CURRENT
  geometry, wait for the daemon's first `MSG_CONFIGURE`, treat it as authoritative (R1).
- **Livelock (whole-guest, churn-triggered, root cause open):** containment, not cure —
  cure requires the deliberate-repro + NMI dump session (user involvement for `xl trigger`).
  Containment = §7 rate limiter + the already-armed trap (wedge-telemetry.ps1,
  soak-wedge.sh, NMICrashDump). The limiter's floor: **no two topology changes closer than
  T_min = 2.5 s** (the measured wedges all involved back-to-back no-settle churn; 100-cycle
  soak WITH settle was clean — that soak is the passing control, the 3×-SyncNow wedge is
  the failing one, both already on record).

## 7. Churn rate limiter (livelock avoidance, in the agent)

Token-bucket over **topology-changing operations only** (replug or mode apply; CDS_TEST
polls are free): capacity 1, refill T_min = 2.5 s. OBTAIN blocks on the bucket (latest-wins
means blocking is cheap — at most one gesture is ever waiting). Additionally: after the
grant handshake, do not start a new OBTAIN until the previous transition's window-0 dump
ack arrived or timed out (the 08-04 live-caught hang followed a second change landing while
the first recovery's revoke/re-grant was in flight — serialize past the ack, not just past
the apply). Both parameters registry-tunable for the deliberate-repro experiments.

---

## 8. Instrumentation and acceptance (every check names its failing control)

### M0 instrumentation — replug-latency decomposition (prerequisite for M5's claims)
Timestamped agent log lines at: request-settled, registry-write, replug-issued,
monitor-departed (first CDS_TEST refusal / display-change notification), mode-available
(CDS_TEST hit), apply-returned, ACCESS_LOST-seen, re-grant-done, dump-sent, ack-received,
repaint-sent. Plus dom0-side convergence stamp (existing follow-latency poll). One table,
N=10 resizes, median+max per stage. *Failing control:* the stage clocks must show the
known ~2–3 s total on the current stack; if the sum disagrees with the end-to-end
follow-latency measurement by >20%, the instrument is wrong, not the system.

### Acceptance for the whole feature (D7, extends D5's six criteria)
1. **One mode change per gesture:** scripted dom0 drag (needs the `_QUBES_VMNAME` variant
   of the dom0 resize service — user install, same pattern as `local.WinResize`) with ≥10
   direction changes over 5 s → exactly one `RESEXACT`, zero `RESSNAP…SNAPPED`, zero
   intermediate replugs. *Failing control:* the v0 per-request loop (kept as a harness
   flag) must fail this on the same gesture — it measurably replugged per request.
2. **R1 (never resize-to-viewport):** dom0-side geometry poll (xdotool, in the resize
   service) across the whole test: the window's size changes only monotonically with the
   scripted drag, never re-set by the guest. *Failing control:* the pre-exact-follow agent
   (snap path) on a non-offered size — daemon adopts the snapped size and resizes the
   window; must be detected.
3. **Calm pixels during drag:** decoded `qtest shot` at 3 points mid-drag → content is the
   pre-drag frame (cropped or partially covered), single generation, no shear. *Failing
   control:* the pre-177ac32 build under the same churn showed interleaved generations —
   already on record as a screenshot.
4. **Exact convergence:** modeprobe `ENUM_CURRENT_SETTINGS` == requested; ddaprobe pitch
   == width*4; fiducial pattern render + decoded compare (the D5 criteria, re-asserted per
   size — carried over unchanged).
5. **Blackout budget:** release→live-pixels-at-new-size (decoded), median over 10 gestures:
   record on current stack (expect 2–3 s), target ≤1 s after M5. *Failing control:* M0's
   per-stage table must attribute the improvement to the stage M5 changed (device-restart
   time), not to noise — an improvement without stage attribution is not accepted.
6. **Mode-list hygiene (R2):** after 20 random-size gestures ending non-fullscreen:
   modeprobe on the IDD lists ≤ {current, fallback(, work-area if M6)}; host size ABSENT.
   Then one fullscreen gesture → host size present; un-fullscreen + one gesture → absent
   again. *Failing control:* D4 v1 with the harness's historical multi-entry registry
   value must show the accumulated list — if it doesn't, the probe is reading the wrong
   device.
7. **Soak with limiter:** 100 mixed cycles (the existing soak harness) + the 3×-no-settle
   pattern now going THROUGH the limiter: zero wedges, qrexec alive, cputime slope < 0.2
   vcpu-s/s. *Failing control:* the same no-settle pattern with the limiter registry-disabled
   — known to wedge (observed 08-05); run it LAST, with forensics staged, as the deliberate
   repro this doubles as.
8. **Boot/respawn (R1 + A4):** cold boot → guest at last dom0-sourced size; kill -9 the
   agent mid-session → respawned agent does NOT change the resolution (watch modeprobe for
   60 s). *Failing control:* the current (A4-less) build re-applies the FullscreenWidth
   cache on respawn — the stress run already demonstrated exactly this.

---

## 9. Work items — effort (person-days, CI-only ~20 min/Windows-build iteration priced in) and feasibility

| # | Item | Effort | Feasibility | Evidence |
|---|---|---|---|---|
| M0 | Latency decomposition instrumentation (agent log stages + one dom0 stamp; no driver logging needed) | 1 pd | **Proven** technique | A1/A6 log instrumentation precedent; follow-latency poll exists |
| M1 | D4v2 stable EDID — fix monitor-arrival regression | 1–2 pd (in progress; unknown tail) | **Risky-unproven** in our tree (currently broken), **proven** concept (every shipping console IDD uses stable EDID) | FINDINGS 08-05 cont 3/5; survey §6 |
| M2 | Mode-list hygiene: trim driver base list to fallback; replace-not-append contract; no-persist-until-settled; acceptance 6 | 1 pd (0.5 driver + 0.5 agent/verify) | **Likely** — all mechanisms exist, policy only | D4 v1 registry path measured working |
| M2b | Boot/respawn policy (A4 rework, dom0-sourced LastApplied only) | 1 pd | **Likely** — designed in PLAN-trackb §3-A4, defect already characterized | stress defect 2 is the failing control, already observed |
| M3 | Agent-native follow: absorb resize-sync.ps1 (stale-echo convergence, gesture debounce unification), retire the PS loop | 1–2 pd | **Likely** — exact-follow + 1200 ms debounce already in the agent; what moves is convergence/retry logic already proven in PS | 8bd39a9, 5969284, d233a2b |
| M4 | Drag state machine (§5): TRACKING silence, OBTAIN/APPLY gating on A6 ack, KEEP semantics, grow-case mismatch measurement | 2–3 pd | **Likely** — every component (A6 park/ack/repaint, latest-wins thread, held-frame masking) individually validated; the composition is new. Grow-case rendering is the one unknown; if ugly → small Phase-3 daemon item | FINDINGS 08-05 cont 3/4 |
| M5 | Monitor-level replug: driver IOCTL → in-place `IddCxMonitorDeparture`+`Arrival` with new description; agent calls IOCTL instead of SetupAPI device restart | 2–3 pd | **Likely-unproven**: DDIs are IddCx 1.0, documented for exactly this (RDP does departure/arrival on count change); parsec-vdd plugs/unplugs monitors at runtime on console — but WE have not run it, and gain size is unknown until M0 says what the device restart actually costs | survey §5/§6; M0 gates the claim |
| M6 | Work-area pre-publish (replug=0 fast path for maximize) | 1–2 pd + a **user/dom0 dependency** (verified work-area source; qubesdb watcher measured absent) | **Likely** mechanically (replug=0 path measured); **blocked** on the source | 8bd9a-replug=0; A5 control source=none |
| M7 | Churn rate limiter + ack-serialization (§7) + soak/limiter-off deliberate repro | 1 pd (+1–2 pd forensics session, user needed for NMI) | **Proven** need, **likely** sufficiency for normal use (settle-respecting soak clean 100 cycles); NOT a root-cause fix, and says so | FINDINGS 08-05 cont 5 |
| M8 | Daemon letterbox paint for grow-case mismatch (ONLY if M4 measures garbage) — Phase 3: design note + user review before code | 1 pd + review latency | **Likely** small; gated by rule, not difficulty | CLAUDE.md Phase 3 |
| M9 | dom0 drag harness (`_QUBES_VMNAME` resize-service variant + xdotool drag script) — needs user install in dom0 | 0.5 pd ours + user action | **Proven** pattern (WinResize service exists, install script written) | FINDINGS 08-04 cont 2 |

Total core path (M0–M5, M7, M9): **~10–14 pd.** With M6+M8: ~13–17 pd. CI loop dominance
note: driver items (M1, M2, M5) burn a 20-min cycle per iteration — estimates assume 3–8
iterations each, consistent with this project's D0–D4 history.

---

## 10. Ordered milestones

1. **M0** instrumentation + baseline decomposition table (unblocks honest claims for
   everything below; also finally answers "what dominates the 2–3 s").
2. **M9** dom0 drag harness (user install) — without it, acceptance 1/2/3/5 cannot run;
   everything after this point measures real gestures, not SyncNow approximations.
3. **M1** D4v2 stable EDID (already in flight; without it every replug mints identity —
   registry hygiene and the config-database reasoning in §4 assume it).
4. **M2 + M2b** mode-list hygiene + boot/respawn policy → acceptance 6 and 8 pass.
5. **M3** agent-native follow, PS loop retired.
6. **M4** drag state machine → acceptance 1, 2, 3 pass on the 2–3 s blackout; grow-case
   verdict decides whether M8 enters the queue.
7. **M7** rate limiter + soak gate → acceptance 7; schedule the limiter-off deliberate
   repro WITH forensics as its failing control (user: NMI trigger).
8. **M5** monitor-level replug → re-run acceptance 5 with stage attribution; this is the
   milestone that turns "calm but 2–3 s" into "calm and ≈sub-second" — or honestly reports
   that the device restart was NOT the dominant cost and the ceiling stands at ~2 s.
9. **M6** work-area pre-publish (when a verified source exists) → maximize becomes the
   fastest gesture instead of the slowest.
10. **M8** daemon letterbox — only if M4 demanded it; Phase-3 design note first.

**Definition of done for "smooth" on this platform:** acceptance 1–8 green, blackout median
at the value M0+M5 justify (target ≤1 s, floor honestly reported if higher), zero wedges in
the limiter-on soak, and the ceiling section (§3) reproduced verbatim in the user-facing
status — mid-drag live resolution tracking is off the table on IddCx 1.5 and is stated as
such, not promised as future work.
