---
name: rig-capabilities
description: Verified inventory of what this dev qube CAN and CANNOT do against the Windows testbed - Admin API, qube lifecycle, tags, netvm, firewall, loop devices, CI, local tooling - plus the exact environment map (loops, ISOs, pools). Read this BEFORE concluding that anything is impossible, blocked, out of scope, or "needs the owner", and before writing any plan that assumes a constraint.
---

# Rig capabilities — measured, not assumed

A constraint read in a binding file is checked against this table before you act on it - a rule that names an example can be stale in the example while right in the rule.

**The rule: an "impossible" is a measurement, not an intuition. Verify with a command; if you cannot, say "unverified", never "impossible".**

## Policy model — TAG-based, not name-based

`dom0/12-install-policy-tagged.sh` grants on **`@tag:win-idd-testbed`**:

    qubes.VMShell          *  win-idd-mgmt  @tag:win-idd-testbed  allow
    qubes.VMExec           *  win-idd-mgmt  @tag:win-idd-testbed  allow
    qubes.Filecopy         *  win-idd-mgmt  @tag:win-idd-testbed  allow
    admin.vm.Start/Shutdown/Kill/CurrentState/List/property.Get  ... @tag:win-idd-testbed  allow

**Consequence: you MAY create new qube names.** A qube on no roster, once tagged `win-idd-testbed`, gets working `admin.vm.CurrentState`, `admin.vm.property.Get`, `qvm-prefs` read **and** write.

Create freely; **tag immediately** — an untagged qube is what policy refuses, and `qvm-clone` fails precisely because it copies volumes before tags exist (hence `mgmt/clone-to-template.sh`'s create → tag → copy order).

## Verified capabilities

| Capability | Status | Notes |
|---|---|---|
| Create a qube (any name) + tag | **PASS** | `qvm-create --class StandaloneVM --property virt_mode=hvm --property kernel=''` then `qvm-tags add win-idd-testbed` |
| `qvm-remove` | **PASS** | Blocks while the qube is not Halted — drain first (see below) |
| `qvm-prefs` read/write | **PASS** | incl. `netvm`, `qrexec_timeout`, `memory`, `vcpus` |
| `qvm-tags` add/list | **PASS** | |
| `qvm-firewall` add/del | **PASS** | Per-qube rules only; inter-VM traffic is dropped in the netvm regardless |
| `qvm-volume info` / `revisions` | **PASS** | Revisions exist and `qvm-volume revert` WORKS from here. Cut on clean shutdown, hold the session's ENTRY state, `revisions_to_keep=2` and `qvm-volume config` is policy-refused. Use `mgmt/harness/checkpoint.sh` (park/unpark = exact+durable; undo-session = post-hoc, depth 2) — never reprovision for a restore |
| Volume clone between qubes | **PASS** | via `mgmt/clone-to-template.sh` (create → tag → copy). A bare `qvm-clone` fails on tag ordering |
| `qvm-pool info` | **PASS** | `qvm-pool info vm-pool` reports current usage and free space |
| Start/Shutdown/Kill guests | **PASS** | ACPI `qvm-shutdown` recovers a headless-but-running guest; a hard kill mid-driver-transition can leave it unbootable |
| Screenshots per window | **PASS** | `tools/qtest shot` → tar of `win-N.png`. An EMPTY tar ≠ "no windows" |
| Whole-desktop capture | PASS but **restricted** | `qtest fullshot` photographs every qube. Only for override-redirect surfaces / dom0 compositing |
| netvm attach/detach (live) | **PASS** | Templates stay `netvm=''`; AppVMs/StandaloneVMs get one for network tests |
| `gh` CLI: run list / download | **PASS** | CI packages come from `gh run download -n qwt-improved-setup` |
| `git push origin` | **PASS** | Public repo `arkenoi/qubes-win-idd-driver` |
| pwsh 7.4 locally | **PASS** | `/home/user/pwsh74/pwsh` — parse-check `.ps1` before shipping (`tools/ps-parse-gate.sh`) |
| `7z`, `cabextract`, `python3` | **PASS** | Inspect MSIs, answer-stick images, catalogs |
| **BLOCK-DEVICE BINDING** (loop-setup, attach, assign, USB emulation) | **PASS, root-free, every step** | See the explicit table in the Block-device binding section below. `sudo losetup` is the ONE spelling that fails; `udisksctl loop-setup` is the one we use, in `matrix.sh`/`prime-run.sh`/`quick-upgrade.sh`/`build-media.sh` |
| `losetup -l` (read) | **PASS** | Reading loop state never needed root |

## Block-device binding

**BLOCK-DEVICE BINDING — THE CAPABILITIES, EXPLICITLY.** Every row is ROOT-FREE and already in
daily use in this repo. Do not infer any of them from a `sudo` rule, and never report one as
missing without running it first:

| what you need | the command that works HERE | already used at |
|---|---|---|
| file -> loop device | `udisksctl loop-setup -f <img>` (`-r` = read-only) | `prime-run.sh:143`, `quick-upgrade.sh:154`, `build-media.sh:65` |
| release the loop | `udisksctl loop-delete -b /dev/loopN` | `matrix.sh:135`, `quick-upgrade.sh:116` |
| mount it in THIS qube | `udisksctl mount --block-device /dev/loopN` | `quick-upgrade.sh:164` |
| which file backs a loop | `losetup -l` (READ is unprivileged) | everywhere |
| disc into a RUNNING guest | `qvm-device block attach --ro --option devtype=cdrom <vm> win-idd-mgmt:loopN` | ACCEPTANCE-PROTOCOL 0.5 Route A |
| disk into a guest BEFORE start (survives Setup's own reboots) | `qvm-device block assign --required -o frontend-dev=xvdi -o devtype=disk <vm> win-idd-mgmt:loopN` | `prime-run.sh:204`, `reprovision-usb.sh:78` |
| emulated USB stick (WinPE has no PV drivers, so a CD is invisible) | that same assign + `qvm-features <vm> qemu-extra-args -- '-drive file=/dev/xvdi,format=host_device,if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99'` | `prime-run.sh` |
| drop a claim | `qvm-device block unassign <vm> win-idd-mgmt:loopN` | `seal-qwt-golden.sh:43` |

`sudo losetup`, `losetup -d`, `mount` and a dom0 shell are what you do NOT have. Each has a
root-free equivalent in the table above, so needing root for ONE SPELLING never means the
capability is absent.

REAL traps here, none of them permission problems:
- `qvm-device block list` is POLICY-REFUSED from this qube. Assert an assignment by re-issuing
  `assign` and reading "already assigned", or in python via `vm.devices['block'].get_assigned_devices()`.
- `--persistent` on *attach* is an ALIAS for `assign --required`: applied at the NEXT start, so
  against a running guest it succeeds and changes nothing the guest can see.
- `assign --required` PERSISTS while loop numbers are TRANSIENT (recycled on reboot and by every
  `loop-delete`). A stale claim makes the guest unstartable with only `internal error: libxenlight
  failed to create new domain` — check assignments FIRST when a guest will not create (`findings/rig.md`).
- **`qvm-start <vm> --cdrom=<holder>:<loopN>` WORKS.** `matrix.sh` uses it in every reinstall cell.
  What IS broken is the **live** `devtype=cdrom` attach/detach against a RUNNING guest - an uncaught
  `libvirtError` in qubesd that returns an empty response - and `lint-harness.py` rule L12 already
  refuses that. The disc goes in AT START.

## Environment map

**Loop devices** (attach them ROOT-FREE with `udisksctl loop-setup`; the backing file may be rewritten in place at constant size):

`losetup -l` lists the current loops and the file backing each one (a vendor ISO or an `answer-usb*.img` stick); loop numbers are transient, read them before use.

`mgmt/build-answer-stick.sh` rewrites a stick **in place at constant size**, so the loop stays valid.
`SIZE_MB` must not change. **`LOCALE` defaults to en-US; Win10 media here is en-GB** — a mismatch
drops Setup to the interactive locale picker silently (tell: guest CPU ~1 s per 40 s instead of
~45 s; proof: a screenshot).

**Provisioning:** `mgmt/reprovision-usb.sh <vm> <iso-loop> <stick-loop>`, and it
**resets `netvm` and `qrexec_timeout`** because it removes and recreates the qube.

**Not reachable from here:** the network-providing qube (the NETVM column of `qvm-ls`). `qvm-check` says `non-existent!` but
`qrexec-client-vm <netvm> admin.vm.CurrentState` says **`Request refused`** — a POLICY refusal, i.e. a
filtered view, NOT proof of non-existence. Do not claim a qube does not exist on `qvm-check` alone.

**Inter-VM traffic is dropped by the netvm**, regardless of the guest's own firewall rules. A
local-endpoint benchmark is genuinely blocked; benchmark against a CDN instead
(`speed.cloudflare.com/__down`, 25 MB; 100 MB returns 403).

## Traps

- **Queued qrexec calls auto-start a Halted qube** and outlive the caller, so a guest looks
  "unkillable" and `qvm-remove` blocks for minutes with pool usage unchanged. **Drain: set
  `qrexec_timeout 15` BEFORE the kill/remove, then restore 6000.** Restoring it too early re-pins the
  qube on the next queued call.
- **One Windows guest at a time.** Three at 8 GB starves the host: qubesd calls start failing and
  guests fail to boot. Shut a guest down before starting the next.
- **`qvm-prefs` can report failure while the write took effect** (`Failed to access 'netvm'
  property`, yet the value changed). Re-read the property; never trust the exit message alone.
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

## NEVER REINSTALL WINDOWS TO GET A WINDOWS GUEST

Cloning a sealed golden takes seconds. A reprovision from vendor media takes tens of minutes and
resets `netvm`, `qrexec_timeout` and tags.

    python3 - <golden> <target> <<'EOF'
    import sys, qubesadmin
    app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
    for v in ('root','private'): dst.volumes[v].clone(src.volumes[v])
    dst.virt_mode='hvm'; dst.kernel=''; dst.memory=8192; dst.maxmem=0; dst.vcpus=4
    EOF

**A full reprovision (R3) is warranted for exactly ONE thing:** the cell that tests
Windows-install-plus-QWT-at-first-logon via the answer file. Nothing else. If you are about to run
`reprovision-usb.sh` for any other reason, you are about to waste tens of minutes - clone instead.

## USE THE BUILT-IN TOOLS-INSTALL MECHANISM, DO NOT BUILD ONE

`qvm-start <vm> --install-windows-tools` "temporarily attach Windows tools CDROM to the domain" -
dom0's own supported way to put the QWT installer in front of a Windows guest. **It requires dom0**:
from this qube it fails with *"Existing block device identifier needed when running from outside of
dom0 (see qvm-block)"*, so the equivalent here is attaching the ISO as a cdrom block device.

**Before building a delivery mechanism, check whether Qubes already has the knob.**

## DO NOT RECORD YOUR OWN FAILURE AS A PROPERTY OF THE PRODUCT

Stock QWT installs reliably. The tools ISO **AUTORUNS** - that is what
`qvm-start --install-windows-tools` is for. Never assert that something cannot be driven without
checking how the product is actually installed by its users.

**And do not aim qrexec at a guest with no qrexec agent** (§2.1 "ST0 - No qrexec, undriveable"):
queued calls against an agentless guest auto-start it, outlive the caller, and produce the
"unkillable qube".

**Rule:** when something that has worked many times fails in your hands, the defect is YOURS until
proven otherwise. Write "my attempt failed, cause unknown", never "X does not work". A wrong record
outlives the session that made it.

## DETERMINE, DO NOT ASK, AND DO NOT INVENT

 - Do not ask permission to continue instead of choosing.
 - Do not invent a mechanism to explain a failure with no evidence, contradicting a path known to work.
If a cause is unknown, the words are "undiagnosed", and the next action is a measurement.

## WHEN A ROUTE ALREADY WORKS, CHANGE ONE VARIABLE — DO NOT WRITE A SECOND ROUTE

A stock QWT install (`answer-stock.iso` → `payload/install-qwt.cmd`) imports the six vendor
`SigningCert*.cer` into **Root AND TrustedPublisher** before driving the MSI: without
TrustedPublisher the PnP driver-store step can stall or fail on the "install this device software?"
trust prompt, and nobody is clicking there.

**The rules.**
1. Before writing a new path to a result the rig already achieves, find the existing one and
   diff the intent. If the difference is one flag, one feature list, one file — change that.
2. A new route inherits none of the old route's hard-won workarounds. Grep the working route for its comments and carry them across explicitly.
3. Any route that runs on a guest with **no qrexec** must be able to report its own failure on the
   only channel such a guest has: THE SCREEN. Write the log, then arrange for it to be displayed
   (a self-deleting script in the all-users Startup folder + one reboot works, because autologon is
   enforced). "It failed silently" is a defect in the harness, not bad luck.
4. Do not generate a batch script with a stack of `echo` lines into another batch script. The
   quoting has to survive two layers of `cmd` parsing and silently does not. Stage a real file.

## ONE OWNER PER GUEST, AND IT IS THE ORCHESTRATOR

An orchestrator holds `/tmp/reprovision-<vm>.lock` precisely so a second one does not act on the
same guest.

- **Check for the lock and for a running orchestrator before touching a guest**:
  `fuser -v /tmp/reprovision-<vm>.lock` and `ps -eo pid,etime,cmd | grep reprovision`.
- A watcher that acts on the guest is a second owner. If an orchestrator is running, watchers are
  **passive** — read state, read the screen, report. Nothing else.
- A conclusion reached without first checking for the existing owner is an artefact: retract it loudly.
- `cmd | tee log` reports **tee's** exit status. Use `PIPESTATUS`, or do not pipe a status-bearing
  command.

## WHEN GUEST STATE IS IN QUESTION, LOOK AT IT. YOU HAVE THE SCREENSHOT TOOL.

**The rule.** A screenshot is cheap and needs no qrexec. Take one BEFORE reasoning about guest
state, not after a checkpoint says to. Specifically, capture immediately when:

- any guest-directed command FAILS or times out (`qvm-shutdown` failing means something is on screen
  saying why - a blocking app, a dialog, a lock screen);
- a wait loop is not progressing as expected, ESPECIALLY when a metric disagrees with the elapsed
  time - the screen is the independent witness that catches a broken instrument;
- before reporting "it is still working" / "it is stuck" / "it is idle" to the owner. Those are
  claims about the screen. Do not make them from a log;
- before concluding anything about a guest with no qrexec. The screen is its ONLY channel; that is
  the entire premise of the primer and of `PRISTINE` mode.

**Do not wait to be told.** The tool is `tools/qtest shot`, it
works on any tagged guest, and an unread screen is a choice.
