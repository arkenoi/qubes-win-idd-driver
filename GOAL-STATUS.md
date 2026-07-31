# Goal status — 2026-07-31

## BLOCKING: the build is NOT shippable

After a **cold boot** the agent fails to enumerate windows and the qube renders nothing in
dom0. Reproduced twice, against a stock control:

| | dom0 windows (same scene) | `EnumWindows` failures |
|---|---|---|
| stock QWT 4.2.2 (`3D2E6BCE`) | **3** | 0 |
| ours (`493ab911fe9a`) | **0** | 5+, `0x80070006 ERROR_INVALID_HANDLE` |

Failing in both `AddAllWindows` and `CollectZOrder`, so windows are never added to the watched
list and never mapped. The user saw artifacts on the desktop before opening any application.

**Root cause not established.** A fail-safe was added so a failed enumeration degrades to
"do not clip" instead of "clip against an arbitrary order" (which made the desktop window
claim the whole screen and suppress everyone's damage). That prevents the worst symptom but
does not fix the enumeration failure, and the qube is still blank on cold boot.

Stock is currently installed on win-idd-test so the qube works.

## Why this was not caught

Every check in the suite restarted `gui-agent.exe` inside a **live session**. The boot path was
never exercised. The restart even *clears* the fault, so a suite built on restarts cannot see
it. `tools/viewcheck/coldboot-test.sh` now exists and does a real shutdown/start, but it was
written after the user found the defect, not before.

Two control runs during this investigation also reported "0 dom0 windows" purely because the
scene had silently failed to launch (`qtest pushrun`'s first push intermittently sends 0
bytes). That nearly produced two wrong conclusions about which build was at fault. The
cold-boot test now retries until the scene demonstrably ran.

## The pattern being corrected

The repeated failure in this project has not been the individual bugs - it is declaring the
work finished on the strength of whichever checks happened to pass, and leaving the user to
find what those checks could not see. Tearing "confirmed" from a mis-cropped comparison,
menus "verified" from window styles rather than the wire, ACCESS_LOST "verified" from a log
line while dom0 was frozen, a regression test that "would have caught" a defect it provably
does not catch, and now a build declared ready that renders nothing after a reboot.

Status below is therefore what has been measured, not a claim that anything is done.

---



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
