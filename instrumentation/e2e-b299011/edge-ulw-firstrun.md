# Edge ULW first-run check — clean install of package b299011

Run 2026-08-02 15:38–15:47 (guest clock) on `win-idd-test`: Win10 22H2, wiped-disk clean
MSI install at 14:34 of `installer.msi fa774936…` / `gui-agent.exe 4b4ce2b1…` (agent
commit `b299011`, zero `.orig` overlays), `netvm = core-net` (unchanged by this run).
`LogLevel=3`, `ProtoTrace` unset — **neither knob was touched**, verified before and after.

**Verdict: PASS on all five acceptance points.**

The guest stayed reachable throughout and after (unlike the 2026-08-02 03:xx run on the
previous package, which wedged ~5 min after its acceptance evidence). No wedge observed
here up to the last probe at 15:47.

---

## Precondition: was this a true Edge first run?

Yes, on the strongest evidence available:

- `msedge.exe` present, version **92.0.902.67**; `Get-Process msedge` = **0** before the run.
- `%LOCALAPPDATA%\Microsoft\Edge\User Data` existed with 61 items, **every single one**
  timestamped `2026-08-02T14:35:03…14:35:08` — one burst during the install's first logon,
  ~3.5 min after the OS install. **No item has a later mtime**, so nothing had ever run
  Edge's UI on this install.
- The Chromium **`First Run` sentinel was ABSENT** before launch
  (`RESULT=FIRSTRUNSENTINEL:False`) — that absence is what makes Edge show the FRE.
- Confirmed empirically: the fullscreen FRE takeover window really appeared (`0xe0290`,
  `WS_EX_LAYERED` + `GetLayeredWindowAttributes` failing) and dom0 shows the
  "Try Collections" first-run carousel card.
- Edge was launched exactly once, for this check; nothing else was launched first.

Honest note: re-checking the sentinel after the run still reported `False` (Edge writes it
at a point this short session did not reach). The precondition therefore rests on the
profile mtimes + the FRE actually being displayed, not on the sentinel flipping.

## Baseline (before launch)

```
RESULT=PRE_LOG:gui-agent-20260802-153022-1976.log|len=2622
RESULT=PRE_PID:1976
RESULT=PRE_LOGCOUNT:16
RESULT=T_LAUNCH:2026-08-02T15:38:52.9315700+00:00
RESULT=EDGE_PID:4688
```
Agent pid **1976**, process start 15:30:22.667, its log
`gui-agent-20260802-153022-1976.log`, 16 log files in `C:\Program Files\Qubes Tools\log`.
Pre-existing guest windows at baseline: Microsoft Store (`ApplicationFrameWindow`,
left over from an earlier session — not opened by this run) and the shell.

---

## (1) Agent alive with the SAME pid — PASS

| checkpoint | guest time | agent pid (start) | newest log | log-file count |
|---|---|---|---|---|
| before launch      | 15:38:52 | 1976 (15:30:22.667) | gui-agent-20260802-153022-1976.log | 16 |
| after 60 s settle  | 15:39:53 | 1976 (15:30:22.667) | same | 16 |
| mid-run log pull   | 15:42:31 | 1976 | same | 16 |
| after Edge close   | 15:43:54 | 1976 (15:30:22.667) | same | 16 |
| final pull         | 15:45    | 1976 (15:30:22.667) | same | 16 |
| final health probe | 15:47    | 1976 | — | — |

Identical pid **and** identical process start time at every checkpoint, no new log file,
log count constant at 16 → no crash and no watchdog respawn. The log contains exactly one
`LogInit` banner (6 lines, all at 15:30:22.695) and no later one.
Services at the end: `QdbDaemon=Running; QrexecAgent=Running; QubesGuiWatchdog=Running`.

## (2) Zero vchan-disconnect / daemon-kill signatures — PASS

Counted over the whole log (`agent-edge-firstrun.log`, 1430 lines, 15:30:22 → 15:43:32,
covering the entire Edge lifecycle from launch to close):

| signature | count |
|---|---|
| `vchan disconnect` / `disconnected` | **0** |
| `msg without CREATE` | 0 |
| `keyed mutex` (0x887a0026) | 0 |
| `RecreateDuplication` | 0 |
| `Reinitialize` | 0 |
| `EnumWindows failed` | 0 |
| `-W]` warnings | 1 (benign `VchanReceiveBuffer … no data, blocking read` at startup) |
| `-E]` errors | 43, all the same line (below) |

The only vchan lines are the startup handshake
(`WatchForEvents: A vchan client has connected`). The daemon stayed alive independently
of the log: `tools/qtest fullshot` listed the qube's windows before, during and after the
Edge session — a gui-daemon `exit(1)` (the failure mode of both fixed daemon-killers)
removes every window of the qube from dom0.

All 43 errors are one benign, pre-existing line:
```
[…-E] GetWindowData: GetRealWindowRect failed with error 0x80070006: The handle is invalid.
```
`DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)` returning ERROR_INVALID_HANDLE for a
window that died between enumeration and query; `GetWindowData` propagates and the window
is skipped. **6 of the 43 occurred before Edge was launched**, so it is not Edge- or
ULW-specific; it is not a burst (max 4 in one millisecond, max 7 in one second, spread over
13 min). Still worth demoting to `LogDebug` — noise, not a defect.

## (3) ULW handled — PASS

Guest-side census 60 s after launch (`edge-step2.raw`):
```
0xe0290  pid=4688  0,31   1705x1380  style=0x96080080 ex=0x00080101 glwa=False Chrome_WidgetWin_1  (no title)
0x501bc  pid=4688  -8,-8  3456x1416  style=0x1fcf0000 ex=0x00000100 glwa=False Chrome_WidgetWin_1  "New tab - Profile 1 - Microsoft Edge"
```
`0xe0290` is the FRE takeover: `WS_EX_LAYERED` (0x80000) with `GetLayeredWindowAttributes`
**failing** — exactly the ULW discriminator `PwWindowEligible()` uses
(`agent/gui-agent/perwindow.c`).

Agent-log ULW markers (in this design the ULW fallback IS the **slice-fed per-window
buffer**, which superseded the older "dropping to legacy path" wording; `(slice-fed)` is
that path's marker):
```
[153855.125-I] PwAttachWindow: 0xe0290: per-window buffer 3440x1398 (4697 pages) attached (slice-fed)
[153855.125-I] SendWindowMap:  Mapping window 0xe0290
[153855.382-I] PwDetachWindow: 0xe0290: per-window buffer 3440x1398 detached (slice-fed)
[153855.399-I] PwAttachWindow: 0xe0290: per-window buffer 1705x1380 (2298 pages) attached (slice-fed)
[153855.413-I] PwDetachWindow: 0xe0290: per-window buffer 1705x1380 detached (slice-fed)
[153855.445-I] PwAttachWindow: 0xe0290: per-window buffer 3440x1400 (4704 pages) attached (slice-fed)
[153855.491-I] PwDetachWindow: 0xe0290: per-window buffer 3440x1400 detached (slice-fed)
[153855.507-I] PwAttachWindow: 0xe0290: per-window buffer 1705x1380 (2298 pages) attached (slice-fed)
[153909.834-I] PwAttachWindow: 0x501bc: per-window buffer 3440x1400 (4704 pages) attached   <- NOT slice-fed
[153909.834-I] SendWindowMap:  Mapping window 0x501bc
```
- The ULW overlay was classified **slice-fed at attach**, so no runtime
  `became PrintWindow-ineligible (layered), rebuilding slice-fed` transition was needed —
  that marker is for windows that acquire ULW *after* attach and is correctly absent here.
- The ordinary Edge frame attached on the normal PrintWindow path: the ULW gate did not
  over-trigger.
- The main window attached **once**, at a **clamped 3440x1400** (raw rect 3456x1416) — the
  maximized clamp is engaged, no attach/detach ping-pong (pre-fix signature was ~3
  reattach/s of a 4700-page grant). Its attach stayed static for the following 4.5 min.
- The overlay's four attach/detach pairs all fall inside 382 ms (3440x1398 → 1705x1380 →
  3440x1400 → 1705x1380) — Edge's own FRE layout/resize sequence, each a clean paired
  rebuild, and it then stops for the rest of the session. Not an error burst.
- **No ULW error burst of any kind**: 12 log lines mention `0xe0290` in total, all
  attach/detach/map; zero `WcAddWindow` / `WcPrefill` failures, zero blank-capture or
  damage-stall lines, zero errors naming the overlay.

## (4) Edge window pixels — PASS

`tools/qtest shot` → `edge-shot.tar` → one PNG `edge-shot/win-0.png`, 3440x1384 (the
maximized Edge frame; the ULW overlay is override-redirect and is invisible to
`local.WinScreenshot` by design).

```
edge-main-window: size=(3440,1384) mean_rgb=(87.8,86.5,83.2) std=82.24
                  black_frac(<8)=0.047583 white_frac(>247)=0.127639 uniq_colors=112106
```
112 106 distinct colours, std 82.2, ~4.8 % black, ~12.8 % white — nowhere near uniform.
Visually (`edge-mainwindow-dom0.png`): the complete new-tab page — tab strip, address bar,
favourites prompt, mountain wallpaper, search box, quick links, the MSN feed and the
privacy-consent banner, all crisp.

Because point (4) can only see the non-ULW window, the ULW surface itself was verified with
the whole-desktop capture **`tools/qtest fullshot`** (stated explicitly, per the note that
`local.WinScreenshot` cannot capture override-redirect windows). dom0 geometry during the
FRE (`edge-fullshot/geometry.txt`):
```
0x1c00188 0  0  3440 1440 0  VMapp command                    <- guest desktop window
0x1c0018b 0  31 1705 1380 1  ?                                <- ULW FRE overlay (ovr=1)
0x1c0018d 5  56 3440 1400 0  New tab - Profile 1 - Microsoft   <- Edge main window
```
```
ULW-FRE-overlay crop: mean_rgb=(83.5,82.3,80.4) std=81.34
                      black_frac(<8)=0.088 white_frac(>247)=0.089 uniq_colors=25668
```
`edge-ulw-overlay-dom0.png` shows the "Try Collections" first-run card over a **correctly
blended, translucent dimming backdrop** through which the new-tab page (wallpaper, MSN
feed, privacy banner) is plainly visible. That is the direct refutation of the original
defect, where PrintWindow on a ULW surface produced a ~93 %-opaque black backdrop. The 1 px
red edge is the by-design override-redirect border; the 31 px y-offset is the known
cosmetic dom0 `force_on_screen` padding (content is window-relative, nothing misregisters).

## (5) Close → unmap, balanced attach/detach — PASS

Graceful `WM_CLOSE` to the main frame, no force kill:
```
RESULT=T_CLOSE_BEGIN:2026-08-02T15:43:31.23
RESULT=EDGE_PROCS_BEFORE:8
RESULT=CLOSING:0x501bc|pid=4688
RESULT=EDGE_PROCS_AFTER_WMCLOSE:0
RESULT=EDGE_PROCS_FINAL:0
```
Agent log, close sequence:
```
[154332.179-I] PwDetachWindow: 0x501bc: per-window buffer 3440x1400 detached
[154332.179-I] SendWindowUnmap: Unmapping window 0x501bc
[154332.192-I] PwDetachWindow: 0xe0290: per-window buffer 1705x1380 detached (slice-fed)
[154332.192-I] SendWindowUnmap: Unmapping window 0xe0290
```
Whole-session balance: **`PwAttachWindow` 6 / `PwDetachWindow` 6**, per hwnd
(`0xe0292` pre-Edge 1/1, `0xe0290` 4/4, `0x501bc` 1/1). Maps 6 / unmaps 4: the three
distinct mapped hwnds were each mapped twice (`AddAllWindows: foreground -> …, re-mapping
to raise it in dom0` — idempotent re-MAP on raise) and each was unmapped once, plus the
screen window's startup unmap of window `0x0`. No hwnd was left mapped.

dom0 after the close:
- `tools/qtest shot` → **0-byte tar** (no per-window windows left);
- `tools/qtest fullshot` geometry:
```
# id x y w h override_redirect name
0x1c00188 0 0 3440 1440 0 VMapp command
```
Both Edge dom0 windows (`0x1c0018b` overlay, `0x1c0018d` main) are gone; only the guest
desktop window remains. No orphan, no stale override-redirect window.

**Caveat, stated because missing data must be declared:** raw `SendWindowCreate` /
`SendWindowDestroy` wire records are **ProtoTrace-only** in this build, and ProtoTrace was
deliberately left off — turning it on requires an agent restart, which would have destroyed
acceptance point (1). The balance above is therefore measured at the attach/detach +
map/unmap level plus the dom0 window list. That is adequate for the failure this check
targets: an out-of-order DESTROY/SHMIMAGE is *fatal* to gui-daemon
(`xside.c:3951-3957 exit(1)`), so the daemon's continued life through and after the close,
with dom0 dropping exactly the two Edge windows, is the observable proof that no such
imbalance occurred.

---

## Guest state left behind

- Edge fully closed (0 processes), both its dom0 windows unmapped.
- A **Microsoft Store** window that pre-dates this run (from an earlier session) is still
  open; it was not opened here and was left untouched. It is not mapped in dom0.
- No registry knob changed: `LogLevel=3`, `ProtoTrace` absent (verified after the run).
- Agent still pid 1976; qrexec responsive at the last probe (15:47).

## Evidence files (all in `instrumentation/e2e-b299011/`)

| file | what |
|---|---|
| `agent-edge-firstrun.log` | full gui-agent log, pid 1976, 15:30:22 → 15:43:32 (1430 lines) |
| `agent-edge-firstrun-mid.log` | same log pulled mid-run (1165 lines), before the close |
| `edge-step1.ps1` / `.raw` | baseline: logs, pid, Edge presence, window census |
| `edge-step1b.ps1` / `.raw` | Edge-profile forensics (mtimes, First Run sentinel) |
| `edge-step2.ps1` / `.raw` | launch + 60 s settle + window census |
| `edge-step3.ps1` / `.raw` | mid-run log + registry dump (LogLevel/ProtoTrace) |
| `edge-step4-close.ps1` / `edge-step4.raw` | graceful WM_CLOSE + post-close state |
| `edge-step5-pull.ps1` / `edge-full.raw` | final log pull |
| `edge-final-health.raw` | final pid/services/registry probe |
| `edge-shot.tar`, `edge-shot/win-0.png` | `qtest shot` during the FRE — Edge main window |
| `edge-mainwindow-dom0.png` | downscaled view of the above |
| `edge-fullshot.tar`, `edge-fullshot/{screen.png,geometry.txt}` | `qtest fullshot` during the FRE (shows the ovr overlay) |
| `edge-ulw-overlay-dom0.png`, `edge-ulw-overlay-dom0-full.png` | crop of the ULW FRE overlay as dom0 renders it |
| `edge-pixel-analysis.txt` | PIL/numpy variance stats for both captures |
| `edge-shot-after.tar` | 0 bytes — no per-window windows after close |
| `edge-fullshot-after.tar` | post-close dom0 geometry (Edge windows gone) |
