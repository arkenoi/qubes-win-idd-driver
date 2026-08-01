# DESIGN — dom0 work-area propagation to Windows guests (protocol extension)

Status: DRAFT for user review, then upstream design discussion (references
qubes-issues #1861). NOT submitted anywhere. Per CLAUDE.md Phase 3 discipline:
no upstream contact without explicit user approval of this text.

## Problem

Windows sizes maximized windows and full-workspace overlays to the **guest work
area** (an OS-global rect the guest controls). In QWT seamless mode the guest work
area is derived from the guest's own screen (resolution mirrored from dom0's display,
minus the guest taskbar) — it knows nothing about:

1. **dom0's usable workspace** (dom0 panels reduce it — 31px top panel measured here);
2. **per-window dom0 decorations** (title bar ≈25px + frame borders ≈5px, consumed by
   every managed window the daemon creates).

Consequences, all observed and screenshot-verified on win-idd-test (FINDINGS.md
2026-08-01): a guest-maximized window's dom0 client cannot fit — the WM places its
client at (5,56); the right edge pokes 5px past the guest area (visible "double
border" against a full-width override-redirect overlay whose edge is at 3440); the
bottom rows fall off dom0's screen; and full-workspace overlays (Edge first-run) get
`force_on_screen`-shifted by the daemon, breaking alignment with the windows they
cover.

Linux guests do not exhibit this because their client windows are freely resized by
the dom0 WM — maximization is executed dom0-side and the guest X window just follows
the resulting client size. On Windows, maximization is executed *guest*-side from the
work-area rect, so the guest must know the right rect.

Related non-solutions tried:
- Mapping guest-maximize to dom0 `_NET_WM_STATE_MAXIMIZED_*` (via the existing
  WINDOW_FLAG_FULLSCREEN → maximize conversion): the dom0 WM maximizes to the dom0
  monitor, which need not match the guest's virtual screen at all (here: a 5120-wide
  ultrawide vs a 3440-wide guest → window maximized across 5120). Reverted.
- The daemon never sends its work area today: `update_work_area()` (xside.c) tracks
  `_NET_WORKAREA` but consumes it only for `force_on_screen` clamping.

## Proposal

### New daemon → agent message: `MSG_WORKAREA`

```c
/* daemon -> agent, protocol >= 1.9 */
struct msg_workarea {
    /* dom0 work area of the current desktop, in dom0 root coordinates */
    uint32_t x, y, width, height;
    /* frame extents the daemon's WM adds to a typical managed (decorated) window,
     * so the guest can reserve room for them per-window */
    uint32_t frame_left, frame_right, frame_top, frame_bottom;
};
```

Sent:
1. once after `MSG_XCONF` during handshake;
2. whenever `update_work_area()` observes a change (the daemon already re-reads
   `_NET_WORKAREA` on root `PropertyNotify`);
3. on `_NET_FRAME_EXTENTS` discovery change (first managed window mapped).

Daemon implementation sketch: extend `update_work_area()` to remember the last sent
rect and emit `MSG_WORKAREA` on delta; frame extents from `_NET_FRAME_EXTENTS` of any
managed VM window (or `_NET_REQUEST_FRAME_EXTENTS` at startup).

### Agent (qubes-gui-agent-windows) behavior

On `MSG_WORKAREA`:

```
usable = intersect(workarea, [0, 0, guest_screen_w, guest_screen_h])
guest_workarea = { usable.x + frame_left,
                   usable.y + frame_top,
                   usable.right  - frame_right,
                   usable.bottom }   // bottom: no dom0 chrome below managed windows
SystemParametersInfo(SPI_SETWORKAREA, 0, &guest_workarea, SPIF_SENDCHANGE)
```

then re-fit currently maximized windows (`ShowWindow(SW_MAXIMIZE)` refresh or
`SetWindowPos` to the new work area). Result: a guest-maximized window's rect equals
exactly the dom0 client rect the WM will grant it → 1:1 congruence, nothing cropped,
no sliver; full-workspace overlays (sized by apps to the work area / their owner
window) land inside dom0's workspace → `force_on_screen` becomes a no-op → overlay
and owner stay aligned.

Guest taskbar: QWT seamless hides it; if visible, Windows re-derives the work area
when the taskbar moves — the agent re-applies on `WM_SETTINGCHANGE` observation
(tracked via the existing window-event hooks) with last-received dom0 values winning.

### Compatibility

- Old agent + new daemon: unknown message type is drained safely by both Linux and
  Windows agents (`untrusted_len`-based skip; verified in both codebases).
- New agent + old daemon: no message arrives; behavior unchanged (current state).
- Feature-gate on protocol minor version bump; no change to any existing message.
- **Per-guest opt-in, not global behavior**: the handshake starts with the AGENT
  announcing its protocol version, so the daemon sends `MSG_WORKAREA` only to agents
  advertising >= 1.9. Linux guests and stock Windows agents never receive it; the dom0
  daemon package update is the only global artifact, with no behavior delta for
  non-participating guests.
- Security: daemon → agent direction (trusted → untrusted); values are advisory
  layout hints, sanitized guest-side by intersection with the guest screen. No new
  agent → daemon surface.

### Alternatives considered

(a) **Static guest-side config** (registry rect pushed over qrexec, applied via
    `SPI_SETWORKAREA` at agent start): works today without protocol changes, breaks
    silently when the user changes dom0 panels/monitors/themes. Reasonable interim;
    candidate for a `qvm-features`-fed value later.
(b) **dom0-side special-casing** (undecorate guest-maximized windows in the daemon /
    WM rule): fixes the fit but loses the title bar (dom0-side move/close affordance)
    and needs per-WM rules; rejected as primary.
(c) **Map guest maximize to dom0 maximize**: tried, fails whenever the guest virtual
    screen != dom0 monitor geometry (see above). Rejected.

## Open questions for upstream

1. Multi-monitor: should `MSG_WORKAREA` carry per-monitor rects (xrandr layout) for
   guests spanning monitors, or is the current-desktop union rect adequate for v1?
2. Should the guest resolution itself follow the work area (i.e., the agent sets the
   guest screen to `usable` size instead of the full dom0 display), making even
   non-maximized fullscreen-ish windows fit? (Interacts with QWT's user-chosen
   resolution registry override.)
3. Whether the Linux agent would also consume this (KDE-in-guest and other
   guest-side-panel setups have an analogous mismatch).
