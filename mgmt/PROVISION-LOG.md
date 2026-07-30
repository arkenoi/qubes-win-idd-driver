# PROVISION-LOG — win-idd-test provisioning

## 2026-07-30 — session start

### Preflight
- Tools present: qvm-* (core-admin-client 4.3.33), 7z, xorriso, curl, wget, git, gh, jq,
  rpm/rpm2cpio/cpio/rpmkeys, gpg, python3.14. MISSING: wimlib-imagex, genisoimage, aria2c,
  openssl (gpg used instead). No sudo (password required) — loop-device tricks unavailable.
- Network OK (netvm: fw-net). ~39 GB free on /home.
- `qvm-block --help` CRASHES (qvm_device.py argparse bug under Python 3.14:
  "action 'store_const' is not valid for positional arguments"). `qvm-device` also affected
  at the same spot when given `block` … to re-test; `qvm-device --help` itself works.
- Admin policy: initially several services refused; user fixed dom0 policy TWICE.
  Now verified working: admin.vm.List, admin.label.List, admin.vmclass.List, admin.Events,
  admin.vm.device.block.Available (self). Assign/Attached targeting SELF still refused —
  believed scoped to win-idd-test dest (untestable until the VM exists).
- local.WinScreenshot probe: rc=1, empty stderr — expected "no visible windows" error text
  did not appear but the call path answers (service reachable, no windows titled
  [win-idd-test] yet). Re-verify once VM has windows.

### QWT acquisition (post-QSB-091 method: dom0 RPM from R4.3 repo)
- Current doc (doc.qubes-os.org …/qubes-windows-tools.html) confirms: for Win10/11 use QWT
  4.2.2 from the **R4.3 dom0 repo**; no direct .exe/.msi download is published.
- Fetched https://yum.qubes-os.org/r4.3/current/dom0/fc41/rpm/qubes-windows-tools-4.2.2-1.fc41.noarch.rpm
  sha256=117c446c73270331d7b5397077c0ade42be0c0cb0a1e5e3320328b9a7333ba9b
- **Signature verified**: rpmkeys shows header+payload OK, key fpr
  f3fa3f99d6281f7b3a3e5e871c3d9b627f3fada4 = "Qubes OS Release 4.3 Signing Key",
  which gpg confirms is signed by the Qubes Master Signing Key
  (427F 11FD 0FAA 4B08 0123 F01C DDFA 1A3E 3687 9494 — matches published fpr on
  doc.qubes-os.org "verifying signatures" page).
  (rpmkeys --import into a private dbpath failed under SELinux in /home; direct
  `rpmkeys -Kv` against the system keyring worked because the release key fpr matched.)
- RPM contains one file: /usr/lib/qubes/qubes-windows-tools-4.2.2.1.fc41.iso (28 MB).
  ISO contains: iso-README.txt + qubes-tools-4.2.2.exe.
- Installer packaging identified (extracted + upstream cross-check
  QubesOS/qubes-installer-qubes-os-windows-tools vs2022/):
  **WiX v4 Burn bundle** (qubes-tools-4.2.2.exe) = vc_redist.x64.exe (/quiet) + installer.msi.
  Burn manifest: WixInternalUIBootstrapperApplication; bundle silent switches are standard
  Burn: `/quiet /norestart` (plus `/log`).
  MSI ProductCode {FB49475E-42A6-4EC6-8A94-F5F4BCEF7FC0}, version 4.2.2.0.
- **MSI feature IDs** (Package.wxs upstream): PvDriversCore, Core, Gui, MoveUsers,
  Autologon, PvDriversNetwork, PvDriversDisk. All AllowAbsent=yes.
  - Gui feature = user-mode gui-agent.exe + gui-watchdog.exe (QubesGuiWatchdog service)
    + registry (SeamlessMode=0 default, DisableCursor=1, LogLevel=3). **No WDDM video
    driver in 4.2.2 at all** — good: capture path constraint (DesktopImageInSystemMemory)
    is not endangered by the installer.
  - Desired selection for win-idd-test: ADDLOCAL=PvDriversCore,Core,Gui
    (skip MoveUsers — standalone; skip Autologon — autounattend already does autologon
    with known password; skip PvDriversNetwork — offline VM; skip PvDriversDisk — BSOD risk).
  - Extracted installer.msi (sha256 7049322128d1…) and vc_redist (sha256 1ad7988c…) for
    possible direct msiexec use: msiexec /i installer.msi /qn /norestart ADDLOCAL=… —
    pending verification that vc_redist must go first (it must: agent links CRT v143).

### Windows ISO acquisition
- quickget consumer path (Mido technique): SKU table resolves (Win10 PEID 2618,
  en-US SKU 16067) but final GetProductDownloadLinksBySku → **SentinelReject** every time
  (IP/heuristic block). Dead for automation.
- Evaluation Center Win10 pages: 404 / "End of Support" — Win10 eval retired post-EOL
  (Win10 EOL 2025-10-14). No automated Win10 source left on official domains.
- Evaluation Center Win11 Enterprise page still serves culture-tagged fwlinks that
  resolve (verified HEAD + ISO9660 CD001 magic via range fetch) to
  software-static.download.prss.microsoft.com:
  - **Win11 Enterprise LTSC 2024 eval** 26100.1742 (24H2-based) en-us, 5 112 850 432 B:
    fwlink linkid=2289029 → 26100.1742.240906-0331.ge_release_svc_refresh_CLIENT_LTSC_EVAL_x64FRE_en-us.iso
  - Win11 Enterprise 25H2 eval 26200.6584 (forbidden per CLAUDE.md, noted only for record).
- **USER DECISION**: proceed with Win11 Enterprise LTSC 2024 eval (24H2 base avoids the
  documented 25H2 double-window bug; official + ungated). Download in progress →
  ~/win-iso/win11-ltsc2024-en-us.iso
- Model note: session continues under Fable 5 (user /model switch mid-session).

### ISO decision revised (research workflow finding, independently re-verified)
- Research agent discovered the Win10 eval *blobs* outlive the eval *pages*:
  **Windows 10 Enterprise LTSC 2021 Evaluation** x64 en-us is live on the official CDN:
  https://software-static.download.prss.microsoft.com/pr/download/19044.1288.211006-0501.21h2_release_svc_refresh_CLIENT_LTSC_EVAL_x64FRE_en-us.iso
  (Content-Length 4898582528, ETag 0x064A148FFFE2246B1B091EF931AE559B74DC3A52C2E8B3832D659A5A221817D3,
  CD001 magic verified twice, WIM XML parsed over HTTP ranges:
  image 1 = "Windows 10 Enterprise LTSC 2021 Evaluation", build 19041.1288/21H2.)
- Blocker found & fixed: xorriso 1.5.8 here has NO UDF write support; removed `-udf` from
  build-unattended-iso.sh. Consequence: payload files must stay < 4 GiB → Win10 LTSC wim
  (3.97 GiB) fits, Win11 LTSC wim (4.3 GiB) does not.
- **USER DECISION (revised)**: switch to Win10 LTSC 2021 eval. Win11 LTSC download killed,
  segments removed. New 8-segment download → ~/win-iso/win10-ltsc2021-eval-x64-en-us.iso
  (single-stream cap ~640 KB/s; 8 parallel range segments give ~3.6 MB/s, curl 8.18 quirk:
  -C is mutually exclusive with -r, resume implemented by range-offset + shell append).
- autounattend image name: "Windows 10 Enterprise LTSC 2021 Evaluation"; eval edition →
  NO --with-key.

### QWT silent install — TEST_SIGN launch condition (critical)
- installer.msi contains ascii "TESTSIGNING" + "SystemStartOptions" + "GuiCert" →
  the official 4.2.2 build is a TEST_SIGN build: Package.wxs adds
  `Launch Condition SYSTEMSTARTOPTIONS >< "TESTSIGNING"` → **MSI refuses to install
  unless the CURRENT boot already has testsigning active**.
  ⇒ payload must be two-stage: stage1 = testsigning on + trust cert + RunOnce hook +
  reboot; stage2 (next autologon) = vc_redist /quiet + msiexec ADDLOCAL + reboot.
- Feature IDs verified identical at tag v4.2.2-1: PvDriversCore, Core, Gui, MoveUsers,
  Autologon, PvDriversNetwork, PvDriversDisk — none carry Level attrs → ALL default to
  installed in silent mode. A bare `/quiet` bundle run would enable MoveUsers +
  randomized-password Autologon (breaks our user/qubes autologon!) + PV disk driver
  (BSOD risk). ⇒ bypass the Burn bundle; run the inner MSI directly:
  `msiexec /i installer.msi /qn /norestart ADDLOCAL=PvDriversCore,Core,Gui /l*v C:\qwt-msi.log`
  (vc_redist.x64.exe /quiet /norestart first — bundle normally does it).
- MSI custom actions: PreparePrivateImg always runs (Return=ignore, harmless),
  PrepareAutologon only when Autologon feature selected (we skip it),
  ScheduleReboot suppressed by /norestart (msiexec returns 3010 — treat as success).
- Staged into ~/win-iso for the payload: qwt-installer.msi (=installer.msi,
  sha256 7049322128d1cf7d9dc2a48f69ef91a5893a8f779d3b2ad7d25fdfc8eee3baf4),
  vc_redist.x64.exe (sha256 1ad7988c17663cc742b01bef1a6df2ed1741173009579ad50a94434e54f56073),
  qubesidd-test.cer.

### CD-ROM persistence verdict (research agent; sources verified: core-admin xen.xml,
### libvirt libxl_domain.c, qubes-doc windows page)
- **Every guest-initiated reboot HALTS the qube**: libvirt template sets on_reboot=destroy,
  libxl destroys the domain, Qubes has zero auto-restart logic. Official Qubes Windows doc
  confirms ("automatic reboots will halt the qube — just restart it again and again…
  without the --cdrom parameter!").
  ⇒ mgmt/CLAUDE.md step 5's premise ("reboots stay within this qvm-start") is WRONG.
  Orchestrator loop: whenever win-idd-test is Halted during install, `qvm-start` it
  (no --cdrom), bounded (~8 restarts / 60 min), screenshot between attempts.
- CD is also structurally gone after first boot (qvm-start unassigns post-start; libvirt
  XML regenerated per start from assignments). BUT the answer file is cached to
  %WINDIR%\Panther, so specialize/oobeSystem passes still run — only CD files vanish.
- Fixes applied:
  - build-unattended-iso.sh: payload also staged at sources/$OEM$/$1/payload → Setup
    copies it to C:\payload while applying the image (primary, ordering-independent);
    [BOOT] dir dropped from remaster.
  - autounattend.xml: windowsPE RunSynchronous drive-scanning copy (secondary);
    oobeSystem Microsoft-Windows-International-Core added (else OOBE stalls on region/
    keyboard pages); HideLocalAccountScreen + NetworkLocation=Work; FirstLogonCommands
    now `powercfg /h off` then C:\payload\setup.cmd (old loop started at C: but read the
    now-absent CD — exactly the reported blocker).
  - payload split two-stage (TESTSIGNING launch condition): payload-setup.cmd = stage 1
    (cert→USERPROFILE, firstboot-setup.ps1, schtasks QWTStage2 SYSTEM boot task, reboot);
    payload-setup2.cmd = stage 2 (delete task, call install-qwt.cmd, reboot).
    SYSTEM boot task avoids UAC token filtering that would break HKLM RunOnce.
  - firstboot-setup.ps1: + powercfg /h off (kills hibernation AND Fast Startup);
    + pre-seed SeamlessMode=1 / DisableCursor=0 (MSI AppSearch then skips its 0/1 defaults).
  - install-qwt.cmd (research-agent deliverable, reviewed): testsigning sanity check,
    vc_redist /quiet, msiexec /qn ADDLOCAL=PvDriversCore,Core,Gui,PvDriversNetwork
    REBOOT=ReallySuppress /l*v C:\qwt-install.log; rc 0/3010 = OK.
- qrexec_timeout: raise to 7200 at VM creation (qubes-doc: profile move + chkdsk can
  exceed 300 s during early boot).
- Track C answer (from QWT research): Windows→dom0 qrexec client =
  C:\Program Files\Qubes Tools\bin\qrexec-client-vm.exe  (args: dest|service|(null)|(null)).
- QTEST_INCOMING (source-derived, confirm live): C:\Users\user\Documents\QubesIncoming.
- Do NOT pre-set qvm-features gui/gui-emulated (core_features.py refuses guest updates for
  pre-existing values → would pin emulated+agent double-GUI). `os Windows` is fine.

### ISO attach WITHOUT root — solved (research agent, tested)
- udisks2 is running here and polkit allows org.freedesktop.udisks2.loop-setup for the
  active session ⇒ `udisksctl loop-setup -r --no-user-interaction -f file.iso` creates
  /dev/loopN as user; udev (99-qubes-block.rules) auto-publishes it to qubesdb →
  admin.vm.device.block.Available. Delete with `udisksctl loop-delete -b /dev/loopN`.
- qvm-start's dom0-only guard only triggers on PATH arguments; the PORT form
  `qvm-start win-idd-test --cdrom=win-idd-mgmt:loopN` works from this qube
  (get_drive_assignment verified in-process). Constraints: mgmt qube stays running,
  ISO file untouched while attached.
- `qvm-block` CLI broken under Python 3.14 (argparse store_const positional);
  `qvm-device block <action>` works. `qvm-device block list <vm>` still refused
  (enumerates all domains) — enumerate via qubesadmin python instead.
- Kit policy script bug found: `admin.vm.Create.standalone` is NOT a real method —
  real name `admin.vm.Create.StandaloneVM`. User fixed policy live (several iterations);
  Create.StandaloneVM + block.Assign/Attach/Detach/List now pass policy.

### ISO verifier corrections (adversarial pass)
- Integrity: verify sha256 against PUBLISHED value
  e4ab2e3535be5748252a8d5d57539a6e59be8d6726345ee10e7afd2cb89fefb5
  (files.rg-adguard.net + quickemu #1510 corroborate; ETag is NOT the sha256).
- RISK (n=1, unresolved): quickemu #1510 reports this exact eval ISO reboot-looping
  after install under plain QEMU ("Why did my PC restart?"). Watch screenshots for a
  boot loop; mitigation if it bites = retail LTSC ISO (user-provided) or Rank-2 eval.
- RISK: eval license may arrive expired (image is ~5 y old); `slmgr /rearm` (×5) if
  Windows shuts down hourly.
- 7z correctly picks the UDF handler on this ISO (ISO9660 view has only README.TXT;
  verifier proved handler choice with a sparse replica + real 7z run).

### Download incident (self-inflicted, resolved)
- First win10 segment run was CORRUPTED: the killed Win11 segdl task's retry loops
  survived curl kills and kept appending Win11 bytes into the same iso-seg* files
  (16 curls, two URLs, segments >612 MiB cap). Lesson: TaskStop the task, not just its
  curl children. Segments wiped, single clean instance restarted 21:11.

### VM created (Admin API, this session)
- win-idd-test: StandaloneVM, label red, virt_mode=hvm, kernel '', memory=maxmem=8192,
  vcpus 4, netvm '' (offline), qrexec_timeout 7200 (raised from kit's 300 per qubes-doc),
  root 80 GiB (85899345920 verified), feature os=Windows. Policy scope re-probed against
  the real VM: block.Assign/Attach @win-idd-test pass, CurrentState answers (Halted).

### Verifier corrections applied (QWT + cdrom adversarial passes)
- install-qwt.cmd: added /reg:64 to all reg adds (MSI RegLocator is 64-bit; WOW-redirected
  writes would be silently ignored); pre-seeded LogDir="C:\Program Files\Qubes Tools\log"
  (MSI has TWO components racing to write LogDir — [INSTALL_DIR]log vs "Q:\Qubes Logs" —
  same NOT LOG_DIR_SET condition; if Q:\ wins and doesn't exist, agent logs vanish);
  added trust of the six QWT self-signed certs (extracted from MSI Binary.SigningCert*
  streams, PEM, sha1s match verifier) into Root AND TrustedPublisher before msiexec —
  the MSI only installs them to Root, and under /qn nobody clicks the driver-trust prompt.
  Certs at ~/win-iso/qwt-certs/, staged into payload by build script. Backup kept
  (.orig). qvm-block CLI is broken (py3.14); use `qvm-device block …` / python instead.
- windowsPE RunSynchronous payload-copy is DEAD CODE (learn.microsoft: windowsPE
  answer-file settings run BEFORE disk config/image apply) — left in as harmless ballast;
  $OEM$ is the actual mechanism. Rebuilt ISO has no Joliet (ISO9660:1999 only) — believed
  harmless (PVD carries full names), verify on first boot.
- VM accidentally started by an admin.vm.Start policy PROBE (empty payload = valid start
  request!) — killed. Lesson: never probe state-changing admin methods.
- User applied several dom0 policy fixes during this session; final probe state: Create.
  StandaloneVM, block.{Available,Assign,Assigned,Attach,Attached,Detach,List,
  Set.assignment}, volume.List/Resize, property/feature services all pass for
  win-idd-test dest.

### Install launched (21:2x)
- ISO complete: 4898582528 bytes, **sha256 == published e4ab2e35…fefb5** ✔
- build-unattended-iso.sh "Windows 10 Enterprise LTSC 2021 Evaluation" (no --with-key)
  → ~/win-iso/win-idd-unattended.iso (4.7G). Verified inside image: /autounattend.xml,
  /payload/* and /sources/$OEM$/$1/payload/* (14 files: setup.cmd, setup2.cmd,
  firstboot-setup.ps1, install-qwt.cmd, installer.msi, vc_redist, qubesidd-test.cer,
  6× SigningCert*.cer).
- Attach: udisksctl loop-setup -r → /dev/loop0 (qubesdb published, mode=r);
  `qvm-start win-idd-test --cdrom=win-idd-mgmt:loop0` → rc=0, VM Running.
  The port-id --cdrom form works from the AppVM exactly as researched.
- Monitor loop armed (screenshots → mgmt/shots/, auto qvm-start on Halted, cap 10
  restarts, stuck-screen detection).

### Boot failure #1 and fix: "CDBOOT: Couldn't find BOOTMGR"
- Root cause: original MS media's ISO9660 view has only README.TXT — CDBOOT there uses
  UDF. Our no-UDF rebuild relied on the PVD, where -relaxed-filenames had stored
  lowercase 'bootmgr'; CDBOOT wants uppercase 'BOOTMGR'.
- Fix (two iterations): xorriso options now `-iso-level 3 -J -joliet-long -D -N -d`
  → PVD uppercase-mapped (incl. exact 'BOOTMGR'; '-d' needed, else 'BOOTMGR.' with a
  trailing dot), Joliet tree preserves case + $OEM$ for Windows Setup (Win7-era retail
  layout, no UDF). PVD root verified by direct PVD parse.
- User fixed admin.vm.CurrentState policy for the monitor's state probe.
- VM restarted with the fixed ISO (loop0), monitor re-armed.

### Install attempt 2 failure: "answer file is invalid"
- Timing was the diagnostic: the error appeared AFTER the heavy CPU phase
  (~31 s CPU/75 s wall = install.wim expansion), so windowsPE parsed and executed fine
  → the invalid setting was in specialize/oobeSystem, i.e. in settings added this session.
- Removed the two version-sensitive OOBE settings added earlier: `HideLocalAccountScreen`
  (suspected Win11-only) and `NetworkLocation` (pointless with netvm ''). Both were
  redundant: UserAccounts + AutoLogon already suppress account creation.
- Also alphabetized Shell-Setup children and deleted the windowsPE RunSynchronous block
  (proven dead code — windowsPE settings run before disk config/image apply).
- CAUTION recorded in the file itself: do not re-add those two settings untested.
- NOTE contradicting the pure "ordering" theory: International-Core-WinPE has
  SetupUILanguage before InputLocale (non-alphabetical) and windowsPE parsed fine.
  Ordering may not be enforced; the removed settings are the likelier cause.
- build-unattended-iso.sh: added REUSE_EXTRACT=1 (skip the ~2 min 7z re-extract per
  answer-file iteration; payload + autounattend still re-staged each run).

### Monitor bug (self-inflicted, fixed)
- First two monitors queried `qrexec-client-vm dom0 admin.vm.CurrentState` → that returns
  DOM0's state, so halt-detection could never fire. Now uses dest=win-idd-test, tracks
  cputime deltas as a liveness signal, and exits on successful qubes.VMShell (= QWT up).
- local.WinScreenshot still returns rc=1 (no matching windows) although the user confirms
  the window title does start with "[win-idd-test]" → suspect the dom0 service's hardcoded
  XAUTHORITY=/home/$DOMUSER/.Xauthority vs Qubes 4.3 GDM's /run/user/1000/. Fix handed to
  the user (dom0-side, not ours to change). Working blind via CPU telemetry meanwhile.

## INSTALL SUCCEEDED — attempt 3 (2026-07-30 ~22:00)

Fully unattended, zero human clicks in the guest. 4 guest reboots, each of which HALTS the
qube (Qubes on_reboot=destroy) and was auto-restarted by the monitor without --cdrom:
  #1 Setup phase 1 -> #2 specialize/OOBE -> #3 payload stage 1 (testsigning) -> #4 QWT stage 2.
CPU-delta telemetry was the progress signal throughout (screenshots were unavailable).

### Acceptance results (all via qubes.VMShell)
| Check | Result |
|---|---|
| OS build | **10.0.19044.1288** = Win10 Enterprise LTSC 2021 Eval, as intended |
| identity | `win-idd-test\user`, qrexec cmds land in interactive **session 1** (console, Active) |
| testsigning | `SystemStartOptions = TESTSIGNING NOEXECUTE=OPTIN` (active in current boot) |
| Qubes services | QdbDaemon / QrexecAgent / QubesGuiWatchdog all **Running, Automatic** |
| build cert | `QubesIDD` present in Root ✔ |
| QWT certs | 12 matches in **Root** and 12 in **TrustedPublisher** (our pre-trust worked) |
| feature selection | PvDriversDisk ✘ absent, MoveUsers ✘ absent, Autologon ✘ absent, Gui ✔, Core ✔ |
| registry pre-seed | SeamlessMode=**1**, DisableCursor=**0**, LogDir=`C:\Program Files\Qubes Tools\log` — all three beat the MSI defaults exactly as designed |
| QubesIncoming | **`C:\Users\user\Documents\QubesIncoming\<srcvm>`** (verified by real qvm-copy; on C: because MoveUsers excluded). Exported to ~/.bashrc as QTEST_INCOMING |
| clean reboot | `qvm-shutdown --wait` + `qvm-start` OK, **qrexec answered 10 s after start** |
| dom0 features | QWT advertised `gui=1`, `gui-emulated=`(empty), `qrexec=1`, rpc-clipboard, audio-model ich6, timezone localtime |
| default_user | `user` (default, no change needed — as researched) |

Neither flagged risk materialised: no quickemu-#1510 reboot loop, no Q: format prompt
(PreparePrivateImg created Q: silently), eval licence not expired.

### Answer-file postmortem (validation workflow wf_cc0e50bc-df8, retrospective)
- The "children must be alphabetical" theory is **REFUTED**. Component children are not
  XSD-validated at all: the ADK autounattend.xsd declares component contents as
  `<xsd:any processContents="lax">`; validation happens in the Component Platform
  Interface against per-component WinSxS manifests (which are PA30/MSDelta-compressed and
  unreadable on Linux). Three known-good Microsoft/community answer files use mutually
  incompatible child orders. The reorder was a **no-op**; the real fix was removing
  **HideLocalAccountScreen**. `NetworkLocation` was exonerated. Comment in
  autounattend.xml corrected so future sessions are not misled.
- For any future failure: the Setup error dialog names the failing pass in brackets
  (`...for pass [specialize]. The answer file is invalid.`) — CAPTURE THAT BRACKET; and
  the guest logs it in `X:\Windows\Panther\setupact.log` (WinPE) / `C:\Windows\Panther\*`.

### Live finding relevant to Track A/B (hand to the dev session)
gui-agent log `C:\Program Files\Qubes Tools\log\gui-agent-*.log` already shows, at
seamless-mode switch / resolution change (5120x1440):
    GetFrame: duplication->AcquireNextFrame() failed with error 0x887a0026:
              The keyed mutex was abandoned.
    CaptureThread: failed to get frame
plus `SetSeamlessMode: Seamless mode changed to 1` and `SendWindowMap: Mapping window 0x40054`.
This is the Desktop Duplication capture path Track A instruments — a real, reproducible
capture failure mode on mode change, worth investigating in Phase 1A.

### Phase 0 items completed here (dev session can skip)
1. `qtest state` / `run` / `pushrun` round-trip **verified working** (see below).
2. `QTEST_INCOMING` — the qtest default already appends the source-VM subdir, so the
   correct value is `C:\Users\user\Documents\QubesIncoming\win-idd-mgmt` (NOT the bare
   QubesIncoming dir — an earlier ~/.bashrc line omitted the subdir and would have broken
   `qtest pushrun`; corrected). Exported in ~/.bashrc.
   Verified: `qtest pushrun probe.ps1` → `PUSHRUN_OK host=WIN-IDD-TEST user=user`.
4. CI convergence: **already green** — arkenoi/qubes-win-idd-driver, last 3 `build` runs
   all success; secrets SIGNING_PFX_B64 / SIGNING_PFX_PASS and var SIGNING_ENABLED=true
   are set. `gh` authenticated as `arkenoi` (scopes incl. repo, workflow);
   gh-token.txt shredded from BOTH ~/qubes-win-idd/secrets and ~/QubesIncoming/....
   Dev repo fast-forwarded to origin/main (2ab411b) + submodule `agent` initialised.

### Cleanup
- Removed ~/win-iso/.unattend-work (4.9 G extract); detached /dev/loop0. /home now 25% used.
- Kept: win10-ltsc2021-eval-x64-en-us.iso (source), win-idd-unattended.iso (rebuildable
  installer), QWT rpm/iso/payload/certs. VM confirmed healthy with NO CD attached
  (Win32_CDROMDrive count = 0), 62 GB free on C:, C:\payload present ($OEM$ proof).

### local.WinScreenshot — FIXED (two separate bugs in the kit's original service)
Bug 1 — X credentials: hardcoded `XAUTHORITY=/home/$DOMUSER/.Xauthority`. This dom0 uses
lightdm, which keeps the cookie at `/run/lightdm/<user>/xauthority` (dom0 user is `ark`,
uid 1000, X11, DISPLAY=:0). The service now probes candidate paths and verifies the
connection before use, and reports a real error instead of failing silently.

Bug 2 (the real one) — window selection by TITLE: `xdotool search --name "^\[win-idd-test\]"`
matches nothing, because **Qubes does not prefix WM_NAME with the qube name**. WM_NAME is
just e.g. `Untitled - Notepad`; the "[vm]" seen in the title bar is window-manager
decoration drawn from the `_QUBES_VMNAME` X property that qubes-gui-daemon sets in dom0.
  → Service rewritten to enumerate `_NET_CLIENT_LIST` and select windows whose
    `_QUBES_VMNAME` equals the target VM. Windows without that property (native dom0
    windows) are never captured.
  → This is also a SECURITY FIX, not just a correctness fix: window titles are set by the
    GUEST and are spoofable — a hostile VM could title itself "[win-idd-test] ..." to get
    itself captured into this qube. `_QUBES_VMNAME` is set by dom0 and cannot be forged
    from inside a VM. Do not revert to title matching.
Fix persisted in `dom0/04-install-screenshot-service.sh` (kit) and installed in dom0.
VERIFIED: `local.WinScreenshot` rc=0 → tar with `win-0.png`, 2566x1022 PNG showing the
guest's Notepad window rendered correctly in seamless mode; `qtest shot out.tar` wrapper
works too. Provisioning acceptance step 3 satisfied.

## HANDOFF
`win-idd-test` is READY. Dev session starts in `~/qubes-win-idd-driver/` (its own CLAUDE.md),
same qube, `export QTEST_INCOMING='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'`
(already in ~/.bashrc). Reinstall recipe, if ever needed:
  mgmt/build-unattended-iso.sh ~/win-iso/win10-ltsc2021-eval-x64-en-us.iso \
      "Windows 10 Enterprise LTSC 2021 Evaluation"     # no --with-key (Eval SKU)
  udisksctl loop-setup -r --no-user-interaction -f ~/win-iso/win-idd-unattended.iso
  qvm-start win-idd-test --cdrom=win-idd-mgmt:loop0    # PORT form; path form is dom0-only
  # then restart the qube (WITHOUT --cdrom) at each halt; ~4 halts total.
