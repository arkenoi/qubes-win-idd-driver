# misc — findings

## CURRENT STATE

AUTHORITATIVE. Supersedes everything under History below. A correction belongs HERE,
not only as a new dated section — the whole reason this file exists is that 654
correction lines were buried chronologically in a 25k-line log, so reading a topic
top-down returned the stale answer.

- Not yet distilled from the history below. UNVERIFIED

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

## Registry: `LogLevel` has a PER-MODULE override that wins

`HKLM\Software\Invisible Things Lab\Qubes Tools\LogLevel` is **not** what gui-agent reads.
There is a subkey `...\Qubes Tools\gui-agent` with its own `LogLevel`, and it takes precedence:
setting the parent to 5 produced zero `-D]`/`-V]` lines; setting
`...\Qubes Tools\gui-agent\LogLevel = 5` produced 369 debug lines in the next instance.
Anything in this repo that says "raise LogLevel" means the subkey.

# 2026-08-04 (later) — validating `66fc670`: three more controls that could not fail

Work in progress on the second of the three unproven commits. Recorded now because the
*preconditions* found here are worth more than the eventual verdict.

## The generalisable error

Twice today the *premise* of a measurement was wrong rather than the measurement: "stock is a
valid control" (it lacked the feature under test) and now "the default is off" (it is on). Both
were one grep away. **Check the premise of a comparison before running it, not after it produces
a clean-looking result** — a wrong premise yields confident, well-replicated, meaningless numbers.

---

## Documents produced today (all committed, all reviewable)

| file | what it is |
|---|---|
| `DESIGN-gui-daemon-restart-survival.md` | why gui-daemon dies, ranked guest-side fixes, the dom0/upstream proposal. **dom0 items need user approval.** |
| `PLAN-trackb-t2-modes.md` | Track B / T2: how our driver supplies arbitrary modes, what gates it, plus the work-area addendum |
| `REVIEW-synthesis-fix-cluster.md` | per-commit keep/revise/revert verdicts for the synthesis cluster; found the wild-pointer bug |
| `SESSION-HANDOFF-2026-08-04.md` | entry point for the next session |
| `scratchpad/` | the harnesses that work: `vmcycle.sh`, `wildptr2.ps1`, `graceful-stop.ps1`, `install-agent2.ps1`, `ab-boot.sh`, `ab-orphan.sh`, `office-shadow-probe.ps1`, and the deliberately-UNRUN `secure-desktop-probe.ps1` |

# 2026-08-04 (close) — `6b5b298` REVERTED: measured, no effect

The user's rule was "if it does nothing, let's revert" — so the "if" was measured rather than
assumed, because the review's claim that its mechanism was impossible was itself unverified and
there WAS a concrete mechanism it might have prevented.

## 1. Watchdog stop semantics (watchdog/watchdog.c)
- `Stop-Service QubesGuiWatchdog` does NOT touch gui-agent.exe: the stop handler (`:264-281`)
  only reports SERVICE_STOPPED. No TerminateProcess, no job object; child handles are closed
  right after CreateProcessAsUser (`:137-138`).
- Respawn = 1 s poll (`:153`, Sleep(1000) + WTSEnumerateProcesses name-PREFIX match `:68`),
  no backoff, no give-up counter. 20+ stop/respawn cycles in one boot trip nothing.
- Consequence for installs: stop watchdog first (agent keeps running), THEN signal
  `Global\QGA_SHUTDOWN`, wait exit, copy, verify hash. `install-agent3.ps1` implements this.

## 2026-08-11 (cont.) — S1b ROOT CAUSE CONFIRMED FROM dom0 guid LOG; causality RESOLVED (H2)

dom0 guid log tail (user-supplied, same storm run):
    Verify failed: (int) untrusted_crt.width >= 0 && (int) untrusted_crt.height >= 0
    (zenity:336840) ... 18:19:35.734   <- the Ignore/Terminate dialog process
    msg 0x90 without CREATE for 0x1018a

FACTS this settles:
1. The failing check is EXACTLY xside.c:2937-2938 in handle_create (MSG_CREATE) — the predicted
   line, now PROVEN not inferred. A negative-as-int width or height was sent for a window.
2. **Causality is H2, not H1.** zenity (the dialog) is stamped 18:19:35.734; the vchan flood is
   18:19:42.246 and the capture death 18:19:43.258 — the dialog came ~6.5 s BEFORE the wedge.
   So: bad MSG_CREATE -> daemon VERIFY fails -> modal dialog -> daemon stops draining the vchan ->
   agent pump blocks in VchanSendBuffer -> CaptureThread times out and dies -> display frozen.
   H1 (flood-first) is REJECTED for this run. The 24H2 wedge (no dialog) remains a separate,
   flood-only path — both exist; the dialog path is faster and worse.
   => ANY single suspicious message = guest display DoS. Bounded/non-blocking vchan writes are
   therefore not a nice-to-have; they are the containment for a whole failure class.
3. `msg 0x90 without CREATE for 0x1018a` — CORRECTED DECODE: with MSG_MIN=123 the enum gives
   MSG_CREATE=130 (0x82), MSG_MAP=132 (0x84), and **0x90 = 144 = MSG_WINDOW_HINTS** (verified
   against qubes-gui-common/include/qubes-gui-protocol.h:134-160, cross-checked by the two
   in-header annotations MSG_UNMAP=133 and MSG_DOCK=143). Same HWND 0x1018a as the storm.
   The rejected CREATE means the daemon holds NO window object, so every later message for that
   HWND is orphaned: agent and daemon state DIVERGE after a rejected CREATE. Any fix MUST keep
   them consistent (suppress dependent messages, not just the bad CREATE).
4. Agent send path has NO sanity guard: SendWindowCreate (agent/gui-agent/send.c:287) computes
   width = rcWindow.right - rcWindow.left from WINDOW_DATA X/Y/Width/Height and sends it
   unvalidated; the daemon's own clamp (min/max to MAX_WINDOW_*) happens only AFTER the VERIFY,
   so a negative value is fatal rather than clamped. Note the guard is NOT at send.c:600 as the
   earlier handover claimed — that reference should not be reused without re-checking.

STILL UNKNOWN: which WINDOW_DATA field went negative and why (25H2 StartFeed geometry). The dom0
log prints the failing values only at log_level>0 for successful creates, not for rejects. Next
diagnostic: agent-side QGAPROTO trace already logs w/h per CREATE (send.c:~336) — re-run the storm
with g_ProtoTrace on and find the CREATE whose w or h is huge-unsigned (= negative as int).

## 2026-08-11 (cont.) — GUEST CLOCK AUDIT (asked: is the guest synced with dom0?)

ANSWER: **No — two distinct errors.** Measured 8 round-trip samples in two batches (~2.5 min
apart), guest `(Get-Date).ToString('o')` vs this qube's clock, offset = guest - midpoint(t0,t1):

| batch | median offset | spread |
|---|---|---|
| 18:43:05-09 | +10801.768 s | 0.21 s |
| 18:45:2x    | +10801.878 s | 0.14 s |

1. **+10800 s = exactly 3 h, absolute/UTC error.** Guest TZ is `UTC` (bias 00:00:00) but its wall
   clock holds LOCAL (EEST, +0300) time: guest claims 18:45 UTC while true UTC is 15:45. Anything
   the guest computes in UTC (TLS validity, WU metadata, Event Log UTC fields, servicing stamps)
   is 3 h in the future. `RealTimeIsUniversal` is NOT set, W32Time Stopped/Manual with
   time.windows.com (unreachable — VM is offline), autotimesvc + vmictimesync Stopped. QWT's
   `qubes.SetDateTime` handler IS installed (`qubes-rpc-services\set-time.ps1`, does `Set-Date $in`
   on a dom0-supplied `...+0000` string, which WOULD be correct given TZ=UTC) — so it has simply
   not been invoked since the TZ was set to UTC. It is dom0-initiated (qvm-sync-clock); the mgmt
   qube cannot trigger it.
2. **+1.8 s residual skew** on top of the 3 h, stable to ~0.1 s across 2.5 min (no measurable
   drift; guest booted 18:34:37, measured 18:43-18:45).

IMPACT ON THE H2 CAUSALITY CLAIM (checked, claim SURVIVES): dom0 guid `zenity` stamped 18:19:35.734
(dom0 local wall) vs guest agent `vchan buffer full` 18:19:42.246 (guest wall). Both faces read the
same local wall clock, so they ARE comparable; correcting the guest by -1.8 s gives ~18:19:40.4 in
dom0 time, still **~4.7 s AFTER** the dialog. The dialog-precedes-wedge conclusion holds with margin
(would need >6 s of skew to invert, and measured skew is 1.8 s).
CAVEATS: (a) the comparison reference was win-idd-mgmt, not dom0 itself (mgmt reports "System clock
synchronized: no", NTP inactive — it inherits dom0's clock at boot; assumed within ~1 s, unverified
because this qube cannot read dom0's clock); (b) the guest REBOOTED at 18:34:37, after the 18:19
incident, so today's 1.8 s skew is not proof of the skew at incident time.

RECOMMENDATION (not applied — user asked to check, not change): before any further cross-log
timing work, either have dom0 run `qvm-sync-clock` / trigger `qubes.SetDateTime` for win11-fresh,
or set the guest clock to true UTC in-guest. Then re-measure. Also worth setting
`RealTimeIsUniversal=1` so the guest reads the Xen RTC as UTC across reboots.

## 2026-08-12 (cont.) — THE POISONED STATE FOUND: believed 5120x1440 vs actual 1920x1080

guest/geometry-truth.ps1 on the live guest: actual mode 1920x1080 (IddSampleDriver active),
but the agent's log shows RESREQ 5120x1440 src=lastapplied -> **RESAPPLIED 5120x1440 (readback
CONFIRMED it applied)** at 00:32:03 - and the mode later REVERTED to 1920x1080 with no agent
request and no agent notice. g_ScreenWidth/Height stayed 5120x1440. Consumers skewed:
 - HandleMotion/HandleButton normalize by believed size, Windows denormalizes over the actual
   primary -> injected pointer scaled by (1920/5120, 1080/1440) = dom0 clicks land wrong.
   This is the S2 class error AND (with HandleButton's dead dx/dy) the unclickable toasts.
 - WaCompute clamps to believed screen -> rect exceeds the real 1920x1080 -> SPI_SETWORKAREA
   0x57 every 30 s, forever (observed 51x).
 - SendScreenGrants grants pages for 5120x1440 (7200) while the capture context is 1920x1080
   (2025) = the standing A3CHECK mismatch. NOTE: granting 7200 pages of a 2025-page surface
   needs a look on its own (what memory backs the excess?).
WHAT REVERTS THE MODE IS STILL UNIDENTIFIED - watch for RESDRIFT lines on the fixed build.

## 2026-08-12 (cont.) — Canonical-baseline comparison (user directive): NO agent regression;
## 2026-08-14 (night) — Win10 rig rebuilt: post 33 FIXED and measured, post 54 does NOT reproduce,
## 2026-08-25 — SECOND-OPINION REVIEW of the Aug 22–25 work (owner-requested re-check). The 4.3.6
## CLAIM DISCIPLINE (owner, 2026-08-27): we never reproduced GWeck's NATURAL trigger - his second
## 2026-08-27 (night) — Track B audit VERDICT: the driver-side Phase 2B items are moot under
## 2026-08-27 (night) — QUIET-HOST re-baseline: load was NOT the factor; the elevation vs
## path is a measured 3x WIN, the screen hash is negligible, and the vs-canonical delta is
## 2026-08-27 (late night) — secure-desktop freeze VALIDATED at v4 after v3 DEADLOCKED;
## 2026-08-27 (late) — 4.3.11 E2E: ALL PHASES PASS on the shipping build; one more real
## 2026-08-28 (early) — 4.3.12 validation on FROM-SCRATCH rigs: A-D pass, and the three-mode
## 2026-08-28 — UNSHIPPED-FIX AUDIT of the whole of FINDINGS: one more gap, and it is the same
## 2026-08-28 — #23: single-instance guard SHIPPED and proven, but it does NOT explain the boot
## 2026-08-28 cont — RETRACTION: there is no boot double-spawn race. It is a SHUTDOWN artifact.
## 2026-08-28 — RETRACTED: the stock set-gui-mode.exe is NOT broken. I asserted a defect from
## reading code and blamed upstream for it. Measurement says otherwise.

CLAIM I MADE: upstream's `set-gui-mode.c` does `SetEvent(event); return GetLastError();`, and since
GetLastError is only meaningful after a failure, a successful mode switch returns stale garbage -
which is what produced the field report "Command 'qubes.SetGuiMode' returned non-zero exit status
46" in Qubes Manager. I dated it to upstream commit 190d10f (2023-12-21) and said we had not broken
it, we had inherited it.

MEASURED on win11-app, against the STOCK binary actually installed (SHA 8DF3D0E1A6F2AB07, no
*.qwt-stock backup - we have never replaced it), with the instrument validated BEFORE the result:

    CONTROL-known-46      EXIT=46   <- a process with a known non-zero code reports it
    CONTROL-invalid-input EXIT=87   <- the same binary's ERROR_INVALID_PARAMETER path works
    SEAMLESS              EXIT=0    <- three runs, agent running, event present

The success path returns 0. The defect does not exist in practice: with no prior API having failed,
GetLastError is still 0 when it is returned. The pattern is fragile, but fragile is not broken, and
"fragile" is not what I told the owner.

TWO SEPARATE ERRORS, both mine:
1. I asserted a runtime defect from source reading alone, on a binary I could have run in two
   minutes - on a rig that was sitting idle.
2. Having asserted it, I attributed it to upstream and to a 2023 commit. That is blame-shifting,
   and it is worse than the original mistake because it invites everyone else to stop looking.

FIRST ATTEMPT AT THE MEASUREMENT WAS ALSO WRONG and nearly became a third error: `cmd /c prog &
echo %ERRORLEVEL%` reported nothing, because set-gui-mode is a GUI-subsystem binary (wWinMain) and
cmd does not wait for one. The next attempt returned 0 even with the agent killed - which should
have been impossible - and that is what forced the known-46 control that validated the harness.
qrexec gets a real exit code because it waits on the process handle; cmd does not.

STILL UNKNOWN: what produces exit status 46 on the reporter's guest. Not this success path. Needs
his gui-agent log and the qrexec side, not another hypothesis.

## 2026-09-01 — stock-vs-ours benchmark suite RE-RUN; the direction has inverted, and the harness is now code

Owner: *"re-run stock vs ours benchmark suite, unattended, i want all the numbers properly
updated."* Done. The authoritative comparison in docs/BENCHMARKS.md was single-variable and
last run 2026-08-09 on a guest that no longer exists, so every published CPU number was stale.

**Result — 6 repetitions, 6 valid, 0 invalid, all four workloads with DISJOINT ranges:**

| workload | stock 4.2.2 | ours 4.3.17 | delta |
|---|---:|---:|---:|
| idle   |  5.053 | 0.328 | -93.5 % |
| drag   | 32.251 | 14.064 | -56.4 % |
| scroll | 47.161 | 3.577 | -92.4 % |
| typing | 26.115 | 2.007 | -92.3 % |

This RETIRES the standing headline "ours costs 2x stock on typing" (2026-08-09), which was true
for the build and guest it measured and has been superseded twice over since. Absolute figures
are guest-relative and not comparable to the old tables; the DIRECTION is.

**Method, and why each piece is there.** `tools/bench-stock-vs-ours.sh`: one guest
(`win10-app`, Win10 19045.6456, 5120x1440), one install, one display stack, `gui-agent.exe`
swapped in place, 3 rounds interleaved with the starting side alternating. The stock control is
`431e4517` - the fork's merge-base with QubesOS/qubes-gui-agent-windows, three upstream commits
after `v4.2.2` - built through the SAME CI job, runner image, pinned dependencies and linker
flags as ours, so the compiler is not a variable either. Control branches pushed and NOT merged:
agent `control/stock-431e451`, superproject `control/stock-4.2.2`.

**What was checked before the numbers were believed:**
 - the RUNNING binary's hash read back off the guest every repetition (`464772F1630E47BF` /
   `5CEF96155147CDC6`) - a harness that proceeds on a failed swap reports numbers for a build
   that never ran;
 - the scene verified BY PIXELS every repetition (luminance stddev of the Notepad client area,
   frame cropped, `tools/bench-scene-check.py`) - the 2026-08-12 wedged Notepad survives agent
   restarts and binary swaps and nothing in the agent's own output can see it;
 - stock is not merely BROKEN: its log for a repetition is 22 lines with 4 warnings, i.e. no
   error loop. It also logs LESS than ours (156 lines over the same workload), so instrumentation
   cost cannot explain the direction;
 - the metric is stable on an unchanged binary - within-side spread 10-13 % (ours) and 21-26 %
   (stock) against a 2.3x-13x separation between sides.

**Why the margin is this large:** the desktop is 7.4 Mpx. Stock streams the whole framebuffer;
this fork adds DDA capture, per-window capture and dirty-rect-limited processing to avoid that.
The effect scales with screen area, so a small guest will show less. Said in the README and in
BENCHMARKS.md rather than left for someone to discover.

**NOT measured, and said so in both documents:** frames delivered (this is CPU cost for a fixed
workload; the scene was verified present on both sides, but a build can be cheap and wrong), and
anything about Windows 11 - one guest, Win10 only.

**Harness defects fixed on the way:** `guest/phase-cpu-bench.ps1` had a chained property access
that threw on exactly the state it exists to report (lint L6) and read screen width through an
assembly not loaded under `-NoProfile`, silently producing nothing. `tools/bench-agent.sh`'s
L3 nested-quote defect is untouched and that harness is NOT what this suite uses. Lint 41 -> 40.

Raw data: `instrumentation/bench-stock-vs-ours-20260901-091217/`.

## 2026-09-01 (cont.) — win11 measured; the drag "regression" was MY HARNESS, retracted same day

Owner: *"it was win10 only benchmark? we need win11 too."* Correct, and win11 was the half that
mattered - the historical concern was that ours cost MORE than stock there (+100 % typing,
2026-08-09). Run on `win11-app` (24H2 build 26100, 5120x1440), same binaries, same method.

**Result, after a harness defect was found and fixed: nothing on win11 is distinguishable from
stock.**

| workload | stock 4.2.2 | ours 4.3.17 | delta | verdict |
|---|---:|---:|---:|---|
| drag   | 14.641 | 16.967 | +15.9 % | inside noise (spread 36 %) - no verdict |
| scroll |  2.965 |  3.046 |  +2.7 % | inside noise - no verdict |
| typing |  2.335 |  2.028 | -13.1 % | inside noise - no verdict |
| idle   |  0.000 |  0.331 | | one side read 0.000 every time - below counter resolution, no verdict |

**RETRACTED, same day, loudly: "win11 drag +59.9 %, REAL, ranges disjoint, ours WORSE."** I
reported that and put it in the README as a known regression. It was an artifact of the harness I
wrote. The suite alternates stock and ours, so every repetition follows a swap between two
DIFFERENT agents - a full re-establishment (re-enumeration, per-window capture channels, buffers,
grants) - and our startup is heavier than stock's, so a short settle biases against whichever side
was just swapped in. Settle was 8 s. At 45 s, nothing else changed: stock 12.203 -> 14.641, ours
19.516 -> 16.967, gap +59.9 % -> +15.9 %, no verdict. BOTH sides moved, which is what a shared
transient looks like.

**What exposed it, and the lesson.** The ablation ran on the same guest, same binary, same
defaults and read ours' drag at 13.3-16.3 against the suite's 18.3-21.7. **Between-session
variance larger than the within-session spread is exactly what a disjoint-ranges verdict cannot
survive** - and the suite never measured between-session variance, so it could not see it. A
disjointness test is only as good as the variance it has actually sampled. The settle is now 45 s
(`BENCH_SETTLE_S` to override) with that measurement written into the comment.

**Also withdrawn:** "our drag went 8.67 (2026-08-10) -> 19.5, +125 %, against a stock control that
did not move". Same inflated figure, and the anchor is soft anyway: that 2026-08-10 table's stock
column was not measured that day (its own caveat says so), and ours read 11.727 on 08-09 vs 8.67
on 08-10 - a 26 % swing on one binary across one day, which now looks like the same session
variance rather than the `SweepDdaExempt` fix it was credited to.

**Second harness defect fixed in the same pass:** a phase where one side read 0.000 in EVERY
repetition was being reported as "ranges disjoint, REAL". A 5 s quiet window can leave the CPU
counter un-ticked; that is the sampler failing to resolve the rate, not a measurement of no CPU.
Both summarisers now refuse a verdict on it - the same missing-data-fails rule the harness already
enforced everywhere else, which I had left a hole in.

**The win10 verdicts stand** (2.3x-13x margins, taken at the same 8 s settle, so the same inflation
on both sides - a 36 % transient cannot manufacture a 13x gap). Direction safe; absolutes are upper
bounds until a re-run at 45 s replaces them.

**Ablation (win11, one binary, knobs only, 3 rounds):** no mechanism is attributable. base 13.826;
noslice 11.102 (-19.7 %), nopw 13.376, noevtprio 14.772, nofreeze 14.777 - every range overlaps
base's, spreads 22-47 %. `InputDragSlice` is the only suggestive one and it explains nothing at
this sample size. No quick fix exists to propose, and none was invented.

**Operational note, owner-reported and mine to own:** while these runs were in flight the owner saw
"an override-redirect piece of desktop on screen". The timeline puts it in the STOCK repetition
(that agent's log carries `Module version: 4.2.2.0` and it mapped three windows in ~80 s where ours
maps one) - stock has none of the 2A-chrome filtering and feeds shell surfaces from the desktop
framebuffer at their rect, which is exactly how one renders as a borderless piece of desktop. It is
stock's documented defect, not ours. **But benchmarking stock on a guest whose windows are on the
owner's real display means the owner watches stock's artifacts for 20 minutes, and I did not warn
them beforehand. Say so before starting, next time.**

Raw data: `instrumentation/bench-stock-vs-ours-20260901-120938/` (win11, 8 s settle, retracted),
`.../bench-stock-vs-ours-20260901-124616/` (win11, 45 s settle, authoritative),
`.../bench-ablate-20260901-122017/`.

## 2026-09-01 (cont.) — everything re-run at the fixed settle; both platforms reproduced twice

Owner: *"rerun everything with the fixed settle once again."* Done, both platforms, one Windows
guest at a time, 45 s settle after every swap.

**WIN10** (19045.6456, 5120x1440), 6/6 valid, every row disjoint:

| workload | stock 4.2.2 | ours 4.3.17 | delta |
|---|---:|---:|---:|
| scroll | 41.010 | 2.649 | -93.5 % |
| typing | 22.815 | 2.312 | -89.9 % |
| idle   |  3.906 | 0.498 | -87.3 % |
| drag   | 29.035 | 16.225 | -44.1 % |

**WIN11** (24H2 26100, 5120x1440), 6/6 valid, nothing distinguishable - and reproduced in a
SECOND independent session, where the drag delta CHANGES SIGN (+15.9 % session A, -3.0 % session
B). A difference that flips sign between sessions is a null result, not a small effect. Both
sessions: no verdict on any workload.

**Both platforms are now reproduced across two sessions.** That is the check that was missing when
I published the false "+59.9 % win11 drag regression": within-session disjointness was never
tested against between-session variance.

**Two harness defects, both found because the instrument refused to produce numbers rather than
producing bad ones:**

1. **Settle floor.** 8 s after a swap between two DIFFERENT agents leaves startup work inside the
   measurement and biases the side just swapped in. Now clamped to >= 30 s in code (default 45,
   `BENCH_SETTLE_S` raises it, a lower value is clamped up with the reason on stderr). Owner asked
   for >= 30 s; the floor is enforced rather than documented.
2. **Guest-readiness gate.** The first win10 re-run produced **6 of 6 INVALID** with an empty
   running hash. Cause: my chain script gated on `qtest run "echo up"`, which proves qrexec only -
   and qrexec answers as SYSTEM long before the interactive user logs on, while `qubes.Filecopy`
   targets the USER's Documents. So every push landed nowhere and `QubesIncoming` did not exist.
   This is the recorded `pushrun-needs-a-session` trap, walked into again. The harness now
   preflights for an ACTIVE console session and refuses to start without one, so no caller can
   repeat it. **The run cost 20 minutes of guest time and produced no wrong numbers** - the
   missing-data rule held.

**What the two-session pair settles.** On win10 the fork is 2x-15x cheaper than stock across the
board; on win11 it is indistinguishable. The mechanism is per-frame fixed cost, not pixels moved:
both agents use the same Desktop Duplication capture and the same grant-once transport, but stock
re-enumerates every top-level window on EVERY captured frame (its own `TODO: don't enumerate all
windows every time, use window hooks`) and has no redundant-frame check at all, while this fork
uses `SetWinEventHook` + a queued event drain and drops frames whose pixels did not change. That
cost scales with (window count x frame rate), so where a session is busy and the screen is large
it is enormous and we recover nearly all of it; where stock is already cheap - win11 - there is
nothing left to recover and we are simply level with it.

Raw data: `instrumentation/bench-stock-vs-ours-20260901-132224/` (win10, 45 s),
`.../bench-stock-vs-ours-20260901-130700/` (win11 session B, 45 s),
`.../bench-stock-vs-ours-20260901-124616/` (win11 session A, 45 s),
`.../bench-stock-vs-ours-20260901-131944/` (win10, 6/6 INVALID - the session-gate failure, kept
because a harness that fails loudly is worth a record).
