# Research plan: dismissing a guest menu whose owner is being dragged

Handoff document. Written 2026-08-17 after SIX failed implementation attempts in one session. The
point of this plan is that **the next person measures before implementing** — every failure below
came from assuming what a code path runs under, or what an API does cross-process, instead of
checking. Do not add a sixth mechanism until Experiment 1 has an answer.

## The problem, precisely

In seamless mode, dom0 can move a guest window while a menu belonging to that window is open. On
native Windows this state cannot arise: the click that grabs a title bar dismisses the menu first. A
dom0-driven move never delivers that click to the guest, so the menu is left open in a configuration
Windows itself never produces, and then **every way of presenting it is wrong**:

- **composited** (synthesized into the owner's buffer): the menu is painted at a fixed offset, so it
  rides along with the window while the real menu stays put;
- **detached** (materialized as its own window): it strands as a bordered dom0 window at the
  position the owner has left. Captured 2026-08-16: Explorer's Home ribbon panel rendered as its own
  red-bordered window on top of an unrelated terminal.

Owner's judgement at the end of the session: the underlying nuisance is **cosmetic and low
priority** — *"ok let it be for a while"*. Do not spend heavily on it, and do not let it block the
release of the fixes that are already verified.

## What is established (measured, do not re-derive)

| fact | evidence |
|---|---|
| Menus do not move when their owner moves | they are separate top-level windows; the composite offset is what makes them appear to |
| Synthesis eligibility is decided by **geometric containment** | `SynthQualifies`, `SYNTH_OVERHANG_MAX` = 12 px, `main.c` |
| The relevant block runs on EVERY tracking pass, not only on movement | gated on `SynthChildCount > 0`; `coordsChanged` is computed separately in the same function |
| It reproduces in Notepad and Explorer | those popups measure `synth=yes`; menus opening OUTSIDE the owner (Edge's 3-dot) are never synthesized and cannot fall off |
| Explorer's two ribbon modes are NOT this bug | pinned ribbon = client area (part of the window); collapsed = transient overlay. Native behaviour, mapped onto member vs non-member |
| The menu does **not** auto-dismiss | owner-confirmed. What dismisses it when clicking away is the **click**, not the focus change |

## What has been ruled out (all measured on the rig)

| mechanism | outcome |
|---|---|
| materialize at drag freeze (`PwDragFrozen` / `DaemonDamageHeld` hooks) | **never fired** on a dom0-driven move — 0 hits. Dead code for the case that matters |
| materialize by membership (child did not move while owner did) | fired correctly, but detaching sooner only performs the artefact sooner |
| `PostMessage(WM_CANCELMODE)` to owner and to menu | fired **9x** in one drag, ignored; child re-synthesized on the next pass |
| `SetForegroundWindow(owner)` | returned **TRUE** and changed nothing — the menu's OWNER IS that window, so activation never leaves it |
| `SendInput(VK_ESCAPE)` | fired, ignored — but see E1b: this delivers to the FOCUSED window, and a menu holds capture, not focus, so the key may never have reached the owner's modal loop |
| `PostMessage(owner, WM_KEYDOWN/UP, VK_ESCAPE)` (E1b) | fired **once**, ignored; menu then materialized as usual. n=1 — see the caveat in E1b |

All of it was reverted; the tree is back to containment-only behaviour.

## The actual open question

**What, if anything, can a SYSTEM-context service do to a menu owned by another user's process?**

Everything above failed in a way consistent with a single explanation — the agent runs as
`NT AUTHORITY\SYSTEM` while the window belongs to `WIN-IDD-TEST\user` — and that same identity
mismatch has already been proven to block two unrelated things this week: `SetWindowLongPtr`
(`ERROR_ACCESS_DENIED`) and `PrintWindow` of override-redirect popups (returns blank). But it has
**not been proven** for menu dismissal; it is currently an inference. Experiment 1 settles it.

## Experiments, in order

Each states what to run and what result means what. Stop as soon as one succeeds.

### E1 — Does identity explain it? (do this first)

The agent already ships a proven escape hatch: `SpawnHelperAsUser()` in `main.c` launches a one-shot
copy of the agent under the window owner's token (`--restyle-caption` uses it, and it works where the
in-process call was refused). **Nobody has tried dismissal from that helper.**

Add a `--dismiss-menu <hwnd>` mode that, running as the user, tries in order: `EndMenu()`,
`PostMessage(WM_CANCELMODE)`, `SendInput(ESC)`. Log which one closes the menu.

- **Any of them works** → the whole problem was identity, the fix is to route dismissal through the
  helper, and E2–E4 are unnecessary.
- **None works** → identity is NOT the explanation, and the mechanism itself is wrong for a reason
  yet to be found. Continue.

### E1b — Deliver ESC to the OWNER's queue — **TRIED 2026-08-17, FAILED**

Implemented and measured before this plan was handed over. `posted ESC to owner 0x102ca` appears in
the log, the menu stayed open, and the containment path materialized it as usual. Reverted.

CAVEAT ON THE STRENGTH OF THIS RESULT: the post fired **once** across six synthesized popups in that
session, because the gate (`coordsChanged && !childMoved`) is narrow. So this is n=1 - consistent
with the five other failures, but not by itself conclusive. If E1 shows the user-context helper CAN
dismiss a menu, re-run this variant from the helper before concluding that posted key input is the
wrong idea; it may have been the identity, not the message.

The reasoning below is retained because it still explains why the earlier `SendInput` attempt was
aimed wrongly, and it remains the right thing to re-test from the helper.

#### original rationale

Owner's observation, 2026-08-17, and it explains why the `SendInput(ESC)` attempt failed rather than
merely recording that it did: **a menu holds mouse capture but not keyboard focus**. It runs a modal
message loop on the OWNER's thread, so the key has to arrive in the owner's queue to be seen by that
loop. `SendInput` delivers to whatever has focus at the time — during a dom0-driven drag that is not
guaranteed to be the owner, so the key may simply never have reached the loop.

    PostMessage(owner, WM_KEYDOWN, VK_ESCAPE, lParam);
    PostMessage(owner, WM_KEYUP,   VK_ESCAPE, lParam);

Note this is NOT the `WM_CANCELMODE` case that failed: that asked the window to cancel a mode, which
a cross-process post from SYSTEM was refused/ignored for. This is ordinary keyboard input into the
queue the modal loop is already pumping.

- **Works** → done, and it is the cheapest possible fix.
- **Fails** → check whether posted input is being filtered cross-process (UIPI applies to posted
  messages in a way it does not to `SendInput`), which points at running it from the user-context
  helper of E1, then at E2.

### E2 — AttachThreadInput + EndMenu

`EndMenu()` affects the calling thread's menu, which is why calling it from the agent does nothing.
`AttachThreadInput(GetCurrentThreadId(), ownerThreadId, TRUE)` joins the owner's input queue, after
which thread-scoped input calls act on that thread. This is the documented route for exactly this
class of problem and **was never tried**.

Try from the agent, and if refused, from the user-context helper. Detach in all paths.

### E3 — Ask the OS what it thinks is happening

`GetGUIThreadInfo(ownerThreadId, &gti)` reports `GUI_INMENUMODE` and `hwndMenuOwner`. Two uses:

1. a **reliable detector** of "a menu is up", far better than inferring it from geometry — which is
   what produced the false positives that dismissed menus on quiet passes;
2. a check on whether the OS still considers the menu active at the moment our attempts fail. If
   `GUI_INMENUMODE` is clear while the menu is visibly on screen, we are not fighting a menu at all
   and every mechanism above was aimed at the wrong object.

### E4 — Synthesize the click that Windows would have delivered

Native dismissal comes from the **click**, not focus (established above). dom0 withholds it because
the drag is happening on its side. Measure first what the guest actually receives during a
dom0-driven drag (`ProtoTrace`, `QGAPROTO,msg=MOTION|BUTTON` lines), then consider injecting a
non-client click. **Treat this as a last resort**: injecting synthetic clicks into a guest is a
blunt instrument with obvious ways to go wrong, and it must never land inside application content.

## How to reproduce and measure

- Rig: `win10-clean`, driven only via `tools/qtest` (`run`, `ps`, `push`, `pushrun`, `shot`).
  `QTEST_VM=win10-clean` must be set on every call — the bare form silently targets `win-idd-test`.
- Repro: open Notepad's File menu (or an Explorer ribbon dropdown), then drag the window **from
  dom0**. Note a guest-side `SendInput` drag does NOT reproduce it: it bypasses dom0's motion path.
- Log markers already in the tree: `QGAPROTO,msg=SYNTH`, `SYNTHPAINT`, `owner geometry changed,
  materializing child`. Enable `ProtoTrace=1` under
  `HKLM\Software\Invisible Things Lab\Qubes Tools\gui-agent` (note: NOT `HKLM\SOFTWARE\Qubes\...`,
  which nothing reads).
- `LogVerbose`/`LogDebug` are below the default level; set `LogLevel=5` in the same key to see them,
  and restore it afterwards.
- `tools/winwatch.cs` enumerates override-redirect surfaces that `qtest shot` cannot see (they are
  absent from `_NET_CLIENT_LIST`), with the agent's own predicates mirrored.
- A composited artefact is only visible in a **full-desktop** capture (`qtest fullshot`); per-window
  shots show clean windows because the artefact lives in dom0's composition. Ask before taking one -
  it captures the whole desktop - and delete it after.

## Rules for whoever picks this up

1. **Measure the mechanism before building on it.** Four of five failures were avoidable by one
   probe. If a claim is "this API will do X cross-process", test it in isolation first.
2. **Verify the code path actually runs** before attributing behaviour to it. The freeze hooks were
   dead code for the reported case and looked plausible for hours.
3. **A log line proves intent, not outcome.** `caption strip` logged success while the window kept
   its caption; read the state back.
4. After any bulk edit, compare `{`/`}` counts against HEAD before committing — the revert here broke
   brace balance on the first attempt.
5. **Do not pin a transient popup into the owner's buffer** to stop it drifting. That is what creates
   the orphaned panel; it trades a small artefact for a worse one.
6. This is cosmetic. If it costs more than a session, park it again and say so.
