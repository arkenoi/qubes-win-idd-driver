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

## NEVER REINSTALL WINDOWS TO GET A WINDOWS GUEST (added 2026-08-30, after doing it three times in one night)

**Measured, same session:** cloning a sealed golden took **1.8 seconds**. A reprovision from vendor
media takes **17-20 minutes** and resets `netvm`, `qrexec_timeout` and tags. I ran the reinstall
three times to obtain guests I already had parked, and the owner had to stop me each time
("why do you run windows install each time", "why don't you clone from already installed windows
golden image", "why windows install again? we agreed to clone it from pristine, no?").

    python3 - <golden> <target> <<'EOF'
    import sys, qubesadmin
    app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
    for v in ('root','private'): dst.volumes[v].clone(src.volumes[v])
    dst.virt_mode='hvm'; dst.kernel=''; dst.memory=8192; dst.maxmem=0; dst.vcpus=4
    EOF

**A full reprovision (R3) is warranted for exactly ONE thing:** the cell that tests
Windows-install-plus-QWT-at-first-logon via the answer file. Nothing else. If you are about to run
`reprovision-usb.sh` for any other reason, you are about to waste 20 minutes - clone instead.

## USE THE BUILT-IN TOOLS-INSTALL MECHANISM, DO NOT BUILD ONE

`qvm-start <vm> --install-windows-tools` "temporarily attach Windows tools CDROM to the domain" -
dom0's own supported way to put the QWT installer in front of a Windows guest. **It requires dom0**:
from this qube it fails with *"Existing block device identifier needed when running from outside of
dom0 (see qvm-block)"*, so the equivalent here is attaching the ISO as a cdrom block device.

I did not look for this and instead built a custom answer stick with `REAL_STOCK_EXE`, a staged
installer, a testsigning reboot and a SYSTEM onstart task - an entire mechanism parallel to one that
already existed. **Before building a delivery mechanism, check whether Qubes already has the knob.**

## DO NOT RECORD YOUR OWN FAILURE AS A PROPERTY OF THE PRODUCT

I wrote a FINDINGS entry titled "the GENUINE-stock route did not produce a working stock QWT" after
MY provisioning attempt failed. Stock QWT installs reliably and always has (owner: "it DID install
thousand times before"). That entry would have told every future reader that stock does not install
on this rig, and they would have stopped looking.

**Related, and it cost this session the entire stock-install path:** I claimed "a pristine guest has
no channel, attaching media does not run it". The tools ISO **AUTORUNS** - that is what
`qvm-start --install-windows-tools` is for. Never assert that something cannot be driven without
checking how the product is actually installed by its users.

**And do not aim qrexec at a guest with no qrexec agent.** Already recorded here and in §2.1 ("ST0 -
No qrexec, undriveable"), rediscovered anyway: queued calls against an agentless guest auto-start
it, outlive the caller, and produce the "unkillable qube" once reported as a defect.

**Rule:** when something that has worked many times fails in your hands, the defect is YOURS until
proven otherwise. Write "my attempt failed, cause unknown", never "X does not work". A wrong record
outlives the session that made it.

## DETERMINE, DO NOT ASK, AND DO NOT INVENT

Two failure modes from the same night, both corrected by the owner:
 - asking permission to continue instead of choosing ("no, you did not find it, I did");
 - inventing a mechanism to explain a failure - "stock 4.2.2 cannot speak Qubes 4.3 qrexec" - with
   no evidence, contradicting a path known to work. Owner: "obvious hallucinatory bullshit that came
   from context overload."
If a cause is unknown, the words are "undiagnosed", and the next action is a measurement.
