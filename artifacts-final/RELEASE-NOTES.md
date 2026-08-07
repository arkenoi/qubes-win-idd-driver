# Qubes Windows Tools 4.2.2 — improved GUI agent (draft)

Package `4.2.2+agent.a68d24492b25`, built by CI run 31129344581 from `main`.
This is a **full QWT install**, not an overlay: the upstream WiX MSI rebuilt from source
with our `gui-agent.exe`, plus certs, the VC++ runtime, the IddCx driver payload and a
two-stage install script.

## Install

    install.cmd            two stages, you reboot between them
    install.cmd /auto      reboots and resumes by itself
    install.cmd /nonet     omit the PV network drivers
    install.cmd /idd       ALSO install and activate the Qubes IddCx display driver
                           — see the caveat below before using this on Windows 10

Binaries are TEST-SIGNED, so the installer enables testsigning and reboots once before the
MSI runs. Read `README.txt` in the package first.

## What changed for users

See `docs/WHAT-CHANGED-FOR-USERS.md` in the repository — behaviour, measured numbers, and an
explicit "not fixed" section.

Headlines: per-window capture (composited-desktop artifacts gone), Office compound windows
render as one window, popups/menus synthesised into their owner, and seamless mode now works
on an IDD-equipped guest (the mode set carries the host size while seamless is active).

## HONEST TEST STATUS — read before shipping this to anyone

**The clean-path acceptance runs used the PREVIOUS build (`agent.018ec54`), not this one.**
That build contained a maximize-clamp regression which cropped the title bar and menu bar out
of maximized windows; it is REVERTED in this package (`agent.a68d244`). So:

| what | status |
|---|---|
| Win11 24H2 clean install + health gate | **PASS 8/8** — but on `agent.018ec54` |
| Win10 22H2 clean install | install PASSES; full acceptance on this build NOT re-run |
| Maximize-clamp regression | fixed in THIS package; verified on a guest via the overlay build (`CHROME=OK`, 16 colours in the top band vs 2 on the broken build) |
| This exact package, end-to-end on a clean guest | **NOT YET RUN** |

**Do not treat this as release-qualified until the acceptance is re-run against
`agent.a68d244`.** That is why it is a draft.

## `/idd` caveat — opt-in, and broken on Windows 10

`/idd` installs and activates the Qubes IddCx display driver (arbitrary guest resolutions).

- **Windows 11 24H2: works.** Verified on a clean install — the IDD is the only active
  display controller and the emulated VGA adapter is offline.
- **Windows 10 19045: does NOT work through this installer.** Activation runs correctly and
  the VGA disable persists, but after the reboot Windows drives the desktop through the
  `ROOT\BASICDISPLAY` fallback while the IDD stays offline. The guest is left without
  arbitrary-resolution support. One such guest also wedged (cause unproven).

`/idd` is therefore **not** enabled by the unattended install media. If you use it on Win10
and lose the display, recover over qrexec with the `idd_recovery` command recorded in the
installer's RESULT JSON (`Enable-PnpDevice` on the VGA instance id, then reboot).

## Other known issues

- **PV networking is not bound** on the reference guest: traffic runs over the emulated
  Realtek NIC while `xennet` never binds its `XENVIF` child (code 28). Networking and Windows
  Update work; the PV path does not. Not established whether stock QWT differs here.
- **Toast notifications** map as borderless (override-redirect) windows over whatever they
  cover, rather than as bordered windows the way Linux qubes show notifications. Undecided.
- **Maximized windows can still overflow the dom0 workspace**, most visibly in the first
  minutes after boot before dom0's work-area feed reaches the guest.
