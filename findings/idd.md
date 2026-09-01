# idd — findings

## CURRENT STATE

AUTHORITATIVE. Supersedes everything under History below. A correction belongs HERE,
not only as a new dated section — the whole reason this file exists is that 654
correction lines were buried chronologically in a 25k-line log, so reading a topic
top-down returned the stale answer.

- Not yet distilled from the history below. UNVERIFIED

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

## 2026-08-01 (session 4, mgmt qube) — win11-idd-test provisioned; per-window build deployed; first Win11 defect

### New test qube: win11-idd-test (Win11 24H2 Enterprise Eval 26100.1742)
Provisioned fully unattended (mgmt/PROVISION-LOG.md has the recipe: autounattend-win11.xml
with LabConfig bypasses, split-swm media, same $OEM$ payload). QWT 4.2.2 + testsigning +
build cert all verified; drive with `QTEST_VM=win11-idd-test` (QubesIncoming path identical).
dom0 policy extended (tag-scoped lifecycle+block.*, name-scoped VMShell/Filecopy);
local.WinScreenshot is now an allowlist service taking +<qube>; qtest shot passes it.

### Per-window build ec55f39 (qwt-improved 4.2.2+agent.ec55f39) deployed and healthy on Win11
Overlay installer OK (sha-verified swap, .orig kept). Evidence of health: PwAttachWindow
per-window buffers for each app window; QGAPERF v=2 seq advancing; overlap scenario
(Notepad + elevated Windows Terminal) both pixel-correct in per-window shots; cold boot
PASS (qrexec 2 s, ENUMFAIL=0, agent up on boot path, 3 buffers attached). Recurring
benign-looking transient: bursts of `GetWindowData: GetRealWindowRect failed 0x80070006`
(ERROR_INVALID_HANDLE) around window churn — recovery works, but frequency on Win11 (11 in
~5 min across two boots) is higher than Win10; watch it.

### DEFECT (user-observed live, dom0-verified): Win11 XAML windowed popups bypass composite synthesis
Symptom: Notepad's "auto-save" teaching bubble renders in dom0 as its own sticky window
with a heavy BLACK FRAME over the Notepad window (instrumentation/win11/
xaml-popup-bypass-dom0.png) instead of being synthesized into the owner.
Taxonomy (instrumentation/win11/xaml-popup-taxonomy.txt): class `Xaml_WindowedPopupClass`
title "PopupHost", same process as Notepad, geometrically contained in the main window,
styles WS_POPUP + WS_EX_NOACTIVATE + WS_EX_NOREDIRECTIONBITMAP — and NONE of the flags the
override-redirect/synthesis classifier keys on (no TOPMOST, no TOOLWINDOW, no LAYERED),
and no GW_OWNER visible linkage.
Two independent classifier gaps:
1. Ownership: XAML windowed popups don't set GW_OWNER to the app main window -> the
   owner-contained synthesis predicate can never match. Candidate fix: same-PID +
   geometric containment (<=4px overhang) as an alternate linkage for
   Xaml_WindowedPopupClass / WS_EX_NOREDIRECTIONBITMAP popups.
2. Capture: WS_EX_NOREDIRECTIONBITMAP means the window HAS NO redirection surface —
   PrintWindow structurally cannot capture it. These windows must be slice-fed
   unconditionally. The black frame is consistent with blank (black) prefill persisting
   where no damage-driven patch has landed.
Impact class: ALL WinUI/XAML apps on Win11 (inbox Notepad, Terminal flyouts, context
menus, teaching tips, jump-list previews) — this is the default popup mechanism on the
new shell, not an Office-style corner case.
NOTE Win11 positives: Search/Start CoreWindows are CLOAKED and correctly invisible;
DummyDWMListenerWindow spam is 0x0-sized and correctly skipped.
Next (dev session): add owner-linkage fallback + unconditional slice-feed for
NOREDIRECTIONBITMAP windows to the acceptance/synthesis predicate; re-test bubble,
Win11 Notepad context menu (same class), Terminal dropdown; then re-run the full
Win10 acceptance set for regressions.

### Win11 XAML popup synthesis — FIXED (agent a5012a5 + 832ce97, dom0-verified)
Two-part fix, both on `perwindow`, package `4.2.2+agent.832ce9738328` deployed on
win11-idd-test:
1. **Same-process fallback owner** (a5012a5): `Xaml_WindowedPopupClass` popups carry no
   usable GW_OWNER; SynthQualifies now falls back to the TOPMOST same-process window
   whose granted buffer contains the popup. GW_OWNER, when tracked, stays exclusive
   (a menu owned by A must not synthesize into overlapping B); synthesized windows
   re-qualify only against their recorded owner (no owner-hopping); WINDOW_DATA gains
   ProcessId. Also fixed en passant: an already-accounted child no longer flunks
   re-qualification when the owner sits at WC_MAX_MASK capacity.
2. **Overhang 4 -> 12 px** (832ce97): XAML menus align to the owner's OUTER window rect
   while the buffer starts at the DWM frame — measured 5 px overhang at 96 DPI, one
   past the old cap, so the File menu still materialized after fix 1. Both consumers
   verified clip-safe first (patch loop intersects with buffer rect; capture mask
   clamps to channel width).
Evidence: teaching bubble AND File menu both `QGAPROTO,msg=SYNTH` into the Notepad
main window; dom0 full-desktop shot shows ONE window with the menu inside
(instrumentation/win11/xaml-popup-synthesized-dom0.png; before:
xaml-popup-bypass-dom0.png). Alt-nav keytip badges (~40x46, ~20px outside the frame)
are deliberately NOT synthesized.
Open Win11 items: (a) `WorkAreaCreateListener: CreateWindowEx failed 0x5 Access is
denied` twice at agent start — the event-driven work-area re-assert (826ad82) is dead
on Win11, needs its own look; (b) recurring transient `GetRealWindowRect 0x80070006`
bursts around window churn — handled, but noisier than Win10; (c) Win10 regression
pass for a5012a5+832ce97 still pending — the fallback only ever fires for popups
GW_OWNER can't place, and Win10-validated owned popups take the unchanged path, but
re-run the win-idd-test acceptance set before calling it clean (coordinate with the
Edge-fixes session which owns that VM right now).

### Keytip badges: small-popup acceptance (agent d6ab61c, dom0-verified)
User-observed on the synthesis build: Alt-nav keytip badges only PARTIALLY visible.
Root cause chain: ShouldAcceptWindow's SM_CXMIN/CYMIN floor (~136x39) silently rejects
the ~40x46 keytip popups; they sit ~20px outside the owner's granted buffer so
synthesis cannot represent them either; the only pixels that reached dom0 were the
fragments overlapping the synthesized menu's patch region.
Fix: override-redirect popups now use a token 4x4 floor (normal windows keep
SM_CXMIN/CYMIN; DWM-cloaked strips like EdgeUiInputTopWndClass stay excluded via the
IsVisible fold, verified before shipping). Result (keytips-visible-dom0.png): menu
synthesized borderless inside Notepad, keytips fully visible as 12 tiny slice-fed
override-redirect windows - each with the daemon's red qube border, which is the
DESIGNED presentation for guest windows and stays (2A-chrome rule 4: never weaken
daemon-side bordering).
Also observed: one borderline keytip synthesized at creation geometry then cleanly
materialized when its final position left containment ("no longer owner-contained,
materializing") - the existing re-check machinery handles the flap.
Win11 stack now: package 4.2.2+agent.d6ab61cf8659 on win11-idd-test (a5012a5 fallback
owner + 832ce97 overhang 12 + d6ab61c small popups).

### Drag phantom identified: Win11 snap-layouts overlay (fix 3c12071, NOT yet verified)
User report: dragging a guest window by its WINDOWS title bar makes a huge phantom window
full of desktop wallpaper appear at the top of the screen, staying until release.
Could NOT be reproduced with synthetic input (SetCursorPos/mouse_event drags) - only with
a real user drag; the high-rate recorder (instrumentation/win11/window-recorder.ps1, run
while the user dragged) caught it: `XamlExplorerHostIslandWindow` (explorer.exe) 2560x360
at (440,0), ex=0x2800a8 = TOPMOST|TRANSPARENT|TOOLWINDOW|LAYERED|NOREDIRECTIONBITMAP,
not cloaked. Corroborated by the agent log: `PwAttachWindow: per-window buffer 2560x360
(900 pages) attached (slice-fed)` on each drag, plus one 3440x1440 slice-fed attach.
NOREDIRECTIONBITMAP -> PrintWindow-ineligible -> slice-fed from the composited desktop ->
wallpaper-filled phantom. Fix 3c12071 rejects click-through + uncapturable + toolwindow
windows in ShouldAcceptWindow. NOT built/deployed/verified yet - first task next session.
Full transcript: instrumentation/win11/drag-recording-snaplayout.txt.

### Keytip presentation is still wrong (open, user-flagged)
d6ab61c made keytips visible but each is announced as its own dom0 window, so the daemon
borders all ~12 of them and their slice-fed content bleeds the pixels behind them
(instrumentation/win11/keytips-bordered-defect.png). Neither this nor the pre-fix
half-cut-fragments state is acceptable. Designed fix in BOOTSTRAP-win11.md OPEN #1:
announce sub-floor popups only when they synthesize, drop them silently otherwise.

## 2026-08-02 (session 7) — FINAL: clean install of b299011, all display gates PASS

Build: `qwt-full` CI 30724190347, `installer.msi fa774936…`, `gui-agent.exe 4b4ce2b1…`,
agent `b299011` = perwindow + `2c5dad2` (workarea listener/lifecycle/drift) + `d64bca6`
(drag move-only suppression) + `b299011` (re-assert throttle + lost-fight backoff).
Installed by unattended ISO on a **wiped disk**. Netvm DETACHED throughout.

| gate | result |
|---|---|
| identity | `gui-agent.exe` = `4b4ce2b1…` (CI manifest), **0 `.orig`**, MSI-installed, testsigning Yes, services Running |
| workarea listener | **0** `CreateWindowEx 0x5` (was 3 per agent start on every build since 6d46132) |
| workarea churn (120 s idle, same script, same guest) | **0 applies, 0 drifts, 0.08 s agent CPU** — control on pre-fix `a459f0e`: **1460 applies (12.2/s), 21 drifts, 3.95 s CPU** |
| drag p50 (bench-agent.sh, identical harness) | **613 us** vs 5 ms bar. Pre-fix `a459f0e`: 17218/16128 us. Old screen-slice baseline: 917 us. 36.1 fps vs 23.7 |
| other phases p50 | scroll 121 us (base 493), type 96 us (base 531), idle 91/99 us (base 522/684) — all improved |
| Win10 protocol regression (5 win11-line fixes) | PASS on 526 non-empty records; occlusion 76/76 correct, menu synthesized not announced, geometry == DWM frame bounds, chromerepro 5→1, 0 bad rejections, 0 sub-floor announcements |
| Edge ULW first-run | PASS on all five points (pid stable, 0 vchan/daemon-kill signatures, ULW slice-fed fallback, real pixels, clean unmap) |
| cold boot | PASS: 2 guest top-level windows → **exactly 2 dom0 windows**, **0 EnumWindows failures**, agent up on the boot path |

### The work area now STICKS, and the backoff never had to engage
Only 6 applies + 3 drifts in the whole boot, then zero for 120 s. Once we stopped
re-asserting at 12 Hz, Explorer stopped counter-setting — the fight was self-sustaining.
`WA_LOST_FIGHT_TRIES` backoff logged 0 times, i.e. it is dead code on this configuration
and remains only as a guard.

### Harness defects found and fixed (they produced a FALSE FAIL on a healthy build)
`tools/viewcheck/coldboot-test.sh` reported "dom0 received 0 windows" on a build that was
demonstrably fine (2/2 windows visible seconds later). Two causes, both fixed:
(a) it screenshotted with no settle wait, racing map+first-damage; (b) it hardcoded
EXPECT=3, a count that assumed `chromerepro` was present — it is absent on a freshly
installed guest. It now derives the expectation from the scene's own window list and
settles 20 s first. `scene.ps1`/`vchanchk.ps1` were only in a stale session scratchpad and
are now committed under `tools/viewcheck/`, so the harness is self-contained.

### NOT claimed
Networking. With a netvm attached this build behaves exactly as before the display fixes
(xenvif never starts, ~2 cores, qrexec dead) — unchanged by our work, not fixed by it, and
still unattributed between us and upstream until the stock-QWT control install runs. The
stock-control ISO is built and verified (`win-idd-unattended-stock.iso`, staged MSI
bit-identical to vendor stock) and that experiment is the next task.

## FINDING (T2): the BASIC DISPLAY ADAPTER's mode list is fixed and lacks 1600x1000 — so the mode list has to become OURS

Framing correction (user, 2026-08-04): an earlier version of this entry said "the adapter
offers a fixed 29-mode list" and called T2 *blocked*, as though the mode list were a fact of
nature to work around. It is not. **The adapter is ours to choose.** Track B exists precisely
to replace the Basic Display Adapter with an IddCx driver we write, and declaring the mode
list — including arbitrary, dynamically-added modes — is that driver's core capability. The
measurement below does not block T2; it establishes that 1600x1000 cannot come from the
*stock* adapter and must therefore be **supplied by our driver**. T2 is a Track B deliverable,
not an obstacle.

The feasibility caveat in SESSION-HANDOFF-2026-08-03 §5 is now settled, and it settles against
the plan. Two independent instruments agree:

1. **The agent's own `InitVideoModes()`**, at `LogLevel=5` (see the registry note below), logs
   the list it will actually choose from: `Enumerated 29 supported modes` — 640x480, 800x600,
   1024x768, 1280x1024, 1600x1200, 1152x864, 1280x768/800/960, 1440x900, 1400x1050, 1680x1050,
   1920x1200, 2560x1600, 1280x720, 1920x1080, 1600x900, 2560x1440, 3840x2160, 960x540,
   1280x1080, 2160x1080, 2560x1080, 3200x1800, 3440x1440, 3840x1080, 3840x1600, 2048x1152,
   2048x1536. **No 1600x1000, and nothing arbitrary.**
2. **`ChangeDisplaySettings(..., CDS_TEST)`**: 1600x1000 -> -2 (`DISP_CHANGE_BADMODE`),
   1234x777 -> -2, 2566x1022 -> -2, 1920x1080 -> 0 (`DISP_CHANGE_SUCCESSFUL`).

Consequence: **T2 as specified is unreachable on the STOCK adapter, and is therefore a Track B
deliverable** — exactly as CLAUDE.md Phase 2B-resize predicted. `SelectSupportedMode()` does
not fail on an unsupported request; it silently snaps to the best-similarity entry in the list
above, so a naive "default to 1600x1000" change would appear to work and quietly give a
different resolution.

Read the right way round, this is the strongest concrete argument yet **for** building the
IddCx driver rather than a reason to defer T2: once the guest monitor is ours, 1600x1000 (and
the dom0-window-following resize of Phase 2B-resize, which needs arbitrary sizes like
2566x1022 that no fixed list will ever contain) becomes a property we simply declare. The 29
modes above are the stock adapter's limitation, not a requirement we must satisfy.

Caveat, stated rather than hidden: a standalone PowerShell `EnumDisplaySettings` probe written
for this returned `MODE_COUNT=0` — its DEVMODE marshalling is wrong. Its **mode list output is
discarded and is not the basis of anything above**; only its `CDS_TEST` return codes are used,
and those are corroborated by instrument 1. The probe was left in the session scratchpad rather
than committed: instrument 1 is production code that already answers this, so a second, broken
copy of the same question is not worth carrying. (Note: SESSION-HANDOFF §5 says this probe "was
written (`scratchpad/modes.ps1`)" — that file does not exist in the repo, in any commit. The
handoff is wrong on that point.) Track B will need a working mode probe to verify the IddCx
driver reports arbitrary modes; write it then, in C++ alongside `tools/ddaprobe`, not in
PowerShell marshalling.

Also observed while there: `HandleXconf: host resolution: 5120x1440` -> agent set 3440x1440
(from the saved `FullscreenWidth/Height`), confirming §5's "registry value is a last-applied
cache, read as if it were user intent".

# 2026-08-04 (close) — D0 DRIVER LIVE: the gating answer is OUTCOME A, and D2 is NEGATIVE

The single most important session of Track B so far. All on the D0 minimal driver
(branch t2/d0-minimal-idd, 1 monitor, EDID-less, single hw id Root\IddSampleDriver, dll
ED1CC64A; control build w/ MONITOR_COUNT=3 exists: scratch/d0-monitor3-control, 7128230F).

1. **"Present but inactive" is DEAD for D0.** Installing the driver (pnputil + devcon,
   deploy-and-test.ps1) brought the IDD monitor UP immediately: desktop extended to
   2048x768 dual (BDA (0,0)-(1024,768) + IDD (1024,0)-(2048,768) @75Hz). Phase 1B's
   "inactive" reading does not describe this build. Exp 8's original acceptance is
   unmeetable-as-written; superseded by the direct measurements below.
2. **THE GATING MEASUREMENT: DesktopImageInSystemMemory = TRUE on the IDD output**, never
   flipped, MapDesktopSurface OK, **pitch tight (4096 = 1024*4)**, in BOTH topologies:
   extended (BDA+IDD) and IDD-primary (BDA disabled). With the BDA disabled the IDD moved to
   **adapter 0 output 0 — the exact output the agent captures** — and ddaprobe's
   agent_capture_would_work read TRUE there. **Outcome A, scoped to: D0 driver, WARP
   renderer, 19045, this topology.** (Formal 3x interleaved cold-boot runs still owed for
   the record; every hot measurement today agreed.)
3. **The agent rode every topology change in place** — windows kept, framebuffer re-granted,
   MSG_WINDOW_DUMP re-sent, dom0 window resized to match (2560x1080 → 1024x768 → …). The
   fork's recovery path is load-bearing and works.
4. **D2 (virtual modes): NEGATIVE.** With the IDD owning the desktop, CDS_TEST rejects
   1600x1000 / 2566x1022 / 1234x777 with DISP_CHANGE_BADMODE. The OS offers exactly the
   monitor∩target intersection — measured: {1024x768, 1600x900, 1920x1080} on the IDD.
   **So T2 requires the driver to PUBLISH the desired modes: D3 (runtime UpdateModes spike)
   and/or D4 (dense grid / IOCTL mode store) are the path.** No shortcut exists.
5. **BDA disable → Windows spins up the Basic Display DRIVER fallback** (ROOT\BASICDISPLAY,
   \\.\DISPLAY3, 1024x768-only) rather than leaving the IDD alone — a second attached
   output, but on adapter 1, so the agent's adapter-0 choice still lands on the IDD.
6. **The PnP auto-revert is proven on the REAL target**: with the BDA disabled and the
   marker armed, the boot task re-enabled it (devcon_exit=0, running=True, status readback)
   at 23:42:02. Note: read revert-result.txt via PowerShell (UTF-16; cmd `type` + grep
   silently hid the line — instrument-blindness trap #8 of the day).
7. Cleanup: IDD uninstalled (ROOT\DISPLAY\0000 removed), reboot, BDA-only 3440x1440
   restored and persisted. Guest ends the day at the shipped-like baseline + A1 agent.

Also this session: A2 (readback-authoritative, agent 2525fdd) and A3 (single-source
framebuffer size, assert-only 936c07d control + fix 0dbec23) implemented and CI-built on
branches t2/a2-readback, t2/a3-assert-ctl, t2/a3-single-source — NOT validated yet, that is
next session's exp 4/5 A/B work.

Next decisive step: **D3 spike** — publish one extra target mode at runtime from the driver
and see if the OS picks it up; if not, D4's dense pre-declared grid (needs re-agreeing the
T2 acceptance criterion with the user: "follows to within N px" instead of exact).

# 2026-08-05 — ARBITRARY RESOLUTION END-TO-END: 2566x1022 on the D4 driver, dom0 window follows

The T2 core loop is demonstrated. Driver `t2/d4-registry-modes` (dll D1212687, CI 30949957738):
reads REG_MULTI_SZ `HKLM\SOFTWARE\QubesIDD\Modes` at monitor arrival, appends the entries to
both monitor and target mode lists; reload = devcon restart (replug). Sequence measured:
`guest/resize-sync.ps1 -SyncNow 2566x1022` → registry publish → replug → CDS_TEST turns
SUCCESSFUL → apply → **readback 2566x1022 match=True** →
- ddaprobe on the IDD output at 2566x1022: flag TRUE, MapDesktopSurface OK,
  **pitch 10264 == 2566*4 TIGHT** — the 8-byte-aligned width case that exp 1 could not clear
  is now cleared. The stride killer is dead on this configuration (three widths measured
  tight: 3440, 1400/1024 alignments, and 2566).
- `agent_capture_would_work` TRUE; agent rode the replug; **dom0 window = 2566x1022, live
  pixels** (decoded, non-flat).
Configuration: IDD primary, BDA disabled with the (previously boot-proven) revert marker
armed. The BASICDISPLAY fallback output remains attached at 1024x768 on another adapter;
does not interfere (agent takes adapter 0 = IDD).
Sync loop: `resize-sync.ps1` (loop mode) watches A1's `RESREQ … src=dom0` lines and syncs
exact on snap — the harness prototype; production home is the agent (mode-cache refresh +
IOCTL instead of replug). NOT yet declared done: the user-required stability stress gate
(scratchpad/stress-resize.sh, 16 mixed cycles) is running; D3 spike answer pending; A6
implementation in flight (user approved the design 2026-08-05, "fit tightly").

# 2026-08-05 (final 3) — M6 + A4-lite delivered: blink-free tiles measured, boot tamed

- **M6 (mode-set pre-publish) ACCEPTED BY MEASUREMENT:** the pre-published tile-half applied
  with `RESEXACT 2560x1409 replug=0` — same-millisecond apply, zero monitor churn, no blink,
  no sound; triple-converged (dom0 window == guest == request). Set builder (agent 44e1669):
  target + work-area maximize + tile-half + 1024x768 fallback, deduped, replace-not-append,
  host-size never added by the builder (rule 2); boot publish + one reload (M6BOOT);
  work-area changes recompute registry-only (M6DEFER, no blink). Watcher's real frame
  extents arrived mid-test and the set self-corrected to true tile sizes (2560x1384).
- **A4-lite boot clamp** (agent d6cb5e9): cached boot size clamped to the work-area ceiling
  (sync qubesdb read pre-HandleXconf; honest fallback when no feed). Measured boot: cache
  2100x1100 applied unclamped (correct - within ceiling), fresh daemon window, WM
  re-maximized, guest followed dom0 - authority order preserved end to end.
- **Resize service v3** (user-installed): clears maximized/fullscreen state before resizing —
  the WM-stuck-window failure mode is gone (de-maximize + follow verified live).
- Watcher frame-extents fix live (user-restarted): feed now carries real extents.
Deployed: agent 385EBAEA (stack: staging + exact-follow + never-exit + echo-family gates +
held-frame + M6 + A4-lite), driver 57eb5004. All merged to main.

# 2026-08-06 (cont 2) — M1 DELIVERED: stable EDID, identity churn eliminated

Driver t2/m1-stable-edid (dll 70C64039, on top of D4v3): monitor 0 carries a fixed
128-byte EDID (vendor QBS, product 0x0001, serial 1, preferred 1920x1080@60);
EvtIddCxParseMonitorDescription now serves our EDID with the same base+registry mode list
as the EDID-less path — the v2 failure was exactly the predicted parse-path rejection of
an unknown EDID. ACCEPTANCE, measured live: `Enum\DISPLAY\QBS0001` = exactly ONE instance,
unchanged across two real replug cycles (novel-size snaps applied, guest followed); even
the session GDI name held (\\.\DISPLAY3 both times — stable identity makes Windows reuse
the display source, so the DISPLAY2→30 session churn is gone too). The 7 pre-M1
Default_Monitor phantoms stopped accumulating; one-shot sweeper in progress.

# 2026-08-06 (exp-9 VERDICT) — PASS 6/6 sides: Outcome A formally recorded on the shipped stack

Protocol as specified in PLAN-trackb-t2-modes.md §2.4/§7 row 9: 3 interleaved rounds of
[BDA control, IDD test], COLD BOOT per side, topology asserted with modeprobe --solo and
re-verified twice post-boot, ddaprobe hash-checked against the CI manifest before every run,
activity-gen driving concurrent damage, acceptance evaluated from the JSON (never the exit
code). Raw JSON + per-side reports: instrumentation/exp9/round-{1,2,3}-{bda,idd}.json.

| side | flag | ever_false | map | pitch | dup | agent_ok | adapter0 attached | acquired | access_lost | redup | fmt | session |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1-bda | True | False | ok | 7680=w*4 | ok | True | 1 | 106 | 0 | 0 | 87 | 1 |
| r1-idd | True | False | ok | 7680=w*4 | ok | True | 1 | 146 | 0 | 0 | 87 | 1 |
| r2-bda | True | False | ok | 7680=w*4 | ok | True | 1 | 111 | 0 | 0 | 87 | 1 |
| r2-idd | True | False | ok | 7680=w*4 | ok | True | 1 | 172 | 0 | 0 | 87 | 1 |
| r3-bda | True | False | ok | 7680=w*4 | ok | True | 1 | 118 | 0 | 0 | 87 | 1 |
| r3-idd | True | False | ok | 7680=w*4 | ok | True | 1 | 161 | 0 | 0 | 87 | 1 |

**Verdict: OUTCOME A, formally.** An IddCx *console* driver on Win10 19045 keeps
DesktopImageInSystemMemory TRUE for the whole run, MapDesktopSurface works with TIGHT pitch,
Desktop Duplication is clean (zero ACCESS_LOST, zero re-duplications across 146-172 acquired
frames per test side), and the agent's own output selection lands on the IDD. The BDA control
passed identically every round — the sides are indistinguishable on every acceptance field,
which is the point: the IDD is not a degraded capture source.

**Scope, per §2.4 — do not overstate:** current driver build (D4v3 + stable EDID 70C64039) +
staging-grant agent, WARP renderer, 19045, 1920x1080 solo topology. Near-zero odds of holding
on a guest with a real GPU; a PASS here must not be ported to GPU passthrough.

Track B's gating question is now closed with evidence at the standard CLAUDE.md demands.
Guest left at IDD-primary 1920x1080, BDA disabled, marker disarmed (the intended steady
config); restore a preferred size with a dom0 resize.

---

# 2026-08-06 (blocker) — ISO/CD attach fails: the BLOCK BACKEND in win-idd-mgmt is broken

Symptom: any new qube started with a CD from this qube dies at domain creation,
`libxenlight failed to create new domain`. dom0 log (user-supplied) names the real cause:
`Stubdom NNN startup: startup timed out` + `device model did not start: -9`, with the
stubdom waiting on `vbd .../51760` whose backend lives in domain 121 = win-idd-mgmt.

Isolation performed (each step a separate control):
- brand-new qube, NO cd, NO netvm -> starts fine  => not memory, not dom0, not the VM
- same qube + CD                                   => fails                => the CD path
- ISO on a freshly created loop device (loop1)      => fails                => not stale loop0
- an 8 MB dummy image on loop2 instead of the ISO   => fails                => not the ISO file
- hot `qvm-device block attach` to a RUNNING qube   => "empty response from qubesd"
=> the block backend export from win-idd-mgmt itself is failing for ANY device. It worked
   earlier the same day (win10-fresh installed from loop0), so it broke during this session.

Also found and fixed on the way (my bug): reprovision.sh did not set netvm, so every new
qube inherited the default `fw-net` - a Mirage unikernel whose vif backend never comes up,
which ALSO causes the stubdom timeout. Installs must be offline; use `core-net` (not
fw-net, not sys-firewall - that name does not exist here) for the networking tests.

CONSEQUENCE: the clean-system E2E acceptance (Win10 + Win11), the clean-system regression
run, Windows Update/networked-qube and Office checks are all BLOCKED until the backend
works. No sudo in this qube, so I cannot restart the service; the cheapest fix is very
likely a restart of win-idd-mgmt itself (which also ends the agent session) or a dom0-side
look at qubesd's error.

# 2026-08-06 (defect found by the Office test) — SEAMLESS MODE IS BROKEN ON THE IDD CONFIG

Switching the T2 guest (IDD primary, M6 published mode set) to SeamlessMode=1 produces:
```
SetVideoModeInternal: ChangeDisplaySettings failed: 0xfffffffe   (DISP_CHANGE_BADMODE)
WorkAreaApply: SPI_SETWORKAREA failed with error 0x57
GetFrame: AcquireNextFrame failed 0x887a0026
```
and only ONE window is ever mapped (0x2003c) with Word running - so the Office
compound-window count cannot be taken, and seamless is effectively non-functional here.

Mechanism (from our own code, no guessing needed): `SetSeamlessMode` forces the HOST
resolution on every StartFrameProcessing (main.c ~1888-1897). The host is 5120x1440. The
IDD publishes only the M6 set - target + work-area maximize/half + LRU + 1024x768 - which
does NOT contain 5120x1440, so ChangeDisplaySettings returns BADMODE, the work area cannot
be applied, and capture churns.

This is an INTERACTION between the T2 driver work and seamless mode, not a regression in
either alone: on the stock Basic Display Adapter the host size is always in the 29-mode
list, so seamless always worked. Fix direction (small): when seamless is active the mode
set must include the host size - i.e. `BuildIddModeSet` should add `g_HostScreenWidth x
g_HostScreenHeight` while `g_SeamlessMode` is TRUE. That is consistent with the user's rule
2 ("host-size modes only when the window is actually fullscreen") because in SEAMLESS mode
the guest desktop IS the host-sized surface.

Consequence for the release qualification: the Office compound-window (2A-chrome) check
cannot be run on an IDD-primary guest until this is fixed; it needs either the fix above or
a BDA-primary guest for the seamless test.

## 2026-08-07 — GATE B PASSED: seamless works on the IDD config after a COLD BOOT; merged to main

The seamless host-mode fix (`agent cb1fa4b`, "seamless mode needs the host size in the IDD
mode set") is now demonstrated on the path that matters — a cold boot, not a service restart,
on win-idd-test with the IDD primary and `SeamlessMode=1` set in both registry keys:

| criterion | measured |
|---|---|
| mode entered | `SetSeamlessMode: Seamless mode changed to 1`; QGAPERF frames stream with `mode=s` (seq 715+ and growing) |
| the fix's code path | `BuildIddModeSet: M6SEAMLESS host 5120x1440 added to set` (repeatedly, incl. before the switch) |
| BADMODE | **0** occurrences in the whole log (the pre-fix signature was `ChangeDisplaySettings failed: 0xfffffffe`) |
| resolution followed | `Win32_VideoController`: IddSampleDriver Device **5120x1440** — the host size, actually applied |
| visual | dom0 fullshot: Notepad rendered as its own red-bordered `[win-idd-test]` window (seamless per-window mapping working) |
| process stability | ONE agent instance across the boot (one log file this boot, PID matches log name) |

Non-fatal wrinkles recorded, not gate failures: 8 transient `0x887a0026` (keyed mutex
abandoned) at startup incl. one `StartFrameProcessing: CaptureInitialize failed` — survived
in place (A7 retry class), no respawn; and `WorkAreaApply: SPI_SETWORKAREA failed 0x57`
twice early in the boot. Both are open items, neither blocks seamless function.

Merged: driver repo `t2/seamless-build` → main (9436282), agent submodule bumped to cb1fa4b.

ALSO: the intended-state device topology, measured for the health gate's allowlist:
IDD `ROOT\DISPLAY\0000` err=0; VGA `PCI\VEN_1234&DEV_1111` err=22 (ours, deliberate);
`XENBUS\VEN_XP0001&DEV_CONS` and `…DEV_VBD` err=28; `XENVIF\VEN_XP0001&DEV_NET\0` err=28
**with the adapter Up and functional** — the last one is unexplained and deliberately kept
OFF the health-check allowlist so the sweep surfaces it.

## 2026-08-07 — health gate VALIDATED both ways; it immediately caught two real things

`guest/health-check.ps1` (replaces the hash-only clean-path gate) now demonstrated per the
instrument rule — seen to FAIL on a defective build and PASS on the intended state:

- **win10-clean (degraded, no IDD)**: ok=false, failed = idd_device_bound (device ABSENT),
  desktop_on_idd, idd_modes_published — exactly the missing function the hash gate scored
  green on 2026-08-06. agent_binary_hash still passes there, proving the two gates measure
  different things.
- **win-idd-test (intended state)**: every check passes except the deliberate XENVIF
  surface (below). PnP allowlist works in both directions.

Instrument bug found while validating (would have made the sweep never-allowlist anything):
once `Get-PnpDevice` has loaded the PnpDevice CDXML module, `Win32_PnPEntity
.ConfigManagerErrorCode` STRINGIFIES as the enum label (`CM_PROB_FAILED_INSTALL`), not the
number, so a string compare against '28' silently fails. Fixed with `[int]` on both sides.
Debugged by instrumenting the real script - an isolated replica of the same loop PASSED,
because the replica never called Get-PnpDevice first.

**Catch #1 — PV NETWORK IS NOT ACTUALLY BOUND on win-idd-test.** The gate refused to
allowlist `XENVIF\VEN_XP0001&DEV_NET\0` err=28, and following it up:
`Get-NetAdapter` shows the active NIC is **Realtek RTL8139C+ (emulated)**, while xenvif
(the PV bus) runs and enumerates the vif child that xennet never binds — despite
ADDLOCAL=...,PvDriversNetwork and xenvif.inf+xennet.inf present in the driver store.
So the 2026-08-06 "networking + Windows Update zero issues" result was real but ran over
the EMULATED NIC, not PV. Re-scoped accordingly: function works, PV path does not.
Whether stock QWT 4.2.2 behaves identically on this platform needs a control before this
counts as our defect. Open item for the release notes either way.

**Catch #2 — the IDD's declared EDID physical size changes the guest's DPI per mode**
(user observed it visually). At host-size 5120x1440 Windows computed the PPI from our
EDID's 60x34 cm and silently switched recommended scaling to 150 % (LOGPIXELSX=144, no
user override present). Previous lower-res runs sat at 100 % — so apparent DPI changed
between runs. Fix in driver/IddSampleDriver/Driver.cpp: image size declared UNDEFINED
(bytes 21-22 and DTD 66-68 zeroed, checksum 0x53→0x78) which pins the recommendation at
96 DPI for every mode; per-monitor user overrides persist via the M1 stable identity.
Needs the next driver build to take effect.

## 2026-08-07 — CLEAN-PATH ACCEPTANCE: install PASSED, health gate FAILED. /idd is not release-ready

First clean-path run on minimal-repack media (vendor ISO `edc53c5c…`, delta manifest beside
the image). Reported honestly, because the install half genuinely worked:

**PASSED** - the install itself, on a guest that had never seen QWT (`existing_qwt: []`):
qrexec answered after 1314 s (proving OUR package delivered it), `ok:true`,
`payload_files_verified: 20/20`, agent hash == manifest (`b758dd92…`), and the IDD
activation sequence ran exactly as designed:

    devcon: Drivers installed successfully.
    IDD devnode up: ROOT\DISPLAY\0000; waiting up to 30 s for its display adapter
    IDD display adapter present: IddSampleDriver Device
    disabling emulated VGA adapter: PCI\VEN_1234&DEV_1111...
    IDD ACTIVATED

Also confirmed: the answer file WAS read off the repacked media (Setup went straight to
"Installing Windows", no locale picker) and `diskprep.cmd` selected the 80 GiB disk by size.

**FAILED - `desktop_on_idd`.** After the reboot the desktop runs on **Microsoft Basic
Display Adapter at 3440x1440** while the IDD sits **offline** (`Availability=8`, no
resolution). Re-measured after settling: identical, so it is not a sampling race.

The confusing part, measured directly: the VGA disable DID persist -
`PCI\VEN_1234&DEV_1111... err=22`, `ConfigFlags=1` (CONFIGFLAG_DISABLED) - and
`ROOT\BASICDISPLAY\0000` is present at err=0. So Windows disabled the PCI adapter as asked
and then drove the desktop through the Basic Display **driver** fallback instead of
attaching the IDD. Disabling the VGA is therefore NOT sufficient to make the IDD the
desktop: an IddCx monitor arrives INACTIVE and something must still activate it
(SetDisplayConfig / topology apply). Our installer never does that step - it assumed the
VGA disable was enough. On win-idd-test the IDD-primary state was reached through the
2026-08-05 experiment sequence, not through this installer path, which is why it was never
caught before.

**Then the guest WEDGED.** Shortly after the health probes, win10-clean stopped answering
qrexec. Forensics captured automatically before any kill (`evidence/wedge-win10-clean-031334`,
domid 884): **zero active grant entries** - the revoke-spin signature in
`docs/upstream-xen-pv-grant-revoke-spin.md`. **Causation NOT established**: this wedge class
has been seen without the IDD, so "the IDD activation caused it" is a hypothesis, not a
finding. What IS established is that this configuration (IDD bound but offline, desktop on
the fallback) reached a wedge within minutes of first boot.

### Release decision (mine, evidence-backed)

`/idd` comes OUT of the default unattended payload and stays an explicitly opt-in,
documented flag. Justification: on a clean install it currently produces a guest whose IDD
is installed and bound but NOT driving the desktop - i.e. no arbitrary-resolution support in
practice, the very defect the flag was added to fix - and that guest wedged. Shipping it on
by default would make every clean install worse than the plain Basic Display Adapter build,
which at least is stable. The activation gap (topology apply after reboot) is now a named,
reproducible bug with a clear fix direction rather than an unknown.

## 2026-08-07 — WIN11 CLEAN-PATH ACCEPTANCE: health gate PASSED 8/8 with the FULL IDD assertion

`win11-fresh`, Windows 11 24H2 build **26100**, installed unattended from the UNTOUCHED
vendor eval ISO (`755a90d4…`) via minimal-repack media, guest never had QWT:

- install: `ok:true`, agent hash == manifest (`b758dd92…`), package
  `4.2.2+agent.018ec54d1584`, qrexec answered after 2009 s (so OUR package delivered it),
  LabConfig TPM/SecureBoot/RAM/CPU/Storage bypasses worked, `diskprep.cmd` picked the disk.
- health gate, run WITHOUT `-NoIddExpected` (the full assertion): **8/8 pass**, and
  decisively `desktop_on_idd` PASSED - `IddSampleDriver Device` is the ONLY active
  controller (1920x1080, Availability 3) while `Microsoft Basic Display Adapter` is
  Availability 8 (offline). `non_idd_active = 0`. Modes published: 5120x1440, 1024x768.

**This inverts the conclusion I drew two hours ago.** I predicted the activation gap would
reproduce on Win11 and treated it as platform-independent. It does not: **`/idd` activation
works end to end on Win11 24H2 and fails on Win10 19045.** Same installer, same package,
same activation sequence, opposite outcome - so the defect is in how Win10 19045 responds to
"PCI VGA disabled + IddCx monitor present": it spins up the ROOT\BASICDISPLAY fallback and
leaves the IDD offline, where Win11 attaches the IDD.

Corroborating datum that this is not "Win10 cannot do it": win-idd-test IS Win10 19045 and
runs IDD-primary at 5120x1440 (Gate B, same day). It reached that state through the
2026-08-05 manual experiment sequence, not through the installer - so on Win10 something in
that sequence performs the activation the installer omits. That is the fix's target.

Release stance UNCHANGED for now (`/idd` stays opt-in, out of the default payload): a Win10
user would still get the degraded, wedge-prone state, and Win10 is the more common target.
But the write-up must say what is true - verified working on Win11 24H2, broken on Win10
19045 via the installer path - rather than "broken".

### Win11 visual step: dom0 SERVICE limitation, not a product failure (do not misread this)

The Win11 run ended `ACCEPT=FAIL reason=screenshot service returned empty tar`. That is NOT
a guest defect. Guest-side evidence, which does not depend on dom0 policy:

    MAPS=4                              (SendWindowMap x4)
    QGAPERF,v=2,seq=7032,...,mode=s,...,win=2      seamless, 2 windows mapped, streaming
    QGAPROTO,msg=SYNTHPAINT,hwnd=0x10284,owner=0x201a6   popup synthesis working
    vchan connected (blocking read on an idle channel)

So the Win11 guest is in seamless mode with windows mapped and frames flowing. The per-VM
`local.WinScreenshot+win11-fresh` returns 0 bytes because the dom0 screenshot service does
not serve `win11-fresh` (its allowlist names win-idd-test / win10-clean / win10-e2e, as seen
when the wedge service was installed). `fullshot` confirms it: the geometry it returns lists
win-idd-test's windows, not win11's.

**Needs one dom0 action from the user** to close the visual acceptance on Win11: add
`win11-fresh` to the screenshot service's allowlist (or reinstall it with the tag-based
policy so any `win-idd-testbed`-tagged qube is served). Until then Win11 visual acceptance is
UNPROVEN-BY-TOOLING, and is recorded as such rather than as a pass or a failure.

## 2026-08-07 — RETRACTION: the Win10 /idd symptom is NOT "falls back to ROOT\BASICDISPLAY"

I wrote that four times (FINDINGS, RELEASE-QUALIFICATION-STATUS, two mgmt scripts, the
release notes) and it is wrong. The archived post-reboot measurement of the failing Win10
guest actually says:

    PCI\VEN_1234&DEV_1111   ConfigManagerErrorCode = 22 (CM_PROB_DISABLED)   <- disable DID persist
    PCI\VEN_1234&DEV_1111   Availability = 3 (Running), 3440x1440            <- SAME device drives the desktop
    ROOT\BASICDISPLAY       absent from the controller list entirely

Both the emulated VGA and the ROOT fallback carry the friendly name "Microsoft Basic Display
Adapter"; I read the name and never checked the PNPDeviceID. The desktop stays on the
EMULATED VGA, which keeps driving video while its devnode is marked disabled. Windows did not
"fall back" to anything.

ROOT CAUSE (this part of the hypothesis survives, with a different mechanism):
**nothing in the package ever performs a display-topology apply.** The /idd sequence is
pnputil -> devcon create root devnode -> wait for a Win32_VideoController -> Disable-PnpDevice
on the PCI VGA -> reboot. An IddCx monitor arrives CONNECTED but INACTIVE (Availability=8,
null resolution) and is not attached to the desktop until a CCD topology apply names its path.
No such call exists anywhere in the package - not before the reboot, not after. The persisted
topology therefore still names only the VGA path at next boot, so Windows drives that rather
than leaving the box headless. The installer's comment at Install-QwtImproved.ps1:740 -
"Activation happens HERE, right before the stage-2 reboot" - encodes the false assumption.

Decisive corroboration: `win-idd-test` is the SAME Win10 19045 build and DOES run IDD-solo,
but it got there via `tools/modeprobe --solo`, which performs exactly the missing step
(detach every other display, CDS_SET_PRIMARY|CDS_UPDATEREGISTRY on the IDD, commit). Win11
24H2 reaches the same end state from the identical installer, so Win11 performs or persists
the apply on its own. The Win10/Win11 difference is NOT driver-side: the IddCx driver has zero
OS-build branches and no version mismatch (verified in driver/IddSampleDriver/Driver.cpp).

FIX (not yet implemented): do the topology apply in the GUI AGENT at startup, before it maps
the screen - QueryDisplayConfig(QDC_ALL_PATHS), find the target whose
DISPLAYCONFIG_TARGET_DEVICE_NAME matches the Qubes IDD, mark ONLY that path active and every
other path inactive, then SetDisplayConfig(SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG |
SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES). Marking the others inactive is what keeps the IDD
the SOLE output, so the desktop bounding box does not grow and seamless coordinates hold.
It must NOT go in the installer's SYSTEM ONSTART task: session 0 gets ERROR_ACCESS_DENIED.

## 2026-08-07 — Win10: IDD is the SOLE active output after cold boot; all three assert together

Clean-room install (untouched vendor ISO + USB answer stick), then a VERIFIED cold boot
(guest confirmed Halted before start; guest uptime 3 min at check time).

Install trailer, stage2-install ok:true:
    addlocal   PvDriversCore,Core,Gui,PvDriversNetwork,PvDriversDisk
    pv_xenvif  installed
    idd_driver activated (ROOT\DISPLAY\0000), VGA disabled
    installed_gui_agent_sha256 == expected_gui_agent_sha256

Health gate: **12/12, ok=True, asserted_all=True, not_applicable=<empty>** - disks, network
and display all measured in the SAME run:
    agent_binary_hash, agent_process, qubes_services_running, idd_device_bound,
    desktop_on_idd, idd_modes_published, pnp_no_unexpected_errors, agent_log_healthy,
    pv_drivers_bound, pv_disk_bound, network_carries_traffic, clipboard_works

Measured end state (pushed script, not a quoted one-liner):
    DEV OK     ROOT\DISPLAY\0000                        <- IDD
    DEV Error  PCI\VEN_1234&DEV_1111...                 <- VGA disabled
    SCREEN \\.\DISPLAY2 primary=True 1920x1080          <- exactly ONE active screen
    VC IddSampleDriver Device          avail=3 1920x1080
    VC Microsoft Basic Display Adapter avail=8
Exactly the inverse of the pre-fix state (VGA avail=3 at 3440x1440, IDD avail=8).

### HONEST LIMIT: the deliberate-reintroduction test is still INCONCLUSIVE

CLAUDE.md requires a check to be SEEN TO FAIL on a build carrying the defect before its PASS
counts. Two attempts did not achieve that, so `desktop_on_idd`'s PASS is recorded as
**supported by a before/after control, but NOT yet validated by falsification**:

 1. NoTopologyApply=1 + cold boot -> STILL PASSED. Cause is my own design:
    EnsureQubesIddSolo applies with CDS_UPDATEREGISTRY, which PERSISTS the topology, so a
    previously-applied solo survives reboots even when the apply no longer runs. Disabling
    the apply cannot revert an already-persisted topology.
 2. Attempt 2 also re-enabled the VGA to tear the persisted topology down, but neither the
    reg add nor the Enable-PnpDevice echoed a success line, so the ARM step is UNCONFIRMED,
    and the run then aborted on the second cold boot. Nothing can be concluded from it.

What DOES support the fix: the same installer on the same Win10 19045 build, WITHOUT the
agent change, left desktop_on_idd FAILING with the VGA driving the desktop (evidence dirs
accept-win10-clean-20260807-023437). That is a real control, one rep.

TODO before the release write-up claims this check is validated: reproduce the pre-fix state
properly - arm the kill switch AND reset the persisted CCD topology (re-enable the VGA and
make it primary), each step VERIFIED to have executed - then cold boot and require FAIL.

## 2026-08-08 — benchmark orchestrator targeted the wrong VM (caught pre-run)

`bench-interleaved.sh` passed `BENCH_VM=$vm`, but `benchmark.sh` reads **`QTEST_VM`** and
defaults to `win-idd-test` (benchmark.sh:112). Both sides would therefore have been pointed at
a third, stale guest.

HONEST SCOPE OF THE CONSEQUENCE: `win-idd-test` was Halted, and `benchmark.sh run` checks
`guest_alive` first, so the actual outcome would have been REP FAILURES, not silently false
numbers. I initially wrote that it would have produced "plausible nonsense" - that was
overstated. It becomes exactly that only if the stale guest happens to be running, which is a
coin flip, not a safeguard.

Fixed by passing `QTEST_VM`, plus a guard that refuses to benchmark any VM other than the two
under test, so a future mis-wiring aborts loudly instead of depending on which guests are up.

## 2026-08-09 (later) — RETRACTION: the elevated swap does NOT work on win11-idd-test

HANDOVER.md claims "win11-idd-test has stock 4.2.2 with a `.orig` backup, so swap ours in,
measure, restore" and "Elevation is available: guest/run-elevated.ps1". Both are FALSE for
this guest, measured today:

- `run-elevated.ps1` fails at `schtasks /create ... /rl HIGHEST` with **Access is denied**.
  Directly confirmed: an unelevated LIMITED task creates fine (RC=0), a HIGHEST task is
  denied. The `user` token is fully UAC-filtered here: `whoami /groups` shows
  **Medium Mandatory Level** with `BUILTIN\Administrators` as **deny-only**;
  `EnableLUA=1`, `ConsentPromptBehaviorAdmin=0x5`, `FilterAdministratorToken`/
  `LocalAccountTokenFilterPolicy` unset.
- There is **no `.orig` backup** on win11-idd-test (`gui-agent.exe.orig` absent) — swap-agent
  never ran there, because it can never elevate there.

Root cause of the bad handover claim: the swap was only ever *verified* on **win10-clean**
(`verify-elevated-swap.sh` runs there), and Win10's default UAC posture let the HIGHEST-task
trick through. It was extrapolated to Win11 without testing. Win11 built from
`autounattend-win11.xml` keeps UAC fully on, so the trick does not work on ANY Win11 guest
from that answer file — not just this one.

Consequence: `ours-vs-stock-one-guest.sh` / `stock-remeasure-1guest.sh` cannot run on
win11-idd-test as written — the swap silently no-ops and the harness would (correctly) refuse
the ours reps on the hash check. The single-variable Win11 stock-vs-DDA comparison is BLOCKED
on elevation, pending a decision (bake `EnableLUA=0`, test-rig-only, into the answer file and
reprovision one reusable stock guest; or credentialed schtasks, which the dev-qube safety
classifier blocks). Roadmap item N1 (the swap loop) inherits this: it must be fixed at the
answer-file level for Win11, not assumed working.

---

## 2026-08-09 (evening) — THE STOCK COMPARISON, AT LAST. It does not say what we hoped.

First single-variable ours-vs-stock measurement in the project's history: ONE guest
(`win11-idd-test`, rebuilt today with genuine stock QWT 4.2.2 + `EnableLUA=0`), our agent
swapped in and out IN PLACE via the elevated scheduled-task path, hash-verified every rep,
5 rounds interleaved, classic Notepad both sides.

**GATE: ddacap=2293, pwcap=13 -> the DDA fast path served 99.4% of captures, zero refusals.**
This is a clean read of the feature working as designed, not a fallback measurement.

| metric | stock 4.2.2 | ours (DDA, cond C) | delta | worst spread | verdict |
|---|---|---|---|---|---|
| typing | 2.188 | 4.381 | **+100.3%** | 62.8% | **REAL — distributions do not overlap** |
| drag   | 12.314 | 11.727 | −4.8% | 34.6% | inside noise — NO verdict |
| scroll | 4.369 | 5.158 | +18.0% | 42.5% | inside noise — NO verdict |

    typing stock [1.400 1.867 2.188 2.333 2.651]   ours [3.042 3.756 5.007 5.795]
    drag   stock [11.396 12.174 12.314 12.331 12.952] ours [9.359 10.784 12.669 13.421]
    scroll stock [3.426 4.070 4.369 4.383 4.843]   ours [4.688 5.152 5.163 6.879]

Typing is the one robust result: **every** ours rep is worse than **every** stock rep
(ours min 3.042 > stock max 2.651). Our agent costs 2x stock on typing CPU. Drag and scroll
differences are smaller than the run-to-run spread and prove nothing in either direction —
the harness's own "BEATS STOCK" tag on drag (0.95x) is NOT supported and must not be quoted.

n=4 on the ours side: `ours-ro3`'s CPU sampler produced no samples, correctly emitted as
`{"na": ...}` rather than 0.

### RETRACTION — what the −67% actually meant

HANDOVER.md's headline ("DDA-sourced capture is a large, measured win: typing −67%") compared
**our binary against ITSELF** with DDA disabled (condition D, typing 12.427). It never compared
against stock. Stock is 2.188. So the honest statement is:

  our build without DDA   12.427   (5.7x WORSE than stock)
  our build with DDA       4.381   (2.0x worse than stock)
  stock 4.2.2              2.188

DDA removes most of an overhead THE FORK ITSELF INTRODUCED. It does not make the fork faster
than what it forked. The ship gate's "publish as a performance bugfix" framing is withdrawn:
on typing, this build is a regression against stock and must not ship as-is.

### The one confound still open, and it is testable

Our build writes a QGAPERF record per frame (`g_PerfEnabled`, gated by the `PerfLog` registry
DWORD, perf.c:89); stock emits none BY CONSTRUCTION (benchmark.sh's own header says so). So
this compares an instrumented build against an uninstrumented one, and an unknown share of
the +100% typing cost is logging, not the feature. Next experiment: same binary, `PerfLog=0`,
third interleaved side — verified by HASH (the binary is ours) plus the ABSENCE of QGAPERF
records (logging really is off). That splits "our code is slower" from "our logging is slower",
which is the difference between a redesign and a build flag.

## 2026-08-09 (night) — SWEEP FIX VERIFIED: idle floor gone, typing at/below stock reference

One binary (agent 92C48AC55CF96D4B = submodule e0cd9c4 sweep fix + 09b643e version bump),
marker-toggled A/B on win11-idd-test, 3 rounds interleaved E,N; cold boot included (the
guest started Halted); hash gate passed on all 6 reps; DDA served throughout (ddacap sums
363-2528 per rep vs pwcap 2-27). E = SweepDdaExempt active (default), N = marker
qga-sweepdda-off present = the pre-fix behaviour deliberately re-introduced.

    phase        E (fix)   N (defect)   stock ref   before-fix ref
    idle pooled    0.83       2.86        0.57         3.04
    typing         1.71       3.93        2.02-2.19    4.38
    drag           8.67      13.15       12.31        11.49-11.73
    scroll         3.51       5.51        4.37         5.16-5.44

- The defect-reintroduced control REPRODUCES the pre-fix numbers (idle 2.86 vs 3.04,
  typing 3.93 vs 4.38): the check has been seen to fail on the defective configuration,
  so its pass is proven meaningful (autonomy rule 5 satisfied).
- Typing separates COMPLETELY per-rep: every E rep (max 2.35) is below every N rep
  (min 3.33). Idle separates on phase means in all four idle windows (pooled 0.83 vs
  2.86); individual 2-5 s idle windows overlap once (1.60 vs 1.25) - short-window
  sampler quantisation, the pooled picture is unambiguous.
- Against the stock REFERENCE (previous run, same guest/harness/phases, not interleaved
  today - claim accordingly): idle 0.83 vs 0.57 (parity within the sampler's floor),
  typing 1.71 vs 2.02-2.19 (at or below stock), drag 8.67 vs 12.31 (~30% below), scroll
  3.51 vs 4.37 (below). The honest headline: THE FORK NO LONGER COSTS MORE THAN STOCK ON
  ANY MEASURED PHASE, and the 2x-typing verdict is repaired at its root cause. A fresh
  interleaved ours-vs-stock run would make the stock comparison ironclad; the E-vs-N
  separation needs no such caveat.
- Not yet in any released artifact: released builds still carry the burn until the next
  release (prepare-but-hold per the owner, 2026-08-09).

## 2026-08-11 (cont.) — REPRODUCED a Start-menu-breaks-under-IDD bug on win11-fresh (24H2); it is a SIBLING of GWeck's, not identical

Goal: reproduce GWeck's S1 (Win key -> garbled/no menu + dom0 "suspicious GUI request" dialog) on
win11-fresh with IDD active. Result: reproduced the USER-FACING breakage (no usable Start menu) via a
concrete, different-from-hypothesized mechanism; did NOT reproduce the dom0 dialog; and FALSIFIED the
workflow's leading S1 theory on this guest.

Setup confirmed: IddSampleDriver Device = OK/active, Basic Display Adapter = Error/disabled; desktop
\\.\DISPLAY2 = 0,0,5120,1440.

FALSIFIED here: the "EnumDisplaySettings fails on IDD -> divide by dmPelsWidth -> INT_MIN -> MSG_CREATE
negative width -> daemon VERIFY dialog" chain. On win11-fresh the agent math (main.c:750-760) runs CLEAN:
EnumDisplaySettings OK, pels=5120x1440, dmPosition=0,0, scale=1.0, all rects positive. No INT_MIN, no
negative dims, no dialog. So GWeck's dom0 dialog is 25H2-specific and needs a different trigger (still open).

REPRODUCED (live gui-agent log + fullscreen dom0 shot, evidence in scratchpad (local only, dom0 shot leaks other qubes - not committed)
scratchpad local shot): press Win ->
- The Start CoreWindow (0x1018a, cls Windows.UI.Core.CoreWindow title "Start") is PARKED OFF-SCREEN at
  16384,6119 (=0x4000, the classic Windows park coord); DWMWA_EXTENDED_FRAME_BOUNDS agrees. Size ~5120x1384.
- It carries a COMPLEXREGION clip (GetWindowRgn type 2), box (window-relative) 2131,502,2989,1392.
- GetRealWindowRect adds the parked origin to the region: 2131+16384=18515 -> announces the Start card at
  ~18515,6621 (858x874), ENTIRELY OUTSIDE the 5120x1440 desktop. The g_StartWindow border fixup
  (main.c:792-801) operates on the already-off-screen rect.
- The reported size then FLIP-FLOPS 5120x1384/1392 <-> 858x890 <-> 858x874 several times in ~2s (region
  present vs momentarily absent as the open animation plays). Each flip = PwResizeWindow grant rebuild
  (detach+reattach) + a SendWindowUnmap+SendWindowMap pair. A MAP/UNMAP/grant STORM.
- Interleaved: "GetRealWindowRect failed 0x80070006 The handle is invalid" every ~1.5s, and finally
  "HandleConfigure: window 0x1018a not tracked" - dom0's configure echo races in after the agent already
  unmapped it. Net: Start ends UNMAPPED; dom0 renders NO Start menu (fullscreen shot shows the guest
  console but no menu). = GWeck's "Windows key -> no usable menu."

Root cause (24H2 path): the agent tracks the Win11 Start CoreWindow which is parked off-screen, then
double-counts the parked origin into its window-relative clip region, announcing an off-desktop window,
and thrashes its size as the region blinks. Distinct from GWeck's 25H2 path where there is NO
CoreWindow (winenum: Wnd_StartFeed instead), so g_StartWindow=FindWindow("Windows.UI.Core.CoreWindow",
"Start")=NULL and all Start special-casing is DEAD - his full-screen Wnd_StartFeed is instead accepted
as a plain window (IsPopup full-screen demotion, main.c:826) and PrintWindow-garbled. Same symptom
class ("no usable Start under IDD"), two different code paths.

Candidate fix (general, safe, helps both): reject/clamp any window whose computed rect lies ENTIRELY
outside the desktop bounds (left>=screenW or top>=screenH or right<=0 or bottom<=0) before MSG_CREATE/
MAP - an off-screen announce is never useful and is the shared failure. Plus: don't thrash - coalesce
the region-blink size flapping. NOT YET IMPLEMENTED (instrument-first; needs the coalescing designed so
it does not regress legit fast resizes). The dom0 dialog (25H2) remains unreproduced - needs a 25H2 target.

## 2026-08-11 (cont.) — REPRODUCED, and it is SEVERE: Start-menu flip storm KILLS the capture thread (frozen display)

Followed the user's "reproduce before fixing". The negative-width MSG_CREATE (dom0 "suspicious GUI
request" dialog) did NOT reproduce on win11-fresh/24H2 (8202 tight-loop samples of the agent's exact
GetRealWindowRect math while hammering Start: only cloaked DummyDWMListenerWindow 0x0 noise, zero
strictly-negative, zero huge, zero off-screen-with-real-size). That dialog stays 25H2-specific
(user: update the test guest to 25H2 later to confirm nothing else broke).

What DID reproduce, in the REAL gui-agent, repeatedly, and it is worse than a cosmetic flip:
1. Start-open -> the agent thrashes the Start CoreWindow 0x1018a: reported size FLIPS between full
   desktop (5120x1392/1384) and the region-clipped card (858x890/858x874) across UpdateWindowData
   passes, each flip a PwResizeWindow grant rebuild (detach+reattach) + a SendWindowUnmap+SendWindowMap
   pair. Root: GetWindowRgn on the animating Start window returns COMPLEXREGION vs none frame-to-frame,
   so the clip is applied then dropped. Captured live at 16:20:45 and 16:23:49.
2. Under rapid Start toggling (16:51) the storm FLOODS the vchan:
     16:51:50 HandleServerData: got unknown msg type 127, ignoring  (x5)
     16:51:51 VchanSendBuffer: vchan buffer full, blocking write
     16:51:51 CaptureThread: error/timeout waiting for frame processing
3. THE CAPTURE THREAD DID NOT RECOVER. Liveness check at 16:58 (7 min later): opened notepad -> the
   agent emitted ZERO new frames (log last-modified frozen at 16:51:51, no PerfEmitFrame, no window
   event). The guest desktop in dom0 is FROZEN. qrexec still works; only the display pipeline is dead.
   RecreateDuplication (the intended capture-death recovery) never fired - a SECOND defect.

So the Start-menu-under-IDD failure GWeck reports is, on our side, a self-inflicted map/unmap STORM
that can back up the vchan and permanently wedge the capture thread = frozen/garbled guest. This is a
DoS of the guest display triggerable by normal Start-menu use. Distinct from (but same family as) the
2A-chrome window-classification issue.

Fix direction (now EVIDENCE-BACKED, not blind): (a) stop the flip - do not oscillate a window's
reported size when its clip region blinks; treat a transient no-region frame as "keep previous
geometry" (debounce/coalesce), and/or don't grant-rebuild + remap on every size wobble; (b) the
off-desktop announce (parked 16384,6119 -> card at ~18515,6621) should be clamped/rejected; (c)
capture-thread recovery must actually fire on the vchan-full/timeout path (RecreateDuplication or
restart), not silently die. NOT YET IMPLEMENTED. Guest left wedged by the repro; recovering via agent
restart next (also validates the recovery path).

## 2026-08-14 (evening) — GWeck's 4.3.1 reports: the escape hatch, and one root cause found by running it

Trigger: forum 42717 posts 54/55/56, the last of which (16:15 today) is new since the handover.
Post 54 is the severe one - Windows 10 22H2 with 4.3.1 comes up after the IDD-activation reboot
as "only a black inactive window", the Windows key does nothing, applications will not start,
shutdown from the Qube Manager does not work, and killing the qube brings the same black window
back. Post 56 adds that AppVMs based on that Win10 template start and then shut down silently.
Post 55: the SAME machine on 09b643e with Open-Shell is completely fine on both Win10 22H2 and
Win11 25H2. He asks for /noidd.

### Shipped today (proven on win11-fresh, by pixels, not by logs)

* `install.cmd /noidd` - fresh install, never activate the IddCx driver (-NoIddDriver existed
  but was reachable only by hand-editing a command line).
* `install.cmd /iddoff` + `guest/deactivate-idd.ps1` - the RECOVERY path: NoTopologyApply=1
  first so the agent cannot re-detach the VGA, then re-enable the VGA, then remove the IDD
  device, then reboot. It deliberately avoids ChangeDisplaySettingsEx so it runs over qrexec
  from dom0 on a guest with no usable display, which is the only situation it exists for.
* `install.cmd /iddonly` now clears NoTopologyApply, or re-activating after /iddoff would
  create the device and never attach it.
* install.cmd names the file a switch needs when it is not on the medium.

MEASURED round trip on win11-fresh (Win11 26200, IDD active at 5120x1440):

    install.cmd /bogus       -> "Unknown option", the new options listed          PASS
    install.cmd /updatesonly -> names the missing file and where it looked        PASS
    install.cmd /iddoff      -> VGA enabled, ROOT\DISPLAY\0000 removed, reboot    PASS
      after reboot: ATTACHED=1 Microsoft Basic Display Adapter 3440x1440,
      agent logs "IDD solo: DISABLED by NoTopologyApply=1", Notepad renders
      in dom0 (screenshot, not a log line)                                        PASS
    install.cmd /iddonly     -> IDD device recreated, VGA disabled, reboot        PASS

### ROOT CAUSE FOUND: /iddonly could never have worked, and it is a quoting bug

The first /iddoff run failed with `IDD DEACTIVATION FAILED: Illegal characters in path`.
Cause: `%~dp0` ends with a backslash, so `-Root "%HERE%"` reaches PowerShell as `-Root
"C:\path\"` - and PowerShell's argument parser reads `\"` as an ESCAPED QUOTE. The script
receives `C:\path"`, with a trailing quote character, and every path built from it is invalid.

This is not a new defect: win11-fresh's own `C:\qwt-idd-activate.log` from 2026-08-11 records

    IDD ACTIVATION FAILED: C:\qwtc"\idd-driver holds 0 .inf files (expected exactly 1)

- the same stray quote, sitting in the log for three days. So the earlier triage of GWeck's
post-35 `/idd` report (user error + the script not shipping) was incomplete: there is a THIRD,
independent cause, and it would have broken /iddonly even on a medium that carried the script.
Fixed by passing `%HEREQ%` (the directory without its trailing backslash) into every script.

Process note: this was found by RUNNING the switch on a guest, not by reading it. The same code
had been read several times today.

### The agent fix, and what could NOT be proven

`EnsureQubesIddSolo` detached every other display first and only then tried to make the IDD
primary, both with CDS_UPDATEREGISTRY. If the second step failed, the guest would be left with
no attached display AND that state persisted for the next boot - which matches post 54 exactly,
including surviving a kill. The failure is reachable in principle: an IddCx adapter enumerates
as soon as its devnode starts but has no mode list until its monitor arrives, and the agent is
started very early by the watchdog service.

Added: (1) a readiness gate - refuse to touch the topology until the IDD publishes a mode,
returning ERROR_NOT_READY, retried for 20 s at startup; (2) a rollback that re-attaches exactly
what was detached, with its previous mode and primary flag; (3) SoloFaultInject, a registry hook
that makes the apply fail on purpose, so the guard can be seen to fail (=2 suppresses the
rollback, i.e. the pre-fix behaviour).

FALSIFICATION ATTEMPT, and it did not succeed. On win11-fresh, with the precondition built and
ASSERTED (IDD detached, VGA attached and primary) and SoloFaultInject=2:

    IDD solo: found IDD adapter '\\.\DISPLAY2', attached=0 primary=0
    IDD solo: detach '\\.\DISPLAY5' -> -2            <- DISP_CHANGE_BADMODE
    IDD solo: set-primary '\\.\DISPLAY_QUBES_FAULT_INJECT' -> -5, commit -> 0
    IDD solo: '\\.\DISPLAY5' is STILL attached
    IDD solo: FAILED - idd attached=0 primary=0, others still attached=1

**Windows refused to detach the last attached display.** So on Win11 26200 the headless state
is structurally unreachable by this path, the rollback never ran, and its PASS is therefore
UNPROVEN - recorded as such. Whether Win10 19045 enforces the same rule is not known here and
is exactly what a Win10 rig would settle. The readiness gate stands on its own reasoning (never
attempt an apply the IDD cannot accept) and is cheap; the rollback stays as defence in depth.

An earlier run of the same experiment was VOID: modeprobe's JSON field is `device_name`, my
harness read `.name`, so `--solo` never ran and the precondition was never established. The
assertion added afterwards caught the next attempt and aborted it instead of producing a
confident wrong answer.

### GWeck is 53 agent commits behind, including the fixes for what he reports

`git log c7ccb459..HEAD` in agent/ is 53 commits. Among them: 8be83b8 (2026-08-12) makes the
agent adopt the size Windows APPLIED instead of the size it requested - that is the diagnosed
cause of his S2 "mouse pointer ~1 cm below where the system thinks it is", and it landed two
days after the release he is running. Also the whole 25H2 shell-surface series (toastcrop,
shell-managed Start, the geometry sanitizer) and the drag work. His 4.3.1 predates all of it.

CONSEQUENCE: the highest-value action for him is a new release, not more diagnosis of 4.3.1.

### Win10 diagnosis is BLOCKED on a rig, and the reason is recorded

win10-clean cannot run anything elevated - measured, not assumed:

    schtasks /Create /RL HIGHEST (guest/run-elevated.ps1)  -> ERROR: Access is denied
    qrexec qubes.VMRootShell                               -> Request refused (no such service)
    qrexec qubes.VMShell+SYSTEM                             -> runs as win-idd-test\user,
                                                              Medium Mandatory Level
    EnableLUA=1, ConsentPromptBehaviorAdmin=5, no consent UI reachable

So the IDD cannot be installed or activated there, and GWeck's platform cannot be reproduced on
the rig we have. A fresh Win10 with EnableLUA=0 is needed (the USB answer-stick route works and
is cheap - FINDINGS 2026-08-07), but it requires creating/removing a qube, which the harness
refuses without the user's approval. Flagged to the user rather than worked around.

## 2026-08-14 (night) — 4.3.1 REPRODUCED on his exact build: two attached displays during the
## 2026-08-15 (evening) — the never-headless guard CANNOT be seen to fail here, so it stays unproven

Setup: win10-tpl = **Windows 10 Pro 22H2 (19045.2965)**, GWeck's exact platform; the 4.3.1 IDD
(`root\iddsampledriver`, from the shipped v4.3.1 package) installed on it; agents swapped by hash
(4.3.1 = 99480D87, 4.3.2 = 20EC3EC4).

The injection itself works. With `HKLM\SOFTWARE\QubesIDD!SoloFaultInject=2` the agent logs
`the apply will be made to FAIL on purpose and the rollback is SUPPRESSED`, aims set-primary at
`\\.\DISPLAY_QUBES_FAULT_INJECT` and gets -5 (DISP_CHANGE_BADPARAM) - exactly the pre-fix sequence.

**But the state it exists to prevent is unreachable on this platform.** Three attempts:

1. IDD already attached+primary, VGA attached: pass detaches the VGA, apply fails -> IDD still
   attached, one display. Nothing lost.
2. VGA attached+primary, IDD DETACHED (the shape of GWeck's post-reboot guest): pass detaches the
   VGA, apply fails -> readback shows BOTH attached again. Windows re-attached them.
3. Agent held out entirely (`NoTopologyApply=1`) and both displays detached by hand with
   CDS_UPDATEREGISTRY: Windows refused the last detach and re-attached the IDD (attached=1).

So Windows 10 22H2 will not leave this guest with zero attached displays, and the persisted-headless
state that `6ea0822` guards against could not be produced. Consequences, stated plainly:

- `6ea0822` ("never leave the desktop with no attached display") is a plausible defensive guard whose
  PASS is **UNPROVEN**. It has never been seen to fail, so it must not be reported as the fix for
  post 54's black window.
- GWeck's "black inactive window" is therefore **NOT explained** by the zero-display mechanism on a
  stock Win10 22H2 + our IDD. Something else on his box produces it (his display config: laptop panel
  disabled, external 1920x1200 on Intel). The one artifact that would settle it is the gui-agent log
  from a BLACK boot - `Q:\Qubes Logs\gui-agent-*.log`, retrievable over qrexec with no display at all.
- Repeated `devcon disable/enable` cycling of the IDD wedged the guest (qrexec stopped answering) and
  left the device in Error state; recovered with kill/start + `devcon remove` + `devcon install`. Do
  not cycle the IDD device as a test trigger.

Rig note: win10-tpl's previous agent (3D2E6BCE, version string 4.2.2.0) was overwritten by 4.3.2 -
`useagent.ps1` keeps no backup, unlike the win11-fresh swap which kept `.devbuild`.

## 2026-08-15 (night) — the arbitrary-resolution feature was a TRAP for any size not already offered

Root cause (workflow wf_b0e24422, 9 agents, plus hand verification). `SetVideoMode` routed by the
request's SOURCE STRING, and only two strings reached the path that can EXTEND the IDD mode list:
`dom0` (resolution.c:1561) and `seamless-force`+QIDD (resolution.c:1575). Every other source - in
particular the boot restore `lastapplied` (vchan-handlers.c:174) and the fresh-guest `xconf` - fell
through to `SelectSupportedMode`, which picks the nearest entry from a cache enumerated ONCE at
startup, i.e. the driver's hardcoded base list. 1920x1200 exists nowhere in `driver/`.

It is a trap rather than a downgrade because of the ORDERING: the only publish on that path runs
AFTER the pick and carries the SNAPPED size, and the legacy tail then PERSISTS the snapped size
(resolution.c:1673 CfgWriteDword FULLSCREEN_WIDTH). So the wanted mode is never offered and never
re-requested - a 1920x1200 monitor is pinned to 1920x1080 for the life of the guest, and dom0 keeps
a 1920x1200 window over a 1920x1080 desktop. That is GWeck's "pointer about 1 cm below where the
system believes it to be" plus a dead band (post 54), on Win10 and Win11 alike, as he reports.
The driver would have accepted it: bounds are 640..16384 x 480..6144 (Driver.cpp:151) - it was
never asked. A4CLAMP is excluded: it runs BEFORE SetVideoMode, and RESREQ read 1920x1200.

FIX (agent 5e752d6): when the Qubes IDD is present, EVERY source takes the publish-and-obtain path;
the legacy snap survives only for a guest with no IDD, where a fixed-mode adapter genuinely cannot
be taught modes. `allowSnap` stays TRUE, matching dom0.

PROVEN, interleaved, on win10-tpl (Win10 22H2) with the precondition re-established before every
run (mode set cleared + IDD restarted, `pre_offered=0` asserted each time):

    shipped 4.3.1 (his binary)     RESSNAP 1920x1080 SNAPPED   desktop=1920x1080  offered_after=0
    fixed bin, ModeSnapFaultInject=1   SNAPPED x3              desktop=1920x1080  offered_after=0
    fixed bin, knob off                NO SNAPPED line x3      desktop=1920x1200  offered_after=2

The knob (`HKLM\SOFTWARE\QubesIDD!ModeSnapFaultInject`, dead code when unset) re-introduces the
defect on the SAME binary, so this check has been SEEN TO FAIL - it is evidence, not a PASS.

METHOD NOTE, and the reason the first re-runs were void: after ONE fixed run the driver offers
1920x1200, so the legacy path then finds an exact match and prints `RESSNAP 1920x1200` with no
SNAPPED suffix - both sides "pass". The defect exists only while the mode is absent, so the mode
set must be reset between runs or the A/B measures nothing.

Also surfaced (not yet acted on): `guest/resize-sync.ps1:40` is a SECOND writer of
`HKLM\SOFTWARE\QubesIDD!Modes` and can race the agent's own publication.

## 2026-08-16 — the ACCESS_LOST root cause is OURS, and it is at boot

Workflow wf_426983cc ranked the triggers by recorded evidence rather than by mechanism, and the
answer is not the one the mechanism suggests.

**#1, and 17 of 24 recorded natural events: we hot-unplug the monitor two statements before we
create the duplication.** `ResolutionPublishBootModeSet` wrote the boot mode set and then made it
live with an IOCTL reload; the driver answers a reload by departing and re-arriving the monitor -
unconditionally, without comparing the sets - which is a hot unplug. `StartFrameProcessing` then
built the desktop duplication into a topology still settling from that replug. FINDINGS 4113 has a
single cold boot with 8 transient 0x887a0026 including a CaptureInitialize that failed outright, and
`StartFrameProcessingWithRetry`'s retry loop exists to survive exactly this.

Nothing needed that reload: the desktop is already running at the current size, so its mode is
offered by definition, and the reload only pre-arms LATER switches - which perform their own obtain.
The neighbouring `ResolutionRecomputeIddModeSet` already states the discipline ("registry rewrite
ONLY ... a dom0 panel move must not blink the screen"); it now applies to boot too.

MEASURED, three interleaved pairs, a COLD BOOT for every run, one change between the binaries, and
each run asserting the agent is alive with a daemon connected before it counts anything:

    round   boot replug (A9F0897F)      no boot replug (363AE675)
      1     4 / 1 / 2                   1 / 0 / 0
      2     4 / 1 / 2                   1 / 0 / 0
      3     4 / 1 / 2                   1 / 0 / 0
            (access_lost / capture_init_failed / a7retry)

Identical in every round: the boot cluster is four events with a failed CaptureInitialize and two A7
retries, and removing the boot reload leaves exactly one event and no retries at all.

**#2 is the only trigger proven at millisecond resolution** and it is not ours: the Winlogon ->
Default input-desktop flip, from GWeck's own log (ACCESS_LOST and "input desktop changed" in the
same millisecond), once per boot. That is very likely the one event still left above.

**Zero recorded occurrences**, and therefore not ranked: the UAC secure desktop. I disabled
`PromptOnSecureDesktop` earlier today on reasoning alone, and item #2 is the LOGON flip, not a UAC
prompt - so that change does not address the proven trigger. It stays (it is sound for seamless, and
correctly mode-gated after the owner pointed out that fullscreen has a real SAS path), but it must
not be described as fixing anything measured.

**Strong negative control**: drag, steady-state capture, DWM restart, RDP and host suspend produce
zero - 16 ddaprobe runs with ACCESS_LOST 0 and re-duplications 0. Novel-size replugs are a blink,
not a fault: obtain -> reload 16 ms -> offered 281 ms -> applied 344 ms, and habitual sizes cost 0.

### RETRACTED, and it would have been severe

I wrote a "quiesce capture across the mode change" bracket and shipped it to a test build. It could
never have worked: `CaptureStop` clears `g_CaptureThreadEnable`, and `RecreateDuplication` bails on
that flag (capture.c:465 "asked to stop while recovering") AFTER releasing the duplication - so
`CaptureReplugEnd` could only return FALSE, every call site discarded the result, and every mode
change with live capture would have frozen the qube's pixels permanently and silently. My own
measurement showed access_lost going UP (3 vs 1) and I read it as noise; the adversary read it as
the defect. Reverted in full (22fad26, d2b56c6).

The lesson is the one this project keeps relearning: an instrument that cannot fail is worthless,
and a fix whose own numbers get worse is not "noisy", it is wrong.

## 2026-08-16 — RETRACTION: the `/idd` "file not found" was OUR bug, and we blamed the reporter

Two entries in this file are **wrong and are retracted**:

- FINDINGS.md ~6442: *"NOT our bug (post 35 /idd 'file not found'): GWeck hand-built Start-Process
  -FilePath 'D:\idd' ... Our install.cmd relaunches via %~f0 (=D:\install.cmd) and cannot emit
  D:\idd"*
- FINDINGS.md ~6945: *"S4 /idd: user error (Start-Process 'D:\idd')"*

Also retracted: my own reading earlier today that GWeck's post-64 `C:\iddoff` meant he was running a
stale `install.cmd` left in `C:\QWT-NG`. He was running 4.3.2. The bug is ours.

**Mechanism (proven experimentally on win10-clean, not argued from source).** `install.cmd`'s option
parser uses bare `shift`. Bare `shift` starts at argument **ZERO**, so it overwrites `%0` with `%1`.
The parse loop runs BEFORE the elevation check, so by the time the UAC relaunch expands `%~f0`, `%0`
is the switch. `%~f` then runs it through the Win32 path normaliser, where `/` is a separator and a
LEADING separator means "root of the current drive":

    BEFORE arg0=[C:\...\shifttest.cmd]  tildef0=[C:\...\shifttest.cmd]
    AFTER  arg0=[/iddoff]               tildef0=[C:\iddoff]
    WOULDRUN: Start-Process -FilePath 'C:\iddoff' -ArgumentList '/iddoff' -Verb RunAs

Byte-identical to his post-64 transcript, ArgumentList included. `/idd` yields `C:\idd`; from a
substituted X: drive, `X:\idd` — which is his post-35 `D:\idd` from the ISO. **One bug produced both
field reports, a year apart in our triage, and we closed the first as user error.**

`RAWARGS` is captured before the loop, which is why the arguments looked right while the path was
destroyed — the asymmetry that made it look hand-built.

**Scope.** Fires iff (non-elevated OR UAC-filtered token) AND >=1 recognised switch. Elevated
console: unaffected. Bare `install.cmd` non-elevated: unaffected (no shift ran) — which is why
double-click installs never showed it. Unrecognised switch: exits 87 first.

**Why no test could ever have caught it.** Every rig sets `EnableLUA=0`
(`mgmt/autounattend.xml:180`, `mgmt/autounattend-win11.xml:246`, `guest/firstboot-setup.ps1:29`), so
`net session` succeeds and the relaunch block is **unreachable on our hardware**. The non-elevated
row — the default posture of every real user — is not merely untested, it is structurally
untestable on the current rigs. Recorded `/iddoff` PASSes all went through qrexec, which holds a
High-integrity token.

**Second defect, same 8 lines.** `exit /b 0` was unconditional and `Start-Process` had no
`-Wait`/`-PassThru`, so a failed elevation was reported to the caller as SUCCESS.
`tools/qwt-bootstrap` waits on it and returns its code, so `qubes-tools-<ver>.exe /passive` run
non-elevated printed an error and exited 0.

**Fixed** by capturing `set "SELF=%~f0"` before the parse loop and reading `%SELF%` thereafter
(preferred over `shift /1` because a future switch cannot reintroduce it), plus `-Wait -PassThru`
with exit-code propagation. **Not yet released, and the regression check has NOT yet been seen to
fail** with the defect reintroduced — that needs a UAC-on rig or a `-ForceUnelevated` hook, so it is
recorded as unproven per the CLAUDE.md rule.

## 3. RESOLUTION (ordered)

1. **Relay churn removal** (the actual wedge fix): one long-lived vchan pool per pass; close channels only after far-end EOF — never `cut_request=True` closes; min-interval throttle (the display path's M7 analog). *Acceptance:* soak harness hammering back-to-back scan passes must wedge the **pre-fix** build within bounded cycles (control seen to FAIL), then zero wedges post-fix over ≥3× that count.
2. **NMI dump on a reproduction** (deterministic closure of the class attribution): arm NMICrashDump + wedge-telemetry boot task on win10-tpl, reproduce via the same hammer, dom0 wedge-kit `--nmi` (user/dom0 action), kd per-CPU module+offset stacks. Also re-derive the CPU figure from dom0 cputime. *Acceptance:* the dump names the spinning driver or shows idle vCPUs — either way the differential in §4 collapses to one entry. Only after this does any upstream report get drafted — and only if the stack lands in libvchan/xen drivers, not QWT's own qrexec (ownership per the recorded correction; user approves text first).
3. **Cross-path pass debounce** (not a mutex — every observed double-fire was *sequential*, 18 s apart; boot+repetition triggers are already the same task under IgnoreNew): skip a pass if one completed <N minutes ago, across scan task / Run task / dom0 RPC. *Acceptance:* pre-fix boot shows two passes (proven pattern); post-fix same boot shows one, with the skip logged.
4. **Ensure-Proxy serviceability probe**: loopback HTTP round-trip to 127.0.0.1:8082; on failure kill any relay-named process and respawn. *Acceptance:* plant a dead/wedged squatter on 8082 → pre-fix pass must FAIL 0x80072EFD (reintroduced defect seen red); post-fix pass recovers and completes.
5. **Protect-Autologon into the finally**, guarded by `$StagedThisSession`. *Acceptance:* test hook throws after staging → pre-fix leaves autologon un-armed (seen to fail); post-fix registry shows re-armed autologon despite the throw.
6. **Relay honesty hardening**: (a) return 502 on exhausted retries — never forward an incomplete best body; (b) fix the 16 MB cap (verify full Content-Length bodies or chunk-verify — no silent truncation); (c) log `complete=unknown` for !LengthKnown responses. *Acceptance:* dom0-side fault-injection shim truncates responses → client must see an error, never a short 200 (pre-fix short-200 observed); force a chunked plain-HTTP response on an up-to-date guest → exit 0, not 75.
7. **Give-up guard hardening**: fire on *any* give-up during the scan window (undercount case reported as scan-degraded/exit 75); Get-RelayGiveUps fails loud when the log is unreadable; derive the log path from `-WorkDir`. *Acceptance:* new FAKE hook simulating N>0-with-giveups → exit 75; delete the relay log mid-scan → pass errors instead of reporting.
8. **Fetch/verify closure**: 416 branch verifies size against server total (probe request/Content-Range), not magic-only; Test-Msu catch returns 'bad'. *Acceptance:* plant an over-long valid-magic file → pre-fix accepted (seen), post-fix discarded+refetched; plant an unreadable file → pre-fix "success" (seen), post-fix discarded.
9. **Sync-Revocation pristine edge**: when a needed cab has no local copy and both fetches fail, fail the pass with a named error and do NOT repoint RootDirURL. *Acceptance:* block cab fetches on a pristine clone → explicit missing-cab error, not 0x80072F8F.
10. **Exit-code contract**: exit nonzero when phase='error' (audit all callers), and make the build gate hard-fail on scan-gate miss. *Acceptance:* induced error → nonzero exit + gate failure.
11. **VM-class matrix completion**: run the shipped classifier on a real Win10 AppVM, a real Win11 Standalone+AppVM, a DispVM, and re-exercise the Standalone direct-internet branch. *Acceptance per cell:* skipped-\* status + zero relay bytes + zero relay processes witnesses.
12. **PidForLocalPort**: loop GetExtendedTcpTable on ERROR_INSUFFICIENT_BUFFER. *Acceptance:* unit-style repro growing the table between calls → pre-fix RST, post-fix identified.
13. **Enable TaskScheduler Operational log** on templates (attributes future pass triggers) and keep wedge-telemetry as a boot task — understood as a *user-mode discriminator only*; it cannot capture a kernel freeze (the NMI path is the closer).
14. **Non-catalog KB targeted handling** (backlog, owner-acknowledged): Defender via standalone mpam-fe.exe through the relay, MSRT as .exe, etc. Explicitly NOT a loopback adapter. Until built, current honest per-pass failure stands. *Acceptance:* Defender definitions version advances on a netvm-free template.
15. **Remaining named probes (no fix yet, none excused):** first-boot vif reset — catch-firstboot.sh armed, next reproduction names the resetter; AppVM no-GUI — run the A/B clone-source probe; Xen teardown hang — dom0-side investigation (escalate), operator rule documented meanwhile.

## 2026-08-25 — the AppVM shutdown ROOT CAUSE: xenbus_monitor AutoReboot on a volatile root. 4.3.5

4.3.4 did not fix it (entry above). The e2e test on a clean template installed from the released
package still reboot-looped, so the real cause was still open. It is this:

`Set-XenbusAutoReboot` in the installer writes `xenbus_monitor\Parameters\AutoReboot=1`, turning the
PV-driver "needs to restart to complete installation" modal into a SILENT reboot. That is correct for
an unattended TEMPLATE install and it is what makes our install non-interactive.

It is inherited by every AppVM, where it is catastrophic: an AppVM's root is VOLATILE, so the driver
install re-runs on every boot, wants a reboot on every boot, and now gets one silently. The guest
reboots, Qubes counts the resets, and halts the qube - the field report, exactly.

**It is NOT the latch.** On the failing boots the PV NIC read `CM_PROB_NONE` and the emulated Realtek
read `CM_PROB_PHANTOM`, i.e. the latch had done its job and the emulated NIC was unplugged. The
initiator is in the guest's own System log:

    1074  C:\Windows\System32\xenbus_monitor_9_1_0_0.exe has initiated the RESTART
    1074  C:\Windows\System32\xenagent_9_1_0_0.exe       has initiated the SHUTDOWN (reason 0x8000000c)

- the first is the silent AutoReboot; the second is dom0 halting the qube afterwards.

**Fix:** the per-boot payload reads the qube class from qubesdb and, on anything that is NOT a
TemplateVM, stops and disables `xenbus_monitor`. A reboot has nothing to complete on a volatile root,
so the service has no job there. Templates keep it - that is where it earns its place.

**Verified, mechanism AND outcome:**

    FINAL=Running at t+240s (previously Transient -> Halted at ~90 s)
    sc query xenbus_monitor -> STATE 1 STOPPED, START_TYPE 4 DISABLED
    payload log: "qube type 'AppVM': xenbus_monitor disabled - a reboot cannot complete an install
                  on a volatile root"
    across three boots: Running, ip 10.137.0.72, tcp YES each time

**Two process failures on the way, both mine and both the same shape.** `tools/qtest push` silently
delivered nothing ("The argument ... does not exist" only became visible when I stopped grepping the
output), so I "deployed" a fix three times without it reaching the guest and nearly reported a
survival that had nothing to do with my change. And my first version of the gating called `QdbGet`
above its own definition inside the payload, which would have made it a silent no-op. Verify the
artefact is installed before believing any result from it.

## 2026-08-25 — 4.3.7 RELEASED: xenbus_monitor ships disabled; acceptance with a fired control,
## 2026-08-27 — bounding-box theory (b) CLOSED: no filter hazard from multi-monitor on current
## builds; found instead a live arbitrary-resolution defect on the win10 4.3.8 rig

**The (b) premise was wrong at the source level.** g_ScreenWidth/Height is the PRIMARY display
mode (EnumDisplaySettings(NULL) adopt + the dom0-driven apply), NOT the virtual-desktop bounding
box - the 08-24 FINDINGS statement "an active second monitor inflates g_ScreenWidth" is
RETRACTED. A second active monitor therefore cannot mis-size the fullscreen gate, and LogonUI
(primary-sized) stays gated in every topology. Defenses verified: (1) Windows itself REFUSES an
extended topology on the IDD guest - SetDisplayConfig(SDC_TOPOLOGY_EXTEND|SDC_APPLY) returns 31
(ERROR_GEN_FAILURE) even with the emulated VGA re-enabled (measured, win10-app 4.3.8; DisplaySwitch
/extend also no-ops); (2) if a second display ever attaches, WM_DISPLAYCHANGE fires
ResolutionRequestIddSoloReassert (1.5 s debounce) which re-asserts IDD-solo; (3) AppVMs always
boot solo (the VGA-disable is template state, volatile root restores it). RESDRIFT (in 4.3.3 too)
adopts the actual mode, so intended-vs-actual mismatch cannot mis-size the gate either. GWeck's
second filter leg remains unidentified (feature-on, or the pre-xconf g_ScreenWidth==0 boot race)
- moot for the fix, the 4.3.8 predicate is leg-independent.

**Found live instead: arbitrary resolutions are BROKEN on the win10-app 4.3.8 rig.** dom0
requests 5120x1440; the agent logs `QIDD ioctl-reload unavailable, falling back to device
restart (PnP)` then `RESKEEP 5120x1440-unavailable keeping 1024x768 reason=mode-never-appeared`.
Pinned facts: the bound IDD driver IS the shipped 4.3.8 build (device ROOT\DISPLAY\0000 at
21.22.19.960, oem14.inf; store also holds the 08/15 and 08/25 generations); QiddReloadModes()
finds NO device-interface instance accepting IOCTL_QIDD_RELOAD_MODES (custom interface GUID,
SetupDiGetClassDevs path); after the replug fallback the requested mode never appears in the
mode list. Meanwhile win11-app (Aug-11-era agent+driver pair) sits at 5120x1440 fine - so either
a regression between the Aug-11 and current driver, or an environment defect of this rebuilt
template chain. The failure is FAIL-SAFE for filtering (RESKEEP keeps actual; gate sized right)
but the T2 feature is dead on this rig. NEXT: check whether the 4.3.8 driver registers the QIDD
interface at all (driver-side source + a fresh-boot interface enumeration), and whether the
modes key the driver reads matches what the agent writes.

## 2026-08-27 — REGRESSION CONFIRMED AND ROOT-CAUSED: 4.3.8 upgrades break arbitrary resolutions;
## decides whether the IDD works; leading fields 21.x/23.x break it, 15.x/8.x do not

The instrumented-driver deployment produced the decisive datum by ACCIDENT before its
breadcrumbs even worked: the new package (DriverVer version 8.1.39.461, built 08:01 UTC) came
up at 5120x1440 on the first boot - on the same template where 21.22.*/23.53.* packages fail
deterministically. Full table, all with functionally identical driver code on one template:

    15.51.7.219  (4.3.7, built 15:51)   WORKS
    21.22.19.960 (4.3.8, built 21:22)   BROKEN
    23.53.52.119 (4.3.9rc, built 23:53) BROKEN
    8.1.39.461   (diag, built 08:01)    WORKS

stampinf's default writes the BUILD TIME (HH.MM.SS.ms) as the DriverVer VERSION. Display
driver versions whose leading fields land in the WDDM driver-version encoding convention
(21.20~WDDM2.1, 23.x~2.3, ...) are parsed by graphics-stack compatibility logic; our evening
builds accidentally claimed to be WDDM 2.1/2.3-era drivers and the stack then never surfaced
the registry modes and answered the QIDD ioctl with STATUS_OPERATION_IN_PROGRESS. Morning
builds (15.x, 8.x) stayed out of the encoding space and worked. THE RELEASES WERE BROKEN OR
NOT BY THE HOUR THEY WERE BUILT - which is why the "regression" appeared exactly at 4.3.8,
why the package A/B followed the INF and not the bytes, and why every content-level theory
(hardlinks, certs, cats, byte-identity) died: the content was never the variable.

Epistemic status: N=4 packages, deterministic per package across many reboots, same bytes -
the correlation is solid; the WDDM-encoding attribution is the best-fitting mechanism but is
inference. The A/B seal: the PINNED build (DriverVer version 4.3.x.y, first field far below
the encoding space) must work on this template, with the banked oem14 (21.22) control already
proven broken twice. Fix shipped as a workflow step that rewrites DriverVer to
<date>,4.3.<build>.<rev> after stampinf and before Inf2Cat/signing, in both driver workflows.
(The DLL FILEVERSION stamping and the activation identical-bytes guard stay as hygiene; the
diag breadcrumbs move to PLUGPLAY_REGKEY_DRIVER - the hardware key rejected UMDF-host writes.)
[CORRECTED 2026-08-28 by the unshipped-fix audit: that is not what shipped. PLUGPLAY_REGKEY_DRIVER
was rejected too, so the breadcrumbs write to a plain FILE - Driver.cpp:269-277, appending to
C:\ProgramData\QubesIDD-diag.log. The sentence above describes an intermediate attempt.]

## 2026-08-27 — IDD activation hardened (repo 1efeee3, ships in the next release): downgrade
## 2026-08-28 — the resize chime was NEVER SHIPPED: a hand-applied rig tweak recorded as a fix

Owner: "we silenced it, and now it is chiming again." Investigated: FINDINGS 2026-08-05
(addendum 4) says "monitor replugs fired Windows' device connect/disconnect sounds on every
resize - silenced via HKCU AppEvents (DeviceConnect/DeviceDisconnect/DeviceFail set to no
sound)". A repo-wide grep for AppEvents/DeviceConnect/SchemeName/etc found EXACTLY ONE hit -
that FINDINGS sentence. No installer, payload script or agent code ever wrote those values.

So the 2026-08-05 "fix" was applied by hand to the then-current test rig and written up as
done. Consequences: every user of every release since has heard the chime on every resize, and
tonight's from-scratch rebuild of the rigs (which discarded the hand tweak) made it audible
here again - the rebuild did not cause the regression, it EXPOSED that there had never been a
fix. This is the failure mode CLAUDE.md's rules exist to prevent: a result recorded from a
state that no artifact reproduces.

Now shipped (1ef4619) in guest/quiet-desktop.ps1, which already had the right machinery: the
three .Current default values are set to an empty REG_SZ ("no sound") for the live user, every
loaded profile, every offline profile (reg load/unload), and C:\Users\Default's hive - the last
two matter because the installer runs as SYSTEM, where a plain HKCU write lands in SYSTEM's own
hive rather than the interactive user's. Verified on win11-app: SET at all three scopes, value
reads back as "(Default) REG_SZ" empty in the interactive user's hive.

That silences the SYMPTOM. The cause - a mode-list reload per new size, which Windows treats as
a monitor hot-plug - is task #26, and removing it also removes the latency the chime accompanies.
AUDIT NOTE: any other "fixed" claim in this file whose implementation cannot be pointed at in the
tree deserves the same suspicion; a hand-applied rig change is not a shipped fix.


## 2026-08-28 — #26 (resize chime/latency): IddCxMonitorUpdateModes TRIED AND REVERTED. The
## replug is removable; making the new size ACTUALLY AVAILABLE by that route is not proven.

Mechanism established first: every new size is written to HKLM\SOFTWARE\QubesIDD\Modes and the
driver's ReloadModes then does IddCxMonitorDeparture -> re-create -> IddCxMonitorArrival. That
is a genuine monitor unplug/replug, which is why Windows plays the device connect/disconnect
chime on every resize, re-enumerates displays, and (measured) kills desktop duplication.

ATTEMPT: replace the replug with IddCxMonitorUpdateModes (we build against IddCx 1.4, which
has it). Two compile errors along the way, both my guesses: IDARG_IN_UPDATEMODES carries no
monitor description - it is {Reason, TargetModeCount, pTargetModes} - and the shared target-mode
builder needed a forward declaration. Third build compiled.

MEASURED on win11-app with that driver bound (4.3.5.16443):
- The replug IS eliminated: "DiagReload updatemodes ok (no replug) targets=10", twice, and the
  OS reacted (DiagCommit paths=1 after each). No departure/arrival.
- Capture still dies: 887a0026 count went 8 -> 10 across the reload window, against an IDLE
  CONTROL of delta=0 over the same 12 s. So the in-place update does NOT save desktop
  duplication; that teardown is not caused by the replug alone.
- Whether the NEW SIZE becomes usable: NOT ESTABLISHED, and probably not. UpdateModes refreshes
  the TARGET mode list; the MONITOR mode list comes from EvtIddCxParseMonitorDescription, which
  runs on ARRIVAL. The OS offers the intersection, so without a re-parse the new size stays
  unavailable - and the agent would then time out waiting and fall back to the PnP device
  restart, which its own comments call the worse path (it disturbs the Xen platform device).

REVERTED (7256c9f, 567e153, fa5a6e3) rather than shipped: a change that plausibly makes resize
SLOWER, on the strength of "the replug went away", is exactly the kind of half-measured fix this
project keeps paying for. Nothing was released with it - 4.3.13 was built from d3273de, before.

INSTRUMENT WARNINGS EARNED THE HARD WAY (all mine, all cost real time):
- schtasks /tr does NOT interpret redirection: without `cmd /c` the ">" is passed to PowerShell
  as an argument and the output silently goes nowhere. Hours of "the task never ran".
- A task running as the (non-elevated) user CANNOT write to C:\ root under UAC - every probe
  that wrote C:\foo.txt produced nothing. Use C:\Users\Public (which, note, is on the PRIVATE
  volume via MoveUsers and survives reboots).
- WmiMonitorListedSupportedSourceModes is NOT an availability oracle: it listed 4 modes
  (1024x768, 800x600, 640x480, 1920x1080) while the guest was running at 5120x1440. It reports
  EDID-declared timings, not the effective mode set.
- EnumDisplaySettings returns 0x0 from the qrexec SYSTEM context AND my DEVMODE marshalling read
  zeros even in-session; do not trust a hand-rolled DEVMODE without validating it against a
  known-good size first.

WHERE #26 GOES NEXT (not started): the reload is needed because monitor modes are only rebuilt
on arrival. Options: (a) publish a BROAD monitor mode list at arrival so common sizes never need
a reload - but dom0 window sizes are arbitrary and the owner's rule forbids snapping the guest
to a grid (dom0 is the source of truth), so coverage would be partial; (b) find whether IddCx
can re-run the monitor description parse without arrival (unknown, needs API research);
(c) accept the reload and attack only the capture death (task #23), which is the part that
blanks the window. The chime itself is already silenced product-side as of 4.3.13.

## 2026-08-28 cont 3 — I put a fullscreen guest window on the owner's display AGAIN. Cause, and
## 2026-08-29 — cell WIN11-24H2 with the monitor ARMED: the decisive "no premature reboot dialog" result

`win11-24h2`, precondition read from the guest: QWT **4.3.1.0**, testsigning ON, PV boot disk, and —
uniquely among the cells run so far — **`xenbus_monitor` Start=2 (Automatic) and Running**. That is
the armed field state, the only configuration in which the premature reboot prompt can actually
fire. Same CI package (`f777bec`), unmodified.

**Result: `INSTALL COMPLETE`, `ok:true`.** Watcher: **88 samples, SAMPLES_WITH_DIALOG=0**, blind=false
throughout. The mechanism is visible working in the same record: `MONITOR_STATES=Running,Stopped`
and `MONITOR_START_VALUES=2,4` — the installer disarmed the running Automatic monitor — and 15
samples carry a pending PV reboot Request that was armed and then cleared. So the Request WAS raised,
the monitor WAS live at the start, and no dialog appeared at any point. `BIGGEST_GAPS=2` in a
3006-line MSI log, both short: a real driver install, not a stall.

This is the strongest evidence available for the "premature reboot dialogs are gone" criterion,
because it is the one cell where the prompt had every precondition it needs.

**Functional: 12 of 15, identical pattern to U11.** Same three network failures
(`pv_drivers_bound`, `network_carries_traffic` at APIPA 169.254.130.108, `pvnic_applier` absent),
same root — `netvm=''` — and the same KM-TEST Loopback artefact defeating health-check's
not-applicable branch.

### Also settled here: xenagent in event 1074 is NOT evidence of a guest-initiated reboot

While recovering this guest I read its shutdown events with ages. The most recent 1074 was
`ageMin=2` — my own ACPI `qvm-shutdown` — attributed to
`C:\WINDOWS\System32\xenagent_9_1_0_0.exe ... on behalf of NT AUTHORITY\SYSTEM`. So xenagent is
simply the component that EXECUTES a dom0-initiated ACPI shutdown; seeing it in 1074 is expected and
says nothing about who decided to reboot. An earlier session cited exactly this signature as "direct
evidence for task #29" (unattended shutdowns); today's audit had already downgraded that on dating
grounds, and this measurement retires it on mechanism grounds as well.

Equally: there was **no 1074 at all** between this guest's boot and my shutdown, during the ~8
minutes it sat `Transient` with qrexec down. It did not reboot itself — its qrexec agent died while
the guest kept running. That is a separate, still-unexplained fault on this guest (it answered two
probes, then went unreachable), and it is NOT the install bug: it happened before any install was
started.

## 2026-08-29 — cell WIN10 armed-monitor (win10-clean): PASSES, health-check ok:true

`win10-clean`, precondition from the guest: QWT **4.3.2.0**, testsigning ON, PV boot disk,
**xenbus_monitor Start=2 (Automatic) and Running**. This is the WIN10 armed-monitor case — the
closest match to the originally reported failing scenario. Same CI package (`f777bec`), unmodified.

    INSTALL COMPLETE, ok:true, ~80 s (06:45:23 -> 06:46:38)
    watcher: 72 samples, SAMPLES_WITH_DIALOG=0
    MONITOR_STATES=Running,Stopped   MONITOR_START_VALUES=2,4   (installer disarmed it)
    SAMPLES_WITH_PENDING_REQUEST=13  (armed, then cleared)
    MSI log 2964 lines, BIGGEST_GAPS=0

**health-check: `ok = True`.**

### This also settles the health-check asymmetry, in health-check's favour

Three checks report `pass:false` here but carry an explicit `na`:

    pv_drivers_bound        na: "no physical network adapter attached - PV NIC not assertable here"
    network_carries_traffic na: "no network attached"
    pvnic_applier           na: "QubesPvNic task not registered - M1 latch deployment absent"

and the overall verdict is still `ok:true`. So the documented "no network attached is not
applicable, never a pass" logic WORKS. It did not fire on win11-fresh or win11-24h2 for the reason
identified earlier: those guests carry two **Microsoft KM-TEST Loopback Adapter** entries that
`Win32_NetworkAdapter ... PhysicalAdapter` counts as physical, so the guest does not look
network-less. That is a defect in the *predicate*, not in the build and not in the check's intent —
the fix is to exclude loopback adapters from the physical-NIC count.

### Cell status after four runs, all on the same unmodified CI package (f777bec)

| cell | guest | precondition | install | dialogs | health-check |
|---|---|---|---|---|---|
| WIN10 stage-2 | win10-u10 | no QWT, monitor Disabled | COMPLETE 49 s | 0/61 | **ok:true** |
| WIN11 upgrade | win11-fresh 25H2 | QWT 4.3.9, monitor Disabled | COMPLETE 72 s | 0/46 | 12/15 (loopback artefact) |
| WIN11 armed | win11-24h2 | QWT 4.3.1, **monitor Auto+Running** | COMPLETE | **0/88** | 12/15 (loopback artefact) |
| WIN10 armed | win10-clean | QWT 4.3.2, **monitor Auto+Running** | COMPLETE 80 s | 0/72 | **ok:true** |

Zero premature reboot dialogs across **267 samples** on four guests, including both armed-monitor
cases where the Request was raised and cleared. Not one install hung.

Note: `win10-clean` was the WIN10 golden and now carries 4.3.15 rather than 4.3.2. Recorded so
nobody later reads it as a pristine 4.3.2 source.

## 2026-08-29 — the WUDFRd 219 question ANSWERED by the new check, on its first run

The investigation left this undecided: is `219 / WudfRd failed to load / ROOT\DISPLAY\0000` rare and
fatal, or common and benign? A prior rig saw 219 on every boot and retracted it as a failure
signature, but never committed the status/device, so it stayed UNPROVEN.

**Measured on the acceptance run's first cell (win10-u10, release ISO `fdd4700`):**

    boot_events_clean:  219 "The driver \Driver\WudfRd failed to load for the device ROOT\DISPLAY\0000"
    idd_device_bound:   PASS
    desktop_on_idd:     PASS

So on this boot the first UMDF load attempt failed, **PnP retried, and the display came up
correctly.** 219 on its own is a RECOVERED TRANSIENT here — not a fatal defect.

**That immediately corrected the check I had just written.** As first implemented,
`boot_events_clean` failed on any 219 and therefore graded a demonstrably-working guest as broken —
it would have failed all six acceptance cells for nothing. Refined: a 219 FAILS only when the device
did **not** recover (`idd_device_bound` false), and otherwise is recorded under
`warnings_recovered`. The signal is kept — being blind to it is what let this class hide — but it
can no longer produce a false failure. Re-graded: `ok = True`, zero failures, warning recorded.

**What is now known vs still open:** known — 219 occurs on a boot whose IDD ends up correctly bound,
so the end state is what decides. Still open — whether it *ever* fails to recover, which is exactly
what the check will now catch if it happens across the remaining cells. That is the honest way to
answer "rare or common": let a check that cannot produce false failures observe it across a real run.

**Note on instrument vs artifact:** the product under test is the single release ISO. `health-check.ps1`
is an INSTRUMENT and is run from the repo (newer than the ISO's copy) — a measuring tool may be newer
than the thing it measures. Everything installed on the guest comes from the ISO and nothing else.

