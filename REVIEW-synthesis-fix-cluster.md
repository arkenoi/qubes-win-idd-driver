# Review: the "off-path" fix cluster (agent HEAD = `6b5b298`)

## 1. The premise is inverted — this cluster is ON-path, and the guest is the outlier

**Per-window capture is ON by default in this fork. Our guest's `PerWindowCapture=0` is our own test residue, not a shipped default.** Three checks, all seconds long:

- `agent/gui-agent/perwindow.c:70` — `DWORD enabled = 1; // default ON: this build exists to exercise the new path`, then `CfgReadDword(NULL, REG_CONFIG_PERWINDOW_VALUE, &enabled, NULL)`. The registry value only *overrides*; `CfgReadDword` leaves the caller's default untouched when the value is absent.
- Nothing in `guest/`, `mgmt/`, `tools/`, `.github/` or any `.ps1`/`.wxs`/`.inf`/`.reg` ever writes `PerWindowCapture` — while `guest/firstboot-setup.ps1:44-45` writes `SeamlessMode` and `DisableCursor` at the *same* key. The absence is real, not a search artifact.
- The `0` on our guest came from a prior typing A/B and was deliberately restored at the end of the 08-04 validation run. `FINDINGS.md:2220` calls it "the shipped default"; that description is wrong and is already retracted at `FINDINGS.md:2180-2205`.

The runtime gate is satisfied in the field too: synthesis needs `PwIsAttached(owner)`, which needs daemon protocol ≥ `0x10007` (gui-common 4.2.3, March 2023); dom0 here reports `0x10008`.

So the question is not "do these matter if the path is off". It is "these run by default — are they right?" Additionally, three of the seven (`d6ab61c`, `3c12071`, `aaa8c37`) live in `ShouldAcceptWindow()` and one (`98eed30`) in `send.c`; **those four change behaviour for every user regardless of the flag.**

One correction to the brief's other premise: "an in-place gui-agent restart destroys gui-daemon" is itself retracted (`FINDINGS.md:2303-2340`). A *force-killed* restart loses the daemon probabilistically; a graceful stop via `Global\QGA_SHUTDOWN` (`scratchpad/graceful-stop.ps1`) does not. Cold boot is required for boot-path acceptance, not for every A/B.

---

## 2. Per-commit verdicts

| Commit | What it does | Verdict | The one reason |
|---|---|---|---|
| `0a334c1` | Composite synthesis: owner-contained popups painted into the owner, never announced | **Keep the code, flip the default to 0 now** | It is on by default while carrying a wild-pointer loop *it introduced*, an unmerged mask-sort fix, a stale framebuffer pointer, and an open user-reported artifact. Reverting 10+ interleaved commits is itself an unvalidated change; turning it off is one line and reversible. |
| `d6ab61c` | Exempts override-redirect popups from the `SM_CXMIN/CYMIN` floor (4 px floor) | **Revise (narrow), do not revert** | It keys on `IsOverrideRedirect`, which means "no `WS_CAPTION`" (`main.c:791-797`) — far broader than "popup", and it is why Office's strips ever reached the chrome rules. But reverting re-opens the half-cut keytip badge defect it fixed. Gate it `&& PwEnabled()`, or anchor it to `Xaml_WindowedPopupClass`. |
| `3c12071` | Rejects Win11 click-through uncapturable shell overlays (snap-layouts phantom) | **Keep** | Narrowest rule in the set, verified against the real defect and in the false-positive direction (Win+Z's non-transparent `XamlExplorerHostIslandWindow` is still announced). Optional: also require `WS_EX_TOPMOST` (it was present in the measurement); it fails *closed*, so tighten cheaply. |
| `98eed30` | Never send a per-window message the daemon has no CREATE for | **Keep — highest value in the cluster; fix the producer too** | `gui-daemon` `exit(1)`s on any non-CREATE message for an unknown window (`xside.c:3942-3956`), killing the qube's whole GUI. But the gate is a net, not a fix: the reachable producer (`UpdateWindowData`'s materialization loop, `main.c:2407-2413`, and `ToggleMap`, `main.c:815-820`) is still ungated on `CreateSent`. |
| `aaa8c37` | Rejects Office's `MSO_BORDEREFFECT_WINDOW_CLASS` shadow strips by class | **Keep as-is; do not "revise the message"** | Validated on *real* Office (control `98eed30`: 4/4 strips synthesized, 731 `SYNTHPAINT`, artifact visible; fixed: 0/0, user confirmed "weird shadow is gone"). Caveat below on attribution. |
| `66fc670` | Never re-home an owned popup onto an unrelated sibling | **Keep** | Validated 3/3, and it is one of the two things that closed the real-Office shadow. Needs the stale comment at `main.c:1043-1047` corrected and one Win11 `GW_OWNER` check. |
| `6b5b298` | Never capture while the secure desktop is up | **Needs evidence — fix or revert this session** | Its stated mechanism is impossible in this code, its privacy rationale is backwards, it introduced a cold-boot risk, and it logs nothing on either edge, so it cannot be validated. |

### Where the stances disagreed, and my call

- **Revert synthesis (`0a334c1`)?** Two of three stances said yes. **No.** The decisive measurement they conditioned it on cannot fail as specified (see §4, T6), the announce-and-slice-feed alternative was never run on Win11, and unwinding the most-repaired subsystem in the tree while its known defects are open is exactly the unvalidated change CLAUDE.md forbids. **But "keep" without action is also indefensible** — hence: flip the default, land the three fixes, re-enable behind a measurement.
- **Revert `d6ab61c`?** No. Its fail-open story ("badges just become invisible again") only holds in the branch where synthesis is *also* gone. With synthesis live, pre-`d6ab61c` behaviour was the user-reported half-cut badge defect.
- **Revert `66fc670`?** No. It is the only ruling that proposed deleting a validated fix against a *reproduced permanent-corruption* bug, on borrowed authority from an undecided parent decision.
- **Demote `aaa8c37` / rewrite its message?** No. The claim that "real 8 px strips are already stopped twice over by `98eed30`'s overlap rule and `d610454`'s sub-floor drop" is **measurably false**: both were present in the `98eed30` control and neither fired, because the strips were adopted by the *fallback* owner (the maximized `OpusApp` frame, which they do overlap) rather than by the dialog they are flush with. Rewriting the message to that causal story would encode a wrong cause in the history.

---

## 3. The uncomfortable findings

**a) A NEW live defect, introduced by `0a334c1`, that nobody logged — a wild-pointer loop on the duplication-recovery path.** `agent/gui-agent/main.c:3565-3576`:

```c
WINDOW_DATA* repaint = (WINDOW_DATA*)g_WatchedWindowsList.Flink;
while (repaint != (WINDOW_DATA*)&g_WatchedWindowsList)
{
    repaint = CONTAINING_RECORD(repaint, WINDOW_DATA, ListEntry);
    if (repaint->Synthesized) continue;          // <-- added by 0a334c1
    ...
    repaint = (WINDOW_DATA*)repaint->ListEntry.Flink;   // the advance it skips
}
```

`continue` skips the advance, so the next iteration re-applies `CONTAINING_RECORD` to an already-converted pointer. `ListEntry` is nowhere near offset 0 (`main.h:63` — preceded by `Handle`, three DWORDs, three BOOLs, `Caption[256]`, `Class[256]`, `X/Y/Width/Height`, ~1 KB), so the pointer marches backwards through the heap, reading `Synthesized`, `IsVisible`, `Width/Height`, `Handle` and `Flink` from garbage — on the main event-loop thread, holding `g_csWatchedWindows`, potentially calling `SendWindowDamageEvent` with a garbage HWND. Trigger: seamless mode + in-place duplication recovery (lock/unlock, UAC, desktop switch, resolution change) with **any** synthesized popup open. Confirmed by `git show` that this exact line came from `0a334c1`. This is strictly worse than the `g_FbBits` hazard, on the same path, and it is the path Phase 2B-resize must exercise constantly.

**b) Two more defects live on HEAD, both with fixes already written or trivial.** The mask row-sweep is still unsorted — `grep -i sort gui-agent/wincapture.cpp` returns nothing, and `git merge-base --is-ancestor d3a5fbc HEAD` says NOT-ANCESTOR, so branch `fix-mask-sort-v2` (measured: 162518 wrongly-copied rows vs 0) was never landed. And `g_FbBits` (`main.c:78`, assigned once at `main.c:2915`, never cleared) is a raw pointer into the granted DDA framebuffer that `RecreateDuplication` revokes, frees and NULLs from the *capture* thread (`capture.c:246-251`), while `PwPatchSynthRect` reads it from the event-loop thread with only a NULL check.

**c) Yes — we are partly repairing our own regression.** Upstream applies one unconditional size floor. `d6ab61c` punched a 4 px hole in it keyed on a predicate that means "caption-less", which is what let Office's 866x8 / 8x558 strips into the pipeline at all. On stock QWT they die on the floor and the whole Office chain never starts. `aaa8c37` is genuinely load-bearing *on this fork*; it would be worth roughly nothing upstream. Say so in the commit trail.

**d) Composite synthesis' bug budget is bad, and its stated benefit is unmeasured.** ~20 commits in 3 days are synthesis defence or repair against 1 that introduced it; two of those defects cost the qube its entire GUI, one burned a permanent shadow into Word's document area, and three are still open (§3a/b) plus one user-reported artifact ("leftovers appear and disappear behind the modal dialog", `FINDINGS.md:2262-2270`, observed on the *fixed* build at `PerWindowCapture=1`). What it buys is the removal of the 2 px frame `gui-daemon` deliberately draws around override_redirect windows (`xside.c:2248`, `BORDER_WIDTH 2`) — the standard Qubes look for every Linux menu, and a security feature. The one genuine argument for it (that dom0's `force_on_screen` can reposition an announced popup independently) has never been measured. That does not justify reverting it today. It does justify not shipping it on by default while three memory-safety-class defects are open in it.

**e) `6b5b298` has no surviving justification as written.** Its cited hang was retracted (Windows Update). Its comment (`wincapture.cpp:76-81`) claims the agent drives `PrintWindow` "at LogonUI" — impossible: channels only ever hold HWNDs from `WcAddWindow` (`wincapture.cpp:344`), whose sole caller is `PwAttachWindow` for agent-tracked windows on the Default desktop. The privacy rationale is *backwards*: the DDA framebuffer is granted once, read-only, for the whole desktop, and dom0 reads it with zero agent participation — idling per-window capture stops no pixel, it freezes the per-window buffers at their **pre-lock** content, so dom0 keeps displaying the unlocked desktop for the duration of the lock. And it introduced a boot-path risk: `AttachThreadToInputDesktop` now returns without attaching when input is not Default (`wincapture.cpp:96-100`), the capture thread calls it exactly once at startup (`wincapture.cpp:226`), the only other call is the failure branch at `:285` — i.e. the recovery path *is* the path this commit disabled — and `c.dead = true` (`wincapture.cpp:278`) is never cleared anywhere in the file, so five failures retire a window's capture permanently. What survives is a thin waste argument (~4 `PrintWindow`s/sec avoided, at the cost of an `OpenInputDesktop` poll every 200 ms — net saving unquantified, possibly negative).

---

## 4. What to test next — ordered, single-threaded

Fixes first; they are cheap and two of them are memory-safety-class on the default path.

**T0 (code only, no VM). Land three fixes.** (i) `main.c:3569` — advance before `continue`. (ii) Clear `g_FbBits`/`g_FbPitch` inside `ctx->frame.lock` in `RecreateDuplication`, or pass the framebuffer as an argument like `PwSliceCopyAndDamage` already does. (iii) Cherry-pick `d3a5fbc` (mask sort) from `fix-mask-sort-v2`; also reconcile `fix-joint-maskpush-v2` against HEAD. (iv) Decide the default: set `enabled = 0` in `PwInit` **or** write `PerWindowCapture` explicitly in `firstboot-setup.ps1`. My recommendation: default 0 until T1–T3 pass, then flip back with a recorded reason.

**T1. The wild-pointer loop — regression check with a failing control.** *Precondition:* `PerWindowCapture=1`, cold boot (this is a boot-and-recovery path). *Run:* open a window with an owner-contained popup that synthesizes (verify `SYNTHPAINT` in the log first — no synth, no test), then force duplication recovery: lock/unlock, or a UAC prompt, or a resolution change. *Control that can FAIL:* the same scene on unfixed HEAD (`6b5b298`) — expect agent hang, AV, or frozen dom0 windows. Judge pixels via `qtest shot`, not the log. If the control does not fail, the trigger condition was not met (no synthesized window at recovery time) — fix the scene, do not record a pass.

**T2. `6b5b298` boot path, and whether it should survive at all.** *Precondition:* add logging on **both** edges of the idle branch (`wincapture.cpp:236-240`) and inside `InteractiveDesktopIsInput`'s failure return — without it this commit is unfalsifiable and cannot be kept under CLAUDE.md's instrument rule. `PerWindowCapture=1`, cold boot, sit at the lock screen ≥60 s before logging in (so the agent starts while Winlogon holds input). *Run:* log in, check the agent log for `PrintWindow` capture activity and `qtest shot` for live windows. *Control that can FAIL:* `98eed30` (pre-commit), where `AttachThreadToInputDesktop` always attached. If the fixed build shows dead channels or a permanently idle sweep, revert `6b5b298`.

**T3. The open user-reported artifact ("leftovers behind the modal dialog").** *Precondition:* `PerWindowCapture=1`. *Run:* move a tracked window across another; count `SendWindowDamageEvent` for the window being **uncovered**. *Control that can FAIL:* the same motion at `PerWindowCapture=0`, where the artifact should be absent. Zero damage for the uncovered window while the mover crosses confirms the occlusion mechanism. Note the tooling limit already found: window-manipulation probes must be native tools, not P/Invoke from the qrexec PowerShell.

**T4. Prove `98eed30`'s gate has ever FIRED.** Its drop path logs at Warning with a counter (`send.c:246-254`), yet no run in FINDINGS reports it. *Precondition:* `PerWindowCapture=1`, real Office Document-Recovery scene. *Run:* a build with the gate present but `aaa8c37` + `66fc670` reverted (i.e. the strips are admitted and adopted again). *Expect:* `dropping MSG_… for 0x…: no CREATE was sent` in the log **and the qube's GUI survives**. That is the only way its PASS stops being unproven.

**T5. Mask-sort validation, post-landing.** Two popups on one owner where the left one is discovered second; `d3a5fbc`'s own measurement (162518 rows copied into masked columns without the sort, 0 with it) is the control able to fail.

**T6. The synthesis justification — run it so it CAN fail.** The proposed test ("open a Notepad File menu and see if dom0 moves it") is non-discriminating: `force_on_screen` (`xside.c:1846-1939`) sets `do_move` only on TOO_WIDE/TOO_TALL/LEFT/TOP/RIGHT/BOTTOM_BORDER_OFF_SCREEN, so a mid-screen menu returns 0 with probability 1, for geometric reasons unrelated to synthesis. *Run instead:* at `PerWindowCapture=0` (all override-redirect popups are announced there — `PwWindowEligible` rejects them anyway, `perwindow.c:213-216`), open context menus flush against the **bottom and right work-area edges** and over the taskbar strip. *Control that can FAIL:* a mid-screen menu in the same run must log `returns 0`; the edge cases must log `returns 1`. Then check whether the repositioned menu visibly jumps and whether clicks land (`HandleConfigure` → `SetWindowPos` should make hit-testing follow, so expect a jump, not a mis-click). No synthesis-disabled build is needed.

**T7. BLOCKED here — needs the Win11 guest.** Does `Xaml_WindowedPopupClass` carry a non-NULL `GW_OWNER` pointing at an untracked `PopupHost`? If yes, `66fc670` silently reverts `a5012a5`, and because `d610454` makes sub-floor popups "synthesize or **drop**, never announce" (`main.c:1245-1257`), the keytip badges degrade to **deleted**, not announced. One `winenum`/`dump-windows` run with an Alt-nav keytip visible settles it. `3c12071`'s `WS_EX_TOPMOST` tightening is in the same bucket — `XamlExplorerHostIslandWindow` does not exist on Win10. Label both untestable on `win-idd-test`.

---

## 5. Upstream posture

**Submit now: nothing.** Not one commit in this cluster is ready as-is.

- **`3c12071`** is the best standalone candidate — it sits in `ShouldAcceptWindow`, depends on no fork-only code, and fixes a documented Win11 artifact class that upstream's README already lists. Hold until there is Win11 evidence from a guest we control and the `WS_EX_TOPMOST` question is settled.
- **`98eed30` layer 1** (the CREATE-set gate) is the only other upstreamable piece, and only after splitting: layers 2–3 reference synthesis, which does not exist upstream. Before submitting, close the objections a maintainer will raise: two sources of truth for "announced" (`WINDOW_DATA.CreateSent` vs `g_CreatedWindows`); the window-0 exemption comment that is factually wrong about the daemon (`send.c:219-221` vs `xside.c:3942-3956`) and duplicates `g_LocalScreenDestroyed`; the symmetric double-CREATE killer left ungated (`xside.c:3944-3948`); a dropped send returning `ERROR_SUCCESS` and being memoized as delivered (`send.c:571` → `main.c:1347-1355`); and an O(n) scan inside the global vchan critical section on every damage message. Also fix the *producer* (`UpdateWindowData`, `ToggleMap`) — a maintainer will ask why the net exists without the hole being closed.
- **`aaa8c37`**: describe honestly as **fork regression repair**, not as a general 2A-chrome fix. On upstream the 8 px strips die on the size floor; the rule buys nothing there. Submit only if real Office is ever observed producing floor-clearing `MSO_BORDEREFFECT` windows.
- **`d6ab61c`**: never upstream alone, and probably not at all — upstream has no synthesis, so the exemption is pure cost with zero benefit. If it ever goes up, it goes as the class-anchored variant.
- **`0a334c1`, `66fc670`, `6b5b298`**: fork-only code (composite synthesis, `wincapture.cpp`). Not upstreamable in any form.
- **Anything asking `gui-daemon` not to `exit(1)` on a window-scoped protocol slip** is a Phase 3 protocol conversation: design writeup, user review, upstream design issue referencing #1861, before any code.