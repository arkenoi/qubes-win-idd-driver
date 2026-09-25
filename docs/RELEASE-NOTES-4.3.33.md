# QWT-NG 4.3.33 — the whole desktop in one window, live

Everything in 4.3.32 is carried forward unchanged. This release is about the mode you could ask
for but not use: **showing the guest's whole desktop inside a single dom0 window, switching to it
and back while the qube runs.**

## Switching to the desktop view now works

dom0 has always had the control — Qube Manager's seamless toggle, which calls `qubes.SetGuiMode`.
Asking for the desktop view simply did nothing: the agent refused the switch unless
`service.gui-fullscreen` happened to be set, and the refusal was invisible, because that service
sets a flag and returns without ever learning what the agent did. From dom0 the call succeeded and
nothing changed.

It is honoured now, on any guest, and it survives a reboot — leave the qube showing its desktop
and it comes back that way.

The reason for the old refusal was real and is handled rather than removed. The desktop window's
image IS the whole-desktop grant, and a seamless-only guest deliberately does not make one, so
mapping that window without it would have shown black. The grant's lifetime now follows the mode:
the desktop surface is plugged in like a monitor on the way in and unplugged on the way out. A
guest that never switches still never holds a whole-desktop grant.

## Windows inside that desktop look like Windows

In seamless mode dom0 draws the frame around each guest window, so the agent strips the window's
own title bar — correct there, and wrong the moment the whole desktop is one window. It was being
applied in both modes with no way back, so inside the desktop view applications had no title bars
and a black band where the frame belonged.

Every such tweak is now applied and reversed in one place, and the caption comes back when you
leave seamless. Explorer renders with its ribbon and file list, Notepad with its icon, title and
buttons. The blanked mouse cursor deliberately stays blanked in both modes: dom0 draws the pointer
over the qube's window either way, and restoring the guest's would give you two again.

## Resizing follows, and the desktop keeps refreshing

Resize the qube's window and the guest resolution follows it, including to arbitrary sizes, with
the content repainting at the new size. That path existed before and could not be seen to work,
because the capture thread could die and nothing noticed — the agent held a live capture pointer,
reported itself healthy, and dom0's image simply froze. That is detected and recovered now.

An off-list size costs a monitor replug, measured at about half a second to repaint; a size the
driver already publishes costs none. Recently used sizes are published, so going back to a size
you just had is the cheap path.

## It cannot take over your screen

Entering the desktop view never comes up covering your display. A remembered size from an earlier
session no longer counts as "you asked for it", and a guest cannot select its way to full screen:
the published mode list does not contain the host size while the desktop view is active. Maximizing
the qube's window yourself is still honoured — that is your action, not the guest's.

## Quieter on a guest nobody is debugging

An idle guest now writes nothing to the agent log, and ordinary window activity writes about a
third less than before. One routine condition — zero-geometry infrastructure windows, which
Windows has dozens of — was being reported as a warning 119 times per session and is now a single
periodic summary. Diagnostic probes are behind the existing trace flag; the per-window lifecycle
lines a field report needs are not, deliberately.

## Known and not fixed

- A window whose title bar was stripped by a **previous** run of the agent keeps it stripped if the
  agent restarts while the desktop view is showing, until that window is recreated.
- The Windows Settings app can render its right-hand panel into a different window. Reported from
  the field, reproduced only there so far, and tracked.
- The intermittent guest stall during upgrades is unchanged and still unexplained.
