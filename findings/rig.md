# rig — findings

## CURRENT STATE

AUTHORITATIVE. Supersedes everything under History below. A correction belongs HERE,
not only as a new dated section — the whole reason this file exists is that 654
correction lines were buried chronologically in a 25k-line log, so reading a topic
top-down returned the stale answer.

- Not yet distilled from the history below. UNVERIFIED

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

# 2026-08-04 — T2 needs OUR driver to supply the modes (measured); T1 instrument rebuilt

> Heading corrected: this originally read "T2 is blocked on the IddCx driver". The framing was
> wrong — the mode list is ours to choose, not an external constraint. See the correction inside.

Guest quiesced first: `qvm-prefs win-idd-test netvm ''` (it was `core-net`). Lockout threshold
was already `Never`, so trap 4.3 cannot bite. `AutoAdminLogon=1` with **no** `DefaultPassword`
is still the configuration — left alone, since setting the password needs the user.

## T1 (validate aaa8c37): the first two instruments were both worthless — replaced

Deployed the CI build of agent `6b5b298` (`gui-agent.exe` sha256 4da9fe96…, verified against the
running file, `.orig` kept). Seamless survived it: Notepad and Word's NUIDialog both rendered
correctly in dom0, and with all four real `MSO_BORDEREFFECT_WINDOW_CLASS` strips present in the
guest (`dump-windows`: 0x10348/34a/34c/34e around dialog 0x10342), dom0 received **one** window
for that dialog, not five. That is the intended effect — but it is **not yet proven**, because:

- **Instrument 1 (count PNGs from `qtest shot`) is void.** The pre-fix control produced the same
  count as the fix. Worse, Word's strips are *transient*: four at 13:37, one at 13:41, none at
  13:42. The metric was tracking scene state, not the build — the exact trap CLAUDE.md warns
  about, hit again.
- **Instrument 2 (grep the agent log for strip HWNDs) was inconclusive**, for the same reason:
  the control run recorded `STRIPS_PRESENT=0`. Nothing was on screen to reject, so "0 mapped"
  proves nothing. Recorded as inconclusive, not as a pass.

Rule 3 is at least reachable, which was worth confirming before building a repro for it: the
strips are caption-less `WS_POPUP`, so `IsPopup()` marks them override-redirect and the size
floor drops from SM_CXMIN/SM_CYMIN (~136x39) to 4x4 — an 8 px strip survives it. Note this also
means rule 2 can never match them: the real strips carry **neither** `WS_EX_TRANSPARENT` nor
`WS_EX_NOACTIVATE`. Only the class rule can.

**Fix: `tools/chromerepro --mso`** (commits 1c94a62, then corrected) creates four strips of the
literal class `MSO_BORDEREFFECT_WINDOW_CLASS` with the measured styles — deterministic, and
independent of Office. The measurement harness now also fails loudly when the main window is not
mapped, so a dead gui-daemon can no longer masquerade as "the fix worked".

### The Office strip bug is a regression THIS FORK introduced (and instrument 3 was nearly void too)

The first `--mso` used Office's true 8 px thickness. That would have produced a fourth worthless
instrument, caught by reasoning before it produced a verdict and then confirmed on the guest:
the stock control run reported `STRIPS_PRESENT=4, STRIPS_MAPPED=0, MAIN_MAPPED=1` — daemon alive,
instrument working, and the strips still not mapped. **Stock rejects an 8 px strip on SIZE**, so
both sides would have read zero for different reasons: a check that cannot fail.

The mechanism, which matters well beyond the harness:

- `ShouldAcceptWindow()` applies the `SM_CXMIN x SM_CYMIN` (~136x39) floor only to
  NON-override-redirect windows. A caption-less `WS_POPUP` is classified override-redirect by
  `IsPopup()`, and those face a 4 px floor instead.
- That exemption is **fork-local**: agent `d6ab61c`, "Accept small override-redirect popups:
  keytip badges died on the SM_CXMIN floor", added to rescue Win11 Alt-nav keytip badges.
- Office's strips are 391x8 and 8x202 — under the old floor, over the new one.

So: **on stock QWT, Office's shadow strips never reach the chrome rules at all; they die on
size.** `d6ab61c` lowered the floor for popups and let them through as a side effect, and that
is what produced the strip adoption, the synthesis flip-flop and ultimately the `msg 0x86
without CREATE` gui-daemon kill. `aaa8c37` closes it.

The fix stands. Its **description** must change: it repairs a regression introduced by this
fork's own keytip-badge fix, not a long-standing upstream defect. Any upstream submission that
presents it as the latter would be wrong, and `d6ab61c` should be submitted (or at least
described) together with it, since alone it re-opens the hole.

Consequence for testing: **stock QWT is the wrong control for a thin-strip test.** `--mso` now
keeps a floor-clearing thickness (the class rule is size-blind, so this tests the rule
faithfully) and `--mso-thin` preserves the realistic 8 px geometry for use against fork builds
that contain `d6ab61c`.

Harness bug found the same way, worth recording because it is generic: the A/B installed each
side's binary by `Copy-Item -Force` over `gui-agent.exe` **while the agent was running**.
Windows locks a running image, so the copy fails; with `-Force` and no error check the harness
then measured the PREVIOUS build believing it was the new one. Caught by the hash readback
(`COPIED=4B4C…` on the side that should have been `4DA9…`). Stop the service before copying,
and always compare the installed hash to the manifest — CLAUDE.md's rule 3, earned again.

Two more harness defects, both caught by guards rather than by results, both worth knowing:
- **Multi-line PowerShell does not survive the `qtest ps` wrapper.** It arrives as literal text;
  all six sides "failed to install" without installing anything. Keep guest logic in pushed
  `.ps1` files, never inline blocks.
- **`grep -oE 'INSTALL=(OK|FAIL)[^\r]*'` truncates at the first letter `r`.** In a POSIX bracket
  expression `[^\r]` is "not backslash, not r" — there is no `\r` escape. `INSTALL=OK which=orig`
  became `INSTALL=OK which=o` and every side was rejected. Use `tr -d '\r'` and match on line.

# 2026-08-04 (end) — CORRECTION: a GRACEFUL agent restart does NOT kill gui-daemon

Found by the design workflow, verified on the guest immediately after. **Two claims I made
earlier today were wrong; both are retracted here.**

## Immediate consequences

1. **Tooling fix, no agent code needed:** stop the agent by signalling `Global\QGA_SHUTDOWN`,
   never `Stop-Process -Force`. `scratchpad/graceful-stop.ps1` does this.
2. **The A/B harnesses can stop cold-booting per side** — that was a workaround for a problem we
   were causing. Cold boot remains right for *boot-path* acceptance, not for every comparison.
3. The full design (guest-side options ranked, dom0 proposal, killed options, and the
   experiments that would settle attribution) is in
   `DESIGN-gui-daemon-restart-survival.md`. **dom0 items need user approval; nothing dom0-side
   has been touched.**

---

## Upstream policy set by the user — recorded in CLAUDE.md

> "we submit nothing until our work is done in full and we have new shiny qwt with all the
> features. until that everything stays in my fork." — "except bugs outside of qwt scope, those
> we report"

So: **nothing from `agent/` goes upstream** until QWT is complete — this withdraws CLAUDE.md's
earlier "small, measured, reviewable PRs" framing and settles the open question about how to
describe `aaa8c37` (it is not being submitted, so the question is moot for now; the regression
framing stays recorded for whenever it is).

**Bugs in components that are not ours are still reported**, because they are not part of the
deliverable and sitting on them helps nobody. Currently qualifying: the two gui-daemon defects in
`DESIGN-gui-daemon-restart-survival.md` §3 (the write-path EOF bypassing `vchan_at_eof`, and the
`restart_guid` use-after-free). Both still need the user to approve the exact text.

---

## Two more instrument failures caught by guards (not by luck)

1. **`qvm-kill` rolled back an install.** The guest hung, I killed it, and the binary on disk
   reverted from `768CA58C` to `F06C0979` — the verified install did not survive, because an
   unclean kill loses unflushed writes. The probe's hash gate caught it and reported VOID; without
   it the entire control run would have measured the *fixed* binary while believing it was the
   control. **Always re-verify the installed hash AFTER any unclean recovery, not just after the
   install.**
2. **The metric was invisible at the shipped log level.** `SendWindowDamageEvent` logs at
   VERBOSE, and I had reset `LogLevel` to 3 at handoff, so the first run read `damage_before=0`
   and would have been reported as "channel dead" had the gate not required a non-zero baseline
   before proceeding.

Both were caught because the checks were written to fail loudly on missing preconditions. That is
now three separate occasions today where a precondition gate turned a silent wrong answer into a
visible VOID.

---

# 2026-08-05 (cont 2) — D3 spike NEGATIVE with valid control; A6 stack + A7-lite built; D4v2 in CI

**D3 (runtime IddCxMonitorUpdateModes on console): NEGATIVE.** Spike driver C0F48F3B
(monitor list incl. 1600x1000, target list excl., thread adds it via UpdateModes ~60 s after
arrival). Measured: T+10s 1600x1000 BADMODE / control 1600x900 SUCCESSFUL; T+90s (timer
fired) 1600x1000 STILL BADMODE / control still SUCCESSFUL. The OS does not re-intersect for
a console IDD on 19045 — consistent with MS Q&A 5924412 and driver-samples#1184. Caveat: the
spike logs nothing driver-side, so "UpdateModes returned an error" vs "OS ignored it" is not
distinguished; either way no console path exists here. Replug (stable-EDID, D4v2) is the
mechanism, exactly as the hypervisor survey predicted.

**A6 implemented** (agent branch t2/a6-grant-lifecycle, commits 67561e0 / 7b73bf8 / 57205f8,
worktree-isolated build; details in the agent report): in-place geometry survival with
ctx-derived sizing, park+ack-gated old-grant revoke with 5 s timeout fallback onto a retry
sweep, bounded 2 s exit drain with ring-headroom guard. Plus **A7-lite** (d256b51, mine):
StartFrameProcessing retries 10x750 ms on 0x887A0026/0x887A0005 instead of dying — the
stress-identified crash class. Parent branch t2/a6-stack (CI 30951775933).

# 2026-08-05 (cont 3) — STRESS GATE PASSED 16/16 ON THE A6 STACK; boot acceptance PASSED

**The A6+A7 agent (6254ECF1, branch t2/a6-stack) passed the same stress that killed the A1
agent twice at cycle 9** — 16/16 cycles, every size exact (1600x1000, 1920x1080, 2566x1022,
1024x768, 1234x777, 3440x1409 = the real work-area size, 1600x900, 2000x1000, twice each),
qrexec alive throughout, dom0-follow latency 2-3 s at every checkpoint, ONE agent instance
across the whole run. The two prior A1 failures ARE the control-that-fails for this pass.
A6 machinery visibly load-bearing: A6PARK=18, A6ACK=18, A6REVOKE=16 (ack-gated),
A6ACKTIMEOUT=0, **A7RETRY=3** (the retry saved the process three times), A6LEAK=1 (one grant
never became revocable and was leaked LOUDLY — the designed fallback; watch the counter).

**Boot acceptance:** revert net disarmed deliberately (IDD-primary is now the intended
config; recovery path documented: qrexec works headless → re-arm marker → reboot), cold
boot → A6 agent up, IDD PRIMARY, BDA stayed disabled, display numbering RESET to DISPLAY2
(identity churn was session-scoped), fresh-boot sync to 2566x1022 ok=True, dom0 window
2566x1022 live pixels.

**Instrument disclosure:** the stress cputime/livelock slope check was silently a no-op in
ALL runs — the Admin API response embeds a NUL, grep went binary-mode, and my harness
"skip-if-empty" guard hid it (the exact 'a check that cannot fail' anti-pattern, again).
Fixed (tr -d '\0'). Livelock absence in the passing run is evidenced by qrexec liveness,
sync timeliness, and follow latency — not by that metric.

**D3 negative stands; D4v2 (stable EDID) still broken** — monitor never arrives, root-cause
hunt with the driver agent in progress; D4 v1 (identity churn per replug, session-scoped)
is the working driver meanwhile.

**Remaining for the full goal demo:** a live dom0 window DRAG with the sync loop running
(loop started on the guest). The dom0-originated request chain itself is already proven
(RESREQ src=dom0 measured from the user's manual drag on 08-04); scripted drag needs the
_QUBES_VMNAME resize service variant.

# 2026-08-05 (close) — ACCEPTANCE SOAK PASS 30/30 on the no-PnP stack; the stability arc closes

Stack: agent A8621D1F (staging grant + exact-follow + input resilience + IOCTL reload) +
driver 57eb5004 (D4v3: IOCTL_QIDD_RELOAD_MODES, monitor-level replug, no PnP).

**SOAK PASS: 30 cycles, 10 graceful agent restarts, 6 reboots, ZERO reverts, ZERO wedges,
all pixels live, every size exact** — including cycle 3 + restart, the exact pattern that
killed three earlier builds (those failures are the controls that fail). Sizes persisted
across every restart and reboot (2340x1100, 1650x950, 2200x1234, 1876x1004, 2464x1200,
2016x1160).

The three-layer fix that got here, each layer evidence-driven:
1. **Staging grant** (one grant per agent lifetime) — removed the grant-revoke churn that
   fed the xenbus revoke spin (NMI-dump-proven).
2. **IOCTL monitor-level reload** (driver replugs its monitor internally) — removed the
   full-device PnP storm that killed Xen event-channel delivery (qrexec deaths).
3. **Input resilience** — a denied SendInput can no longer kill the agent.

Remaining known defect, now the ONLY recurring one: **gui-daemon's EOF coin-flip death on
agent exit — 6/10 restarts** in this soak. It is the dom0-side bug documented in
DESIGN-gui-daemon-restart-survival.md §3, upstream report awaiting user approval; guest
recovers by qube restart. Honest scope note: real interactive drag streams (WM configure
bursts) remain validated only by the user's manual drags; every machine-drivable layer of
the same path is soak-proven.

Upstream drafts now pending user approval: gui-daemon EOF (2 defects), xl console overflow,
xenbus/xeniface revoke spin. All in docs/ + DESIGN-gui-daemon-restart-survival.md.

# 2026-08-05 (addendum 3) — SyncNow harness retired: it now races the agent it tests

The rapid-pair machine check "failed" (2345x999 mode_never_offered) because of the harness,
not the agent: the agent's echo-follow processed the daemon's echo of the harness's first
apply through its FULL native path — RESREQ src=dom0 → WriteRequestedIddMode(2222x1111) →
QIDD ioctl-reload → RESEXACT replug=1, ~420 ms — and its registry write raced the harness's
write of the second size. Two writers on HKLM\SOFTWARE\QubesIDD\Modes: the agent is now the
rightful owner; resize-sync.ps1 -SyncNow is RETIRED as a resize-testing tool (still fine as
a one-shot recovery hammer when no agent runs). Incidentally this was the first complete
live validation of the agent-native loop end to end, echo-triggered.

Consequence for testing: machine-driving the agent's obtain path requires REAL MSG_CONFIGURE
traffic — i.e. the _QUBES_VMNAME-based dom0 resize service (v2, written, awaiting the user's
one-command reinstall) or the user's hands. Soak harnesses must not touch the modes registry
while the agent runs.

# 2026-08-06 (cont 3) — M1 + M0 delivered; registry swept; exp-9 harness parked

**M1 stable EDID: ACCEPTED** (driver 70C64039). `Enum\DISPLAY\QBS0001` = ONE instance,
stable across replugs AND across a cold boot; session GDI name stable too. Identity churn
is structurally over.
**Registry hygiene: swept.** guest/registry-hygiene.ps1 (conservative: Default_Monitor
phantoms only, diffed against Get-PnpDevice -PresentOnly; QBS0001 never touched). Admin run
reported 6 phantoms LOCKED (Enum keys are SYSTEM-ACLed); re-run as SYSTEM via a one-shot
scheduled task removed all 6 → Default_Monitor down to 1 instance. Record that: the sweeper
must run as SYSTEM, not admin.
**M0 blink instrumentation: DELIVERED and measured** (agent 0A105F60). First real
decomposition of a novel-size blink: obtain-start → reload-returned **16 ms** →
mode-offered **281 ms** (1 poll) → applied **344 ms** → repaint-sent **813 ms**. So the
IOCTL reload is nearly free, the driver's mode-offer latency (~265 ms) dominates the
pre-apply half, and **the post-apply repaint path costs ~470 ms** — the single biggest
remaining lever, and it is agent-side (capture recreate → re-grant → re-dump → ack →
repaint), not driver-side. Habitual sizes remain 0 ms (replug=0, no blink at all).
**One more livelock, one more gate:** the single-pass exit revoke still wedged a shutdown
(slope 3). Exit revokes are now attempted ONLY when the daemon is gone (dead vchan); with a
live daemon the grants are leaked BY DESIGN and loudly — the daemon still maps them, so the
revoke cannot succeed and can only lose the xenbus race. Deployed, boot verified.
**Snap regression battery** (scratchpad/snap-regress.sh, user directive): near-half snaps,
20px-off and arbitrary sizes do NOT snap, window position preserved — **PASS 4/4** on the
current stack.
**exp-9 formal record: PARKED.** The harness stops on its own persistence check (empty
string reaches check_persist despite a validating/retrying mp_json); the guest and topology
were healthy each time. Debt, not a defect in the product; script is committed for a later
debugging pass.

## 2026-08-07 — the clean-room route's FIRST run exposed two harness defects (both mine)

The run failed within seconds, and both causes were checks that could not do their job -
the same class this file keeps recording:

1. **A check that could never PASS.** The answer-disc assertion I had just written used
   `qvm-device block list "$VM"`, and this qube has NO PERMISSION for that call (it answers
   "Failed to list 'block' devices ... you do not have access"). So the assertion failed on a
   run where the assignment had in fact succeeded. Verified afterwards the permitted way: a
   SECOND `qvm-device block assign` answers *"block device win-idd-mgmt:loop1::1 already
   assigned to win10-clean"* - which is positive proof the first one stuck. That is now the
   check.
2. **A check that could never FAIL.** `reprovision.sh ... | tee -a log || fail "..."` judges
   TEE's exit status, not reprovision's. reprovision exited 1 and the harness sailed past it,
   printing "waiting for the release install to complete in-guest" about a guest that had
   never been started. Now judged via `${PIPESTATUS[0]}`, and the guard was demonstrated to
   catch a deliberately failing command before being trusted.

Both fixed and relaunched. Worth stating plainly: the assertion in (1) was written *because*
a silently-missing answer disc is indistinguishable from "the answer file was ignored" an
hour later - and it was written in a form that could not work. Permission-dependent commands
must be exercised once by hand before they are used as gates.

## 2026-08-11 (cont.) — GWeck investigation workflow landed; correlation with the LIVE repro

Full synthesis saved to docs/GWECK-post44-investigation.md (root causes S1-S4, serial repro plan,
DRAFT forum reply, open questions). Key points and how they line up with the live win11-fresh repro:
- S1a garbled Start (25H2): Wnd_StartFeed full-screen popup demoted to NORMAL by IsPopup (main.c:826,
  '>=' fires on screen-size equality) -> PrintWindow-fed XAML host -> garble; all g_StartWindow
  special-casing is DEAD on 25H2 (no CoreWindow). MATCHES my repro's sibling-path note; my 24H2 repro
  hit the CoreWindow path instead (same symptom, both bad).
- S1b dom0 dialog: PROVEN by elimination it is MSG_CREATE with (int)width/height<0 (xside.c:2937); the
  SOURCE of the negative value is UNEXPLAINED (g_StartWindow inversion REFUTED - NULL on 25H2). My live
  24H2 repro FALSIFIED the EnumDisplaySettings-div0 candidate here (clean scale=1) -> the dialog is
  genuinely 25H2-only; needs a 25H2 target + GWeck's guid log to name the failed VERIFY.
- NEW from the live repro (the static workflow under-weighted this): the ACTUAL freeze mechanism on
  24H2 is the Start map/unmap FLIP STORM -> VchanSendBuffer full -> CaptureThread error/timeout ->
  capture thread DIES and does not recover (RecreateDuplication never fires; the watchdog only restarts
  a DEAD process, not a stuck-capture live one). Recovered by killing gui-agent.exe (watchdog relaunched
  it, frames resumed). This is a reproducible guest-display DoS independent of 25H2.
- S2 mouse ~1cm-low + S3 caret: agent stores the REQUESTED (not read-back APPLIED) resolution on
  RESAPPLIED-MISMATCH (resolution.c:1207) + missing SDC_FORCE_MODE_ENUMERATION poke -> injects pointer
  against a wrong believed height -> vertical-only skew. Per the workflow this is REPRODUCIBLE ON 24H2
  via a forced A4CLAMP request (next reproduce-first target, no 25H2 needed).
- S4 /idd: user error (Start-Process 'D:\idd') on top of OUR gaps - /iddonly + activate-idd.ps1 were
  committed (80f8d97) ~4h AFTER the v4.3.1 assets were uploaded, so they never shipped; README is stale.

QUEUED (reproduce-first discipline, per user): (1) provision a 25H2 test target - user/dom0 decision,
gates S1a/S1b validation;
**[FALSE BLOCKER on item (1) — corrected 2026-08-29, and self-refuted 29 lines below: the very next
entry, "25H2 TARGET LIVE", records this same session creating `win11-24h2` from a halted
`win11-fresh` and DISM-ing the 25H2 eKB, entirely from this qube. Provisioning a target is
`admin.vm.Create.*` + `admin.vm.tag.Set` + `volumes[...].clone()` (use `clone_vm(...,
ignore_devices=True)` to dodge the non-`block` device-class refusal). Only the decision to SPEND
the disk is the owner's, not the mechanism.]** (2) reproduce S2 on 24H2 via A4CLAMP + measure skew 3x interleaved before any
fix; (3) the S1b structural guard (SendWindowCreate (int)w/h>0, mirroring send.c:600) validated by
INJECTING an inverted rect and seeing the dialog with guard off / suppressed with guard on; (4) re-release
containing 80f8d97 + README fix. No fixes committed yet - all gated on their own repro.

## 2026-08-11 (cont.) — CLOCK FIXED (harness-side); in-guest settings CANNOT hold it

Attempted, in order, each verified by 4-5 sample offset measurement + a COLD REBOOT:
1. `RealTimeIsUniversal=1` + Set-Date to true UTC -> offset went +10801.8 s -> -0.216 s. **Reboot
   re-broke it: +10686 s.**
2. `RealTimeIsUniversal=0` + TZ `FLE Standard Time` (+03, matching dom0) + Set-Date -> -0.173 s.
   **Reboot re-broke it again: +10684.7 s** (guest UTC 18:52 vs true 15:54).
CONCLUSION (measured, not assumed): the guest's virtual RTC is re-derived from dom0's LOCAL wall
clock at every domain start, and guest RTC writes are DISCARDED when the domain is destroyed. No
in-guest setting (RealTimeIsUniversal either way, timezone either way) survives a reboot. The
residual is not a constant 3 h either - both boots landed ~115 s short of exactly +3 h, so the
error is not even predictable enough to subtract.

FIX SHIPPED: `tools/qtest synctime` — pushes this qube's clock into the guest, accurate to
**median -0.009 s** (5 samples, verified on a FRESHLY BOOTED guest, i.e. the boot path is the
tested path). Gotcha found and fixed while building it: the one-way-latency probe must be the
same SHAPE as the setter — probing with `cmd /c echo` while setting via powershell under-estimated
latency by ~0.7 s and left the guest that slow.
USAGE RULE: call `qtest synctime` after EVERY `qtest start`, before any measurement whose
timestamps will be compared to dom0 logs. Harnesses should do it unconditionally.
PERMANENT FIX (dom0, user-only): `qvm-sync-clock` / letting dom0 drive `qubes.SetDateTime`
(the handler `set-time.ps1` IS installed in the guest and would be correct), or changing the
domain's RTC basis to UTC. Not attempted - dom0 is out of scope for this qube.
Guest now left at TZ=FLE Standard Time (+03) so its wall clock reads the same face as dom0 logs.

## 2026-08-11 (cont.) — RENDERING-CORRECTNESS INSTRUMENT + a retraction

Built `tools/rendercheck` + `guest/render-truth.ps1`: compares GUEST truth (full-desktop capture
+ every visible top-level window) against what dom0 actually renders, per window, in pixels.
Verified working: Notepad 0.0% differing on a clean run, 0.41% with a caret blinking.

**RETRACTION (same-day, loud, per CLAUDE.md):** I claimed "with the Start menu open, dom0 has NO
window for it — the S1a defect, caught automatically." That was WRONG. It came from `qtest shot`,
which is per-window and CANNOT show override-redirect windows — and Start is override-redirect.
`tools/qtest`'s own comment (line ~48) says exactly this, and I used the wrong capture anyway.
The user confirmed dom0 DOES draw it: "thin border, with some extra stuff within rectangle".
STANDING RULE going forward: **any claim about what dom0 displays must come from `qtest fullshot`**
(its geometry.txt carries the override_redirect + mapped columns); per-window `shot` may only be
used for pixel comparison of ordinary windows. rendercheck now runs fullshot and treats its
geometry list as authoritative; the raw list is printed in every report.

Two real defects the instrument found in its own first runs (both fixed in it):
1. Guest truth must use DWMWA_EXTENDED_FRAME_BOUNDS, not GetWindowRect: Win11's ~7 px invisible
   border made Notepad read 1440x753 while the agent announces (and dom0 renders) 1426x746.
2. P/Invoke needs CharSet=Unicode or every window title marshals to its first character only.

STILL OPEN (the real S1a work): characterise the "extra stuff within the rectangle" the user sees
in the Start popup. Requires a fullshot taken WHILE Start is held open - ordinary qrexec calls
steal focus and dismiss it, so the keypress and the capture must run concurrently (attempted
once; the menu had already closed both times).

Also visible in the dom0 terminal during this session (relevant to the clock work): `qvm-sync-clock`
fails with "ClockVM sys-whonix is not running, aborting!" - so the permanent dom0-side clock fix
needs sys-whonix running (or a different clockvm). `tools/qtest synctime` remains the workaround.

## 2026-08-12 (cont.) — Workflow audit of the evidence corpus (5 agents, wf_e1ebbf98)

Corrections to the handover's "established facts", from re-reading the RAW pulled logs:
 - **F2's "guest window static while agent announces motion" is VOID**: both pos-sampler
   runs backing it recorded ZERO movement for the entire session INCLUDING the commanded
   drag - the instrument never observed the event. No evidence the guest window was static;
   the async-SetWindowPos-queue mechanism requires it to MOVE, and nothing contradicts that.
 - **F1's "zero inbound configures at VERBOSE" is unverifiable**: not one Debug/Verbose
   line exists in any preserved pull, and HandleConfigure only logs at those levels. It was
   also scoped to DURING-drag at best; the replay lives after release.
 - The 12:22/12:28 (pre-c9481cb) traces show the second pass with re-generated values
   (429/234 for 431/236, one value dropped) - not a byte-replay of a queue; on c9481cb the
   second pass is exactly +7 px in x. Both fit re-generation through the winrect-vs-DWM
   coordinate seam, not ring drainage.
 - Daemon side (xside.c): NO animation/deferred moves - the ring is the only replay tape it
   drains (in order, one XMoveResizeWindow each); handle_configure_from_vm BOUNCES any
   non-matching agent configure back with its own geometry (sequence-number-free protocol,
   known to spin); ACK byte-echoes are indistinguishable from announces in ProtoTrace
   (fixed: QGAPROTO,msg=CONFIGURE-ACK tag, agent 0057c7a).
 - c9481cb's rate limiter also had 3 latent bugs (stale pending never invalidated; pending
   surviving HandleConfigure's dictated position; flush unreachable for Pw-attached windows
   which are the DEFAULT) - all three are structurally fixed by the 9f6ac17 flush rewrite
   (flush current canonical X/Y, skip byte-identical, Pw-branch call site added).

## 2026-08-14 — locale audit: one real protocol bug, and a retraction of my own fix rationale

A 14-agent audit of every locale-dependent assumption confirmed 2 findings and rejected 8. The
rejections were correct and worth recording: Start Menu paths have not been localized since Vista,
and the `~xx-XX~` tags in CBS package identities are identifiers, not localized text.

### CONFIRMED and FIXED: every progress line was unparseable on a German guest

`guest/wu-update.ps1:25` formatted dom0 progress with `"{0:0.0}" -f $p`. PowerShell's `-f` uses
CurrentCulture, and in a CUSTOM numeric format string the "." is the decimal-separator PLACEHOLDER,
not a literal. dom0 parses progress with `float(line)`, and `float("75,0")` raises.

Measured on the English guest by forcing the culture in-process, with the defect as a control:

    culture   culture-bound      invariant (shipped)
    en-US     '75.0'  ok         '75.0'  ok
    de-DE     '75,0'  BREAKS     '75.0'  ok
    fr-FR     '75,0'  BREAKS     '75.0'  ok
    ru-RU     '75,0'  BREAKS     '75.0'  ok
    control (defect re-introduced under de-DE) produced a comma = True

So on GWeck's German edition EVERY progress line, starting with the first, was unparseable and fell
through to being displayed as a message. Fixed with an explicit InvariantCulture format. `Prog` is
the only number crossing the protocol; the other stderr writes are text.

### RETRACTED: "windows11.0 vs windows10.0 separates client from server"

I wrote that into the resolver comment and the commit message without checking it. Measured, it is
false - SERVER packages are also named windows11.0-*:

    "2026-08 Cumulative Update for Microsoft server operating system version 24H2 for x64-based
     Systems (KB5120233)"  ->  windows11.0-kb5120233-x64_9344a2fc....msu

What the family check actually buys is separating Windows 10 packages from Windows 11 ones. The
real client/server separator is the KB NUMBER, which is product-specific: 24H2 cumulative is
KB5121003 client / KB5120233 server, .NET is KB5120710 client / KB5120708 server. Measured:
KB5121003 returns four rows, all client (24H2/25H2 x x64/arm64), no server row at all.

### The audit's own central claim was also wrong, and measurement settled it

It argued a "Dynamic Cumulative Update" row carries the SAME KB as the LCU with a near-identical
filename, so only a DISM applicability check could separate them. Measured - both halves are false:

    Safe OS Dynamic Update ... (KB5121002)  ->  windows11.0-kb5121002-x64_....CAB
    Setup Dynamic Update   ... (KB5106084)  ->  windows11.0-kb5106084-x64_....CAB

Dynamic Updates ship .cab, not .msu, so the existing `\.msu` filter drops them outright; and they
carry their own KB numbers, so a KB search never returns them beside the cumulative. No
applicability-fallback machinery is needed. The English `Dynamic` keyword was never load-bearing.

Also seen: the server cumulative KB5120233 bundles the SAME superseded kb5043080 that broke us, so
that bundling is a catalog-wide pattern rather than something specific to KB5121003.

### Incidental, and a rule for this repo

A CJK stem added to the ranking hint was mangled to '?a??a?' in transit and broke the parse -
caught by `ps-syntax-check.ps1` before deploy. Files under `guest/` cross qrexec as ASCII: keep
them ASCII-only.

Re-verified after all edits: syntax clean, and KB5121003 resolves to the identical file across
en-US/de-DE/fr-FR/ja-JP.

## 2026-08-15 (night) — the rest of the list: three more fixes, one honest "unproven"

Driven by workflow wf_cdf94a84 (4 defects, each diagnosed then attacked by an adversary).

**1. A second writer of the agent's mode set - REMOVED.** `guest/resize-sync.ps1` wrote
`HKLM\SOFTWARE\QubesIDD!Modes` as a SINGLE-entry list (`-Value @($size)`) and replugged the device.
That does not merely race the agent's publication, it destroys the set: the target slot, the LRU of
recent dom0 sizes, the habitual work-area sizes, and the host entry that seamless REQUIRES (without
it the seamless force fails DISP_CHANGE_BADMODE). It was the v0 prototype of a loop whose production
home is the agent - its own header says so - nothing called it and it never shipped in a package, so
it is deleted rather than defanged. (The reviewing agent preferred making it read-only; deleting a
destructive stray that git history still holds is the smaller surface.)

**2. A ceiling we do not have is not a ceiling of zero - FIXED.** `SelectSupportedMode` filtered
every candidate against `g_HostScreenWidth/Height`, which are 0 until HandleXconf assigns them and
stay 0 if msg_xconf carried zero (nothing validates it). At zero the filter rejects EVERY mode and
the tail returned index 0 - an arbitrary adapter mode, unrelated to the request and not even inside
the ceiling just enforced - which SetVideoMode then PERSISTS as FullscreenWidth/Height, so the next
boot asks for it again. Unset bounds now mean no ceiling; a genuine no-fit returns MAXDWORD ("no
opinion") and the guest keeps its current resolution. Reachability, not oversold: with the IDD
present the exact-follow path bypasses this function, so it matters mainly for a non-IDD guest and
for anything reaching the snapper before xconf. `ModeCeilingFaultInject` re-introduces it - and on
an IDD guest it MUST be paired with `ModeSnapFaultInject=1` or the run proves nothing, which is
exactly the trap this project keeps falling into.

**3. Two guest-log defects - FIXED.** `GetWindowData` logged every dead-window race at ERROR
(E_HANDLE from DwmGetWindowAttribute when a window closes between enumeration and measurement) -
dozens of lines a minute on an idle guest, which is how a real failure gets missed; only that one
status is demoted. `WorkAreaApply` had the worse one: it stored `g_WaLastApplied` BEFORE attempting
the apply, so a REFUSED apply was remembered as applied - the next pass saw "unchanged", returned
early, and the guest kept a work area Windows never accepted with nothing retrying it. The rect is
now clipped to the desktop that actually exists (dom0's feed describes dom0's window; the guest
desktop can legitimately be smaller, briefly so during a mode change), the refusal names the
rectangle and the desktop, and the applied rect is recorded only after Windows accepts.

**UNPROVEN, and said so rather than proxied:** the work-area fix. The failing condition
(SPI_SETWORKAREA refused every 30 s) was observed on win11-fresh but could NOT be reproduced on
win10-tpl - in fullscreen with no dom0 work-area feed `WorkAreaApply` never runs, and forcing a
smaller desktop behind the agent's back did not take. It is correct by construction (recording an
apply that was refused is plainly wrong) but it ships without a defect-present/defect-absent pair.

## 1. VERDICT MATRIX

Legend: cells are judged under the current shipped code. "Scan-as-answer" (honesty of the reported number) vs "scan-as-pass" (the guest survives and completes) are judged separately where they diverge.

### Win10 22H2

| Cell | Template (netvm-free) | StandaloneVM | AppVM |
|---|---|---|---|
| **scan** | **UNRELIABLE** — answer honesty is deterministic (proxy scan proven: 8 updates, exit 0x0, zero adapters; give-up guard prevents false zeros), but the *pass itself* is the proven trigger context of a whole-guest kernel freeze (2026-08-19 wedge fired mid-Sync-Revocation of a back-to-back pass; relay vchan churn implicated). Also: task-#14 truncation can still cost a pass (honest exit 75), and a dead relay squatting :8082 is an unfixed proven-once path. | n/a — must skip. Offline skip **RELIABLE** under current classifier (skipped-standalone, zero relay bytes). Direct-internet branch **UNPROVEN** (only exercised under the retired discriminators; re-run Test-DirectInternet/NoAutoUpdate-undo under the live-qubesdb classifier). | n/a — must skip. **UNPROVEN** — the live-qubesdb `/type=='AppVM'` branch has never run on a real AppVM (the full-witness proof used the retired RootIdentity stamp). Test: boot a real Win10 AppVM, assert skipped-appvm + zero relay bytes/processes. |
| **download** | **RELIABLE** — 729.7 MB one attempt, zero resumes, verified size+magic; rides CONNECT (byte-perfect, immune to the plain-HTTP truncation). Residual: shares the guest with the churn-freeze exposure until the relay fix lands. | n/a | n/a |
| **install** | **UNPROVEN on the template proper** — full drain 19045.2965→.6456 proven on win10-clean (same image, Standalone rig) incl. the msu→cab rc=50 workaround; no install has ever run on win10-tpl itself. Test: one dom0-driven drain on win10-tpl with UBR + CBS state=112 acceptance. Deterministic known gap (not flakiness): non-catalog KBs (Defender defs, MSRT, UHT, KB5066747, KB5001716) fail honestly every pass. | n/a | n/a |
| **boot** | **UNRELIABLE** — (1) the 4h kernel-freeze wedge (attributed to relay-churn-triggered PV-driver spin class, final stack pending NMI dump); (2) ~1-in-5 fresh-build first-boot-with-vif reset, resetter unknown (probe armed: catch-firstboot.sh). | **RELIABLE** — autologon incident fixed (unlimited autologon + re-arm), reboot-survival proven. | **UNRELIABLE** — first-boot no-GUI ("Awaiting for a vchan client", 3/3 on one lineage), trigger unidentified; self-heal guard never seen to fire. Probe on record: A/B clone from display-experimented vs clean source. |

### Win11 (24H2 lineage)

| Cell | Template (netvm-free) | StandaloneVM | AppVM |
|---|---|---|---|
| **scan** | **UNRELIABLE by shared exposure** — scan mechanics proven (win11-tpl, win11-clonetest; Sync-Revocation self-heal 3/3 second-lineage), but the relay/pass structure is identical to the one that froze win10-tpl and the churn fix is not implemented; no wedge probing has ever run on Win11. One honest scan-failed already occurred (2026-08-19). | n/a — **UNPROVEN**: skip has never been tested on Win11 (win11-fresh historically ran the FULL pipeline as the stamped rig — that proves the pipeline, not the skip). | n/a — **UNPROVEN**: never run on win11-app. |
| **download** | **RELIABLE** — 4867 MB @ 12.8–15.2 MB/s, single attempt, verified. | n/a | n/a |
| **install** | **RELIABLE** — 26100.8875→.9168 (KB5121003) CBS-clean with superseded-sibling filter + applicability check + one-package-per-session serialization; 25H2 .NET KB5120708 rc=3010. Caveats: the one-package rule rests on n=2 on one image (ALLOW_MULTISTAGE hook kept for re-falsification); 25H2 as a *template* and any feature update never driven. | n/a | n/a |
| **boot** | **UNPROVEN** — no wedge recorded, but the win10-style wedge/Defender-idle probing has never run on Win11. Test: register wedge-telemetry boot task + TaskScheduler Operational log, soak template boots. | **RELIABLE** — healthy long-lived (win11-fresh). | **UNPROVEN (n=1)** — one good boot (win11-app, IDD active). |

**DispVM (both platforms): UNTESTED** — falls through to the AppVM skip branch by code read; never executed. Test alongside the AppVM cell.

## 2026-08-20 (cont) — large-download acceptance: PASSED, but only on the second attempt; the first was a null result

### Take 1 — DISCARDED, and recorded as discarded

Ran a `-Action download` pass with the fixed relay and got `stream ended early` occurrences: 0,
16MB-boundary cuts: 0. That looked like a pass and is NOT one. The pass lasted 90 s, every PLAIN
line in it was a ~7 KB metadata fetch, and the "fetched file now" line never printed: MSRT is
already installed, so the pass had nothing large left to fetch. Zero truncations out of zero large
transfers is a check that could not fail. Reported as void rather than as a green light.

### Take 2 — a real transfer, single request, decisive

Reconstructed a genuine large plain-HTTP URL: the relay log truncates its request line at 120
chars, but that was enough to recover the path prefix
(`/c/msdownload/update/software/secu/2025/09/...`) and the full filename came from the payload
still on disk. Fetched it with ONE `HttpWebRequest` through 127.0.0.1:8082 and no resume loop, so
the relay alone decides how many bytes arrive:

    URL             http://download.windowsupdate.com/c/msdownload/update/software/secu/2025/09/
                    windows10.0-kb5066130-x64-ndp481_06046fee...cab
    HTTP status     200
    Content-Length  79,240,605  (75.57 MB)
    received        79,240,605  (75.57 MB)   shortfall 0
    time            22.4 s, ONE request
    relay log       PLAIN tries=1 bytes=0 body=79240605/79240605 complete=True streamed=True

75.57 MB is 4.7x MaxVerifyBytes. `streamed=True` is the spill path doing exactly what it was built
to do. Against the recorded control the old build stops at ~16.8 MB (16 MB + one 64 KB read +
headers) and hands that over under the original 200 - the behaviour the resume ladder was papering
over. Binary under test verified in the same run: 43520 bytes / 978240E3C7D509DA, --selftest 8/8.

So the truncation fix is now demonstrated end to end through qrexec/vchan, not only in the
unit-level selftest.

### Two deviations, both deliberate, both reverted

1. **TWO Windows guests ran at once** (win10-tpl for this test while win11-fresh stayed up). That
   breaks the standing one-guest-at-a-time rule and was an explicit owner exception for this run
   only - NOT a new pattern, and not to be repeated. Contention was noted as a risk to timing
   numbers; the acceptance criterion used (bytes received vs Content-Length) is immune to it.
2. **The relay's peer allowlist was disabled for the test run** (`QUBES_UPDATES_PEER_ALLOWLIST=off`)
   because the test process is not the update process. That gate decides WHO may use the proxy and
   has nothing to do with response framing, so it does not weaken the result - but it must never be
   left off. The relay was killed afterwards and verified stopped; the updater restarts it on
   demand with a clean environment, gate on. Both test scheduled tasks were removed and verified
   gone.

---

## 2026-08-20 (cont) — user=SYSTEM policy line is LIVE, and it REFUTES the "win11-fresh is user-bound" theory

Owner added the policy line (placed FIRST - qrexec policy is first-match-wins, and an earlier
`qubes.VMShell ... allow` would have made a later line dead; the first attempt measured exactly that
and returned the default user).

VERIFIED LIVE, one command:

    printf 'whoami\r\nexit\r\n' | qrexec-client-vm win10-tpl qubes.VMShell
    -> nt authority\system          (before the line: win-idd-test\user)

So pre-session qrexec now works on the testbed. This closes the 2026-08-13 "a Windows qube at the
sign-in screen is UNMANAGEABLE" hole: with `user=SYSTEM` the child runs on QrexecAgent's own
LocalSystem token, no logon required. Autologon stops being the only lifeline.

### The refutation

With that capability in hand, win11-fresh STILL does not answer:

    win10-tpl   qubes.VMShell (SYSTEM)   rc=0, whoami = nt authority\system
    win11-fresh qubes.VMShell (SYSTEM)   rc=124 hang (60 s)
    win11-fresh qubes.VMExec  (SYSTEM)   rc=124 hang (40 s)

The SYSTEM path needs no session, no logon and no user token, and it is proven working on the
control in the same minute. Therefore win11-fresh was NEVER a no-session problem. Both the owner's
"user-bound" hypothesis and my "starved by servicing" framing are wrong as stated: the qrexec agent
is not being serviced AT ALL.

### What the CPU says

    cputime deltas over 20 s samples: 2.80, 2.88 cores of 4
    ~70-73% sustained, flat, for ~2 hours

Steady-state burn with zero responsiveness is SPIN, not work. Servicing fluctuates and is I/O
bound; a `pause` loop pegs cores flat. That is the signature of the wedge diagnosed from the
2026-08-20 NMI dump (CPUs spinning in nt!KeFlushMultipleRangeTb on _KPRCB.PacketBarrier waiting for
a TLB-shootdown IPI that never lands).

IF CONFIRMED, THIS CORRECTS OUR OWN ROOT-CAUSE ENTRY: win11-fresh was NOT running the relay soak -
it was booting and servicing. The current entry names per-fetch relay churn as the trigger. A wedge
here would mean the trigger is ANY heavy concurrent MM teardown (servicing generates plenty), and
relay churn was only the fastest provocation we knew. Not claimed until a dump says so - flagged
here so the churn attribution is not treated as settled.

Capture proposed to the owner (needs dom0 `xl trigger <domid> nmi`). The analysis toolchain is
ready and proven: vol3 + the DumpType-6 crash-layer patch + msdl ISF build + the per-CPU walker.
Caveat recorded: win11-fresh's dump settings were never configured by us and cannot be read while
it is unreachable, so the capture may come up empty.

---

## 2026-08-21 — the fork is wired into CI and BUILDS; two build defects found and fixed on the way

`core-agent/` (arkenoi/qubes-core-agent-windows) now builds in the gui-agent job, which already
stages the exact dependency set it needs (libvchan, xencontrol, windows-utils, qubesdb-client).
Artifact `gui-agent-package` from run 32422134646 contains:

    qrexec-wrapper.exe    27,136 bytes   <- carries the U15 drain fix
    qrexec-agent.exe      33,792 bytes
    qrexec-client-vm.exe  14,848 bytes   (+ .pdb for each)

Two real defects surfaced, both of the "green build that is not actually building the thing" family:

1. **`relocate-dir` needs the WDK.** Building the whole solution failed on
   `nt.h: cannot open include file 'ntifs.h'` - AFTER every qrexec binary had already compiled. The
   qrexec projects need no WDK, so CI now targets the three projects directly and the WDK never
   enters this job.
2. **`qwt_version.h` is GENERATED, by exactly one project's PreBuild event** (qrexec-agent's
   `set-version.ps1`). Building qrexec-wrapper first therefore died on RC1015 for a header that
   would have existed had the order differed. A build whose success depends on project order is not
   a build: CI now generates the header up front and asserts it exists.

The `continue-on-error` + explicit annotation added when the step was written paid for itself twice:
both failures were loud and said in plain words that the U15 fix was NOT in the package, instead of
disappearing into an otherwise-green run.

STILL NOT CLAIMED AS FIXED: built is not tested. The acceptance for U15 remains the byte-loss probe
(proxy-probe.cs; control = sender 30/30, guest 20/30) re-run against a wrapper carrying this build,
and it must reach 30/30. Deploying a replacement qrexec-wrapper.exe also has to be done carefully -
it is the binary every qrexec call runs through, so a bad swap costs the guest's manageability.

---

## 2026-08-21 — U6 VM-class matrix: the unproven cells are now EXECUTED (4 of 5)

U6 was never a defect, it was a set of code-read assumptions nobody had run. With the AppVM boot
loop fixed by priming, they can be. Every run asserts the binary under test by hash first, and the
security-relevant half is class-independent: exit 0, NO proxy acquired, NO relay started.

    win10-app   AppVM         class=AppVM        phase=skipped-appvm       ok=true
    win11-app   AppVM         class=AppVM        phase=skipped-appvm       ok=true
    win11-disp  DispVM        class=DispVM       phase=skipped-appvm       ok=true
    win11-fresh StandaloneVM  class=StandaloneVM phase=skipped-standalone  ok=true
    (TemplateVM is exercised by every ordinary pass, including the U7 drain)

Each read its class LIVE from qubesdb and took the right branch, with the agent logging why:
"AppVM/DispVM - not a template; updates are the template's business. Exiting before any proxy
activity."

**DispVM was the one recorded as "falls through to the AppVM skip branch by code read; never
executed".** It is now executed, and the code read was right - qubesdb reports `DispVM`, which is
not TemplateVM and not StandaloneVM, so it takes the default branch. This is also the first Windows
DispVM ever booted in this project (created from win11-app as a dvm template, tagged into the
testbed policy).

The acceptance instrument was generalised rather than copied: it derives the expected phase from the
class the guest reports, so one script covers all classes and cannot be "passed" by asserting the
wrong branch.

### The one cell NOT covered, and why I did not just do it

"StandaloneVM with DIRECT INTERNET" - the branch that disables the proxy updater and undoes
NoAutoUpdate=1 - needs a Windows guest actually connected to the internet. CLAUDE.md says plainly:
"Do not enable networking on the test VM. Everything ships via qtest push." Giving a guest we treat
as hostile a real route is exactly what that rule exists to prevent, so it is an owner decision, not
mine to take silently. Everything else about that branch is already proven: the classifier returns
StandaloneVM correctly (measured above), and the offline half of the branch runs.

Fleet currency note: win11-tpl was still carrying the 4CFE3C5D updater from the earlier rollout, which
predates the -Scheduled switch, so the first win11-app run failed on parameter binding rather than on
anything about AppVMs. Refreshed to B16D89F221D6C954 (relay selftest 13/13); win11-fresh likewise.

### U6 COMPLETE — the direct-internet StandaloneVM cell, run with the owner's authorisation

    direct_internet_reachable  true            <- asserted FIRST, see below
    NoAutoUpdate  1 -> (absent)                <- removed, as the branch requires
    took_direct_internet_branch  true
    phase  skipped-standalone   exit 0   proxy_unchanged   no_relay_started
    log: "StandaloneVM with direct internet - it updates ITSELF via Windows Update.
          The qubes proxy updater is template-only: disabled. Undoing NoAutoUpdate=1."
    NoAutoUpdate restored to 1 afterwards; netvm removed again (offline posture per CLAUDE.md)

The `direct_internet_reachable` assertion is the point of the test, not decoration: without it a
guest that failed to get a route would silently have measured the OFFLINE branch and reported a
pass - the cell would look covered while the branch under test never ran. It probes the same two
URLs the updater's own Test-DirectInternet uses.

Why this branch matters: a standalone with a route updates itself through Windows Update, so the
proxy updater must both stand down AND undo the NoAutoUpdate=1 policy it otherwise leaves behind.
Getting only the first half right would leave the guest with Windows Update switched off and nobody
driving it - never updated by anyone, silently.

Incidental confirmation: attaching a NIC to a STANDALONE causes exactly ONE driver-install reboot
and then settles (root is persistent), which is the same mechanism that loops forever on an unprimed
AppVM. It reached `console user Active` on its own afterwards.

U6 matrix is now 5/5: AppVM (Win10), AppVM (Win11), DispVM, StandaloneVM offline, StandaloneVM with
direct internet - plus TemplateVM, exercised by every ordinary pass.

---

## 2026-08-23 — ACCEPTANCE: the submitted unikernel `192d53ab` runs. Plus a guest-side defect it exposed

The owner deployed `192d53ab` to fw-net and confirmed it was already in place for yesterday's
measurements, so the 12.21 MB/s (Windows, release xenvif) and 15.08 MB/s (Linux) recorded above were
against the SUBMITTED build, not the previous one. The unmeasured-delta warning is retired.

**Four Windows cold boots, `win10-app` (AppVM, netvm=fw-net), release xenvif 9.1.0.100:**

    boot 1   PV NIC Up at 38 s uptime    12.23 MB/s   10485760 B
    boot 2   PV NIC Up at 24 s uptime    12.98 MB/s   10485760 B   (first attempt failed - see below)
    boot 3   first HTTP 200 at 27 s      (bench hit the window; connectivity proven at 27 s)
    boot 4   PV NIC Up                   14.29 MB/s   10485760 B

Every boot attached the PV NIC and carried a full 10485760 B. The attach path - `handshake`'s
Closing arm, the RX `check_open` raise sites, the dispatcher retry loop, none of which had ever run -
is exercised four times over. **Linux pair on the same firewall, from this qube: 16.43 / 17.07 /
16.54 MB/s** (recorded 15.5, pre-fix 17.7) - no regression for the ~28 production qubes.

**The intermittent bench failures were NOT the firewall.** Two of the four benches failed every
transfer while the NIC read Up. Rather than retry, a 3-second-resolution boot timeline was taken:

    22s  http=ERR  ips=169.254.121.222        (APIPA - nothing applied yet)
    25s  http=200  ips=10.137.0.72            <- working
    33s  http=200  ips=10.137.0.72
    37s  http=ERR  ips=10.137.0.70            <- WRONG address surfaces
    40s  http=ERR  ips=(none)
    43s  http=ERR  ips=10.137.0.72
    51s  http=200  ips=10.137.0.72            <- stable from here to 119 s

One adapter throughout, so this is not the emulated-NIC handover. Root cause, from the registry:

    HKLM\...\Tcpip\Parameters\Interfaces\{26771a3...}  EnableDHCP=1  DhcpIPAddress=10.137.0.70
    live address: 10.137.0.72  PrefixOrigin=Manual  SuffixOrigin=Manual

**DHCP is still enabled on the PV adapter and holds a stale lease for 10.137.0.70** (the qube's
Qubes-assigned IP is 10.137.0.72 - confirmed via `admin.vm.property.Get+ip`).

**CORRECTION to the first version of this entry: I had the causality backwards.** I wrote that the
applier tears the addresses down and the stale lease "surfaces in the gap". The order is the
opposite, and it matters because it is what makes the fix the right one:

    1. DHCP client is live on the PV NIC and STOMPS the applier's static .72 with the leased .70
    2. traffic dies immediately - .70 is not this qube's address
    3. the applier's next pass removes the foreign address (the interface briefly has NO address)
    4. it re-adds .72; connectivity returns ~5-10 s later, after route/DNS/ARP re-establish

Step 4's lag is measured, not assumed: in the stamped run below the address was already back to .72
at 44 s and 47 s while transfers still failed, recovering at 50 s.

**The lease is baked into the image, now verified rather than inferred.** It reappeared on a fresh
cold boot, and it points at an obsolete server: `DhcpServer=10.138.25.43`, `LeaseObtained`
= 2026-08-19 21:19 UTC. Today's gateway for this guest is 10.138.21.72. 10.138.25.43 is the netvm
this image was primed against - it is the very address in this file's own applier comment at
`guest/pvnic-selfprime.ps1:78`. A Linux netvm runs a DHCP server; mirage-firewall does not, which is
why the client falls back to APIPA (169.254.121.222 at 22 s above) or re-uses the cached lease. A
Windows AppVM's root comes from the template, so win10-tpl carries this and every AppVM inherits it.

This is almost certainly the mechanism behind the recurring "network configuration FAILED" reports:
`Applied()` samples a moving target. Fixed in `guest/pvnic-selfprime.ps1` by disabling DHCP on the
interface before applying the static config. **NOT yet validated** - the applier lives in the
TEMPLATE (win10-tpl), so proving it needs a template update plus a cold boot, which also touches
win10-clean and the other AppVMs on that template. Not done unilaterally.

Note for future benchmarking: the bench must wait for a stable non-APIPA address, or it samples this
window and reports a firewall failure that is not one. Both failing runs did exactly that.
(The 4th URL in `pv-bench.ps1`, thinkbroadband, errors on every run - a dead alt URL, not a defect.)

**"HTTP 200 proven at 27 s, then the benchmark failed" - resolved by measurement, not reasoning.**
That pair looked self-contradictory and the first explanation for it was reconstruction (two qrexec
calls landing either side of a window). Re-run properly: one continuous in-guest script, REAL 10 MB
transfers, every attempt stamped with guest uptime, on a fresh cold boot:

    17s  ips=10.137.0.72   FAILED
    23s  ips=10.137.0.72   10485760 B   0.83s   12.01 MB/s
    30s  ips=10.137.0.72   10485760 B   0.58s   17.17 MB/s
    33s  ips=10.137.0.72   10485760 B   0.15s   64.84 MB/s
    37s  ips=10.137.0.72   10485760 B   0.19s   52.48 MB/s
    40s  ips=(none)        FAILED          <- address gone
    44s  ips=10.137.0.72   FAILED          <- address back, path not yet
    47s  ips=10.137.0.72   FAILED
    50s  ips=10.137.0.72   10485760 B   0.62s   16.15 MB/s
    ... 56-97s all succeed, 20-70 MB/s

So the guest genuinely goes WORKING -> BROKEN -> WORKING with no intervention, and the two earlier
measurements simply fell on opposite sides of the outage. Nothing about the 200 was wrong; the
inference that stitched them together was.

Two things this run also settles: the outage happens on a boot where **.70 never appears at all**
(so the visible wrong address is one symptom of the live DHCP client, not the whole mechanism), and
the working transfers bracket the window at full rate - 12.01 MB/s at 23 s and 16.15 MB/s at 50 s -
so the firewall path is healthy either side. `192d53ab` is not implicated in any of it.

Fix status: `Set-NetIPInterface -Dhcp Disabled` added to the apply path in
`guest/pvnic-selfprime.ps1`. Still NOT validated - it must reach win10-tpl to take effect, which
also touches win10-clean and the other AppVMs on that template.

## 2026-08-23 — END-TO-END: pipeline builds green, ACCEPTANCE FAILS. Not done

Ran the full rebuild three times with the driver step in place. The BUILD completes and every step
self-verifies:

    13:55:40  installing patched xenvif from <pkg>
    13:56:04    push attempt 1 delivered 0/4 files; retrying     <- the retry earned its place
    13:56:17    patched xenvif installed
    14:02:32  latch primed (NICS=1, veto key, tasks verified across a boot cycle); never had a netvm
    14:02:57    scrub removed 23 network-identity item(s)
    14:03:09    verified: no lease, no static DNS, no NetworkList profile, DHCP off everywhere
    14:03:09  done: template=win10-tpl appvm=win10-app

**But the AppVM reset-loops on every networked boot.** It reaches Running, answers qrexec, then goes
Dying within ~20-40 s, repeatedly. So the deliverable is NOT met.

**What the evidence says.** Moving the service log to the PRIVATE volume (`Q:\qwtng-netsetup.log`,
which survives the volatile root - the AppVM's C: takes its own evidence down with it) gives the same
picture on three consecutive boots:

    17:03:53 up=12s qubesdb ip=10.137.0.72 gw=10.138.21.72
    17:04:36 up=11s qubesdb ip=10.137.0.72 gw=10.138.21.72
    17:05:24 up=13s qubesdb ip=10.137.0.72 gw=10.138.21.72

qubesdb is read correctly every time, and then NOTHING - no "adapter up", no "applied". The service
is doing exactly what it should (waiting for `OperationalStatus.Up` rather than touching a device
mid-install); the PV NIC simply never starts. On the pre-driver-step build the same guest reported
`CM_PROB_FAILED_POST_START`. So the failure is the NIC, not the applier and not the scrub.

**Working vs failing differs in one thing: template history.** Everything measured earlier today at
13-16 s with 0/21 failures ran on the LONG-LIVED win10-tpl - a template that had been booted many
times, had the patched xenvif installed by hand, and had already carried a vif. A template freshly
built from the never-networked standalone has never had a vif at all, so the AppVM installs the PV
NIC from scratch on every volatile boot. Leading suspicion, NOT yet proven: with two xenvif packages
now in the DriverStore, that per-boot install goes down a path that demands a restart (problem 14),
which is the reset loop the latch exists to prevent - and adding our package to a never-networked
template is new today. Reordering so the driver installs BEFORE prime_latch (a PV INF has no
NOCLOBBER on `Services\XEN\Unplug\NICS`, so installing it after priming clobbered the latch) fixed
one real defect but did not fix this.

**State:** win10-tpl and win10-app are the freshly built pair, halted. The pipeline changes are
committed and each one is justified by a measured failure. The acceptance is not met and I am not
calling it done.

## 2026-08-27 (night) — 4.3.9 acceptance FAILED; three mechanism models falsified; do not publish

The stamped-DLL build is real (FILEVERSION 4.3.5.1503, sha 88e323c1 != 5dc42759 - and the .rc
had NEVER been referenced by the vcxproj, which is WHY all rebuilds were byte-identical). But
phase A (upgrade of the healed rig to 4.3.9) FAILED: boot1 kept 1024x768, boot2 came up
3440x1440, 5120x1440 never appears, ioctl still 0xC0000476. e2e did not pass -> 4.3.9 NOT
published (owner's gate). 4.3.7 stays Latest and keeps working.

**Falsified tonight, in order:**
1. UMDF-copy hardlink identity: after the 4.3.9 rebind the copy, link and binding are fully
   COHERENT (88e323c1, linked into the oem7 store dir, bound oem7) - and the device still
   fails. RETRACTED as the mechanism (it was consistent with, but not the cause of, the E1/E2
   package A/B).
2. Byte-identical rebuilds as THE cause: a byte-DIFFERENT upgrade breaks identically. The
   stamping stays (hygiene; removes a real confound) but it is not the fix.
3. Modes-key content at boot: the failing boots had 5120x1440 FIRST in the key; and after a
   deterministic key write (5120x1440,1024x768 only) the guest booted at 3440x1440 - a mode in
   NEITHER the key NOR s_SampleDefaultModes (1920/1600/1024). Some third mode source exists
   (suspect: dxgkrnl's persisted GraphicsDrivers configuration against the M1 stable EDID
   identity) and the driver's actual read/offer behavior is invisible.

**What is actually known:** oem12-bound boots reach 5120x1440 (many samples); every other
binding tried (oem14, oem7) fails to surface 5120x1440 while sometimes surfacing OTHER
registry modes (3440x1440); the QIDD ioctl answers STATUS_OPERATION_IN_PROGRESS in the failing
states; the failure is per-BINDING, reproducible across reboots, and survives device
recreation. Driver code identical (modulo the new version resource), cert identical, cats
valid, INFs identical modulo DriverVer.

**Next step (decided): instrument the driver.** It is our code and currently emits nothing:
record into its device registry key (a) the modes-key content each read sees, (b) the mode
list it offers at each arrival, (c) every ReloadModes entry/exit + ioctl disposition. Then the
oem12-vs-other difference becomes readable instead of inferred. No further mechanism claims
until that data exists.

## 2026-08-28 cont 6 — stability e2e on the 4.3.14 candidate: 33 passed, 1 failed (harness)

> **UNPROVEN as a headline (audited 2026-08-29).** Parts of this run are solid and stay: the
> artefact identity cell (installed agent == release binary, bar 2), the 8 cold boots (bar 7), and
> the window-geometry cells, which measured real pixels (3826x1016 on a 5120x1440 host) with
> notepad open (bar 5). What does not hold up as a "33 passed" count:
> * the **secure-desktop PASSes** — that check was a PRESENCE test for `QGADESKSTUCK`, unable to
>   distinguish a recovery from a freeze, and was only proven able to fail AFTER correction later
>   in this session. By the project's own rule 6 its PASS here is not evidence.
> * the **autologon PASSes** — cont 5 records the plaintext-rearm task being deliberately put BACK
>   on the rig, so any later autologon cell on that rig (or an image derived from it) is confounded
>   again unless it asserts the secret is the LSA one. This entry does not say what "armed" was
>   asserted on.
> * **"nothing fullscreen-sized"** as evidence for the boot/shutdown fix — these boots ran with the
>   feature OFF, where the pre-existing `WS_CAPTION` gate denies the window anyway. The phase gate
>   that actually shipped (`6e6329a`) was never exercised (bars 3 + 4).
> * **"WIN10 recorded 0 self-initiated restarts"** — zero records from an instrument that produced
>   nothing on that chain is missing data, not a negative result (bar 6).
>
> The harness and its logs are not in the repo, so none of this run is reproducible from the record.

Both chains rebuilt from the golden images and installed with the real installer
(`install.cmd /auto /autologon:qubes`), package 4.3.14+agent.5634f905a8dd, agent 581912664391:

    WIN11 / WIN10   installed agent == release binary          PASS / PASS
                    installer armed autologon                  PASS / PASS
                    app-menu rpc scripts placed over stock      PASS / PASS
                    reboot-cause audit installed               PASS / PASS
                    all built-in app-menu entries reported     PASS / PASS  (45 / 49 available)
    template cold boot: user session + windows + secure desktop PASS / PASS
    AppVM x3 cold boots: session, windows, secure desktop       PASS / PASS (one exception below)

Every window check ran with notepad OPEN and measured the PNG: one window, 3826x1016 on a
5120x1440 host. Nothing host-sized anywhere - the rule broken on 2026-08-28 now has direct
evidence on both chains, on 8 separate boots.

THE ONE FAILURE IS MINE: `WIN10-app-b1: screenshot failed` - an empty tar even with notepad
launched, on the AppVM's FIRST cold boot (the slowest). The same check passed on the other seven
boots including two later ones on that same VM. Cause: an 8-second fixed sleep racing a cold first
boot, not a product defect. The check now POLLS (6 attempts, ~42 s) instead of sleeping a
constant. A fixed sleep in an acceptance check is a false-failure generator, and a false failure
costs exactly as much credibility as a missed one.

REBOOT AUDIT (#29), second run: WIN11 recorded 4 records again, all `xenagent` executing a
shutdown "on behalf of NT AUTHORITY\SYSTEM", timestamps matching the install's own reboot and the
harness's qvm-shutdown calls. WIN10 recorded 0. No self-initiated restart in either chain.

WATCHDOG: 'died within' 6 (WIN11) / 6 (WIN10), 'not restarting it (going down)' 1 / 22. The
suppression fires, but the FIRST death of a shutdown still gets a respawn because it happens
before the SCM sends PRESHUTDOWN. Logged with the signals consulted; not fixed.

NOT in this build, committed after it: the appmenus sync hardening, the qubes.GetAppmenus alias,
and the curated 8-entry default menu. The release candidate must be rebuilt and re-tested with
those before shipping - the e2e now asserts the service exits 0 and the alias exists.

## 2026-08-28 — ours-wins CI guard: the stale-payload bug class is now a build failure (guard subagent)

> **UNPROVEN WHEN WRITTEN — later made true (audited 2026-08-29).** The ten-seeded-defect validation
> below is the best instrument work of the session and STANDS as instrument validation (bar 3 done
> properly). But it ran entirely OFFLINE against a FAKE stock image and a FAKE package tree, with no
> real CI run executed — so "is now a build failure" was a prediction at the time. The real-data
> behaviour did need fixing afterwards (`0e19c67` reverted msi-image entries swept in by accident;
> `e92ffde` gave the guard the second root its data needed). It IS recorded CI-green after `e92ffde`
> — cite that commit, not this entry, for the guard actually working.

The 2026-08-25 incident class (a file we maintain sources for ships from the STOCK 4.2.2 image,
or not at all, with CI green) is now guarded in CI. New files, both data-driven from ONE list:

- `packaging/ours-wins.psd1` — THE list: Mirrors (the rpc payload sweep rules, matching
  make-setup's new rpc/qubes-rpc-services + rpc/qubes-rpc layout), Files (one-offs, e.g.
  guest/VMExec.ps1), Binaries (must differ from stock: reference/gui-agent.exe,
  reference/gui-watchdog.exe, bin/qrexec-wrapper.exe when present), DeadEnds (core-agent's
  VMExec.ps1 must STAY stock-identical — editing the dead-end copy now fails the build with
  instructions), SweepTrees (core-agent rpc dir + guest/ compared against the stock image by
  basename), CompiledSources (git diff of core-agent vs its 4.2.2 base f79d290ae62a with
  dir→binary mappings for qrexec-wrapper/agent/client-vm), KnownGaps (documented, WARN-only,
  stale entries FAIL).
- `packaging/check-ours-wins.ps1` — the guard; runs in release-package.yml's setup job on every
  package build, extracts the vendored stock MSI as its baseline (msiexec /a), collects ALL
  violations then throws. Ours-vs-stock text compares are CRLF/BOM-tolerant (repo stores LF, a
  Windows CI checkout materializes CRLF).

INSTRUMENT VALIDATED before trusting it (pwsh 7.4.6 user-space in ~/pwsh74, fake stock image
built from the core-agent base commit with CRLF conversion, fake package tree mimicking the new
make-setup sweep): clean state PASSES with exactly the 2 expected G1 warnings; TEN deliberately
seeded defects each FAIL with the targeted message — not-shipped-at-all (the incident itself),
stale-copy-staged, fork-binary-identical-to-stock, unshipped-file-shadowed-by-stock (guest
sweep), dead-end-copy-edited, overlay orphan, stale KnownGaps after the gap closes (the ratchet),
missing base commit (missing data fails), divergent compiled dir with no binary mapping, and
optional-binary-absent-with-no-KnownGaps-entry.

Collision audit (decoded the stock MSI's string pool via olefile — no extraction tooling here):
the ONLY basenames shared between the stock MSI and our maintained trees are the 7 known rpc
files, all covered. The sweep cannot false-positive on the first real CI run.

**UNPROVEN — a prediction stated as a result (audited 2026-08-29). The guard's real-data behaviour
did need correcting, in `0e19c67` and then `e92ffde`.**

MAINTENANCE CONTRACT: when release-package.yml starts building core-agent and passing
-CoreAgentBins, flip bin/qrexec-wrapper.exe to Required=$true and DELETE the KnownGaps entry in
the same commit — the guard flags the entry as stale otherwise, and staging qrexec-agent.exe /
qrexec-client-vm.exe without Binaries entries fails the orphan check until they are listed.

Path filters completed in release-package.yml (packaging/**, qwt-full.yml + pv-xenvif.yml
themselves, patches/**, vendor/**, contrib/**, tools/qubesdb-read/**, tools/winenum.cs,
.gitmodules; both submodules were already listed) and the FALSE comment in qwt-full.yml
("rpc scripts are staged from here") corrected — core-agent contributes nothing to the MSI today.

## 2026-08-29 — step-0: first-hand guest measurements, and the instrument chain proven on a live guest

All measured today by me on `win10-u10`, booted, probed, shut down cleanly via ACPI. These are
first-hand readings, not inherited claims.

**win10-u10 actual content** (`guest/qwt-state.ps1`, both Uninstall roots):

    QWTVERS=4.2.2.0   QWTCOUNT=1        AGENTFILEVER=4.3.3.0
    TESTSIGNING=True  SYSTEMSTARTOPTIONS=" TESTSIGNING  NOEXECUTE=OPTIN"
    BUSTYPE=SCSI      XBMSTATUS=Running XBMSTART=2  XBMPIDS=3076

Three things follow:

1. **This guest is a ready-made stock-QWT-4.2.2 target with the STOCK monitor state** —
   `xenbus_monitor` Start=2 (Automatic) and *Running*. That is the S10 precondition the plan
   costed at 17-90 min of golden-building, and it already exists. It is also a genuinely different
   precondition from the win10-clean clones, where the installer logged `(was Disabled/Running)`:
   Automatic+Running vs Disabled+Running. **Preserve this guest** — do not reuse it as a scratch
   target.
2. **It is NOT pristine stock.** The registered product is 4.2.2.0 while `gui-agent.exe` is
   4.3.3.0, i.e. an agent binary was swapped in without the MSI registration changing. Usable as a
   stock-*registration* upgrade source; NOT a clean stock image. Recorded rather than smoothed over.
3. Its boot disk is already on the PV path (`BUSTYPE=SCSI`).

**Instrument chain validated end-to-end on a live guest**, each state produced deliberately:

| case | condition | result |
|---|---|---|
| A | healthy guest, no app open | `EMPTY` |
| B | unserviceable target (`win-idd-test`) | `CAPTURE-FAILED` |
| C | healthy guest, notepad open | `CAPTURED`, 1 window 2566x1022, `VERDICT=DESKTOP` |

**Two defects in my own new code, found only because this ran against a real guest:**

- `local.WinScreenshot` exits 1 **both** when it refuses a target and when the guest simply has no
  mapped windows. My first `_snap` judged rc alone and so labelled a *healthy* win10-u10
  `CAPTURE-FAILED`: seamless mode maps nothing with no app open, and opening notepad immediately
  produced a 1-window capture. The discriminator cannot be rc, and cannot be stderr (qrexec does
  not propagate it) — it is whether the target is serviceable at all, decided locally.
- `_snap` set `SNAP_STATE` but every caller invoked it as `n=$(_snap ...)`, a **subshell**, so the
  state never escaped and `screenverdict` returned `NOSHOT` even for a captured window. That
  silently disables `bootwait`'s terminal detection — the very guard against the kill-restart loop
  that is H2's suspected brick mechanism. A guard that cannot fire is worse than none.

Both are the same lesson the campaign exists for: an instrument is not trustworthy until it has
been seen to produce each of its outcomes on the real system.

## 2026-08-30 — every acceptance guest was built with a 2 GiB private volume (Q:)

Owner, seeing it in an Explorer screenshot: *"this qube has Q: of 2Gb, wtf even is that?"*

Measured: `win10-clean:private` size 2147483648 (exactly the Qubes default), ~300 MB used, Q:
reporting 1.98 GB total. Q: is the private volume, and QWT's MoveUsers relocates `C:\Users` onto it -
stock behaviour, and README.md explicitly says to "check the private volume size first". So 2 GiB
was the ENTIRE budget for every user profile on the guest.

**Cause: the fix existed but only covered half the fleet.** `mgmt/clone-to-template.sh` already
extended private to 20 GiB for the template/AppVM path, with a comment recording why. But
`scratchpad/reprovision.sh` - which is what the ACCEPTANCE MATRIX actually uses to build guests -
extended only `root` (to 80 GiB) and never touched `private`. Every cell therefore ran against a
2 GiB private volume.

This is the same root cause as the earlier AppVM push failure, where a 2 GiB private volume left no
`Q:\Users` at all and `qubes.Filecopy` failed with "getting Documents path failed 0x80070002" -
nothing could be pushed, so nothing could be tested. That was diagnosed and fixed in one script and
not the other, which is exactly how a fixed bug comes back.

**Fixed** in `reprovision.sh` (20 GiB, per the owner: "40gb of private volumes is a waste, 20 should
be typically enough"). Placement matters: the extend runs BEFORE Windows installs, so QWT formats Q:
at the full size and no in-guest partition resize is needed for new provisions.

**The live guest needed both halves.** Extending an EXISTING guest's volume leaves the filesystem
behind - Qubes said so plainly ("Online resize of volume ... failed (you need to resize filesystem
manually)"). Resized in-guest with Resize-Partition: Q: went 1.98 GB -> 19.98 GB, 19.68 GB free.
Worth remembering: on an existing guest, `qvm-volume extend` alone changes nothing Windows can see.

## 2026-08-30 — the matrix harness could report a VACUOUS PASS, and a 0-cell run that looked clean

Found by the runbook conversion (Fable), reviewing `mgmt/harness/matrix.sh` against the protocol
rather than trusting it. Three defects, two of which manufacture false results in silence.

**1. Vacuous PASS on a missing release binary.** `verify_installed` asserts the guest installed OUR
build with

    grep -qa "\"installed_gui_agent_sha256\":\"$ASHA"

and `ASHA=$(sha256sum $S/dl/qwt-full-package/gui-agent.exe ...)`. If that file is absent, sha256sum
fails, **ASHA is empty**, and the pattern degenerates to matching the bare key - so it matches ANY
RESULT line and the cell passes without ever checking which build installed. That is precisely the
`INVALID-WRONGBUILD` case H1 exists to prevent, produced by the check meant to prevent it.

**2. A campaign with no cells reported as a clean run.** `CELLS` defaulted to `seeded`, which
matches no case arm in the driver, so the loop fell through and the summary printed
`0 passed, 0 failed` - indistinguishable at a glance from a completed matrix. An unknown selector
was likewise narrated (`unknown cell 'x'`) and then ignored, so a typo silently shrank the matrix
while the summary still read clean.

**3. Preconditions built by uninstalling.** `cell_fresh` / `cell_upgrade_stock` construct their
entry state with `msiexec /x`, which **P1.0 forbids explicitly** - QWT *is* the qrexec agent, so
removing it removes the control channel, and the protocol records that this already "cost
`win10-u10`". They also invoke helper scripts from `/home/user/.claude/jobs/<id>/tmp/`, the
garbage-collectable session path H0 banned for the wait library. NOT fixed here - it needs the
precondition rebuilt a legal way, and it is recorded as P0-PRE.8.

**Fixed (1) and (2), and both guards were SEEN TO FAIL before being trusted:**

    CELLS unset            -> FATAL: CELLS is unset. Name the cells explicitly
    gui-agent.exe removed  -> FATAL: ... missing - without it the agent-hash check
                                     silently matches any build

An unknown selector now increments FAIL instead of being narrated past. Per H5 these guards move
from "PASS-UNPROVEN" to having a fail-proof on record.

**Bearing on tonight's aborted matrix run:** `gui-agent.exe` was present, so ASHA was non-empty and
that run was not vacuous on this axis. The 0-cell path was never hit either, since CELLS was always
passed explicitly. The defects were latent, not active - but they were latent in the one instrument
the whole acceptance claim rests on.

## 2026-08-30 — Win11 primer PROVEN, and the selftest harness nearly reported the opposite

`win11-base`'s seal carried the caveat *"Primer NOT yet selftested on Win11 - do that before relying
on it."* Settled: `mgmt/prime-selftest.sh win11-base prime-selftest-11 selftest`. Evidence is a
screenshot, because a primed guest is pristine Windows with no QWT and therefore no qrexec —
`evidence/prime-selftest-prime-selftest-11-20260830-114839/PASSED-proof-win11.png`. All four
criteria visible on screen:

    PRIMER SELFTEST PASSED
    The primer hook ran this job as: nt authority\system
    Date: Sun 08/30/2026 11:49:38.96      Job media was: D:\qubes-prime\
    Windows build: Microsoft Windows [Version 10.0.26100.1742]
    Testsigning state: SystemStartOptions REG_SZ NOEXECUTE=OPTIN FVEBOOT=2633728   <- no TESTSIGNING
    QubesPrime task: ERROR: The system cannot find the file specified.             <- self-unregistered

`win11-base` re-sealed to record this. The volumes are byte-identical to the 11:22Z seal — the
golden itself was never booted, a clone was.

### The harness produced a FALSE NEGATIVE on this very run, and it was a timer

The first frame this script captured was a **bare desktop**, and its own closing message says *"A
bare desktop with no Notepad means the hook did NOT fire - the channel is broken."* The channel was
fine. Re-capturing the same guest three minutes later showed the full PASS text above.

Cause: the loop exited on `restarts>=1 && elapsed>=240`, an ELAPSED-TIME condition measured from
the start of the whole run. On Win11 the job's reboot landed later than on Win10, so 240 s arrived
while the guest was still booting — before the StartUp shower opened Notepad. This is exactly the
failure H2 bans a bare `sleep`-poll for: a timer cannot tell *"not yet"* from *"never"*, and here it
turned a PASS into a "the channel is broken" verdict that would have sent the next session chasing
the primer instead of running cells.

Fixed two ways, both in `mgmt/prime-selftest.sh`:
1. The settle window is now anchored to the RESTART (`SETTLE=210` s after the guest comes back),
   not to the start of the run — the one form of fixed delay H2 permits, a declared settle attached
   to a grading step.
2. Frames are numbered and never overwritten. The old code deleted `win-*.png` each pass and copied
   the largest PNG to `latest.png`; once `latest.png` existed it was usually the largest, so `cp`
   copied it onto itself (`are the same file`) and DISCARDED the new capture. The evidence directory
   could hold an old frame under a name asserting it was current.

Standing lesson, and it is the same one twice in one day: **the CPU-quiescence probe, the PRISTINE
gate, and now this** all failed by grading on a proxy (a timer, a verdict string) instead of the
signal. Judge the thing itself, and when the instrument and the guest disagree, re-measure before
believing the instrument.

## 2026-08-30 — U0 and U2 PASS; the VM-class matrix and the QdbDaemon race fix are validated

**U0** (deploy state, read-only, `win11-tpl`): task shapes exactly as specified —
`QubesWindowsUpdateScan` boot PT2M + PT6H repeat as SYSTEM with `-Scheduled`;
`QubesWindowsUpdateRun`/`Download` with no triggers and no `-Scheduled`; `QubesAutologonGuard`
boot PT30S. Policy `NoAutoUpdate=1` and `ExcludeWUDriversInQualityUpdate=1` (the latter is what
stops Windows Update delivering Xen drivers over the PV-NIC latch). Offline baseline clean:
no relay process, winhttp Direct. All five deployed scripts hash-match the shipped payload.

**U2** — every class arm behaves as the security model requires, witnessed by what CHANGED rather
than what was logged:

| class | observed |
|---|---|
| TemplateVM (`win11-tpl`) | classified from qubesdb, ran the proxy pass |
| AppVM (`win11-app`) | *"AppVM - not a template; updates are the template's business. Exiting before any proxy activity."* exit 0, `RELAY_AFTER 0`, `ProxyEnable 0` |
| StandaloneVM + netvm (`win10-c1`) | *"StandaloneVM with direct internet - it updates ITSELF ... Undoing NoAutoUpdate=1."* `NoAutoUpdate` 1 -> **removed**, no relay, proxy settings removed |

**The boot-path clause is the valuable one.** U2 binds classification to a COLD BOOT because a live
re-run clears the QdbDaemon startup race it exists to catch. Armed, cold-booted, checked:

    {"rebooted":true,"classes_seen":"TemplateVM","class_correct":true,"saw_empty_class":false,
     "refused_to_classify":false,"skipped_as_standalone":false,"qdb_retry_evidence":true,"ok":true}

`qdb_retry_evidence:true` means the retry loop actually fired — so the fix is load-bearing on a real
cold boot, not merely present in the source. That had never been exercised before.

Minor instrument nit: `wu-boot-acceptance-arm.ps1` reports `vm_class_now=WIN-IDD-TEST`, which is the
hostname, not a class. The post-boot CHECK is the authority and is correct; the ARM line is
mislabelled and would mislead a reader.

## 2026-08-30 (evening) — P4 re-run clean, and THREE instruments found lying

Continuation of the 4.3.16 acceptance campaign. All work on `win10-p46`, the rebuilt clean subject.

### P4 re-run on a clean subject with the scan provably disarmed — DONE
`mgmt/harness/p4-run.sh win10-p46` → rc=0, with the G-0c precondition in the transcript:
`SCAN_BEFORE Ready nextrun=08/31 03:00` → `SCAN_AFTER Disabled`, `RELAY_AFTER 0`, `DISARMED True`.

| cell | result |
|---|---|
| BENCH-2 idle CPU | 0.03 / 0.02 / 0.00 s per 120 s (baseline ~0.08, pre-fix control 3.95) |
| BENCH-1 scroll p50 | 351 / 314 / 368 µs vs canonical 374–436 — below the band on all three |
| RND-7 | guest-side 5 HWNDs, dom0 mapped exactly 1 |
| RND-5 | dom0 0 mapped, **6** deny lines `Start surface not presented in seamless mode (SeamlessStart=0)` for HWND 0x10174 |

Three measurement conditions, showing the controls were load-bearing: contaminated subject + scan
live = 334/307/345; clean subject + scan **live** = 417/366; clean subject + scan **disarmed** =
351/314/368.

`p4-run.sh` bug found and fixed: `$(... | grep -c '\.png$' || echo 0)` emits **two** zeros (grep -c
prints `0` *and* exits 1), so the variable became `"0\n0"` and mangled the log line it was
interpolated into — RND-5's output lost its deny-count half, which is the vacuity proof.

### `set-resolution.ps1`: the bug was a NULL device name, not DEVMODE marshalling — RETRACTION
The note committed in that file earlier the same day claimed `Marshal::SizeOf` and
`Marshal::OffsetOf` disagreed, and hard-coded `dmSize=156` to match the offsets. That was wrong.
Measured on win10-p46:

```
ES  DISPLAY1/mode0/220    rc=1  640x480      <- the 220-byte layout reads correctly
ES  null/current/220      rc=0  0x0
CUR \\.\DISPLAY1          rc=0  modes=29     <- attached, INACTIVE
CUR \\.\DISPLAY2          rc=1  5120x1440    <- the desktop lives HERE
EnumDisplayDevices(NULL,0..3) -> rc=0 for every index (enumerates nothing on this guest)
```

Two display devices; the desktop is on **DISPLAY2**; the script passed `lpszDeviceName = NULL`, and
`EnumDisplayDevices` returning nothing meant there was no cheap way to see which device was active.
Marshalling was never involved. Hard-coding a constant to reconcile two measurements of one fact is
how a broken instrument gets a green banner.

**Also refuted: the session-0 story.** qrexec here runs as SYSTEM but in **session 1 on WinSta0**:

```
via qtest (qrexec):        whoami=nt authority\system  sessionId=1  winsta=WinSta0
via schtasks /ru user /it: whoami=win-idd-test\user     sessionId=1  winsta=WinSta0
```

An identical probe returned byte-identical output through both paths, and `ChangeDisplaySettingsEx`
succeeds from qrexec. I had written session-0 blindness into `guest/run-as-user.ps1`'s header as the
cause *before testing it*, and committed it. Corrected in place. `run-as-user.ps1` keeps its real
purpose — running as the USER PRINCIPAL (toasts, Start, HKCU), which is a different thing from the
session.

Fixed script verified end to end: containment 5120x1440 → 1920x1080 → 1600x900, each step confirmed
by read-back **and** by the agent (`SendWindowConfigure hwnd=0x0,w=1600,h=900`,
`A6CONFIGURE window 0 -> 1600x900`). RND-8's blocker is gone.

### `local.WinResize` reported a dom0 tooling fault as a guest condition
`local.WinScreenshot` returned **2 windows** for win10-p46 while `local.WinResize` returned
`GEOM ok=0 err=no_window` **in the same second**, using byte-identical selection
(`_NET_CLIENT_LIST` + `_QUBES_VMNAME`). The only difference is `geom()`, which shells out to
`xwininfo`. `no_window` names a *guest* condition, so the obvious reading is "the guest mapped
nothing" — a safeguard result, not an outage. `dom0/10-install-resize-service.sh` v5 now
distinguishes `empty_client_list` / `no_window` / `geometry_unreadable` and flags the dom0-side
ones. **dom0 must reinstall it before the new strings appear.**

### The P5 harness scored a product PASS as a FAIL — and its "0 mapped" was blind
First P5 run graded SG3 (captioned windowed-fullscreen, which the README says is ALWAYS allowed) as
FAIL on `dom0 mapped=0`. The agent's own log for that HWND:

```
SendWindowCreateInternal: QGAPROTO,msg=CREATE,hwnd=0x40236,...,ovr=0,style=0x14cf0000
PwAttachWindow: 0x40236: per-window buffer 1586x893 attached
SendWindowMap: QGAPROTO,msg=MAP,hwnd=0x40236,ovr=0,...,vis=1,w=1586,h=893
```

The product mapped it. The harness used a fixed 18 s settle, which is shorter than PowerShell's
runtime `Add-Type` C# compile, so the probe window did not exist yet and `qtest shot` returned an
empty tar — read as "the gate denied it". Proven by re-measuring the same probe at increasing
settles: **25 s / 60 s / 100 s all return the probe (1186x693) plus its console (979x512)**; a
1176x600 notepad was captured throughout as a control.

This also voids the *dom0 half* of SG2/SG4/SG9 from that run — same blind settle. Their agent-side
deny evidence stands.

**Structural fix, not a longer sleep**: `p5-run.sh` now (a) waits on the probe's own
`"visible":true` JSON as the readiness signal instead of guessing, and (b) keeps a small Notepad
mapped for the whole run as a LIVE POSITIVE CONTROL — a cell whose capture cannot see the control is
`INVALID-INSTRUMENT`, never a pass. Until this, "nothing mapped" was a verdict a blind tool could
manufacture.

### New instruments
- `guest/fsgate-probe.ps1` — creates one window with exactly-specified styles at the guest screen
  size, reads the styles BACK with `GetWindowLong`, and prints hwnd/style/exstyle/rect/covers_screen
  as the cell's vacuity proof. `WS_SYSMENU|WS_EX_APPWINDOW` on the borderless arm is load-bearing:
  without it `IsPopup()` (main.c:1221) classifies the window override-redirect and it is denied by
  the **Mode 1** branch, so the cell would pass while never reaching the Mode 2 gate it exists to test.
  Refuses to run unless the guest screen is strictly inside the host screen.
- `mgmt/harness/p5-run.sh` — P5 with the scan disarmed, containment applied AND verified against the
  agent, per-cell deny-line vacuity proofs, and the live control above.
- `guest/run-as-user.ps1` — runs a command/script as the user principal and recovers its stdout.

---

## 2026-09-01 — acceptance protocol work CONCLUDED. An honest accounting.

Owner: *"i think we conclude the acceptance protocol for now. it was a humbling exercise in
futility."* Largely correct, and the record should say so plainly rather than bury it.

**What was futile.** Twenty-five prose rules were added to this protocol. Measured the same day
they were written, by the linter, against their own author: rule 15 ("one harness per guest") had
**7 harnesses** not following it after I stated I had wired it everywhere; rule 18 ("a check must
be able to fail") had **9 more checks** that can only ever emit PASS after I had hand-repaired
four. Adherence to hours-old rules, by the person who wrote them, was roughly 60%. A rule that
requires a reader to notice something is worth what that reader's attention is worth on the day.
The three days spent refining protocol prose bought understanding, not control.

**What was not futile**, and is worth keeping:

* **The verification apparatus was measuring less than it claimed, and that is now known.**
  `or-fullscreen-never-mapped` was graded from a screenshot that structurally cannot see an
  override-redirect window — it would have passed a build leaking a fullscreen takeover surface,
  the exact class the Mode-1/Mode-2 design exists to prevent. Three more checks were vacuous in
  the same way. `L7` finds **105** ledger names that no harness emits at all.
* **The fault injector** (`FI_GATE_OFF`, `FI_DROP_*`, `FI_NOSYNTHPAINT`, `FI_NOSCREENCONFIG`) —
  reusable, compiled out of release builds, and the only reason any of the above was findable.
* **`tools/lint-harness.py` + the pre-commit hook** — seven mechanical lints, self-tested 8/8
  against planted violations plus a negative control, enforcing rather than advisory.

**Where the ledger stands:** PASS 319 / PASS-UNPROVEN 40 / N/A 21 of 429. Those numbers are worth
less than they look and should not be quoted as an acceptance result: an unknown share of the
PASS rows rest on checks of the quality the linter is now finding. **The 33 open lint findings are
the honest backlog** — 7 missing locks, 9 unfailable checks, 17 fragile probes — and they are
concrete edits, not judgement calls.

**If this is resumed**, the order that follows from all of the above: clear the 33 lint findings
first, re-run the campaign against repaired checks, and treat any PASS predating that as
unverified. Do not add prose rules. When something is learned, ask whether it can be a lint; if it
cannot, write it down AND mark it unenforced, so its unreliability is visible rather than assumed.

