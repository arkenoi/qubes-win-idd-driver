# QWT-NG 4.3.33 — Windows updates on a template that install and tell dom0 the truth; the whole desktop in one window, live

Everything in 4.3.32 is carried forward. This release brings two things: **Windows updates on a Qubes template that actually
install and report truthfully to dom0**, and the mode you could ask for but not use — **the guest's whole desktop inside a single
dom0 window, switching to it and back while the qube runs.**

## Windows updates on a template install, and dom0 is told the truth

A Windows template updated from dom0 (Qube Manager / `qubes-vm-update`) has no network of its own; the update runs through the
Qubes update proxy. On such a template, in a field report on German Windows 11 25H2, updates could fail silently or be reported as
done when they were not. Each cause is fixed:

- **The first contact with Windows Update failed silently** (`0x8024402C`), and the remedy for it — one restart — never ran in any
  release. dom0 is now given the reason and the restart request, and the next update completes.
- **The Windows Security platform update (KB5007651) was never actually installed.** The updater ran its installer with a switch
  that installs nothing, then reported the item current. Installer-type updates — the Security platform, Defender signatures
  (KB2267602), the Malicious Software Removal Tool (KB890830), the Defender platform (KB4052623) — are now installed by Windows
  Update's **own installer**, from content fetched through the proxy, with the update's own command line. Each is judged by what it
  actually changes; the Security platform is read after it finishes switching, which can be a few seconds after the installer returns.
- **dom0 received a bare error code** instead of the reason; a pass that collided with the boot-time scan was declared dead and
  stopped the scan's proxy; a pass cut off part-way blocked every later one; dom0 could be told the proxy was still running when it
  was not. All fixed. *(Corrected 2026-10-03: this list also named "any scan offering two or more updates crashed" - that defect
  was introduced and fixed during this release's development and never shipped in 4.3.32.)*
- The update proxy process is owned by the pass that started it: nothing is stopped by name.

Verified on a template built to the reporter's environment (German Windows 11 25H2, no network, no `user` account): the first-contact
restart; then the Security platform, Defender signatures and the Removal Tool installed and verified by what they change; .NET and
the September cumulative staged for the restarts dom0 was asked for, each restart performed; dom0's update state correct after every
round.

## Capture on Windows 11 24H2 and later is event-driven

Window content is copied when it changes — only the changed regions — instead of being re-read on timers, and the capture helpers no
longer wake while nothing changes. This is the bulk of the work since 4.3.32; its formal acceptance is still in progress (see Known).

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
- The intermittent guest stall during upgrades is unchanged and still unexplained. It struck one Windows 10 clean-install cell of this
  release's acceptance; that cell and the reinstall cell that depends on it were re-run on the same package and passed.
- A template that has both a .NET update and a cumulative update to install asks dom0 for a restart **twice**: update packages are
  staged one per restart. Removing the second request is the next step.
- On the event-driven capture, typing reaches dom0 a little later than before the redesign: about 9 ms at the median over all keys,
  about 20 ms on the second key of a sequence typed one per second. The cause is not established; tracked. *(Corrected 2026-10-03:
  this line first said every other key was within 10 ms - one key position measured 12 ms slower.)*
- The desktop-quieting step still stops OneDrive by its process name; the next release stops no process by name.

## How this release was verified

The full acceptance gate on this exact package: clean install, same-version reinstall, upgrade from the previous release and an
AppVM cold-boot series, on Windows 10 and Windows 11; the error-notification and crop-before-map feature tests; and the template
update test above on the reporter's environment, run separately on the same package the same day.
