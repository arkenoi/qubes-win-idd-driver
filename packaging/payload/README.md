# Improved Qubes GUI agent for Windows qubes

This package replaces the **GUI agent** of an existing Qubes Windows Tools 4.2.2
installation with a rebuilt, faster one. It is an **overlay updater**, not a Qubes Windows
Tools installer.

Measured effect (win-idd-test, Win10 LTSC 2021, 4 vCPU, seamless mode): median per-frame
cost during a scripted window drag **44.9 ms -> 1.33 ms**, windows interrogated per frame
**~67 -> 1.44**. See `MANIFEST.json` for the exact commit these numbers belong to.

---

## What it replaces, and what it does not

| | |
|---|---|
| **Replaces** | `bin\gui-agent.exe` (event-driven window tracking via `SetWinEventHook` instead of per-frame `EnumWindows`; in-place recovery from `DXGI_ERROR_ACCESS_LOST`) |
| **Optionally replaces** | `bin\gui-watchdog.exe` — see "About gui-watchdog.exe" below. **Off by default.** |
| **Does not touch** | Qubes Windows Tools itself, the Xen PV drivers (`xenbus`, `xeniface`, `xenvif`, `xennet`, `xenvbd`), `qrexec-agent.exe`, `qubesdb-daemon.exe`, the qrexec RPC handlers, services, or any registry value |

Everything it writes is reversible: each replaced file gets a `.orig` backup next to it and
`-Restore` puts it back byte for byte.

## Requirements

* A Windows qube with **Qubes Windows Tools 4.2.2 already installed and working**
  (`C:\Program Files\Qubes Tools\bin\gui-agent.exe` must exist). This package cannot
  bootstrap QWT — see "Fresh machine" below.
* Administrator rights in the Windows qube (it stops and starts a service and writes to
  `C:\Program Files`).
* Nothing else. No network, no reboot, no test-signing change.

## Install

Copy this whole directory into the Windows qube (`qvm-copy-to-vm`, or Qubes' "copy to
other qube"), open an **elevated** PowerShell in it, then:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-qwt-improved.ps1
```

The script prints a transcript, then a line `=== RESULT ===` followed by a JSON object.
`"ok": true` means: the file on disk hashes to the file in this package, the
`QubesGuiWatchdog` service is `Running`, and `gui-agent.exe` is running again.

Then check from dom0 that the desktop is still live — drag a window, or start a GUI app
with `qvm-run <qube> notepad`. The install script can only verify the guest side.

Re-running the script is a no-op: if the installed files already match, it does not stop
the service and does not restart anything.

### Options

```powershell
# also replace gui-watchdog.exe (see below - not recommended without a reason)
.\install-qwt-improved.ps1 -Components all

# report what is installed right now; changes nothing, no elevation needed
.\install-qwt-improved.ps1 -Status

# reinstall even if the hashes already match
.\install-qwt-improved.ps1 -Force

# non-default QWT location
.\install-qwt-improved.ps1 -BinDir 'D:\Qubes Tools\bin'
```

## Uninstall / restore

```powershell
powershell -ExecutionPolicy Bypass -File .\install-qwt-improved.ps1 -Restore
```

This copies `gui-agent.exe.orig` back over `gui-agent.exe` and restarts the service. Use
`-Components all -Restore` if you installed the watchdog too. The `.orig` files are the
untouched binaries the QWT MSI shipped, so after `-Restore` the install is bit-identical to
a stock QWT 4.2.2.

If you ever need to do it by hand (e.g. the script cannot run):

```powershell
Stop-Service QubesGuiWatchdog -Force
Stop-Process -Name gui-agent -Force -ErrorAction SilentlyContinue
Copy-Item 'C:\Program Files\Qubes Tools\bin\gui-agent.exe.orig' `
          'C:\Program Files\Qubes Tools\bin\gui-agent.exe' -Force
Start-Service QubesGuiWatchdog
```

A full `msiexec` repair of QWT (`msiexec /f ...`) also restores the shipped binaries, but
it re-runs the whole QWT install and is a much bigger hammer.

## Fresh machine (no QWT yet)

This package intentionally does not carry Qubes Windows Tools. Install upstream QWT first,
then overlay:

1. Install Qubes Windows Tools 4.2.2 in the Windows qube by the current official procedure
   (<https://doc.qubes-os.org/en/latest/user/templates/windows/qubes-windows-tools.html>).
   Note that the official 4.2.2 build is a **test-signed** build: its MSI carries a launch
   condition on `SYSTEMSTARTOPTIONS >< "TESTSIGNING"` and refuses to install unless the
   current boot already has test-signing enabled (`bcdedit /set testsigning on`, reboot).
2. Reboot, confirm the qube's GUI works normally.
3. Apply this package as above.

## About `gui-watchdog.exe`

`gui-watchdog.exe` is included in this package but is **not installed by default**, because
this project changed no watchdog source: the only diff against upstream `v4.2.2` in that
component is its `.vcxproj` build plumbing. Installing it would swap a binary that upstream
signed for a functionally identical local rebuild, gaining nothing and putting the service
that keeps your GUI alive on a less-tested binary. It ships here so the package is a
complete set of what CI built, and for developers who want to test a watchdog change.

## Code signing

Upstream Qubes Windows Tools binaries are Authenticode-signed with a **self-signed**
`CN=Qubes Windows Tools` certificate that the QWT MSI installs into the machine `Root` and
`TrustedPublisher` stores. The binaries in this package are not signed by that certificate
(we do not have its private key, and we should not).

Practically this changes nothing about whether they run: Windows does not require
Authenticode on user-mode executables, and the QWT watchdog does not verify the signature
of the agent it launches. It does mean `Get-AuthenticodeSignature` on the installed
`gui-agent.exe` will report `NotSigned` (or a test certificate, if this package was built
with signing enabled) instead of `Qubes Windows Tools`. Verify integrity with
`SHA256SUMS.txt` in this directory instead.

## Contents

```
install-qwt-improved.ps1   this installer
README.md                  this file
MANIFEST.json              agent commit, dependency refs, build time, file hashes
SHA256SUMS.txt             hashes of every file in this package
bin/                       gui-agent.exe, gui-watchdog.exe  (installable)
symbols/                   matching .pdb files (not installed; for debugging)
tools/                     dump-windows.exe, ddaprobe.exe   (diagnostics, not installed)
optional/idd-driver/       the experimental Qubes IddCx display driver
```

`optional/idd-driver/` is **not** installed, configured or referenced by
`install-qwt-improved.ps1`. It is an in-development indirect display driver shipped here
only so one CI artifact carries everything the build produced. Do not install it on a
Windows qube you care about.
