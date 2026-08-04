# Goal status — updated 2026-08-04 (evening)

## PRIMARY GOAL (set by the user 2026-08-04): arbitrary guest resolutions in NON-SEAMLESS
## mode, synced to the dom0 window size and work area (T2 / PLAN-trackb-t2-modes.md)

Progress today, every claim measured against a control (details in FINDINGS 2026-08-04 cont 2-5):

| plan item | status |
|---|---|
| exp 0 — 19045 re-baseline (3x ddaprobe) | **PASS 3/3** — flag TRUE, pitch tight, session 1 |
| exp 0b — instrument validation | **PASS both** — inverted ddaprobe FALSE-path proven on real DXGI; pixel comparator passes AND fails correctly. Caveat: judge ddaprobe by JSON, its exit code never carried the flag |
| exp 1 — pitch at 1400x1050 (32-not-64-byte aligned) | **PASS — pitch TIGHT (5600)**, flag held. Does not clear 8-byte-aligned widths (2566) |
| exp 2 — pin non-seamless config | guest half **PASS** (SeamlessMode=0 both keys, survives cold boot, single live dom0 window). dom0 half needs the resize service (user) |
| exp 7 — PnP auto-revert proof | **PASS** — boot task re-enabled a disabled device, status-readback verified, marker cleared on success only |
| A0 modeprobe (external witness) | **LANDED + acceptance PASS** (29 modes, CDS_TEST verdicts correct) |
| A1 snap logging (control build for A2-A4) | **LANDED + VALIDATED both directions** (SNAPPED on 1600x1000→1680x1050; absent on exact match; modeprobe corroborated) |
| exp 8 — D0 minimal IDD present-and-inactive | in flight (CI iterating; guest baseline taken: wmi_monitors=0, vscreen 3440x1440, 1 VC) |

**Unplanned discovery that reshapes T2:** the guest→dom0 half already works end-to-end in
non-seamless mode on the current fork build — an externally applied mode change (1400x1050)
propagated through recovery → re-grant → re-dump, and the dom0 window resized to exactly
1400x1050 with a live desktop. Remaining: dom0→guest requests (snap to 29 modes today) and
arbitrary sizes (the IDD).

**New defect knowledge:** graceful agent exit still leaks per-window grants (no detach-all on
the exit path) — design to fix in DESIGN-a6-grant-lifecycle.md, awaiting user approval.
**Double-cursor** (user observation): explained — PrintWindow side effect; returns in
fullscreen mode; T2-mode fix needs IDD hardware cursor or DisableCursor=1 (FINDINGS cont 5).

Infrastructure: graceful agent stop (QGA_SHUTDOWN) adopted everywhere (install-agent3.ps1,
first use verified `stop=graceful`); deliberate hang-reproduction experiment deferred.

---

# Goal status — updated 2026-08-02

## Display/agent package: CLEAN-INSTALL VERIFIED, no regressions found

Build `b299011` (package `installer.msi fa774936…`, `gui-agent.exe 4b4ce2b1…`) was
installed from an unattended ISO onto a **wiped disk** — not overlaid on a stock QWT, no
`.orig` backups — and passed every display gate by measurement, each against a control:

| gate | number |
|---|---|
| drag frame cost p50 | **613 us** (bar 5 ms; pre-fix build 17.2 ms; old baseline 917 us) |
| work-area re-assert churn, 120 s idle | **0 applies / 0.08 s CPU** (pre-fix 1460 / 3.95 s) |
| `WorkAreaCreateListener 0x5` | **0** (was 3 per agent start since 6d46132) |
| Win10 protocol/acceptance regression | all invariants hold on 526 records |
| Edge ULW first-run | 5/5 points |
| cold boot | 2 guest windows → 2 dom0 windows, 0 EnumWindows failures |

Two defects were found and fixed this session, both invisible to code review and caught by
measuring: the work-area listener could never be created on ANY OS (`OpenInputDesktop`
lacked `DESKTOP_CREATEWINDOW`), and per-frame `PrintWindow` recapture of a dragged window
was pure waste (its content is position-invariant, so the diff was always empty). Fixing
the first exposed a third — a 12 Hz re-assert ping-pong with Explorer — which was itself
found by measurement, not review, and fixed after the first attempt was rejected in
adversarial review for a starvation bug.

## BLOCKER unchanged: networking

With a netvm attached the guest is still unusable (xenvif installs but never starts,
~2 cores burned, qrexec dead). This is **not a regression** — it predates and is unaffected
by the display work — but it means the package is not yet a shippable Qubes Windows Tools
install. New this session: the "graceful two-boot dance" the previous handoff proposed is
**unexecutable**, because a netvm-attached guest never becomes responsive enough to service
ACPI. The next experiment is the stock-QWT control install (ISO built and verified) to
settle whether the defect is ours or upstream/environmental.

## Standing rule this session kept honoring
Every claim above is a measurement against a control, and the two results that looked like
failures were investigated rather than accepted: a cold-boot "FAIL" turned out to be two
harness defects (no settle wait, hardcoded window count) on a healthy build, and an
"MSI upgrade starves the guest" entry I wrote was retracted after I found the upgrade had
never applied and that my own short probe timeouts had misread a live guest as dead.

---

## Historical (pre-2026-08-02)



## BLOCKER (2026-08-01, session 6): networking is broken on the current build

The full-source QWT (our agent, upstream WiX installer, stock PV drivers) installs cleanly
and every display check passes — but **attaching a netvm makes the guest unusable**: xenvif
installs yet never starts, the emulated-NIC unplug is never armed, ~2 cores burn and qrexec
stops answering. **This is not a shippable Qubes Windows Tools install.** Nothing here goes
to a real qube or upstream until networking works. Details, evidence and the two required
experiments (clean-reboot retest; stock-QWT control install) are in
`SESSION-HANDOFF-qwt-full.md`.

## Display work: per-window capture build shipped and validated

The mission-defining feature — **per-window capture** (each guest window gets its own
granted framebuffer, killing the composited-desktop artifact class) — is IMPLEMENTED,
built into an installable package, deployed to win-idd-test, and validated end to end
against every acceptance criterion. Full detail: `FINDINGS.md`, entry **2026-08-01**.

- Branch: `agent/perwindow` (commit `ec55f39`), submodule bumped on `main`.
- Package: `qwt-improved 4.2.2+agent.ec55f39`, CI run `30671887528` (all jobs green),
  local copy `artifacts/qwt-final/`.
- Deployed on win-idd-test (swapped into Program Files, `.orig` backup present; watchdog
  restores it on boot). **This build — not stock — is what is installed.**
- Capture engine is **PrintWindow(PW_RENDERFULLCONTENT)**, NOT WGC: WGC cannot activate
  in the agent's SYSTEM/session-1 context (IsSupported 0x8007000E, CreateForWindow
  throws). See FINDINGS 2026-08-01 and DESIGN-per-window-capture.md §3.
- Daemon is UNMODIFIED — this rides the daemon's existing per-window MSG_WINDOW_DUMP path
  (the Linux-agent model).

Acceptance (all PASS, evidence in `instrumentation/perwin-*.png` and FINDINGS): no window
corruption in overlap, no tear, no wobble (drag: 2/219 stale, max 5px), Office-style
compound windows = 1 clean window, no stray borders, no double titles, popup/menu leaves
host uncorrupted, and **cold-boot survival** — the prior blocker (below) is fixed.

### The prior cold-boot blocker — RESOLVED
The earlier build failed cold boot: the agent's window enumeration failed with
`0x80070006 ERROR_INVALID_HANDLE` and the qube rendered nothing. That is fixed — the
per-window build was validated across a full shutdown/start with the agent coming up on
the boot path, windows attaching, and ZERO `EnumWindows failed`. `tools/viewcheck/
coldboot-test.sh` does the real shutdown/start check.

## The pattern being corrected (still binding)

The repeated failure in this project has not been the individual bugs - it is declaring the
work finished on the strength of whichever checks happened to pass, and leaving the user to
find what those checks could not see. Every result in the 2026-08-01 entry was measured
against a control or a screenshot, and the single most important fix (a capture-thread
deadlock) was found only by running two overlapping windows — exactly the scenario the
acceptance demanded, not a check that happened to pass.

---

## Historical (pre-2026-08-01, Phase 2A live-session build) — kept for reference



The numbers below are from a LIVE-SESSION binary (no reboot): package `4.2.2+agent.12457021ab71`
(agent `1245702`, CI run 30622146664), installed on win-idd-test via its own installer and
re-validated end to end AFTER every fix in this session.

## (a) Phase 2A — MET

| metric | stock | this build |
|---|---|---|
| frame cost p50 during drag | — | **917 us (0.92 ms)** |
| windows interrogated / frame | ~67 | **1.03** |

Bar was < 5 ms. Raw records: `instrumentation/bench-e2e-final.txt` (+ earlier runs
`bench-rc`, `bench-wobfix`, `bench-final`, `bench-revert10`, all under the bar).

## (b) ACCESS_LOST — MET

`RecreateDuplication: duplication recreated in place after 1 attempt(s) - windows kept`, zero
unmap/destroy, agent alive, and — the check that matters — dom0 window images **update** after
recovery (1/1 changed; frozen would be 0/1).

Caveat unchanged and stated plainly: the trigger is a desktop switch, not literally a
resolution change. qrexec runs in session 0 where the display APIs fail
(`EnumDisplaySettings` = FALSE), so a programmatic resolution change cannot be driven from the
harness. The recovery is keyed on the DXGI error, not the cause.

## (c) Office chrome — MET

`GUEST-COUNT=5`, `MAPPED-OF-OURS=1`. Counted from the agent's own `SendWindowMap` log.
Real-Office validation still outstanding (chromerepro's strips are larger than real chrome).

## (d) Upstream diff — READY, NOT SUBMITTED

`upstream/access-lost-recovery.patch`, 6 commits cherry-picked onto upstream `431e4517` as
`agent/pr-access-lost`, verified to build standalone in CI (run 30618973361). Awaiting explicit
approval of the exact diff and text.

Note: the occlusion-clipping and damage-registration fixes below are NOT in that PR. They are
separate changes and want their own review; the ACCESS_LOST PR stays scoped.

## Defects fixed this session

Every one was found by checking OUTPUT, not logs, after the previous suite reported green.

| defect | presented as | found by |
|---|---|---|
| recovery impossible after a desktop switch (`E_ACCESSDENIED`, thread on the old input desktop) | every dom0 window uniformly black | dom0 pixel check |
| framebuffer grant not refreshed after recovery | dom0 images byte-identical forever while the guest changed | md5 across captures |
| damage delivered to occluded windows | menu items corrupting their host window; debris when windows overlap | protocol trace |
| hidden windows contributing to the occlusion region | windows going partially blank — **a regression I introduced with the clipping fix** | code review of my own change |
| damage registered against a stale origin | contents wobbling within the frame | protocol trace ax/ay vs lx/ly |

### Wobble — measured, then eliminated

Same scripted drag, measured in-guest with no cross-VM capture skew:

| | stale origin | dx p95 | dx max | dy max |
|---|---|---|---|---|
| before | **52%** | 22 px | 38 px | 20 px |
| final | **0%** | **0 px** | **0 px** | **0 px** |

This contradicts my earlier conclusion in `WOBBLE-STATUS.md` that wobble was architectural and
unfixable in the agent. There is a genuine architectural floor — dom0's geometry can never be
perfectly current — but essentially all of the observed magnitude was avoidable in-agent
staleness, and it is gone.

## Test stability — full suite on the final build, one sequence

```
deployed binary            gui-agent.exe 92920 bytes, .orig backup present, running
ACCESS_LOST                recreated in place after 1 attempt, no teardown, agent alive
content after recovery     dom0 images updated 1/1
Office chrome              GUEST-COUNT=5  MAPPED-OF-OURS=1
protocol invariants        all hold (25 records)
wobble desync              stale=0%  dx max=0  dy max=0
drag p50                   917 us
interrogated/frame         1.03
```

## Suite credibility

Seven checks have been observed FAILING on builds with the relevant defect injected, and
passing again on the shipping build (see `instrumentation/ACCEPTANCE-PROTOCOL.md`): both
clipping directions, `popup-override-redirect`, `damage-within-window`, the two geometry
invariants, and ACCESS_LOST content freshness. The in-place-recovery assertion and the wobble
measurement were proven against the real pre-fix builds.

Two checks remain unproven by negative control (`menu-announced`,
`origin-known-for-damaged-windows`); both guard against missing data rather than a code
defect, and their PASS is not counted as evidence.

## Open, with honest status

1. **The dom0 rectangle over menus — UNRESOLVED.** The trace proves the menu is announced
   `override_redirect=1`, so dom0 is not treating it as a managed window. Whether what the
   user sees is Qubes' by-design anti-spoofing outline on popups or an empty frame with
   missing content cannot be distinguished from inside this qube: `local.WinScreenshot`
   captures neither override-redirect windows nor decorations. `dom0/07-install-fullscreen-
   screenshot.sh` is written and ready; it needs a one-time install because it does not keep
   the isolation property of the existing service.
2. **Real-Office validation** of the chrome predicate.
3. **Absolute pixel registration** is established by the protocol trace, not by screenshot
   diffing: `compare-views.py` now refuses to judge in four situations where it previously
   emitted confident numbers it had no basis for.

## What is NOT claimed

That the visual defects are fixed. Their *mechanisms* were found, fixed, and the fixes
verified by measurement; whether the screen now looks right is the human check, and that is
the one thing this qube cannot perform.
