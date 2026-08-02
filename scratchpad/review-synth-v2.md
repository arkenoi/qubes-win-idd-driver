# Adversarial re-review — synth heal burst v2 (`519e0cb`, branch `synth-repatch-timer-v2`)

Base `b299011`. Files: `gui-agent/main.c`, `gui-agent/main.h`, `gui-agent/capture.c`.
Read-only review of the committed tree; nothing built, no VM contact.

## VERDICT: **NEEDS_WORK**

Both v1 blockers are genuinely addressed — this is not a repeat of v1's failure. The idle-cost
claim holds under my own reading, and the `capture.c` ordering fix is correct in substance.
What blocks it is the same *class* of defect that sank v1, in a new place: **the change's own
bounding argument is the logical negation of its own root-cause claim**, and the sufficiency of
"3 passes over 350 ms" is unmeasured. Under one reading the fix is unnecessary; under the other
it reintroduces the reported bug for any popup that finishes painting (or is re-blanked) later
than 350 ms. That is decidable only with instrumentation, and this project's own rule is
instrument-before-implement.

The minimal correct changes are in §6; they are small (≈15 lines) and do not change the shape
of the design.

---

## 1. BLOCKER 1 (unbounded idle churn) — **FIXED as stated for idle; cost claim is WRONG for repeating stimuli**

### What I verified independently

* `SynthNextHealTimeout()` (`main.c:2935-2945`) returns `INFINITE` after a single read of
  `g_SynthHealArmed`, before any lock or list walk. With no burst armed the main loop's wait is
  byte-for-byte what it was. **The idle-cost claim is true.**
* Arming sites are exactly two: `SynthActivate` (`main.c:1234`) and the `geomChanged` branch for
  a synthesized child in `UpdateWindowData` (`main.c:2211`). `git show 519e0cb` confirms no
  third site. Both are on the main thread, both under `g_csWatchedWindows`
  (`AddWindow`←`ExamineWindow`←`TrackWindows`, and `UpdateWindowData`'s documented contract).
* `geomChanged` (`main.c:2167-2172`) is a true edge detector: the fresh values are written back
  unconditionally on the same pass, so a window that sits still never re-arms. The long-lived
  synthesized child from `instrumentation/e2e-b299011/win10-regression.md:292-297` (owned,
  caption-less WinForms child, `SYNTHPAINT rx=81,ry=75` constant) therefore costs **one** burst
  when it appears and nothing afterwards. **This is the case v1 got wrong and v2 gets right.**
* Schedule arithmetic is correct: `50 << (3 - SynthHealLeft)` after the decrement gives gaps
  50 / 100 / 200 → passes at **+50 / +150 / +350 ms**. Matches the claim.
* `GetTickCount()` wrap is handled everywhere by `(LONG)(a - b)` on `DWORD`s. Correct.
* Disarm paths: `SynthDeactivate` zeroes `SynthHealLeft` only when the owner's last child goes
  (`main.c:1256-1257`) — correct, a two-child owner keeps healing the survivor.
  `RemoveWindow`'s owner-death loop (`main.c:1438-1452`) frees the owner without touching the
  global cache; `SynthHealPass` then finds nothing armed and sets `g_SynthHealArmed = FALSE`.
  **One no-op wakeup, never a missed pass — as claimed.** Same for `SetSeamlessMode`'s list reset.
* No spin: every timeout pass either consumes a `SynthHealLeft` or leaves a strictly future
  deadline, and `SynthHealPass` re-derives `(armed, deadline)` authoritatively at the end
  (`main.c:3041-3042`). A deadline already past yields a 0 wait → one immediate `WAIT_TIMEOUT`
  that makes progress. Note `now` is sampled *before* the lock, so a long pass can judge later
  owners "not due" and vote a past deadline — that costs one extra iteration, not a spin.

### Where the claim is nevertheless wrong

The commit and notes state: *"WORST CASE PER POPUP: 3 wakeups for the popup appearing, plus 3
more in the 350 ms after it last changed shape."* That is worst case **per arming event**, and
arming is guest-controlled and repeatable. The true bound is: **≤3 copies per arm, arms
unlimited**.

Concrete: I traced the three stimulus rates the review asked about.

| stimulus | geometry-change period | what actually happens |
|---|---|---|
| hand drag / joint owner+child motion (documented, 58 maskpushes in 2.6 s = 2/step) | ~16–30 ms | arms faster than the deadline → deadline is pushed forward every arm → **no heal pass ever fires during the motion**, only ≤20 Hz *no-op* wakeups (lock + list walk, no copy, no `MSG_SHMIMAGE`). Then 3 passes after motion stops. **Bounded, cheap. Claim holds.** |
| slow/animated geometry change: cursor-tracking comctl32 tooltip, IME candidate window, resizing/cascading flyout, a window oscillating between two rects | ~150–350 ms | arm → pass at +50 (full re-copy + `SendWindowDamageEvent` + `LogInfo SYNTHPAINT` per child) → pass at +150 → next arm resets. **Standing ~5–10 Hz cadence of full re-copies for as long as the stimulus lasts** — i.e. v1's rejected behaviour, at up to 2× v1's rate, reachable from the guest. |
| static | — | zero. Correct. |

This is materially better than v1 (v1 needed only a long-lived child *existing*; v2 needs
repeated geometry changes) and in every such case DDA frames are flowing anyway, so the heal
copies are pure duplication of work the in-frame path is already doing. It is not by itself a
blocker — but it is a **cost claim stated more strongly than the code supports**, which is
exactly what got v1 rejected, and the fix is two lines (§6.1).

### Cache staleness — verified sound

`g_SynthHealArmed` / `g_SynthHealDeadline` are moved *earlier only* at the arm sites and
re-derived exactly in `SynthHealPass`. Both are main-thread-only (arm sites and the pass all run
on the main loop; `SynthHealPass` writes them *outside* the lock but on that same thread). No
path can make the cache miss a pass. Confirmed.

---

## 2. BLOCKER 2 (crash risk in `RecreateDuplication`) — **FIXED; rationale still names the wrong invalidator**

`capture.c:218-271` read in full at this revision.

Correctness checks, all pass:

* `framebuffer` / `grantRefs` are stashed and `ctx->framebuffer` / `ctx->grant_refs` cleared at
  the **top** of the locked region (`:231-234`), before the held-frame `ReleaseFrame` (`:236`),
  before `IDXGIOutputDuplication_Release` (`:252`), and before the revoke (`:266`). Ordering is
  as claimed.
* Revoke uses the **stashed address** — identical to the address `XcGnttabPermitForeignAccess2`
  produced (`:553`). No count is involved in this API. Right address.
* **No double revoke:** `CaptureTeardown` (`:433`) revokes only `if (ctx->xc && ctx->grant_refs)`,
  and `grant_refs` is now NULL. `GetFrame` re-maps/re-grants only `if (!ctx->grant_refs)` (`:529`),
  so the recovery path re-grants exactly once.
* **No leak:** `free(grantRefs)` is now unconditional. This is a *behaviour change*, not a no-op:
  previously a non-NULL `grant_refs` with a NULL `ctx->xc` leaked. The notes call it "no reachable
  behaviour changes"; it is better described as fixing a leak on a path argued unreachable.
* **Nothing reads `ctx->framebuffer` between clear and revoke.** Inside the region: nothing.
  On the main thread, `ProcessNewFrame(&capture->frame, capture->framebuffer)` (`main.c:3740`) is
  fenced by the `frame_event`/`ready_event` handshake and cannot overlap. `SynthHealPass` reads it
  and now correctly sees NULL → `sourceValid` FALSE → burst dropped.
* **Does not break the capture thread's own use:** after recovery, `GetFrame`'s
  `LastPresentTime == 0 && ctx->grant_refs` skip (`:520`) is bypassed because `grant_refs` is NULL,
  and the re-grant branch runs. The early-return at `:297` (resolution changed) leaves exactly the
  same state the old code left. No regression.
* `g_FbBits` dangling: `StopFrameProcessing` now clears `g_FbBits`/`g_FbPitch` (`main.c:3561-3562`),
  and `SynthHealPass`'s `capture->framebuffer == g_FbBits` identity test catches a stale publish
  after a re-grant that lands at a different address. If the re-grant lands at the *same* address
  the pointer is valid again, so that is safe too. The residual (guard→memcpy instant) is real,
  correctly described, and is the pre-existing `SynthActivate` exposure — not new.

**One correction to the rationale.** The commit says releasing the duplication "invalidates the
`MapDesktopSurface` mapping `g_FbBits` points at". That is not what the code does:
`ctx->frame.mapped` is set TRUE only on the **first** frame (`capture.c:540`), and that frame's
`ReleaseFrame` calls `UnMapDesktopSurface` (`:702-711`) and clears it. From frame 2 onward the
agent — and dom0 — read that address with the surface already unmapped; its validity is pinned by
the **grant**, not by the map. So the operation that actually invalidates it is
`XcGnttabRevokeForeignAccess`, and the *old* ordering ran that revoke while `ctx->framebuffer` was
still non-NULL, i.e. while a reader could pass the guard. The new ordering covers that, so the fix
is right — but the stated reason is the second-order one, and after v1 was rejected for an inverted
claim this deserves to be said accurately in the commit message.

**Accepted.** This hunk is shippable as-is.

---

## 3. NEW DEFECT (major) — the bounding argument negates the root-cause claim

`main.c:1194-1199` and `:1008-1015` justify the burst with:

> *"Any LATER pixel change inside a synthesized child is by construction damage to the desktop
> framebuffer, so it produces a DDA frame and the in-frame paths handle it"*
> *"anything slower than that is not a mid-draw capture, it is a window that repaints later —
> which is desktop-framebuffer damage, produces a frame, and is already handled by the in-frame
> paths."*

The root cause claims the opposite: that the popup's own paint on a static screen does **not**
result in a heal, which is why the menu stays blank. Both cannot be true.

* **If damage→frame→heal holds** (the bounding argument): then the popup's first paint produces a
  frame, `ProcessNewFrame`'s dirty-rect patch (`main.c:3295-3299`) and its 200 ms full re-copy
  (`:3305-3310`) run, and the reported defect could not persist. The fix would be treating a
  symptom whose cause lies elsewhere.
* **If it does not hold** (the root cause): then the burst is the *only* heal, and its 350 ms
  horizon is the whole safety margin. A popup that finishes painting at +400 ms is blank forever —
  **the reported bug, reproduced.**

### Concrete failure scenario for the second branch

There is a mechanism in this tree that fits the user's symptom better than "mid-draw capture", and
it puts the failure squarely past 350 ms on this guest:

1. `SynthActivate` calls `SynthUpdateMask(owner)` → `WcSetMask` (`wincapture.cpp:339-356`), which
   sets the mask **and** `ch->dirty = true` → the WGC engine thread will re-`PrintWindow` the owner.
2. `SynthActivate` then immediately does `PwPatchSynthRect` → writes the menu pixels into `PwBuffer`.
3. A recapture that was **already in flight** when `WcSetMask` ran is using the *old* (empty) mask.
   When it completes it copies `PrintWindow` output over the whole window — and `PrintWindow` does
   not render owned popups — so it overwrites the just-patched menu region with owner-only pixels.
   The menu reads as **blank**, showing the owner's content.
4. Static screen → no further DDA frame → nothing corrects it. Moving the cursor into the menu
   produces a hover repaint → real damage → the in-frame patch heals it. **Exactly the reported
   symptom, including the "only when the cursor moves into it" part.**

Under this mechanism the burst *does* usually work — but only because +50 ms happens to outlast a
`PrintWindow`. This project has measured `PrintWindow` at **15–18 ms on the WARP guest**
(`main.c:3226-3228`) with tracking interrogations stalling ~8 ms each behind it, and the whole
premise of the drag work is that this number blows up under load. A recapture that lands at
+400 ms — entirely plausible on a 4-vCPU WARP guest with Defender/Search running, which is
exactly the state the b299011 e2e run documented (first bench 1.97 ms p50 vs 698 µs settled) —
lands **after the last burst pass** and blanks the menu with nothing left to heal it.

I cannot decide between the two branches from source; that is the point. The root cause has not
been measured, and the constant that carries the whole fix (350 ms) was chosen against an
unmeasured mechanism.

**Worst-case answer to the review's key question:** static screen, keyboard-opened menu, no further
input — best case correct at +50 ms, stated worst case +350 ms, **true worst case: never**, if the
event that blanks or completes the popup lands after +350 ms. There is no later heal: the in-frame
periodic pass requires a frame, and the premise of the fix is that no frame arrives.

---

## 4. NEW DEFECT (minor) — the in-frame path is *not* "completely unchanged"

`SynthHealPass` writes `owner->SynthLastFullPatch = now` (`main.c:3025`), the same stamp the
in-frame 200 ms periodic pass consumes (`main.c:3306`). So the last heal pass at +350 ms **pushes
the in-frame periodic re-copy out to +550 ms**. If frames resume at +360 ms the first in-frame full
re-copy is now 190 ms later than it would have been on the parent build. That widens precisely the
blind window §3 is about.

The commit claims *"the in-frame paths are now completely unchanged; this is an additional trigger
only."* The code is unchanged; its **schedule** is not. Either drop the stamp (accept one redundant
in-frame copy) or say so in the commit.

---

## 5. Other findings (none blocking)

* **Starvation, not a bug:** `WaitForMultipleObjects` prefers signalled objects over the timeout, so
  with a continuously-signalled source (vchan traffic) a due pass can be deferred indefinitely.
  Benign — a busy loop means frames are flowing and the in-frame path is doing the work.
* **`WAIT_TIMEOUT` ordering:** correct and necessary. `WAIT_TIMEOUT` (0x102) is tested at
  `main.c:3645` **before** the `>= MAXIMUM_WAIT_OBJECTS` check at `:3657`; `WAIT_FAILED`
  (0xFFFFFFFF) still falls into the failure branch. The `continue` skips only the
  `DEBUG_DUMP_WINDOWS` block and the `exitLoop` test (`exitLoop` cannot be set on that path);
  `vchanIoInProgress` is re-initialised at the top of every iteration and is never read anywhere
  in the function. `capture` is the loop-local and is NULL-checked inside `SynthHealPass`.
  **No misclassification path found.**
* **Field discipline:** `SynthHealLeft`/`SynthHealDue` are zeroed by the `ZeroMemory` at
  `main.c:882` (the only `WINDOW_DATA` allocation path); entries are never reused after `free`.
  Mutated only from `SynthArmHeal`/`SynthHealPass`, both main-thread, both under
  `g_csWatchedWindows`. Correct.
* **Degenerate inputs to `SynthHealPass`:** NULL `g_FbBits`, NULL `capture`, `PwBuffer == NULL`,
  vchan down, fullscreen, `g_LocalScreenDestroyed` → burst dropped (`main.c:3001-3006`), no copy,
  no log storm. A child whose rect falls outside the owner buffer is caught inside
  `PwPatchSynthChildClipped` (`:2874-2893`) with a `LogWarning` and returns; the pass still
  decrements `SynthHealLeft`, so **it cannot spin** — worst case 3 warnings per child per burst.
  `PwDetachWindow` does set `PwBuffer = NULL` (`perwindow.c:363`), so the guard is meaningful.
* **Log volume:** `PwPatchSynthChildClipped` emits `LogInfo QGAPROTO,msg=SYNTHPAINT` per child per
  pass, and INFO is visible at the guest's default `LogLevel=3`. 3 extra INFO lines per popup per
  burst — acceptable, and it is what makes the notes' idle-verification step checkable.
* **/W4 /WX:** I found nothing that would fail. All tick differences are explicitly `(LONG)`-cast;
  `(remaining > 0) ? (DWORD)remaining : 0u` is type-consistent; the shift operand
  `(UINT)SYNTH_HEAL_PASSES - owner->SynthHealLeft` is 0..2 after the decrement, never negative,
  never ≥32; `armed`/`deadline` are initialised; both new statics are used (no C4505);
  `(const BYTE*)capture->framebuffer` from a `const CAPTURE_CONTEXT*` is legal C. The
  declaration-after-statement in `RecreateDuplication` matches existing style in both files
  (`main.c:3838`, `capture.c:266`). No shadowing. **CI is still the real check.**

---

## 6. Minimal correct changes

**6.1 — bound re-arming (fixes §1's cost claim), 2 lines.**
At the `geomChanged` site (`main.c:2211`), do not reset a burst already in flight:

```c
if (owner->SynthHealLeft == 0)
    SynthArmHeal(owner);
```

and in `SynthHealPass`, skip a due copy the in-frame path has already covered — insert before the
`owner->SynthHealLeft--` block:

```c
if ((LONG)(now - owner->SynthLastFullPatch) < SYNTH_FULL_PATCH_MS)
{
    owner->SynthHealLeft--;                 // consume the pass, do no work
    owner->SynthHealDue = now + (...same gap...);
    /* vote as usual */
    continue;
}
```

This makes the heal strictly complementary to the in-frame periodic pass, caps total full
re-copies at the in-frame rate no matter what the guest does, and removes §4 as a side effect.

**6.2 — close the >350 ms tail (fixes §3), one of:**

*(a) preferred, addresses the mechanism:* give `wincapture` a mask generation counter — `WcSetMask`
bumps `ch->maskGen`; a capture that started with an older `maskGen` is discarded rather than
committed. That removes the stale-mask overwrite deterministically and makes the burst a backstop
rather than the fix. Small, local to `wincapture.cpp`.

*(b) cheap fallback:* re-arm the burst once from the owner's *next* completed capture, or extend to
4 passes (+750 ms). This is still a timing guess and should be labelled as one.

**6.3 — measure before either.** One instrumented build answers it, and it is the same harness the
notes already describe: log, per popup, (i) tick of `SYNTH`, (ii) tick and dirty-rect count of every
DDA frame in the following second, (iii) for each `SYNTHPAINT`, whether the copied bytes differed
from what was already in `PwBuffer`. If (ii) is empty and the last differing (iii) is early, the
burst is right and 350 ms is generous. If (ii) is non-empty, the in-frame path is already firing and
the real defect is the overwrite in §3 — a different, cheaper fix. Either result makes the next
commit message defensible; without it this ships a second unevidenced timing constant.

**6.4 — commit-message corrections:** state the true bound ("≤3 passes per *arming event*", not per
popup); name `XcGnttabRevokeForeignAccess`, not the duplication `Release`, as the operation the
reordering guards against (§2); drop or qualify "the in-frame paths are now completely unchanged"
(§4); and describe `free(grantRefs)` as a leak fix rather than a no-op tidy-up.
