# Edge ULW first-run check — clean install of the FIXED package (agent a459f0e)

Run 2026-08-02 03:09–03:17 on `win-idd-test` (Win10 22H2, clean MSI install of
`installer.msi f590c878…` / `gui-agent.exe 663d7e9b…`, netvm detached, LogLevel=3,
ProtoTrace off — neither knob was touched by this run).

**Verdict: PASS on all five acceptance points.**

**Loud caveat, not part of the acceptance:** ~5 minutes AFTER the last acceptance
evidence was collected, while running a purely cosmetic log-flush driver, the guest
entered the previously documented starvation/wedge state (qrexec dead, ~2.9 cores
burning). See "Post-test: guest wedged" below. Everything below the wedge line is
NEW information about that defect, not about Edge.

---

## Precondition: was this a true Edge first run?

Partly-qualified YES, stated precisely because it matters:

- `msedge.exe` present, version **92.0.902.67**; `Get-Process msedge` = 0 before the run.
- `%LOCALAPPDATA%\Microsoft\Edge\User Data` **did already exist**, 55 items, every one
  timestamped `2026-08-02T02:31:45…02:31:48` — a single burst during the install's first
  logon, i.e. materialized by Windows' Edge first-logon initialization, ~8 minutes before
  the earliest gui-agent log on this boot. No profile item has a later mtime.
- The Chromium **`First Run` sentinel was ABSENT** (`RESULT=FIRSTRUNSENTINEL:False`),
  which is what makes Edge show the first-run experience.
- Confirmed empirically: the FRE takeover really did appear (fullscreen ULW window
  `0x3041c`, and the dom0 screenshot shows the "Welcome to the new Microsoft Edge"
  carousel card). Edge's UI had never been shown on this install.

Edge was launched exactly once, for this check, and nothing else was launched first.

## Baseline (before launch)

```
RESULT=PRE_LOG:gui-agent-20260802-030352-6480.log|len=2623
RESULT=PRE_PID:6480
RESULT=PRE_LOGCOUNT:13
RESULT=T_LAUNCH:2026-08-02T03:11:07.6853571+00:00
RESULT=EDGE_PID:7612
```

Agent process: pid **6480**, started 03:03:52, log
`gui-agent-20260802-030352-6480.log`, 13 log files in `C:\Program Files\Qubes Tools\log`.

---

## (1) Agent alive with the SAME pid — PASS

| checkpoint | time | pid | newest log | log file count |
|---|---|---|---|---|
| before launch | 03:11:07 | 6480 (start 03:03:52.337) | gui-agent-20260802-030352-6480.log | 13 |
| after 60 s settle | 03:12:07 | 6480 (start 03:03:52.337) | same | 13 |
| after Edge close | 03:15:50 | 6480 (start 03:03:52.337) | same | 13 |
| final pull | 03:19 | 6480 (start 03:03:52.337) | same | 13 |

Same pid, identical process start time, no new log file, log count constant at 13 →
no crash, no watchdog respawn. The single agent log spans 03:03:52 → 03:15:28 with no
`LogInit` line after the first one.

## (2) Zero vchan-disconnect / daemon-kill signatures — PASS

Counted over the whole log (`agent-edge-firstrun.log`, 634 lines, covers the entire
Edge lifecycle from launch through close):

| signature | count |
|---|---|
| `vchan disconnect` / `disconnected` | **0** |
| `msg without CREATE` | 0 |
| `EnumWindows failed` | 0 |
| `keyed mutex` (0x887a0026) | 0 |
| `RecreateDuplication` | 0 |
| `Reinitialize` | 0 |
| `-W]` warnings | 1 (the benign `VchanReceiveBuffer … blocking read` at startup) |
| `-E]` errors | 25 — all one line, see below |

The only vchan lines in the log are the startup handshake:
```
[030352.504-I] WatchForEvents: A vchan client has connected
[030352.519-I] HandleVersion: gui daemon version: 0x10008
```
The daemon stayed alive: dom0 `local.WinFullScreen` continued to list the qube's
windows before, during and after the Edge session, and per-window screenshots kept
working — a daemon `exit(1)` (the failure mode of both fixed daemon-killers) would
have removed every window from dom0.

All 25 errors are the same benign line:
```
[…-E] GetWindowData: GetRealWindowRect failed with error 0x80070006: The handle is invalid.
```
`0x80070006` is `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)` returning
ERROR_INVALID_HANDLE (`main.c:703`) — the window died between enumeration and query.
`GetWindowData` propagates it and the window is simply skipped (`main.c:849-853`).
Zero of these occur in the 7.5 min of log before Edge starts and the first one lands
1.9 s after launch, so they are Edge-correlated (Chromium creates/destroys many
short-lived helper HWNDs), but they are a pre-existing benign race, not ULW-specific
and not a burst (max 4 within one millisecond, 25 in 4.5 min). Recommend demoting to
LogDebug — it is log noise, not a defect.

## (3) ULW handling — PASS

Guest-side window census 60 s after launch (`edge-step2.raw`):
```
0x3041c  pid=7612  0,0    3440x1400  style=0x96080080 ex=0x00080101 glwa=False Chrome_WidgetWin_1  (no title)
0x30430  pid=7612  -8,-8  3456x1416  style=0x1fcf0000 ex=0x00000100 glwa=False Chrome_WidgetWin_1  "New tab - Profile 1 - Microsoft Edge"
```
`0x3041c` is the FRE takeover: `WS_EX_LAYERED` (0x80000) with
`GetLayeredWindowAttributes` **failing** — exactly the ULW discriminator
`PwWindowEligible()` uses (`perwindow.c:205-238`).

Agent log, ULW path markers (naming note: in the shipped design the ULW fallback is
the **slice-fed per-window buffer**, which superseded the older "dropping to legacy
path" wording; `(slice-fed)` is the marker for that path):
```
[031110.193-I] PwAttachWindow: 0x3041c: per-window buffer 3440x1398 (4697 pages) attached (slice-fed)
[031110.193-I] SendWindowMap:  Mapping window 0x3041c
[031110.421-I] PwDetachWindow: 0x3041c: per-window buffer 3440x1398 detached (slice-fed)
[031110.437-I] PwAttachWindow: 0x3041c: per-window buffer 1705x1380 (2298 pages) attached (slice-fed)
[031110.482-I] PwDetachWindow: 0x3041c: per-window buffer 1705x1380 detached (slice-fed)
[031110.550-I] PwAttachWindow: 0x3041c: per-window buffer 3440x1400 (4704 pages) attached (slice-fed)
[031111.150-I] PwAttachWindow: 0x30430: per-window buffer 3440x1400 (4704 pages) attached      <- NOT slice-fed
[031111.150-I] SendWindowMap:  Mapping window 0x30430
```
- The ULW overlay was classified slice-fed **at attach**, so no runtime
  `became PrintWindow-ineligible …` transition was needed (that marker is for windows
  that acquire ULW after attach; correctly absent here).
- The ordinary Edge frame attached on the normal PrintWindow path — the ULW gate did
  not over-trigger.
- The main window attached ONCE at a **clamped 3440x1400** (raw rect is 3456x1416):
  the maximized-clamp fix is engaged and there is no attach/detach ping-pong (the
  pre-fix signature was ~3 reattach/s of a 4700-page grant).
- Three attach/detach cycles of `0x3041c` inside 360 ms are the overlay's own resize
  sequence (3440x1398 → 1705x1380 → 3440x1400) while Edge lays out the FRE; each is a
  clean paired rebuild, and it stops. Not an error burst.
- No ULW-related error line of any kind (`ineligible`, blank-capture, damage stall).

## (4) Edge window pixels — PASS

`tools/qtest shot` → `edge-shot.tar` → one PNG, `edge-shot/win-0.png`, 3440x1384
(the maximized Edge frame; the ULW overlay is override-redirect and is invisible to
`local.WinScreenshot` by design).

```
edge-main-window: size=(3440,1384) mean_rgb=(149.0,205.0,223.6) std=59.41
                  black_frac(<8)=0.000062  white_frac(>247)=0.026553  uniq_colors=280814
```
280 814 distinct colours, std 59.4, ~0.006 % black — not uniform. Visually
(`edge-mainwindow-dom0.png`): full new-tab page — tab strip, address bar, favourites
prompt, the lake wallpaper and the Edge logo, all crisp.

Because point (4) can only see the non-ULW window, the ULW surface was verified
separately with the whole-desktop capture `tools/qtest fullshot`
(`edge-fullshot.tar`), which DOES show override-redirect windows. dom0 geometry
during the FRE:
```
0x1c00188 0  0  3440 1440 0  VMapp command                       <- guest desktop window
0x1c0018b 0  31 3440 1400 1  ?                                   <- ULW FRE overlay (ovr=1)
0x1c0018d 5  56 3440 1400 0  New tab - Profile 1 - Microsoft      <- Edge main window
```
```
ULW-FRE-overlay crop: mean_rgb=(99.0,130.3,141.5) std=48.98
                      black_frac(<8)=0.000067  white_frac(>247)=0.051878 uniq_colors=93659
```
`edge-ulw-overlay-dom0.png` shows the "Welcome to the new Microsoft Edge" card with the
Edge logos and the *correctly blended, translucent* dimming backdrop through which the
new-tab page is visible. This is the direct refutation of the original defect
(PrintWindow on a ULW surface rendered this backdrop ~93 % opaque black). The 31 px
y-offset is the known, cosmetic dom0 `force_on_screen` padding for override-redirect
windows — content is window-relative, so nothing is misregistered.

## (5) Close → unmap, no CREATE/DESTROY imbalance — PASS

Close was a graceful `WM_CLOSE` to the main frame (not a force-kill):
```
RESULT=T_CLOSE_BEGIN:2026-08-02T03:15:27.93
RESULT=CLOSING:0x30430|pid=7612
RESULT=EDGE_PROCS_BEFORE:8
RESULT=EDGE_PROCS_AFTER_WMCLOSE:0     (no force kill needed)
```
Agent log, close sequence:
```
[031528.489-I] PwDetachWindow: 0x30430: per-window buffer 3440x1400 detached
[031528.489-I] SendWindowUnmap: Unmapping window 0x30430
[031528.548-I] PwDetachWindow: 0x3041c: per-window buffer 3440x1400 detached (slice-fed)
[031528.548-I] SendWindowUnmap: Unmapping window 0x3041c
```
dom0 after the close — `tools/qtest shot` returns a **0-byte tar** (no per-window
windows left) and `tools/qtest fullshot` geometry is:
```
# id x y w h override_redirect name
0x1c00188 0 0 3440 1440 0 VMapp command
```
Both Edge dom0 windows (`0x1c0018b` overlay, `0x1c0018d` main) are gone; only the
guest desktop window remains. No orphan, no stale override-redirect window.

Lifecycle balance over the whole session: `PwAttachWindow` 5 / `PwDetachWindow` 5
(3+1 for `0x3041c`'s resize rebuilds and 1 for `0x30430`), every mapped hwnd unmapped,
and `AddAllWindows: foreground -> … re-mapping to raise it` accounts for the 6 maps
vs 4 unmaps (raise re-sends MAP; it is idempotent).

**Caveat, stated because the acceptance says missing data must be declared:** raw
`SendWindowDestroy` / CREATE wire messages are **ProtoTrace-only** in this build, and
ProtoTrace was deliberately left off — enabling it needs an agent restart, which would
have destroyed acceptance point (1)'s same-pid requirement. The balance above is
therefore measured at the attach/detach + map/unmap level plus the dom0 window list.
This is adequate for the specific failure this check targets: an out-of-order
DESTROY/SHMIMAGE is *fatal* to gui-daemon (`xside.c:3951-3957` `exit(1)`), so the
daemon's continued life through and after the close, with dom0 correctly dropping
exactly the two Edge windows, is the observable proof that no such imbalance occurred.

---

## Post-test: guest wedged (NOT part of the acceptance — new data on a known defect)

Sequence:
- 03:15:50 — Edge closed, all five checks evidenced, guest healthy, qrexec fine.
- 03:17 — post-close `fullshot` OK.
- 03:19 — final log pull OK (qrexec fine).
- 03:20 — a **cosmetic** helper (`edge-step6-flush.ps1`: open Notepad, `SetWindowPos`
  it 200× at ~20 Hz, close it) was started to push the block-buffered agent log past
  its 64 KB boundary. It never returned; its `qubes.VMShell` was killed client-side at
  03:24:40.
- 03:24 onward — **qrexec is dead**, identical signature to the previous session's
  BLOCKED report:
  ```
  vchan_timeout.c:46:qubes_wait_for_vchan_connection_with_timeout: vchan connection timeout
  qrexec-agent-data.c:371:handle_data_client: Data vchan connection failed
  ```
  8 attempts 03:31–03:50, zero successes, each failing after the 120 s data-vchan timeout.
- Guest is `power_state=Running` and burning **2.90 cores** (admin.vm.CurrentState
  cputime delta over 30 s: 86 897 067 590 ns) — an idle guest is ~0.05 cores.
- `fullshot` at 03:42 still lists the qube's desktop window (`0x1c00188`), so the dom0
  daemon is alive; only the guest side is wedged.

Two things this adds to the existing record:
1. The wedge recurs on a **clean install of the fixed package with netvm detached
   the whole time** — so a netvm attach is *not* necessary to trigger it.
2. It was NOT triggered by Edge: 4 minutes and several successful qrexec round-trips
   separate Edge's exit from the onset. The trigger during this run was either the
   Notepad `SetWindowPos` storm or a spontaneous recurrence; this run cannot
   distinguish the two.

Recovery needs a VM restart, which this session is forbidden to perform. Nothing was
left open in the guest deliberately — Notepad from the flush helper may still be open
and was not confirmed closed (the script never reported back).

## Evidence files (all in this directory)

| file | what |
|---|---|
| `agent-edge-firstrun.log` | full gui-agent log, pid 6480, 03:03:52→03:15:28 (634 lines) |
| `edge-shot.tar`, `edge-shot/win-0.png` | qtest shot during FRE — Edge main window |
| `edge-mainwindow-dom0.png` | downscaled view of the above |
| `edge-fullshot.tar`, `edge-fullshot/{screen.png,geometry.txt}` | whole dom0 desktop during FRE (shows the ovr overlay) |
| `edge-ulw-overlay-dom0.png` | crop of the ULW FRE overlay as dom0 renders it |
| `edge-pixel-analysis.txt` | PIL/numpy variance stats for both |
| `edge-shot-after.tar` | 0-byte — no per-window windows after close |
| `edge-fullshot-after.tar` | post-close dom0 geometry (Edge windows gone) |
| `edge-fullshot-wedged.tar` | dom0 desktop at 03:42, guest wedged |
| `edge-step1.ps1`, `edge-step1b.ps1` | baseline + Edge-profile forensics |
| `edge-step2.ps1`, `edge-step2.raw` | launch + 60 s settle + window census |
| `edge-step3.ps1`, `edge-step3.raw` | log/registry pull (LogLevel=3, ProtoTrace unset) |
| `edge-step4-close.ps1` | graceful WM_CLOSE |
| `edge-step5-pull.ps1`, `edge-full.raw` | final log pull |
| `edge-step6-flush.ps1` | the log-flush helper that ran when the guest wedged |
