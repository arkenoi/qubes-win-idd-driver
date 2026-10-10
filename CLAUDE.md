# CLAUDE.md — Qubes Windows Tools: agent (Track A), IddCx driver (Track B), updates (Track C)

Binding rules for every session. The incidents behind them are in `findings/rules.md`; measured state is in
the `findings/*.md` CURRENT STATE heads; procedures are in `.claude/skills/`. Keep this file to rules.

## Mission

Radically improve Windows-guest desktop responsiveness and fidelity in the QWT seamless model, with ZERO
security-model changes.
- **Track A** — `agent/` (fork of QubesOS/qubes-gui-agent-windows): window tracking, capture, the per-window
  de-slice broker (`tools/wgcbroker/`).
- **Track B** — `driver/`: the QubesIDD IddCx indirect display driver (arbitrary modes, behind `/idd`).
- **Track C** — the dom0-owned Windows update path, a first-class deliverable IN THIS REPO:
  `guest/qubes-windows-update.ps1`, `guest/wu-update.ps1`, `guest/qubes-updates-relay.cs`,
  `guest/install-updater-agent.ps1` and the scan/availability tasks; record in `findings/updates.md`. Guest
  auto-update is OFF (NoAutoUpdate=1); dom0 drives every install; the relay serves sanctioned hosts or refuses
  with a FINAL 403, never a transient answer, never a timeout as a fix.

## Environment

| Thing | Value |
|---|---|
| Test guests | every qube TAGGED `win-idd-testbed`; goldens `win{10,11}-qwt` and `win11de-qwt` (German 25H2), bases `win{10,11}-base`, `win11de-base` - see the rig-cycle skill |
| Drive a guest | `tools/qtest` (`QTEST_VM=<vm>`): `run`/`ps`/`push`/`pushrun`/`start`/`shutdown`/`kill`/`state`/`shot`; console `tools/qcon` (ONE attach per session) |
| Builds | GitHub Actions (`.github/workflows/`); `gh run watch`; the driver package is `build`'s `idd-driver-package`, the installable ISO is `release-package`'s `qwt-improved-iso` |
| Screenshots | `qtest shot out.tar` -> per-window PNGs of that qube's windows (dom0 service, tagged qubes only); when a whole-desktop capture is justified is in the experimenter skill |
| Signing | CI test-signs with a throwaway cert (secrets already set); guests trust it via `guest/firstboot-setup.ps1` |
| Agent fork | `agent/` submodule, `origin` = the owner's fork, `upstream` = QubesOS: commit there, bump the submodule here |
| Judge | `tools/jev.py` - every SEMANTIC judgment (which class, final vs transient, which cause, is a draft load-bearing); exact matching, counting and timestamp joins stay in code. `.claude/skills/jev/SKILL.md`. Low confidence is a finding; the wire log is the receipt |

## The rig (binding)

- **You control every qube TAGGED `win-idd-testbed` and may CREATE more**: create, tag immediately, and it is
  drivable (policy is tag-based: `dom0/12-install-policy-tagged.sh`). Pre-authorised without asking: qube
  create/remove, `qvm-prefs` read+write (incl. `netvm`), `qvm-tags`, `qvm-firewall`, `qvm-volume` info/clone,
  power state, `qtest` run/push/shot. **Off-limits:** a dom0 shell, `sudo` in this qube, editing qrexec policy,
  qubes that are NOT tagged.
- **Never write a limitation** into code, a comment, a finding, a commit message or a reply until you have
  (a) grepped this repo for something already doing it and (b) run the cheapest probe that would disprove it.
  Before declaring anything impossible, read `.claude/skills/rig-capabilities/SKILL.md` - its list is the record
  of this exact mistake. `fw-net` cannot be started from here: that is a policy refusal, not absence; it exists
  and serves traffic.
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
  capability is absent — that inversion has been made six times and cost hours each time.

  REAL traps here, none of them permission problems:
  - `qvm-device block list` is POLICY-REFUSED from this qube. Assert an assignment by re-issuing
    `assign` and reading "already assigned", or in python via `vm.devices['block'].get_assigned_devices()`.
  - `--persistent` on *attach* is an ALIAS for `assign --required`: applied at the NEXT start, so
    against a running guest it succeeds and changes nothing the guest can see.
  - `assign --required` PERSISTS while loop numbers are TRANSIENT (recycled on reboot and by every
    `loop-delete`). A stale claim makes the guest unstartable with only `internal error: libxenlight
    failed to create new domain` — check assignments FIRST when a guest will not create (`findings/rig.md`).
  - **`qvm-start <vm> --cdrom=<holder>:<loopN>` WORKS - corrected 2026-09-25.** This line said it was
    "BROKEN from this qube and poisons the guest" and cited `findings/rig.md`, where the claim it points at
    (line 59, 2026-09-20) is itself flagged **STALE - not re-measured since the host reboot**, and where a
    LATER entry (line 23, 2026-09-22) records the opposite as measured: the start-time disc was verified
    inside the guest during that campaign, disc at D: with the expected commit. `matrix.sh` uses it every
    reinstall cell. What IS broken is the **live** `devtype=cdrom` attach/detach against a RUNNING guest -
    an uncaught `libvirtError` in qubesd ("device type 'cdrom' cannot hot unplugged") that returns an empty
    response; `lint-harness.py` rule L12 already refuses a live cdrom attach. The disc goes in AT START.
- **Before launching ANY job that installs, boots or reboots a guest, read `.claude/skills/rig-cycle/SKILL.md`.**
  A short test cycle is `mgmt/harness/quick-upgrade.sh` over a golden; a clean install from base is for FULL
  acceptance, or when the clean-install path is itself under test. A broken upgrade harness is a thing to FIX,
  not a licence to clean-install.
- **A release's gate is SCOPED to what the diff touches** (owner 2026-10-07, `docs/ADR-acceptance.md`), which REPLACES
  "full acceptance before every release": `tools/gate-scope.py required <base>..<head>` says which suites are needed
  and why, over an always-run core; the full gate - all install variants and the fault-injection path - is forced by
  an unmapped path, by 10 releases or 21 days since the last passing full run, by a failed full run, or by a change to
  `mgmt/gate-scope.json`. `tools/hooks/release-cut-gate.sh` refuses a cut whose coverage receipt does not satisfy it,
  and `mgmt/gate-ledger.json` is where the counting comes from. Never assert the floor by hand; run the tool.
- **Run VM-mutating jobs serially** (`mgmt/harness/vmlock.sh`): concurrent jobs reboot the guest underneath each
  other and destroy each other's results.
- The test guest is disposable and assumed hostile: nothing from it is executed here, its output is parsed as
  data. If it wedges: `qtest kill`, then `qtest start`.

## Networking (binding)

- Templates (`win10-tpl`, `win11-tpl`) stay `netvm=''`. AppVMs/StandaloneVMs that exercise PV networking MUST
  have a netvm (`qvm-prefs <vm> netvm fw-net`). Payload still ships via `qtest push`; the netvm exercises the PV NIC.
- **PV-network testing protocol:**
  1. **A second boot is a FAILURE.** An AppVM with our QWT must take an immediate netvm attach with ZERO
     reboots (vif appears, PV NIC binds, emulated adapter unplugs, same boot) - that is what
     `guest/pvnic-selfprime.ps1`'s latch + veto key deliver. Needing a second boot means the latch is absent or
     broken (`pvnic_applier` reports it); a bare StandaloneVM has no latch and is not the configuration to accept against.
  2. Grade no sooner than ~90 s after qrexec comes up.
  3. Assert traffic with a FILE TRANSFER (a few MB over the PV NIC, cross-checked against that adapter's
     `rx_bytes` delta), never by pinging the gateway (a Qubes netvm does not answer ICMP). DNS or a TCP connect
     is only a smoke test.
  4. A guest that has already seen a vif cannot test first-vif behaviour; that needs a guest that never had
     one, with the watcher armed before the vif appears.
  5. The premature reboot dialog is a network-path event ("Xen PV Network Class"): a `netvm=''` result proves
     nothing about it.

## Field reports (binding)

A field report is reproduced on the REPORTER'S environment, enforced by code: the environment is data in
`mgmt/reporters/<name>.json`; `mgmt/harness/env-assert.sh <vm> <name>` must pass before the rig is used for it;
the PreToolUse hook `tools/hooks/reporter-env-gate.sh` refuses a launch that names a registered reporter
without it. If that environment does not exist on the rig, building it is the first task.

## The public repo and upstream (binding)

- **The repo is PUBLIC.** Captures of any kind, per-run evidence, raw benchmark output and incident/security
  notes go to `scratchpad/` (gitignored) or the private memory dir - never a tracked path, never a new
  "evidence"-style directory. Stage named files only; never `git add -A`. `.githooks/` inspects commits and
  pushes (`core.hooksPath=.githooks` stays set); no bypass, no `--no-verify`. When unsure, it stays out.
- **Submit NOTHING upstream** until the work is finished and a complete new QWT exists: no PRs, no issues for our
  own agent work, no "small reviewable PRs" proposed, never a push to QubesOS repositories. The one exception: defects in components that are NOT
  ours (`qubes-gui-daemon`, vchan/libvchan, `qubes-core-admin` tooling) are reported when found - only with the
  owner's approval of the exact text. Currently qualifying (see `DESIGN-gui-daemon-restart-survival.md` §3):
  gui-daemon's `handle_vchan_error` never consults `vchan_at_eof`; a use-after-free if `execv` fails in
  `restart_guid`. Everything in `agent/` stays in the fork.
- Anything touching the GUI protocol, gui-daemon or the grant lifecycle: design writeup first, owner review,
  upstream design issue (referencing #1861) before code. Never start it unilaterally.

## Product decisions (binding)

**Fullscreen: two independent modes - never conflate them.**
- **Mode 1, the boot/shutdown/logon screen: UNCONDITIONALLY OFF**, not governed by any feature. Enforced in
  `ShouldAcceptWindow` by class (the per-window LogonUI window) AND by PHASE: a fullscreen-sized window is denied
  while no shell window exists (boot, logon, shutdown), while the input desktop is secure, and for
  `FS_BOOT_SETTLE_MS` after it stops being secure; override-redirect + fullscreen is rejected unconditionally.
- **Mode 2, a borderless true-fullscreen app window** (>= ~99% of the guest screen, no `WS_CAPTION`): mapped only
  when opted in via `qvm-features <vm> service.gui-fullscreen 1` (qubesdb `/qubes-service/gui-fullscreen` wins over
  the registry `ShowFullscreenScreen`), read once at agent Init. A maximized window WITH a title bar is always
  allowed. The feature governs ONLY Mode 2.
- **Secure desktop** - mode-dependent; the safety criterion is geometry, not desktop identity: SEAMLESS - never
  mapped, since each secure surface would become its own standalone dom0 window indistinguishable from dom0's own
  UI (the frame path freezes while the input desktop is not Default, enforced in `ProcessNewFrame`; `QGADESKSTUCK`
  logs a persistent freeze). NON-SEAMLESS - shown, secure or not:
  window 0 is shrunk on entry (1280x800) and refused at host size unless `g_ResolutionFromDom0`, so a guest can
  never promote itself to fullscreen; `qubes.SetGuiMode` is honoured on any guest - the desktop surface is plugged
  in on entry (grant made, window 0 mapped) and unplugged on exit, so a seamless guest never holds a
  whole-desktop grant.
- **Autologon is enforced** (`guest/set-autologon.ps1`: credentials validated with `LogonUser` before writing,
  password as the LSA secret `DefaultPassword`, re-asserted by a boot-time SYSTEM task) - it is how lockouts are
  handled. UAC runs with `PromptOnSecureDesktop=0`.
- **Controls: ONE feature.** `service.gui-fullscreen` is the single control for guest-originated fullscreen and the
  top-level README's feature table is its specification. Do not invent knobs, modes or behaviours around it; when
  behaviour and README disagree, the README wins and the code changes.

**Capabilities are decided at START.** System/build capabilities (`g_OsBuild`, `g_WgcBroker`, `g_SliceRetire`,
`g_DeSlice`, `PwEnabled()`) are latched once at Init and never re-read at runtime. A component that was working
and stops is a FAILURE of an eligible system - reported loudly, never quietly recovered from, never treated as
a capability change (`BrokerState()`: NOT_ELIGIBLE is start-time only; STARTING/READY/DOWN are runtime).

**Window filtering.** Chrome fragments that are not windows (Office shadow strips: layered + transparent +
no-activate owned windows, alpha 0 via `GetLayeredWindowAttributes`, DWM-cloaked) are dropped; popups, tooltips
and toasts are sent as override-redirect, like the Linux agent does for menus, and toasts must STAY mapped. The
same predicate owns the Win11 25H2 "double windows" class - `tools/winenum` dumps every top-level HWND's
attributes to find the discriminator. Any change to the predicate is tested against BOTH `tools/chromerepro`
(main window + layered shadow strips + a popup) and a live toast (`Windows.UI.Notifications`). Never weaken
daemon-side bordering - the fix is to stop presenting chrome fragments as windows. Real-Office validation happens
in the owner's Office qube: ask first.

**Displays (IDD).** Never let a monitor dom0 does not see extend the desktop: an active second monitor enlarges
the desktop bounding box the agent maps as the screen, Windows places windows where dom0 never looks, and seamless
coordinates break. A monitor that must be "ignored" is INACTIVE (`SetDisplayConfig`), not merely uncaptured. If
the IDD ever has to feed frames through its own grant path (a staging copy in the swapchain loop + xeniface gnttab
IOCTLs) rather than the existing capture, STOP and present that plan to the owner before starting it.

## Retired and parked lines (binding)

Before naming ANY component as a cause or a gap, run `git log --oneline -S<name> -- .` and read the newest
commits first. A line the owner has retired stays closed until the owner reopens it in writing.
- **The gui-agent-restart-survival line - RETIRED** (owner 2026-10-10: *"guest daemon restart NEVER was
  the cure, stop chasing this path at all"*). `DESIGN-gui-daemon-restart-survival.md` §2 and §3 are closed:
  no graceful-stop work, no in-process re-listen, no G0 A/B of the restart procedure, nothing pending upstream.
  §1.1 stays as mechanism reference only. **"dom0 shows no windows for a live guest" was never a reported
  symptom** - it was assembled from that document, one harness line the harness itself grades
  `INVALID-INSTRUMENT`, and an assistant's own notes quoted back as measurements (2026-10-10; the file that
  carried it is deleted). What WAS reported are dom0 TOASTS: the register entries are `SHUTDOWNDEATHTOAST`,
  `SWEEPNOTREAD` and `NOTIFYCLOCK` in `findings/issues.md`. A toast is traced from its text to its WRITER
  before anything is grepped - the death family is watchdog/agent -> Application log 4001-4004 ->
  `guest/qwt-report-death.ps1`, which shares no log tag with the agent's own `QerrReport` route.
- **A gui-daemon RECONNECT is BEST EFFORT - never a mandate, never a sanctioned path** (owner 2026-10-10:
  *"we MAY reconnect. but it is best effort, not a mandate nor a scantioned path"*). It may be OBSERVED, never
  demanded: no suite, probe or acceptance criterion may require one to pass (Jev `suite_may_require` 0.27), and no
  fix may be built on one. `gate-preflight` applies its bit across a REBOOT for exactly this reason. The sweep's
  `vchan_reconnects` breach names the LOST connection, not the re-announce (Jev split it 0.53/0.36 - left graded,
  the `why` string says which). Distinct from the NOTIFICATION BRIDGE's relay reconnect, which IS ours and IS
  asserted (`a0-toast-bridge.sh` P6b); never conflate the two.
- **The xenbus bucket-lock line - RETIRED** (reverted entirely f7c16ce). Stock xenbus 9.1.0.0 in a guest is the
  INTENDED state. Do not name xenbus in a finding.
- **set-gui-mode's "stale GetLastError" and "exit status 46" - both CLOSED** (43019f5: measured, the success path
  returns 0; 46 is `qrexec-wrapper` passing a Win32 error when child setup fails). Do not name set-gui-mode as a
  cause; there is no "upstream agent" to report anything to.
- **Win10 22H2 parked updates - informational BY DESIGN** (`findings/updates.md`): KB5071959 is never chased;
  KB5068781's only gate is the owner's ESU licensing. A Win10 22H2 guest reporting 0 actionable updates with ESU
  items as info is CORRECT.

## Working rules (binding)

- **Escalate to the owner only** when: a dom0/sudo/policy/vCPU change is needed; upstream contact is warranted;
  an acceptance cannot be met after ~3 focused iterations; a test guest needs a reinstall; or a security-relevant
  tradeoff appears (anything weakening isolation is out of scope, period).
- **Operator intervention is Jev-bound.** Before stopping to put a question to the owner, ask Jev whether you
  should (what you are blocked on, what you would do with no answer, the cost of guessing wrong) and act on the
  verdict - if Jev says decide it yourself, decide and surface the point in the next report. Enforced:
  `tools/hooks/ask-operator-gate.sh` refuses `AskUserQuestion`/`ExitPlanMode` unless the wire log carries a recent
  Jev question whose id contains `ask_operator`, `should_ask`, `operator_intervention`, `escalate_to_owner`,
  `interrupt_the_owner` or `blocking_question` (it checks that the question was asked, not the answer). The
  mandated approval gates above stay real.
- **Do not stop to report and never ask what to do next.** A turn ends when the goal is met or a genuinely
  blocking external dependency is hit (a dom0 action, a credential, an approval this file mandates). If several
  things are open, work them in order without checking in. Choose, act, and say what was chosen; questions are
  for the approval gates this file mandates (upstream submission, dom0/policy changes), not for direction.
- **Evidence.** Absence of a regression is not evidence of intended behaviour: a fix is done when its intended
  effect is demonstrated - the defect gone, measured, against a control. No result counts until the instrument is
  validated:
  1. a metric is shown stable on ONE unchanged binary over >= 3 runs before any verdict;
  2. build comparisons run >= 3 times per side, interleaved with the control;
  3. the artefact under test is verified installed (running binary hash vs the manifest);
  4. missing data FAILS - never an approximation, never a silent skip;
  5. a check counts as evidence only once it has been seen to FAIL with the defect present.
- **Judge output, not logs** (the pixels changed, not "recovered" in a log). **Test the boot path** - a reboot is
  part of acceptance. **Retract loudly and immediately** when a claim turns out wrong: say so plainly in the next
  message and in the doc, and remove it from any status summary.
- Commit early and often; record findings in the `findings/*.md` CURRENT STATE heads.
