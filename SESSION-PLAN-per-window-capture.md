# Session plan — per-window capture feasibility (executes DESIGN-QUESTIONS-per-window-capture.md)

Written 2026-07-31 as the handoff for a fresh-context code session. Read
`DESIGN-QUESTIONS-per-window-capture.md` first; this file turns its questions into an ordered,
acceptance-gated work plan. CLAUDE.md rules apply in full, especially the autonomy-enforcement
and instrument-validation sections.

## Objective and hard scope limits

**Objective:** produce an evidence pack answering Q1–Q4 by measurement and source reading, and
on that evidence draft the Phase-3 design writeup (Q5–Q7) for user review. That writeup is the
session's terminal deliverable.

**This session writes NO protocol code, NO agent capture rework, and contacts upstream about
NOTHING.** Per CLAUDE.md Phase 3, anything touching the GUI protocol, gui-daemon, or grant
lifecycle needs a design writeup and user review *before* code. Probe tools that only run in
the guest and read APIs are in scope; changes to `agent/gui-agent/*` are not.

**Entry state (from GOAL-STATUS.md):** stock QWT 4.2.2 is installed on win-idd-test because our
build has an unresolved cold-boot enumeration failure. That is fine for this session — every
probe below is a standalone tool run against stock. Do NOT deploy our agent build; the cold-boot
bug is a separate workstream and must not be entangled with these measurements.

## Ordering logic

The design doc's §4 order is right and is kept: the cheapest check that can void the whole
premise runs first, and the check that decides "protocol change or not" runs in parallel because
it needs no VM time.

```
Gate 0  PrintWindow occlusion probe   — validates the premise; failure voids everything
Step 1  Read gui-daemon (parallel)    — Q1: is MSG_WINDOW_DUMP per-window already honoured?
Step 2  WGC availability + mappability — Q4
Step 3  Capture cost scaling           — Q3
Step 4  Grant budget                   — Q2
Step 5  Design writeup                 — Q5/Q6/Q7, drafted from the above, ends the session
```

Steps 2–4 are guest-mutating and run **serially** (CLAUDE.md: concurrent VM jobs destroyed
results before). Step 1 is local reading and can interleave with anything.

---

## Gate 0 — occluded-window PrintWindow probe (design doc §4.2)

**Question:** does `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)` return correct pixels for a
window fully covered by another? If no, the premise is wrong and the design doc says so itself:
stop, record the negative result in FINDINGS.md and the design doc, and end the session there.

**Build:** `tools/pwprobe/` — small C tool, same shape as `tools/chromerepro` (plain Win32,
`.vcxproj`, added to the existing tools job in `.github/workflows/build.yml`). Behaviour:
1. Create window A, fill with a deterministic pattern (reuse chromerepro's drawing approach or
   `tools/notepad-fill.py`'s content idea — but self-drawn is better: exact expected pixels).
2. Create window B fully covering A, different pattern.
3. `PrintWindow(A, ..., PW_RENDERFULLCONTENT)` into a DIB; also `PrintWindow` with flags=0 as
   the control arm.
4. Write both captures as BMP/PNG to disk plus a stdout verdict line comparing captured pixels
   against A's expected pattern (`PWPROBE: fullcontent=MATCH|MISMATCH plain=...`).

**Run:** `qtest push` + `pushrun` (remember: first push intermittently sends 0 bytes — verify
the tool demonstrably ran, retry loop like `viewcheck/coldboot-test.sh` does). Judge the
**pixel comparison the tool itself computed in-guest**, and pull the BMPs for a second look;
`qtest shot` sees only what dom0 composites and cannot judge this.

**Instrument validation:** run 3×. Also run the deliberate-failure arm: capture A *without*
`PW_RENDERFULLCONTENT` while occluded — on most systems that returns stale/occluder content,
which demonstrates the probe CAN report MISMATCH. A probe never seen to fail is not evidence
(CLAUDE.md rule 5). If the flags=0 arm also returns correct content, note it but treat the
check as unproven-by-negative-control and say so in FINDINGS.md.

**Acceptance:** 3/3 runs, fullcontent arm MATCH, negative arm demonstrated. Then proceed.

## Step 1 — Q1: read gui-daemon for per-window MSG_WINDOW_DUMP (no VM time)

**Question:** `SendScreenGrants()` sends `MSG_WINDOW_DUMP` with `header.window = 0` ("screen").
Is a non-zero window id defined, and does the daemon treat that grant as the window's backing
store — or does it only ever composite from the window-0 buffer?

**Method:**
1. Clone read-only into `upstream/`: `QubesOS/qubes-gui-daemon` and `QubesOS/qubes-gui-common`
   (protocol headers). Pin and record the commit hashes. Read-only clone is fine; the
   no-upstream-contact rule is about pushing/PRs/issues.
2. Trace the daemon's `MSG_WINDOW_DUMP` handler: how the grant list is mapped, whether the
   mapping is stored per-window or globally, and what the composition path uses as the pixel
   source for a window (its own dump buffer? offsets into window 0's?). Follow `MSG_SHMIMAGE`
   handling for the same question: are damage coordinates interpreted window-relative or
   screen-relative when a window has its own buffer?
3. Cross-check against the Linux agent (`qubes-gui-agent-linux`, clone if needed): does it
   send per-window dumps already? If the Linux agent does per-window MSG_WINDOW_DUMP, Q1's
   answer is almost certainly yes and the Windows agent is the outlier.

**Deliverable:** a verdict in FINDINGS.md with file:line citations for every claim, one of:
- **A: daemon already honours per-window dumps** → the proposal is agent-side only; Q6 shrinks.
- **B: defined but unused/broken daemon-side** → protocol intact, daemon patch needed (Phase 3).
- **C: window-0 is structural** → full protocol design needed; raises the cost of everything.

This verdict re-scopes Step 5, so finish it before writing any design prose.

## Step 2 — Q4: WGC availability and CPU-mappability

**Question:** is `Windows.Graphics.Capture` usable on this Win10 22H2 guest, and can its output
reach CPU-readable memory — at what per-frame cost? This decides whether per-window capture
keeps, degrades, or destroys the zero-copy property.

**Build:** `tools/wgcprobe/` (C++/WinRT console tool, CI-built like ddaprobe). Behaviour:
1. Report `GraphicsCaptureSession::IsSupported()` and OS build.
2. Create a capture item for a target HWND (`CreateForWindow` via the interop interface —
   note: on Win10 this may require the target to be visible, borders may be included, and
   `IsBorderRequired`/`IsCursorCaptureEnabled` knobs are 20H1+; record what actually works).
3. For each captured frame: copy to a D3D11 staging texture, `Map()`, and time acquire→mapped
   per frame over 100 frames; print p50/p95 like ddaprobe does.
4. Print whether any path avoids the staging copy (it will not — WGC surfaces are GPU-side;
   the point is to measure the copy, not hope it away).

**Also answer here (cheap, same tool):** does the frame carry dirty-rect info? (WGC on Win10
gives none — confirm and record; dirty rects would have to come from elsewhere, e.g. in-guest
diffing or DWM. This materially affects the design and must be in the writeup.)

**Acceptance:** stats stable across 3 runs on an unchanged scene; numbers recorded per window
size (small window vs maximized) since the copy cost scales with area.

## Step 3 — Q3: capture cost scaling with window count

**Question:** N WGC sessions vs one DDA desktop duplication — does cost scale with N, or with
total damaged area?

**Method:** extend `wgcprobe` with a multi-window mode: spawn K pattern windows (reuse pwprobe/
chromerepro scaffolding), capture all K concurrently, measure aggregate CPU and per-frame
latency for K ∈ {1, 4, 10, 30}. Control arm: ddaprobe's existing 100-frame DDA measurement on
the same scene, interleaved (CLAUDE.md rule 2: 3 runs per side, interleaved with control).
Keep the scene static for one series and animated (scripted invalidation) for another, so
"scales with count" vs "scales with damage" is actually separable.

**Acceptance:** a table in FINDINGS.md: K × {static, animated} × {WGC aggregate, DDA baseline},
3 interleaved runs each, with the instrument first characterised on one unchanged configuration.

## Step 4 — Q2: grant budget and re-grant cost

**Question:** practical ceiling and latency of `XcGnttabPermitForeignAccess2` when granting
per-window buffers (30+ windows, ~33 MB for a 4K window), and re-grant cost on resize.

**Method:** `tools/grantprobe/` — console tool linking the same xencontrol library the agent
uses (see `agent/gui-agent/` imports and the agent build for how it links). Behaviour:
1. Allocate and grant N buffers of representative sizes (a mix: 1280×720, 1920×1080, 4K),
   N stepping up until failure or 64; report per-grant latency and the failure mode/ceiling.
2. Release/re-grant a single buffer 100× to price the resize path.
3. Print totals: pages granted vs any limit it can discover.

Grants without a dom0 consumer mapping them is the honest limitation of this probe — record it
explicitly. The guest-side ceiling and latency are still the numbers Q2 asks for; the dom0-side
mapping cost belongs in the design writeup as an open item (dom0 experiments are out of scope
for this qube).

**Caution:** granting near the ceiling may destabilise the guest or QWT itself. Run this LAST
of the VM steps, snapshot expectations first (`qtest state`), and be ready to `qtest kill` /
`start`. Do not leave grantprobe resident; every run releases everything before exit.

**Acceptance:** ceiling + latency table, 3 runs, VM verified healthy afterwards (qrexec answers,
`qtest shot` shows a live desktop).

## Step 5 — design writeup (Q5, Q6, Q7) — terminal deliverable

Only after Steps 0–4 have verdicts. Write `DESIGN-per-window-capture.md`:

- **Architecture:** guest supplies per-window content, dom0 owns placement (import from
  `instrumentation/ARCHITECTURE-PER-WINDOW.md`, updated with measured numbers).
- **Q1 verdict** and its consequence: protocol-compatible (A), daemon patch (B), or protocol
  design (C) — with the file:line evidence.
- **Q5 — migration:** propose the incremental path (per-window capture for normal windows,
  composited fallback for fullscreen/exclusive), justified against what Steps 2–3 showed about
  mixed-mode cost. Flag-day only if the evidence forces it.
- **Q6 — placement ownership:** what MSG_CONFIGURE becomes, and how a dom0-side resize reaches
  the guest. Reuse the Phase 2B-resize channel analysis (CLAUDE.md) — read qubes-gui-daemon +
  qubes-gui-agent-linux for `qubes.SetMonitorLayout` vs MSG_CONFIGURE while doing Step 1; it is
  the same reading session.
- **Q7 — security:** many small read-only grants vs one large read-only grant; enumerate what
  dom0 maps in each model, note that placement moving to dom0 *reduces* guest influence over
  dom0-side geometry, and state plainly anything that could weaken isolation (none expected;
  if found, it is out of scope, period).
- **Costs and open items:** WGC dirty-rect absence, dom0-side mapping cost (unmeasured), the
  grant-budget probe's no-consumer caveat, Win10-1803 floor for WGC and the PrintWindow
  fallback for older/edge windows.
- **Explicitly not started:** any code. The writeup ends with the upstream plan (design issue
  referencing qubes-issues #1861) which requires the user's approval of the exact text.

Then stop — this is one of the approval gates CLAUDE.md actually mandates. Present the writeup
and the evidence pack to the user.

## Failure/exit conditions

- **Gate 0 fails (occluded content not retrievable):** the design doc is void by its own §4.
  Record it, check whether WGC (Step 2's tool) succeeds where PrintWindow failed before fully
  closing the door — WGC is the primary proposed API, PrintWindow only the cheap proxy. If both
  fail on occluded content: negative design note, session over.
- **Q1 verdict C plus bad Q3/Q4 numbers:** the honest writeup may be "not worth it at current
  cost"; that is a valid terminal deliverable. Do not soften it.
- Any probe needs >3 focused iterations to build/run → stop burning tokens, report options
  (CLAUDE.md escalation rule).
- Anything needing dom0 (e.g. the fullscreen screenshot service install from GOAL-STATUS open
  item 1) → ask the user; never attempt.

## Bookkeeping

- `FINDINGS.md` does not exist yet in this repo despite CLAUDE.md mandating it — create it in
  this session's first commit and append dated entries per step.
- Every probe tool: README.md + .vcxproj, wired into the existing tools build in
  `.github/workflows/build.yml`, deployed via the artifact → `qtest push` → `pushrun` flow.
  Hash-verify the pushed binary before trusting any run (CLAUDE.md rule 3).
- Commit early and often; each step's verdict is a commit.
- Not this session's problem, but do not lose it: the cold-boot enumeration failure
  (GOAL-STATUS.md) still blocks shipping the Phase-2A agent build. It stays a separate session.
