# QWT-NG 4.3.34 — every failure says what happened and what to do; nothing is stopped by name

Everything in 4.3.33 is carried forward. This release is about failures: when a part of Windows Tools dies, you are told, once,
in words you can act on — and the tools no longer stop or adopt processes by their names.

## Error notifications you can act on

Every error notification Windows Tools sends to dom0 now has one shape. The title says what happened, in plain words: "The GUI
agent crashed", "The Qubes RPC agent service stopped with an error". The body says what happens next and what you can do, then
the cause — the code's meaning taken from the right source (a process exit, a Windows error, a service's own code, a scheduled
task's result) — and a last technical line with the program, its process id, the code and where the logs are.

Some of what the old texts got wrong, fixed:

- "Reported once per boot" was printed on every crash, though each crash is reported on its own. Crashes now say which crash of
  this boot they are.
- A helper that stopped answering was reported as having exited, with "exit code unknown". A hang is now reported as a hang.
- Exit codes were explained from the wrong table — a service's own error code was explained as if it were a process exit code.
  Each code is now read from the table of the place it came from.
- Service failures used Windows' internal wording ("time 1 per the SCM"). They now say when Windows restarts the service, read
  from the service's own recovery settings.
- The GUI agent watchdog blamed every quick crash on an exhausted Xen grant table. It now names the exit code it saw, and gives
  that explanation only for that code.
- Components were named by their file names. They now have names: the notification and menu capture helper, the notification
  bridge, the Qubes RPC agent.

A crash notification that would be too long for dom0's notification service is sent with a shorter list of log locations
rather than not at all.

## A part of Windows Tools that dies is reported, every time

Until now a part of Windows Tools that died was recorded only in the guest's own logs. Now:

- A crash, an unhandled .NET exception, a service that stops unexpectedly, or one of the tools' scheduled tasks failing is
  reported to dom0 from Windows' own records, once per death (up to eight notifications per boot; every death is also logged).
- The GUI agent watchdog and the GUI agent write one Windows Event Log entry for each helper that dies without being asked to.
- Four services — the Qubes RPC agent, the QubesDB daemon, the GUI agent watchdog and, where it is installed, the PV network
  address service — are set to be restarted by Windows if they fail. The Qubes RPC agent and the QubesDB daemon also report their real exit codes when
  they stop with an error; they used to report success whatever happened.
- The watchdog stops the GUI agent it started, by its own process handle, and never takes over another process that happens to
  have the same name.
- A qube with no GUI domain no longer has its GUI agent restarted over and over: the agent says once why it cannot start, and the
  watchdog stops relaunching it.

## Nothing is stopped by name

The installers and the guest scripts used to stop processes by their names. Services are now stopped through Windows' service
manager, and the GUI agent is asked to stop through its own stop signal. OneDrive is no longer stopped at all; its policies still
apply when it next starts.

## The updater is installed even when the last update check was interrupted

If a qube had been shut down while its update check was running, or the check had hit its time limit, installing 4.3.32 or
4.3.33 did not install the Windows Update agent at all: the qube kept its previous updater, and the only trace was a warning in
`C:\qwt-improved-install.log` ("Windows Update agent deploy failed: QWTUPDSTATEUNKNOWN"). A qube on 4.3.32 in that state could not
get out of it, because its own updater also refused every later pass. The installer now follows the same rule as the updater: an
interrupted check, or an update pass from before the qube's last restart, no longer blocks it. Only an install or download
interrupted in the current boot still does, and the message says to restart the qube and run the installer again.

## The installer no longer answers qrexec calls while it is still setting up devices

After Windows Installer finishes, the installer still changes devices for up to about a minute: it installs and activates the display
driver, switches off the emulated graphics adapter, sets up the updater and prepares the PV network adapter. Until now Windows
Installer started the Windows Tools services itself, as part of the install, so a qrexec call from dom0 could arrive in the
middle of that work.
Each call into the qube makes Windows map, and afterwards unmap, a page shared with the caller, and on Xen every unmap makes the
guest wait for QEMU in the qube's stub domain. Four of the install stalls on record happened in that window; one more froze in
the first start after an install, and one on a qube with no Windows Tools installed at all - this change does not reach those.

Now the services start one at a time, each after the previous one is running, and the Qubes RPC agent starts only when the device
work is done. In a manual install, qrexec answers when the install has finished - later than before by the length of that work
(24 s measured on Windows 10; up to about a minute on earlier runs). With
`install.cmd /auto /reboot` the qube powers off at the end of the install as before, and qrexec answers at its next start.

## Known and not fixed

- A template that has both a .NET update and a cumulative update to install asks dom0 for a restart **twice**, as in 4.3.33:
  the updater installs one restart-requiring package per pass, in the order Windows Update offers them, and .NET comes first.
  Measured on the reporter's environment: when .NET was staged first, Windows did not register the cumulative staged after it in
  the same pass, although DISM reported success - which is why the updater waits for the restart; when the cumulative was staged
  first, both installed with one restart. A version that stages the cumulative first and checks that Windows registered it is
  to be measured for the next release.
- After a cumulative update, Windows can restart itself while it finishes installing, and on Qubes a restart the guest starts
  itself ends with the qube shut down. On the reporter's environment that happened once with the cumulative alone and twice with
  the cumulative and .NET together, so the qube had to be started again until the update was done.
- The guest stall can still happen outside the install's device work: one is on record in the first minutes of a qube's first
  start after an install, and one on a qube with no Windows Tools installed at all. The part of it that happens in QEMU is not
  something Windows Tools can change.
- If a part of Windows Tools crashes during that last minute of an install, while the Qubes RPC agent is not yet started, the crash
  is recorded in the guest's own log but not reported to dom0.
- On the event-driven capture, the repaint after a keystroke still reaches dom0 a little later than before it (measured on a
  pre-release build: about 9 ms at the median, about 20 ms on the second key of a sequence typed one per second).
- The notification bridge's reports about its own failures may not reach dom0 (found by reading the code; not yet checked on a
  guest).

## How this release was verified

The full release acceptance ran on this exact package (release-package 37206244684, built from 24e28f46) on 2026-10-04 and
passed:

- The package checks: driver versions, the 84 manifest files and the analyser, 13 of 13.
- Eight install cells on Windows 10 22H2 and Windows 11 (retail 26300): a clean install from a pristine image, a same-version
  reinstall, an upgrade from 4.3.33, and an AppVM derived from the installed template with cold boots - all passed, and no guest
  stalled. In the clean installs the installer's own log shows the Qubes RPC agent held through the device work (24 s on
  Windows 10) and started only afterwards.
- The error notifications sent to dom0, the window crop before mapping, and the updater on the reporter's environment (a German
  Windows 11 25H2 template, three update rounds) - all passed.

One clean gate is not a measurement of the stall rate: eight installs without a stall would also happen about one time in five
if nothing had changed. Every install from here on is part of that check.
