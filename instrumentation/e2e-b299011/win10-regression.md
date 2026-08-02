# Win10 protocol/acceptance regression for the five win11-line fixes — b299011 clean install

Run 2026-08-02 15:12–15:31 on `win-idd-test` (Win10 22H2, 10.0.19045.2965), the brand-new
clean install of 2026-08-02 14:34.

**Install identity, measured, not assumed** (`gate0.raw`):

```
RESULT=AGENTHASH 4B4CE2B1C5441C88F73A47E4608AA075DCCCA356C2B1FAC48A58DA90D3059E8E
RESULT=ORIGCOUNT 0
RESULT=TESTSIGNING testsigning  Yes
RESULT=SERVICES QdbDaemon=Running;QrexecAgent=Running;QubesGuiWatchdog=Running
RESULT=REG [...\gui-agent] LogLevel=3 ProtoTrace=<absent>       (pre-run baseline)
```

Hash matches the package manifest for b299011; zero `*.orig` in `bin\` — MSI-installed, never
overlaid. Agent submodule `b299011` contains the five fixes under test: `a5012a5` fallback
owner, `832ce97` overhang 4→12, `d6ab61c` small-popup floor, `3c12071` shell-overlay
rejection, `d610454` synthesize-or-drop.

## Verdict

**The four acceptance conditions the task defined all PASS, on non-empty data.**
**One additional confirmation the task asked for came out NEGATIVE and is reported as a
finding, not smoothed over:** `QGADRAG,ev=maskpush` **does** fire during genuine joint
owner+child motion — 58 pushes in 2.6 s — once the scenario that actually produces joint
motion is built (the scripted drag cannot produce it, see Scenario 6).

| condition | result | evidence |
|---|---|---|
| protocol invariants hold on non-empty data | **PASS** | drag run: 579 QGAPROTO records, `all invariants hold`; scenario run: everything except the pre-known stale `menu-announced` |
| no legit-window rejections (`3c12071`) | **PASS** | 0 rejection lines in 4 LogLevel=4 logs covering 12 distinct windows |
| no sub-floor announcements (`d610454`) | **PASS** | 0 sub-floor drop lines; smallest window ever announced is 286x393, floor is 136x39 |
| chromerepro 5 / 1 | **PASS** | `GUEST-COUNT=5`, `MAPPED-OF-OURS=1`; dom0 shows exactly 1 bordered window |
| *(also asked)* `maskpush` absent during joint owner+child motion | **NOT CONFIRMED — contradicted** | 58 maskpushes in 2.6 s of lockstep owner+child motion (`jointmove2`) |

Two suite invariants fired and were adjudicated against stronger evidence, exactly as the
task instructed; both are known tooling debt, restated below with their limits.

Scope, stated up front: this run proves the five fixes cause **no Win10 regression**. It does
not prove they work — none of the Win11 constructs they target exists here. Same conclusion as
the 2026-08-02 02:45 run on the previous install; see "What this run does NOT establish".

---

## Setup and knob hygiene

`HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent`: `ProtoTrace`=1 (was **absent**),
`LogLevel`=4 (was 3) — the per-module key, as instructed, because both greps this task depends
on are `LogDebug`. Agent restarted via `Stop-Process -Name gui-agent -Force` (watchdog
respawn); a new log file confirmed each time.

`LogLevel=4` verified **effective**, not assumed: 1878 / 713 / 340 / 684 lines at level `D` in
the four pulled logs, including `GetRealWindowRect`, `SendWindowConfigure`, `SynthUpdateMask`
and the `QGADRAG` markers. So both target lines were emittable.

Line-number note: the task cites `main.c:1924` (3c12071) and `main.c:1175` (d610454). In the
`b299011` checkout they are at **1976** and **1227**. The greps below match on the log *string*,
not the line number, so the discrepancy does not affect the result.

**Restored** (`trace-off.raw`, `cleanup-verify.ps1`): `ProtoTrace` removed, `LogLevel`=3, agent
restarted, `PROTORECS-AFTER 0`, `DEBUGLINES-AFTER 0`, `RESULT=REG LogLevel=3
ProtoTracePresent=False`. All windows opened by this run closed (`RESULT=PROCS 0`). Post-restore
`qtest shot` returns a live, correct Notepad window (`post-restore/win-0.png`) — seamless
survived the whole run. Services all Running. The VM was never killed, restarted or
reconfigured; netvm untouched.

---

## Scenario 1 — two overlapping Notepads, typing into the front one (occlusion)

`w10-scn1.ps1`. BACK `0x802c0` at (150,120) 700x500, FRONT `0x402b4` at (500,320) 700x500
(overlapping BACK's lower-right). 40 keystroke bursts into FRONT over 12.1 s.

QGAPROTO census inside the typing phase (`151354.960`–`151407.023`):

```
type    76 recs  {'DAMAGE': 76}
        DAMAGE by hwnd: {0x402b4: 76}     <- FRONT only
                                          <- BACK 0x802c0: ZERO damage records
```

76 damage messages, every one to the front window, none to the occluded one. Non-empty, and
the invariant is satisfied on it.

dom0 pixel confirmation (`menu-held-shot/win-0.png`, BACK, captured while both windows were
up and the menu was open): completely clean — no text from the front window, no menu
fragments, no debris anywhere in the covered region.

## Scenario 2 — Notepad File menu opened and HELD

Same run. Menu `0x6006e` at (508,370) 229x196, held ~6 s with 6 hover steps, left open while
dom0 was photographed.

The menu was **never announced** and **never mapped**. It was synthesized:

```
[151410.085] SynthActivate: QGAPROTO,msg=SYNTH,hwnd=0x6006e,owner=0x402b4,x=508,y=370,w=229,h=196
             QGAPROTO,msg=SYNTHPAINT,hwnd=0x6006e,owner=0x402b4,...   x13
```

`0x402b4` is the FRONT Notepad — the menu's real owner, so the owner selection picked
correctly (via the ordinary `GW_OWNER` path; `a5012a5`'s same-process fallback was not entered,
see scope note).

dom0 while held (`menu-held-full/geometry.txt`) lists exactly three windows for the qube:

```
0x1c00188 0 0 3440 1440 0 VMapp command
0x1c00189 157 120 686 493 0 Untitled - Notepad
0x1c0018b 507 320 686 493 0 *Untitled - Notepad
```

**No separate menu window, no phantom window, no bordered fragment.** The front Notepad's PNG
(`menu-held-shot/win-1.png`) shows the File menu drawn correctly inside the window, unbordered,
with the typed text intact around it.

### Adjudication 1 — `check-protocol.py` `menu-announced` (pre-known, per task instruction)

```
$ python3 tools/check-protocol.py scn1-trace.log scn1-guest.json
records=149 guest_windows=9
  CONFIGURE=6 CREATE=3 DAMAGE=122 MAP=4 SYNTH=1 SYNTHPAINT=13
FAILED 1 invariant check(s):
  [menu-announced] menu hwnd=0x6006e was visible in the guest but never mapped
```

**Stating it explicitly, as required: this failure is the synthesis path working.** The
invariant counts only `MAP` as "announced" and predates composite synthesis. Judged on the
`QGAPROTO msg=SYNTH` record: `0x6006e` has a SYNTH record naming its true owner, 13
SYNTHPAINTs, and dom0 carries no separate window for it while rendering it correctly inside its
owner. The checker needs a `SYNTH`-aware clause; that is tooling debt, not an agent defect.

Every other invariant in that run holds: `popup-override-redirect`, `damage-within-window`,
`no-damage-to-occluded-window`, `origin-known-for-damaged-windows`,
`geometry-matches-visible-window`, `origin-matches-visible-window`.

## Scenario 3 — drag (damage-within-geometry, origin-known)

`w10-scn2.ps1`: menu closed with ESC, then the front Notepad dragged by its title bar with
synthetic `SendInput` in a circle, radius 180 px, **321 moves in 10.23 s**.

```
$ python3 tools/check-protocol.py scn2-trace.log scn2-guest.json
records=579 guest_windows=8
  CONFIGURE=428 CREATE=3 DAMAGE=130 MAP=4 SYNTH=1 SYNTHPAINT=13

all invariants hold
```

Non-empty specifically *inside the drag phase* (`151601.929`–`151612.476`):

```
drag   428 recs  {'CONFIGURE': 422, 'DAMAGE': 6}
       CONFIGURE by hwnd: {0x402b4: 422}
       DAMAGE    by hwnd: {0x402b4: 6}
```

So `damage-within-window` and `origin-known-for-damaged-windows` had data to judge during the
drag, and passed. Announced geometry equals DWM extended frame bounds exactly, not
`GetWindowRect`:

| hwnd | announced (last CONFIGURE) | guest `GetWindowRect` | guest DWM extended |
|---|---|---|---|
| `0x802c0` | (157,120) 686x493 | (150,120) 700x500 | **(157,120) 686x493** |
| `0x402b4` | (506,320) 686x493 | (499,320) 700x500 | **(506,320) 686x493** |

### QGADRAG marker counts (asked for explicitly)

Drag phase (`151601.929`–`151612.476`):

| marker | count in drag phase | count in whole scenario log |
|---|---|---|
| `ev=suppress` | **154** | 155 |
| `ev=refresh` | **56** | 58 |
| `ev=settle` | **0** | 2 (both at window creation, 151344.601 / 151347.632) |
| `ev=maskpush` | **0** | 2 |

422 CONFIGUREs against 6 DAMAGEs is `d64bca6`'s move-only recapture suppression engaging.

The two `maskpush` records in this log are at `151410.085` (menu open — `SynthActivate`) and
`151556.866` (menu close, `n=0`), i.e. **outside the drag window entirely**. That is a true
statement about this drag, but it is a weak one: `w10-scn2.ps1` presses ESC before dragging, so
there is no synthesized child at all during the drag. Scenario 6 builds the missing condition.

## Scenario 4 — `occlusion-test.ps1` + `check-occlusion.py`

```
$ python3 tools/check-occlusion.py occlusion.raw
base=0x2026e cover=0x202d0
  phase visible: 5 damage rect(s), 5 reaching past x=300
  phase hidden : 6 damage rect(s), 6 reaching past x=300
FAIL [under-clip] BASE was sent damage at rx=0 w=586 (reaches 586) while COVER is on top
occlusion clipping is WRONG
```

### Adjudication 2 — the checker's screen-slice criterion is INVALID here (documented 2026-08-02)

BASE was per-window-captured for the whole test, from the agent's own log (`agent-occl.log`):

```
[151736.804] PwInit: per-window capture ENABLED
[151751.419] PwAttachWindow: 0x2026e: per-window buffer 586x393 (225 pages) attached   [BASE]
[151751.788] PwAttachWindow: 0x202d0: per-window buffer 286x393 (110 pages) attached   [COVER]
[151801.991] PwDetachWindow: 0x202d0 ...      [151809.335] PwDetachWindow: 0x2026e ...
```

Both attaches precede the `visible` phase marker (`151757.741`) and both detaches follow the
`hidden-end` marker (`151807.179`), so BASE was PW-fed in **both** phases. A PW window's damage
rects are its own buffer geometry, never an intersection with a composited screen dirty rect —
the PW branch in `main.c` `continue`s before the `rgnCovered` clipping code by design, clipping
being retained only for LEGACY-path windows underneath. The checker's literal criterion is
therefore unsatisfiable by a PW-attached window and its failure says nothing about this build.
**`check-occlusion.py` needs a PW-aware rewrite before its result counts again.**

Adjudicated by dom0 pixel evidence, as instructed (`occl-pixel.ps1`, `occl-pixel-analysis.txt`,
BASE white, COVER pure red, captured while overlapping; dom0 geometry BASE x=119 w=586,
COVER x=428 → overlap is BASE-relative x ≥ 309):

```
BASE png 586x393; overlap columns x>=309
BASE red-ish pixels, whole window : 9 / 230298
BASE red-ish pixels, x>=309       : 0        <-- bleed criterion
COVER own PNG red-ish             : 82289 / 90768 (90.66%)   <-- detector sensitivity control
```

Zero bleed. The 9 stray red-ish pixels are in BASE's own title-bar app icon, outside the
overlap columns (visible in `occl-pixel-shot/win-2.png`, which is otherwise a clean white
window).

**Honesty markers, unchanged from the previous run:** the pixel check has an
instrument-sensitivity control but **no defect-injection control** — no build with the bleed
re-introduced was run in this session, so its PASS is **unproven by negative control**.
`check-occlusion.py`'s own documented controls (`0eabb2b8a0fc`, `5598a2fbda93`) were taken on
screen-slice builds; its discriminating power on a per-window build is not established in
either direction.

## Scenario 5 — chromerepro (2A-chrome)

`artifacts/chromerepro.exe` SHA256 `4f64d30a…9e3d2` (guest re-hashed the same value), pushed
and run on a fresh agent log.

```
RESULT=GUEST-COUNT 5
RESULT=MAPPED-OF-OURS 1
RESULT=MAPPED-HWNDS 0x602ce
RESULT=TOTAL-SENDWINDOWMAP 10
```

Guest-side inventory (`%TEMP%\chromerepro.txt`): main `0x602CE` (`QubesChromeReproMain`,
style `0x14CF0000`, ex `0x00000100`) + shadow0..3 `QubesChromeReproShadow` (style `0x94000000`,
ex `0x080800A0` = LAYERED|TRANSPARENT|TOOLWINDOW|NOACTIVATE, alpha 160, owned by main,
160 px thick vs `SM_CXMIN=136 SM_CYMIN=39`) — all four strips are **above** the size floor, so
they had to be rejected by the chrome predicate, not by the size filter.

Agent's own `SendWindowMap` census in that log: `0x402b4`, `0x802c0` (the two pre-existing
Notepads) and `0x602ce` — of *our* five windows, only the main one. dom0 agrees:
`chromerepro-full/geometry.txt` lists exactly one chromerepro window
(`0x1c0018d 1419 495 626 453 chromerepro - main window`) and no shadow strips.
**5 guest windows → 1 dom0 window.**

Method note (kept from the previous run because it is the documented false-PASS mechanism):
counting screenshot PNGs alone would be unsound — `import -window` fails silently on
layered/transparent windows. The count comes from the agent's `SendWindowMap` lines; dom0 is
corroboration.

Log-level note: the `rejecting compound-window chrome` line is `LogVerbose` (level 5), so it is
absent at LogLevel=4. That absence is expected and is **not** evidence either way; the
`MAPPED-OF-OURS=1` census carries the result.

## Scenario 6 — joint owner+child motion (the `maskpush` confirmation) — NEGATIVE

The task asks to confirm `ev=maskpush` does not appear during joint owner+child motion. The
scripted drag cannot answer that, so two extra probes were built.

**6a — `jointmove.ps1`: Win10 menus do not travel with their owner.** File menu opened on a
Notepad, then the owner moved in 40 steps of (6,3) px. The transcript samples both rects each
step:

```
STEP 0  owner=400,300  menuvis=1  menu=408,350
STEP 39 owner=634,417  menuvis=1  menu=408,350
```

The owner travelled 234 px; the `#32768` menu never moved. So this is **not** joint motion, and
the 3 maskpushes it produced (`n=1, n=1, n=0`) are legitimate mask changes. It did produce a
useful side result: the menu drifted out of the owner's buffer and was **materialized**
correctly — `SynthActivate SYNTH hwnd=0x501ce owner=0x5019c` followed by
`CREATE hwnd=0x501ce 229x196 ovr=1` — i.e. `d610454`'s "announce only when synthesis cannot
represent it, and only above the floor" path, exercised and correct (229x196 ≫ 136x39).

**6b — `jointmove2.ps1`: genuine joint motion, built explicitly.** An owned, caption-less
(→ override_redirect → synthesis-eligible) WinForms child was repositioned in lockstep with its
owner, 40 steps of (6,3) px in 2.6 s. Lockstep verified in the transcript (`rel=88,75` constant
for all 40 steps) and in the agent's own view (`SYNTHPAINT ... rx=81,ry=75` constant every
frame — 81 rather than 88 because the owner's announced origin is DWM-inset by 7 px). The child
was synthesized once (`SYNTH hwnd=0x601ce owner=0xb0080`) and never announced.

Result during the joint-motion phase:

```
during joint phase: {'maskpush': 58, 'refresh': 15, 'suppress': 25}
```

**58 maskpushes in 2.6 s — two per motion step.** The mechanism is visible in `agent-joint2.log`;
one representative pass:

```
[152718.132] GetRealWindowRect: 0xb0080: rect (343,218) 686x493      <- owner interrogated
[152718.132] SendWindowConfigure: ...,hwnd=0xb0080,x=343,y=218,...
[152718.132] SynthUpdateMask: QGADRAG,ev=maskpush,hwnd=0xb0080,n=1   <- push #1 (MIXED state:
                                                                       new owner, stale child)
[152718.132] GetRealWindowRect: 0x601ce: rect (424,293) 240x180      <- child interrogated
[152718.132] SynthUpdateMask: QGADRAG,ev=maskpush,hwnd=0xb0080,n=1   <- push #2 (restore)
```

`SynthUpdateMask` only pushes when the computed mask differs from the memo, so these two
pushes necessarily carried *different* rects: the mixed-state mask and then its restore.
That is precisely the cost `SynthFlushMasks` (main.c:1141-1158, and its comment) exists to
eliminate — "Computing at the call sites instead pushed a mixed-state mask plus its restore -
two forced recaptures per pass, at input rate during a menu-over-drag."

Reading of the mechanism (source-consistent, not directly instrumented): the deferral is
per-*pass*, and `TrackWindows`' non-resync path processes only the windows in the current
`SetWinEventHook` batch (main.c:2455-2469). A joint move emits the owner's and the child's
`LOCATIONCHANGE` in separate batches, so the owner's pass flushes a mask computed against the
child's stale position, and the child's pass flushes the restore. The within-pass deferral works;
the across-pass case is not covered. Each push takes `WcSetMask`'s exclusive engine lock and
forces a full recapture, so this is 2 forced recaptures per input event for as long as a menu
is up over a moving window.

Scope of this finding, honestly: the harness sets the two window positions in two separate API
calls sub-millisecond apart. A real app doing the same in one `DeferWindowPos` batch would
still generate two separate WinEvents, so the finding should generalise — but that has not been
measured. **No negative control** was run for it either; it is a positive observation of an
unexpected marker, which needs no control to be believed, but its *magnitude* on a real Win11
menu-over-drag is unmeasured. It does not affect the four acceptance conditions, and no visual
defect was observed as a result of it in this run.

## Scenario 7 — the two grep-based regression checks

Across all four LogLevel=4 logs pulled — `agent-scn.log` (346932 B), `agent-occl.log`
(112132 B), `agent-chrome.log` (37637 B), `agent-joint2.log` (95434 B) — covering the desktop
pseudo-window, 3 Notepads, a `#32768` menu, 2 WinForms occlusion windows, a WinForms owner+child
pair and chromerepro's main + 4 shadow strips (12 distinct HWNDs):

| grep | source | hits |
|---|---|---|
| `click-through uncapturable shell overlay ... rejecting` (`3c12071`, main.c:1976, LogDebug) | 4 logs | **0** |
| `sub-floor popup ... dropping silently` (`d610454`, main.c:1227, LogDebug) | 4 logs | **0** |
| any line containing `rejecting` | 4 logs | **0** |

**No legitimate window was rejected.** The chromerepro strips remain the sharpest available
test: ex-style `0x080800A0` carries TRANSPARENT and TOOLWINDOW but **not**
`WS_EX_NOREDIRECTIONBITMAP` (`0x00200000`), so `3c12071`'s three-bit conjunction correctly did
not fire on them — they were dropped by the older, narrower 2A-chrome rule instead. That is the
intended narrowness of `3c12071` demonstrated on real windows.

**No sub-floor fragment was announced.** Complete set of announced windows across every run
(floor `SM_CXMIN×SM_CYMIN` = 136x39):

```
hwnd=0x0       3440x1440 ovr=0   (screen pseudo-window)
hwnd=0x802c0    686x493  ovr=0   (BACK Notepad)
hwnd=0x402b4    686x493  ovr=0   (FRONT Notepad)
hwnd=0xb0080    686x493  ovr=0   (joint-motion owner)
hwnd=0x5019c   2566x1022 ovr=0   (jointmove Notepad)
hwnd=0x602ce    626x453  ovr=0   (chromerepro main)
hwnd=0x2026e    586x393  ovr=0   (occlusion BASE)
hwnd=0x80062    586x393  ovr=0   (pixel-test BASE)
hwnd=0x202d0    286x393  ovr=0   (occlusion COVER)
hwnd=0x302d0    300x400  ovr=0   (pixel-test COVER)
hwnd=0x501ce    229x196  ovr=1   (materialized menu, scenario 6a — above floor, correct)
```

Smallest announced window: 229x196. Nothing below the floor, no keytip-badge-shaped fragment,
exactly one `ovr=1` and it is the correctly-materialized menu.

Log health: 3 startup `VchanReceiveBuffer: no data, blocking read` warnings (normal) and 8
identical transient `GetWindowData: GetRealWindowRect failed 0x80070006 (invalid handle)` errors
— a window vanishing mid-enumeration. Pre-existing noise, unrelated to these fixes.

---

## What this run does NOT establish

1. **None of the five fixes was positively exercised on Win10.** Every one targets a Win11
   construct that does not occur here:
   * `a5012a5` fallback owner — the Win10 `#32768` menu has a real `GW_OWNER` (SYNTH record
     names `0x402b4` directly), so the same-process fallback picker was never entered.
   * `832ce97` overhang 4→12 — the menu (508,370 229x196) is fully inside its owner's buffer
     (506,320 686x493): overhang 0. The raised cap was never reached.
   * `d6ab61c` small-popup floor / `d610454` synthesize-or-drop — no sub-floor popup occurred
     (0 drop lines); the badge path was never entered. Only `d610454`'s *materialization* branch
     was exercised (scenario 6a), and it behaved correctly.
   * `3c12071` shell-overlay rejection — no Win10 window carries
     TRANSPARENT+NOREDIRECTIONBITMAP+TOOLWINDOW together, so the rejection never triggered. Only
     its *false-positive* direction was tested, and it was clean.

   The result is therefore **"no Win10 regression on b299011"**. It is not evidence the fixes do
   their job; that evidence is the `win11-idd-test` work.

2. **Two suite invariants could not judge this build** (`menu-announced`, `check-occlusion.py`
   under-clip). Both were adjudicated by other evidence. Both are tooling debt; until they are
   updated a future green run of the suite is worth less than it looks.

3. **No negative controls were run this session.** No build with any of these defects
   re-introduced was installed, so every PASS here is "the check did not fire", not "the check
   was shown able to fire on this build family".

4. **Nothing about cold boot, networking, work-area soak, or the drag perf bar** — Gate 2/Gate 3
   items, out of scope here. (Work-area churn and drag p50 were measured separately on this
   install and passed.)

5. **The maskpush finding is unquantified on real workloads.** Measured on a synthetic lockstep
   owner+child move only.

## Evidence files (all under `instrumentation/e2e-b299011/`)

| file | what |
|---|---|
| `gate0.ps1`, `gate0.raw` | install-identity probe (hash, `.orig`, testsigning, services, registry, log census) |
| `trace-on.ps1`/`.raw`, `trace-off.ps1`/`.raw`, `cleanup-verify.ps1` | registry knobs set and **restored**, with verification output |
| `w10-scn1.ps1`, `scn1.raw`, `scn1-trace.log`, `scn1-guest.json` | overlap+typing+held-menu scenario, trace and guest ground truth |
| `w10-scn2.ps1`, `scn2.raw`, `scn2-trace.log`, `scn2-guest.json` | menu close + SendInput title-bar drag |
| `menu-held-shot.tar` / `menu-held-shot/` | dom0 per-window PNGs with the File menu HELD (front: menu composited in-window; back: clean) |
| `menu-held-fullshot.tar` / `menu-held-full/` | dom0 full screen + `geometry.txt` (3 windows, no menu window, no phantom) |
| `occlusion-test.ps1`, `occlusion.raw` | `check-occlusion.py` input |
| `occl-pixel.ps1`, `occl-pixel-shot/`, `occl-pixel-full/`, `occl-pixel-analysis.txt` | pixel-level bleed adjudication + detector sensitivity control |
| `chromerepro-run.ps1`, `chromerepro.raw`, `chromerepro-shot/`, `chromerepro-full/` | 5/1 census, guest inventory, dom0 corroboration |
| `jointmove.ps1`, `jointmove.raw`, `jointmove-qgadrag.txt` | Win10 menu does not follow its owner; menu materialization |
| `jointmove2.ps1`, `jointmove2.raw`, `jointmove2-qgadrag.txt`, `agent-joint2.log` | genuine joint owner+child motion; the 58-maskpush finding |
| `agent-scn.log`, `agent-occl.log`, `agent-chrome.log`, `agent-joint2.log` | full LogLevel=4 agent logs (the grep corpus) |
| `pull-log.ps1`, `parse-raw.py` | log extraction (FileShare.ReadWrite) and transcript splitting |
| `post-restore-shot.tar` / `post-restore/`, `post-restore-full/` | seamless still working after the knobs were restored |
