# Qubes features and qubesdb keys

Everything configurable about a QWT-NG guest is a **Qubes feature**, set from dom0 with
`qvm-features` and read by the guest out of qubesdb. Nothing here needs editing inside Windows.

This document is generated from the source, not from intent: every row cites the file and line
that reads or writes the value, and the behaviour described is what that code does.

---

## 1. Features you may want to set

These are ordinary Qubes service features: **`1` (or any non-empty value) enables, `""` disables**,
and `qvm-features --unset` returns the qube to the default. All are read **once, at agent start** —
changing one on a running qube takes effect at the next restart. A dom0 feature overrides the
guest-local registry value in every case.

| feature | what enabling it does | default |
|---|---|---|
| `service.enableWinKey` | The Windows key reaches the guest, so Start — or a third-party shell like Open-Shell — opens. Left off, the agent drops Super *presses* and any Mod4 chord **in seamless mode only** (`agent/gui-agent/vchan-handlers.c:375-389`); Super *releases* always pass and fullscreen is never filtered. Read at `agent/gui-agent/perf.c:352` | off — the key is blocked |
| `service.gui-fullscreen` | Allows a **borderless** true-fullscreen window — a game, video player or presentation — to be mapped (`agent/gui-agent/main.c:3165`), and lets dom0 switch the qube out of seamless into whole-screen mode (`main.c:3007`). A maximized window that still has a title bar is always allowed; the boot/shutdown screen is never allowed. Read at `main.c:6930` | off |
| `service.hideGuestTitleBar` | Strips `WS_CAPTION` from guest windows so dom0's decoration is the only header (`main.c:1832-1845`). Read at `perf.c:348` | off |
| `service.uac-secure-desktop` | Renders UAC elevation prompts on Windows' **secure desktop** instead of the normal one. Left off (the default), consent appears in dom0 as an ordinary window you can read and click. Turned on, the prompt is drawn on a desktop the agent must never grant to dom0 — so it is **invisible**, and the qube appears to hang until the prompt times out. Only worth setting if in-guest prompt spoofing matters more to you than being able to answer the prompt. Read at agent start (`agent/gui-agent/main.c`, QGAUAC block) | off — prompts visible in dom0 |
| `service.uac-disable` | Turns UAC **off** in the guest (`EnableLUA=0`); needs a guest reboot. Absent, the guest's own setting is left alone; `0` forces UAC on. **Not recommended:** without UAC any code in the qube reaches admin/kernel directly, and that is the surface facing the hypervisor (hypercalls, grant tables, PV drivers) — the one boundary Qubes actually depends on. Read at agent start | absent — guest's own setting untouched |
| `service.gui-agent-debug` | Full diagnostic logging in one switch (added 4.3.10+): per-frame `QGAPERF` telemetry, protocol/paint traces, and Debug log level. This is what to set before collecting a log for a bug report; unset it to return to the quiet default (a normal session logs tens of KB instead of MB). Overrides the guest-local `PerfLog`/`ProtoTrace` registry values in both directions. Read at `agent/gui-agent/perf.c` (QGADEBUG block in `PerfInit`) | off — quiet log |

`service.hideGuestTitleBar` is **experimental and best left alone**: the restyle changes a window's
style, which makes the agent re-map it, and dom0's window manager answers an unmap/map cycle with
`MSG_WINDOW_FLAGS set=MINIMIZE` — so enabling it makes windows minimize themselves. Measured; it is
default-off for that reason (`perf.c:121-127`). It was named `service.guestTitleBar` before 4.3.3,
with an opt-in that could not actually be expressed from dom0.

---

## 2. Features a Windows qube needs to work

These are not optional. The dom0 RPM applies them at install, and `qwt-ng-prepare-qube <vm>`
applies them to a qube created later — you should not normally need to set them by hand.

| feature | value | why | who reads it |
|---|---|---|---|
| `os` | `Windows` | Qubes core treats the qube as Windows; our dom0 CLIs (`qvm-windows-update`, `qwt-ng-prepare-qube`) use it as the `--all` selection filter (`packaging/rpm/qvm-windows-update:11`) | Qubes core **and** us |
| `vmexec` | `1` | Makes dom0 use `qubes.VMExec` instead of `qubes.VMShell`. Without it dom0's update commands arrive at `cmd.exe` as POSIX shell text and the run aborts before our agent is reached (`packaging/rpm/qwt-ng-prepare-qube:10-16`) | Qubes core; we set it (`:59`) |
| `gui`, `qrexec` | `1` | Qubes core treats the qube as GUI- and qrexec-capable | Qubes core |
| `audio-model`, `timezone`, `no-monitor-layout`, `rpc-clipboard`, `stubdom-qrexec` | per qube | Qubes core only — **no code in this package reads any of them.** They appear here only because our clone tooling copies them (`mgmt/clone-to-template.sh:47-48`) | Qubes core |

Also required, and applied by the same tools — a **preference**, not a feature:

    qvm-prefs <vm> qrexec_timeout 1800

A Windows boot that is *applying* an update has been measured taking 259 s to answer qrexec,
against a 60 s default (`packaging/rpm/qwt-ng-prepare-qube:28,66-70`).

---

## 3. Features dom0 sets, that describe the guest

| feature | direction | meaning |
|---|---|---|
| `updates-available` | **dom0-owned, guest-reported** | Drives the "updates available" marker in the Qubes Update tool. The guest never writes it: it reports a *count* over `qubes.NotifyUpdates` (`guest/qubes-windows-update.ps1:295`) and dom0 owns the flag. `qvm-windows-update --all` targets running Windows qubes where it is set and non-zero. Reads back as `1` when true and as an **empty string** when false — empty means "cleared", not "missing"; genuinely unset raises `QubesFeatureNotFoundError` |
| `gui-emulated` | dom0 | Qubes core; required by our unattended-install watcher so there is a stubdom console to screenshot (`mgmt/win-install-watch.sh:5`) |
| `qemu-extra-args` | dom0 | Only used by the development rig to attach an unattended-answer USB stick (`mgmt/reprovision-usb.sh:58`). Not part of a normal install |

---

## 4. qubesdb keys the guest reads

You do not set these; Qubes writes them. Listed so a failure is diagnosable.

### GUI agent

| key | effect | absent |
|---|---|---|
| `/name` | the qube name the agent reports (`agent/gui-agent/main.c:6811`) | falls back to `gethostname()` |
| `/qubes-gui-domain-xid` | the domain the framebuffer grants are made to (`main.c:6843`) | the agent cannot grant — fatal for the GUI |
| `/qubes-service/gui-fullscreen`, `/qubes-service/enableWinKey`, `/qubes-service/hideGuestTitleBar`, `/qubes-service/gui-agent-debug`, `/qubes-service/uac-secure-desktop`, `/qubes-service/uac-disable` | section 1 | section 1 |
| `/qubes-workarea` | dom0's work area and window-frame extents as `"x y w h fl fr ft fb"`, applied in the guest with `SPI_SETWORKAREA` so maximized windows fit dom0's screen rather than the guest's (`agent/gui-agent/workarea.c:333-334`). The **only key that is watched live** (`workarea.c:388`) — every other key here is read once | inferred from observed window origins; if that fails, the work area is left alone |

**Note the inverted precedence.** For `gui-fullscreen` and `enableWinKey` a dom0 feature beats the
guest registry. For `/qubes-workarea` the guest registry value (`WorkArea`) beats dom0
(`workarea.c:59-78`). That is deliberate but it is a trap.

There is also no shipped producer for `/qubes-workarea`: the only writer is a development-rig
autostart script (`dom0/09-install-workarea-watcher.sh`) which hardcodes a qube name and is not
part of the RPM. On a stock Qubes 4.3 the key is simply absent.

### Networking and identity

| key | read by | effect | absent |
|---|---|---|---|
| `/qubes-ip`, `/qubes-netmask`, `/qubes-gateway` | `core-agent/src/network-setup/qubes-network-setup.c:259-273`; PV-NIC self-prime applier `guest/pvnic-selfprime.ps1:167` | the static IPv4 configuration applied to the PV NIC | fatal for that pass — the guest logs and aborts |
| `/qubes-primary-dns` | `qubes-network-setup.c:280` | `netsh … set dnsservers static` | falls back to the gateway |
| `/qubes-secondary-dns` | `qubes-network-setup.c:287` | `netsh … add dnsservers` | falls back to the primary |
| `/type` | updater `guest/qubes-windows-update.ps1:1206`; installer `packaging/setup/Install-QwtImproved.ps1:1557` | **the qube class, and therefore whether the update proxy is allowed at all.** `TemplateVM` → run the proxied pass; `StandaloneVM` → skip (and lift `NoAutoUpdate` if it has a real route); AppVM/DispVM → skip. Unreadable after 8 tries (~14 s) → skip and refuse to proxy | refuses to proxy — the safe direction |
| `/qubes-vm-type`, `/qubes-vm-updateable` | `qubes-windows-update.ps1:1208-1211` | fallback class detection when `/type` is unavailable | — |

`qubesdb-cmd` in the guest mis-parses `/`-prefixed keys, so the package ships
`qubesdb-read.exe` (`tools/qubesdb-read/qubesdb-read.c`) and `guest/qubesdb-read.ps1` for
reading these by hand.

### What the guest writes

`advertise-tools.exe` writes the legacy `/qubes-tools/*` keys — `version`, `os`, `qrexec`, `gui`,
`gui-emulated`, `default-user` (`core-agent/src/advertise-tools/advertise-tools.c:232-262`) — and
fires `qubes.NotifyTools`. That is the Qubes R3/R4.0-era advertisement path; nothing in this
package writes the modern `/features-request/*`. **Do not assume `os=Windows` or `vmexec` appear
by themselves** — a guest structurally cannot advertise a feature to dom0, which is why the dom0
RPM sets them.

---

## 5. Guest-local registry overrides

Base key: `HKLM\Software\Invisible Things Lab\Qubes Tools`, read as
`…\Qubes Tools\<module>\<Value>` with a fallback to the root key. The GUI agent's module is
`gui-agent`. These exist so a guest can be configured without dom0; **the dom0 feature wins
wherever both are present**, except `WorkArea` as noted above.

| value | type / default | feature that overrides it |
|---|---|---|
| `ShowFullscreenScreen` | DWORD, absent → `0` | `/qubes-service/gui-fullscreen` (`main.c:6928-6934`) |
| `BlockMenuKey` | DWORD, absent → block | `/qubes-service/enableWinKey` (`perf.c:322-330`) |
| `WorkArea` | REG_SZ `"x,y,w,h"`, sanity-checked ≥ 640×480 and on-screen | **overrides** `/qubes-workarea` |

`service.hideGuestTitleBar` has no registry twin — qubesdb is its only source.

Other values under that key (`MaxFps`, `DisableCursor`, `SeamlessMode`, `StagingGrant`, the
`InputDrag*` family, and `HKLM\SOFTWARE\QubesIDD\Modes`) are tuning and telemetry, not feature
overrides, and are not documented as a supported interface.

---

## 6. Deliberately not honoured

| key | why |
|---|---|
| `/qubes-service/yum-proxy-setup` (dom0 `updates-proxy-setup`) | The update proxy is gated on the qube **class** read from `/type`, not on this service flag, so that an app qube cannot acquire a proxy by having a feature set (`guest/qubes-windows-update.ps1:1165-1167`) |
| `/qubes-vm-persistence` | known, never read |
