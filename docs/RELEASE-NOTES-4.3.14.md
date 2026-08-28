# QWT-NG 4.3.14 — stability

This release is about a qube coming back by itself, and about the guest never taking over your
screen. Nothing here changes the display pipeline or performance.

## The qube can log itself back in — the installer arms autologon

A Windows guest that stops at the sign-in screen is not merely inconvenient, it is **gone**: with
no interactive session, qrexec service calls have nobody to run as, so dom0 cannot run apps in it,
update it, or read it. And in seamless mode the sign-in screen is not displayed at all, so the
qube's window simply stays **empty** — measured: autologon off means zero windows mapped, while
the qube is running and answering. Two forum reports were exactly this.

The installer now arms autologon:

* it validates the credentials with `LogonUser` **before writing anything** — arming with a wrong
  password causes the very lockout this prevents;
* it stores the password as the **LSA secret** `DefaultPassword`, not as the world-readable
  plaintext registry value, and removes a plaintext value if one is there. An LSA secret is also
  not consumed by `AutoLogonCount`, which is what silently disarmed autologon before;
* a boot-time SYSTEM task re-asserts the settings, because Windows updates rewrite them;
* `install.cmd /autologon:PASSWORD` for an unattended install, `/noautologon` to skip; run
  interactively it asks, with a two-minute deadline so a minimised install can never hang on it.

Verified with a control that fires: with the secret correct a user session forms with no plaintext
password anywhere; with the secret deliberately wrong, **no session forms** — so Winlogon is
demonstrably using the value we write. Re-arm at any time with `set-autologon.ps1`, kept in the
guest under `Qubes Tools\vmupdate-shim\`.

Guests joined to a domain, or using a Microsoft account with Windows Hello, cannot be armed this
way. That is known and not yet handled.

## A new qube has something in its application menu

A freshly installed Windows guest has almost nothing in its Start Menu that the shortcut sweep
finds, so dom0's application list came up nearly empty — and in seamless mode there is no taskbar
and no desktop either, so that list is the only way in. The guest now also reports **Notepad,
Microsoft Edge** (when present), **File Explorer, Settings, Command Prompt, Windows PowerShell**,
and elevated **Command Prompt (Administrator)** and **Windows PowerShell (Administrator)**.
Entries a real Start Menu shortcut already provides are not duplicated.

The two elevated entries go through the ordinary Windows elevation prompt. They deliberately do
not use any silent-elevation trick — a menu entry that quietly handed out admin would be a hole —
and since 4.3.11 that prompt is an ordinary window in dom0, so it can actually be answered.

Run `qvm-sync-appmenus <vm>` in dom0 after upgrading to pick them up.

## Nothing fullscreen-sized during boot or shutdown, ever

"The boot/shutdown screen is never allowed, feature or not" was enforced by matching the window
**class** (`LogonUI`, override-redirect). That leaked: with `service.gui-fullscreen` enabled, a
fullscreen-sized boot-phase surface that is neither of those was mapped and covered the whole
display. Startup and shutdown are a *phase*, so they are now tested as one — a fullscreen-sized
window is denied while there is no shell window (boot, logon, and shutdown once explorer has
gone), while the input desktop is secure, and briefly after it stops being. In those phases
nothing fullscreen-sized is an app anyone asked for, whatever its class, and the feature does not
apply to it.

## The secure desktop, by mode

In **seamless** mode the Windows secure desktop is never shown — each surface would become its own
standalone dom0 window, and that full-screen dimming backdrop was the "unclosable black window"
field reports. In the **windowed desktop** (non-seamless, `service.gui-fullscreen`) the whole guest
desktop is shown in one bounded window, sign-in screen included, because there it is ordinary
content in a window you can move and close. That is the way into a guest that cannot log itself
in. UAC prompts are unaffected: they are ordinary windows in both modes.

## Diagnostics that say what is wrong

* **`QGADESKSTUCK`** — the agent now says when it has been frozen on the secure desktop for more
  than 30 seconds, naming the desktop, the elapsed time, and the two ways out. A guest waiting at
  a sign-in screen used to produce a completely silent log.
* **Reboot-cause audit** — on an AppVM the System log lives on the volatile C: and is destroyed by
  the restart it describes, so an unattended reboot could not be told apart from one dom0 asked
  for. Event-triggered tasks now copy Event 1074 (who asked), 6008 and 41 onto the private volume
  as they are written.
* **The watchdog stops respawning the agent into a shutting-down machine**, and records which
  signals it consulted every time the agent dies. One respawn can still happen at the very start
  of a shutdown, before the service control manager reports it — visible in the log, harmless.

## Upgrading

An in-place upgrade: run the installer, it detects the older version and lets the MSI replace it
in one transaction. Validated end to end on clean Windows 10 22H2 and Windows 11 25H2 installs,
template plus an AppVM through three cold boots each.
