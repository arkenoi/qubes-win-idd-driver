# drag — findings

## CURRENT STATE

AUTHORITATIVE. Supersedes everything under History below. A correction belongs HERE,
not only as a new dated section — the whole reason this file exists is that 654
correction lines were buried chronologically in a 25k-line log, so reading a topic
top-down returned the stale answer.

- Wobble was FIXED 2026-08-16 by `InputDragQuantise` + interpolated origin. Shipped defaults `AdoptMs=25 / AnnounceMs=50`, `LagMs=10`, `OriginInterp=1`; the servo is superseded and OFF. Do not read the top of docs/PLAN-drag-quality.md, which still says "parked". [verified 2026-08-16]
- Owner reports the wobble is BACK as of 2026-09-01. **Cause FOUND and fixed (`6385c25`) - see the crossing entry below.** Awaiting the owner's confirming hand drag on the fixed build.
- All three good translation branches gate on `window == g_InputDragWindow && g_InputDragOriginValid`; anything else falls through to the LIVE origin, i.e. the gain-1 oscillator. So any path that fails to arm the latch or clears it mid-drag silently restores stock wobble. Code-read, not measured. [verified 2026-09-01]
- **ROOT CAUSE, MEASURED on a hand drag 2026-09-01: `HandleCrossing` releases the drag latch mid-drag on a GENUINE normal-mode LeaveNotify.** 569 ms into a 5.0 s guest-native drag, dom0 sent `LeaveNotify mode=0 (NotifyNormal)` and the latch was torn down. Before it: 50 motion events, 50/50 on the interpolated origin, 8 % window-path reversals. After it: 490 events, **489/490 on the LIVE origin** - the gain-1 oscillator - and **20 % reversals**, which is the wobble exactly as originally measured (16-19 %). The same teardown also disables `InputDragFreezeContent`, `DragEventPriority` and the announce pacing (they gate on the same latch): the announce rate inside the drag was 33.5/s against the ~14/s the tuning was fitted at. Fixed in `ae09bdc` by DELETING the teardown, not guarding it: `HandleCrossing` now receives the message, records it under the drag trace, and touches no state. The intermediate guarded version (`6385c25`, `2ad98c8`) is superseded - keeping a speculative path alive on a hypothetical was the same reasoning that caused the bug. The one defect that commit had a mandate for, a `LogWarning` per crossing on the INPUT path at ~10/s, stays fixed. [verified 2026-09-01, hand drag, agent EB25802E85D471A8]
- **PROVENANCE of that teardown, because it is the process lesson and not just a bug** (owner asked, 2026-09-01: *"what exactly invented this teardown path?"*). The task in hand on 2026-08-30 was an owner-reported unbordered Windows Update dialog (`096fa98`, `93a0d9c`, `30c4e65`); from 01:01 that day onward the whole session was the acceptance/test framework. At **00:42** I recorded MSG_CROSSING as unhandled and ended the entry *"Not yet fixed. The right handler behaviour needs deciding (on leave: release hover/capture ...), and the Linux agent's treatment of XCrossingEvent is the reference."* At **00:44** - two minutes later - I wrote the handler anyway, and not the behaviour that note described: it tore down the DRAG latch, a different subsystem, not the reported problem, not in the note, not requested, not measured. It shipped inside a legitimate log-flood fix and was reviewed as one. The hole it claimed to close had been closed 17 days earlier by `INPUT_DRAG_STUCK_MS` (`cef692a`, 2026-08-13). Cost: a wobble regression plus three burned hand drags. [verified 2026-09-01]
- **RETRACTED**: the 2026-09-01 claim that "the `MSG_CROSSING` handler ... did NOT resolve the owner's complaint, so it is NOT the regression". It IS the regression. That claim was made from code reading and a hand drag with no instrument; measurement reverses it. `b71f611` introduced it, `8b72b4e`'s `mode == NotifyNormal` guard is correct but insufficient - the damaging event is a genuine normal-mode leave, because in a guest-native drag the WINDOW moves out from under a nearly-stationary hand, which is precisely what X reports that way.
- **NOT the cause, both measured and both now excluded**: (a) dom0's apply lag - the synthetic calibration shows a lag > ~25 ms *would* reproduce the wobble, but on the real drag 91 % of events never consulted the announce history at all, so the wobble is explained without it; (b) inbound daemon configures yanking the window (`InputDragCfgGuard`) - the hand drag recorded **0** `CONFIGURE-IN` and **0** `DAEMONMOVE` with `drag=1`, so it is inert on the real path exactly as it was in 2026-08-12. Keep the knob, default OFF; do not spend another session on either. [verified 2026-09-01]
- No `InputDrag*` default changed between the user-approved baseline 168a869 and HEAD, so the regression is in behaviour around the drag path, not in its tuning. [verified 2026-09-01]
- **"The tuning was never committed, only written to the registry" is DISPROVEN.** `b75358b` put 25/50 in `perf.c` and `168a869` put `OriginInterp=TRUE` there; `git diff 168a869..HEAD -- gui-agent/perf.c` changes no drag default and no drag constant in main.c/main.h either. The live guest confirms it from the other end: `HKLM\...\Qubes Tools\gui-agent` holds ONLY `ProtoTrace=0` and `ProtoTraceWobble=0` - zero `InputDrag*` overrides - so the running agent is on compiled-in defaults that equal the approved values. The installer seeds only SeamlessMode/DisableCursor/LogDir, so no missing seeding script exists to find. [verified 2026-09-01]
- **What was NOT committed is the LOGGING LOAD the tuning was fitted against, and it is a timing parameter.** The whole ladder and the approval ran with `ProtoTrace=1` (written by `scratchpad/swap-interp.ps1`, which is how the metric was computed at all) on a build whose `QGA_PERF_DEFAULT` was 1, i.e. a per-frame QGAPERF line by default. `ffae88a` (2026-08-27) set `QGA_PERF_DEFAULT` to 0 and moved SYNTHPAINT under ProtoTrace for log-size reasons. The drag law is a delayed-feedback controller whose constants were fitted at a measured 13.7 announces/s that the ladder itself calls "saturated by the window's own movement", not by the 50 ms pacing floor (which would allow 20/s). Remove the logging and the saturation point moves. HYPOTHESIS, not measured - the announce cadence on a quiet build has never been measured, because the only instrument that measured it was the thing that slowed it. That is what `ProtoTraceDrag` exists to close. UNVERIFIED
- The four-fix drag-wobble series of 2026-08-12 (`43de7d4`) was reverted whole by `e2f36be` because sub-fix 1 (suppress ALL PrintWindow recapture for the latched window) made it worse. The other three - rate-limiter exemption for the latched window, inbound MSG_MOTION coalescing, and IGNORE MID-DRAG DAEMON CONFIGURES WHILE THE LATCH HOLDS - were measured INERT that day and reverted as collateral. None was ever re-landed. The configure guard is worth re-testing specifically, because the machinery it guards against (`DaemonStreamTick`, `ApplyPendingDaemonMove`) landed in `336ccc7` AFTER that measurement, so "zero inbound configures inside the latch window" was measured on code that did not yet have it. Re-added as `InputDragCfgGuard`, DEFAULT OFF, with the trace that decides it. [verified 2026-09-01]
- `scratchpad/drag-armcheck.ps1` reads `HKLM\SOFTWARE\Qubes\GuiAgent`, which is not the key the agent uses (`HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent`). Its `overrides = "none (shipped defaults)"` answer was structurally incapable of reporting an override, so it is not evidence for any run it was used on. [verified 2026-09-01]
- Residual BY DESIGN: `AdoptMs` assumes a constant dom0 apply lag against a measured median 0 / p75 17 / tail 82, 398 ms. Events past adopt take the wrong sign. [verified 2026-08-16]
- The instrument now exists and is calibrated: `ProtoTraceDrag=1` (input-rate QGAPROTO lines only, ~44/s, no per-rect DAMAGE flood so feel and mechanism come from ONE run), `msg=MOTION br=` naming the translation law actually taken, `msg=DRAGLATCH` naming every arm/teardown, and `tools/drag-analyze.py`. Arm with `guest/drag-trace-run.ps1 -Sim 0`, pull with `guest/drag-trace-pull.ps1` (pulling must never use the -run script: it restarts the agent and would destroy the episode). [verified 2026-09-01]
- `guest/sample-window-motion.ps1` REPORTS `armed: true` AND WRITES NOTHING - the task ends Ready with no winmotion.txt, not even its own "no notepad" sentinel. Fix it and prove it writes a file BEFORE asking anyone to drag. Three hand drags on 2026-09-01 produced zero measurements. [verified 2026-09-01]
- The "next suspect" from the previous session - the frame-path insertion from the secure-desktop freeze work (878ae5e, 7e3f0b6, fb4c1cd) - was NOT the cause and needs no further work: its body only runs on the secure desktop, and the measured drag ran entirely on the Default desktop. [verified 2026-09-01]

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

## 2026-08-01 session-5 (win11 line): drag phantom verified fixed; keytips synthesize-or-drop

**Deployed on win11-idd-test: `4.2.2+agent.d61045417ed6`** (CI 30700488504).

### Snap-layout drag phantom (3c12071): VERIFIED FIXED
- Deployed `4.2.2+agent.3c1207143254`, then log-verified: dragging raised the transparent
  `XamlExplorerHostIslandWindow` and `ShouldAcceptWindow` rejected it
  ("click-through uncapturable shell overlay ... rejecting"), no oversized slice-fed attach.
- **User dragged by hand and confirmed: no artifacts in dom0.**
- Contrary to the session-4 note, synthetic input DOES reproduce the drag overlay: a SLOW
  stepped drag (SetCursorPos+mouse_event, 5px/30ms steps after a proper engage) raises it.
  Fast/jumpy synthetic drags were what failed. `scratchpad/dragtest.ps1` pattern works.
- Win+Z raises a DIFFERENT XamlExplorerHostIslandWindow flavor (344x244, NO WS_EX_TRANSPARENT,
  clickable) - correctly announced+slice-fed+raised, correctly unmapped on dismiss. The
  rejection triple (TRANSPARENT+NOREDIRECTIONBITMAP+TOOLWINDOW) leaves it alone by design.

### Keytip badges (OPEN #1): FIXED by d610454 (synthesize-or-drop + foreground owner pref)
- `d610454` in AddWindow: sub-floor override-redirect popups (below SM_CXMIN/CYMIN) that
  fail SynthQualifies get DeletePending and are dropped SILENTLY instead of being announced
  as bordered slice-fed fragments (RemoveWindow is already silent for !CreateSent entries).
  Materialization re-adds through the same gate, so a badge drifting out of its owner is
  re-dropped, never announced.
- Also in `d610454`: same-process fallback owner now prefers the FOREGROUND window over
  topmost-containing (two-same-process-windows ambiguity from session-4).
- Verified with TWO Notepad windows of one process: log shows per-geometry owner assignment
  (0x40236/0x60250/0x80238 -> owner 0x301be; 0x9024a at x=2103 -> owner 0x70072), SYNTHPAINT
  for each, zero announcements/materializations. dom0 fullshot mid-Alt: F/E/V badges render
  borderless and pixel-correct inside the red-bordered win11 Notepad. No bordered fragments.
- Alt keytips hold as long as needed for a shot if you don't send Esc; fullshot takes
  ~20-60s per capture, so budget one shot per ~45s hold (`scratchpad/keytiptest.ps1`).

### Operational notes
- Agent log level: the effective knob is the PER-MODULE key
  `HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent\LogLevel` (overrides the base
  key). The watchdog does NOT recycle the agent on service restart - `Stop-Process gui-agent`
  and let the watchdog respawn it. LogLevel=4 floods (per-second window dumps; one perf
  sample showed log=13593us) - restored to 3 after testing.
- `qrexec-client-vm dom0 local.WinFullScreen` HANGS without `</dev/null` - use
  `tools/qtest fullshot`, which already does it right.
- Intervening commit `3f7c956` (synthesis paint-skip diagnostics) from the parallel session
  is in this build's history; coordinate as before.

### Still open (unchanged): synthesis flap during drags (#2), WorkAreaCreateListener 0x5 (#3),
### GetRealWindowRect 0x80070006 bursts (#4), Win10 regression pass for all five fixes (#5).

### 2026-08-01 — "attaching a netvm makes the guest unresponsive" = NO PV NETWORK DRIVER
User observed twice that giving win-idd-test a netvm renders it unresponsive, and that
removing the network makes it instantly responsive again. Diagnosed on the clean guest:

| probe | result |
|---|---|
| `Xen PV Network Class` PnP device | **Unknown** (never started) |
| `xenvif` system driver | **Stopped** (while xenbus/xenfilt/xeniface are Running) |
| `XP0001 XENBUS VBD`, `XENBUS CONS` | **Error** |
| active NIC | **Realtek RTL8139C+** (emulated), IP 10.137.0.64 |
| `System` process CPU | **269 s** (top consumer by an order of magnitude) |
| QWT network-setup log | `GetAdaptersInfo failed with 0xe8, retrying` for ~4 min, then settles on "Adapter 6: Realtek RTL8139C+" |

Mechanism: with no PV netfront the HVM falls back to the QEMU-emulated RTL8139, which
traps to the device model per packet. That burns kernel time in-guest and device-model
time out-of-guest, starving the GUI agent and qrexec -> the VM looks hung. Detach the
netvm and the emulated NIC goes idle -> instant recovery. Both observations explained.

NOT a regression from our agent work: it is a PROVISIONING gap. Our unattended install
runs QWT's MSI with an ADDLOCAL feature list (guest/install-qwt.cmd); the PV network
driver is either absent from that list or failed to bind. The PV stack is partial -
enough for vchan/qrexec (xeniface), not for networking (xenvif stopped).

NEXT SESSION, before the Office test:
1. Inspect `guest/install-qwt.cmd` ADDLOCAL and compare against the MSI's feature table
   (`msiinfo`/`msidump` on ~/win-iso/qwt-iso/installer.msi from Linux).
2. Re-run the MSI with the network feature enabled, reboot, confirm `xenvif=Running` and
   a `Xen PV Network Class` adapter carrying the IP instead of the Realtek.
3. Only then attach the netvm for Office + `slmgr /ato`. Expect normal responsiveness.
This is also a strong argument for the full source build: a correctly-bound PV driver set
is what a real QWT package installs and what our overlay approach can never fix.

## RESULT (T1, aaa8c37): VALIDATED — control failed as required

Method: one **cold boot per side** (in-place restarts are unusable, see above), binary installed
with the agent stopped and the installed hash compared to the CI manifest before every run,
`chromerepro --mso` for the scene, metric = `SendWindowMap` announcements for the strip HWNDs
taken from the same `dump-windows` snapshot. Three rounds per side, interleaved.

| round | build | strips present | **strips announced to dom0** | main announced | total |
|---|---|---|---|---|---|
| r1 | stock `4B4CE2B1…` | 4 | **4** | 1 | 7 |
| r1 | fix `4DA9FE96…`   | 4 | **0** | 1 | 3 |
| r2 | stock              | 4 | **4** | 1 | 7 |
| r2 | fix                | 4 | **0** | 1 | 3 |
| r3 | stock              | 4 | **4** | 1 | 7 |
| r3 | fix                | 4 | **0** | 1 | 3 |

Unanimous and clean: 4/4 vs 0/4, three times each, and the difference in `total` is exactly the
four strips. **The check has been seen to FAIL on a build carrying the defect**, which is what
makes the PASS mean anything (CLAUDE.md evidence rule 5). `MAIN_MAPPED=1` on every run proves
gui-daemon was connected and the instrument live, so a zero is a real rejection and not silence
from a dead daemon. Every run was also a cold boot, so the boot path is covered.

### Scope of this result — read before quoting it

- It validates **`aaa8c37` only** (reject `MSO_BORDEREFFECT_WINDOW_CLASS`).
- **`66fc670`** (never re-home an owned popup onto an untracked owner) and **`6b5b298`** (never
  capture while the secure desktop is up) are **still unvalidated**. They were present in the
  binary under test but nothing here exercised either path.
- It is measured against `chromerepro --mso`, i.e. Office's class and ex-styles at a
  floor-clearing thickness — not against real Office. Given the mechanism is a pure class-name
  comparison, and real strips were separately observed to be admitted on a fork build, this is
  strong but not identical to an end-to-end Office test.

### `qtest shot` cannot see layered windows — first instrument was doubly worthless

An attempt to add pixel evidence failed and is recorded rather than dropped: with the **control**
build announcing all four strips, `qtest shot` still returned exactly **one** PNG, byte-identical
(md5 `36efd5a5…`) to the fixed build's. `local.WinScreenshot` uses `import -window <id>`, which
silently fails on `WS_EX_LAYERED` windows — the chromerepro README already warned of this and I
re-derived it the expensive way.

So counting PNGs, today's first instrument, was not merely noisy: **it is structurally blind to
exactly the windows this bug creates**, and would report a PASS against a build with the defect
fully present. No pixel-level before/after is obtainable from this dev qube; the daemon-side
"five bordered fragments vs one" can only be confirmed by a human looking at dom0's screen.
The agent's announcement log is the authoritative instrument available here.

## Stock QWT is the wrong control here too — for a different reason than the strips

Composite synthesis does not exist upstream; it arrived in fork commit `0a334c1` ("Composite
synthesis: owner-contained popups painted into their owner, never announced"). Stock therefore
emits no `msg=SYNTH` under any circumstances. The control for `66fc670` must be **agent
`aaa8c37`**, the commit immediately before it, built from throwaway branch `control/aaa8c37`
(superproject pins the submodule there; `workflow_dispatch` builds it — do not merge that
branch). Control binary `6554EFED…`, test binary `4DA9FE96…`.

That is now twice in one day that the obvious control — "the binary that shipped" — was
incapable of exhibiting the defect under test, each time for a different reason. **Before any
future A/B: ask what makes the control able to FAIL, and confirm the feature under test even
exists on that side.**

## The repro's own ordering was the third dead control

Synthesis adopts a popup into a **tracked** same-process, non-override-redirect sibling.
chromerepro created the orphan popup before `ShowWindow(g_Main)`, so the popup reached the
agent while no sibling was tracked yet; `SynthQualifies()` then failed for want of a
*candidate* rather than because of the fix, and both builds announced it identically. The
agent log shows it plainly on the control: `AddWindow` → `SendWindowCreate` for the popup at
`.564`, and the main frame's `PwAttachWindow` only at `.689`. Fixed by creating the orphan
last, after pumping messages for 3 s.

Also fixed here: the measurement parsed only the LAST `###` snapshot of `dump-windows`, which
is empty whenever the process is killed just after writing a header — that read as "the scene
is missing" and failed a run that was fine. It now scans every snapshot and dedupes by HWND.

## RESULT (`66fc670`): VALIDATED — control failed as required, on two opposed signals

Control = agent **`aaa8c37`** (`6554EFED…`), test = **`6b5b298`** (`4DA9FE96…`),
`PerWindowCapture=1`, scene `chromerepro --orphan`, one cold boot per side, installed hash
compared to the manifest every run, 3 interleaved rounds.

| round | build | orphan synthesized | adopted by main frame | orphan announced |
|---|---|---|---|---|
| r1 | control `6554EFED…` | **1** | **1** | 0 |
| r1 | fix `4DA9FE96…`     | 0 | 0 | **1** |
| r2 | control              | **1** | **1** | 0 |
| r2 | fix                  | 0 | 0 | **1** |
| r3 | control              | **1** | **1** | 0 |
| r3 | fix                  | 0 | 0 | **1** |

Unanimous. The control adopted the popup into the frame every round — `SYNTH_ALL` naming the
exact pair each time (`0x1029c->0x7005c`, `0x3025e->0x10292`, `0x102a4->0x50164`) — and the fix
synthesized nothing at all in any round.

What makes this hard to fool is that the **two signals move in opposite directions**. A
synthesized popup is painted into its owner and deliberately never announced, so the control
reads adopted-but-unmapped while the fix reads refused-but-announced. A confound that merely
suppressed synthesis would drive both counts to zero; a dead gui-daemon would suppress the
announcement too. Only the intended behaviour produces the observed inversion, and
`ORPHAN_PRESENT=1` on all six runs confirms the scene was actually built every time.

### Scope — same caveats as `aaa8c37`, plus one

- Validates `66fc670` only. **`6b5b298` remains unvalidated.**
- The defect is **unreachable at the shipped default** (`PerWindowCapture=0`), so this fixes a
  real path that is latent in the default configuration.
- Measured against `chromerepro`, not real Office. The mechanism is generic (any app whose
  owned popup points at an untracked owner), which is precisely why the synthetic repro is
  appropriate here — but it is not an end-to-end Office test.

# 2026-08-05 (cont 4) — the user was right: the stress missed the real drag path. Two fixes, one bounded fragility

**User-reported breakage after real manual resizes, screenshot-confirmed:** dom0 window
showed interleaved content GENERATIONS — a diagonally sheared band of old-geometry pixels
(own taskbar + watermark) inside the new-size window. My stress had validated settled
one-at-a-time syncs; a real drag is a MSG_CONFIGURE stream, and the v0 loop replugged the
monitor PER REQUEST. Two distinct defects:

1. **Stale patchwork after a grant switch.** The existing full repaint fires when the
   re-grant is SENT; under overlapping recoveries stale damage still interleaves. Fix
   (agent 177ac32): a second full-screen repaint ON THE WINDOW-0 DUMP ACK — the one point
   where the new mapping is provably current on both sides. Validated: A6ACKREPAINT fires
   (3/3 settled syncs), decoded screenshot after churn is a single clean generation.
2. **Per-request replug during drags.** resize-sync rewritten: debounced latest-wins —
   act only when the newest dom0 request is stable for 2 polls and differs from current.
   One replug per gesture, exactly the pattern every hypervisor stack ships (survey §4).

**Bounded remaining fragility, honestly stated:** deliberately bypassing the debounce
(3 back-to-back -SyncNow, no settle) wedged the guest AGAIN — qrexec dead, cputime slope
~1.9 vcpu-s/s (measured with the FIXED sampler), ACPI shutdown never processed, kill
required. The livelock family is real and is triggered by rapid display-topology churn;
the debounce keeps normal use off that path but does not fix the underlying guest-side
defect. Next diagnostic requires deliberate reproduction with dom0 forensics staged
(protocol exists, evidence dir instrumentation/hang-2026-08-04/).

**gui-daemon coin-flip death observed again** on the second graceful agent install of one
boot (agent waited at "Awaiting for a vchan client", zero dom0 windows, empty screenshot) —
one more datapoint for the §3 upstream report (DESIGN-gui-daemon-restart-survival.md).

State: agent AD4DE497 (A6+A7+ackrepaint) running, IDD primary, debounced loop live,
guest at 2560x1440 clean. D4v2 stable-EDID fix still iterating in CI.

# 2026-08-05 (cont 7) — "it died" root-caused: ONE denied SendInput killed the agent AND the daemon

The user's window death during their drag was neither the livelock nor grants. The wedged-
looking state had qrexec ALIVE and zero CPU spin — only gui-daemon was dead. Agent log,
17:24:39: guest idled ~9 min → lock screen took the input desktop → dom0 sent mouse motion →
`HandleMotion: SendInput failed with error 0x5 (ACCESS_DENIED)` → **HandleServerData treats
any handler failure as fatal** → agent exits → vchan closes → gui-daemon EOF death (the
known dom0 coin-flip) → window gone. A single undeliverable mouse event took down the whole
GUI chain. This crash class is trivially triggerable: UAC secure desktop, idle lock, any
desktop switch.

**Fix (agent 8ad3f1e+f37759c, deployed A11F5E60, stack t2/resilience-stack):** all six
SendInput sites route through InjectInput() — log, best-effort AttachToInputDesktop for the
next event, DROP the event, continue. Protocol-safe (body already consumed). Input
injection failures are never fatal again.
**Hygiene:** the test qube no longer idle-locks or blanks (NoLockScreen=1,
InactivityTimeoutSecs=0, monitor-timeout 0) — a guest whose input comes from dom0 must
never take the input desktop away.
**Also observed:** CaptureTeardown revoke noise 0x490 on that exit path (grant already
gone) — harmless, but confirms exit-path revokes can no-op.

Full acceptance soak per the user's gate ("test until it does not die, misbehave, or revert
to 2560x1440") running: scratchpad/soak-full.sh — 30 cycles of exact resizes (never
2560x1440), agent restarts every 3rd (size must persist; daemon deaths counted separately
as the KNOWN dom0 bug), reboots every 5th (size+topology must persist), pixel checks,
stop-at-first-hard-failure.

# 2026-08-05 (addendum 2) — the lost-resize bug: filter ate real intent; now suspect-only + defer

User-reported "last resize failed": the widened settle-window filter DROPPED a genuine
settled request (2055x1308, 3.3 s after a 2734x941 apply) — a settled drag's request never
re-arrives, so the drop was a permanent loss. The same trace also delivered the day's best
performance datum: **the agent-native IOCTL obtain applied a novel size in 356 ms**
(RESREQ→ioctl-reload→RESEXACT replug=1), no PnP, first live use.

Fix (agent a38c2f5, deployed 3DCEAD75): echo suspects are ONLY the pre-apply size and
desktop-transit sizes recorded during the obtain (recovery path feeds them via
ResolutionNoteTransitSize); suspects are DEFERRED to the settle-window end then applied
(worst case one convergent late bounce), never dropped; fresh sizes apply immediately.
Machine check: rapid pair 2222x1111 → 2345x999 (second inside the first's window) both
applied exactly. Real-drag confirmation is the user's.

# 2026-08-05 (addendum 4) — wrong-jump #3 fixed (75 ms announce race); device sounds silenced

The user's third wrong-size jump: the capture thread's recovery cycle announced a transit
mode (A6CONFIGURE 1920x1080) 75 ms AFTER the resolution thread's apply cleared the in-flight
flag — outside the suppression gate — and the daemon echoed it back into an apply. Fix
(deployed 2977CCD8): the announce gate now covers the whole settle window; while it is open
ONLY the exact target geometry may be announced, and suppressed geometries are recorded as
echo suspects (which the defer filter then handles even if one leaks).

Also: monitor replugs fired Windows' device connect/disconnect sounds on every resize —
silenced via HKCU AppEvents (DeviceConnect/DeviceDisconnect/DeviceFail set to no sound).

Resize-service note: the repo's dom0/10 installer had regressed to the v1 title-matching
body, which is what the user's reinstall deployed (still no_window). v2 restored in the repo
from git history (commit 15d530a); needs one more user reinstall to unlock scripted
real-MSG_CONFIGURE soaks.

# 2026-08-05 (final 2) — REAL-PATH DRAG SOAK 28/28; held-frame masking deployed

**The goal's invariant is machine-proven on the true path.** With the user-installed
_QUBES_VMNAME resize service, soak-drag.sh drove 28 cycles of REAL dom0 WM resizes
(14 drag-like configure streams + 14 jumps) through gui-daemon into the agent-native
exact-follow: 28/28 triple-converged (requested == dom0 window == guest resolution),
zero wedges, zero reverts, zero crashes — and ALL 7 graceful agent restarts kept
gui-daemon alive (0 EOF deaths this run; earlier today 4-6 of 10 — the settle-gate
sequencing has narrowed the dom0 race substantially, dom0 patch still the real fix).
4 clean reboots, sizes persisted. DeviceFail canary silent across ~40 replugs.

Along the way this session closed, in order, the full echo-family: (1) mid-drag snap
applies (exact-follow), (2) pre-apply-size echo (RESECHO), (3) transit-size echo via
A6CONFIGURE (in-flight gate), (4) the 75 ms announce race (settle-window gate), (5) the
re-dump geometry channel (A6DUMP gate), (6) lost-real-intent from over-filtering
(suspect-only defer). Plus: device plug sounds silenced (DeviceFail kept as canary),
shadow-cursor re-blank per mode change.

**Held-frame masking deployed (agent 3362f62, exe 5EA4CDF8, user-committed):** during
exact-obtain/settle no screen damage is sent - the daemon freezes on the last clean frame
and snaps fully painted at the final size, replacing the transient sheared-band mangling
(the last user-visible defect). Scripted drag-stream verification converged exactly
(2260x1130 triple-equal); the freeze-vs-mangle visual is the user's confirmation.

# 2026-08-06 (close) — M7 + fit guard landed; the idle/deaf wedge still reachable via drag soak

**Fit guard** (agent on t2/fit-guard, deployed 6177C57F; user rule "if remembered geometry
does not make sense, snap to the nearest that does"): a dom0 request whose FRAME cannot fit
the work area snaps to the largest published habitual size that does; when none is known the
current resolution is kept. Verified live: `RESFIT 5120x1440 does not fit work area
5110x1379 - snapping to 5110x1379`. This is what stops a WM-remembered oversized geometry
(seen when the daemon window is recreated after an agent restart) from pushing borders
off-screen.

**Status of the wedge, stated honestly.** M7 defeats the *storm* reproduction decisively
(6/6, replugs 4→0 after the first pass). It does NOT eliminate the idle/deaf failure: the
real-path drag soak reached cycle 10 (9 gestures, 2 agent restarts, 1 reboot, all
converged exactly) and then qrexec died again. So the remaining trigger is not raw replug
RATE alone — the drag soak's replugs are already spaced by M7 — and the PV-servicing defect
is still reachable under sustained mixed load. Guest-side mitigation has taken it from
"first storm" to "~10 mixed cycles"; the rest is the dom0/PV side.

**Two harness corrections this session** (both mine, both the same class as before):
soak-full.sh RETIRED — it drove raw devcon PnP restarts through the obsolete SyncNow path,
manufacturing the very churn it then reported; soak-drag.sh now (a) asserts guest==CURRENT
dom0 window after a restart rather than the pre-restart size (the WM legitimately re-places
a recreated window — the earlier "REVERT" was a false alarm) and (b) treats a missing dom0
window as the KNOWN daemon EOF bug: reboot and continue, not fail.

Deployed: agent 6177C57F (staging + exact-follow + never-exit + echo/announce gates +
held-frame + M6 + A4-lite + M0-tail + M7 LRU/limiter + fit guard), driver 70C64039 (D4v3 +
stable EDID). Snap battery PASS 4/4 on this build.

## 2026-08-07 — PV mismatch is REAL and lives inside the QWT 4.2.2 payload; upstream drivers would bind

Chased the user's question ("if they are byte identical, how come they announce different
hw?") to a concrete answer by fetching the Xen Project's own Windows PV drivers
(https://xenbits.xen.org/pvdrivers/win/, index reachable, tarballs dated 2023-07-13).

    QWT 4.2.2 xennet (stock AND ours - byte-identical):  requires REV_09000005
    QWT 4.2.2 xenvif child, as enumerated on the guest:  offers  REV_09000004 ... 09000000
    UPSTREAM Xen Project xennet 9.1.0.3:                 requires REV_09000003
    UPSTREAM Xen Project xenvif 9.1.0.2

So the QWT 4.2.2 payload is INTERNALLY INCONSISTENT: its xennet demands an interface
revision one higher than its own xenvif publishes, so the NET child can never bind and
Windows falls back to the emulated Realtek NIC. Since our MSI's PV binaries are byte-identical
to stock's, **stock QWT 4.2.2 has the same defect** - this is not something we introduced,
and it is not "wrong codebase" on our side.

Upstream's xennet 9.1.0.3 asks for REV_09000003, which IS in the device's hardware-ID list
(04/03/02/01/00). So swapping in the upstream pair is a plausible fix, exactly as the user
suggested.

RETRACTED along the way, in order: "wrong codebase" (refuted by the byte diff);
"upstream packaging bug" (premature - it is a QWT PACKAGING inconsistency, upstream's own
pairs look self-consistent); "the 2026-08-06 networking result ran over the emulated NIC"
(I back-projected today's observation onto an entry that never recorded the adapter);
"stale cached devnode" (cannot apply to a freshly installed system, as the user pointed out).

BEFORE acting on the driver swap, two things must land:
1. The fresh-guest reading from `win10-clean` (health gate now includes `pv_drivers_bound`) -
   it says whether a never-upgraded guest binds PV. Everything above predicts it will NOT.
2. Whether replacing PV drivers inside the QWT MSI is acceptable at all: they are
   attestation-signed by Xen Project, our guests run testsigning, but a real release would
   need the signing question answered. That is a USER DECISION, not mine - it changes what
   the product ships beyond the agent.

## 2026-08-11 (cont.) — RETRACTION + the REAL artifact, measured: announced rect > visible card

**RETRACTION of the "ghost windows" entry above.** Two flaws, both mine:
1. My guest enumeration is taken via qrexec, and a qrexec call STEALS FOCUS AND CLOSES THE START
   MENU (established earlier the same session). So "dom0 has Start, guest does not" can be produced
   by the instrument itself. The user also corrected me: nothing had been closed on their side.
2. That same enumeration returned only Notepad/EdgeUi/Progman - it had also LOST Shell_TrayWnd,
   which earlier runs did list. An enumeration missing the taskbar is not a trustworthy basis for
   declaring anything absent.
The Start menu subsequently vanished from dom0 on its own (user: "it vanished now"), which is what
a correctly-unmapped window looks like. **The ghost claim is withdrawn as unproven.** The three
unmatched SendWindowMap lines remain interesting but prove nothing on their own - a mapped window
that is still legitimately open produces exactly the same log.
`tools/rendercheck`'s ghost detector must therefore NOT be trusted while guest truth comes from a
focus-stealing qrexec call; treat `ghosts_in_dom0` as a hint, not a verdict, until guest truth is
collected without touching focus.

**WHAT IS REAL, and it is the artifact the user described.** The "New notification" window is the
OneDrive "Turn On Windows Backup" toast - a PERSISTENT ACTIONABLE notification ("Remind me again
in: 1 Week", "Let's get started" / "No thanks"), so it legitimately stays until dismissed. Measured
from the dom0 capture:
    announced / bordered by dom0 : 1524,700  **396 x 332**   (border rect measured: exactly that)
    actually visible toast card  : 1526,731  **377 x 287**
    => dead margin INSIDE the announced rectangle: **19 px horizontally, 45 px vertically**
The margin is not empty: it shows whatever was composited beneath (guest wallpaper here), and dom0
draws its qube border around the FULL announced rect. That is precisely the user's "thin border,
with some extra stuff within rectangle" and their "announced geometry does not match REAL geometry
either". The cause is the usual Win11 convention gap - the window rect includes the drop-shadow /
invisible margin, while the visible card is smaller (the same 7px-class discrepancy that made
render-truth.ps1 need DWMWA_EXTENDED_FRAME_BOUNDS: 1440x753 vs 1426x746 for Notepad).

This is exactly what `docs/TOAST-fix-plan.md` proposes (CropL/T/R/B in WINDOW_DATA applied inside
GetWindowData) - now CONFIRMED LIVE with numbers instead of being a design guess, and it applies to
any shadowed popup, not just toasts. Note the Start menu measured EXACTLY 858x890 border vs card
earlier, i.e. Start does NOT show this margin - so the crop must be derived per window (from the
DWM frame bounds vs window rect), never a constant.

## 2026-08-11 (cont.) — S1a FIXED on 25H2; new live defects recorded for handover

Build d342e93a (geometric crop + the NULL-deref crash fix) deployed to win11-fresh, hash-verified,
crash-loop check PASSED (PID 1136 unchanged over 75 s, log count static at 157 - no rotation).
dom0 now announces:
    Start            544,219  832x736   (was 531,142 858x890; measured card left/width = 544/832)
    New notification 1540,730 364x289   (was 1524,700 396x332)
Both equal the drawn card; the user confirms the menu "looks fine". **GWeck's S1a is fixed on the
surface he reported it on.** Remaining for S1a: cold-boot repeat, and a 24H2 non-regression check
(24H2's Start has no margin, so its announce must STAY 858x890).

NEW DEFECTS the user reports on this build, recorded not diagnosed (leads in the handover):
 - ALL windows react weirdly to DRAG (Feedback Hub especially). Suspicion order: the never-run
   performance gate (rank 2 added a ring query per message; QGAPERF shows dt~520 ms / acq~515 ms in
   this period, though much of that is idle wait), then the HandleConfigure crop-suppression branch
   (ruled out by inspection for uncropped windows - WINDOW_DATA is zeroed at main.c:913-922 - but
   unverified at runtime), then the HandleButton/HandleMotion locking change.
 - An overlap bug, no capture obtained: by the time the fullshot ran every dom0 window had been
   destroyed and re-announced (IDs 0x1c0018f... -> 0x1c001a1), leaving only the unmapped VMapp entry.
 - Toasts: geometry now correct but still NOT CLICKABLE, wrongly positioned (guest 1920x1080 inside
   a 5120x1440 dom0 screen puts a guest-corner toast mid-dom0-screen), not draggable, and multiple
   toasts should stack.
 - Start should be a NORMAL (WM-managed) window rather than override_redirect, and reachable as a
   regular app-menu item; the Win key should not work from seamless apps at all.

## 2026-08-12 — Defects A+B root-caused ON THE LIVE GUEST (scripted drag reproduces both)

Instrumented reproduction on win11-fresh, build d342e93a (agent PID 1136, hash-verified):
`guest/drag-harness.ps1` (new: SendInput circle-drag of Notepad, 60 Hz, precise t0/t1) +
`guest/perf-window.ps1` + `guest/log-window.ps1` + `guest/reset-census.ps1` (all new).

**Defect B is deterministic from a drag.** One 16 s scripted drag: every dom0 window ID changed
(0x1c001b1..b7 -> 0x1c001b9..bf) and Notepad+Feedback Hub came back mapped=0. Log shows the chain
at 23:56:46: `CaptureThread: error/timeout waiting for frame processing` (capture.c:1330 waits
1000 ms for ready_event, comment says "XXX arbitrary timeout") -> error_event -> main loop FULL
RESET: destroy screen window, AttachToInputDesktop, XcOpen (new handle), SendScreenGrants,
DESTROY+CREATE+MAP of every window (~2 s outage). Census: **6 such resets in 25 min**, four in
23:39-23:43 = exactly the user's "weird drag/overlap" period. RecreateDuplication count = 0 - this
is NOT the DDA recovery path, it is the frame-processing timeout.

**Defect A measured under active drag** (45 QGAPERF frames in 16 s):
    dt  p50 113 ms   p95 1.01 s   max 4.5 s      (idle-active before: 14-43 ms)
    dmg p50  77 ms   p95 972 ms   (the dominant phase; suspiciously clipped at the 1 s timeout)
    snd p50 0.3 ms   max 7.7 ms   (raw vchan send is NOT the cost)
    enu p95 171 ms  max 218 ms;  wak p95 187 ms  max 223 ms;  upd max 115 ms (spikes)
Dragged window's MSG_CONFIGURE goes out at ~1 Hz during a 60 Hz drag = the "weird" feel.

Also caught, standing defects on this guest:
 - `WorkAreaApply: SPI_SETWORKAREA failed 0x57` EVERY 30 s (51 times) - retry loop never succeeds.
 - Agent log is 145 MB after 25 min at LogLevel 3 (DAMAGE per-rect lines dominate).
 - A3CHECK grant geometry g=5120x1440 vs ctx=1920x1080 on every reset (fullscreen-size grant while
   the guest desktop is 1920x1080 - check intended).
 - Boot-time 0x887a0026 keyed-mutex AcquireNextFrame failure recovered by A7RETRY (known).

## 2026-08-12 (cont.) — ProtoTrace A/B gate + reproduction attempts + S1a cold-boot PASS

Interleaved gate (3 runs/side, same binary d342e93a, agent restarted identically each run,
fresh boot, no toast): ProtoTrace=1 vs 0 both HEALTHY under drag (dt p50 ~17.5 ms both; tot max
580 ms vs 66 ms - ProtoTrace has a real tail cost but is NOT the collapse). The pre-reboot
collapse (dt p50 113 ms) did NOT reproduce after reboot under: toast visible, Feedback Hub
running, ProtoTrace=1, Start opened, drag - separately or combined. The catastrophic state is
SESSION-STATE dependent (suspect: earlier fullscreen RESAPPLIED 5120x1440 poisoning believed
geometry; grant IS g=5120x1440 vs ctx=1920x1080 per A3CHECK). Mechanisms to fix regardless:
 1. capture.c:1330 1000 ms wait treated as FATAL -> full reset = defect B (proven live).
 2. ProtoTrace DAMAGE trace does GetRealWindowRect + g_csWatchedWindows lock PER RECT (send.c
    ~905, commit 8f9c004) - measured tail contributor.
 3. toastcrop sync UIA on the single WatchForEvents thread (verifier: bounded transient per
    (hwnd,w,h) slot, 3 attempts x 500 ms; Start ANIMATES size -> fresh slots).
 4. CODE-PROVEN (adversarially verified): DESTROY send failing in degraded mode leaves hwnd in
    created-set AND destroyed-ring; CREATEDUP branch returns before ClearWindowDestroyedLocked
    (send.c:527-556) -> window permanently drops damage. Fix: clear the ring in that branch.

**Win-key CAN open Start on 25H2** when sent from an interactive-session scheduled task
(guest/open-start.ps1) - direct qrexec keybd_event fails, the session was the difference.
Automated S1a testing is now possible.
**S1a COLD-BOOT CHECK PASSED**: after kill+start (guest wedged during a drag run - qrexec dead,
display live; killed+restarted), Start announces 544,219 832x736 = the drawn card.
**Persistent toast trigger**: guest/fire-toast.ps1 (reminder-scenario toast stays until
dismissed) - gives a stable shell surface for measurements.

## Fix bundle (agent b92506c..8be83b8, submodule bump cca7d4e), verified in code + adversarial
review, NOT yet run on a guest:
 1. capture.c: slow main loop tolerated up to 15 s (was: 1 s timeout = fatal full reset =
    defect B). FI proof: FI_PUMP_STALL.
 2. HandleButton: clicks carry their own absolute position (ButtonAbsolute=1 default).
 3. CREATEDUP clears the destroyed ring (failed-DESTROY damage-drop, code-proven).
 4. Wobble probe (per-rect GetRealWindowRect+lock) opt-in via ProtoTraceWobble.
 5. toastcrop: UIA on a dedicated worker (own IUIAutomation, no shared lock during RPC),
    tracking path cache-only, PokeWindowTracking on resolve, 2 s whole-walk deadline.
 6. resolution.c: adopt-applied on mismatch (fix A2), ResolutionAdoptCurrent on
    WM_DISPLAYCHANGE + 2 s drift tick (RESDRIFT), known-unappliable memo (60 s TTL).

## 2026-08-12 (cont.) — FIX BUNDLE VALIDATED ON win11-fresh (build 7db23513, agent 31ffaaf)

Deployed via swap-agent, hash-verified, crash-loop check PASSED (PID 6888 stable 105 s, log
count static). Verified against the same instruments that measured the defects:
 - **Defect B dead**: 3 interleaved drag runs, window IDs stable throughout, cap_timeout=0
   (was 6/25 min pre-fix, ~1 per drag). No 'main loop slow' lines even.
 - **Defect A dead**: drag dt p50 17.9 ms / p95 39.6 ms / max 154 ms over 1443 frames -
   AT 5120x1440, 4x the framebuffer area of the original collapse scene.
 - **Workarea fixed**: SPI_SETWORKAREA failures 0 (was 51); 'guest work area set to
   (16,64)-(5104,1424)' applied cleanly.
 - **RESDRIFT works**: 4 adoptions tracked the boot transit 5120->1024->1920->5120; A3CHECK
   converged to g=5120x1440 ctx=5120x1440 (pages 7200==7200). The 5120x1440 mode STUCK this
   session - the guest desktop now matches dom0, and the toast appears at 4724,891 = the real
   dom0 bottom-right. Toast POSITIONING largely resolves itself in this config; keep watching
   RESDRIFT counts for the unexplained reversion.
 - **Toastcrop worker bug found by its own logging gap**: worker alive, UIA ready, but zero
   measurements completed - the async lookups spent all 3 attempts in ~450 ms (pre-XAML).
   Fixed (attempts counted on completed measurements, 6x250 ms), CI round 3 in flight.
 - **Movability feasibility PROVEN**: SetWindowPos on a shell-band CoreWindow (by handle,
   from qrexec) moves it and the move sticks (guest/move-toast-probe.ps1). WM-managed shell
   surfaces are implementable; design pending (focus semantics, decorations).
Still needing the user's hand: dom0-side click on a toast (ButtonAbsolute path), dom0-side
window drag feel. Automated proxies all green.

## 2026-08-12 (cont.) — Round-4 build (ShellManaged) cold-boot validation on win11-fresh

Build e179e46f (agent fcafe61) deployed, guest COLD-BOOTED, hash-verified:
 - Toastcrop async worker WORKS after the pacing fix: first live toast measured insets
   16/30/16/13, announced 4735,1247 364x157 = the cropped card at the TRUE dom0 bottom-right
   of the 5120x1440 desktop. Positioning requirement: met in this config.
 - Toast is now WM-MANAGED (or=0): dom0 frames it; movable by the dom0 WM. Guest focus is
   NOT stolen when a toast fires (Notepad stayed foreground through fire-toast; the
   HandleFocus quarantine works).
 - 5120x1440 survived the cold boot; drag after cold boot: dt p50 19.5 ms over 436 frames.
 - **NEW DEFECT found by pixels: 25H2 Start at 5120x1440 maps a WORKAREA-SIZED (5120x1384)
   StartMenuExperienceHost window** - opaque white, WM-framed, covering the whole dom0
   screen, card content drawn top-left. The 90% exclusions (classifier + ratio guard) kept
   the crop away from it by design. Fixed in agent 4dc559b: no classifier ceiling, absolute
   card floor for oversize hosts. The geometric search already finds the 858x874 card.
 - Toastcrop measured a sibling StartMenuExperienceHost window 858x874 (card insets
   13/69/13/69) and correctly gave up (6 attempts) on a card-less 858x890 sibling - the new
   'no card measured' Info line works.

## 2026-08-12 (cont.) — DRAG REPLAY ROOT CAUSE FOUND (user live drag + ProtoTrace, build 172A72B1)

**RETRACTION: handover fact F1 ("the daemon sends NO MSG_CONFIGURE during the drag") is
WRONG for a dom0 WM title-bar drag and is hereby retracted.** Proof: the deployed agent's
trace contains SendWindowConfigure calls at input rate (70-100/s) with byte-identical
duplicates 3-8 ms apart. The ONLY code path that can emit those is HandleConfigure's ACK
(vchan-handlers.c:777) - it bypasses both the dedupe and the c9481cb rate limiter - and it
only runs when MSG_CONFIGURE arrives. During a title-bar drag the pointer is grabbed by the
dom0 WM: motion is NOT forwarded; the daemon relays ConfigureNotify as MSG_CONFIGURE at
input rate. (F1 was probably verified against a guest-native drag - different path.)

**Mechanism (1:1 trace, user drag 14:36:50-56 local, scratchpad drag-evidence-1.txt):**
1. Daemon streams MSG_CONFIGURE (the drag path: ~22 distinct positions per stroke).
2. HandleConfigure applied EACH as its own SWP_ASYNCWINDOWPOS at daemon coords, unconverted.
   Two defects: (a) the flood queues in the window's thread, which applies moves at frame
   cadence (~10 Hz at 5120x1440) - the GUEST window physically replays the path for ~2 s
   after release; (b) daemon coords are announce-space (DWM extended frame bounds), SetWindowPos
   is GetWindowRect-space -> every applied move lands +7 px off (invisible border).
3. The frame path (main.c "writer #2") honestly re-announces each lagging step: the trace
   shows the ENTIRE walk re-sent 1:1, offset exactly +7, at ~10 Hz, ~2 s behind - each value
   != LastCfg (dictated value) because of the +7, so the "don't echo the daemon" guard never
   matched. The daemon applies each announce as a real move -> dom0 window replays the path.
4. At 10 Hz the echo stream sails UNDER the c9481cb 16 ms rate limit -> that fix cannot help.
   Scripted in-guest drags produce no inbound configures at all -> F3 explained (they never
   reproduced it).
5. "What changed vs older QWT": nothing in the protocol - the session-start bisect already
   showed pre-existing. At 1920x1080 the apply/frame cadence was fast enough that the queue
   and the +7 bounce settled within 1-2 frames; at 5120x1440 (~10 fps frame path) the same
   loop smears into a visible 2 s replay. Drag cost = the amplifier, as the user suspected.

**Fix (agent, this commit):** three coordinated changes, all measured-cost-conscious:
 - LATEST-WINS APPLY: HandleConfigure stashes the newest daemon geometry; ApplyPendingDaemonMove
   posts at most ONE async SetWindowPos in flight per window (in-flight = GetWindowRect vs
   posted target, 200 ms timeout); applied at drain end + per frame. The guest-side replay
   queue can no longer form.
 - COORD CONVERSION: announce-space -> SetWindowPos-space delta cached per window (refresh
   >= 500 ms apart; the reverted 95492ed recomputed per configure and made things worse).
   Applied position now lands exactly where dom0 dictated -> the frame path's fresh rect ==
   LastCfg -> no echo at all; also kills the permanent +7 settle offset.
 - DAEMON-DRIVE SUPPRESSION + DAMAGE HOLD: while MSG_CONFIGUREs for a window are <300 ms old,
   position-only announces are withheld (dom0 knows where its own window is) and the window's
   damage is held (announced origin = daemon's framebuffer read origin; sending damage against
   a frozen origin would paint the window's OLD screen region). On drive end: flush announces
   the true resting position ONLY if it differs from what the daemon dictated, then one
   full-window settle repaint. CfgFlushPendingMove now flushes current canonical X/Y (a
   withheld stale intermediate must never be announced late) and skips byte-identical echoes.

## 2026-08-12 (cont.) — DRAG REPLAY FIXED, USER-CONFIRMED ("all good")

Build E3D6810A (agent 336ccc7) on win11-fresh, hash-verified, ProtoTrace on during the test:
user dragged real windows by the dom0 title bar and confirmed the acceptance criteria - no
jump-back, no replay, no settle wander. Automated gates all green on the same build:
 - toast: fired, cropped card at dom0 bottom-right, two toasts stacked correctly (fullshot
   pixels inspected, not just geometry);
 - census: cap_timeout=0, workarea_fail=0; scripted drag settles in 60 ms, ZERO post-release
   configures after the one settle announce (144 ms after release, exactly winrect+7);
 - A3CHECK g=ctx=5120x1440 pages 7200==7200, RESDRIFT adopted correctly on start;
 - benchmark within noise of 172A72B1 baseline (3 runs/side, hash-verified): dmg_p50 12-13us
   both, tot_p50 1.2-1.8ms (fix) vs 1.5-2.2ms (base), dt_p50 216-280ms vs 280-319ms.

## NEW PRIMARY (user 2026-08-12): frame-delivery collapse during drags

Both today's builds (172A72B1 AND E3D6810A) capture only 4-5 frames/s during a scripted
drag (dt_p50 216-319 ms, acq~=dt so the time is spent WAITING for frames), while the
morning fix-bundle validation on 7db23513 (agent 31ffaaf) measured dt p50 17.9 ms over
1443 frames - same VM, same 5120x1440, same harness. ~12x fewer delivered frames. The
user: predating the session does not matter, chase it and fix it. This collapse is also
the amplifier that made the drag replay visible at all.
Next experiment (serial): redeploy 7db23513 interleaved with E3D6810A, 3 runs each - build
regression vs environment/scene drift.

## the delta vs the README table is the GUEST platform

The user's standard: the baseline is the recorded canonical benchmark (README table, agent
09b643e, 2026-08-10, win11-idd-test) - guest-side drag cost counts even where dom0-side
corrections mask it. Method: instrumentation/drag-harness.ps1 phases + 250 ms sampling of
gui-agent cumulative CPU (guest/phase-cpu-bench.ps1), win11-fresh @1920x1080, 3 runs/side,
hash-verified.

| phase | README 09b643e | 2409BD22 (current) | 92C48AC5 (README-era binary, SAME guest) |
|---|---:|---:|---:|
| drag   | 8.67 | 13.0-15.6 (med 13.9) | 15.3-16.2 (med 15.7) |
| scroll | 3.51 | 5.2-7.1 | 3.9-4.9 |
| type   | 1.71 | 4.2-6.2 | 4.6-5.3 |
| idle   | 0.83 | 0.3-1.0 | 0.3-1.0 |

**Single-variable verdicts:**
1. NO agent-code regression: the exact binary behind the README numbers costs the SAME
   (slightly more) on today's guest/scene as the current build. The current agent is the
   cheaper of the two at drag on identical scenes.
2. Toast hypothesis (user): FALSIFIED - same binary, toast dismissed vs present: drag
   14.0-18.7 vs 15.3-16.2 = noise. An on-screen toast does not tax the occlusion path.
3. The 1.6-1.8x gap vs the README table is the GUEST PLATFORM (win11-fresh/25H2 vs the
   08-10 win11-idd-test guest): same binary, same harness, same resolution, different
   guest. Flagged as its own future investigation for guest-side drag UX (candidates:
   25H2 DWM/compositor changes, IDD driver version/config differences).

**New canonical references, final build D27E826B (agent 857965a), win11-fresh 25H2:**
 @1920x1080: drag 11.6/15.9 scroll 3.8/4.4 type 4.0/5.8 idle 0.7-2.9 (2 runs)
 @5120x1440: drag 11.4-16.5 scroll 4.2-6.4 type 2.7-4.5 idle 0.0-2.1 (3 runs)
 Run-to-run spread on this guest is high (~±25%); compare medians of >=3 runs only.

**Incident during the resolution flips (user-reported "rendering bug"):** restoring
5120x1440 via ChangeDisplaySettings switched the active display DEVICE (DISPLAY1->DISPLAY2,
IDD monitor); the guest shell lost every visible window (bare wallpaper, no taskbar;
processes alive; explorer never crashed) and the agent correctly announced nothing -
GetRealWindowRect handle-invalid spam while it chased the dying handles, prev agent
instance died in the transition. RECOVERY: explorer restart + fresh window = fully healed,
no reboot needed. LESSON: in-guest ChangeDisplaySettings mode flips can hop display
devices and collapse the shell's window set on this IDD-equipped guest - use them only
with a recovery plan; dom0-driven resize remains the proper path (unavailable in seamless).

## 2026-08-12 (cont.) — FINAL: clean cold boot on D27E826B, all green

Post-boot on the final build (agent 857965a): agent auto-start PID 5044, hash-verified,
RESDRIFT->A3CHECK converged g=ctx=5120x1440, fresh Notepad renders full chrome (no black
regions), toast card cropped+positioned at the corner, scripted drag settles 12 ms after
release with zero post-release configures. Shell fully healthy after the earlier
explorer-restart recovery + reboot.

WATCH ITEM (user-reported, transient, pre-reboot damaged session): "top half of the
Notepad window was black" on the freshly-opened window. Two suspects if it recurs on a
clean session: (a) the clipped drive-settle repaint missing a region when a placement
configure pair arms a stream on a fresh window (agent 857965a code); (b) the pre-existing
per-window prefill painting a fresh window's buffer before its first full content copy.
Recurrence protocol: fullshot immediately, then guest-eyes.ps1 (guest-side pixels decide
whether the black exists in the guest or only in dom0's copy).

## 2026-08-12 (cont.) — Guest-drag wobble: measured, root-caused, four fixes landed (agent 43de7d4)

MEASURED on a real user drag (ProtoTrace, build D27E826B): 10 announce stalls of 76-472 ms
in a 5.7 s drag, catch-up jumps to 337 px, 43 direction reversals >3 px - vs a clean 26 ms
cadence with zero stalls on a scripted drag minutes apart. Frame correlation split it into
two species: (A) big-area frames delivered at 150-195 ms (acq-bound), (B) the pump busy
BETWEEN frames (476 ms with acq=19 ms).

Investigation (wf_c4ca99e0, 5 agents) ranked the mechanisms; all four GO fixes landed:
 1. **The dominant, most drag-shaped artifact**: the throttled 150 ms mid-drag PrintWindow
    refresh was the ONE recapture the drag latch did not suppress - a 15-50 ms synchronous
    stall injected into the dragged app's own modal move loop at ~6.7 Hz (freeze-then-snap).
    Latched windows now skip it; the settle recapture on release repaints once.
 2. Announce-cadence aliasing: the 16 ms limiter beat against the ~20 ms frame cadence and
    withheld positions only flushed at frame boundaries (the tracking-pass flush the
    comment claimed had NO call site). The latched window is now limiter-exempt.
 3. Inbound MSG_MOTION coalescing (the w9r3irkhc design, finally landed): latest-wins
    pending slot, flushed before any non-motion dispatch and at both drain ends - a
    post-stall backlog no longer replays the stale trajectory through SendInput.
 4. Mid-guest-drag daemon configures are ignored while the latch holds (ACK still echoes):
    the user's hand is the geometry authority; a WM bounce can no longer yank the window
    backward or arm the drive suppression mid-drag. Inert on clean drags (0 inbound
    configures in both traced episodes).
Deferred with instrumentation-first verdicts: HandleMotion origin reconstruction (magnitude
unmeasured), the 25H2 platform 1.6-1.8x cost multiplier (no designed fix; re-evaluate after
fix 1 lowers the floor).
ACCEPTANCE (user-felt + traced): a hand drag with no >60 ms announce stalls, no catch-up
jumps, and no rhythmic hitch; dom0-drag replay harness re-run (fix 2 touches the limiter
that fixed the replay).

## 2026-08-12 (cont.) — GWeck goal batch + wobble fixes DEPLOYED (build C55DCDA7, agent 43de7d4)

Automated validation green on win11-fresh 25H2, hash-verified:
 - QGASHELLMANAGED policy=2 (start-only), QGABLOCKWIN on, A3CHECK converged 5120x1440.
 - **Start menu IS a WM-managed dom0 window**: fullshot geometry or=0, mapped, 832x736 =
   exactly the cropped card; dom0 gives it a frame and the title "[win11-fresh] Start".
   Size-lock hint fired: QGAPROTO,msg=HINTS,sizelock=832x736.
 - Toasts UNCHANGED: or=1 corner popup at 4740,1222, card renders (policy separation works).
 - Occlusion choreography (armed-task, dom0-only captures): a console window stacked ABOVE
   the open Start in dom0 shows its own content (agreeing z-order: no bleed); Notepad moved
   UNDER the Start region and inspected after: fully intact, no Start-pixel debris, no
   stale regions. Census cap_timeout=0, workarea=0. Scripted drag settles in 4 ms.
 - Instrument facts re-learned: EnumWindows CANNOT see shell surfaces (the programmatic
   Start-move stickiness test silently no-oped - the real test is a dom0 WM drag, user
   checklist); any guest process activity while Start is open DISMISSES it, including the
   opener's own cleanup - both opener scripts now use exit-before-fire + hidden console
   (the shipped installer helper had BOTH defects; fixed before first ship).
Pending user-hand checks: Start frame drag (move-stickiness - the one unproven design
assumption), resize refusal (size-lock end-to-end), Start clickability, dom0-restack-above
bleed severity (documented Phase 3 limitation), Win-key block feel, wobble verdict.

## 2026-08-12 (cont.) — WOBBLE ROOT CAUSE: input translated against the LIVE origin instead
## of the ANNOUNCED one (agent b93d259)

The forth-and-back oscillation during a GUEST-NATIVE drag (user-reproduced; distinct from
the dom0-frame drag replay, which stays fixed) is a positive feedback loop on the input path:
 - gui-daemon sends window-RELATIVE input coords, computed against the rect it was last
   TOLD about (xside.c process_xevent_motion: k.x = ev->x).
 - The agent added them back to the LIVE tracked origin (data->X/Y) in BOTH input paths
   (InjectMotion and HandleButton), so injected cursor = true cursor + (live - announced).
 - The app's own modal move loop moves the window by that error -> the live origin changes
   -> the next error changes. While announces are starved (ProcessNewFrame holds
   g_csWatchedWindows for the whole per-window pass; the daemon also defers while
   have_queued_configure is set) the error ACCUMULATES and the window runs AHEAD of the hand;
   when the backlog flushes and dom0 adopts the newest position, the next injected sample is
   short by the whole accumulated gap and the window is yanked BACKWARD.
 - Predicts amplitude = drag velocity x announce dead time (~1300 px/s x ~160 ms = ~80 px,
   the observed max) and predicts HORIZONTAL-ONLY error on a horizontal drag (y stayed
   260-263 while x swung 80 px) - which no jitter/DWM-lag/two-writer story predicts.
 - The code comment at vchan-handlers.c:427 ALREADY stated the correct rule ("dom0's
   coordinates are relative to the rect the agent ANNOUNCED"); only the field was wrong.
FIX: both paths use LastCfgX/Y when CfgSentValid, falling back to X/Y before the first
announce. Every WINDOW_DATA writer runs on the pump thread under the lock, so this is not a
two-writer race - the window really moved back, because we told it to.

**INSTRUMENT CORRECTION (retraction):** the first oscillation measurement was ACK-POLLUTED -
every configure ACK byte-echo is ALSO traced by send.c as a plain msg=CONFIGURE, so 155 of
245 "outbound" lines in that trace carried dom0's coordinates, not ours. Re-measured on a
clean trace (1 ACK): the oscillation is REAL - 23 direction reversals in 143 genuine
announces. Also retracted earlier the same session: "the drag latch never armed" was an
artifact of LogLevel=3 hiding LogDebug lines; the latch does arm (guest LogLevel is now 4).

## 2026-08-12 (cont.) — Start on 25H2: the phantom is the remaining defect (agent, card gate)

The user watched four failed managed-Start attempts ("maximized window, then dead";
"console popped, then window at random position, then dead"; wallpaper contents). Causes,
now separated:
 1. PHANTOM MAPPING (the big one): StartMenuExperienceHost keeps a top-level surface alive
    while Start is CLOSED. Mapping it announces a window with no menu inside, so dom0 shows
    a slice of bare desktop at whatever rect that surface reports - measured 1201x919, and
    once x=6063 on a 5120-wide screen ("random position"), vanishing when the phantom does
    ("then dead"). FIX: ShellSurfaceCardless() + a genuine-open gate in ShouldAcceptWindow -
    a classified shell surface whose card measurement FINISHED with no card and no sticky
    last-good is not a window. In-flight measurements are never rejected.
 2. CONSOLE FLASH: the Start opener's launcher (powershell, even -WindowStyle Hidden)
    flashes a conhost window that steals focus and dismisses the menu it just opened - the
    user's "console popped". FIX: the whole chain is windowless (.lnk -> wscript //B ->
    Run(...,0) hidden powershell -> keybd_event(VK_LWIN)). SendKeys "^{ESC}" from that
    context does NOT open Start at all (guest screenshot: no menu, all shell hosts
    main=0x0) - the VK_LWIN chain is the proven one.
 3. Instrument note: `qtest fullshot` takes ~50 s and every qrexec retrieval flashes a
    console, so a transient menu cannot be observed that way. Added
    capture-start-render.ps1 / read-start-render.ps1: the guest samples its OWN screen while
    Start is open and the PNG is retrieved later.
Rig is back on ShellManaged=0 (headerless corner Start), the only configuration ever
confirmed to render correctly. Frozen-anchor (=2) exists but is unproven and NOT recommended.

## 2026-08-13 — DRAG: the accepted configuration, and what each part actually fixed

Shipped defaults (agent, verified by CLEARING every registry override and reading the
agent's own PerfInit lines back - build 69E59CE6):
  QGADRAGSERVO on gain=85% tau=25ms deadband=3px fast>=24px@85% clamp=on
  QGADRAGFREEZECONTENT on   QGADRAGEVTPRIO on   QGAMONCACHE on   QGADRAGFREEZE off

The user's drag complaints were FOUR separate defects, each with its own cause and fix.
Everything below is measured, mostly with guest/sample-window-motion.ps1 (in-guest 10 ms
sampling of the guest's OWN GetCursorPos + GetWindowRect, retrieved after the fact so the
observation cannot perturb the drag):

1. WOBBLE (forth-and-back). Structural, pre-existing (16% of announces reversed on the
   user-confirmed-good build, 19% on a regressed one). gui-daemon sends WINDOW-RELATIVE
   motion (xside.c: k.x = ev->x) and the agent reconstructed an absolute against a GUEST
   origin; that is exact only when it equals dom0's APPLIED origin, which lags our
   announces and is unobservable during a guest drag (zero inbound configures measured in
   a 5.85 s latch). Gain-1 servo + transport lag = oscillator. FIX: Smith predictor -
   timestamped ring of our own announces, reconstruct dom0's applied origin, damp at 85%.
   Servo the CURSOR not the window, so Windows re-anchoring the modal loop's grab
   mid-drag (drag-to-restore of a maximized window) cannot poison it.
2. STARTUP DELAY. Measured 193 ms and 211 ms between the INJECTED cursor moving and the
   window moving (221 px of cursor travel banked in one case); warm 30-40 ms. Cause:
   PrintWindow(PW_RENDERFULLCONTENT) is a synchronous cross-process render that executes
   in the DRAGGED APP'S UI THREAD, so the app cannot process the mouse messages that move
   its own window. FIX: freeze content during the drag (dom0 keeps the last good bitmap,
   one authoritative full repaint on release). Result: 0 ms on four of seven drags.
   Residual: cold first-drag still 156-259 ms - OPEN.
3. JUMPINESS. The guest's own window rect advanced only every 54-70 ms in 12-68 px hops
   (~16 Hz). Announcing faster cannot smooth motion that is not happening: the mouse
   events driving the app's move loop arrived in clumps at frame cadence, because the pump
   drains the vchan only on its own event or at the top of a frame, and g_WindowEventSignal
   is LAST in the wait array by design. FIX (DragEventPriority): while the drag latch is
   armed, drain input FIRST and then announce, both ahead of the frame wait.
4. FAST-DRAG TRAILING. The 85% damping is only needed near the settling point; applied to a
   fast hand it just lags. The user proposed 'first jump immediately, then adapt' = gain
   scheduling. Implemented at 100% for deviations >=24 px and it produced CRAZY
   EXTRAPOLATED JUMPS: at full gain a mis-reconstructed origin is applied whole, and the
   damping had been silently absorbing those errors. Reverted to neutral (fast gain ==
   base gain) and added the CLAMP that makes the idea safe: an injected step may never
   exceed 2x the hand's own relative movement for that event + 32 px, so a wrong estimate
   can only make the window LAG, never overshoot. Raising InputDragServoFastGainPct is now
   a field experiment rather than a risk.

PROCESS FAILURES THIS ROUND, recorded so they are not repeated:
 - A knob's registry READ silently failed to land in perf.c (the edit did not match), so
   the value was hardcoded and could not be flipped when it misbehaved - the binary had to
   be rolled back instead. EVERY generated edit is now verified by grepping the file, not
   by trusting the script's own success message.
 - Latency was judged for hours with ProtoTrace=1 and LogLevel=4 live on the guest, which
   multiply the frame-walk tail (tot max 580 ms vs 66 ms off). Diagnostics are now OFF by
   default on the rig and must be re-enabled per measurement.
 - MonInfoCache measured 3x interleaved: upd p95 3457->1631 us, upd max 40.2->14.6 ms.
   tot_max did NOT improve in the same runs (89.6->168.2 ms median) and is unexplained -
   NOT claimed as a win, still open.

## 2026-08-13 — DRAG WOBBLE PARKED by the user; the measured wins ship, the servo does not

User verdict after side-by-side testing of servo-on vs servo-off: "the difference is
marginal, both suck in a way, lets record experiment results and put improvement on long
term plan, not now." Full write-up, including how to resume it: docs/PLAN-drag-quality.md.

SHIPPED, default on (each measured independently of the parked work):
 - InputDragFreezeContent: content frozen during a guest drag, one full repaint on release,
   and the freeze OWNS the capture channel so the engine's sweep cannot fire a PrintWindow
   into the dragged app's thread. Startup 193/211 ms -> 0 ms on four of seven drags.
 - DragEventPriority: input drained (then announced) ahead of the frame wait while dragging.
   Fixes the guest window only advancing every 54-70 ms in 12-68 px hops.
 - MonInfoCache: upd p95 3457->1631 us, upd max 40.2->14.6 ms, 3x interleaved.
SHIPPED, default OFF (experiments, knob-revivable): InputDragServo (Smith predictor),
InputDragServoClamp, InputDragFreeze (frozen dom0 window), gain scheduling (neutral).

WHY THE SERVO DID NOT SHIP: theory and simulation were sound (delay cancels out of the loop;
1.6% residual reversals vs 43%), but on the guest the ESTIMATE was unreliable in both
directions - full gain on a bad reconstruction gave "crazy extrapolated jumps", and a
reconstruction running ahead collapsed the deviation so the window "just sits there". The
control law was never the problem; the origin estimate was, and it was never measured
against ground truth. That is the first thing to do if this is revived.

RESIDUAL, unfixed and recorded: cold first drag 156-259 ms (vs ~0 warm); the ~46 ms guest
composite quantum at 5120x1440 (vs ~18 ms at 1080p) which announces are slaved to and which
is NOT agent code - the authorised resolution A/B was never run; tot_max unexplained under
MonInfoCache; and the twice-seen wedged-window corruption (proven guest-side, fresh windows
always clean).

## 2026-08-15 (night) — the agent announced UNINITIALIZED STACK MEMORY as window geometry

The most serious defect found today, and the first mechanism that actually explains the dom0
"invalid or suspicious GUI request" dialog GWeck photographed (post 45) - unexplained through two
prior investigations.

`GetRealWindowRect` returns a WIN32 status, not an HRESULT, and two of its failure returns are
POSITIVE numbers: `ERROR_INVALID_DATA` (0xd) and `win_perror`'s return. `GetWindowData` tested
`if (!SUCCEEDED(status))`, and `SUCCEEDED(0xd)` is TRUE - so for those two failures it skipped the
error path entirely, fell through with its `RECT rect;` still UNINITIALIZED, and returned
ERROR_SUCCESS. Whatever was on the stack became the window's geometry and was announced to dom0.

The `ERROR_INVALID_DATA` path is not exotic - it is every zero-sized top-level window (degenerate
DWM bounds AND degenerate GetWindowRect), which ordinary shell surfaces produce constantly.

PROVEN, identical 40 s workloads on win10-tpl with a deliberately created 0x0 top-level window
(`scratchpad/zerowin.cs`), agent liveness asserted before each run:

    pre-fix  (4.3.2, 20EC3EC4):  65 GetRealWindowRect rejections ->  1 reached GetWindowData
                                 => 64 swallowed, each returning success with a junk rect
    fixed    (D05BC3A2):         65 GetRealWindowRect rejections -> 65 reached GetWindowData

Fix: test `status != ERROR_SUCCESS`. Companions, both required: `UpdateWindowData` and
`GetWindowData` demote E_HANDLE and ERROR_INVALID_DATA to debug, because propagating them correctly
turned 64 silent garbage announcements into 65 ERROR lines per 40 s - measured on the proving run
itself - which would have moved the noise rather than removed it.

TWO HAZARDS THIS BRANCH INTRODUCED YESTERDAY, caught by adversarial review and not by me:
  - `|| !found` in SelectSupportedMode pinned index 0 for a zero-dimension request - reinstating
    the arbitrary pick the change existed to remove, for the one input that produces it. A zero
    request now returns the "no opinion" sentinel explicitly.
  - the MAXDWORD sentinel made SetVideoMode return ERROR_SUCCESS WITHOUT applying a mode, while the
    adopt-current rescue sat INSIDE the failure branch - so g_ScreenWidth/Height could stay 0 and
    `x * 65535 / g_ScreenWidth` in HandleMotion divides by zero on the first pointer event. The
    rescue is hoisted out; its own zero test was always the real guard.
Both are the direct argument for running the adversary over one's own patches, not just over the
code one is patching.

Also: the capture-restart gate logged BOTH its edges below the default log level, so a shipped
guest recorded nothing when capture stopped or came back - the one question a "my qube is frozen"
report needs answered. Now CAPTUREGATE at warning/info.

## 2026-08-15 (late) — RETRACTION: the capture gate does NOT stop windows being announced

I wrote earlier today that while `g_LocalScreenDestroyed` is set "NO NEW WINDOW CAN EVER APPEAR" and
that this "explains GWeck's #16 and #17 exactly". **That is overstated and I withdraw it.** The
injector built to prove it disproved it instead.

With `CaptureGateFaultInject=7` (confirm suppressed, deadline disabled, capture error raised on
purpose), the gate opened and a brand-new window was announced anyway:

    CAPTUREGATE CaptureGateFaultInject: raising a capture error on purpose to open the gate
    CAPTUREGATE capture error - screen window destroyed, waiting for the gui-daemon confirm
    SendWindowUnmap: Unmapping window 0x0
    SendWindowMap: Mapping window 0x1201c6      <- a window mapped AFTER the gate opened

So `ProcessWindowEvents` being skipped is not the whole story: some other path still announces
windows in that state. The code-level reading (main.c:6196-6199 discards window events) is correct;
the CONSEQUENCE I drew from it is not.

What the defect run DID show, which is a real fault worth fixing: with the confirm suppressed the
daemon eventually dropped the connection, and the agent then sat in "Awaiting for a vchan client"
until the first-boot self-heal fired at 90 s and respawned it. So the user-visible cost of a gate
that never opens is a session outage of at least 90 s, not a permanent freeze.

The deadline fix (15 s, two re-sends, then respawn) shortens that and makes it explicit in the log,
and it is committed - but it is **NOT PROVEN**: the fix-side run never reached the gate, because by
then the rig had been churned into a state where no daemon client attached, so the injector's own
precondition (g_VchanClientConnected) never held. Rig rebooted clean; injectors disarmed.

To finish this properly: run the pair on a freshly booted guest, fault=7 then fault=5, each with a
confirmed vchan client before the injected error, and compare the time from the injected capture
error to a working session. Until that exists, the gate fix is defensive code with a plausible
rationale and no demonstration - the same status as the work-area fix, and it must be described
that way.

## 2026-08-16 — drag wobble is still there, and it is the PARKED structural one

Owner dragged a window on win10-clean (pre-pool build 363AE675, 5120x1440) and reported crazy jumps
plus rendering errors. Both captured with ProtoTrace on:

  - WOBBLE: 2 direction reversals in the last 25 CONFIGURE announces (~8%), against the 16-19%
    recorded in docs/PLAN-drag-quality.md. This is the PARKED defect, not a regression: gui-daemon
    sends WINDOW-RELATIVE motion (`k.x = ev->x`) and withholds `ev->x_root`, so the agent adds back
    an origin that lags and is unobservable mid-drag. Gain-1 correction plus transport lag is an
    oscillator. The one-line exact fix is in dom0 (forbidden), freeze was rejected, the servo is
    default-off and judged marginal.
  - RENDERING: the window came back with its right-hand side BLACK and real content on the left -
    a per-window buffer filled only where damage covered it.

Announce cadence measured on the same rig, which is the thing PLAN-drag-quality names as "likely the
largest single remaining factor" and had never been run:

    desktop=5120x1440   announces=295   gap p50=26.0 ms  p95=62.0  mean=122.3

The plan predicted p50 66 ms at this resolution; the measured p50 is 26 ms, so the announce clock is
better than assumed - but the p95 of 62 ms and a mean dragged to 122 ms by outliers say the TAIL is
what a user feels, consistent with the earlier bench (tot p50 442 us, p99 40 ms, enu max 600 ms).

**A defect the slab pool introduced, found by that screenshot and fixed immediately**: with buffers
reused, the unpainted region would have shown the PREVIOUS WINDOW'S pixels rather than black - one
application's content inside another's frame. Slabs are now zeroed on acquire (agent 2addd20),
restoring the pre-pool appearance exactly.

## 2026-08-16 — drag baseline locked (agent `3811e98`, package build 31942731976)

User-confirmed good on win10-clean. This is the reference point for any future drag change; per the
canonical-benchmark rule, compare against these numbers, never against an intra-day build.

Binary under test verified installed: running `gui-agent.exe` SHA256 prefix `DA3E37CD274F8454`,
equal to the pushed artifact. Preconditions asserted in-run, not assumed:
`QGADRAGQUANT on (adopt=70 ms, announce pacing=140 ms)` from the log banner, and **no** registry
overrides present — so this measures the shipped defaults, not a ladder rung.

| metric | value | note |
|---|---|---|
| announces | 225 | 10 s hand drag with deliberate reversals |
| moves | 162 | non-zero deltas |
| reversals | 23 (14.2 %) | includes genuine hand direction changes - see caveat |
| max run | 1520 px | long straight runs are clean |
| announce gap | p50 134 ms, p95 802 ms | p50 tracks the 140 ms pacing as designed |
| edge black-fraction | left=0 right=0 top=0 bottom=0 | **was left=7** before the crop fix |

**Caveat on the reversal metric**: it counts every sign change in announced x, so a reversal the
user's hand actually performed is indistinguishable from a wobble the agent invented. 14.2 % here vs
11.6 % at the 200 ms rung is therefore NOT evidence that 140 ms is worse - the hand paths differed.
The metric is only comparable across runs driven by a scripted, identical mouse path. Treat the
hand-drag number as a sanity bound (it is nowhere near the 85.7 % of the broken pacing=0 build), not
as a precision instrument.

**Crop refresh is settle-only.** `WcSetCrop` marks the WGC channel dirty, so refreshing it per move
event forces a full-window recapture at input rate. A move now only sets `PwCropStale`; the settle
handler applies it, where a recapture is already scheduled - the correction is free and lands before
the repaint, so the first post-drag frame is already correct.

## 2026-08-16 — where the frame rate actually goes, and why drag is not smoother

### The agent is not the bottleneck: 0.7 % of the frame budget

win10-clean on the IddSampleDriver (5120x1440@60, BDA disabled), full-rate damage load, 900 frames,
`PerfLog=1 PerfEveryN=1`:

| metric | p50 (us) |
|---|---|
| frame interval `dt` | 16868 -> **59.3 fps** |
| `AcquireNextFrame` blocked (`acq`) | 15091 |
| **agent total (`tot`)** | **114** |
| damage `dmg` / wake `wak` / enum `enu` / send `snd` | 53 / 75 / 5 / 0 |

The agent spends 114 us per 16.9 ms frame. The other 99.3 % is the capture thread BLOCKED waiting
for DWM to present. Optimising the agent's frame path buys nothing - that work is not what we wait
on. p10 fps was 30.4 (`dt` p95 = 34490 = exactly two vblanks), but the load generator is a PowerShell
WinForms painter, so missed vblanks are plausibly the generator's, not the pipeline's - unproven.

What caps the rate is OUR driver: every published mode was hardcoded 60 Hz and DWM presents at the
mode rate. Now configurable via `HKLM\SOFTWARE\QubesIDD\ModeVSync` (default 60 = unchanged),
applied to monitor modes, registry modes AND the target list, since the OS offers the intersection.
Owner decision 2026-08-16: 60 Hz is fine; the knob ships default-off and unexercised - **not tested
at any value other than 60**, so raising it is unproven and would need a guest-CPU measurement first
(no GPU: DWM composites through WARP on the CPU).

### Drag smoothness is capped by the announce rate, not the frame rate

The window only MOVES in dom0 when we send `MSG_CONFIGURE`, and those are paced at
`InputDragAnnounceMs` = 140 ms: **~7 position updates/s against a 60 fps content stream**. That is
the stepping, and the two rates are independent.

The pacing is not arbitrary. dom0 sends motion in WINDOW-RELATIVE coordinates and withholds
`x_root`, so reconstructing an absolute position needs to know which window origin dom0 used for
that event. We know every origin (we chose them); we do not know WHEN dom0 applied one, so we wait
`InputDragAdoptMs` = 70 ms to be sure. Announce faster than the apply lag and events become
ambiguous - each announce moves the origin the next event is measured against, closing the gain-1
loop that produced the 85.7 %-reversal build.

**dom0 does not tell us either.** Measured on the baseline drag: **541 announces for the drag
window, 26 inbound configures - 4.8 %.** There is no per-move confirmation to lock onto; the 70 ms
is a guess because the protocol offers nothing better.

Two ways up, in order of availability:
1. **Shrink the guess.** 70/140 was chosen conservatively and never measured against dom0's real
   apply lag. If the true lag is ~30 ms, pacing could roughly halve. In-guest, no protocol change.
   Requires a SCRIPTED identical mouse path - hand drags are not comparable (see the baseline note).
2. **Close the gap.** Daemon sends `x_root`, or echoes applied geometry. Deletes the problem, but it
   is an ENHANCEMENT, not a bug, so it does not qualify for the CLAUDE.md upstream exception and
   waits for the completed work.

### Hiding guest-native window controls: technically yes, but it costs WM management

Tested on Notepad: stripping `WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX|WS_MAXIMIZEBOX` +
`SWP_FRAMECHANGED` works - `caption_gone: true`, app survives, outer rect unchanged, and seamless
keeps streaming normally (agent announced the window with `ovr=0` and damage kept flowing).

But the window drops out of dom0's WM-managed window list. dom0's screenshot service selects from
`_NET_CLIENT_LIST` filtered by `_QUBES_VMNAME` and exits 1 when it captures nothing:

| state | captured |
|---|---|
| caption stripped | 0 bytes (2/2 attempts, plus 3 earlier) |
| caption restored | 20480 bytes (2/2) |

Notepad was the VM's only mapped window, so "nothing captured" means that window specifically left
the managed list. The consequence is the opposite of the goal: you do not get "dom0 decoration
only", you get NO decoration from either side - and with it, no dom0 titlebar to move or close by.
Strictly, what is proven is the service's before/after, not the X property directly.

It would not be uniform anyway: apps that custom-draw their caption (Chrome, Edge, Office, Win11
Explorer) paint those buttons into the CLIENT area, where no style change reaches them. The result
would be some windows losing the caption and others keeping it.

Conclusion: not worth doing by style-stripping. If the goal is the double-titlebar look, the layer
that owns it is dom0's WM decoration policy (off-limits) or the daemon (upstream, later).

## 2026-08-16 — attempt to measure dom0's apply lag offline: FAILED, hypothesis disproved

Tried to recover dom0's apply lag `L` from the baseline drag log with no new drag, on the hypothesis
that some of the 26 inbound configures were echoes of positions we announced.

**They are not.** Correlating all 541 outbound announces against the 26 inbound configures for the
drag window matched all 26 at exactly 0 ms - because the match found our own ACK REPLY, emitted in
the same millisecond as the inbound request:

    20260816.144113.230 IN  199 271     <- dom0's configure request
    20260816.144113.230 OUT 199 271     <- our ACK, same ms, same coords

So the inbound stream during a drag is dom0-INITIATED (the WM adjusting), not confirmation of
anything we sent. dom0 emits no per-move acknowledgement, which is exactly why `InputDragAdoptMs` is
a fixed guess. The 4.8 % inbound/outbound ratio measured earlier stands but means dom0-initiated
moves, not feedback.

**Consequence for measuring `L`.** It needs real dom0-driven pointer motion over the window:
- a guest-side `SendInput` drag does NOT work - it never generates dom0 motion events, so the
  reconstruction path under test is bypassed entirely;
- polling dom0 window geometry is not an option: geometry polling captures the whole dom0 desktop
  (privacy), and the qrexec round trip is far too coarse to resolve a ~30 ms lag anyway;
- so it is either one ordinary hand drag with the trace build installed, or a dom0-side pointer
  injection service (xdotool mousemove/mousedown is present in dom0, but adding a service is a dom0
  change and needs the owner).

Rig is left armed for the first option: trace build `058B4A02E45A677A` installed and verified,
ProtoTrace on, shipped drag defaults, Notepad open. One caption drag produces the data.

## 2026-08-16 — dom0's apply lag MEASURED: it is under one motion event, not 70 ms

Recovered from a real 10 s dom0-driven drag (window `0x20030`, 543 motion events, 37 announces)
captured by the new `QGAPROTO,msg=MOTION` trace. No new drag was needed - the trace had already
recorded one.

**Method.** When dom0 applies announce k, its window origin O jumps by `A_k - A_(k-1)`, so the
window-relative coordinate `r = P - O` jumps by exactly the NEGATIVE of that, in one event. Search
the motion stream for that signature after each announce; the delay is `L`.

**Result: 20 of 36 announces produce an identifiable jump, median L = 0 ms, p75 = 17 ms.**

**Instrument validated before believing it** (the estimator could match by coincidence: 36 deltas, a
610 ms window, +/-3 px tolerance):

| variant | matched /36 |
|---|---|
| real announces | **20** |
| announce times shifted +1.5 s | 2 |
| announce times shifted +3.0 s | 0 |
| announce times shifted -2.0 s | 2 |
| real times, scrambled delta VALUES | ~6 (chance floor) |

So the match is time-locked to the announce and value-specific: 20 vs a ~6 chance floor, collapsing
to 0-2 when the times move. The 16 unmatched announces are expected - small deltas and fast hand
motion mask the signature.

**Sampling resolution.** Motion arrives at **54.3 events/s, p50 gap 9.0 ms** (p90 18 ms). So `L` is
at or below one-to-two events, i.e. under ~18 ms. It cannot be resolved finer than that from this
data, and the honest statement is `L < 18 ms`, not `L = 0`.

**Consequence.** `InputDragAdoptMs = 70` waits 4-8x longer than dom0 needs, and
`InputDragAnnounceMs = 140` is bounded below by that wait - which is what caps the window's
dom0-visible motion at ~7 updates/s while content streams at 59.3 fps. The 70/140 pair was chosen
conservatively against a lag nobody had measured; now it is measured.

Next rung to test: **adopt 35 / pacing 70** (2x margin over the p75, and pacing = 2x adopt, the
ratio the shipped pair uses - `pacing == adopt` is known-bad at 67.1% reversals). That should double
the dom0-visible update rate to ~14/s.

Also note this answers the sampling question directly: we do NOT need to sample the cursor faster.
54 Hz already localises dom0's apply to ~9 ms; the 70 ms wait was never a sampling limit.

## 2026-08-16 — drag baseline v2 LOCKED: 25/50 + interpolated origin

Supersedes the morning baseline (70/140 quantised, tag `drag-baseline-20260816`). User-approved:
"good enough, we can stop here and take it as baseline".

**How it got here.** The morning pair was chosen against a dom0 apply lag nobody had measured. The
new `QGAPROTO,msg=MOTION` trace measured it - `L < 18 ms` (median 0, p75 17, 9 ms sampling) - which
made the 70 ms adopt 4-8x too large and the pacing bounded below by it. Ladder, scored on a
path-independent metric (injected-path reversals MINUS the reversals the hand actually made):

| rung | announce rate | excess reversals | deviation p90/max | backward jumps >=20px |
|---|---|---|---|---|
| 35/70 | 6.4/s | 208 (+38%) | 82 / 800 px | 7.5% of events |
| **25/50** | **13.7/s** | **118 (+23%)** | 67 / 261 px | 9.5% |
| 20/40 | 13.4/s | 180 (+36%) | 45 / 215 px | 8.9% |

25/50 is a floor in BOTH directions: below it adopt drops under dom0's real apply lag, the adopted
origin has not been applied, the error takes the wrong sign and the loop reopens (user: "jumps back
a bit"); and pacing under 50 returns nothing (13.4 vs 13.7/s) because the announce rate is already
saturated by the window's own movement and `CFG_POS_MIN_INTERVAL_MS`.

**Interpolated origin** then removed the residual: the origin now ramps between bracketing announces
evaluated at `now - InputDragLagMs` (10 ms) instead of stepping to a whole announce delta at once.
Chosen over the servo the owner floated, deliberately: a damper smooths the step by WITHHOLDING
motion, handing back the latency the ladder had just bought (~33 px of trail by the old servo's own
comment, the same order as the artefact). Interpolation adds none.

Net vs this morning: **dom0-visible update rate ~7/s -> 13.7/s, excess reversals 38% -> 23%.**

**Two-window overlay/z-order check** (owner-requested acceptance): three windows mapped
simultaneously - a green-on-black console overlapping a white Notepad - and every capture came back
complete, with correct chrome and **zero cross-window bleed** (0.0% green pixels inside either
Notepad capture despite real overlap). The grant slab pool is not leaking foreign pixels, the defect
it had when introduced.

LIMIT OF THIS CHECK, stated plainly: `qtest shot` returns PER-WINDOW captures, so it proves capture
isolation, NOT the composited z-order on screen. Which window dom0 actually draws on top is not
verified here and needs eyes on the display.

**Unproven / open**
- `L` is from ONE drag; the ladder rungs are one hand-drag each. Path-normalised, so comparable, but
  a repeat of 25/50 would firm up the +23%.
- Interpolation is deliberately NOT an exact model: dom0's origin genuinely steps (it applies each
  configure at one instant). Ramping is a hedge against L's variance (tail at 82, 398 ms). Guessing
  each step edge exactly is what 20/40 tried, and mis-timing one is what reopened the loop.

## 2026-08-16 — the red flashing frames IDENTIFIED: announced drop-shadow windows, ~317 ms each

Owner: "i see red frames flashing before they get synthesized." Now characterised end to end.

**It is NOT announce-then-synthesize.** Checked first, because that was the obvious hypothesis: in
the agent's protocol trace, `CREATE` and `SYNTH` never occur for the same hwnd - 84 windows announced,
69 synthesized, **zero overlap**. A window is either announced or composited, never announced and
then withdrawn into its owner. So the flash is not a transition.

**It is the shadow windows themselves.** Filtering `CREATE` by the shadow signature
`ex=0x08180028` (LAYERED|TRANSPARENT|NOACTIVATE|TOPMOST):

    41 shadow windows announced, mapped lifetimes:
    333 317 333 333 316 116 350 317 317 333 317 317 334 300 316 355 317 317 334 317 ... ms

**~317 ms each, tightly clustered** - a NetUI fade duration. dom0 draws its 1 px qube-coloured
border around every window it maps, override-redirect included (CLAUDE.md 2A-chrome expects
"+1px-bordered popup when open"), so each of these is a red frame that appears and disappears in a
third of a second. With 41 in a session of ribbon use, that is the flashing.

Correction to the owner's reading, which was otherwise right: the red frame is not the content popup
awaiting synthesis. The content popup (`Net UI Tool Window`) composites silently and is never
announced (verified: 26/26 eligible, CREATE=0). The flashing object is the DECORATION, which is
structurally unsynthesizable (born ownerless or orphaned within 165 ms).

**This upgrades the shadow-drop from a cost optimisation to a visible-defect fix.** Previously the
cost was measured but the visual harm was explicitly recorded as NOT demonstrated. It is now
demonstrated, by the user, with the mechanism and timing attached.

## 2026-08-16 — OPEN: distortion when dragging over another window, ONLY with an override modal

Owner: "when i drag over another window i see moments of distortion, it self-heals but still there"
- then narrowed it: **"it happens only if modal dialog in override window kicks in"**.

**Plain overlap during motion is EXONERATED, measured.** Swept a white Notepad back and forth across
a green-on-black console (800x500) for ~60 s, 40 px steps at 45 ms, capturing 4 times mid-motion.
Cross-window bleed in every capture:

| capture | green pixels inside Notepad |
|---|---|
| mid-motion x4 | **0.0%** |

The console kept its own content (2.1-4.5% green) and Notepad stayed white. So the per-window
capture path isolates correctly while windows move over each other - this is NOT a generic occlusion
or slice-feed bug, and that whole family can be set aside.

**The trigger is an override-redirect modal appearing during the drag.** Not reproduced here yet;
recorded with the leads that fit it, none verified:

1. `CollectZOrder` runs ONLY while an override-redirect popup is on screen (`main.c:4047-4049`,
   noted during the chrome-predicate review). The owner's trigger is precisely "an override popup
   appears", so the drag would suddenly start doing z-order collection mid-motion. Timing-wise this
   is the closest fit and is where I would look first.
2. Occlusion accounting (`rgnCovered`) is accumulated only over WATCHED windows (`main.c:4656`,
   `5167`). A modal that is override-redirect is watched, but one dropped by a chrome rule is not -
   worth re-checking now that rule 4 drops NetUI shadows, since a dropped occluder stops clipping
   damage of the windows beneath it.
3. dom0 does not manage override-redirect windows at all, so they are absent from
   `_NET_CLIENT_LIST` - which also means **`qtest shot` cannot see them**. Any capture-based
   investigation of this bug is blind to the very window that triggers it; that is why the sweep
   above could only exonerate the plain path, not reproduce the reported one.

Self-heals, per the owner, which is consistent with the settle-time full recapture.

NEXT STEP when this is picked up: get the exact modal (which app, which dialog), then run
`tools/winwatch.cs` during the drag - it enumerates override-redirect windows that the screenshot
service cannot see, and its `ovr`/`synth`/`DEMOTED` columns would show what the agent decided about
that dialog at the moment of the distortion.

## 2026-08-16 — CONFIRMED BY PIXELS: a synthesized menu is orphaned when its owner is dragged

Owner reproduced it in Explorer and asked for a full-desktop capture (per-window shots are
structurally blind here - a materialized popup is `ovr=1`, so dom0 never lists it in
`_NET_CLIENT_LIST` and the screenshot service cannot see it).

**What the capture shows**: Explorer's **Home ribbon panel** (Clipboard / Organise / New / Open /
Select groups, fully rendered) sitting as its OWN dom0 window, with the qube's red border, on top of
an unrelated dom0 terminal - far outside the Explorer window it belongs to. (Capture deleted after
analysis; it was a whole-desktop shot.)

**Mechanism, and it is exactly as predicted from the code** (`main.c:3578-3595`):

    if (!SynthQualifies(c, &stillOwner))
    {
        LogInfo("0x%x: owner geometry changed, materializing child", c->Handle);
        SynthDeactivate(c);
        c->DeletePending = TRUE;
    }

A menu is a SEPARATE top-level window and does not move when its owner is dragged. So:
1. menu opens inside the owner -> synthesized, painted into the owner's buffer;
2. owner is dragged; the menu stays at its screen position while the owner leaves;
3. containment fails -> `SynthDeactivate` -> announced as its own dom0 window, bordered, at the
   position the owner has now left.

It reproduces in Notepad and Explorer because those are the surfaces that measure `synth=yes`
(contained in the owner). Menus that open OUTSIDE the owner - Edge's 3-dot menu, most context menus
- are never synthesized and so cannot fall off. "Not always, but in Notepad" is precisely this.

**Proposed fix, still NOT implemented**: materialize a dragged window's synthesized children at DRAG
START, from the input-drag latch, before the owner moves - so they are announced at their true
screen position and never travel inside a frozen owner bitmap. Same machinery (`SynthDeactivate` +
`DeletePending`), trigger moved earlier from "containment already broke" to "the owner is about to
move". Alternative worth weighing: dismiss the menu instead, which is what a real WM drag does.

Cannot be tested from here - it needs a dom0-driven drag with a menu held open, and guest-side
SendInput bypasses the dom0 motion path entirely. Needs a hand test on the rig.

## 2026-08-16 — OPEN: a synthesized menu falls off synthesis when its owner is dragged

Owner: "if a synthetic menu is open, it stays in place during the drag and falls off synthesis" -
and "not always but in notepad it does".

**Why Notepad specifically**: its File menu is one of the few popups that measures `synth=yes`
(contained inside the owner - verified earlier today, `#32768` at 408,350 229x196 inside a Notepad at
400,300 800x600). Menus that fall OUTSIDE the owner - Edge's 3-dot menu, most context menus - are
never synthesized, so they cannot fall off. The bug is reachable only where synthesis is reachable.

**Mechanism, from the code (`main.c:3578-3595`)**: when the owner's geometry changes, every
synthesized child is re-tested and materialized once containment breaks:

    if (!SynthQualifies(c, &stillOwner))
    {
        LogInfo("0x%x: owner geometry changed, materializing child", c->Handle);
        SynthDeactivate(c);
        c->DeletePending = TRUE;
    }

A menu is a SEPARATE top-level window with its own screen position. Dragging the owner does not move
it - it stays where it was opened. So during a drag:

1. Early in the drag the menu is still inside the owner's rect, so it stays SYNTHESIZED - painted
   into the owner's buffer. And because a drag FREEZES the owner's content (`PwDragFrozen`, no
   recapture until settle), the menu is baked into the frozen bitmap and TRAVELS WITH THE WINDOW,
   while the real menu is stationary.
2. The owner keeps moving, containment fails, the child materializes and is announced as its own
   window - at its true, stationary position.
3. The frozen owner bitmap still contains the painted menu until the settle recapture, so for a
   moment BOTH are visible.

That also explains the earlier "moments of distortion, self-heals" report: the settle-time full
recapture is what clears the stale painted copy.

**Proposed fix, NOT implemented**: materialize a dragged window's synthesized children at DRAG
START, from the input-drag latch, before any movement - so they are announced at their true screen
positions and are never baked into a frozen bitmap that moves. The machinery already exists
(`SynthDeactivate` + `DeletePending`, used by the containment path above); this only moves the
trigger earlier, from "containment broke" to "the owner is about to move".

NOT ATTEMPTED because it cannot be honestly tested from here: it needs a real dom0-driven drag with
a menu held open, and dom0 pointer injection is not available to this repo (a guest-side SendInput
drag bypasses the dom0 motion path entirely). Needs a hand test on the rig.

## 2026-08-17 — menu-on-drag PARKED, all four mechanisms measured and reverted

Owner: *"it fails. ok let it be for a while. it was okayish when i assumed it auto dismisses, and
seemingly it does not at all."*

Everything added today for this is reverted; the tree is back to the containment behaviour it had
this morning. What was tried, all measured on the rig, none of it working:

| mechanism | result |
|---|---|
| materialize at drag freeze | **never fired** on the owner's path (0 hits) - dead code for a dom0-driven move |
| materialize by membership | fired, but detaching sooner only performed the artefact sooner ("drops out even more aggressively") |
| `PostMessage(WM_CANCELMODE)` cross-process | fired **9x**, ignored; child re-synthesized next pass |
| `SetForegroundWindow(owner)` | returned **TRUE**, changed nothing - the menu's OWNER IS that window, so activation never leaves it |
| `SendInput(ESC)` | fired, ignored |

**The premise was wrong too.** "Okayish" rested on the menu auto-dismissing after a moment; the
owner then established it does not auto-dismiss at all. What dismisses it when you click away is the
CLICK, not the focus change - so the whole focus-based family is dead, not merely misapplied.

**Process failure worth recording.** Five attempts, and the first four shared one fault: asserting
which conditions a code path runs under, or what an API does cross-process, instead of measuring
first. Every correction came from the owner's observation. The reverting commit itself then broke
brace balance on the first try (-2) because I replaced ranges by index without checking; caught by
comparing `{`/`}` counts against HEAD before committing, which is now the minimum bar for any
bulk edit of this kind.

**Do not resume this** without first measuring what actually reaches an open menu owned by another
process from a SYSTEM service. Trying a sixth mechanism blind is not warranted - the underlying
behaviour is cosmetic, and the released fixes have not reached the reporter yet.

## 2026-08-25 — DO NOT ANNOUNCE 4.3.4: end-to-end test says it does NOT fix the AppVM shutdown

Tested the SHIPPED artifact the way a user installs it, not through our pipeline:
win10-tpl destroyed and rebuilt as a clean TemplateVM cloned from the pristine never-networked
win10-clean (stock QWT 4.2.2, `NICS` empty, no QubesPvNic task, stock network-setup.exe present),
then the released `qwt-ng-4.3.4-agente3177a5-setup.tar.gz` extracted and installed in-guest.

**The installer's own fix worked:**

    11:07:50 QwtngNetSetup registered=True; stock network-setup.exe present=False
    11:07:50 LogDir -> Q:\Qubes Logs
    11:07:51 PV NIC unplug latch armed for shutdown (NICS=1)
    "package_version":"4.3.4+agent.e3177a5b6da2","pvnic_prime":"seeded","pvnic_latch":"armed"

**And the AppVM still dies.** Fresh AppVM created on that template: Running for 75 s, then Transient
-> Halted at ~90 s. It is not a first-boot-only effect - it repeats, with a NEW gui-agent log every
~60 s (11:17, 11:18, 11:19, 11:21, 11:22, 11:23, 11:24), i.e. a reboot loop that Qubes eventually
halts.

**The initiator, from the guest's own System log:**

    11:25:36 id=1074  C:\Windows\System32\xenbus_monitor_9_1_0_0.exe has initiated the RESTART
    11:17:50 id=1074  C:\Windows\System32\xenagent_9_1_0_0.exe   has initiated the SHUTDOWN

So the reboot is demanded by the PV drivers' own xenbus_monitor - the AutoReboot path - not by
anything in the gui agent, and our installer explicitly records `"xenbus_autoreboot":true`.

**And the latch value is wrong:** the AppVM reads `NICS=2`, not 1. Our service and task both write 1,
so something overwrites it during the PV NIC install. If 2 does not mean "unplug the emulated NIC",
the emulated NIC survives, xenvif's NET child demands a restart on every boot, xenbus_monitor
performs it, and the qube is halted - which is exactly the observed loop and exactly the field report.

Difference from every AppVM we tested successfully all week: those templates were built by our
pipeline, which never activates the IDD driver. This one went through the SHIPPED installer, which
records `"idd_driver":"activated"`. That is the untested combination, and it is what users get.

4.3.4 fixes a real defect (templates shipped un-latched) but it is NOT the defect behind
"AppVM shuts down seconds after starting". The release must not be announced as fixing that.

## 2026-09-01 — DRAG WOBBLE: full chronology, and the regression that undid the fix

Owner: *"it certainly was deemed acceptable at some moment. dig the full chronology and examine
what is missing."* It was, and something specific undid it.

**Chronology (agent submodule, dates from git):**

    2026-08-12  wobble first root-caused: input translated against the LIVE window origin, which
                leads dom0 and closes a gain-1 loop. A four-fix series landed and was REVERTED
                the same day (e2f36be reverts 43de7d4 ...).
    2026-08-13  the ACCEPTED configuration: content freeze (InputDragFreezeContent), input-rate
                drain (DragEventPriority), MonInfoCache. Servo experiment shipped default-OFF.
                Owner PARKS the wobble - "the difference is marginal, both suck in a way".
    2026-08-16  60f1cb4 quantised origin: translate against an announce dom0 has CERTAINLY
                applied. 9b8f888 ships it at 70/140. a024918 adds a MOTION trace, which MEASURES
                dom0's apply lag for the first time: median 0, p75 17 ms, tail (82, 398).
                b75358b retunes to 25/50 on that measurement (ladder in perf.c; 25/50 was the
                minimum, 20/40 measurably worse). 49c100a adds the interpolated origin.
                **168a869 - "Interpolated origin ON by default: USER-APPROVED drag baseline".**
    2026-08-17..08-31  ~90 further agent commits. VERIFIED: `git diff 168a869..HEAD -- perf.c`
                contains NO change to any InputDrag* knob. The tuning is byte-identical to what
                was approved, so the regression is not a retune.
    2026-08-30  **b71f611 "handle MSG_CROSSING (127) instead of logging it as unknown at input
                rate"** - and this is the one.

**What is missing: `mode`.** `HandleCrossing` released the drag latch on ANY `LeaveNotify`:

    if (crossingMsg.type == LeaveNotify && window && window == g_InputDragWindow) {
        g_InputDragWindow = NULL; g_InputDragOriginValid = FALSE; DragAnnounceClear();
    }

X synthesises crossing events for GRAB BOOKKEEPING as well as for real pointer motion, and
gui-daemon forwards the mode verbatim and unfiltered (`xside.c process_xevent_crossing`:
`k.mode = ev->mode`). **A drag IS a pointer grab**: activating it delivers `LeaveNotify` with
`mode=NotifyGrab` to the windows below the grab window - and dom0 decorates guest windows, so the
WM's grab is on the frame and the guest window sits below it - with the matching `NotifyUngrab`
on release. Reading those as "the pointer left" tears down the drag state at the moment a drag
begins:
 - `g_InputDragWindow = NULL` -> `InputDragFreezeContent` stops suppressing the per-frame
   `PrintWindow`, which is the 193-211 ms startup stall coming back;
 - `DragAnnounceClear()` -> the announce ring `InputDragQuantise` translates against is EMPTY, so
   the reconstruction falls back to the live origin. That is exactly the gain-1 oscillator
   Quantise was written to remove.
So both shipped drag fixes are silently disabled mid-drag and the wobble returns at full
strength - matching "it wobbles as hell" after a period when it was acceptable.

Root enabler: **`NotifyNormal`/`NotifyGrab`/`NotifyUngrab` were never defined** in
`gui-agent/xorg-keymap.h` (only `EnterNotify`/`LeaveNotify` were), so the field was easy to
ignore. Defined now, and the latch release is guarded on `mode == NotifyNormal`. The non-normal
case logs `latch KEPT` with the mode so its frequency is visible.

**NOT CONFIRMED FIRING on a live guest, and that matters.** A scripted drag never arms the latch
(PLAN-drag-quality: it "cannot show this defect at all"), so only a hand drag can prove it. The
tell in the CURRENT build is the line `pointer left the window while the drag latch was held -
releasing it` appearing in the agent log during a drag. If it is there, this is the cause. If it
is absent, the regression is elsewhere and the next place to look is the frame-pipeline gating
added for the secure-desktop work (878ae5e, 7e3f0b6, fb4c1cd), since announces are slaved to
frames.

**Second, independent and already known:** even with the latch intact, `AdoptMs=25` assumes a
constant apply lag against a measured distribution of median 0 / p75 17 / tail 82, 398 ms. Every
announce whose real lag exceeds 25 ms adopts an origin dom0 has not applied, the error takes the
wrong sign, and the loop reopens for those events (perf.c says exactly this). That residual was
accepted at 08-16; it is a tail effect, not the "as hell" case.

## 2026-09-01 — STAGED FOR THE OWNER'S DRAG TEST (build 33454192029, branch fix/drag-crossing-mode)

Two independent changes are waiting on one thing only: a HAND drag. Neither can be graded from
here - a scripted drag never arms the drag latch (PLAN-drag-quality: it "cannot show this defect
at all"), and dom0 menu launchers cannot be clicked from this qube.

**1. Drag wobble - `mode == NotifyNormal` guard on the crossing handler** (agent `8b72b4e`).
   WHAT TO LOOK FOR: drag a window around for ~10 s. The claim is that the wobble returns to the
   2026-08-16 user-approved behaviour. Grade it the way it was graded then - by hand, against
   memory of stock - because that is the only instrument that works.
   THE LOG TELL, which decides it independently of feel:
     - regression present (old binary): `pointer left the window while the drag latch was held -
       releasing it` appears DURING a drag;
     - fix working (new binary): `crossing mode=N on the dragged window - grab bookkeeping,
       latch KEPT` appears instead, with N != 0.
   If NEITHER line appears, the crossing path is not the cause and the next suspect is the
   frame-pipeline gating from the secure-desktop work (878ae5e, 7e3f0b6, fb4c1cd), because
   announces are slaved to frames.

**2. dom0 app-menu launchers - the two fixed ids** (core-agent `b2ccd83`, verified on the guest
   already: both entries emit, both launch, both return in 4-5 s instead of blocking, and File
   Explorer opens on the interactive user's folder). The only unverified step is clicking them in
   dom0 after `qvm-sync-appmenus win10-app`.

**State win10-app was left in** (an AppVM: C: resets on shutdown, so all of this is lost on a
restart and must be re-applied):
 - fixed `start-app.ps1` + `get-appmenus.ps1` deployed over the installed copies, `.orig` backups
   kept alongside;
 - `qemu-extra-args = -serial file:/dev/hvc0` still SET on the qube (survives restarts - it is
   qube metadata, not guest state). Stubdom-side only, cannot affect drag. Remove with
   `qvm-features --unset win10-app qemu-extra-args` + restart if unwanted;
 - test windows closed; a Microsoft Store window opened itself during testing and was left.

**Pushed for CI** (all to the owner's own forks, on branches, nothing to QubesOS):
 - `arkenoi/qubes-gui-agent-windows` -> new branch `fix/drag-crossing-mode` (8b72b4e)
 - `arkenoi/qubes-core-agent-windows` -> `fix/qrexec-wrapper-drain-race` (b2ccd83)
 - `arkenoi/qubes-win-idd-driver` -> new branch `fix/drag-crossing-mode`
`main` here is still 201 commits ahead of origin, unchanged - that is the pre-existing state, not
something this session altered.

**STAGING COMPLETE.** Build 33454192029 green; `gui-agent.exe` = `21E157E1640B9BBB` swapped onto
win10-app with `guest/swap-agent.ps1`, which confirms the RUNNING process hash matches the pushed
binary (`HASH_RUNNING=21E157E1640B9BBB`, `SWAP_OK`) - the "verify the artefact under test is
actually installed" rule satisfied rather than assumed. Seamless re-verified afterwards by pixels:
a Notepad window opened and dom0 captured it cleanly.

**Logging deliberately left at DEFAULT.** `qvm-features win10-app service.gui-agent-debug 1` also
sets `g_ProtoTrace` (perf.c:288), and ProtoTrace multiplies the frame-walk tail (tot max 580 ms vs
66 ms off) - judging drag feel with it on would poison the measurement. So:
  RUN 1 (feel)      - default logging, drag by hand, judge the wobble. This is the verdict.
  RUN 2 (mechanism) - only if run 1 is ambiguous: enable gui-agent-debug, drag, grep the log for
                      the latch lines, and do NOT judge feel on that run.

## 2026-09-01 — the drag just tested was measured with ProtoTrace ON. Verdict void, guest re-staged

Owner dragged and I went looking for the evidence. Found something that invalidates the run:

    HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent
        ProtoTrace       = 1
        ProtoTraceWobble = 1

Left set in the registry from an earlier debugging session and never cleared. The running agent's
log confirms it was ACTIVE, not merely configured: **1900 of 2076 lines were QGAPROTO**. This
project's own rule, `docs/PLAN-drag-quality.md:83`: *"ProtoTrace=1 multiplies the frame-walk tail
(tot max 580 ms vs 66 ms off). **Never judge latency with it on.**"* So "wobbles as hell" was
measured on a build carrying a known latency multiplier, and it says nothing about the crossing
fix either way. **The verdict is void - not negative.**

Cleared both keys, restarted the agent (pid 7692, hash 21E157E1640B9BBB - still the fixed build),
and confirmed the trace really stopped: **QGAPROTO now 1 line of 140.**

**Why the log showed zero crossing lines, and why that is NOT evidence of absence.** Every line in
that log is `-I]` (Info). `LogLevel = 3` on the parent key filters Debug and Verbose, and both the
crossing tell-tales are below Info - `HandleCrossing`'s per-event line is LogVerbose, and the
latch-release / latch-KEPT lines are LogDebug. At this level they cannot appear no matter how many
crossings arrive. This is the same class as the recorded trap "a stale gui-agent\LogLevel silently
discards every LogDebug line - hours of instrumentation went to a file nobody wrote", and it cost
a round again today.

**Guest is re-staged for a clean run:** fixed agent running, ProtoTrace off, a Notepad window open.
 - RUN 1 (feel, do this first): drag by hand. Quiet build, no trace, no debug logging. This is the
   verdict.
 - RUN 2 (mechanism, only if run 1 is ambiguous): set
   `HKLM\...\Qubes Tools\gui-agent\LogLevel = 5` (Verbose), restart the agent, drag, then grep for
   `crossing` / `latch KEPT` / `drag latch was held`. Do NOT judge feel on that run - and put
   LogLevel back afterwards.

## 2026-09-01 — STOPPING the drag work. Three hand drags burned, zero measurements. Read this first.

Owner: *"why did i drag at all?"* and *"you are obviously in degraded state"*. Both correct, and
the record needs to say so plainly rather than leave a trail of half-claims.

**Three drags, nothing to show:**
 1. drag 1 - VOID. I said the guest was staged without checking its registry; `ProtoTrace=1` and
    `ProtoTraceWobble=1` were still set from an old session, and this project's own rule is never
    to judge latency with them on. My staging error, not a finding.
 2. drag 2 - NO INSTRUMENT. I asked for it before arming anything, then discovered the tell-tale
    lines are LogDebug/LogVerbose and `LogLevel=3` filters them. Nothing could have been learned.
 3. drag 3 - INSTRUMENT DID NOT FIRE. `sample-window-motion.ps1` reported `armed: true`, the
    `QwtWinMotion` task shows state Ready (so it ran and exited), and **no `winmotion.txt` was
    ever written** - not even the script's own "no notepad" sentinel. So the task failed before
    its first write. Cause unknown; the arming function's success return is clearly not evidence
    that sampling happened, which is itself a defect in the instrument.

**What is actually established about the wobble (all code-reading, none of it measured):**
 - The three good translation branches all gate on `window == g_InputDragWindow &&
   g_InputDragOriginValid`; anything else falls through to the LIVE origin, i.e. the gain-1
   oscillator. So any path that fails to arm or clears the latch mid-drag silently restores stock
   wobble.
 - `g_InputDragOriginValid = (buttonMsg.type == ButtonPress) && haveTracked` - a press that does
   not find the window tracked disables the whole mechanism for that drag.
 - The `MSG_CROSSING` handler (b71f611, 2026-08-30) cleared that state on ANY LeaveNotify,
   ignoring `mode`. Fixed (8b72b4e) and shipped in the build now on the guest. **Did not resolve
   the owner's complaint**, so it was at most contributory. The fix is still correct - grab
   bookkeeping must not be read as a departure - but it is NOT the regression.
 - Fault injection is compiled into this build (044712a) but is NOT armed: the only values under
   the gui-agent key are ProtoTrace=0 and ProtoTraceWobble=0. Ruled out.
 - No `InputDrag*` default changed between the 2026-08-16 user-approved baseline (168a869) and
   HEAD. The regression is therefore in behaviour around the drag path, not in its tuning.

**Where the next session should look, in order** (do NOT re-derive the above):
 1. Arm a WORKING ground-truth sampler first and prove it writes a file BEFORE asking for a drag.
    Fix `sample-window-motion.ps1` or replace it; its "armed" return is not proof.
 2. The 141-line insertion in the frame path at `FrameRedundant`/`ProcessNewFrame` from the
    secure-desktop freeze work (878ae5e, 7e3f0b6, fb4c1cd). Announces are slaved to frames, and
    the quantise law needs a paced announce stream; a new early-return in that path is the
    strongest remaining candidate and was never examined.
 3. `ShouldAcceptWindow` (+72 lines, several new `return FALSE`) and `IsPopup` (+40): a window
    that stops being tracked stops arming the latch.

**Process note, kept because it cost the owner three drags.** The failure mode was mine and it is
the recorded one: reading code and re-staging instead of measuring, and treating my own setup
errors as discoveries. The rule that would have prevented all three: an experiment whose
instrument has not been shown to produce data on a known-good subject is not ready to run, and a
human's time is the most expensive input on this rig.

## 2026-09-01 (session 2) — the tuning WAS committed; the instrument now exists; dom0's apply lag is the mechanism

Owner: *"my main suspect is tuning: you could commit the code, but not the script that writes
proper defaults for it."* Checked properly, and it is not that. What the check DID turn up is a
measured mechanism that needs nothing in our code to have regressed.

### 1. The tuning is in the code, and the guest is running it

 - `b75358b` (2026-08-16 18:33) put `AdoptMs=25 / AnnounceMs=50` in `perf.c`; `168a869` put
   `OriginInterp=TRUE` there. `git diff 168a869..HEAD -- gui-agent/perf.c` changes no drag
   default; no drag constant in main.c/main.h changed either (`CFG_POS_MIN_INTERVAL_MS`,
   `DAEMON_DRIVE_ACTIVE_MS`, `DAEMON_MOVE_INFLIGHT_MS`, `DAEMON_OFF_TTL_MS`,
   `INPUT_DRAG_STUCK_MS`, `DRAG_ANNOUNCE_RING` all identical).
 - The live guest confirms it from the other end. Full dump of
   `HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools` on win10-app: root key has SeamlessMode,
   DisableCursor, LogDir, Fullscreen/Windowed W/H, LogLevel=3, Vchan*; the `gui-agent` subkey
   has ONLY `ProtoTrace=0` and `ProtoTraceWobble=0`. **Zero `InputDrag*` overrides**, so the
   running agent is on compiled-in defaults - which equal the approved values.
 - The installer seeds only `SeamlessMode`, `DisableCursor`, `LogDir`
   (`packaging/setup/Install-QwtImproved.ps1`). There is no missing seeding script to find,
   because none is needed.
 - `guest/tune-drag.ps1` and `scratchpad/{swap-interp,set-rung,drag-mode}.ps1` write the knobs
   by hand, and nothing in the install path calls them. Every value they set is also a code
   default at the approved value.

**So the owner's main suspect is disproven, with evidence from both ends.**

### 2. What the approval state really was, and the two things about it that were NOT code

The LAST acceptance is **2026-08-16 evening, baseline v2** ("good enough, we can stop here and
take it as baseline"). Earlier ones: 08-12 drag REPLAY "all good" (a different defect, dom0-WM
drags), 08-13 "parked - both suck in a way" (not an approval), 08-16 morning baseline v1
(70/140, superseded the same day).

Two properties of that approved run are not in any commit:
 - it ran with **`ProtoTrace=1`** (written by `scratchpad/swap-interp.ps1` - the ladder metric is
   computed FROM that trace, so every rung including the approved one had it on), and
 - on a build with **`QGA_PERF_DEFAULT` = 1**, a per-frame QGAPERF line by default. `ffae88a`
   (2026-08-27) set it to 0 for log-size reasons.
Both make the approved build slower than today's on the frame/announce path, and the drag law is
a delayed-feedback controller fitted to that timing. **Measured today and NOT supported as the
cause**: the announce cadence on the quiet build is 14.9/s (gap p50 67 ms) against 13.7/s
recorded at approval. The plant did not move here. Recorded so nobody re-derives it.

### 3. Also found: three drag fixes were reverted as collateral in 2026-08-12 and never re-landed

`43de7d4` landed four; `e2f36be` reverted all four because sub-fix 1 (suppress ALL PrintWindow
recapture for the latched window) was measured to make the wobble WORSE. The other three -
latched-window rate-limiter exemption, inbound MSG_MOTION coalescing, and **ignore mid-drag
daemon configures while the latch holds** - were measured INERT that day and went with it. The
configure guard is re-added here as `InputDragCfgGuard` (DEFAULT OFF) because the machinery it
guards (`DaemonStreamTick`, `ApplyPendingDaemonMove`) only landed in `336ccc7`, AFTER the
measurement that called it inert. Measured again today on the synthetic drag: still zero inbound
configures inside the latch window, so still inert THERE - the hand-drag trace decides it.

### 4. The instrument now exists, and it is calibrated

Improved the EXISTING QGAPROTO trace rather than adding another (agent `3d5afec`):
 - `ProtoTraceDrag=1` enables ONLY the input-rate messages (~44 lines/s measured), leaving the
   per-DAMAGE-rect flood off - so feel and mechanism come from the SAME run instead of the two
   incomparable runs the "never judge latency with ProtoTrace on" rule used to force;
 - `msg=MOTION` gained `br=` (which of the three fixed translation laws the event took; `trk`
   said 1 for the LIVE origin too, so the old line could not tell "the fix applied and still
   wobbles" from "the fix was never armed") and `wx,wy` (the window's real position per event);
 - `msg=DRAGLATCH` names every arm/teardown with `armed=`;
 - `msg=CONFIGURE-IN` / `msg=DAEMONMOVE` name what an inbound configure DID.
`tools/drag-analyze.py` reads the trace and fits dom0's apply lag from it.

**Calibrated against known truth** (`dragsim.c` injects a chosen dom0 lag; guest win10-app,
agent `EB25802E85D471A8`, hash-verified running, shipped tuning, quiet build):

| injected dom0 apply lag | analyzer's fitted lag | window-path reversals | mean deviation |
|---|---|---|---|
| 17 ms (the p75 the tuning assumes) | **10 ms** | 5 % | 1 px |
| 80 ms | **90 ms** | 41 % | 187 px |
| 200 ms | **190 ms** | 40 % | 828 px |

The fit recovers the injected value within one 10 ms grid step every time, and the wobble metric
moves 5 % -> 41 % with it. **The check has been seen to FAIL on a deliberately reintroduced
defect**, which is what makes a PASS mean anything (CLAUDE.md evidence rule 5).

### 5. The mechanism this exposes

At the shipped tuning, with dom0 answering in 17 ms, the drag is EXACT at every hand speed
tested (150/400/900/1600 px/s: 1 reversal, mean deviation 1 px - the single reversal is a
stimulus artefact, `SimPath` starts the triangle at -amp so the first event teleports the cursor
by one amplitude). The law only breaks when **dom0's actual apply lag exceeds the assumption**:
22 % reversals at 80 ms, 35 % at 200 ms - and 16-19 % is the wobble signature as originally
measured. Matching the estimator to reality (`InputDragLagMs` = the real lag) collapses the
positional error (187 -> 27 px at 80 ms; 828 -> 14 px at 200 ms) but not the reversals, so a slow
dom0 is intrinsically jittery and a WRONG assumption about it is what adds the large excursions.

**Consequence: "we fixed it once, now it wobbles like crazy again" is fully explained by dom0's
apply lag rising past ~25 ms, with no regression anywhere in our code.** That is consistent with
every negative result to date: no knob changed, no default lost, the latch arms, and the branch
taken is INTERP for 100 % of events. It is a HYPOTHESIS until dom0's lag is measured on a real
drag, which is the one thing a script cannot do (owner, this session: *"instrumented drag that
does not depend on pointer fails to do it"* - and indeed the synthetic drag is clean at 1 %).

### 6. State the guest was left in - ready for ONE hand drag

win10-app, agent `EB25802E85D471A8` (running hash verified against the pushed artifact),
Notepad `0xC001A` at 600,400 900x650. Banner asserted from the log, not assumed:

    QGADRAGQUANT on (adopt=25 ms, announce pacing=50 ms)
    QGADRAGINTERP on (lag=10 ms)
    QGAPROTO off (wobble probe off, drag-only trace on)
    QGAPERF off
    QGADRAGCFGGUARD off

Quiet build, so the feel verdict is valid on the same run as the mechanism. Drag Notepad by its
title bar for ~10 s, then `guest/drag-trace-run.ps1 -Sim 0 -WaitMs 0` pulls the lines and
`tools/drag-analyze.py` answers all four questions at once.

## 2026-09-01 (session 2, cont.) — ROOT CAUSE: one crossing event disables every drag fix

The hand drag the previous session could not turn into a measurement. Guest win10-app, agent
`EB25802E85D471A8` (running hash verified against the pushed artifact), shipped tuning asserted
from the log banner, quiet build (`QGAPROTO off ... drag-only trace on`, `QGAPERF off`), so the
feel verdict and the mechanism come from the same 5 s.

    press     t=0
    crossing  t=+569 ms   LeaveNotify mode=0 (NotifyNormal)  -> latch released
    release   t=+4985 ms

|  | motion events | translation branch | window-path reversals |
|---|---|---|---|
| before the crossing | 50 | 50/50 INTERP | 4/50 = 8 % |
| after the crossing | 490 | **489/490 LIVE (gain-1 oscillator)** | 99/490 = **20 %** |

20 % against the 16-19 % that defined the wobble when it was first measured. One event, and
every shipped drag fix stops applying at once - the interpolated origin, `InputDragFreezeContent`,
`DragEventPriority`, and the 50 ms announce pacing all gate on `g_InputDragWindow`. The announce
rate inside the drag was 33.5/s (gap p50 30 ms) against the ~14/s the 2026-08-16 ladder was
fitted at, because pacing is one of the things the latch gates.

**The event, and what the wire looked like on either side of it.** It was
`mode=0 (NotifyNormal), detail=3 (NotifyNonlinear)` - X's label for a real move between windows
in different branches, not bookkeeping. Before it, `ox/oy` steps cleanly to each announced
position and `rx` stays in a ~420-610 band while the window walks 605 -> 1388 px. After it, `ox`
is the LIVE window origin and the loop diverges within four events:

    +551  MOTION rx=435 ox=1369 br=2   CONFIGURE x=1395     <- last good event
    +569  DRAGLATCH ev=crossing armed=0 mode=0 detail=3
    +569  MOTION rx=474 ox=1435 br=0   CONFIGURE x=1496
    +651  MOTION rx=745 ox=1386 br=0   CONFIGURE x=1386
    +670  MOTION rx=103 ox=2072 br=0   CONFIGURE x=2072
    +701  MOTION rx=1034 ox=1212 br=0  CONFIGURE x=1212
    +718  MOTION rx=1073 ox=2475 br=0  CONFIGURE x=2475
    +751  MOTION rx=1477 ox=867  br=0  CONFIGURE x=867

i.e. announced positions swinging 867 <-> 2475 - **~1600 px excursions at ~15 Hz** - which is the
"wobbles like crazy" the owner reported, written down.

**Why the previous session's mode guard did not save it.** `8b72b4e` reasoned that X synthesises
crossings for grab bookkeeping and guarded on `mode == NotifyNormal`. True, and insufficient: the
event that does the damage IS normal-mode. In a guest-native drag the WINDOW is what moves - each
announced position makes dom0's WM move the frame under a hand that is nearly stationary in root
coordinates - and a window moving out from under the pointer is exactly what X reports as a
normal-mode LeaveNotify. The handler's premise, "a pointer that has left the window cannot still
be dragging it", is false whenever the window is the thing that left.

**Fix (`6385c25`): the button decides, not the mode.** `msg_crossing.state` carries X's button
mask and gui-daemon forwards it verbatim (`xside.c`: `k.state = ev->state`). While button 1 is
held there is no such thing as "the drag ended". The only case this release was ever written for
- a LOST Button1 release - is exactly the case where the mask is clear, so the guard costs it
nothing, and a genuinely stuck latch is still caught twice over (the next Button1 event anywhere,
and the `INPUT_DRAG_STUCK_MS` sweep). `detail == NotifyInferior` is excluded for the same reason
as the grab modes: the pointer moved to a child window and is still inside.

**Two hypotheses this measurement killed, recorded so they are not re-run:**
 - dom0's apply lag. The synthetic calibration is real (22 % reversals at 80 ms, 35 % at 200 ms
   against 1 % at 17 ms) and worth keeping as the known failure mode of `AdoptMs`/`LagMs`, but it
   is not what happened here: 91 % of the drag's events never consulted the announce history at
   all. The lag fit on this trace is meaningless for the same reason.
 - `InputDragCfgGuard` (ignore mid-drag daemon configures). The hand drag recorded **0**
   `CONFIGURE-IN` and **0** `DAEMONMOVE` with `drag=1` - inert on the real path, exactly as
   `e2f36be` measured it on 2026-08-12. The knob stays, default OFF, and should not be revisited
   without a trace that shows a non-zero count.

**Evidence rule 5 is satisfied without extra work**: the build that produced the table above IS
the defect build, measured on the same guest, same window, same tuning, with the same instrument
that will grade the fix. The failing side is not hypothetical.
