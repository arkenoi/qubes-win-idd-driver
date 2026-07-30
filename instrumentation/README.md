# Phase 1A.2 — gui-agent per-frame instrumentation

Design + patch for the measurement step that decides Phase 2A's scope: **does window
tracking/enumeration dominate the seamless frame, or does repaint/dirty-rect volume?**

| file | what it is |
|---|---|
| `phase1a-timing.patch` | unified diff against the `agent/` submodule (a fork of `QubesOS/qubes-gui-agent-windows`) |
| `drag-harness.ps1` | scripted drag / scroll / typing workload, run via `tools/qtest pushrun` |
| `analyze-perf.py` | turns the agent log into the decision table |

Nothing here has been applied to `agent/` or built yet — this session owns only
`instrumentation/`. The patch is verified to apply cleanly (`git apply --check` and
`patch -p1 --dry-run`) against `agent/` at commit `431e451` ("Don't use local .artifacts dir").

```
cd agent && git checkout -b phase1a-instrumentation && git apply ../instrumentation/phase1a-timing.patch
```

---

## 1. What the patch touches, and why there

Line numbers are from the pre-patch tree.

| location | what it is in the stock agent | what the patch adds |
|---|---|---|
| `gui-agent/capture.c:342` `GetFrame()` | `AcquireNextFrame` + first-frame grant + `GetFrameDirtyRects` | QPC around `AcquireNextFrame` (`acq`) and around the dirty-rect size-query/fetch/malloc pair at `capture.c:404-431` (`drq`); dirty-area sum computed *outside* the timed region |
| `gui-agent/capture.c:441` | `// TODO: GetFrameMoveRects (they seem to always be empty when testing)` — the real line is **441**, as CLAUDE.md says | a measurement-only `GetFrameMoveRects` into a 64-entry stack buffer, placed *before* the dirty-rect block because MSDN requires move rects be processed first. Never used to produce output. Reports `mr`, running max `mrmax`, and logs the first non-empty result loudly |
| `gui-agent/capture.c:550` `CaptureThread` | drops frames with `dirty_rects_count == 0` | counts them (`skip`) and stamps QPC right before `SetEvent(frame_event)` so the main loop can measure its own wakeup latency (`wak`) |
| `gui-agent/main.c:1013` `ProcessNewFrame()` | the whole seamless per-frame path | brackets the four phases (see below) and emits one record |
| `gui-agent/main.c:1045` | `// TODO: don't enumerate all windows every time, use window hooks…` | the `enu` bracket starts right after it; `AddAllWindows()` at `main.c:601` is the `EnumWindows(AddWindowsProc, 0)` call at `main.c:610` |
| `gui-agent/main.c:1020-1041` | fullscreen (non-seamless) early-return path | also instrumented, `mode=f` |
| `gui-agent/vchan.c` / `vchan.h:43` | `VCHAN_SEND` → `VchanSendBuffer`, `VCHAN_SEND_MSG` → `VchanSendMessage` | both now route through one new `VchanSendTimed()`, which is the *only* place send cost is measured. Covers every hot-path message: `MSG_SHMIMAGE` (`send.c:404`), `MSG_CONFIGURE` (`send.c:375`), `MSG_MAP`, `MSG_WINDOW_FLAGS`, `MSG_WMNAME`, and the raw `MSG_UNMAP`/`MSG_DESTROY` used by `ToggleMap`/`RemoveWindow` |
| `gui-agent/main.c:1260` | `DumpWindows()` runs once a second **at any log level** | gated on `LogGetLevel() >= LOG_LEVEL_DEBUG`. See §6 — separable hunk |
| `gui-agent/perf.{c,h}` (new), `vs2022/gui-agent/gui-agent.vcxproj(.filters)` | — | the instrumentation itself + project file entries |

### The phase split

`(a)` window enumeration/tracking, `(b)` dirty-rect extraction, `(c)` message send —
required by CLAUDE.md 1A.2 — map onto the emitted fields as:

```
(a) tracking  = upd + enu + rem     upd: UpdateWindowData() over the watched list (main.c:1049-1063)
                                    enu: AddAllWindows() -> EnumWindows           (main.c:1066)
                                    rem: DeletePending removal loop               (main.c:1069-1086)
(b) damage    = drq + dmg           drq: GetFrameDirtyRects in the capture thread (capture.c:404-431)
                                    dmg: IntersectRect loop over windows x rects  (main.c:1089-1127)
(c) send      = snd                 all time inside VchanSendTimed during the frame
```

Send time is **subtracted out of each phase**, so `upd`/`enu`/`rem`/`dmg` are pure
compute/USER32 cost and `snd` is pure transport cost. Without that subtraction, `upd`
would silently include the `MSG_CONFIGURE` writes that `UpdateWindowData` performs
(`main.c:961`, `main.c:972`) and the answer would be meaningless.

The accumulator is `__declspec(thread)`, so the capture thread and
`ResolutionChangeThread` (`resolution.c:238`) cannot corrupt the main loop's accounting.

---

## 2. Record format

One line per emit, at `LOG_LEVEL_INFO`, into the **existing** agent log — no new log file
and no new rotation logic:

* `qubes-windows-utils` `LogInit()` already creates `gui-agent-YYYYMMDD-HHMMSS-<pid>.log`
  per process start and purges files older than `LogRetention` at startup
  (`LogRetention` on the test VM = `0x93a80` = 7 days; `LogDir` =
  `C:\Program Files\Qubes Tools\log`).
* INFO is deliberate: the test VM's `LogLevel` is `3` (INFO), so the records appear
  **without** raising the level. Raising it to DEBUG/VERBOSE would flood the log from
  `GetRealWindowRect`, `AddWindowsProc` and `SendWindowDamageEvent` and would dominate
  exactly what we're measuring.

```
[20260730.221503.412-3712-I] PerfEmitFrame: QGAPERF,v=1,seq=812,n=1,mode=s,dt=16612,acq=15220,wak=413,mrq=9,drq=48,upd=2740,enu=6033,rem=31,dmg=221,snd=498,tot=9601,dr=4,mr=0,mrmax=0,area=451200,win=7,sends=5,skip=0,log=41
```

| field | meaning |
|---|---|
| `v` | record format version (`PERF_RECORD_VERSION`) |
| `seq` | frames handed to `ProcessNewFrame` since agent start (monotonic; gaps ⇒ dropped log lines) |
| `n` | **frames aggregated into this line** (`PerfEveryN`, default 1). Every time/count field below is a **sum over `n` frames** — divide by `n` for per-frame values |
| `mode` | `s` = seamless, `f` = fullscreen |
| `dt` | µs between this frame's `ProcessNewFrame` entry and the previous one ⇒ achieved frame cadence |
| `acq` | µs in `AcquireNextFrame` — **mostly idle wait, not cost**. Reported separately and excluded from `tot` |
| `wak` | µs from the capture thread's `SetEvent(frame_event)` to `ProcessNewFrame` entry ⇒ scheduler wakeup latency (relevant to CLAUDE.md fact #5, the 4-vCPU question) |
| `mrq` | µs in the measurement-only `GetFrameMoveRects` |
| `drq` | µs in `GetFrameDirtyRects` (size query + fetch + `malloc`) |
| `upd` | µs in the `UpdateWindowData` loop, **send time removed** |
| `enu` | µs in `AddAllWindows()` (the per-frame `EnumWindows`), **send time removed** |
| `rem` | µs in the `DeletePending` removal loop, **send time removed** |
| `dmg` | µs in the damage/intersection loop, **send time removed** |
| `snd` | µs inside `VchanSendTimed` during this frame (all messages) |
| `tot` | µs for the whole `ProcessNewFrame`. `tot ≈ upd+enu+rem+dmg+snd`; the residual is loop overhead and the critical-section entry |
| `dr` | dirty rects reported by DDA |
| `mr` | move rects reported by `GetFrameMoveRects` this frame |
| `mrmax` | **max `mr` ever seen since agent start** — carried in every record, so a single `tail -1` answers the move-rect question |
| `area` | total dirty area in pixels (sum of dirty-rect areas) — the "repaint volume" axis of the decision |
| `win` | watched windows at the end of the frame (last value, not a sum) |
| `sends` | number of `VchanSendTimed` calls during the frame |
| `skip` | frames the capture thread dropped for having 0 dirty rects, since the last emitted record |
| `log` | µs the **previous** emit took ⇒ the instrumentation's own self-cost, measured not assumed |

Two other lines to grep for:

```
QGAPERF on: freq=10000000 everyN=1 qpc_cost_ns=24 default=1 (sink …)
QGAPERF-MOVERECTS: first non-empty GetFrameMoveRects: count=3 src=(120,340) dst=(100,320)-(900,940)
```

`qpc_cost_ns` is measured at startup by timing 10 000 `QueryPerformanceCounter` calls.
On a Xen HVM guest QPC may be backed by an invariant TSC (~20–30 ns) or by an emulated
timer (~1 µs); with ~14 QPC calls per frame that is the difference between 0.4 µs and
14 µs of self-inflicted cost, so it is measured on every run rather than assumed.

---

## 3. Enable / disable

Resolution order — **environment > registry > compile-time default**:

| knob | where | default |
|---|---|---|
| `QUBES_GUI_PERF=0\|1` | process environment | unset |
| `PerfLog` (DWORD) | `HKLM\Software\Invisible Things Lab\Qubes Tools\gui-agent` (falls back to the parent key, like every other agent config value) | absent |
| `QGA_PERF_DEFAULT` | compile-time macro in `perf.h` | **1 (ON)** |

```powershell
# turn it off without rebuilding, then restart the agent
reg add "HKLM\Software\Invisible Things Lab\Qubes Tools\gui-agent" /v PerfLog /t REG_DWORD /d 0 /f /reg:64
# aggregate 30 frames per line if per-frame logging ever turns out to distort
reg add "HKLM\Software\Invisible Things Lab\Qubes Tools\gui-agent" /v PerfEveryN /t REG_DWORD /d 30 /f /reg:64
```

When disabled, the only residue on the hot path is a predicted-taken test of one global
`BOOL` inside `PerfNow()` (which returns 0, so every delta is 0 and `PerfEmitFrame`
returns immediately) plus one `perfWindows++` per window per frame. No QPC calls, no
formatting, no I/O, no behaviour change. **Before upstreaming, flip `QGA_PERF_DEFAULT`
to 0 in `perf.h`** — that one-line change makes the whole thing opt-in, which is what a
reviewable PR should look like.

### Emit-per-frame vs aggregate — the choice, and why

**Chosen: one line per frame (`PerfEveryN=1`), with aggregation available as a safety valve.**

* The decision point needs *distributions*, not means: "does tracking dominate" is
  answered by p95/p99 of `enu` vs `dmg`, and the causal question ("is cost driven by
  window count or by dirty-rect area?") needs the per-frame correlation between `enu`,
  `win`, `dr` and `area`. Averaging over N frames destroys exactly that.
* Cost: at 60 fps a record is ~200 B ⇒ ~12 KB/s, one buffered `WriteFile` per line
  (`LogSafeFlush=0` on the test VM ⇒ no `FlushFileBuffers` per line). That is ~3 orders
  of magnitude under what the path can take.
* The emit is a single `_LogFormat` call with integer arguments only — no allocation, no
  string building of our own, one lock acquisition.
* And it is not a guess: the `log` field reports the previous emit's real cost, so the
  first run tells us whether per-frame emission is affordable. If `log` turns out to be a
  meaningful fraction of `tot`, set `PerfEveryN=30` and re-run — the fields become sums
  over 30 frames, `n=30` tells the analyzer the divisor, and nothing else changes.

---

## 4. Turning the log into the decision table

Pull the log (read-only, parse as data — never execute anything from the guest):

```bash
tools/qtest run 'type "C:\Program Files\Qubes Tools\log\gui-agent-*.log"' > agent.log
# or, with the exact name:
tools/qtest run 'dir /b "C:\Program Files\Qubes Tools\log"'
```

**awk one-liner** (whole file, or pipe through `grep` first to slice a phase):

```bash
grep -h 'QGAPERF,v=' agent.log | sed 's/.*QGAPERF,//' | awk -F'[,=]' \
 '{for(i=1;i<NF;i+=2)v[$i]=$(i+1); n+=v["n"]; for(k in v) s[k]+=v[k]}
  END{printf "frames=%d fps=%.1f | tracking(upd+enu+rem)=%.0fus (%.0f%%) damage(drq+dmg)=%.0fus (%.0f%%) send=%.0fus (%.0f%%) | tot=%.0fus/frame dr/f=%.2f area/f=%.0fpx win=%d mrmax=%d\n",
   n, n*1e6/s["dt"], (s["upd"]+s["enu"]+s["rem"])/n, 100*(s["upd"]+s["enu"]+s["rem"])/s["tot"],
   (s["drq"]+s["dmg"])/n, 100*(s["drq"]+s["dmg"])/s["tot"], s["snd"]/n, 100*s["snd"]/s["tot"],
   s["tot"]/n, s["dr"]/n, s["area"]/n, v["win"], v["mrmax"]}'
```

```
frames=599 fps=60.2 | tracking(upd+enu+rem)=8839us (92%) damage(drq+dmg)=274us (3%) send=500us (5%) | tot=9619us/frame dr/f=3.53 area/f=449110px win=7 mrmax=0
```

**Python, with percentiles and per-workload slicing** (this is the one to actually use):

```bash
./analyze-perf.py agent.log --markers qgaperf-harness-*.json
./analyze-perf.py agent.log --since 20260730.221000.000 --until 20260730.221010.000
./analyze-perf.py agent.log --csv frames.csv     # for plotting / correlation
```

It prints, per harness phase: achieved fps, mean/p50/p95/p99/max for every field, the
counts per frame, the `tracking / damage / send / moverects / unaccounted` breakdown as
a share of `tot`, the wakeup latency, the instrumentation self-cost, and a **MOVE-RECTS
VERDICT** line derived from `mrmax`.

Reading it for the Phase 1A decision:

* `tracking ≫ damage` and `enu` the biggest single term ⇒ the `EnumWindows`-per-frame
  TODO is the target; Phase 2A `SetWinEventHook` is the fix and should remove ~`enu`+most
  of `upd` from every frame.
* `damage ≫ tracking`, `dr` small but `area` ≈ full screen ⇒ DDA is reporting coarse
  damage; the win is damage coalescing / killing the full-screen fallback, and Track B
  (an IDD that produces honest dirty rects) gets re-ranked *up*.
* `snd` dominant, or `sends`/frame large ⇒ per-rect `MSG_SHMIMAGE` chattiness, fix is
  batching, and it re-ranks the gui-daemon side.
* `tot ≪ dt` while the drag still looks laggy ⇒ the agent is not the bottleneck at all;
  look at `wak` (scheduler, 4 vCPUs) and `acq`/`skip` (DDA cadence), and re-read omeg's
  #1045 input-simulation theory.
* `mrmax > 0` ⇒ the `capture.c:441` TODO is live and move rects are worth implementing.
  `mrmax == 0` after a real drag ⇒ the in-code note is confirmed and Phase 2A should
  drop move rects entirely.

---

## 5. The harness (`drag-harness.ps1`, Phase 1A.4)

```bash
tools/qtest pushrun instrumentation/drag-harness.ps1
```

Phases, in order: `idle-pre` (5 s) → `drag` (10 s) → `idle-mid1` (2 s) → `scroll` (10 s)
→ `idle-mid2` (2 s) → `type` (10 s) → `idle-post` (5 s). Idle phases are the baseline the
active ones are compared against.

* **drag** — Notepad is centred, grabbed by the title bar with `SendInput`
  `MOUSEEVENTF_LEFTDOWN`, then walked around a 200 px circle at 60 Hz for 10 s (0.5 Hz
  circle), button released in a `finally` so a failure never leaves the mouse captured.
* **scroll** — cursor over the Notepad client area, `MOUSEEVENTF_WHEEL` ±3 notches at
  20 Hz, down for the first half and back up for the second (a 400-line file is opened so
  there is something to repaint).
* **type** — `KEYEVENTF_UNICODE` down/up pairs at 10 Hz. Small, single-window damage —
  the "typing latency" case.

Design points that matter for the numbers being trustworthy:

* Runs in **console session 1** (verified — `qubes.VMShell` lands there), and the script
  **proves** `SendInput` reaches the input desktop before doing anything: it moves the
  cursor to a known point and re-reads it with `GetCursorPos`, aborting loudly otherwise.
  Without that check a broken session silently produces a beautiful "idle" dataset.
* All input loops are **C#, not PowerShell**. At 60 Hz, PowerShell per-iteration object
  churn is comparable to what we're measuring in the agent; the P/Invoke structs are also
  filled in C# because PowerShell's `$x.u.mi.dx = …` writes to a *copy* of the nested
  value type and silently does nothing.
* Absolute coordinates (`MOUSEEVENTF_ABSOLUTE|VIRTUALDESK`) so pointer acceleration
  cannot make the path non-reproducible.
* `timeBeginPeriod(1)` + sleep-then-spin pacing; each loop reports its **achieved**
  cadence and jitter (p50/p95/max), so a run where the guest was too loaded to keep
  cadence is visible instead of being mistaken for agent slowness.
* Phase boundaries are printed as `yyyyMMdd.HHmmss.fff`, byte-identical to the agent log's
  timestamp prefix, so `analyze-perf.py --markers` slices by string comparison. They are
  also written to `%TEMP%\qgaperf-harness-*.json` and repeated in the `=== RESULT ===`
  JSON.

Deployment order for the run (Phase 1A.3, not done here): stop `QubesGuiWatchdog`, back up
`C:\Program Files\Qubes Tools\bin\gui-agent.exe` to `.orig`, swap in the instrumented
build, start the service, confirm seamless still renders with `tools/qtest shot`, *then*
run the harness.

---

## 6. Honest list of what is **not** verified

1. **It has not been compiled.** No MSVC/EWDK in this qube and the CI `gui-agent` job is
   not converged (gated on `AGENT_BUILD`, its build step throws). The project builds with
   `/W4 /WX /permissive- /std:c17 /sdl`, so any warning is a build break. The patch
   deliberately mirrors constructs the existing code already uses under those flags —
   mixed declarations, `for (UINT i = …)`, narrow+wide string-literal concatenation
   (`capture.c:169-170`), `UINT = size_t / sizeof(…)` (`capture.c:431`) — but the first
   build may still need a cast or a `#pragma warning(suppress:…)`.
2. **`GetFrameMoveRects` ordering.** MSDN says move rects must be processed before dirty
   rects and the MS DesktopDuplication sample calls them in that order; the patch follows
   it. Whether calling it at all perturbs the existing `GetFrameDirtyRects` result on this
   Basic-Display-Adapter path is **unverified** — first thing to check on the first run is
   that `dr` and the rendered desktop are unchanged versus a `PerfLog=0` run.
3. **QPC backing on this guest** — TSC vs emulated timer. Measured at startup
   (`qpc_cost_ns`) precisely because it can't be assumed. If it comes back ≫100 ns,
   `PerfEveryN` and/or dropping the finer brackets is the answer.
4. **`wak` cross-thread QPC.** Windows documents QPC as consistent across processors, so
   the capture-thread stamp is comparable to the main-thread one. Not measured here.
5. **The existing `0x887a0026` "keyed mutex was abandoned"** fault at seamless switch /
   resolution change is untouched by this patch. It happens in `AcquireNextFrame`
   (`capture.c:348`) and will now show up as a `LogWarning("failed to get frame")` plus a
   gap in `seq`; that is a separate investigation.
6. **`DumpWindows` gating is a behaviour-adjacent hunk.** It skips work whose output was
   being discarded (`OpenProcess` + `QueryFullProcessImageName` per window per second, and
   both the watched-windows and logger locks) at any `LogLevel < 4`. It removes a ~1 Hz
   confounder from the measurement, but it is *not* instrumentation. If a reviewer objects,
   it drops out cleanly — it is a single hunk at `main.c:1260`.
7. **Error-path attribution.** A `goto cleanup` out of the removal loop (`main.c:1081`)
   attributes the elapsed time to `dmg` rather than `rem`. Error path only; frames where
   this happens also carry a `RemoveWindow` warning in the log.
8. `PerfEmitFrame` is called after `LeaveCriticalSection`, so the log write never happens
   under `g_csWatchedWindows` — but it does happen on the main loop thread, between the
   frame being processed and `SetEvent(capture->ready_event)` (`main.c:1291`). Its cost is
   therefore inside the frame pipeline, which is why `log` is reported.
