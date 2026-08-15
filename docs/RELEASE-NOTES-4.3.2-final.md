# QWT-NG 4.3.2

Supersedes 4.3.1 (`agent c7ccb45`). If you are on 4.3.1, this release is worth taking: it fixes two
defects that made the guest visibly wrong on some hosts, and it actually contains the installer
switches announced during 4.3.1 but never shipped in it.

## Fixed since 4.3.1

**The mouse pointer sat about a centimetre below where Windows thought it was.** If your monitor is
a size the display driver did not already offer — 1920×1200 is the reported case — the agent matched
the request against the mode list *as it was*, picked the nearest offered mode (1920×1080), and then
published *that* size to the driver. The wanted mode therefore never became available and every
later attempt snapped again: the guest was pinned to 1920×1080 for its whole life while dom0 kept a
1920×1200 window over it. Hence a pointer that lands high, a dead band, and clicks that miss.
The requested size is now published to the driver first, the driver is reloaded, and the mode is
waited for. Measured before/after with the defect deliberately re-introduced on the same binary.

**dom0's "invalid or suspicious GUI request" dialog.** The agent could announce window geometry it
had never actually measured. `GetRealWindowRect` returns Win32 status codes, two of which are
positive numbers; the caller tested them with `SUCCEEDED()`, which is true for a positive value, so
those two failures skipped the error path and fell through with an uninitialised rectangle — stack
contents sent to dom0 as a window's position and size. The daemon is right to treat that as hostile.
Measured: of 65 measurement failures in 40 seconds, 64 were silently swallowed before the fix and
none after. Zero-sized top-level windows are ordinary, so this was not rare.

**Installer switches that 4.3.1 promised but did not contain**, plus the bug that broke one of them:

    /noidd     fresh install: do not activate the indirect display driver, stay on the emulated
               adapter. The driver files are still staged, so you can turn it on later
    /iddoff    recovery on a guest that already has it: re-enable the emulated adapter, stop the
               agent re-applying the IDD topology, remove the IDD device, reboot
    /iddonly   the reverse - activate it later on a guest that already has QWT
    /idd       accepted and does nothing: the IDD is on by default. It is an argument to
               install.cmd, never a file to launch

**Resolution selection no longer invents an answer.** When the host screen size is not yet known,
every candidate mode used to be rejected and the code returned mode index 0 — an arbitrary size
unrelated to what was asked for, which was then persisted and re-requested on the next boot. An
unknown host size now means "no ceiling", and a genuine no-fit keeps the current resolution.

**The guest log is usable again.** A window that closes between being listed and being measured is
normal, not an error; it was logged as one, dozens of times a minute, which is how a real failure
gets missed. The capture-restart gate, by contrast, logged *nothing* at default level — so a frozen
guest recorded no explanation at all. Both corrected.

**A fast-failing agent no longer gets hammered.** The watchdog restarted it once a second for ever.
For a failure that restarting cannot fix — an exhausted Xen grant table, for instance — that made
things worse. The delay now doubles up to a minute for an agent that keeps dying immediately, and
resets as soon as one survives.

**Windows Update integration** keeps the update-time window gate *and* is now positional: the proxy
serves the update process, and anything else gets a connection reset that reads as "no network"
rather than a hang. Additional updaters can be granted per policy via `AllowedImages` /
`AllowedServices` under `HKLM\SOFTWARE\Qubes\UpdatesProxy`. A Delivery Optimization policy the pass
sets for its own use is now restored on every exit path.

## Known open

- **A guest that answers qrexec but shows no windows at all.** Each agent start grants the
  framebuffer to dom0 and a killed agent never revokes, so repeated restarts can exhaust the Xen
  grant table; the agent then fails during vchan init (`0x5aa`) and only a reboot clears it. This
  release bounds the damage (see the watchdog change) but does not fix the leak.
- **A black, inactive window after the reboot that activates the IDD**, reported on Windows 10 22H2.
  Not reproduced here on the same build, the same upgrade path and the same Windows version. Note
  that activating the IDD *disables the emulated display adapter*, so there is no fallback if the
  IDD does not come up; the installer's result JSON prints the exact `Enable-PnpDevice` command that
  restores the previous display over qrexec. If you hit this, the guest's
  `Q:\Qubes Logs\gui-agent-*.log` from that boot is the artefact that would explain it.
- **The stock Windows 11 Start menu is not supported** and is not being chased. Its window is not
  even the same kind of object between 25H2 updates. Install Open-Shell; it works, including the
  original menu.
