---
name: guest-capture
description: MANDATORY before writing or changing any code that screenshots a Windows guest. There is ONE correct way to capture a guest's screen; call the helper, never qtest fullshot directly. Load this before adding a capture to any harness, probe or test.
---

# Capturing a guest's screen — call the helper, never fullshot

## The one rule

**Call `w_screen` (`mgmt/harness/e2e-wait.sh`). Do not call `./tools/qtest fullshot` from new code.**

```bash
source mgmt/harness/e2e-wait.sh
verdict=$(w_screen "$VM" "some-tag" "$OUTDIR")   # RECOVERY | BLACK | DESKTOP | UNKNOWN | NOWINDOW
```

`w_screen` already does the correct thing and it is the only place that should know how:

1. **per-window first** — `qtest shot` → `local.WinScreenshot+<vm>`, gated by the
   `win-idd-testbed` tag, returns ONLY that guest's windows;
2. **desktop capture only if that yields nothing**, because a guest with no session (early install,
   Automatic Repair, a stranded install) maps no windows while dom0 still draws its framebuffer;
3. **crop this guest out of the desktop capture and DELETE the desktop tar** before returning.

The verdict survives. The desktop never becomes an artifact.

## Why this exists

`qtest fullshot` photographs the **entire dom0 desktop** — every other qube, the owner's editor,
dom0 terminal scrollback. Three such captures reached a PUBLIC repo.

On 2026-08-29 the rule went into the experimenter skill: *never escalate to fullshot merely because
a per-window shot came back empty.* On **2026-08-30** `e2e-wait.sh` was promoted into this repo with
`w_screen` calling `qtest fullshot` unconditionally, and it stayed that way for ten days - through
dozens of runs, and through my own repeated citing of that very rule.

No excuse survives inspection here. The rule was written, it was read, it was quoted in this
project's own commit messages, and the code did the opposite the whole time. Prose in a skill did
not stop it. It was found on 2026-09-09 only because a stall capture happened to be opened by hand
and contained the owner's notes.

**So this skill does not rely on being read.** `tools/lint-harness.py` FAILS the commit when new code
calls `qtest fullshot` outside the sanctioned allowlist below. If you believe you need a new direct
caller, you are changing that allowlist deliberately, in a commit, with a reason - not deciding it
in the moment.

## The only sanctioned direct uses of fullshot

An **override-redirect** dom0 window (a notification bubble, a menu, a tooltip) is absent from
`_NET_CLIENT_LIST` and cannot be captured any other way. That is the dom0 render witness in
`a0-toast-bridge.sh` and `p3a-etw-gate.sh`. Also dom0-side compositing defects.

If you add one: it must be a **deliberate, commented** call, the artifact must go to `scratchpad/`
or an evidence dir (never a tracked path), and it must be justified in the commit message.

## Reading a result

- **An empty per-window tar is NOT "no windows".** Three causes: the target does not exist or lacks
  the `win-idd-testbed` tag (the dom0 service then exits non-zero writing nothing, which looks
  identical); the tool discarded the window; or genuinely no windows. Exclude the first two before
  concluding the third — and never respond by photographing the desktop.
- `NOWINDOW` is a legitimate verdict and callers already handle it. A stalled guest reporting
  `NOWINDOW` is information, not a reason to escalate.
- **Read the screen, do not just confirm pixels exist.** The text in a cmd window is often the only
  place the real error appears. `Read` the .png.

## Never

- Never put a capture — of any kind — on a tracked path. `evidence/` and `scratchpad/` are
  gitignored; the commit+push hooks content-inspect staged archives and the gate has no legitimate
  bypass.
- Never add a new direct `qtest fullshot` caller to a harness "just for now".
