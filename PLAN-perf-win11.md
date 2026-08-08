# Plan: eliminate the Windows 11 overhead, or beat stock

Exit condition set by the user (2026-08-08): execute until the overhead is gone **or** we have
an improvement over stock. This plan is written against measured numbers, not remembered ones.

## The measured baseline — and the reframing it forces

Median CPU, % of one core, from the four-row matrix plus the controlled BDA run:

| metric | win10 stock | win10 ours | win11 stock | win11 ours (IDD) | win11 ours (BDA) |
|---|---|---|---|---|---|
| idle   |  0.105 | 0.027 | **0.000** |  0.240 | 0.343 |
| typing | 32.608 | 4.375 | **3.126** | 14.993 | 9.540 |
| drag   | 33.087 | 12.961 | **12.327** | 16.108 | 12.324 |
| scroll | 47.834 | 8.911 | **4.064** | 13.931 | 8.907 |

**The problem is not that Windows 11 is expensive.** It is that:

- on **Windows 10** our agent is dramatically better than stock — typing 7.5x, scroll 5.4x,
  drag 2.6x cheaper;
- on **Windows 11** stock is already good, and **we are worse than stock**: typing 3.05x
  worse, scroll 2.19x worse, drag at parity, idle worse in absolute terms.

So the goal is not "make Win11 as cheap as Win10". It is: **stop losing to stock on Windows 11
without giving up the Windows 10 win.** Everything below is measured against that.

There are also **two independent overheads**, and they must not be conflated again:

- **A — agent on Win11**: ours(BDA) 9.540 vs stock 3.126 typing. Same display path, so this is
  ours.
- **B — the IddCx display path**: ours(IDD) 14.993 vs ours(BDA) 9.540 typing. Same agent, so
  this is the display path, and it is *additional* to A.

## Working hypothesis for A, and why it is plausible

Windows 11 presents 1.88x more frames than Windows 10 for identical input (488 vs 259 over
20 s, agent/display/resolution held constant), while per-frame cost differs by only 1.12x
(117 vs 104 us). So the surplus is frame COUNT.

That hurts *us* far more than it hurts stock, because the two designs scale differently in
presents:

- **stock** captures one composited screen and sends dirty-rect metadata — per-present cost is
  small and roughly flat in window count;
- **ours** captures per window with `PrintWindow` (~15-18 ms per capture on a WARP guest) —
  per-present cost is paid *per affected window*.

Multiply a per-window cost by 1.88x the presents and the Win10 advantage inverts. This predicts
exactly the observed shape: typing and scroll (small, frequent damage → many cheap presents for
stock, many expensive per-window captures for us) hurt most, drag (large damage, already
throttled by the move-settle logic) stays at parity.

**This is a hypothesis with a decisive test**, not a conclusion: if it is right, the per-window
fast path's hit rate is low and raising it moves typing/scroll toward stock.

## RESULTS (2026-08-08 evening) — the hypothesis above is half wrong

The working hypothesis said the surplus was workload-driven: Windows 11 repainting more *per
unit of input*. Measurement says otherwise, and the correction matters more than the original
guess.

**D4 — the surplus is AMBIENT.** Windows 11 presents **18.75 fps with no input at all**
(30 s idle, 3 reps: 563/603/460 frames), carrying ~350k real dirty pixels per frame with
`empty=0` — so these are genuine repaints, not cursor-only frames the agent already drops.

That is **77% of Windows 11's own 24.4 fps workload rate**, and it exceeds Windows 10's entire
workload rate of 12.9 fps. So most of what the 488-vs-259 comparison attributed to "workload"
was background repaint that happens whether or not anyone is using the machine. The
within-Win11 comparison is the load-bearing one and needs no Win10 side.

It also explains the idle CPU row that looked anomalous: ours 0.343 vs stock 0.000. Stock's
single composited screen capture shrugs at ambient repaint; our per-window `PrintWindow` pays
for every one of them, at idle, forever.

**D5 — desktop effects are NOT the cause.** Frame counts moved +2% to +9% with effects off,
inside 9–25% run-to-run noise and in the *wrong direction*. Transparency/Mica/animations are
ruled out. `disable-visual-effects.ps1` stays in the tree but is not the lever.

**D2 — the 0% hit rate was our own defect, not a falsification.** `PwScreenUnchanged` required
`g_ZOrderValid`, and `CollectZOrder` (`main.c:2754`) deliberately skips its `EnumWindows` pass
unless an override-redirect popup is on screen. So the check refused 100% of the time: 0 skips
in 5557 decisions. Replaced with an order-free test (foreground window + no other visible
window overlaps); re-measuring now. **The coalescing premise remains untested**, not disproven.

### What this does to the mechanism

The two terms are now clearly separable, and they multiply:

    our CPU  ~  (presents Windows generates)  x  (our per-present, per-window cost)
                 ~19/s ambient + workload         PrintWindow, 15-18 ms on WARP

Stock is cheap in the second term, so the first term barely hurts it. We are expensive in the
second term, so the first term dominates us. **Both are worth attacking, and neither
substitutes for the other.**

## Diagnostics in flight, and what each one decides

| # | measurement | decides |
|---|---|---|
| D1 | CPU vs baseline, instrumented build | did coalescing reduce work at all |
| D2 | hit rate `pwskip/(pwskip+pwcap)` | does the fast path fire, and what caps it |
| D3 | FocusRaise off vs on | is occlusion the cap on D2 |
| D4 | idle present rate, **both guests** | is the surplus ambient or workload-driven |
| D5 | desktop effects off vs on | do Win11's default effects cause the surplus |

D4 is the fork in the road: ambient → the target is whatever repaints unprompted (shell
surfaces), and the remedy is a post-install tweak. Workload-driven → shell tweaks are a dead
end and the work is all in the capture path.

## Interventions, ranked by expected value over cost

Ordered so the cheapest decisive things happen first. Each is gated on the diagnostic that
justifies it; nothing here is implemented before its gate says so.

**RE-RANKED 2026-08-08 after D4/D5.** Shell quieting moves from 3 to 1: it attacks the term
now known to dominate (~77% of presents happen with no input), and effects — the other
candidate for that term — are ruled out. The former 1 and 2 are capture-path work and stay,
because they attack the *other* factor in the product above.

0. **Identify and quiet whatever repaints 19x/sec on an idle desktop.**
   Step one is `locate-idle-repaint.sh`, which diffs consecutive whole-desktop fullshots during
   idle and attributes the changed bounding box against enumerated window rects — no agent
   change, no build, and it names the surface instead of testing suspects at ~45 min per guess.
   Step two is machine-wide policy on the `disable-hw-accel.ps1` delivery path (candidates:
   `AllowNewsAndInterests`, `EnableDynamicContentInWSB`, `TurnOffWindowsCopilot`), which
   survives later software installs and applies to accounts created afterwards.
   Expected value: largest of anything here, and it is registry-only.

1. **Raise the coalescing hit rate** (gate: D2 shows it firing but low).
   The screen-hash compare already skips byte-identical recaptures. If the hit rate is capped
   by the occlusion guard, and D3 shows focus-raise lifts it, that is a one-line behaviour
   change already built and switchable.
2. **Skip per-window capture when the window's damage is empty** (gate: D2 shows `pwcap` high
   with unchanged content). Cheaper than the hash: intersect the dirty rect with the window
   rect *before* hashing, which is already done — the win would be tightening what counts as
   an intersection (sub-rect precision rather than whole-window).
3. **Shell-surface quieting** (gate: D4 ambient). Disable Win11 widgets/search-highlight/
   Copilot/notification polling via the existing post-install path. Cheap, shippable, no code.
4. **Desktop effects** (gate: D5 positive). Same path as 3.
5. **Reduce per-capture cost** (gate: 1-4 insufficient). `PrintWindow` is the expensive unit at
   15-18 ms. The alternatives are per-window WGC capture from DWM redirection surfaces (no
   occlusion dependency, but wants a D3D device on a WARP guest — measure before believing) or
   reading the window's region out of the granted framebuffer when provably unoccluded.
6. **Attribute damage to windows** (gate: 1-5 insufficient, or D4/D5 both nil). DDA gives dirty
   rects, not "which window dirtied this". Correlating rects with window rects inside the agent
   is the only way to find the *producing* surface. This is an agent code change and the point
   at which the cheap options are exhausted.
7. **The IddCx path (overhead B)** — untouched by 1-6. ours(IDD) costs 5.45 points of typing
   CPU more than ours(BDA) with the same agent. Diagnose separately once A is settled; do not
   let it contaminate A's measurements.

## Exit criteria — quantitative, no interpretation required

**Primary (the user's bar): beat stock on Windows 11.** Against stock win11:

| metric | must reach | currently ours(BDA) | gap |
|---|---|---|---|
| typing | <= 3.126 | 9.540 | 3.05x |
| scroll | <= 4.064 |  8.907 | 2.19x |
| drag   | <= 12.327 | 12.324 | met |
| idle   | <= 0.105 (win10 stock; win11 stock reads 0.000) | 0.343 | not met |

**Secondary (do not regress what already works):** Windows 10 ours must stay at or below
typing 4.375, drag 12.961, scroll 8.911.

**Non-negotiable:** the 14-check acceptance gate keeps passing, and the seamless correctness
fixes stay. A performance win bought by dropping a correctness fix does not count.

## Rules this plan runs under

Taken from CLAUDE.md because every one of them has already been violated at least once here:

- interleaved reps, >= 3 per side, agent hash asserted at every point;
- a metric is stable on one unchanged binary before any verdict is read from it;
- missing data fails — never substituted with an approximation or a zero;
- a check counts as evidence only once it has been seen to FAIL;
- judge pixels and counters, not log lines that claim success;
- a reboot is part of acceptance, not an optional extra;
- retract loudly and immediately when a claim turns out wrong.
