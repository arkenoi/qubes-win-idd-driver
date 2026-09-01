# autologon — findings

## CURRENT STATE

AUTHORITATIVE. Supersedes everything under History below. A correction belongs HERE,
not only as a new dated section — the whole reason this file exists is that 654
correction lines were buried chronologically in a 25k-line log, so reading a topic
top-down returned the stale answer.

- Sections dated 2026-08-30/31 were ERASED on 2026-09-01 (owner call: those sessions were contaminated and their output is void). Do not cite them and do not reconstruct them from git history. Claims RETRACTED in that window STAY retracted; claims MADE in that window are void — re-verify live before relying on anything that traces there. [verified 2026-09-01]
- Not yet distilled from the history below. UNVERIFIED

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

## 2026-08-01 (session 3) — composite synthesis + work-area sync

### Composite synthesis (agent 49e119a, CI 30691320005) — WORKING, dom0-verified
Owner-contained override-redirect windows (menus, tooltips, bubbles; <=4px overhang)
are now SYNTHESIZED: tracked locally, never announced to dom0. Verified with Notepad's
File menu: dom0 window list = 1 window (was 2), the menu renders INSIDE Notepad with no
border rectangle of its own, 0 vchan disconnects.

Design choice (adversarial workflow wf_82dac5f5, 5 agents): the analysts' first design
switched the OWNER to slice-fed while any child existed; the attackers showed that costs
a full ~19MB grant rebuild per popup show/hide (menu browsing = continuous churn) and
bleeds every overlapping guest window into the owner for the popup's lifetime. Shipped
instead: **owner stays PrintWindow-fed + capture MASK + per-rect patch**. wincapture's
row loop compares/copies only the segments between masked column ranges, so the popup
region is never overwritten; the frame loop patches exactly that region from the live
DDA desktop image. No grant churn, no whole-owner bleed, popup pixels are composited
truth (which is what a topmost popup should show).

Two bugs found by running it, both dom0-verified:
1. **Invisible menus**: a menu paints ONCE before the tracking pass learns it exists, and
   a static screen then yields no further DDA frames -> the dirty-rect-driven patch never
   ran. Fixed by publishing the live framebuffer pointer in globals (valid for the whole
   duplication - the daemon reads it continuously) and patching immediately at synthesis.
2. **Daemon killed (whole-qube GUI loss, reproduced live)**: materialization cleared
   `Synthesized` and relied on the normal removal path to re-add the window, but
   RemoveWindow's silence gate tested `Synthesized` -> it sent UNMAP+DESTROY for an hwnd
   the daemon never had a CREATE for. Fixed with an explicit `CreateSent` flag gating all
   teardown sends (also covers failed announces). The attackers had flagged exactly this
   divergence between the two analysts' change lists as "itself a latent daemon-killer".

### Work-area sync (agent workarea.c) — implemented, partially validated
Sources in priority order: registry `WorkArea="x,y,w,h"` / qubesdb `/qubes-workarea`
(written by the optional dom0 watcher `dom0/09-install-workarea-watcher.sh`, live across
panel/monitor changes) / inference from daemon-dictated window origins. Applies
SPI_SETWORKAREA + SetWindowPlacement re-fit of maximized windows.
Measured: SPI_SETWORKAREA **must not** carry SPIF_SENDCHANGE - the broadcast makes
Explorer recompute from its own taskbar geometry and revert us (verified both ways
in-guest); without flags it sticks. OPEN: after an agent restart the value was observed
back at the OS default, i.e. something (Explorer's WM_DISPLAYCHANGE recompute after the
agent's SetVideoMode) still overwrites it asynchronously -> needs a periodic re-assert
(cheap SPI_GETWORKAREA compare on the existing ~2s tick) before this is reliable.
No dom0/daemon changes; MSG_WORKAREA dispatch is present but dormant (locally-defined
constant) until a protocol-1.9 daemon exists.

### Work-area re-assert made event-driven (agent, CI 30693970781 green)
User asked for event-driven rather than timed. Both halves now are:
- dom0 watcher: `xprop -root -spy _NET_WORKAREA` blocks until a change (the 60s loop in
  it is only a re-push safety net for VM restarts, not the change detector);
- guest: qubesdb `qdb_watch` blocks; and the re-assert against Explorer's overwrite is a
  hidden top-level window on the window-event thread's existing message loop handling
  WM_SETTINGCHANGE(SPI_SETWORKAREA)/WM_DISPLAYCHANGE. No timers, no polling. (The
  listener must be a real top-level window: broadcasts skip HWND_MESSAGE windows.)
Build note: workarea.c has no <stdint.h>, so no uint32_t casts there.

### BLOCKED: guest unreachable after attaching a netvm (for the Office test)
User attached `fw-net` to win-idd-test for Windows activation + an Office trial download.
After the required restart the VM reports power_state=Running with high cputime but:
qrexec never answers (many probes over ~20 min), and a dom0 full-desktop screenshot shows
NO win-idd-test windows at all (agent never connected). One kill+start cycle already
attempted; per CLAUDE.md the second failure stops for user input rather than retrying.
Nothing in the guest could be driven, so the Office/Word rendering test did not start.
Suspects, in order: (a) the expired EnterpriseSEval license watchdog interacting with a
now-networked boot, (b) QWT network-setup on first netvm attach, (c) unrelated boot stall.
The last agent build deployed to the guest is CI 30691320005 (synthesis, validated);
CI 30693970781 (event-driven work-area re-assert) is built but NOT yet deployed.

### Windows ISO acquisition: what actually blocks automation
Microsoft's software-download connector API is reachable and works headlessly for the
catalogue steps (session GUID -> page cookies -> vlscppe fingerprint ->
getskuinformationbyproductedition returns the full SKU list; Win10 22H2 English = SKU
16067). The FINAL call, GetProductDownloadLinksBySku, returns
`{"Key":"ErrorSettings.SentinelReject","Value":"Sentinel marked this request as rejected."}`
even from a residential exit IP - so it is the SESSION that is rejected (no fingerprint
JS executed), not the address. quickget/Fido fail identically for the same reason.
Script kept at `tools/get-win-iso.sh` with this documented; finishing it needs a real
browser engine to run the vlscppe fingerprint once and hand over its cookies.
Workaround used: Firefox opened in the mgmt qube, link copied, curl'ed.
ISO in flight: ~/win-iso/Win10_22H2_EnglishInternational_x64v1.iso (5.71 GB).

### NEXT SESSION - clean-room rebuild (user's leftover-independence test)
The current guest carries sediment from this session (hand-swapped gui-agent.exe +
.orig backups, a WorkArea registry value, an expired eval license, a mid-life netvm
attach) and is currently UNREACHABLE (Running, no qrexec, no windows). Plan:
1. `mgmt/build-unattended-iso.sh ~/win-iso/Win10_22H2_EnglishInternational_x64v1.iso "Windows 10 Pro" --with-key`
2. wipe + recreate win-idd-test (dom0/02-create-win-qube.sh mirrors the Admin API calls
   this qube is allowed to make), install unattended with QWT, keep netvm OFF.
3. deploy CI 30693970781 (composite synthesis + event-driven work-area sync) onto the
   pristine guest - this validates the agent against stock QWT, not our leftovers.
4. then: maximized-window geometry check, and the MS Office/Word rendering test the user
   asked for (Word is the most complex window layout available: ribbon, backstage,
   dropdowns, task panes - the real synthesis stress test).

## 2026-08-01 (session 3b) — CLEAN-ROOM REBUILD DONE; synthesis paint defect found on it

### Rebuild (user's leftover-independence test) — SUCCESS
Retail Win10 22H2 (English International) installed unattended on a wiped win-idd-test:
`OS=Windows 10 Pro, BUILD=10.0.19045`, testsigning Yes, QdbDaemon/QrexecAgent/
QubesGuiWatchdog Running, stock `gui-agent.exe` = 80968 B, QubesIncoming path unchanged.
qrexec answered 16 min after boot. **Retail, not eval** -> no more hourly wlms shutdowns
(License Status: Notification = unactivated only).
Two build fixes were needed vs the eval image: (a) `install.wim` is 5.17 GB > ISO9660's
4 GiB, split to .swm with wimlib (this xorriso has no UDF write support); (b) the answer
file must match the media language - our en-US autounattend made Setup silently ignore
the unattend and sit on the locale picker; switched to en-GB (`0809:00000809`),
`autounattend.xml.enus.bak` keeps the original.
Media attach from this qube: `sudo losetup --find --show --read-only <iso>` then
`qvm-start win-idd-test --cdrom=win-idd-mgmt:loopN` (the PATH form is dom0-only; the
loop-device identifier form works from a VM).

### Our build OVERLAID on stock QWT: window suppression OK, composited paint MISSING
NOTE (user): this is an OVERLAY (install-qwt-improved.ps1 swaps bin\gui-agent.exe on an
existing QWT 4.2.2, watchdog left stock) - the GUEST is clean, the QWT install is not
"our stack installed cleanly". User decision 2026-08-01: go for a FULL SOURCE BUILD of
qubes-windows-tools with our agent fork integrated, and deploy that instead.
Deployed 4.2.2+agent.03f04018d508 (CI 30693970781) on the pristine guest: install OK,
agent 124664 B, 0 vchan disconnects, synthesis activates on Notepad's File menu
(`msg=SYNTH,hwnd=0x10296,owner=0x30256,x=254,y=309,w=229,h=196`) and dom0 correctly
shows ONE window (no separate bordered menu window).
**CORRECTION (user caught this): the "red-bordered letter boxes" were NOT ours.** The
full-desktop service captures the WHOLE dom0 screen including other qubes' windows, and
the parallel session's win11-idd-test Notepad was stacked over ours at those coordinates.
Cropping win-idd-test's rect out of a full-desktop shot does NOT isolate our VM. Use the
VM-SCOPED per-window service for anything about OUR window contents
(`tools/qtest shot` -> local.WinScreenshot+win-idd-test, which does import -window on our
window ids only); reserve fullshot for dom0-side geometry/border questions, and even then
read geometry.txt rather than eyeballing overlapping pixels.
**The real symptom, re-measured VM-scoped with the menu open (MENU=0x4017e):** the
dropdown is simply NOT PAINTED - Notepad's window shows "File" highlighted and blank
client area where the menu should be composited. So synthesis suppresses the child window
(correct) but PwPatchSynthChildren contributes nothing on this guest.
NEXT SESSION starts here. Hypotheses, cheapest first:
1. wrong source geometry: the copy uses guest screen coords (c->X/Y) into the granted
   framebuffer; if this guest's screen != the framebuffer stride/size assumed
   (g_ScreenWidth vs frame->rect.Pitch), rows smear - check g_FbPitch vs g_ScreenWidth*4
   on this guest (fresh install may have a different DDA pitch/padding).
2. mask/patch rect mismatch: WcSetMask clips to PwWidth/PwHeight of the OWNER buffer,
   patch clips to the same - verify owner PwWidth vs Notepad's actual 2566x1022.
3. the red borders in the fragments suggest the copied region is NOT the menu at all but
   another part of the composited desktop (borders are dom0-drawn, so their presence in
   guest framebuffer content would mean we are reading dom0-composited pixels - impossible
   -> more likely these are Notepad's own menu-item bitmaps at wrong offsets).
Repro: deploy on clean guest, open Notepad, Alt+F, `tools/qtest fullshot`.

## 2026-08-01 (session 6) — full source build: inventory done, qwt-full.yml cut; synth mid-draw fix landed

### Lost fix re-implemented (PLAN hazard cleared)
The "200 ms full re-copy of synthesized children" fix existed nowhere on disk (previous
session wrote it but never committed; no stash). Re-implemented as agent `382fa05`:
`SynthLastFullPatch` (DWORD, GetTickCount) on the owner's WINDOW_DATA, stamped at
SynthActivate's initial paint; in ProcessNewFrame's PwIsAttached/non-slice branch, when
SynthChildCount>0 and >=200 ms elapsed, `PwPatchSynthChildren(entry, NULL)` (NULL = full
child rects, same path as PwPatchSynthRect) + damage via the existing
PwPatchSynthChildClipped -> SendWindowDamageEvent. Reviewed: lock discipline unchanged
(runs where the existing patch loop runs), wrap-safe tick math. Limitation (documented in
commit): tick fires only while frames flow — acceptable, a painting popup IS a frame source.

### PLAN step 1 (inventory) — headline corrections to the plan's assumptions
Full record: ci-notes/qwt-full-build.md. Upstream clones under upstream/ro/.
- `QubesOS/qubes-windows-tools` does not exist; QWT 4.2.2 = qubes-builderv2 building
  independent component repos + `qubes-installer-qubes-os-windows-tools` (WiX v4.0.5,
  tag v4.2.2-1 = 14c189e). No submodule to override; MSI wants a flat
  `QUBES_REPO\<comp>\bin\<file>` tree (72 files) + per-component sign.crt.
- **PV network "packaging gap" was a misdiagnosis**: ADDLOCAL always had PvDriversNetwork
  and it staged correctly (DifX). xenvif can only bind once a netvm-provided VIF exists,
  and the emulated-RTL8139 unplug is a two-boot dance (arm Services\XEN\Unplug on first
  PV start -> reboot -> xen.sys unplugs at early boot; vetoed until a VIF was enumerated
  once). Expected remedy on the wiped guest: attach netvm, reboot twice. install-qwt.cmd
  ADDLOCAL needs NO change.
- EWDK-in-CI infeasible (15 GB); choco-WDK (83 s, WDK 26100) proven by the idd-driver job
  if drivers-from-source is ever wanted.

### PLAN step 2 decision: rebuild the real installer from source in GitHub CI
Chosen integration = build installer.msi + Burn bundle from the genuine upstream WiX
sources (pinned v4.2.2-1) with QUBES_REPO staged from (a) our CI-built, test-signed
gui-agent/gui-watchdog + our cert as gui-agent-windows sign.crt, (b) all unchanged files
bit-identical from the GPG-verified shipped MSI (vendored: vendor/qwt-4.2.2/, ITL sigs and
certs kept). Rationale + rejected options in ci-notes/qwt-full-build.md §2. User directive
recorded: build remotely on GitHub whenever possible.

### PLAN step 3: .github/workflows/qwt-full.yml added
Single windows-2022 job; agent steps reused verbatim from build.yml; new pieces:
packaging/stage-qwt-repo.ps1 (parses wxs QUBES_REPO refs, stages from admin image with
hash-dedupe, fails loudly), .distfiles nupkg pinning, fake EWDK tree for the bundle's
vc_redist, TEST_SIGN=1, CWD=vs2022\installer for the CreateVersionWxi CodeTask.
Iterating to green next; then step 4 (unattended ISO with our MSI) + step 5 acceptance.

### Session-6 install-path findings (reinstall-over-existing-guest, API-started)
1. **bootfix.bin**: MS media prompts "Press any key to boot from CD/DVD" whenever the disk
   already carries a bootable OS; unattended = prompt times out = the OLD install boots.
   Tell: qrexec ANSWERING during what should be Setup (old QWT lives). Fix landed in
   build-unattended-iso.sh: delete boot/bootfix.bin from the repacked ISO (promptless CD
   boot). Fresh/empty disks never hit this - why the session-3b rebuild worked.
2. **API-initiated qvm-start gives NO VGA console** (OPEN, dom0-side): starts issued from
   this qube leave the domain labeled Transient and never attach qubes-guid until qrexec
   connects, so install-phase boots are headless; dom0-initiated starts show the VGA
   console from BIOS onward (user-confirmed behavior). Consequence: during unattended
   installs the ONLY instruments are admin.vm.CurrentState cputime deltas (~1 s/s = WIM
   apply or payload stage; ~0 = wedged) and halt events; qvm-ls state stays Transient
   throughout, and qvm-start blocks ~10 min returning 0 around the reboot. Do not read
   Transient as stuck - read cputime.
3. Reinstall-over-existing-guest needs no qvm-remove: autounattend WillWipeDisk=true wipes
   disk 0 from Setup. (qvm-remove and sudo were permission-blocked this session anyway;
   udisksctl loop-setup replaces sudo losetup, and stale loop capacity after an ISO
   rebuild is detectable via /sys/block/loopN/size vs the file size.)

### ROOT CAUSE of the "headless install / blackbox" episode: stale `gui` feature
`qvm-features` are advertised by the GUEST (QWT sets `gui=1`, `qrexec=1`) and SURVIVE a
disk wipe, because they live in the qube's metadata, not the disk. With `gui=1` still set,
dom0 believes the VM supplies its own gui-agent and never starts the EMULATED VGA console
-> every install-phase boot is invisible, and the only telemetry left is cputime/disk
deltas. This is why the console "used to appear at boot and vanish when seamless kicked
in" (fresh qube: no gui feature -> console; after QWT: gui=1 -> seamless) and why it never
appeared during reinstalls.
FIX before any reinstall on an existing Windows qube:
    qvm-features --unset <vm> qrexec
    qvm-features <vm> gui ''          # or --unset; must not be truthy
    qvm-features <vm> gui-emulated 1  # dom0 attaches qubes-guid to the stubdomain
Verified: after setting these, `tools/qtest fullshot` shows a real console window -
720x400 (VGA text: BIOS/CD load) then 1024x768 "Setup is starting". Console geometry is
therefore a first-class progress signal: 720x400 = firmware/boot, 1024x768 = Setup GUI.
Corollary corrections to earlier notes in this session:
- "API-initiated qvm-start gives no console" was WRONG - the feature flags decided it, not
  who initiated the start. Retracted.
- A black 720x400 console with ~0 cpu is the SLOW BIOS/CD-load phase, not a hang; it can
  last minutes on a 5.8 GB ISO before Setup switches to 1024x768.
New instrument: `mgmt/win-install-watch.sh <vm> [dir]` - per-90s screenshot + cputime +
disk sampling, emits only console-phase changes, halts (auto-restart), stalls (~9 min of
nothing), or QREXEC UP. Replaces the state-only babysitter for install runs.

## 2026-08-02 (session 7) — CLEAN INSTALL of the fixed package: gates 0 and 1 PASS

Wiped-disk unattended install of `installer.msi f590c878…` (agent `a459f0e` = perwindow +
workarea 0x5 fix `2c5dad2` + drag suppression `d64bca6`). NOT an overlay: `gui-agent.exe`
= `663d7e9b…` (CI manifest), **0 `.orig` files**, `QWT_INSTALL_OK`, MSI status 0, ARP
"Qubes Windows Tools v4.2.2.0", testsigning Yes, services Running.

### Workarea fix: works, and immediately exposed a defect it created
- `WorkAreaCreateListener … 0x5` count: **0** (was 3/agent-start on every build since
  6d46132). Root cause was `OpenInputDesktop` lacking `DESKTOP_CREATEWINDOW`.
- The drift check earns its keep on the very first boot:
  `work area drifted: OS has (0,0)-(3440,1400), ours was (5,56)-(3435,1435); re-asserting`
  — exactly the Explorer overwrite that beat the old build.
- **NEW DEFECT (found by measuring, not reading): re-assert ping-pong.** The now-live
  listener re-asserted on every broadcast, and Explorer answers each of our
  SPI_SETWORKAREA with its own: **1018 applies in 84.9 s (~12/s)**, 293 in the last 20 s,
  each an EnumWindows + cross-process SetWindowPlacement sweep **on the hook thread**.
  Every one issued a real SPI_SETWORKAREA, i.e. the OS value differed each time →
  Explorer's disagreement is PERSISTENT, not transient.
- Fix v1 (`425c439`, sliding-window debounce) was **rejected in review**: a suppressed
  call still stamped the deadline, so any sustained external broadcast train would starve
  re-asserts *including the drift-check backstop*. Reworked in `b299011`: CAS gate that
  leaves the deadline untouched, applied ONLY to WM_SETTINGCHANGE, plus a
  5-strikes→30 s backoff for a fight we cannot win. Acceptance is a 120 s idle
  measurement, not a reading.

### Gate 1 (both previously BLOCKED by the wedge) — PASS
- **Win10 regression for the five win11-line fixes**: occlusion 76/76 damage to the front
  window, 0 to the occluded one (dom0 pixel check: 0 cover-coloured px in the overlap);
  menu SYNTHesized into its owner, never announced; drag 526 records "all invariants
  hold"; announced geometry == DWM extended frame bounds exactly; chromerepro
  GUEST-COUNT=5 MAPPED-OF-OURS=1; 0 shell-overlay rejections of legitimate windows,
  0 sub-floor announcements. **Drag-fix engagement proven**: `QGADRAG ev=suppress 153,
  refresh 59, settle 2` during the drag, `ev=maskpush` only OUTSIDE it (the menu-over-drag
  criterion).
- **Edge ULW first-run**: agent pid stable, 0 vchan/daemon-kill signatures, ULW window
  slice-fed via the shipped fallback while the normal frame took the PrintWindow path,
  window renders real content, clean unmap on close.
- Two limitations reported rather than papered over: `check-occlusion.py`'s screen-slice
  criterion is INVALID for per-window-captured windows and needs a rewrite before its
  result counts again (ACCEPTANCE-PROTOCOL.md still lists it as proven); Edge's "true
  first run" is qualified (Windows pre-initialised the profile during install).

### RETRACTED: "MSI REINSTALL starves the guest"
I wrote that entry from two mistakes of my own and it is WRONG on both counts.
1. The reinstall never took effect: `gui-agent.exe` was still `663d7e9b…` (a459f0e)
   afterwards, so nothing about `b299011` was ever exercised by it.
2. qrexec had in fact RECOVERED at 01:44:59 — my probes used 12-15 s timeouts against a
   busy guest and read "slow" as "dead", and I then destroyed the domain on that basis.
What actually happened: a PV-driver-touching reinstall attempt caused transient boot-time
PnP churn on the OLD (churning) build, which resolved on its own. Lesson recorded because
the same short-timeout mistake produced a premature `qtest kill` twice today: when probing
a guest under load, use >=40 s timeouts and confirm with a cputime trend before killing.

## Guest state at end of session

| thing | value |
|---|---|
| `netvm` | **detached** (`''`) — still a measurement control, NOT the end state T6 wants |
| `gui-agent.exe` | `4DA9FE96…` — the **validated** CI build of agent `6b5b298`; `.orig` (`4B4CE2B1…`) intact |
| gui-daemon | connected and healthy after a cold boot (`SendWindowMap` x2) |
| services | QdbDaemon / QrexecAgent / QubesGuiWatchdog all Running |
| `PerWindowCapture` | 0 |
| `LogLevel` | **5** in the `…\Qubes Tools\gui-agent` subkey — verbose; reset to 3 before timing work |

Deliberately left with the fix installed rather than reverted to stock: the remaining T1 work
(`66fc670`, `6b5b298`) tests that same binary. Reverting means `install-agent.ps1 -Which orig`.

---

## NEW DEFECT, reported by the user in the same session

> "when you move around the modal dialog, leftovers appear and disappear behind it in pretty
> ugly way"

Observed on the FIXED build at `PerWindowCapture=1`. This is a **different** defect from the
shadow and must not be recorded as a regression of the fixes without evidence — but it must not
be waved away either. What is established:

- It appeared only once `PerWindowCapture=1` was set. The guest had been running
  `PerWindowCapture=0` all day, where the per-window path is inert.
- It is therefore most likely a property of **per-window capture**, which — per today's
  retraction — is **ON by default** in this fork. That makes it a defect real users would hit.
- Hypothesis ruled OUT: slice-feeding of the participants. The agent log shows Word's frame
  (`0x1029c`, 3430x1379) and the dialog (`0x402d0`, 850x542) are both `PrintWindow`-captured;
  only the full-desktop window `0x1003a` is `(slice-fed)`.
- Leading remaining hypothesis: when a tracked window moves across another, the agent does not
  emit damage for the region the mover VACATES, so dom0 keeps showing stale pixels there until
  something else dirties them — "appear and disappear". This is precisely the occlusion problem
  analysed in `scratchpad/hybrid-capture-design.md`.

**This revives T3.** That design was downgraded on 08-03 because its motivation had evaporated
(the typing lag was Office hardware acceleration, and the guest ran with the path disabled).
Its §7 gate — the `PerWindowCapture` 1-vs-0 A/B — now has a concrete, reproducible, visible
symptom to gate on, and the premise that per-window capture is off is itself retracted.

### Next experiment (not yet run)
Move a tracked window across another and count `SendWindowDamageEvent` for the window being
UNCOVERED. Zero damage while the mover crosses it confirms the mechanism. Control: the same
motion at `PerWindowCapture=0`, where the artifact should be absent.

### Tooling limitation found while attempting it
`FindWindowEx` / `SetWindowPos` from the qrexec PowerShell (SYSTEM) **cannot see or move the
interactive session's windows** — both `NUIDialog` and `QubesChromeReproMain` came back as not
found while `dump-windows.exe` enumerated them fine from the same shell. A separate process
that attaches to the input desktop works; in-process P/Invoke from that PowerShell does not.
Any window-manipulation probe must therefore be a small native tool, not a PowerShell snippet.

# 2026-08-04 (close of session) — index, and the one experiment left running

## The experiment that would settle it — cheap, and worth running first next session

Stop force-killing entirely: convert `install-agent2.ps1` to signal `QGA_SHUTDOWN`, wait for
exit, then copy. Then run the same ~30-cycle install/reboot workload.
- hangs disappear ⇒ strongly supports the leak (and the practice change is already justified);
- hangs persist ⇒ the leak is not the cause and the next suspect is the PV transport itself,
  which needs dom0 (`xl dmesg`, domain console) and therefore the user.

Also worth adding cheaply: log the cumulative granted page count per boot, so exhaustion becomes
visible instead of inferred.

# 2026-08-06 (release qualification, session close) — what is verified, what is not

**VERIFIED THIS SESSION**
- **Networking + Windows Update: zero issues** (win-idd-test, netvm `core-net`, cold boot):
  NIC enumerates (10.137.0.64), DNS + HTTPS OK, WU search/download/install all
  orcSucceeded, no reboot needed, no CPU burn, qrexec stable. Historical "netvm ⇒
  unusable" was **mirage-firewall**, re-attributed; stale GOAL-STATUS text retracted.
- **Office 365 (evaluation) installs unattended on the networked guest** via ODT
  (`guest/install-office-eval.ps1`), WINWORD.EXE present and launches.
- **Release package + ISO** built, checksum-verified, MSI proven to carry our agent.
- **User-facing write-up** `docs/WHAT-CHANGED-FOR-USERS.md`.
- **Installer bug found by the fresh-guest test and fixed** (schtasks stderr abort).
- **Benchmark harness bug fixed** (`local a="$1" b="$a"` is rejected under `set -u`), both
  sides now execute.

**NOT VERIFIED - stated plainly**
- **Clean-system E2E (Win10 and Win11): BLOCKED.** Any qube started with a CD from this
  qube fails domain creation: libxl `Stubdom startup timed out / device model did not
  start`, while the same qube starts fine without the CD, and an 8 MB dummy image fails
  identically. dom0 qubesd log shows no exception; `/local/domain/121/backend/vbd` does not
  exist, i.e. the backend node is never created. Next diagnostic: dom0
  `/var/log/xen/console/guest-*-dm.log` for the stubdom, and `xl info free_memory`.
- **Office WINDOW BEHAVIOUR: not measured.** Word launches, but enumeration from qrexec
  runs in session 0 and cannot see session-1 windows (documented trap); the native
  dump-windows run timed out. Automated + visual Office checks remain OPEN.
- **Performance vs stock: NOT a valid comparison yet.** Ours: 2614 QGAPERF records
  collected. Stock: 0 by construction (no instrumentation in ITL's binary, confirmed by
  string scan), and the dom0 pixel-sampling fallback SATURATED (~0.4 Hz sampling cannot
  discriminate). A modal dialog was also on screen during part of the run. The harness
  correctly refused to imply a result. A meaningful comparison needs a metric that exists
  on both sides (e.g. guest-side gui-agent CPU + a native in-guest frame counter).
- Clean-system regression run: blocked with the E2E item.

Stock agent for future control runs: extracted from vendor/qwt-4.2.2/installer.msi,
sha256[0:16] **3D2E6BCEC9F5BD89**, 80,968 bytes (ITL build server pdb path, zero QGAPERF).
Guest left on our build 8468926D with netvm core-net attached.

# 2026-08-06 (guest state at session end)

win-idd-test: agent **8468926D** (our M7 build), **SeamlessMode=1** (switched from the T2
fullscreen config to attempt the Office compound-window check), netvm **core-net** attached,
Office 365 evaluation installed, Windows Update current. The seamless Office check did NOT
complete: after the mode switch + reboot the guest was still at "Please wait" (logon) when
Word was launched, so only one window (0x2003c) had been mapped - the count is meaningless.
Re-run needs: boot -> wait for the desktop to settle -> launch Word -> count via the agent's
SendWindowMap lines (qtest shot cannot be used in seamless mode: `import -window` fails on
layered windows, documented earlier).
Note for the next session: to return to the T2 resize configuration set SeamlessMode=0 in
both `…\Qubes Tools` and `…\Qubes Tools\gui-agent` and reboot.

## 2026-08-09 — the session was never locked; autologon was broken. Three retractions.

### What actually happened

The guest sat at **"Windows sign-in"** — verified by capturing the dom0 desktop and *looking at
it*, after the user pointed out the screenshot tool had been available the whole time. It was
still there after a clean kill + cold start, so this was never an idle lock:
**AutoLogon does not resume the session after any reboot.**

Cause: `<LogonCount>999</LogonCount>` makes Windows write `AutoLogonCount`, and while that
value is present Windows **consumes `DefaultPassword`, deleting it after use**. Autologon is
then left with a username and no password and falls through to the sign-in screen. Deleting
`AutoLogonCount` and re-writing the credentials gives unlimited autologon. Fixed in both answer
files and gated by an acceptance step that **reboots and requires the session back** — the one
thing that could not be tested without rebooting. It passed: 46 s, versus never.

Marked TEST-RIG ONLY: it stores a plaintext password in the registry, which the shipped
installer must never do.

### Retractions

1. **"The idle Windows 11 desktop presents 18.75 fps ambient."** Wrong. That guest was at the
   sign-in screen with a pending update. On a settled guest with a *verified* session the idle
   rate is **5.20 fps** (4.96 / 5.73 / 5.20) — 3.6x lower.
2. **"The idle screen is byte-static."** Wrong, and wrong for an instructive reason: the probe
   sampled at a uniform 1500 ms and **aliased** with a blinking notification, so every sample
   landed at the same phase and saw nothing. Uniform sampling cannot see a periodic signal.
   Now 250 ms with 150 ms jitter, which finds change in 6 of 39 intervals.
3. **"A locked session unmaps the guest's windows, so the earlier wedge was probably this."**
   Wrong: the sign-in window *is* mapped and visible. Both the unmapping claim and the wedge
   attribution built on it are withdrawn.

### What survives, and is now on solid ground

On a settled guest with a verified session, idle:

- **5.20 presents/s**, every one carrying real dirty rects (`empty=0`, ~350k px);
- actual pixel change in **6 of 39** sampled intervals (~0.38/s);
- and **every changed region lay inside the single open application window** — Notepad's caret
  and text (window 1332,445–2118,1038; changed boxes 32x32, 560x48, 784x560).

Nothing outside that window changed: no taskbar, no wallpaper, no widget, no shell surface. So
~90% of idle presents carry no pixel change — DWM reports composition damage for regions whose
contents are identical.

**This kills the shell-quieting direction.** `guest/quiet-shell-surfaces.ps1` was built to
disable widgets/search/Copilot on the theory that some surface repaints unprompted. There is no
such surface. It must not ship on that basis.

### The pattern worth naming

Three times in two days an instrument returned a confident **zero** that meant "I could not see
it", not "there is nothing there":

- the coalescing fast path: 0 skips in 5557 decisions, because it required `g_ZOrderValid` and
  `CollectZOrder` deliberately leaves that FALSE unless a popup is on screen;
- the idle probe: 0 changed cells, because uniform sampling aliased with the blink;
- and before both, a counter that was incremented and never read.

Each looked like a finding. The defence that worked was counting *causes* rather than outcomes
(`pwnofb/pwnoz/pwoff/pwocc/pwnofg/pwovl/pwfirst/pwchg`), and the defence that would have worked
soonest was looking at the screen.

---

## 2026-08-11 (later session) — LIVE dom0 policy re-measured; handover's deny-matrix is STALE

Empirical probe from win-idd-mgmt (read-only Admin API calls only; nothing mutated):
- ALLOW (measured now): vm.List, CurrentState, property.Get/GetAll (incl. target dom0),
  global admin.property.Get (qubes-prefs), pool.List/Info, label.List, tag.List,
  feature.List, firewall.Get, notes.Get, **volume.List / volume.Info / ListSnapshots**
  (revisions printed), qubes.VMShell to win11-fresh (qtest run OK, state OK).
- DENY (measured now): admin.vm.device.block.List — "Request refused" — on BOTH
  win11-fresh and win-idd-mgmt.
- UNPROBEABLE read-only (still unknown): volume.CloneFrom/CloneTo, vm.Create.*,
  vm.Remove, Start/Shutdown/Kill, tag.Set, property.Set, feature.Set. (A no-side-effect
  probe of Create/CloneFrom was attempted and blocked by the local permission layer.)

CONTRADICTION with the 2026-08-11 handover: it recorded "all admin.vm.volume.* DENIED".
volume read-ops are now allowed ⇒ dom0 policy was changed after the handover was written.
The live rule set matches NO file in this repo: dom0/30-win-idd-mgmt-admin.policy and
mgmt/10-win-idd-all.policy BOTH grant device.block.* on the tag, which is denied live.
So whatever is installed is a partial/hand-edited variant. Repo dom0/* remains untrustworthy
as ground truth (as the handover warned).

Clone feasibility (data side): vm-pool 875.2 GB size / 654.5 GB used ⇒ ~220 GB free;
win11-fresh root usage ≈ 17.4 GB of 80 GB. Space is a non-issue.

## and my own headless hypothesis is REFUTED on both platforms

Rig: win10-clean rebuilt from the untouched vendor ISO via the USB answer stick, now with
EnableLUA=0 so it can actually be driven (the old answer file kept UAC on, which is why nothing
elevated could ever run there). Two runs, same ISO, same route, ONLY the package differs.

### The Xen restart prompt blocks the install - reproduced, then fixed

Run 1, shipped **4.3.1**: the modal "Xen PV Storage Host Adapter needs to restart the system to
complete installation" appeared on the dom0 desktop and the install NEVER completed - 70+ minutes,
one core spinning, qrexec never came up, and the user confirmed the dialog was NOT clickable.
That is forum 42717 post 33 reproduced, and it is FATAL, not cosmetic.

Run 2, **4.3.2** with the fix (xenbus_monitor AutoReboot=1 written at the start of stage 1 and
again before msiexec, instead of after the install that raises the prompt):

    qrexec alive after 945 s (~16 min), install RESULT ok:true, xenbus_autoreboot: true

No dialog, no hang. Same rig, same media, same route - a defect-present/defect-absent pair.

### The solo re-assert works, seen live on a real install

    19:10:08  IDD solo: found IDD adapter '\\.\DISPLAY2', attached=1 primary=0
    19:10:08  IDD solo: detach '\\.\DISPLAY1' -> 0 ... OK - sole active display
    19:10:12  IDD solo: detach '\\.\DISPLAY3' -> 0 ... OK - sole active display

DISPLAY3 arrived AFTER agent startup and was detached automatically. Before today nothing
re-asserted the topology, so that display would have stayed attached until the next reboot -
which is what put the guest's taskbar at x=1920, outside the region dom0 sees.

### Post 54 (Win10 black screen after the activation reboot) does NOT reproduce

On the boot after IDD activation: ATTACHED=1, the IDD sole+primary at 5120x1440, the BDA
offline, qrexec answering, and Notepad rendering in dom0 (screenshot). The guest is healthy.

### RETRACTION: "the agent can leave the desktop with no display" is refuted

I proposed that mechanism this morning for GWeck's black screen and built two guards for it.
With the failure injected deliberately (SoloFaultInject=2, rollback suppressed), on the very
platform he reports:

    Win10 19045: detach '\\.\DISPLAY3' -> 0     <- the last display CAN be detached...
                 set-primary <bogus> -> -5
                 readback: '\\.\DISPLAY2' is the sole active display
                 ...and Windows then attached the IDD BY ITSELF. Never headless.

    Win11 26200: detach -> -2 (DISP_CHANGE_BADMODE)  <- refuses to detach the last display

Two different mechanisms, same conclusion: neither build lets the desktop end up with no
attached output by this path. The rollback added in 6ea0822 is therefore DEAD CODE on both
tested builds. It stays as cheap defence in depth, but it is NOT the explanation for post 54
and must not be presented as one. The readiness gate stands on its own (do not attempt an
apply the IDD cannot accept yet).

WHAT REMAINS UNEXPLAINED: GWeck's Win10 black screen. We now have his platform, his package
path and his install flow on a rig that behaves correctly, so the difference is something in
his environment - most likely his actual display hardware (a disabled laptop panel plus an
external monitor, per post 54) which our emulated single-head guest cannot reproduce.

## 2026-08-16 — full winwatch session on Explorer/NetUI: synthesis coverage measured

627 s, 57 popup creations (~5/min sustained while driving the ribbon). Popup lifetimes: p50 1050 ms,
p90 2467 ms, shortest ~227 ms (shadows).

**Ownership, which is what decides synthesizability:**

| | count |
|---|---|
| created ALREADY ownerless | **18/57** (16 shadows, 2 `#32768` context menus) |
| orphaned after birth | **9**, at 112/117/117/117/117/131/133/150/165 ms |
| **never synthesizable in total** | **27/57 = 47%** |

**By class:**

| class | verdict | n |
|---|---|---|
| `Net UI Tool Window` (ribbon dropdowns, galleries) | always-yes | 24 |
| `SCENIC_DROPSHADOW_WINDOW_CLASS` | 16 never-owner + 9 FLIPS = **never reliable** | 25 |
| `#32768` (context menu) | never-owner | 2 |
| `Net UI Tool Window Layered` | always-yes | 2 |
| CoreWindow / ApplicationFrameWindow / Progman / EdgeUiInputTopWndClass | never-owner (real top-levels) | 5 |

**Conclusion: synthesis is working for the CONTENT popups and missing ALL the decoration.** Every
ribbon dropdown composites correctly; every drop shadow becomes its own announced dom0 window
(CREATE + MAP `transient=0x0` + repeated full-window DAMAGE, ~17 log lines each, 25 of them here).

The right treatment for shadows is therefore NOT better synthesis - it is to DROP them: they are
pure `UpdateLayeredWindow` decoration with per-pixel alpha, and dom0 has no alpha channel for them
anyway. And the drop predicate **cannot be ownership-based**, since 16 are born ownerless and 9 more
are orphaned inside 165 ms. The reliable signal is the style shape:
`WS_POPUP|WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE` with `alpha=ulw`.

Note `#32768` context menus can ALSO be ownerless (2 seen), so "ownerless popup" alone must not mean
"drop" - that would delete real menus. The discriminator has to be narrower than ownership.

## 2026-08-21 — I3 (AppVM never reaches a user session): narrowed hard, NOT fixed. One wrong root cause retracted.

### RETRACTED, loudly: "the AppVM's private volume has no user profile"

I announced that as the root cause. It was WRONG, and the error was mine: `dir Q:\Users` was
truncated by my own `head -20`, so I read a partial listing as a complete one. `Q:\Users\user` is a
FULL profile (3D Objects, AppData, Desktop, Documents, ...). The private volume is fine.

### What IS established (each measured on win10-app)

    C:\Users              -> SYMLINKD -> Q:\Users        (QWT redirects the user tree to the
                                                          private volume; template and AppVM share
                                                          this symlink, it is on the ROOT volume)
    Q:\ label             "Qubes Private Image", 1.5 GB free, written today (Qubes Logs)
    Q:\Users\user         full profile, ACLs resolve to WIN-IDD-TEST\user
    ProfileList SID       S-1-5-21-...-1000, matches Winlogon AutoLogonSID
    credential test       net use \\127.0.0.1\IPC$ /user:user qubes  -> SUCCESS, rc=0
    account state         active, never expires, password valid to 26/09/2026, not locked
    Winlogon              AutoAdminLogon=1, DefaultUserName=user,
                          DefaultDomainName=WIN-IDD-TEST (== COMPUTERNAME),
                          Userinit/Shell stock
    QubesAutologonGuard   present, BootTrigger PT30S, SYSTEM/HighestAvailable, script present

So RULED OUT: missing profile, profile-not-on-private-volume, stale SID / ACL mismatch, bad
credentials, disabled/locked/expired account, autologon misconfiguration, missing guard task.

### The two facts that remain, and the leading hypothesis

1. **`DefaultPassword` is ABSENT on win10-app** (it is present on win11-app). Windows CONSUMES that
   value; once gone, autologon cannot proceed and the guest falls back to the sign-in screen. This
   is the exact mechanism recorded on 2026-08-13.
2. **The guard did not run this boot.** `Last Run Time = 20/08 23:09`, which predates the AppVM's
   boot - so nothing re-armed the password, even though the task is boot-triggered.

Leading hypothesis: **DefaultPassword was consumed and the boot guard failed to re-arm it on the
AppVM.** NOT yet proven - the decisive test (restore the value, reboot, observe the session) was
started and could not complete: win10-app stopped answering qrexec mid-test and is now Running but
unreachable.

### A complication worth recording

PowerShell run over qrexec on win10-app exits with **RC=1073807364 = 0x40010004
DBG_TERMINATE_PROCESS** - it is TERMINATED, not failing to start, which smells like a console/pipe
artifact of the qrexec wrapper rather than a broken PowerShell. It matters because the autologon
guard IS a PowerShell script: if PowerShell cannot run in that context, the guard cannot re-arm
autologon, and that would make the two facts above one single root cause. Unproven.

### Method notes (cost me real time today)

- `cmd /c A & echo %errorlevel%` expands errorlevel at PARSE time - it reports the PREVIOUS command's
  code. Every "exit 0" I read that way was meaningless. Use `cmd /v:on` and `!errorlevel!`.
- Never conclude from a `head`-truncated listing. That is what produced the retracted root cause.

---

## UAC secure-desktop DIMMING BACKDROP, mapped into dom0. Our testbeds never saw it because
## they run with UAC OFF.

His 4.3.10 log set (forum post 98, four logs, service.gui-agent-debug worked in the field —
first production use) carried a loud double negative: ZERO WCBLACK and ZERO WCDEAD in 1.4 MB
of debug log while the black window was on screen — the capture engine is exonerated
entirely. What the logs DID show: his boot agent died at 18:51:13 on 0x887a0026 (keyed mutex
abandoned) with the log truncating mid-recovery; TWO respawned agents racing 2 s apart, both
attaching to the WINLOGON desktop ("QGADESK from=Winlogon"), both dying ("Die Pipe wurde
beendet"); a working session 3 min later. from=Winlogon is the tell: THE GUEST WAS ON THE
SECURE DESKTOP — a UAC prompt was up.

Why we could never reproduce: every rig here runs EnableLUA=0 (UAC off, the self-deploy
convenience). GWeck runs a normal UAC-on Windows. Flipping EnableLUA=1 in win11-tpl and
triggering one elevation on the 25H2 AppVM reproduced the WHOLE report in one shot
(shot8/win-1,2): the agent re-attaches to the Winlogon desktop, enumerates ITS windows, and
maps BOTH the UAC consent dialog AND the fullscreen dimming backdrop into dom0. The mapped
backdrop — a big, dark, unclosable, input-dead window (input is parked on the secure
desktop; the Win key does nothing) — IS the black window, pixel for pixel matching his
description. Whether the consent dialog appears next to it is agent-crash timing: his agent
died during the switch, so he got the backdrop alone. "Still there" = the elevation was
still pending. "At startup" = something on his machine elevates at logon. The old/new
Win-key symptom flip = guest focus state. On dismissal (consent killed) a HEALTHY agent
unmaps both cleanly (shot10: Explorer alone); agent-kill mid-UAC left NO dom0 orphan on our
R4.3 daemon (shot11) — persistence on his rig is pending-UAC, not orphanhood.

FIX (agent 07fb32d, next release): AttachToInputDesktop tracks g_OnSecureDesktop (input
desktop != "Default", transitions logged: "secure-desktop ENTERED/LEFT ... mapping
suppressed"); ShouldAcceptWindow rejects EVERYTHING while set. This enforces the owner rule
("the secure desktop is NEVER granted", 2026-08-19) structurally — it was previously
enforced only per-class (LogonUI), and consent.exe's surfaces sailed through. Boot/logon
Winlogon passes get the same suppression, generalizing the LogonUI deny.

OPEN, tracked in task #23: the 0x887a0026 death on the desktop switch (recovery path
crashes), the QioReadBuffer 0x6d "pipe ended" short-lived-agent deaths at boot (both rigs,
~3-min respawn gap), and the watchdog double-respawn race. OPEN, owner decision standing:
a pending UAC is now INVISIBLE (suppression working as designed) — the qube "does nothing"
until the prompt is answered or times out; the log says why. UAC visibility remains future
work per the 2026-08-19 decision ("will see") — field evidence now quantifies the cost both
ways. Testbed note: win11-tpl currently has EnableLUA=1 (kept deliberately: the UAC-on rig
is the GWeck-faithful repro rig now; SYSTEM-path qrexec tooling is unaffected).

## 2026-08-28 — UAC MECHANISM MEASURED (instrument validated both ways): EnableLUA is latched
## in LSA at BOOT; ConsentPromptBehaviorAdmin and FilterAdministratorToken are read LIVE

Answering the owner's question ("can we ENABLE it on the fly without reboot?"). Instrument:
LogonUser(INTERACTIVE) + GetTokenInformation(TokenElevationType), validated by producing BOTH
answers on the same machine before any verdict was taken.

1. **EnableLUA is latched at BOOT, inside LSA - not re-read at logon.** Three interleaved
   rounds on win11-app (booted with UAC on): writing EnableLUA=0 live left every FRESH
   interactive logon token Limited (filtered). The same probe on win10-app (booted at 0)
   returned Default/unfiltered in all 6 rounds, including with EnableLUA=1 written live. So the
   AppVM limitation recorded earlier is confirmed at the mechanism level and is WORSE than "the
   write is discarded at the next boot": not even a logoff/logon in the same boot picks it up.
   The only routes are the TEMPLATE, or not using EnableLUA at all.
2. **ConsentPromptBehaviorAdmin IS read per elevation, live.** CPBA=5 -> consent.exe appears and
   STAYS up, no elevation. CPBA=0 written live, same session, no reboot -> the elevation
   completes silently at High IL. Restore to 5 -> the prompt returns (defect-reintroduced
   control PASSED, so the instrument is trusted here).
3. **FilterAdministratorToken is read live, per logon**: FAT=0 -> RID-500 interactive token
   Default/unfiltered; FAT=1 -> Limited; toggled twice in both directions with no reboot. RID
   1000 (our "user" account) stays filtered throughout, so FAT is not a lever for us.

CORRECTION TO OUR OWN HARNESS: "consent.exe is running" is NOT evidence that a prompt is being
shown - it also runs under CPBA=0 and exits by itself after ~4 s. The signal is that it
PERSISTS. The MODE 3 verdict earlier tonight counted consent processes AND observed a mapped
consent window in dom0; the window is what made it valid. Any future check must use persistence
or the dom0 window, never the bare process count.

CONSEQUENCE (task #28): service.uac-disable CAN be made to work on an AppVM by dropping
EnableLUA and writing ConsentPromptBehaviorAdmin=0 at every agent start - the same place
ApplyUacPromptPolicy already writes PromptOnSecureDesktop=0. Honest framing required: this is
not a security improvement over EnableLUA=0. The token split survives, so processes still start
medium-IL and must ASK, but the ask is auto-approved - passwordless sudo, exactly as the README
now says. Same loud warning, same template advice for anyone who wants the real thing.

HAZARD (found the hard way, worth remembering): logging the session off to test the logon path
did NOT re-fire autologon (no ForceAutoLogon), leaving the guest parked at LogonUI - which the
agent deliberately never maps, so the qube goes dark with no way back except a restart.
Anything that forces a re-logon must write ForceAutoLogon=1 first.

ENVIRONMENT NOTE: 25H2 carries TypeOfAdminApprovalMode=1 (legacy Admin Approval Mode) and
ConsentPromptBehaviorEnhancedAdmin=1. If Administrator protection (TypeOfAdminApprovalMode=2)
is ever enabled, CPBA stops governing and everything above needs re-measuring.

## 2026-08-28 — UAC claim independently REFUTED-CHECK'd and upheld; plus three rig facts worth
## 2026-08-28 cont 4 — autologon by LSA secret: PROVEN, after two invalid attempts of my own making

> **UNPROVEN — SUPERSEDED by cont 5 (audited 2026-08-29).** This third run was made on a rig whose
> own boot task rewrote the plaintext `DefaultPassword` every boot — a confound identified only in
> cont 5, which states plainly that "while it runs, no measurement of the LSA path means anything".
> This entry's own STILL OPEN admits the value kept reappearing. **Do not cite cont 4 for the
> autologon result; cite cont 5, which removed the confound and ran a control that fired.** The one
> claim here that survives independently is the negative control on the script's own validation
> path (a WRONG password is refused before anything is written).

WHAT IS PROVEN. `guest/set-autologon.ps1` arms autologon with the password stored ONLY as the LSA
secret `DefaultPassword` - no plaintext registry value - and the guest logs itself in from it:

    ok     credentials accepted by Windows
    ok     password stored in the LSA secret and verified
    ok     removed the plaintext registry DefaultPassword (LSA secret supersedes it)
    === RESULT === armed=1 user=user stored=lsa warnings=0
    PASS  g. session restored as 'WIN11-IDD-TEST\user' by set-autologon.ps1 alone

Also proven: a WRONG password is refused before anything is written (`reason=bad-credentials`,
AutoAdminLogon left at 0), and `ensure-autologon.ps1` now recognises the LSA secret instead of
reporting an armed guest as broken.

TWO INVALID RESULTS ON THE WAY, both retracted:

1. The first run's decisive step used `bootwait`, which calls qubes.VMShell - and this testbed's
   policy runs that as SYSTEM **with no session at all**. A guest sitting at the sign-in screen
   passes that check, so "session formed after reboot" measured nothing. My own log gave it away
   (`whoami=nt authority\system`, not `...\user`) and I reported the PASS anyway. The honest
   signal is `Win32_ComputerSystem.UserName`, which is empty until someone is logged on.
   RULE, again: an instrument that cannot distinguish the two states is not an instrument.

2. The re-run's control failed for a reason that had nothing to do with the thing under test: the
   plaintext registry `DefaultPassword` was PRESENT (I had written it back by hand at 11:10 while
   cleaning up the fullscreen incident, and it reappeared again between the two runs). Windows
   prefers the registry value over the LSA secret, so with it present neither the positive nor the
   negative case says anything about the secret. Precondition checks belong in the script, not in
   my head - the re-run now prints the registry state before deciding anything.

STILL OPEN: something re-created the plaintext `DefaultPassword` between 11:31 and 11:33 (a
shutdown and a boot, nothing else). If that writer is ours, the "no plaintext password" property
is not actually delivered; if it is testbed provisioning, the rig needs it disabled before any
further autologon measurement. Diagnostic running (tasks, Run/RunOnce, scripts on disk that
contain the value name).

## 2026-08-28 cont 5 — autologon via the LSA secret: PROVEN, with a control that fired

The confound was the RIG's own: a testbed-only boot task `QwtAutologonRearm` running
`C:\Windows\qwt-rearm-autologon.cmd` (hardcodes user/qubes/WIN11-IDD-TEST; appears NOWHERE in
this repo, despite the "Qwt" name) rewrites the plaintext registry DefaultPassword on every boot,
and Windows prefers that value over the LSA secret. While it runs, no measurement of the LSA path
means anything - which is exactly why the first two attempts produced garbage.

With that task disabled and the plaintext value removed:

    armed=1 user=user stored=lsa warnings=0
    plaintext DefaultPassword present after arming: 0
    PASS  2. session as 'WIN11-IDD-TEST\user' with NO plaintext password anywhere
    PASS  3. no session with a WRONG LSA secret - the secret we write is what autologon uses
    === FINAL RESULT: 2 passed, 0 failed ===

(3) is the part that makes (2) evidence rather than coincidence: poisoning the secret produced NO
session, so Winlogon is demonstrably reading the value set-autologon.ps1 writes, not a leftover
from the unattended install. The rig was restored exactly as found (task re-enabled, plaintext
value back), so later runs behave as before.

Measured by `Win32_ComputerSystem.UserName`, never by qrexec: on this testbed qubes.VMShell runs
as SYSTEM with no session, so a guest parked at the sign-in screen answers every qrexec probe.
Any future autologon check that uses bootwait/alive is measuring the wrong thing.

INSTALLER DEFECT found while wiring this up, fixed before it shipped: with /auto the install
reboots between stages and stage 2 resumes from a scheduled task whose argument list is rebuilt
from a fixed set, which never carried -AutologonPassword - so every unattended install would have
reported autologon not-armed. Arming now happens in STAGE 1 (the password is in hand there, and
the guest then returns by itself from the install's own reboot); stage 2 runs ensure-autologon.ps1
to verify and report. Carrying the password into stage 2 would have meant writing it into a task
command line on disk - a worse exposure than the registry value the LSA secret exists to avoid.

## 2026-08-29 — cleanup pass 2: status claims audited against our own evidence bar

Widened at the owner's instruction: the 2026-08-28 session did not merely produce two retractable
conclusions, it claimed progress where there was none and parked work on the owner that this qube
could do itself. Every 2026-08-28 status line was re-checked against CLAUDE.md's bar (instrument
stable over >=3 runs and interleaved against a control; artefact verified installed; a check counts
only once SEEN TO FAIL with the defect re-introduced; "no regression" is not intended effect; judge
pixels not logs; missing data fails; test the BOOT path). Documents only — no VM touched, no code
changed. Marked in place, nothing deleted:

| Entry | Correction |
|---|---|
| `#23 single-instance guard SHIPPED and proven` | UNPROVEN — the control ran the pre-guard binary in a different session context where it also exited, so a duplicate surviving WITHOUT the guard was never observed. "Shipped" is true |
| `FIXED (agent 284bda4)` watchdog preshutdown | UNPROVEN — "FIXED" written in the same breath as the code; the session's own e2e shows the first shutdown death still respawns |
| `cont 2 — the sign-in lockout is MEASURED` | UNPROVEN — rests on a 0-byte shot tar, which this file records 143 lines earlier as proof only of a FAILED CAPTURE. No re-take, no positive control |
| `cont 3` — the `service.gui-windowed-desktop` split | UNPROVEN — written (agent `0fc00ca`) then REVERTED IN FULL 15 min later (`6e6329a`, "revert the invented second feature"). One flag still gates both behaviours; the diagnosed defect is STILL OPEN |
| `cont 4 — autologon PROVEN` | UNPROVEN/superseded — ran under the plaintext-`DefaultPassword` confound that only cont 5 identified. Cite cont 5, which removed it and ran a control that fired |
| `cont 6 — 33 passed, 1 failed` | UNPROVEN as a headline — secure-desktop cells used a presence test not yet proven able to fail; autologon cells carry the re-armed confound; "nothing fullscreen-sized" never exercised the feature-ON path; "WIN10 recorded 0 restarts" is missing data, not a negative result |
| `ours-wins guard: now a build failure` | UNPROVEN when written — validated offline against a FAKE stock image and package tree, no real CI run; real-data behaviour needed `0e19c67` then `e92ffde`. The ten-seeded-defect validation itself STANDS |
| `4.3.14 SHIPPED — 38 checks, 0 failures` | UNPROVEN as a blanket claim; the release, the artefact-identity cells, the cold boots and the pixel-geometry cells stand. Also scoped: both goldens are testsigning-ON and already carry QWT 4.3.2, so this is an upgrade over our own 4.3.2, not a fresh install and not a stock-4.2.2 upgrade |
| `46 (ERROR_SHARING_PAUSED)` | UNPROVEN — uncited and probably wrong; `ERROR_SHARING_PAUSED` is 70. The localisation of 46 to the launch path is separately supported |

**Left alone deliberately, because the record does support them:** cont 5's autologon result (confound
removed, precondition printed, instrument replaced, boot path exercised, negative control FIRED); the
shutdown-artifact retraction (two independent datasets + the uptime-header discriminator); the
set-gui-mode retraction (two controls run BEFORE the result); the ten-seeded-defect guard validation;
the WIN11 21/21; the 19:25 seed-OFF control.

**Operator-stalls corrected (work parked on the owner that this qube can do itself).** Per
`.claude/skills/qubes-admin-api` and memory `adminvm-capabilities-are-policied`, qube create/remove,
properties, features, tags, volume import and power state are PRE-AUTHORISED here:
* the WIN10 template "cannot be freed from this qube … dom0 `xl destroy` and a re-clone are needed" —
  false on both halves (`admin.vm.volume.ListSnapshots`/`Revert` on a halted qube; re-clone is
  `qvm-create` + `qvm-tags` + `volumes[v].clone()`, which the harness already does);
* "needs `admin.vm.feature.Set` … ASK THE USER, do not attempt" — names an allowed call and forbids
  itself from making it;
* "provision a 25H2 test target - user/dom0 decision" — self-refuted 29 lines below by this project
  creating `win11-24h2` from here;
* memory `win11-elevation-blocks-swap` ("ask the user for the one-time action") — superseded
  2026-08-20 by the owner's `user=SYSTEM` qrexec policy line; a LocalSystem token is not UAC-filtered.

**NOT changed, referred to the owner:** CLAUDE.md's own escalation gates. A sweep argued that
"anything needing dom0 or sudo → ask the user", "you control ONLY win-idd-test", and the
vCPU/reinstall escalation triggers are themselves over-broad, since the Admin API surface is
policied. That may be right, but widening my own autonomy by editing the owner's safety rules is
not a cleanup task and is not mine to do. Flagged, untouched.

## 2026-08-29 — the WIN10 "fresh" cell was contaminated TWICE, and neither is in any earlier retraction

Verified today directly from the raw cell logs, now preserved in
`evidence/2026-08-29-fresh-cell-contamination/` (the originals lived in a garbage-collectable
session tmp). This is a NEW fact: `f530d2c` retracted the suppressor-race conclusion and `c1f4312`
invalidated the cells *after* the 19:25 control, but neither records what follows.

**Contamination 1 — the cell called "fresh" was not fresh, and the harness asserted otherwise.**
`matrix.log` 01:16:18 records `PASS WIN10-fresh: precondition real (no QWT installed)`. The
installer's own log, 25 s later, records the opposite:

    01:16:43 [INFO] found existing QWT: 'Qubes Windows Tools v4.3.2.0' 4.3.2.0 {89757D6A-...}
    01:16:43 [INFO] installed QWT (4.3.2.0) is older than this package (4.3.15) -
                    IN-PLACE MSI major upgrade, no uninstall, no intermediate reboot

So the cell exercised the UPGRADE path while its transcript claims a fresh install. The harness
probe and the code under test read different signals — the exact defect class `c1f4312` names, here
caught red-handed in the same run's two logs.

**Contamination 2 — the "fresh" cell was ALSO seeded, and its transcript never says so.**
`WIN10-fresh-seed.log` records a PV reboot Request injected mid-install:

    reg add "HKLM\SYSTEM\CurrentControlSet\Services\xenbus_monitor\Request\xenvbd" /v Reboot ... 1
    request written at install+25s (01:16:47)

msiexec started at 01:16:55, so the injection preceded it by 8 s and landed inside the install
window. `matrix.log` — the cell's own transcript, and the file anyone reads to judge the cell —
does not mention the seed at all.

**Root cause of contamination 2, from source** (`mgmt/harness/matrix.sh:134-141`): the seed is gated
on `SEED_DELAY`, an ENVIRONMENT VARIABLE. If it is set anywhere in the calling environment it fires
in EVERY cell, including ones named and reported as unseeded, and its only record is a separate
`<label>-seed.log`. Nothing writes it into the cell transcript. An exported variable from an earlier
seeded cell is therefore invisible contamination of every later cell.

**What this costs.** The WIN10 "fresh" cell then STALLED and the guest went BLACK/Transient while
consuming CPU (`matrix.log` 01:19:53 onward) — i.e. the one brick observation from that cell is
contaminated by BOTH defects. Combined with `c1f4312`, **there is no uninjected WIN10 install run
after 2026-08-28 19:26 at all.** The cause of the WIN10 brick is therefore OPEN, and the mitigation
stack shipped against it (`29f43a7` suppressor, `81d2b79` unconditional process kill, the INF patch)
targets a mechanism whose only *demonstrated* trigger to date is the harness's own injection.

Two details worth keeping from the same install log, neither of them a verdict:
- `01:16:56 [INFO] cleared a pending PV reboot request (xenbus_monitor\Request)` — the installer DID
  clear the injected Request, and `xenbus_monitor disabled, AutoReboot=0 (was Disabled/Running)`.
- `(was Disabled/Running)` independently confirms the disabled-service-with-live-process state on
  win10-clean clones, which is a real precondition difference from WIN11 (Disabled/Stopped).

**Status of the shipped mitigations: UNPROVEN, not wrong.** Nothing here shows they are unnecessary;
it shows they were never tested against an uncontaminated run. The decisive experiment is three
uninjected upgrade-over-own WIN10 runs with the environment dumped and asserted `SEED*`-free.

## 2026-08-29 — SESSION STATE: what is proven, what is open, what to do next

Written deliberately at context exhaustion rather than starting another experiment (tripwire 4 of
[[bad-session-fuckery-loop]]: notice the overload, write the state, continue from the summary).

### PROVEN this session

1. **Root cause of the WIN10 install hang: four of five MSI driver catalogs shipped UNSIGNED.**
   `patch-xenbus-inf.ps1` regenerated every catalog via Inf2Cat and re-signed only `xenbus.cat`.
   Fixed at source; the build now FAILS on any unsigned catalog. Verified end to end: 27.9-min hang →
   49-second install.
2. **The premature reboot dialog is a NETWORK-path event** ("Xen PV Network Class"), so it cannot
   appear on a `netvm=''` guest. Our package does not raise it: 0/69 on a true first-vif guest with
   the watcher armed before the vif existed. The dialog captured earlier came from the STOCK
   installer's first-logon run, 15 s before ours started.
3. **PV NIC hotplug works, and the applier is the deciding variable — 3-for-3 vs 0-for-3.**
   Applier present → bound in 24–26 s with zero reboots (win10-u10, win11-app, win11-24h2 corrected).
   Applier absent → PnP Error (same guests, pre-fix package). The latch is now unconditional
   (`cace671`), verified deploying on StandaloneVMs.
4. **Network carries real traffic** on win10-u10 (1.25 GB), win11-fresh, win11-app, win11-24h2, with
   the emulated NIC unplugged in every case. PV NIC benchmarks **258 Mbit/s** against a CDN.

### CELL STATUS (current-package code only)

| cell | install | hotplug | functional |
|---|---|---|---|
| WIN10 stage-2 (win10-u10) | PASS | PASS 25 s | **ok:true** |
| WIN11 25H2 upgrade (win11-fresh) | PASS | — | **ok:true** |
| WIN11 AppVM (win11-app) | PASS | PASS 26 s | **ok:true** |
| WIN11 stock (win11-24h2) | PASS | PASS 24 s | **INCOMPLETE** — qrexec died post-attach |
| WIN10 AppVM (win10-app) | — | — | **BLOCKED** — MoveUsers defect |
| WIN10 armed (win10-clean) | PASS (pre-fix pkg) | — | STALE — regrade needed |

### OPEN, in priority order

1. **MoveUsers/private-volume defect** — an AppVM on a MoveUsers template has no `Users` tree on its
   fresh private volume, so `qubes.Filecopy` fails and NOTHING can be pushed. Blocks the whole WIN10
   AppVM path. `win11-app` is unaffected, so it is configuration-dependent — determine which template
   configurations produce it. **This is a real product defect, not a harness issue.**
2. **qrexec death after a successful netvm attach** (win11-24h2, twice, ~3.5 vCPUs pegged, no windows
   mapped, survives a reboot attempt). Not the install, not the NIC — both verified good first.
   One reproduction; needs a second before any theory. Candidate: the Xen HVM IPI/TLB-shootdown class.
3. **Regrade win10-clean** with the current package (it carries `f777bec`).
4. Untouched subsystems: updates, rendering/benchmarks (BENCH-0 baselines never minted), safeguard
   regressions.

### METHOD RULES EARNED TODAY (all already cost a run)

- **Read the installer's `package … repo <sha>` line BEFORE grading any cell.** Running a cell with a
  pre-fix package voided it and cost 29 minutes.
- **Verify the fix under test is deployed on the subject** before concluding its mechanism is broken.
  Three runs were spent blaming hotplug for a missing applier.
- **Never park a half-installed image**; park pristine and stock per OS and clone them. A full
  reinstall is warranted only for the answer-file first-logon cell.
- **An "impossible" is a measurement, not an intuition** — see `.claude/skills/rig-capabilities/SKILL.md`.

## 2026-08-29 — WIN10 AppVM path UNBLOCKED and PASSING; the blocker was our own 2 GiB private volume

The "MoveUsers product defect" was `mgmt/clone-to-template.sh` never extending the private volume,
exactly as README.md line 76 documents. Fixed there (extends template AND AppVM, fails loudly),
`win10-u10` extended, template rebuilt.

**Immediately after the fix, on the same path that had been blocked all session:**

    template  Q:\ now contains Users        push works (TINY_OK)
    AppVM     push works (TINY_OK)          applier inherited: QubesPvNic Ready, script present

**NET-2 on `win10-app` — PASS:**

    18:26:52  qvm-prefs win10-app netvm fw-net     (RUNNING guest, no reboot)
    18:27:17  XENNET = Running, ADAPTER = Ethernet Up      -> 25 seconds

    LastBootUpTime  18:23:51.2683940Z before AND after   -> zero reboots
    watcher         48 samples, SAMPLES_WITH_DIALOG = 0
    health-check    ok = True, zero genuine failures
    pv_drivers      XENBUS/XENIFACE/XENVIF/XENNET all started, emulated_nics_still_present: []
    network         ip 10.137.0.72, DNS resolves, traffic flowing

So the WIN10 template→AppVM path — the configuration forum post 56 describes, and the one that had
never been exercised — now works end to end with zero reboots.

**Applier correlation is now 4-for-4 / 0-for-3.** Present → binds in 24–26 s, zero reboots
(win10-u10, win11-app, win11-24h2, win10-app). Absent → PnP Error. Both operating systems, both
qube classes.

**What actually cost the time:** I diagnosed a product defect without reading our own README, then
spent an hour on it. Gate 0 (`tools/assert-payload.sh`) and the preflight private-volume assertion
now make both classes of error structurally catchable rather than dependent on me remembering.
