# Adversarial review — 425c439 "workarea: debounce broadcast-driven re-assert"

Scope: `agent/gui-agent/workarea.c` at 425c439 (branch `perwindow`), read-only. Call graph
cross-checked against `main.c`, `resolution.c`, `vchan-handlers.c` at the same commit.

## Verdict: NEEDS_WORK

The debounce is well-typed, wraparound-correct, and it does break the measured 12 Hz
ping-pong. Two defects stop it from shipping as-is:

- **D1 (real, latent):** the stamp is advanced on the *suppressed* path, making this a
  sliding-window **debounce**, not a **throttle**. Any SPI_SETWORKAREA broadcast train at
  >1 Hz keeps pushing the deadline forward and starves *every* re-assert **indefinitely**,
  including `WorkAreaEnsureApplied`'s drift correction — which is the exact "backstop" the
  commit message relies on. The message's "Loss is bounded to <=1 s of a stale work area"
  is false; the true bound is "until the broadcast train drops below 1 Hz".
- **D2 (design):** the debounce sits in `WorkAreaReassert`, i.e. on the shared path, so it
  also rate-limits the two callers that were never the problem — `WM_DISPLAYCHANGE` (rare,
  high-value) and `WorkAreaEnsureApplied` (already self-limited to 0.5 Hz). Only the
  `WM_SETTINGCHANGE(SPI_SETWORKAREA)` case is a >1 Hz source.

Plus one thing the commit does not claim but the numbers imply — see **O1**: the fix lowers
the fight from ~12 Hz to ~0.5 Hz but does not end it, and the acceptance measurement for
this commit has to prove that.

---

## 1. Correctness of the debounce primitive

```c
static volatile LONG lastReassert; // interlocked: listener + main-loop threads
DWORD now = GetTickCount();
LONG prev = InterlockedExchange(&lastReassert, (LONG)now);
if (prev != 0 && (DWORD)(now - (DWORD)prev) < WA_REASSERT_MIN_MS)
    return;
```

### 1a. Types / interlocked semantics — CORRECT
- `InterlockedExchange(LONG volatile *Target, LONG Value)`; `&lastReassert` on a
  `static volatile LONG` is an exact parameter match, no qualifier discard. `LONG == long`
  on MSVC x64, so the `_InterlockedExchange` intrinsic binds fine.
- `(LONG)now`: DWORD→LONG for values > `LONG_MAX` is implementation-defined in C17, but MSVC
  is two's-complement wrap and the bit pattern is what matters here. The explicit cast also
  suppresses C4245 (the project builds `/W4 /WX`, see §5).
- `(DWORD)prev` restores the bit pattern; `now - (DWORD)prev` is unsigned modulo-2^32
  arithmetic — the textbook-correct tick delta.

### 1b. GetTickCount wraparound (49.7 d) — CORRECT
`prev = 0xFFFFFF00`, `now = 0x00000050` → `now - prev = 0x150` = 336 ms < 1000 → correctly
suppressed. No sign extension leaks in because both operands are cast to DWORD before the
subtraction. This is handled properly and matches the existing `WorkAreaEnsureApplied`
pattern (`now - lastCheck < WA_DRIFT_CHECK_MS`).

### 1c. The `prev != 0` sentinel — HARMLESS, and nearly a no-op
The guard only changes behaviour when `now < WA_REASSERT_MIN_MS`, i.e. within the first
second of `GetTickCount` (system boot, or the 49.7-day wrap). Outside that, `now - 0 == now`
is already ≥ 1000. So:
- *first call at tick 0*: `prev == 0` → passes. Correct, intended.
- *`GetTickCount()` legitimately returns 0* (once per 49.7 d, and only if the ~15.6 ms tick
  sequence lands exactly on 0): the stamp is written as 0, so the *next* call misreads it as
  "never called" and skips the debounce. Cost: **one extra re-assert every 49.7 days.**
  Not a bug; not worth code. (If you want it gone, `now |= 1` — a ≤1 ms distortion.)

No failure scenario found here.

### 1d. Stamping on the suppressed path — **D1, the real bug**
`InterlockedExchange` writes `now` unconditionally, *then* the code decides to return. Every
suppressed call therefore moves the deadline one full `WA_REASSERT_MIN_MS` into the future.
The re-assert fires only after a **full 1 s of silence**, not "at most once per 1 s".

**Failure scenario D1-a — defence blackout of unbounded duration.**
State: agent applied `T`; some source (Explorer recomputing during a taskbar auto-hide
cycle, an app calling `SystemParametersInfo(SPI_SETWORKAREA, …, SPIF_SENDCHANGE)`, a
docking/OSK/tablet-mode transition, or a monitor/mode churn from the IddCx work in Track B)
broadcasts `WM_SETTINGCHANGE(SPI_SETWORKAREA)` at ~1.5 Hz for 30 s while the OS work area
sits at `E ≠ T`.
Trace:
- t=0.0 broadcast → listener → `WorkAreaReassert` → stamp=0.0, passes → apply.
- t=0.7 broadcast → stamp=0.7, **suppressed**.
- t=1.4 broadcast → stamp=1.4, **suppressed**.
- t=2.0 main loop → `WorkAreaEnsureApplied`: `now-lastCheck ≥ 2000` → **`lastCheck = 2.0`
  is written before any work** (workarea.c:338) → detects drift (`E ≠ T`) → logs "work area
  drifted" → `WorkAreaReassert` → `now-1.4 = 0.6 < 1.0` → **suppressed**, and stamps 2.0.
- t=2.1 broadcast → stamp 2.1, suppressed. … t=4.0 drift check → last stamp 3.5 →
  suppressed again, `lastCheck` burned for another 2 s.
Result: **for the whole 30 s the work area stays `E` and both defence paths are dead.**
Pre-fix the agent would have corrected it (expensively, but correctly). The drift check makes
this *worse* than a plain miss, because it consumes its own 2 s budget on an attempt it
knows was rejected.

**Why the measured workload does not expose it (and why that is not a defence).** In the
measured ping-pong the broadcast is tightly coupled 1:1 to our own apply, so the train stops
the instant we stop applying: t=0 apply, t≈0.05 Explorer's broadcast (suppressed, stamp
0.05), silence; the t=2.0 drift check sees a 1.95 s-old stamp and passes. So this commit
does fix *the storm it was written for*. D1 is a latent trap in a primitive that is now on
the only path that defends the work area, and it converts "we fight too hard" into "we do
not fight at all" for any broadcaster the agent does not itself drive. Given the previous
commit (2c5dad2) shipped on a model of Explorer's behaviour that the very next measurement
falsified, betting the defence path on "no external source ever exceeds 1 Hz" is the wrong
bet.

**Concurrency of the primitive itself is correct.** Two threads racing: A exchanges and gets
an old `prev` (passes); B exchanges 1 ms later and gets A's stamp (suppressed). Exactly one
winner, no lost update, no double-apply. That part is right.

## 2. Does it stop the measured storm? Call-graph trace

`WorkAreaReassert` has exactly three callers, all now behind the shared debounce:

| Site | Caller | Thread | Rate |
|---|---|---|---|
| workarea.c:305 | `WaWndProc` `WM_SETTINGCHANGE(SPI_SETWORKAREA)` | window-event thread | **the 12 Hz source** |
| workarea.c:311 | `WaWndProc` `WM_DISPLAYCHANGE` | window-event thread | rare (mode set) |
| workarea.c:358 | `WorkAreaEnsureApplied` | main-loop thread (`main.c:2588` in `ProcessWindowEvents`, `main.c:3524` in `WatchForEvents`; `ProcessWindowEvents` is called from `WatchForEvents` at main.c:3657, so both are genuinely main-loop) | ≤0.5 Hz, already self-limited |

- **Storm path: yes, cut.** The ping-pong is self-terminating once suppressed: we stop
  applying → Explorer has nothing to answer → no further broadcast. Confirmed by trace.
- **Drift correction: suppressed as collateral, and asymmetrically expensively.** See D1-a:
  `WorkAreaEnsureApplied` stamps `lastCheck` *before* calling `WorkAreaReassert`, so one
  suppression costs 2 s, not 1 s. Even in the benign single-broadcast case the worst-case
  correction latency is **~4 s** (drift check at t, suppressed by a broadcast at t-0.9;
  retry at t+2 s), not the "~1–2 s" the commit message states. Debouncing a caller that is
  already rate-limited to half the debounce frequency buys nothing and only adds latency.
- **`WM_DISPLAYCHANGE` collateral.** Sharing one stamp with the high-rate work-area path
  means a work-area broadcast can swallow a display change — the one event where the target
  rect definitely changed (`WaCompute`/`WaRectSane` are bounded by `g_ScreenWidth/Height`).
  Recovery is via the drift check, so it is bounded in the benign case, but the coupling is
  gratuitous. Note that the agent-initiated mode change path is *not* at risk: `SetVideoMode`
  (resolution.c:187) calls `WorkAreaApply()` directly after updating `g_ScreenWidth/Height`,
  and that call is not debounced — a stale-dimension apply from a suppressed/early listener
  event is corrected there in either interleaving. I traced both orderings; no bug.

## 3. Other churn sources — clean

- `EnumWindows(WaRefitProc, 0)` runs **only** after a successful `SPI_SETWORKAREA`
  (workarea.c:199), i.e. strictly proportional to the apply rate. Cutting applies cuts the
  refits 1:1. Good — and note it runs on the *window-event thread* when driven by
  `WaWndProc`, so 12 Hz of `EnumWindows` + synchronous cross-process `SetWindowPlacement`
  was stalling hook delivery, which is a bigger deal than the 4 % CPU. That is the strongest
  argument for this commit.
- Direct `WorkAreaApply` callers are all self-limiting via the `changed` shortcut
  (`!EqualRect(&target, &g_WaLastApplied)`), which only `WorkAreaReassert` defeats:
  - `main.c:3588` — once, at vchan connect.
  - `resolution.c:187` — only on an actual resolution change.
  - `vchan-handlers.c:66` — `MSG_WORKAREA`, rare.
  - `vchan-handlers.c:499` → `WorkAreaNoteDaemonOrigin` — runs on **every** `MSG_CONFIGURE`,
    but `WorkAreaApply` is reached only when the running minimum origin decreases; that is
    monotone and converges in a handful of samples. Not a churn source.
  - `WaWatchThread` (workarea.c:264/278) — qubesdb writes only.
  No second high-rate path. The commit targets the only one.

## 4. Races / lock ordering — no new problems

- `lastCheck` (`static DWORD`, `WorkAreaEnsureApplied`) is main-loop-thread-only — verified:
  both call sites are inside `WatchForEvents`'s loop. Non-atomic is fine. Different variable,
  no interaction with `lastReassert` beyond the *logical* one in D1-a.
- `lastReassert` is genuinely cross-thread (window-event + main-loop) and is correctly
  interlocked. The in-code comment naming both threads is accurate.
- Lock ordering: the debounce runs **before** `EnterCriticalSection(&g_WaLock)` and takes no
  lock, so the suppressed path is lock-free and cheap. No inversion introduced.
- Correct placement **after** the `!g_WaInitDone` guard: pre-init broadcasts (Explorer's
  autologon SPI_SETWORKAREA, `HandleXconf`'s early `WM_DISPLAYCHANGE` — both called out in
  2c5dad2) return without poisoning the stamp, so the first real re-assert is not eaten.
  Had the debounce been placed above that guard it would have been a startup bug. It is not.
- Pre-existing, untouched by this commit: `SetRectEmpty(&g_WaLastApplied)` + `WorkAreaApply()`
  in `WorkAreaReassert` are not atomic together, and `WorkAreaApply` is reachable from four
  threads (main loop, window-event, `WaWatchThread`, `ResolutionChangeThread`). The debounce
  incidentally *narrows* that window. Not a regression.

## 5. C correctness — COMPILES

`vs2022/gui-agent/gui-agent.vcxproj` builds `workarea.c` as **C17** (`LanguageStandard_C
stdc17`), **`/W4`**, **`TreatWarningAsError=true`** (the C++17/W3/no-WX relaxation applies
only to `wincapture.cpp`).
- Mid-block declarations (`static volatile LONG` + `DWORD now` + `LONG prev` after
  statements): legal in C17, and already the file's style (`BOOL have` at :174, `DWORD now`
  at :335). OK.
- `DWORD` vs the signed literal `WA_REASSERT_MIN_MS` in `<`: no C4018 for a non-negative
  literal, and the identical construct at :336 already builds. OK.
- No shadowing (C4456/C4457/C4459), no unused locals (C4189), no uninitialised reads.
- `WA_REASSERT_MIN_MS` placed beside `WA_DRIFT_CHECK_MS` at the top — consistent.
- `static volatile LONG` is zero-initialised at load, which the `prev != 0` sentinel relies
  on. Correct.

No compile or `/WX` risk found.

---

## O1 — the fix does not end the fight, and the commit message reads as if it does

The 1018 log lines are the tell. `WorkAreaApply` logs "guest work area set" *only after*
`SPI_GETWORKAREA != target` **and** `SPI_SETWORKAREA` returned TRUE (workarea.c:184–198). So
each of those 1018 iterations read back an Explorer value `E` that genuinely differed from
our target `T`. The disagreement is persistent, not transient.

Predicted post-fix steady state (**a hypothesis to be measured, not a claim**):
t=0 drift check → apply `T` → Explorer writes `E` + broadcasts at t≈0.05 → suppressed →
silence → t=2.0 drift check sees `E ≠ T` → apply `T` → … i.e. a **permanent ~0.5 Hz
oscillation**: one "work area drifted…re-asserting" + one "guest work area set" log line and
one `EnumWindows`+`SetWindowPlacement(SW_MAXIMIZE)` sweep every 2 s, forever, with maximized
windows re-fitted to `T` and then left at `E` for most of each cycle. That is 24× cheaper
than 12 Hz — a real win — but it is not resolution, and it may trade a high-CPU/visually-
stable state for a low-CPU/visually-jittery one.

**Acceptance gate for this commit should be exactly this count**, from the same harness:
`grep -c 'guest work area set'` and `grep -c 'work area drifted'` over a ≥120 s idle run.
- ≈0 after startup → Explorer settles; O1 is moot and the fix is complete.
- ≈0.5/s sustained → the fight persists and the root cause (`T` is a rect Explorer will not
  accept, or `T` is computed against geometry Explorer disagrees with) needs its own commit:
  either read back `SPI_GETWORKAREA` after applying and record *that*, or count consecutive
  losses and back off to a long interval with one WARN, rather than re-asserting forever.

Do not merge on the reasoning alone — that is the same failure mode as 2c5dad2's item 5
("Re-asserts only happen on real work-area/display changes"), which this very measurement
disproved one commit later.

---

## Minimal correct change

Two edits, both local to `workarea.c`, together making the commit message's claims true.

**(1) Debounce only the source that actually storms.** Give `WorkAreaReassert` a parameter
so `WM_DISPLAYCHANGE` and the already-rate-limited drift check are not collateral:

```c
// workarea.h
void WorkAreaReassert(void);              // unconditional (drift check, display change)
void WorkAreaReassertThrottled(void);     // >=WA_REASSERT_MIN_MS apart (broadcast listener)
```

```c
// workarea.c — new wrapper; WorkAreaReassert reverts to its 2c5dad2 body
void WorkAreaReassertThrottled(void)
{
    if (!g_WaInitDone)
        return;

    // ...existing ping-pong comment...
    static volatile LONG lastReassert; // interlocked: listener thread only today, but
                                       // this is the shared-state form regardless
    DWORD now = GetTickCount() | 1;    // 0 is the "never asserted" sentinel
    LONG prev = InterlockedCompareExchange(&lastReassert, 0, 0);   // atomic read
    if (prev != 0 && (DWORD)(now - (DWORD)prev) < WA_REASSERT_MIN_MS)
        return;                        // NOTE: stamp deliberately NOT advanced
    if (InterlockedCompareExchange(&lastReassert, (LONG)now, prev) != prev)
        return;                        // another thread won this slot; it re-asserts

    WorkAreaReassert();
}
```

and at workarea.c:305 call `WorkAreaReassertThrottled()` instead of `WorkAreaReassert()`.
Leave :311 (`WM_DISPLAYCHANGE`) and :358 (`WorkAreaEnsureApplied`) on the unthrottled entry
point.

**(2) The read/CAS pair is what fixes D1** — a suppressed call leaves the deadline where it
was, so the rate limiter is a true throttle (≥1 re-assert per second under *any* broadcast
rate) instead of a debounce that can be starved forever. It is a single-shot compare-exchange
with an early return on loss — **no retry loop, no spin** (explicitly not the busy-loop shape
this project rejected before). `| 1` keeps the sentinel meaningful at the 49.7-day wrap; cost
is ≤1 ms of skew.

With (1)+(2) the commit message becomes literally true: the broadcast path is capped at 1 Hz,
a genuine overwrite is corrected within ≤2 s by the drift check regardless of broadcast
traffic, and no external broadcaster can disarm the defence.

**Optional, cheap, and worth it for the next measurement:** a `LogWarning` (or a counter
folded into the existing periodic stats) on the Nth consecutive suppressed re-assert, so the
next log tells you whether D1-a is happening in the field instead of leaving it to inference.
