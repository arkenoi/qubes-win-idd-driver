# QWT-NG 4.3.3

A bugfix and performance release. It supersedes 4.3.2 (`agent bacfd2c`, 2026-08-15) and is worth
taking on any guest: it fixes three defects that were reported from real installs, closes the
Windows-update path end to end, and removes the first-boot black-window and network-loop failures
that made a freshly installed guest look broken.

Nothing here changes the security model. No new dom0 component, no new qrexec service that dom0
must trust, no change to what the guest may ask for.

---

## Fixed since 4.3.2 — the three reported from real installs

**`install.cmd /iddoff` (or any switch) failed with `C:\iddoff` when run without elevation.**
Present in every release since 4.3.0. The switch parse loop used a bare `shift`, which shifts from
argument **zero** — so once a switch had been consumed, `%0` *was* the switch, and the elevated
relaunch handed `%~f0` to the Win32 path normaliser, where a leading separator means "root of the
current drive". `C:\iddoff`. It fires only when the shell is non-elevated (or holds a UAC-filtered
token) **and** at least one recognised switch is present, which is why it survived three releases:
every one of our test rigs runs `EnableLUA=0`, so the relaunch block is structurally unreachable
here. The script now captures `SELF=%~f0` before the loop. The same block used to launder failures
into `exit /b 0`; it now waits for the elevated child and propagates its exit code.

**The Windows key was dead — no Start menu, and Open-Shell unusable with it.** `g_BlockMenuKey`
shipped **on**, which dropped Super presses and every Mod4 chord in seamless mode before they
reached `SendInput`. In seamless the taskbar window is never mapped, so that key is the only way
into any Start menu — including the third-party one we had recommended as the workaround. The block
is now **opt-in** (`qvm-features <vm> service.enableWinKey`, see below).

**A black, inactive window on the FIRST boot after install, recovering by itself after ~30 s.**
Mechanism, from the guest's own System log: with a NIC attached, QWT's `xenagent` installs the PV
network drivers on first boot (three 7045 "service was installed" events) and then issues a 1074
shutdown, because a driver install wants a reboot. The GUI agent has already published a screen, the
domain restarts underneath it, and the window is black and inactive until the guest returns. Where
the root volume persists that is one reboot; where it is a discarded CoW overlay — an **app qube
built from a Windows template** — it is an endless boot loop, which is how the mechanism was finally
caught. The fix primes the PV NIC in the **template**, so the drivers and the unplug latch live in
its persistent root and the first boot of every qube built from it has nothing left to install.
Verified here: app qubes that previously looped forever now reach `console user Active` with a netvm
attached and zero restarts. Not reproduced on the reporter's 25H2 rig, so for that specific report
this remains a probable — not proven — cause.

---

## Windows Update

The guest can now be updated from dom0 over qrexec, with **no netvm ever attached to the Windows
qube**. Updates are dom0-owned by design: the guest's own automatic updates stay off
(`NoAutoUpdate=1`) and every install is driven by dom0. This release is where that path stopped
having holes.

- **`0x80072F8F` — "the security certificate is out of date" — is fixed.** On a proxy-only guest,
  schannel could not fetch the Microsoft certificate trust lists, so every TLS handshake to the
  update service failed for a reason that had nothing to do with the clock. `Sync-Revocation` now
  mirrors the CTLs through the relay. (The CDP CRLs, which we chased first, were never the
  mechanism.)
- **The relay never serves a short body as a success.** If a response is cut off, the relay now
  answers `502` and logs `PLAIN REFUSED` instead of handing Windows a truncated package that
  fails later, somewhere else, with an unrelated error. Bodies larger than the verification
  window spill to the client rather than being truncated. Replies to `HEAD`, and `204/304/1xx`,
  are correctly understood to have no body.
- **The proxy is template-only.** An app qube, a disposable, or a standalone never acquires a
  proxy, never starts the relay and never touches the guest's WinHTTP/IE proxy settings. A
  standalone that has real internet disables the proxy updater *and* removes the `NoAutoUpdate`
  policy, so it is not left switched off with nobody driving it.
- **Truncated output from long-running commands is fixed** (`core-agent` fork): `qrexec-wrapper`
  left on vchan close without draining the receive ring, so the tail of a command's output was
  lost — worst on exactly the long servicing runs that needed it. It now drains the ring, as the
  Linux implementation does, and waits up to 120 s for the child's exit code instead of 1 s.
- **Defender signature updates install netvm-free**, verified by effect rather than by exit code.
- **Package formats that previously failed** now install: combined SSU+LCU `.msu` (DISM returns
  `ERROR_NOT_SUPPORTED` for these; `wusa.exe` is the correct handler), Win10 `.msu`→`.cab`
  servicing, and .NET cumulative updates whose component filenames do not carry the rollup's KB
  number.
- **Updates that genuinely cannot be installed are reported as informational, not as failures**,
  with the reason: post-EOS/ESU packages, express-only packages on a guest with no route, and
  WU-client blobs DISM rejects as not-a-package. dom0 gets an actionable count instead of phantom
  failures.
- **The automatic scan is debounced**, and only a pass that actually *answered* may suppress the
  next one — a pass that failed to answer does not buy silence. A scan dom0 explicitly asks for is
  never skipped.
- **Autologon is re-armed at every pass that stages a reboot.** While `AutoLogonCount` exists
  Windows consumes `DefaultPassword` and then falls back to the sign-in screen — which, in a qube
  with no login screen exposed, means a guest nobody can get back into.

---

## Display and input

- **The boot/shutdown flash is gone.** The full-screen black/blue frame that appeared while Windows
  booted, shut down, or switched sessions is a `LogonUI` window; it is now denied unconditionally.
  This is deliberate and permanent: the Windows secure desktop is never presented to dom0.
- **Fullscreen windows behave the way you would expect.** A *windowed* fullscreen — a maximized app
  that still has a title bar — is always shown. Only a **borderless** true-fullscreen window (a
  game, a video player, a presentation taking over the screen) is gated behind
  `service.gui-fullscreen`, and the transition flash into it is shrunk by unmapping a window as
  soon as it stops being eligible instead of at the next sweep.
- **Window drag is smoother.** dom0's origin is now ramped rather than stepped, and the drag path
  translates against the origin dom0 has *actually applied* rather than against a guess. Defaults
  come from a measured lag instead of a guessed one.
- **Windows no longer show a previous window's pixels.** Granted buffers are reused instead of
  spending a grant reference per window, and a reused slab is zeroed — without that, a
  partially-painted window briefly displayed whatever had been there before.
- **A window that moves no longer keeps a stale capture crop** (per-window capture refreshes the
  crop on move rather than freezing it at attach).
- **A GUI freeze is bounded.** If dom0's confirmation never arrives, the capture gate no longer
  waits forever; the failure is also now reported distinguishably — a qube that never had a GUI
  versus one whose daemon died.
- **Start menu, taskbar surfaces and toast notifications work on Windows 11 25H2** — clickable,
  movable and correctly positioned.

---

## Networking

- **PV NIC priming is netvm-free.** Priming runs from a latch in the template with no network
  attached at any point, and no reboot loop. The applier reads its configuration live from qubesdb.
- **`network-setup.exe` is retired.** Our qubesdb applier owns the job; the stock helper is no
  longer shipped or invoked.

---

## Packaging and CI

- **`release-artifacts/` is no longer committed.** An 86 MB snapshot of build output was in the
  repository, and it was stale: it contained a pre-fix `install.cmd`. Anyone who looked there got a
  broken installer that CI had never built. The directory is now ignored and carries a README
  explaining where the real artifacts come from.
- **There is now a test job.** Nothing previously executed a user-facing switch or a guest script in
  CI, which is precisely how the `install.cmd` defect above shipped three times. Every push now
  runs: the relay's own `--selftest` (response framing and the pid-lookup race, compiled with the
  same in-box compiler the guest uses), `install.cmd` switch parsing through a dry-run hook, a
  PowerShell parse of every shipped script, and a set of cheap invariants.
- **The overlay package announces its real version.** `make-package.ps1` carried its own version
  literal frozen at `4.3.0`, so the overlay packages built for 4.3.1 and 4.3.2 both claimed 4.3.0.
  It now reads `agent/version`, the same single source the MSI's `ProductVersion` uses.

---

## Configuration

Every `qvm-features` flag and qubesdb key this release reads is documented in
[`docs/QVM-FEATURES.md`](QVM-FEATURES.md). The two most likely to be wanted:

    qvm-features <vm> service.enableWinKey 1     # let the Windows key through (Start / Open-Shell)
    qvm-features <vm> service.gui-fullscreen 1   # allow borderless true-fullscreen windows

`service.guestTitleBar` is renamed to **`service.hideGuestTitleBar`** and now follows the same
convention as every other feature: a non-empty value enables it. Its old opt-in was spelled `0`,
which dom0 cannot express for a service feature, so the knob could not actually be turned on. It
stays experimental and default-off.

---

## Known limitations

- The `AcquireNextFrame 0x887a0026` capture-error path still suspends window tracking while the
  screen window is down, which can cost a session outage until the daemon's confirm arrives. The
  wait is now bounded, but the underlying error is not fixed.
- ESU-era packages on an out-of-support guest are reported, not installed; that needs an ESU MAK.
- The first-boot black-window fix is verified here but unproven on the 25H2 rig that reported it.
