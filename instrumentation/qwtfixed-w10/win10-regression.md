# Win10 protocol/acceptance regression for the five win11-line fixes — RUN (2026-08-02 02:45–03:05)

Build under test: clean install of the FIXED package on `win-idd-test` (Win10 22H2,
10.0.19045.2965). `gui-agent.exe` SHA256 `663D7E9B…6DB4` (matches the manifest), zero
`*.orig` in `bin\`, testsigning Yes, `QdbDaemon/QrexecAgent/QubesGuiWatchdog` Running.
Agent submodule `a459f0e` = perwindow + `2c5dad2` + `d64bca6`, containing the five fixes
under test: `a5012a5` fallback owner, `832ce97` overhang 4→12, `d6ab61c` small-popup floor,
`3c12071` shell-overlay rejection, `d610454` synthesize-or-drop.

## Verdict: PASS — with two invariant adjudications stated in full below

Every acceptance condition the task defined was met on **non-empty** data:

| condition | result |
|---|---|
| protocol invariants hold on non-empty data | **yes** — 526 QGAPROTO records, all invariants hold (drag run); menu run holds on everything except the pre-known stale `menu-announced` |
| no legit-window rejections (`3c12071`) | **yes** — 0 rejection lines across 3 LogLevel=4 logs covering 10 distinct windows |
| no sub-floor announcements (`d610454`) | **yes** — 0 sub-floor drops, 0 announced windows below the floor; only 3 windows ever announced in the scenario run |
| chromerepro 5 / 1 | **yes** — `GUEST-COUNT=5`, `MAPPED-OF-OURS=1`, dom0 shows exactly 1 bordered window |

**But read the scope statement in "What this run does NOT establish" before quoting the
PASS.** This run proves the five win11-line fixes cause **no Win10 regression**. It does not
and cannot prove the fixes *work*, because none of the Win11 conditions they target exists on
Win10 — that evidence lives on `win11-idd-test`.

Two suite invariants fired and were adjudicated against stronger evidence rather than
papered over. One was pre-known (`menu-announced`); the second (`check-occlusion.py`
under-clip) is a **new** stale-invariant finding of this run and is reported as such, not as
a pass.

---

## Setup

`HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent`: `ProtoTrace`=1 (was **absent**),
`LogLevel`=4 (was 3). Agent restarted (`Stop-Process gui-agent`, watchdog respawn); a new log
file was confirmed each time (`RESULT=LOGAFTER`). **Restored at the end**: `ProtoTrace`
removed, `LogLevel`=3, agent restarted, verified `PROTORECS-AFTER 0` / `DEBUGLINES-AFTER 0`.
All test processes killed (`RESULT=PROCS 0`); a post-restore `qtest shot` still returns a live
Notepad window, so seamless survived the whole run.

`LogLevel=4` was verified **effective**, not assumed: the scenario log contains 1744 lines at
level `D`, including `GetRealWindowRect`, `HandleConfigure`, `DumpWindows`, `WorkAreaCreateListener`
and the `QGADRAG` markers. Both greps this task depends on (`main.c:1227` sub-floor,
`main.c:1976` shell-overlay) are `LogDebug` and were therefore emittable.

Work-area spam (`WorkAreaApply: guest work area set`, known defect, debounce in CI) was
filtered out of every analysis, per instruction.

---

## Scenario 1 — two overlapping Notepads, typing into the front one (occlusion invariant)

`instrumentation/qwtfixed-w10/w10-scn1.ps1`. BACK `0x30268` at (150,120) 700x500,
FRONT `0x2043e` at (500,320) 700x500 (overlaps BACK's lower-right). 40 keystroke bursts into
FRONT over 12.5 s.

QGAPROTO census inside the typing phase (`20260802.024948.019`–`.025000.566`):

```
type    76 recs  {'DAMAGE': 76}
        DAMAGE by hwnd: {0x2043e:76}      <- FRONT only
                                          <- BACK 0x30268: ZERO damage records
```

76 damage messages, every one to the front window, none to the occluded one. The data is
non-empty and the invariant is satisfied on it.

dom0 pixel confirmation (`menu-held-shot.tar`, captured while both windows were up): the BACK
Notepad's PNG is completely clean — no text from the front window, no menu fragments, no
debris anywhere in the region the front window covers.

## Scenario 2 — Notepad File menu opened and HELD

Same run. Menu `0x50230` at (508,370) 229x196, held ~6 s with 6 hover steps, and left open
while dom0 was photographed.

The menu was **never announced** and **never mapped**. It was synthesized:

```
QGAPROTO,msg=SYNTH,hwnd=0x50230,owner=0x2043e,x=508,y=370,w=229,h=196
QGAPROTO,msg=SYNTHPAINT,hwnd=0x50230,owner=0x2043e,...   x13
```

`0x2043e` is the FRONT Notepad — the menu's real owner, so `a5012a5`'s owner selection picked
correctly (via the ordinary `GW_OWNER` path; see scope note).

dom0 while held (`menu-held-fullshot.tar/geometry.txt`) lists exactly three windows for the
qube: the desktop pseudo-window plus the two Notepads. **No separate menu window, no phantom
window, no bordered fragment.** The front Notepad's PNG shows the File menu drawn correctly
inside the window, unbordered, with the typed text intact around it — host uncorrupted.

### Adjudication 1 — `check-protocol.py` `menu-announced` (pre-known, per task instruction)

```
$ python3 tools/check-protocol.py scn1-trace.log scn1-guest.json
records=150 guest_windows=9
  CONFIGURE=6 CREATE=3 DAMAGE=123 MAP=4 SYNTH=1 SYNTHPAINT=13
FAILED 1 invariant check(s):
  [menu-announced] menu hwnd=0x50230 was visible in the guest but never mapped
```

**This is the correctly-synthesized menu, not a defect.** The invariant counts only `MAP` as
"announced" and predates composite synthesis. Judged on the `QGAPROTO msg=SYNTH` record as
instructed: `0x50230` has a SYNTH record naming its true owner, 13 SYNTHPAINTs, and dom0
carries no separate window for it while rendering it correctly inside its owner. Stating it
explicitly, as required: **this failure is the synthesis path working.** The checker needs a
`SYNTH`-aware clause; that is a tooling fix, not an agent fix.

Every other invariant in that run holds: `popup-override-redirect`, `damage-within-window`,
`no-damage-to-occluded-window`, `origin-known-for-damaged-windows`,
`geometry-matches-visible-window`, `origin-matches-visible-window`.

## Scenario 3 — drag (damage-within-geometry, origin-known)

`w10-scn2.ps1`: menu closed, then the front Notepad dragged by its title bar with synthetic
`SendInput` in a circle, radius 180 px, **316 moves in 10.22 s**.

```
$ python3 tools/check-protocol.py scn2-trace.log scn2-guest.json
records=526 guest_windows=8
  CONFIGURE=374 CREATE=3 DAMAGE=131 MAP=4 SYNTH=1 SYNTHPAINT=13

all invariants hold
```

Non-empty, and specifically non-empty *inside the drag phase*
(`20260802.025238.677`–`.025249.207`):

```
drag   374 recs  {'CONFIGURE': 368, 'DAMAGE': 6}
       CONFIGURE by hwnd: {0x2043e:368}
       DAMAGE    by hwnd: {0x2043e:6}
```

368 CONFIGUREs (motion tracked at input rate) and 6 DAMAGE records — so
`damage-within-window` and `origin-known-for-damaged-windows` had data to judge during the
drag, and passed. The 368-CONFIGURE/6-DAMAGE ratio is `d64bca6`'s move-only recapture
suppression engaging: `QGADRAG,ev=suppress` ×153, `ev=refresh` ×59, `ev=settle` ×2.

Geometry ground truth agreed exactly (announced = DWM extended frame bounds, not
`GetWindowRect`):

| hwnd | announced (last CONFIGURE) | guest `GetWindowRect` | guest DWM extended |
|---|---|---|---|
| `0x30268` | (157,120) 686x493 | (150,120) 700x500 | **(157,120) 686x493** |
| `0x2043e` | (506,312) 686x493 | (499,312) 700x500 | **(506,312) 686x493** |

Incidental (Gate 2 territory, recorded because it was in the same log):
`QGADRAG,ev=maskpush` occurred exactly twice — at menu open (`025003.738`) and menu close
(`025233.535`), i.e. **outside** the drag window entirely.

## Scenario 4 — `tools/viewcheck/occlusion-test.ps1` + `check-occlusion.py`

```
$ python3 tools/check-occlusion.py occlusion.raw
base=0x303e6 cover=0x30458
  phase visible: 5 damage rect(s), 5 reaching past x=300
  phase hidden : 6 damage rect(s), 6 reaching past x=300
FAIL [under-clip] BASE was sent damage at rx=0 w=586 (reaches 586) while COVER is on top
occlusion clipping is WRONG
```

### Adjudication 2 — NEW finding: `check-occlusion.py` is stale for per-window capture

This invariant belongs to the **legacy screen-slice** path. In that path the framebuffer is
the composited desktop, so an unclipped dirty rect really does hand COVER's pixels to BASE.
On this build BASE and COVER each own a per-window buffer, which the agent's own log states:

```
PwInit: per-window capture ENABLED
PwAttachWindow: 0x303e6: per-window buffer 586x393 (225 pages) attached   [BASE,  025717.566]
PwAttachWindow: 0x30458: per-window buffer 286x393 (110 pages) attached   [COVER, 025717.707]
PwDetachWindow: 0x30458 ... 025728.035    PwDetachWindow: 0x303e6 ... 025735.410
```

Both attaches precede the first damage record (`025717.613`) and both detaches follow the
last, so BASE was per-window-fed for **both** phases. Its damage rects are `rx=0,ry=0,586x393`
(the whole buffer) and `rx=0,ry=31,586x361` (client area) — the window's own geometry, not an
intersection with a screen dirty rect. Under `main.c` the PW branch `continue`s before the
`rgnCovered` clipping code by design; clipping is retained only so LEGACY-path windows beneath
are still clipped.

So the checker's literal criterion cannot be satisfied by a PW-attached window, and its
failure here says nothing about the build. The criterion that survives the architecture change
is: **BASE's dom0 pixmap must contain none of COVER's pixels.** Measured directly
(`occl-pixel.ps1`, `occl-pixel-shot.tar`, `occl-pixel-analysis.txt`) with BASE white and COVER
pure red, captured while overlapping:

```
BASE red-ish pixels, whole window : 5 / 230298
BASE red-ish pixels, x>=300       : 0     <-- bleed criterion
COVER's own PNG                   : 102524 red pixels (91.22%)
```

Zero bleed. The 5 stray red-ish pixels are in BASE's own title-bar chrome, outside the overlap
columns.

**Honesty markers on this adjudication:**
* The pixel check has an *instrument-sensitivity* control (the same detector finds 91% red in
  COVER's PNG), but **no defect-injection control** — no build with the bleed re-introduced was
  run in this session. Per the standing rule its PASS is recorded as **unproven by negative
  control**, not counted as hard evidence.
* `check-occlusion.py`'s own documented negative controls (`0eabb2b8a0fc`, `5598a2fbda93`) were
  taken on screen-slice builds. Its discriminating power on a per-window build is **not**
  established, in either direction. It needs a PW-aware rewrite before its result counts
  again — same class of problem as `menu-announced`, and it is listed in ACCEPTANCE-PROTOCOL.md
  as a proven check, which is now only true for legacy-path windows.

## Scenario 5 — chromerepro (2A-chrome)

`artifacts/chromerepro.exe` SHA256 `4f64d30a…9e3d2`, pushed and run on a fresh agent log.

```
RESULT=GUEST-COUNT 5
RESULT=MAPPED-OF-OURS 1
RESULT=MAPPED-HWNDS 0x603ee
```

Guest-side inventory (`%TEMP%\chromerepro.txt`): main `0x603EE`
(`QubesChromeReproMain`, style `0x14CF0000`) + shadow0..3 `QubesChromeReproShadow`
(style `0x94000000`, exstyle `0x080800A0` = LAYERED|TRANSPARENT|TOOLWINDOW|NOACTIVATE,
alpha 160, owned by main, 160 px thick vs `SM_CXMIN=136 SM_CYMIN=39`) — i.e. all four strips
are **above** the size floor, so they had to be rejected by the chrome predicate, not by the
size filter.

Agent's own `SendWindowMap` census: only `0x603ee` was ever mapped. dom0 agrees —
`chromerepro-shot.tar` contains exactly one PNG and `geometry.txt` lists one chromerepro
window (`1419 495 626 453 chromerepro - main window`). **5 guest windows → 1 dom0 window.**

Note on method: counting screenshot PNGs alone would be unsound (`import -window` fails
silently on layered/transparent windows — the documented false-PASS mechanism). The count
above comes from the agent's `SendWindowMap` lines; the dom0 shot is corroboration only.

Note on log level: the `rejecting compound-window chrome` line is `LogVerbose` (level 5), so
it is absent at LogLevel=4. That absence is expected and is **not** evidence either way; the
`MAPPED-OF-OURS=1` census is what carries the result.

## Scenario 6/7 — the two grep-based regression checks

Across all three LogLevel=4 logs pulled (`agent-scn.log` 337808 B, `agent-occl.log` 44778 B,
`agent-chrome.log` 27003 B), covering the desktop window, 2 Notepads, a `#32768` menu, 2
WinForms windows, and chromerepro's main + 4 shadow strips:

| grep | source | hits |
|---|---|---|
| `click-through uncapturable shell overlay ... rejecting` (`3c12071`, main.c:1976, LogDebug) | 3 logs | **0** |
| `sub-floor popup ... dropping silently` (`d610454`, main.c:1227, LogDebug) | 3 logs | **0** |

**No legitimate window was rejected.** The chromerepro strips are the sharpest test available
here: exstyle `0x080800A0` carries TRANSPARENT and TOOLWINDOW but **not**
`WS_EX_NOREDIRECTIONBITMAP` (`0x00200000`), so `3c12071`'s three-bit conjunction correctly did
not fire on them — they were dropped by the older, narrower 2A-chrome rule instead. That is
the intended narrowness of `3c12071` demonstrated on real windows.

**No sub-floor fragment was announced.** The complete set of windows announced in the whole
scenario run is three:

```
CREATE hwnd=0x0      3440x1440         (screen pseudo-window)
CREATE hwnd=0x30268  686x493  ovr=0    (BACK Notepad)
CREATE hwnd=0x2043e  686x493  ovr=0    (FRONT Notepad)
```

Nothing below `SM_CXMIN×SM_CYMIN` (136x39), nothing with `ovr=1`, no keytip-badge-shaped
fragments. The chromerepro run announced exactly one window (`0x603ee`, 626x453).

Log health: 1 warning (`VchanReceiveBuffer: no data, blocking read`, normal startup) and 3
errors, all the same transient `GetWindowData: GetRealWindowRect failed 0x80070006 (invalid
handle)` — a window vanishing mid-enumeration. Pre-existing noise, not related to these fixes.

---

## What this run does NOT establish

Stated plainly, because the PASS above is narrower than it looks:

1. **None of the five fixes was positively exercised on Win10.** Every one targets a Win11
   construct that does not occur here:
   * `a5012a5` fallback owner — the Win10 `#32768` menu has a real `GW_OWNER`, so the
     same-process fallback picker was never entered. Only the ordinary owner path was proven.
   * `832ce97` overhang 4→12 — the Win10 menu (508,370 229x196) is fully inside its owner's
     buffer (506,312 686x493): overhang 0. The raised cap was never reached.
   * `d6ab61c` small-popup floor / `d610454` synthesize-or-drop — no sub-floor popup occurred
     (0 drop lines); the badge path was never entered.
   * `3c12071` shell-overlay rejection — no Win10 window carries
     TRANSPARENT+NOREDIRECTIONBITMAP+TOOLWINDOW together, so the rejection was never
     triggered. Only its *false-positive* direction was tested, and it was clean.

   The result is therefore **"no Win10 regression"**, which is what this task asked for. It is
   not evidence the fixes do their job; that evidence is the win11-idd-test work.

2. **Two suite invariants could not judge this build** (`menu-announced`,
   `check-occlusion.py` under-clip). Both were adjudicated by other evidence. Both are tooling
   debt; until they are updated, a future green run of the suite is worth less than it looks.

3. **No negative controls were run this session.** No build with any of these defects
   re-introduced was installed, so every PASS here is "the check did not fire", not "the check
   was shown able to fire on this build family". The pixel-bleed check in particular is new
   and unproven in that sense.

4. **Nothing about cold boot, networking, work-area soak, or the drag perf bar** — those are
   Gate 2/Gate 3 items, out of scope here.

## Evidence files (all under `instrumentation/qwtfixed-w10/`)

| file | what |
|---|---|
| `gate0.ps1` | install-identity probe (hash, .orig, testsigning, services, registry, log census) |
| `trace-on.ps1` / `trace-off.ps1` | registry knobs set and **restored**, with verification output |
| `w10-scn1.ps1`, `scn1.raw`, `scn1-trace.log`, `scn1-guest.json` | overlap+typing+held-menu scenario, trace and guest ground truth |
| `w10-scn2.ps1`, `scn2.raw`, `scn2-trace.log`, `scn2-guest.json` | menu close + SendInput title-bar drag |
| `menu-held-shot.tar` | dom0 per-window PNGs with the File menu HELD (front: menu composited in-window; back: clean) |
| `menu-held-fullshot.tar` | dom0 full screen + `geometry.txt` (3 windows, no menu window, no phantom) |
| `occlusion.raw` | `occlusion-test.ps1` transcript (input to `check-occlusion.py`) |
| `occl-pixel.ps1`, `occl-pixel-shot.tar`, `occl-pixel-analysis.txt` | the pixel-level bleed adjudication |
| `chromerepro-run.ps1`, `chromerepro.raw`, `chromerepro-shot.tar` | 5/1 census, guest inventory, dom0 corroboration |
| `agent-scn.log`, `agent-occl.log`, `agent-chrome.log` | full LogLevel=4 agent logs (the grep corpus) |
| `pull-log.ps1`, `parse-raw.py` | log extraction (FileShare.ReadWrite — `File::ReadAllBytes` fails silently against the live writer) and transcript splitting |
| `post-restore-shot.tar` | seamless still working after the knobs were restored |
