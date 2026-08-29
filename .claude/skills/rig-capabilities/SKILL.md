---
name: rig-capabilities
description: Verified inventory of what this dev qube CAN and CANNOT do against the Windows testbed - Admin API, qube lifecycle, tags, netvm, firewall, loop devices, CI, local tooling - plus the exact environment map (loops, ISOs, pools) and a list of false limitations previously invented and disproven. Read this BEFORE concluding that anything is impossible, blocked, out of scope, or "needs the owner", and before writing any plan that assumes a constraint.
---

# Rig capabilities — measured, not assumed

**Why this exists.** Across one session I invented five separate limitations that were all false, and
each one distorted a plan or wasted rig time: "screenshots are impossible for this guest", "the qube
is unkillable", "networking cannot be tested", "fw-net is not visible", "qube names cannot be
invented because policy is name-based". The owner had to correct every one. **The rule now: an
"impossible" is a measurement, not an intuition. Verify with a command; if you cannot, say
"unverified", never "impossible".**

Everything below was executed and recorded on 2026-08-29 unless marked otherwise.

## Policy model — TAG-based, not name-based

`dom0/03-install-policy.sh` and `dom0/12-install-policy-tagged.sh` grant on **`@tag:win-idd-testbed`**:

    qubes.VMShell          *  win-idd-mgmt  @tag:win-idd-testbed  allow
    qubes.VMExec           *  win-idd-mgmt  @tag:win-idd-testbed  allow
    qubes.Filecopy         *  win-idd-mgmt  @tag:win-idd-testbed  allow
    admin.vm.Start/Shutdown/Kill/CurrentState/List/property.Get  ... @tag:win-idd-testbed  allow

**Consequence: you MAY create new qube names.** Verified end to end — created `qwt-probe-tmp` (a name
on no roster), tagged it `win-idd-testbed`, and immediately got working `admin.vm.CurrentState`,
`admin.vm.property.Get`, `qvm-prefs` read **and** write. Then removed it.

*Supersedes the memory `reuse-policied-qube-names`, which said "never invent qube names; recycle the
roster that already has dom0 policy". That is FALSE as stated.* Create freely; **tag immediately** —
an untagged qube is what policy refuses, and `qvm-clone` fails precisely because it copies volumes
before tags exist (hence `mgmt/clone-to-template.sh`'s create → tag → copy order).

## Verified capabilities

| Capability | Status | Notes |
|---|---|---|
| Create a qube (any name) + tag | **PASS** | `qvm-create --class StandaloneVM --property virt_mode=hvm --property kernel=''` then `qvm-tags add win-idd-testbed` |
| `qvm-remove` | **PASS** | Blocks while the qube is not Halted — drain first (see below) |
| `qvm-prefs` read/write | **PASS** | incl. `netvm`, `qrexec_timeout`, `memory`, `vcpus` |
| `qvm-tags` add/list | **PASS** | |
| `qvm-firewall` add/del | **PASS** | Per-qube rules only; inter-VM traffic is dropped in the netvm regardless |
| `qvm-volume info` / `revisions` | **PASS** | `revisions` has returned empty here — do not rely on snapshots |
| Volume clone between qubes | **PASS** | via `mgmt/clone-to-template.sh` (create → tag → copy). A bare `qvm-clone` fails on tag ordering |
| `qvm-pool info` | **PASS** | `vm-pool` ~81% used, ~155 GB free |
| Start/Shutdown/Kill guests | **PASS** | ACPI `qvm-shutdown` recovers a headless-but-running guest; a hard kill mid-driver-transition can leave it unbootable |
| Screenshots per window | **PASS** | `tools/qtest shot` → tar of `win-N.png`. An EMPTY tar ≠ "no windows" |
| Whole-desktop capture | PASS but **restricted** | `qtest fullshot` photographs every qube. Only for override-redirect surfaces / dom0 compositing |
| netvm attach/detach (live) | **PASS** | Templates stay `netvm=''`; AppVMs/StandaloneVMs get one for network tests |
| `gh` CLI: run list / download | **PASS** | CI packages come from `gh run download -n qwt-improved-setup` |
| `git push origin` | **PASS** | Public repo `arkenoi/qubes-win-idd-driver` |
| pwsh 7.4 locally | **PASS** | `/home/user/pwsh74/pwsh` — parse-check `.ps1` before shipping (`tools/ps-parse-gate.sh`) |
| `7z`, `cabextract`, `python3` | **PASS** | Inspect MSIs, answer-stick images, catalogs |
| **`losetup` ATTACH** | **FAIL** | Permission denied — needs root. Loop devices must already exist; rebuild the backing IMAGE in place at constant size instead |
| `losetup -l` (read) | **PASS** | |

## Environment map

**Loop devices** (attachment needs root; the backing file may be rewritten in place at constant size):

| Loop | Backing file | Role |
|---|---|---|
| loop0 | `Win10_22H2_EnglishInternational_x64v1.iso` | Win10 vendor ISO — **en-GB media** |
| loop3 | `win11-24h2-eval-x64-en-us.iso` | Win11 vendor ISO — en-US media |
| loop9 | `answer-usb.img` | answer stick (rebuilt per campaign) |
| loop10 | `answer-usb-win11.img` | answer stick |
| loop11 | `answer-usb-stock.img` | answer stick |

`mgmt/build-answer-stick.sh` rewrites a stick **in place at constant size**, so the loop stays valid.
`SIZE_MB` must not change. **`LOCALE` defaults to en-US; Win10 media here is en-GB** — a mismatch
drops Setup to the interactive locale picker silently (tell: guest CPU ~1 s per 40 s instead of
~45 s; proof: a screenshot).

**Provisioning:** `mgmt/reprovision-usb.sh <vm> <iso-loop> <stick-loop>`, ~18–20 min, and it
**resets `netvm` and `qrexec_timeout`** because it removes and recreates the qube.

**Not reachable from here:** `fw-net`. `qvm-check` says `non-existent!` but
`qrexec-client-vm fw-net admin.vm.CurrentState` says **`Request refused`** — a POLICY refusal, i.e. a
filtered view, NOT proof of non-existence. Do not claim a qube does not exist on `qvm-check` alone.

**Inter-VM traffic is dropped by the netvm.** Tested: served on `10.137.0.63:8899`, guest firewall
already `accept all`, added an explicit accept rule — **zero requests arrived**. So a local-endpoint
benchmark is genuinely blocked; benchmark against a CDN instead (`speed.cloudflare.com/__down`,
25 MB; 100 MB returns 403).

## Traps that have cost real time

- **Queued qrexec calls auto-start a Halted qube** and outlive the caller, so a guest looks
  "unkillable" and `qvm-remove` blocks for minutes with pool usage unchanged. **Drain: set
  `qrexec_timeout 15` BEFORE the kill/remove, then restore 6000.** Restoring it too early re-pins the
  qube on the next queued call.
- **One Windows guest at a time.** Three at 8 GB starves the host: qubesd calls start failing and
  guests fail to boot. Shut a guest down before starting the next.
- **`qvm-prefs` has reported failure while the write took effect** (`Failed to access 'netvm'
  property` twice, yet the value changed). Re-read the property; never trust the exit message alone.
- **`pkill -f <pattern>`** matches this shell's own command line and kills the session. Filter by PID.
- **A tool-call timeout kills backgrounded children.** Use `setsid nohup … &` for long runs.
- **`pnputil` prints "Driver package added successfully" for a package that did not land** — only a
  DriverStore hash check catches it. And **xenvif.sys differs per CI build**, so cross-build hash
  comparison is meaningless; compare against the package the guest was actually installed from.
- **Inline PowerShell through `qtest run` collapses quotes.** Push a script and run it instead.

## Before writing any plan

1. If a step looks blocked, run the command and record the result. "Unverified" is an acceptable
   answer; "impossible" needs evidence.
2. Do not reinstall Windows where a clone will do — a QWT-free Windows is deterministic. Park a
   pristine image per OS and a stock-QWT image per OS, and clone them. A full reprovision is
   warranted only for the cell that tests Windows-install-plus-QWT-at-first-logon.
3. Never park a half-installed or mid-campaign image in place of a pristine one.
