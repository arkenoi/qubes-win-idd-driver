# Overlapping windows show each other's pixels — PRE-EXISTING, architectural

Reported by the user: *"there are artifacts if i move one window over another, they just get
erased when underlying window gets focus."*

## Reproduced and controlled

`zorder.ps1`: open two Notepad windows, position B overlapping A, focus B, then focus A.

| agent | result |
|---|---|
| ours (Phase 2A + chrome + ACCESS_LOST) | window B's dom0 image contains **A's pixels** in the overlap region — A's client area and status bar baked in |
| **stock shipped QWT 4.2.2** | **identical artifact** (`artifact-zorder-STOCK.png` vs `artifact-zorder-ours.png`; the images differ only in a cursor-column digit) |

**NOT a Phase 2A regression.** Same reasoning as the tearing artifact: control first, blame second.

## Mechanism

The agent grants the whole desktop framebuffer once and sends per-window rectangles. dom0
paints each window by reading *that window's rect out of the shared framebuffer*. But the
guest framebuffer holds the **composited** desktop: wherever A overlaps B, the pixels in B's
rectangle genuinely are A's. So an obscured window's dom0 image necessarily contains the
obscuring window's content.

It only becomes visible when the guest's stacking and dom0's stacking disagree, and they
disagree because **the agent never tells dom0 about z-order or focus**:
- measured: `SendWindowConfigure` count = **0** across the entire focus change;
- `gui-agent/send.c` has no focus / raise / restack message at all — only `MSG_MAP` with
  `transient_for`;
- `EVENT_OBJECT_REORDER` (0x8004) and `EVENT_SYSTEM_FOREGROUND` (0x0003) are not hooked —
  though note the OLD per-frame code did not act on them either, since it only sent
  `MSG_CONFIGURE` on geometry change. Hooking them alone would therefore NOT fix this.

## What a fix would require (not attempted here)

This is a protocol/daemon-level issue, i.e. CLAUDE.md Phase 3 territory ("anything touching
the GUI protocol, gui-daemon, or grant lifecycle: design writeup first, user review, upstream
design issue before code"). Sketch of the options:

1. **Tell dom0 the stacking.** The agent learns z-order (hook `EVENT_OBJECT_REORDER` /
   `EVENT_SYSTEM_FOREGROUND`, walk `GetWindow(GW_HWNDPREV)`) and sends it. Needs a protocol
   message the Windows agent does not currently send — check whether the daemon already
   honours something equivalent for the Linux agent before inventing one.
2. **Capture per-window instead of per-rect-of-desktop.** `PW_RENDERFULLCONTENT` /
   `DwmpQueryWindowThumbnail`-style per-window capture would give each window its own,
   uncomposited pixels. Much more invasive and costlier per frame.
3. **Track B (IddCx)**: an indirect display driver per window is not how IddCx works, so this
   does not fall out of Track B for free.

Option 1 is the cheap one and the right first design writeup. Worth an upstream issue on its
own — it is independent of everything else in this repo.
