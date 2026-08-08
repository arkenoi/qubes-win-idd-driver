# Design note: a never-occluding guest desktop

**Status: proposal, not started.** Per CLAUDE.md Phase 3 this touches the GUI protocol and
window model, so it needs review before any code.

## The idea

In a seamless setup dom0 already owns stacking: it draws the windows, decides what is on top,
and the user's notion of "in front" lives entirely there. The guest's own Z-order exists only
because Windows insists on compositing a desktop. RDP-style remoting exploits the same
observation - a remoted window is not occluded by the other remoted windows, because the
client composites them.

So: give the guest a virtual desktop large enough that **every top-level window gets its own
non-overlapping slot**, and let dom0 place them where the user actually wants them. The guest
never has one window on top of another; dom0 does all the stacking.

The IddCx driver is what makes this reachable. The Basic Display Adapter has a fixed mode
list, so a desktop big enough to tile every window was never available. An indirect display
driver reports whatever modes it likes - that is its core capability, already used for
arbitrary resolutions.

## What it would buy

This is the interesting part, because it collapses several separate problems at once:

1. **PrintWindow disappears from the hot path.** Today per-window content comes from
   `PrintWindow` (~15-18 ms per capture on a WARP guest) precisely *because* the screen cannot
   be trusted: another window may be on top. With no occlusion, the screen region for a slot
   *is* that window's content, so capture becomes a strided copy out of the framebuffer that
   is already granted to dom0.
2. **The measured Windows 11 overhead evaporates rather than being mitigated.** Win11 presents
   ~1.9x more frames than Win10 for identical input (488 vs 259 over 20 s, agent/display/
   resolution held constant). Each surplus present currently triggers a redundant
   `PrintWindow`. With screen-fed slots the cost of a redundant present drops to a dirty-rect
   intersection - the thing DDA already hands us.
3. **The occlusion guard in `PwScreenUnchanged` becomes unconditional.** That guard exists
   only because screen != window content when something overlaps. Remove overlap and the
   screen-hash short-circuit applies always, not just to unoccluded windows.
4. **Damage maps 1:1.** A DDA dirty rect intersects exactly one slot, so "which window
   changed" stops being a region-arithmetic problem.
5. **The compound-window and synthesis machinery loses its hardest case.** Owned popups,
   shadow strips and composited children are currently entangled with who covers whom.

## What it would cost - the honest list

None of these are fatal, but together they are a protocol-level change, not a patch.

- **Two coordinate spaces, everywhere.** The guest lives in slot space; dom0 lives in user
  space. Every `MSG_CONFIGURE`, every input event, every damage rect needs translation. Get
  one path wrong and windows land in the wrong place - the same class of bug as the seamless
  coordinate breakage the IDD activation notes already warn about.
- **Applications that read screen geometry.** `GetSystemMetrics(SM_CXSCREEN)`,
  `MonitorFromWindow`, work-area queries: an app that maximises would fill the whole tiled
  desktop. Per-window work-area lies are possible but this is where the sharp edges live.
- **Who assigns slots, and when.** Windows are created, resized and destroyed constantly; slot
  allocation becomes a live packing problem, with fragmentation. A window that resizes beyond
  its slot forces a re-layout, which is a bulk re-grant.
- **Framebuffer size.** Tiling N windows needs area proportional to their sum, not the screen.
  A few large windows on a 4K-class guest could mean a very large surface, and that surface is
  the thing granted to dom0.
- **Input routing and focus.** Hit-testing must happen in dom0's space and be translated back;
  focus follows dom0, not the guest's Z-order.
- **Anything that genuinely needs a composited desktop.** Screen capture inside the guest,
  magnifier tools, and full-screen exclusive apps see a desktop that does not look like a
  screen.

## The sharpest objection: allocation scales with desktop size

Raised by the user, and it is the strongest one so far because it attacks the *mechanism* (a
large desktop) rather than the goal (no occlusion). It deserves to be stated at full strength
rather than filed under "framebuffer size" above.

The asymmetry that makes it bite: on a normal desktop, overlapping windows **share** screen
area, so the composited surface is bounded by the screen no matter how many windows exist. A
tiled desktop's area is the **sum** of window areas. Tiling therefore systematically inflates
exactly the quantity that several allocations are proportional to - and it inflates it most in
the case the design is meant to help, many windows open at once.

What is proportional to desktop area on a guest with no GPU:

- the IddCx swapchain surface, times however many buffers are in flight;
- DWM's composition target - and DWM composites through WARP here, on the CPU;
- the Desktop Duplication desktop image and its staging surface;
- the agent's granted framebuffer, and with it the **grant reference count**, which is linear
  in pages: 3440x1440x4 B is ~18.9 MiB ~ 4.8k pages today, while a 16384x16384 desktop (the
  D3D11 maximum texture dimension, and therefore a hard cap on any single-desktop scheme)
  would be 1 GiB ~ 262k pages. Whether that collides with the domain's grant table limit is a
  dom0-side question that must be **measured, not assumed** - I have not verified it.

And a second-order effect that does not show up in any allocation count: a composition pass
streams the whole target through a CPU cache that does not grow with it. Cost per frame can
degrade non-linearly once the target stops fitting, which is precisely the "weird performance
impact" shape.

So the design as sketched trades redundant per-window captures for a permanently larger
software composition surface. On a guest with no GPU that trade could be net-negative, and
nothing measured so far says which way it goes.

**This reorders the experiments.** The desktop-size sweep below is now first, because it is a
pure measurement on unchanged, already-shipped code and it can kill the design before any of
the hard work starts.

**If the sweep says cost scales with area**, the single-giant-desktop form is dead, but the
idea is not. The fallback is **multiple IddCx monitors** - the driver can expose several, each
with its own swapchain sized to its own mode, so allocation tracks actual need instead of a
worst-case bounding box, and the 16384 texture bound stops applying to the aggregate. What it
buys in allocation it pays for in monitor hotplug churn on every window create/destroy, and
dom0's screen model would have to cope with many monitors. Worth designing only if the sweep
justifies it.

## Relationship to the fix landing now

The `PwScreenUnchanged` change (agent `0e8df01`) is the tactical version of the same insight:
*use screen content when it is a valid proxy for window content*. It is guarded to the cases
where that is provably true today. A non-occluding desktop is the strategic version - it makes
the proxy valid by construction rather than by check.

They are not alternatives. The tactical fix is small, measurable and shipping; this proposal
is a redesign of the window model and should be judged on its own evidence, starting with a
prototype that tiles two windows and measures whether screen-fed capture actually beats
`PrintWindow` on a WARP guest before any of the coordinate work is attempted.

## What I actually think (recorded for the later revisit)

Asked directly, rather than laid out as an option space.

**Tiling has a bad shape.** Its benefit is largest with many windows open - and so is its
cost, because that is exactly when the summed area diverges most from the screen area. A
design whose payoff and whose penalty both peak in the same case is one to be suspicious of.
The tactical `PwScreenUnchanged` fix also pays off most with many windows, but its cost is
O(window area), not O(desktop area). That asymmetry alone may be decisive.

**My prediction for the sweep**, written down now so it can be wrong in public: steady-state
CPU stays roughly flat with desktop area, because DWM composition is dirty-region driven and
most per-frame work tracks damaged area rather than total area. What I expect to scale is
memory, mode-change/transition cost, and any path that degrades to a full-target pass. So I
expect **memory and grants to be the hard wall before CPU is** - which, if right, points at
the multi-monitor variant rather than one giant desktop.

**The reframing I think is actually correct.** RDP does not enlarge the desktop either. It
does not tile. It gets non-occluded window content because **that content already exists**:
DWM composites the desktop *from* per-window redirection surfaces, so unoccluded pixels for
every window are already sitting in the guest, by construction, at no extra allocation. The
right analogue to "remote windows do not have occlusions" is therefore per-window capture from
DWM - `Windows.Graphics.Capture` via `IGraphicsCaptureItemInterop::CreateForWindow`, which
captures a window even while it is covered - and **not** a tiled desktop.

That would deliver the same properties the tiling design was invented for:

- window content independent of occlusion, so the guard in `PwScreenUnchanged` becomes moot;
- no `PrintWindow` in the hot path;
- damage attributable per window;

while costing **none** of the desktop enlargement: no summed-area framebuffer, no grant
explosion, no 16384 texture bound, no coordinate translation, no slot packing, no input
re-routing. CLAUDE.md already anticipates this ("Per-window WGC capture, Phase 2/#6, kills this
class structurally") - the connection to the user's RDP question is what is new here.

Its own risks, which are real and unmeasured: WGC wants a D3D device and these guests run
WARP, so per-window capture may be *slower* than the screen read it replaces; there is a
capture-border indicator on some Windows builds (suppressible via `IsBorderRequired` only on
newer ones); and it needs Windows 10 1803+/1903+ depending on the API surface used.

**So my recommendation for the revisit:** run the sweep as agreed, because it is cheap and it
settles the allocation question either way. But treat tiling as the *fallback*, and put
per-window WGC capture at the front of the queue - it is the design that actually matches what
RDP does, and it is testable without touching the protocol at all.

## "Plug in where RDP does" - where that actually is

Asked as the alternative to building a tiled desktop. Answering it precisely is worth more
than the tiling design was, because it turns out we are already standing in two of RDP's three
plug points, and the third is not what it looks like.

**1. Pixels - already there.** On modern Windows the display path for a remote session is an
*indirect display driver*: the same IddCx framework Track B already builds. Remote display is
the scenario IddCx was introduced for. If that is right there is no new place to plug in for
pixels - Track B put us at RDP's plug point already. **To verify rather than assert:** inside
an active RDP session, enumerate display adapters; a remote session should show an indirect /
remote display adapter rather than the machine's real GPU. Cheap to check, and it should be
checked before this paragraph is relied on.

**2. Window metadata - already there.** RemoteApp/RAIL (MS-RDPERP) sends per-window orders -
create, move, z-order, icon, destroy - over a virtual channel, and the client builds local
proxy windows from them. That is structurally what our agent already does with its window
messages over vchan. Same plug point, different wire format.

**3. The correction to the premise.** RemoteApp does not eliminate occlusion. It
**synchronizes z-order**: the client reports the stacking it is showing, and the server orders
its session windows to match. Remote windows look non-occluding because a RemoteApp session
normally contains *only* the remoted apps - there is nothing else in it to cover them - not
because of any capture trick. The well-known artifact is the proof: interleave a **local**
window between two remote ones and RemoteApp cannot represent it, because the server holds a
single z-order.

That correction is not pedantry. It hands us a design much cheaper than tiling.

## Z-order synchronization - the cheap version of the same idea

If dom0 pushed its stacking order to the guest and the agent applied it (`SetWindowPos`), the
guest's composition would agree with what the user is actually looking at. Then:

- the window the user is interacting with is top-most in **both**, so the screen framebuffer is
  a valid source for its content;
- the occlusion guard in `PwScreenUnchanged` - which is precisely the ceiling on the fix now
  under validation - starts succeeding for the window that matters most;
- and none of it needs an IDD, a tiled layout, coordinate translation, or a larger desktop, so
  **the entire allocation-scaling objection does not apply**.

It does not remove occlusion. It makes guest occlusion agree with dom0 occlusion - which is
what RDP actually does, as opposed to what the tiling sketch imagined it does.

### Does this need new bidirectional messaging? No - checked in source, 2026-08-08

**The transport is already bidirectional.** `agent/gui-agent/vchan-handlers.c:783-810`
dispatches daemon -> agent messages today: `MSG_KEYPRESS`, `MSG_BUTTON`, `MSG_MOTION`,
`MSG_CONFIGURE`, `MSG_FOCUS`, `MSG_CLOSE`, `MSG_KEYMAP_NOTIFY`, `MSG_WINDOW_FLAGS`,
`MSG_DESTROY`, `MSG_WINDOW_DUMP_ACK`. Nothing needs to be built to carry dom0's intent into
the guest; that channel is load-bearing already, since it is how input arrives.

**There is no stacking message.** The protocol enum
(`upstream/ro/qubes-gui-common/include/qubes-gui-protocol.h:136-166`) has no `MSG_RESTACK` or
`MSG_RAISE`. Full z-order synchronization - all N windows, not just one - would be a new
message, hence Phase 3.

**But partial synchronization already exists and is already acted on.** `MSG_FOCUS` reaches
`HandleFocus` (`vchan-handlers.c:689`), which calls `SetForegroundWindow(window)` at line 712 -
and line 713 is a commented-out `BringWindowToTop(window)`. Since dom0 focuses the window it
raised, the guest is already being told, once per interaction, which window belongs on top.

Three consequences, in decreasing confidence:

1. The window the user is actually working in is *probably already* top-most in the guest,
   because `SetForegroundWindow` normally raises. So the fast path's hit rate for the window
   that matters may already be good - which makes this a **measurement**, not an argument:
   `g_PwSkippedCaptures` against the number of eligible frames answers it directly.
2. The commented-out `BringWindowToTop` is a hint, not a free win. It was presumably commented
   out for a reason that is not recorded, and re-enabling it is a behaviour change that needs
   the same before/after treatment as any other.
3. What focus does NOT give is the stacking of windows 2..N. That is the part a real restack
   message would add, and the part worth a protocol proposal only if measurement shows the
   focused-window case is not already carrying most of the benefit.

`SetWindowPos`-driven restacking can also fight the guest's own focus and activation logic, so
any move beyond what already happens needs measurement rather than implementation-first.

## Actually running RDP - rejected, and why

The literal reading - guest runs an RDP server, dom0 runs a client - is out of scope. It would
replace a small vchan message protocol with a large protocol parser in dom0, and throw away the
zero-copy grant transport that already exists (established fact 1). That is a security-model
change, which this project does not make.

## Where that leaves the three candidates

| | occlusion handling | desktop size | protocol change |
|---|---|---|---|
| tiled desktop | removed by construction | **sum of window areas** | large |
| per-window WGC capture | content despite occlusion | unchanged | none |
| z-order sync | guest matches dom0 | unchanged | small, maybe none |

The two that do not enlarge the desktop are the two worth pursuing, and they compose: z-order
sync raises the fast path's hit rate now, WGC removes the dependency on the screen later.

## Experiments, in kill-first order

**1. Desktop-size sweep - does cost scale with desktop area at constant workload?**
Requires no new code at all: the IddCx driver already reports arbitrary modes, and the typing
and drag harnesses plus the QGAPERF instrumentation already exist. Hold the window set,
window sizes and input script identical; sweep the desktop through 1920x1080, 3440x1440,
5760x2160, 7680x4320. Read agent CPU, present rate and per-frame `tot`.

  - flat vs. area -> the allocation objection is bounded, continue to experiment 2;
  - scales with area -> single-giant-desktop tiling is dead; re-scope to multiple IddCx
    monitors, or drop the proposal and keep the tactical fix.

Note the interaction with the Windows 11 finding: Win11 already presents 1.88x more than
Win10 for identical input. If present rate *also* scales with desktop area, the two multiply,
and Win11 on a tiled desktop is the worst cell in the matrix. The sweep must therefore run on
both guests, not just one.

**2. Is a strided read from the granted framebuffer actually much cheaper than `PrintWindow`
for the same window?** Same window, same size, same guest. If the gap is small the whole
rationale weakens - and that costs an afternoon rather than a protocol change.

**3. Grant accounting at a large desktop.** Confirm what the domain's grant table actually
tolerates before assuming a large framebuffer can be granted at all. dom0-side, so it needs
the user.

Only after all three: coordinate translation, slot packing, input routing.
