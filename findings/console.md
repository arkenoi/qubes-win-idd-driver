# console — findings

## CURRENT STATE

AUTHORITATIVE. Supersedes everything under History below. A correction belongs HERE,
not only as a new dated section — the whole reason this file exists is that 654
correction lines were buried chronologically in a 25k-line log, so reading a topic
top-down returned the stale answer.

- We SHIP `xencons` since 4.3.16. `XENBUS\VEN_XP0001&DEV_CONS` binds (cm=0) and the guest runs an interactive `cmd.exe` on the PV console ring. [verified 2026-09-01]
- `qvm-console <vm>` == `sudo xl console -t pv <vm>`. Plain `xl console <vm>` can NEVER work on a Qubes HVM: no `<serial>` in the libvirt XML, so the stubdom has no console 3 (qubes-issues #3039). [verified 2026-09-01]
- `Unable to attach console` means execv failed, not "no tty" - `/usr/libexec/xen/bin/xenconsole` is mode 0700 root, so use sudo. [verified 2026-09-01]
- Stock Qubes DENIES `admin.vm.Console` to everyone including dom0; the shipped policy file is comments only. Grant added to dom0/12-install-policy-tagged.sh. [verified 2026-09-01]
- The guest CAN WRITE the ring - `guest/console-write.ps1`, a second handle on the xencons device. Lines land in dom0's `guest-<vm>.log` continuously with no qrexec, no session and no attached reader. [verified 2026-09-01]
- An emulated serial needs NO dom0 change (`qvm-features <vm> qemu-extra-args '-serial file:/dev/hvc0'` -> COM1 appears). Output-only; interactive SAC is unreachable on Qubes because a Qubes patch drops the dom0 qemu that serves stubdom consoles. [verified 2026-09-01]
- Traps: ONE attacher at a time (a concurrent `xl console` makes a probe read empty), and it needs a LOGIN per boot. [verified 2026-09-01]
- It will NOT rescue the wedge: no bugcheck occurs and nothing is schedulable to emit. UNVERIFIED

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

## The experiment

Control = `6b5b298` reverted on top of `a4f6961` (`768CA58C`), i.e. a **single variable** — unlike
`98eed30`, which also lacks four other fixes. Test = `F06C0979`. `PerWindowCapture` on (its
default). Scene: a console window scrolling text forever, so its per-window channel produces
continuous damage — a static window emits none even when perfectly healthy, which would have made
"no damage" unreadable. Trigger: `CreateDesktop` + `SwitchDesktop` away for 8 s (more than the
five capture attempts needed to trip `DEAD_AFTER_FAILURES`) and back.

| build | damage before | damage after | channel |
|---|---|---|---|
| guard REVERTED `768CA58C` | 136 / 12 s | **83 / 12 s** | alive |
| guard PRESENT `F06C0979` | 176 / 12 s | **118 / 12 s** | alive |

**Identical behaviour.** The hypothesised harm — `AttachThreadToInputDesktop()` following onto a
non-`Default` desktop, captures failing five times, `DEAD_AFTER_FAILURES` marking the channel
dead forever — **did not occur without the guard**.

Combined with the rest of the case against it, that is enough to revert:
- its stated justification (guest stuck at "Welcome", PrintWindow stalling LogonUI from SYSTEM)
  was **already retracted** — FINDINGS 2026-08-03 shows that hang was Windows Update;
- it logs **nothing** on either edge of its idle branch, so in production it can never be shown
  to have acted — unfalsifiable by construction, which CLAUDE.md's instrument rule forbids.

Reverted in agent `8629a9c`.

## 2026-08-14 — THE SERIALISED PATH LANDS: 26100.8875 -> 26100.9168

Second pass, shipping default (multistage override cleared), single package, cached .msu reused
(416 "already complete" - no 4.8 GB re-fetch, which is what preserving a staged package bought):

    build = 26100.9168 (24H2)
    KB5121003 installed = True        KB5120710 installed = True
    RebootPending absent   winsxs pending.xml absent   DISM: no component store corruption

The acceptance criterion that stood unproven all day is met. One reboot-requiring package per pass,
dom0 driving a second pass for the deferred one, is a WORKING model - not just the right diagnosis.

### The teardown hang, and why the kill was safe

The apply took far longer than the 6.3 min known-good run and the guest sat on "Restarting" burning
exactly ONE core. That is consistent with the offline commit (poqexec is single-threaded by design;
the multi-core phase is TiWorker staging, which had already finished at 842 CPU-s). But the real
story was visible in dom0: `qvm-ls` showed **Transient**, not Running, for 8+ minutes - Windows had
finished and issued its restart, and it was the DOMAIN TEARDOWN that hung (`on_reboot=destroy`).

So the kill destroyed an already-committed Windows, not a live transaction - confirmed by the clean
CBS state and the successful build above. Worth knowing for next time: on this rig a stuck
"Restarting" should be diagnosed from dom0 state FIRST. Running = still working; Transient = Windows
is done and the domain is failing to go away, where a kill is safe and correct.

Unresolved: WHY the teardown hangs. Not investigated - it cost ~20 minutes here and would strand a
user who does not know to kill the qube.

## 2026-08-29 — xencons (PV console) now BUILDS and test-signs in CI

Owner: *"why not to give it a cheap shot -- download, build, add?"* Done — the source is public, it
uses the same `build.ps1`/`msbuild.ps1` layout as xenvif, and CI already builds and signs that.

`.github/workflows/pv-xencons.yml`, pinned to upstream SHA `a815963`, produces:

    xencons.sys 79,248   xencons_monitor.exe 128,720   xencons_tty.exe 112,664
    xencons.inf 3,788    xencons.cat 3,518 (SIGNED)    xencons-signer.cer   PROVENANCE.txt

**Four inherited assumptions had to be corrected**, three of them mine from copying the template and
one the driver itself surfaced. Recorded because "copy the working workflow" is cheap and its baked-in
assumptions are not:
1. the header carried xenvif's `rev 0x09000005` argument — that is about xennet binding and is
   meaningless for a console driver; rewritten truthfully;
2. `git clone --branch $SHA` does not accept a raw SHA — now clone, checkout, and assert the resolved
   SHA equals the pin, so a moving branch can never silently change what is built;
3. the xenvif control-ring patch step (mirage-firewall's `feature-ctrl-ring`) has no meaning here and
   was failing on a nonexistent patch file — removed rather than stubbed;
4. **the driver ships more than xenvif does**: its INF has `[monitor_copyfiles]` and `[tty_copyfiles]`
   referencing `xencons_monitor_*.exe` and `xencons_tty_*.exe` — a PV console has a userspace side a
   NIC does not — so Inf2Cat failed signability until the file set was widened.

**What this buys, precisely:** an out-of-band channel for the failure that currently blinds every
other one. When the wedge hits we lose qrexec, window capture and the event log simultaneously; a PV
console is readable from dom0 with `xl console` and depends on none of them. **What it does not buy:**
a guarantee — if the guest is deadlocked at high IRQL the console may be silent too. It is the
instrument for the observed class "guest alive, qrexec dead", which is what we keep hitting.

**Not yet shipped in the package.** Building it is half the job; adding it to the payload, installing
it, and confirming `XENBUS\VEN_XP0001&DEV_CONS` leaves CM code 28 is the other half — and that
allowlist entry in `guest/health-check.ps1` becomes wrong the moment it does.

## 2026-08-30 — the PV console BINDS: DEV_CONS err=28 -> err=0, first time in this project

Owner asked "console?". Checked rather than assumed, and the first answer was the honest negative:
`win10-clean` was installed from the `fdd4700` (4.3.15) ISO, which predates the xencons wiring, so
it read `DEV_CONS err=28`, no `xencons.sys`, and no `pv-drivers\xencons.inf` in its installed
package. Built and shipping is not the same as installed.

Side-loaded the 4.3.16 artifact's xencons payload (diagnostic install, NOT acceptance) to de-risk
the matrix before six cells depend on it:

    before:  XENBUS\VEN_XP0001&DEV_CONS\_  err=28  svc=(none)
    after:   XENBUS\VEN_XP0001&DEV_CONS\_  err=0   svc=xencons  name="Xen PV Console"
             C:\Windows\System32\drivers\xencons.sys present, service Running

Verified the DEVICE, not pnputil's word for it - this project has a recorded trap where pnputil
prints "Driver package added successfully" for a package that did not land.

**Consequences.** The whole chain works: build from the pinned xenbits SHA, Inf2Cat, test-signing,
signer-cert import into Root/TrustedPublisher, pnputil install, device bind. It also validates the
health-check change made earlier today - dropping the `DEV_CONS:28` allowlist in favour of a real
`pv_console_bound` assertion - which would otherwise have failed every cell.

**Still unconfirmed, and only the owner can confirm it:** that `xl console <vm>` from dom0 actually
produces readable output. This qube has no dom0 shell. That is the half that matters for the wedge,
since the console is the only channel that does not die with qrexec, window capture and the event
log.

## 2026-08-30 — TWO-STAGE (E1) path GRADED: 9 passed, 0 failed, and xencons proven in-cell

`tools/grade-twostage.sh win10-u10 6022427`, on a guest provisioned from pristine media with the
release payload stick (stick-orchestrated, because a pristine guest has no qrexec to push to):

    PASS  stage1-prepare ok:true            PASS  two distinct run_ids
    PASS  stage2-install ok:true            PASS  stage 1 ran with testsigning INACTIVE
    PASS  installed agent == release binary (20CAB4C56816077D)
    PASS  PV driver CONS bound (svc=xencons)
    PASS  PV driver IFACE bound (svc=xeniface)
    PASS  PV driver VBD bound (svc=xenvbd)
    PASS  xenbus_monitor is not running
    note  DEV_VIF present: 0  (expected on netvm=''; the PV NIC is graded on the AppVM cells)

This is the E1 two-stage path proven as a graded cell, not merely observed in passing. The checks
that make it a two-stage claim rather than a relabelled single-stage one: BOTH stage RESULTs, TWO
distinct run_ids (one would mean a single invocation), and `testsigning_active:false` on the
installer's own PRECONDITION line - the state that DEFINES E1, asserted on the authority P1.0 names.

**xencons is now proven bound in a graded install** (`DEV_CONS err=0 svc=xencons`), which closes the
"all drivers" gap for the console. It had been allowlisted as expected-broken since QWT shipped no
xencons at all; that ceased to be true at 4.3.16.

**Probe defect caught before it became a false regression.** The first version of the driver check
used a PowerShell `-replace '.*DEV_([A-Z]+).*','$1'` whose `$1` was mangled by shell quoting, and it
reported "no devnode found" for ALL FOUR drivers on a guest where three were demonstrably bound.
Four-for-four failure is a broken probe, not four broken drivers - verified directly before
reporting anything. This is the same species as the five earlier checks-that-cannot-fail; the
difference is it was caught in the same minute rather than after a campaign.

# 2026-09-01 — Xen console: why `xl console` and `qvm-console` can never reach a Windows guest

Traced end to end in source (Xen 4.21 = installed version, qubes-core-admin main, libvirt main,
qubes-vmm-xen-stubdom-linux main). Not a bug in our rig: three structural facts.

**They are not the same tool.** `qvm-console` -> `qrexec-client-vm <vm> admin.vm.Console` ->
dom0 `/etc/qubes-rpc/admin.vm.Console` -> `qubesd-query` -> `qubes/api/admin.py::vm_console`,
which is literally
`xpath("string(/domain/devices/console/@tty)")` on the libvirt XML, returned to the script, which
then runs `socat - OPEN:"$path"`. libvirt filled that attribute at domain-create from
`libxl_console_get_tty(domid, port 0, LIBXL_CONSOLE_TYPE_PV)` on the GUEST domain
(libvirt `libxlConsoleCallback`). So **`qvm-console <vm>` == `xl console -t pv <vm>`**, and plain
`xl console <vm>` is a DIFFERENT console. `xl` is dom0-only: it is installed in win-idd-mgmt but
every hypercall returns Permission denied, so nothing here can run it.

1. **`xl console <vm>` (no `-t`) cannot work on any Qubes HVM.**
   `libxl__primary_console_find()`: a domain with a stubdomain redirects to
   `(stubdomid, STUBDOM_CONSOLE_SERIAL=3, TYPE_PV)`. libxl creates stubdom console 3 only if the
   guest has an emulated serial: `libxl_dm.c` `num_console = 3; if (b_info->u.hvm.serial)
   num_console++`. libvirt sets `u.hvm.serial` only from `<serial>` elements
   (`libxl_conf.c:778 if (def->nserials)`), and Qubes' `templates/libvirt/xen.xml` emits
   `<console type="pty"><target type="xen" port="0"/></console>` and **no `<serial>` at all**.
   => stubdom has consoles 0,1,2; console 3's xenstore `tty` node does not exist; xenconsole
   fails with "Could not read tty from store". = qubes-issues **#3039**, marmarek's answer there
   is exactly "use `sudo xl console -t pv <hvm_domain>`".
2. **`-t pv` / `qvm-console` attach fine and land on a LIVE interactive cmd.exe.**
   **RETRACTED, same session:** I first wrote here that "Windows has no PV console frontend and
   never writes a byte". That is wrong, and it contradicted our own work - the owner caught it
   ("windows has pv console"). Since 4.3.16 we build and ship **xencons** (CI
   `.github/workflows/pv-xencons.yml`, xenbits SHA a815963). Measured on `win10-app`, 2026-09-01:

       XENBUS\VEN_XP0001&DEV_CONS\_      cm=0  svc=xencons   "Xen PV Console"
       XENCONS\VEN_XP&DEV_CONSOLE\0      cm=0                (the statically-created "default" PDO)
       xencons.sys present; xencons_monitor  Running/Automatic  pid 3280
       xencons_tty_9_1_0_0.exe  RUNNING  pid 3656
       HKLM\...\xencons_monitor\Parameters\default\Executable = xencons_tty_9_1_0_0.exe

   Source chain: the default PDO takes `ConsoleCreate` (not `FrontendCreate`) and rides
   xenbus.sys's `XENBUS_CONSOLE_INTERFACE` = the primary HVM console ring, the very one
   xenconsoled serves. `IOCTL_XENCONS_GET_NAME` returns `"default"`, matching the INF's
   `Parameters\default`. `xencons_tty` runs `%SystemRoot%\system32\cmd.exe /q /a` via
   `CreateProcessAsUser` (src/tty/tty.c:119,159).
   So dom0 xenconsoled <-> HVM console ring <-> xenbus <-> xencons <-> monitor -> tty -> cmd.exe
   is **complete and live right now**. `qvm-console <vm>` / `xl console -t pv <vm>` give an
   interactive Windows prompt.
   **Why it reads as "cannot attach": a pty has no scrollback.** cmd.exe printed its banner at
   boot; a later attach sees a blank screen and produces nothing until you PRESS ENTER. The log
   `/var/log/xen/console/guest-<vm>.log` is xenconsoled's independent copy of the same ring, so
   it holds that history - hence "the log shows it is ok" while the live attach looks dead.
3. **qvm-console's own extra failure mode: the empty tty.** `xpath("string(...)")` yields `""`
   for a missing attribute with no error, so a domain whose XML has `<console type='pty'>` and no
   `tty=` makes the RPC run `socat - OPEN:""` -> "Cannot connect to <vm>", no diagnostic. That is
   qubes-issues **#5156** (libvirt loses the race to read `console/tty`). Xen 4.21 added an
   xswait on `console/tty` before firing console-available (`libxl_create.c:1959`), so it should
   be fixed - but an INSTANT "Cannot connect" is this, and a silent attach is (2).
   Discriminator, dom0: `virsh -c xen:/// dumpxml <vm> | grep -A2 '<console'`.

**Tooling fixed:** `dom0/11-wedge-forensics.sh` step 5 called `xl console "$DOMID"` with no
`-t pv`, i.e. it has been capturing nothing since it was written, and this is the call that
"crashed with buffer overflow" on 2026-08-04. Now `-t pv`, plus it collects
`/var/log/xen/console/guest-$VM{,-dm}.log` and the libvirt console XML. Needs a dom0 reinstall of
the service to take effect (`13-install-wedge-forensics-service.sh`); the service is currently
REFUSED by policy anyway (`local.WinWedgeForensics` -> "Request refused"), so it needs reinstall
regardless.

**Stale docs that caused the wrong claim, now fixed:** `README.md` and
`docs/WHAT-CHANGED-FOR-USERS.md` both still listed "`XENBUS\...&DEV_CONS` sits at code 28 - QWT
ships no `xencons`" under Known limitations. `guest/health-check.ps1` had been updated correctly
(it asserts CONS is bound), the user-facing docs had not. Both now say `-t pv` / `qvm-console`
and "press Enter".

**An emulated serial would still ADD something** - not the interactive console (we have that),
but the two windows xencons cannot cover: before Windows/xencons loads, and a guest deadlocked at
high IRQL. Both DESIGNED, NOT TESTED:
 - read-only, no dom0 change: `qvm-features <vm> qemu-extra-args '-serial file:/dev/hvc0'` (the
   template interpolates this into the stubdom qemu cmdline; hvc0 is the stubdom logging console
   -> `guest-<vm>-dm.log`) + `bcdedit /ems on /bootems on /emssettings EMSPORT:1` in the guest.
   DESIGNED, NOT TESTED.
 - interactive: add `<serial type='pty'/>` via a dom0 `/etc/qubes/templates/libvirt/xen-user.xml`
   override -> stubdom gets console 3 -> plain `xl console <vm>` works and, with EMS, gives an
   interactive SAC prompt on a guest whose qrexec and gui-agent are dead. Needs dom0.

**Unrelated observation, same session:** `win-idd-test` no longer boots - `qvm-start` dies after
~52 s with "Cannot connect to qrexec agent for 6000 seconds" (the early-exit path: the domain
stopped running) and the qube ends Halted. `win10-app` starts in 18 s on the same rig, so this is
guest-specific, not systemic.

## 2026-09-01 (same session, cont.) — the qvm-console failure is a POLICY DENY, and it is stock

Owner ran, in dom0:

    $ qvm-console win10-app
    Use '^]' to exit remote console
    Cannot connect to win10-app2026/09/01 00:54:25 socat[284623] W waitpid(): child 284624 exited with status 1

That is neither of the two mechanisms above. "Cannot connect to %s" is `qvm-console`'s own
message, printed by its `qrexec_console()` for ANY nonzero exit of the inner
`qrexec-client-vm ... admin.vm.Console` (it special-cases only 200 = flock busy), and the inner
call's stderr is thrown away by the wrapper (`2>/dev/null`) - so the real reason never reaches
the terminal. The socat "status 1" is just `qrexec_console`'s own `exit 1` and discriminates
nothing.

**Stock Qubes denies `admin.vm.Console` to everyone, dom0 included.** In qubes-core-admin:
`qubes-rpc-policy/admin.vm.Console.policy` contains **only comments** - *"The admin.vm.Console
service is dangerous... This is why the default policy is 'deny'"* - and
`90-admin-default.policy.header` resolves the service to `include/admin-local-rwx`, which ships
with **no rules at all**. There is no implicit dom0 allow in qrexec policy: `@adminvm` is an
ordinary source token. So a stock system has `qvm-console` permanently dead, for every qube and
every caller, with that one uninformative line as its only symptom.

Confirm in dom0 (the wrapper hides exactly this): `qrexec-client-vm win10-app admin.vm.Console
</dev/null; echo rc=$?` -> expect `Request refused`, rc=126.

**Grant added to `dom0/12-install-policy-tagged.sh`** (needs a dom0 re-run to take effect):

    admin.vm.Console  *  @adminvm      @tag:win-idd-testbed  allow target=dom0
    admin.vm.Console  *  win-idd-mgmt  @tag:win-idd-testbed  allow target=dom0

Needs no policy at all, and proves the guest end immediately: `sudo xl console -t pv <vm>`,
then **press Enter** -> the cmd.exe prompt that xencons_tty is already running.

**Second defect found in our own kit, same file.** `12-install-policy-tagged.sh` writes
`29-win-idd-testbed.policy` with `cat >` (truncate), and
`13-install-wedge-forensics-service.sh` APPENDS its grant to that same file - so re-running 12
after 13 silently revokes wedge forensics. That is why `local.WinWedgeForensics` answered
"Request refused" from win-idd-mgmt this session despite having been installed. 12 now declares
the line itself; 13 checks before appending, so it will not duplicate.

## 2026-09-01 — `xl console` "Unable to attach console" = execv failed; and the dom0 workarea leftover

**"Unable to attach console" is not a console diagnosis.** From `tools/xl/xl_console.c`,
`main_console` prints that string **unconditionally after the exec call returns**:

    if (!type) libxl_primary_console_exec(...); else libxl_console_exec(...);
    fprintf(stderr, "Unable to attach console\n");
    return EXIT_FAILURE;

Both helpers end in `execv()` - on success the process image is replaced and the fprintf can
never run. So that message means the **execv did not happen**, and the overwhelmingly likely
cause is permissions: `/usr/libexec/xen/bin/xenconsole` is **mode 0700, root:root** (verified in
this qube's xen-runtime 4.21.1-4.fc44, same package as dom0). Run it under `sudo`. It is NOT the
missing-tty error - that one comes from xenconsole itself ("Could not read tty from store") and
only after the exec succeeded.

**dom0 workarea watcher: leftover, now removable.** `dom0/09-install-workarea-watcher.sh`
installs `~/.local/bin/qubes-win-workarea-watch.sh` plus a `~/.config/autostart/` entry, hard
coded to `win-idd-test`, that mirrors dom0's `_NET_WORKAREA` into that guest's qubesdb. Three
problems, all fixed in the installer this session:
1. **No uninstaller** - it survives every dom0 login. Added `--uninstall` (kills, removes both
   files, and prints the `qubesdb-rm -d <vm> /qubes-workarea` needed to clear the last value).
2. **Hard-coded VM** - it makes ONE testbed guest a different experimental subject from all the
   others (the agent watches `/qubes-workarea`; FINDINGS records workarea churn at 12.2
   applies/s on a pre-fix agent). Now takes the VM as `$1`.
3. **Unconditional write every 60 s** - `push()` compared against a local `last` cache which the
   poll loop cleared each minute so a restarted guest's fresh qubesdb got repopulated; net
   effect was a qubesdb write + syslog line every minute forever. `push()` now reads back the
   VM's actual value and writes only on a real change, which covers the restart case for free.

It cannot start a halted VM: `qubesdb-write -d` talks to a dom0-local socket, not qrexec. On a
halted `win-idd-test` it simply fails silently once a minute.

## 2026-09-01 — PV CONSOLE WORKS END TO END from the dev qube; what it buys over qrexec

With `admin.vm.Console` granted (owner installed the policy), from win-idd-mgmt:

    $ qrexec-client-vm win10-app admin.vm.Console      rc=0
      \r\n[ATTACHED]\r\n\r\nWIN-IDD-TEST login:
    (later, after login) sent "\r" -> received '\r\nC:\Users\user>'

So it is a **bidirectional interactive Windows shell over qrexec**, not a read-only trickle.
`sudo xl console -t pv <vm>` gives dom0 the same thing (owner confirmed; sudo was the fix -
`/usr/libexec/xen/bin/xenconsole` is mode 0700 root, and xl's "Unable to attach console" is
printed unconditionally after a FAILED execv, so it means "could not run xenconsole", never
"no tty").

**ONE ATTACHER AT A TIME.** dom0's `xl console` and the dev qube's `qvm-console` open the same
pty slave and split the byte stream. Measured here: probe 1 got the login banner, probe 2 got
NOTHING (owner was attached concurrently), probe 3 got the prompt. A silent console is therefore
not evidence of a dead console until you have checked that nobody else is attached. The cmd.exe
session also PERSISTS across detach/reattach - probe 3 found it already logged in.

**What it buys over qrexec** (the honest list):
1. **Disjoint transport.** qrexec = vchan + qrexec-agent in the interactive user session
   (+ gui-agent for capture). The console = xenbus console ring + evtchn, serviced by dom0's
   xenconsoled. They share no code, no session, no service. The recurring wedge class recorded
   here is exactly "guest alive, qrexec dead - qrexec, window capture and the event log all go
   at once"; the console is the only instrument that is not in that set.
2. **No logged-on session needed.** qrexec runs in the user's session - `pushrun` against a
   session-less guest returns NOTHING and reads as "found nothing" (it bricked a subject once).
   `xencons_tty` prompts for a login itself and builds its own token
   (`LoadUserProfile` + `CreateProcessAsUser`, src/tty/tty.c:119,159), so it can produce a shell
   where qrexec structurally cannot: sign-in screen, logged-off guest, autologon disabled - the
   2026-08-28 lockout ("0 windows mapped, qrexec answers, no password box anywhere").
   **INFERRED FROM SOURCE + the login prompt, NOT YET DEMONSTRATED on a logged-off guest.** That
   is a cheap, high-value test and it is the claim to prove before relying on this.
3. **Retroactive.** xenconsoled writes `/var/log/xen/console/guest-<vm>.log` continuously whether
   or not anyone is attached, so it holds output from BEFORE you started looking. No other
   instrument here retains that.
4. **Zero guest cooperation from dom0.** `sudo xl console -t pv <vm>`: no policy, no agent, no
   qubesdb, no netvm.

**What it does NOT buy** (do not oversell it):
1. **It probably will not survive the measured wedge.** That is a Xen HVM IPI/TLB-shootdown
   deadlock (proven from two NMI captures). If vCPUs spin at high IRQL, xencons's own DPC/worker
   does not run either and the console goes silent with everything else.
2. **No pre-Windows coverage.** xencons is a PnP driver enumerated by XenBus well into boot -
   nothing for firmware, Setup, or a bugcheck screen. That is the gap the emulated-serial + EMS
   option covers (SAC also survives states a user-mode tty cannot, and offers restart/crashdump).
3. **No pixels.** It does not replace `qtest shot` for anything display-related, which is most
   of this project.
4. **Not on QWT-free images.** xencons ships in OUR package, so a pristine guest still cannot be
   driven; the "one provisioning run per version" cost from 2026-08-29 stands unchanged.

**Loose end, low value now:** the owner's `qvm-console` IN DOM0 still failed after the policy
went in, while the same call from win-idd-mgmt succeeded - so the policy did take effect and the
remaining dom0-side issue is separate (dom0-as-source/dom0-as-target routing). Moot in practice:
dom0 has `sudo xl console -t pv`, which needs no policy at all.

## 2026-09-01 — THE GUEST CAN WRITE TO THE PV CONSOLE RING. Windows now has a dom0-captured log

Owner: *"linux writes a lot there. windows, nothing. can we write something useful there?"* Yes,
and it is cheap. **PROVEN end to end on win10-app**, both directions of the claim:

    guest: [QubesConsoleWriter]::Send(...)  -> OPEN_OK write_ok=True wrote=47/47 err=0
    dev qube listener over admin.vm.Console -> '\r\nQCONMARK-ALPHA host=win-idd-test t=01:23:47\r\n
                                                QCONMARK-BRAVO second write proves streaming\r\n'
    shipped helper, re-validated as the file we commit:
                                              '[QWT] 2026-09-01T01:26:30.589+00:00 HELPER VALIDATION ...'

**And bytes written with NO reader attached were still delivered on attach** - the 01:23:47 pair
was written before the listener existed and arrived anyway. Independently of that, xenconsoled
writes the ring to `/var/log/xen/console/guest-<vm>.log` continuously.

**Mechanism.** Open a SECOND handle on the xencons device
`\\?\XENCONS#VEN_XP&DEV_CONSOLE#0#{0d3edd21-8ef9-4dff-856c-8c68bf4fdca3}` and WriteFile to it.
Legitimate by construction: xencons.sys keeps a per-FileObject handle list and xencons_monitor
opens with `FILE_SHARE_READ|FILE_SHARE_WRITE`, so this does not disturb the interactive tty
sharing the ring. The interface path comes from the DeviceClasses key NAME with its leading
separators unescaped (`##?#...` -> `\\?\...`); there is **no `#` subkey holding SymbolicLink** on
19045, and assuming there was is why the first attempt reported "no interface" on a bound driver.

**Instrument bug worth remembering, second time this class has cost this project time:** calling
WriteFile via `Add-Type -MemberDefinition` with an `out uint` parameter returned
**wrote=0 err=0** - a silent no-op that reads exactly like "the guest cannot write to this
device". Moving the whole call into a real C# type fixed it. Identical failure class to the
qubesdb P/Invoke bug already recorded here ("unreadable in a Windows guest" was marshalling).
**A capability conclusion drawn from a P/Invoke that returned zero-and-no-error is not a
capability conclusion.**

**Shipped:** `guest/console-write.ps1` (validated by pushing and running THE COMMITTED FILE, not
the scratch script that proved the mechanism).

**Why this matters here.** It converts the console from "a shell someone must log into" - which
the three dents above made nearly useless for unattended work - into a **guest -> dom0 telemetry
channel that needs no qrexec, no session, no gui-agent and no attached reader**, and that is
captured retroactively. That is precisely the gap: *"when this happens we lose every channel at
once."* Candidates to emit: gui-agent lifecycle (init, seamless switch, resolution change,
`AcquireNextFrame` 0x887a0026 keyed-mutex death, RecreateDuplication, QGADESKSTUCK), the wedge
watchdog heartbeat and last words, installer phase markers, IDD mode changes.

**Cautions, all real:**
 - it crosses an isolation boundary into a dom0-readable file. dom0 must treat it as DATA -
   sanitise before display (the helper strips control chars at the source too, but a hostile
   guest will not use the helper);
 - volume is unbounded from dom0's side; a chatty or hostile guest can grow that log. Phase
   markers and failures only, rate-limited;
 - it interleaves with the interactive console session, so attached humans see it scroll past
   their prompt - hence the `[TAG] timestamp` prefix, so it is filterable;
 - user-mode and post-PnP: nothing before xencons loads, and nothing during a high-IRQL wedge.
   A KERNEL-mode writer (the agent's driver side, via XENBUS_CONSOLE at DISPATCH_LEVEL) would
   narrow the second gap and is the obvious follow-up if wedge last-words are the goal.

**NOT DONE, and it is the owner's call:** wiring this into the gui-agent as a log sink. That is a
change to shipped agent behaviour and adds a guest->dom0 emission path, so it wants an explicit
decision rather than being slipped in as instrumentation.

## 2026-09-01 — what Windows-native text streams are worth plugging into the console ring

Measured on win10-app first, because every option below is gated on config this guest does not
have:

    bcdedit {current}: no `debug`, no `ems`, no `bootlog`      debugtype = Local (no wire transport)
    Debug Print Filter key: ABSENT   -> DbgPrintEx INFO-level output is suppressed by default
    Win32_SerialPort: NONE           -> EMS/SAC has literally nowhere to emit
    C:\Windows\ntbtlog.txt: absent

So Windows currently emits nothing out-of-band by any route. Ranked candidates:

1. **`DbgPrint`/`DbgPrintEx` - the real `printk` analogue.** A kernel driver registers
   `DbgSetDebugPrintCallback` (Vista+, works with NO debugger attached) and forwards to the
   console ring. Content includes the Xen PV drivers' own logging, PnP/storage, and our IDD -
   i.e. the PV stack's own view of a wedge, which nothing else gives us. Being kernel-mode it
   also pairs with a kernel-mode ring writer, removing the user-mode dependency the PowerShell
   helper has. **Requires unmasking** `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\
   Debug Print Filter` (absent here, so a naive implementation would receive nothing and look
   broken). Costs: firehose volume; the callback runs at the caller's IRQL and must not block;
   and DbgPrint is a global serialisation point, so broad unmasking measurably slows the guest -
   which matters in a project whose whole point is measuring latency. API claims here are from
   documentation, NOT yet verified on this rig.
2. **EMS / SAC - Windows' own designed out-of-band console.** Boot progress, an interactive text
   shell, and `restart`/`crashdump` verbs, in the kernel, answering in states user-mode cannot.
   **But it emits to a SERIAL PORT and this guest has none** (measured above), so it is the
   emulated-serial route (`<serial type='pty'/>` -> stubdom console 3), not the PV ring. This is
   the strongest answer for wedge RESCUE specifically, and it is Microsoft's mechanism rather
   than something we invent.
3. **Bugcheck last-words** via `KeRegisterBugCheckReasonCallback`: a driver writes a final
   summary into the ring as the machine dies. Narrow but exactly on target for "what was
   happening when it went". Design care needed: that callback runs at HIGH_LEVEL with interrupts
   off, so the ring write must be lock-free with everything pre-allocated.
4. **ETW / Event Log forwarding**: the richest CONTENT (Kernel-Boot, Kernel-General, WHEA, disk),
   but user-mode consumers, so it dies with everything else - and the event log is already
   recorded here as silent during the wedge. Good for boot-phase and post-mortem-adjacent work,
   useless for last words.
5. **`bcdedit /set bootlog yes` -> ntbtlog.txt**: a file, not a stream. Low value.

**What does NOT exist, so nobody should go looking:** there is no Xen KD transport (no "KDXEN"),
and KDNET does not support the Xen PV NIC - so "attach a kernel debugger over the PV plumbing we
already have" is not available. Kernel debugging needs the emulated serial too.

**Ordering that follows:** (a) our own QWT text (gui-agent lifecycle) into the ring - possible
today with no new driver; (b) emulated serial + EMS/SAC, one dom0 libvirt change and one bcdedit
change, covering pre-Windows and bugcheck states the PV ring cannot reach; (c) kernel-mode
DbgPrint forwarding, most work and with a real perf caveat.

## 2026-09-01 — the main console log IS written; and INTERACTIVE SAC is not reachable on Qubes at all

Owner confirmed the SERIALMARK lines arrived in `guest-win10-app-dm.log`, closing the last hop:
**guest COM1 -> stubdom hvc0 -> a dom0 log file, with no dom0 change.** Also observed: "nothing
useful in main console log anyway". Two Qubes patches to qubes-vmm-xen explain both halves.

**1. `1004-systemd-enable-xenconsoled-logging-by-default.patch`.** Upstream xenconsoled defaults
to `log_guest = 0, log_hv = 0` - logging OFF. Qubes flips it:

    Environment=XENCONSOLED_ARGS="--replace-escape --timestamp=all"
    Environment=XENCONSOLED_TRACE=all

So the guest console ring **is** captured, timestamped, continuously. "Nothing useful in the main
console log" is not logging being off - it is Windows emitting nothing there, which is exactly
the gap `guest/console-write.ps1` closes. Bonus: `--replace-escape` rewrites ESC to a dot in the
log, which already blunts the ANSI-injection caution I raised earlier - a hostile guest can still
spam volume, but not paint someone's terminal. **Open, and worth one check: whether
`guest-<vm>.log` survives a domain restart or is truncated per boot.** The `[QWT] HELPER
VALIDATION` line was written before two subsequent reboots, so its absence would answer that
rather than contradict the mechanism.

**2. `0618-libxl-do-not-start-qemu-in-dom0-just-for-extra-conso.patch` - this RETRACTS what I told
the owner earlier.** I said interactive SAC "needs a dom0 libvirt change". It needs more than
that, and probably is not reachable at all. Qubes patches libxl:

    -    need_qemu = 1 || libxl__need_xenpv_qemu(gc, &sdss->dm_config);
    +    need_qemu = libxl__need_xenpv_qemu(gc, &sdss->dm_config);

with the commit message *"We prefer to have broken extra consoles (breaking also saving/restoring
HVM to a savefile), than running qemu in dom0."* Stubdom consoles 1-3 are left with
`consback = IOEMU` and **no qemu in dom0 to serve them**. So even after adding `<serial>` to the
libvirt XML - which would make libxl create console 3 - nothing would back it. Interactive SAC
(the `cmd` channel, `restart`, `crashdump`) would additionally require reverting a deliberate
Qubes security/complexity decision to keep qemu out of dom0. That is not a knob, it is a
disagreement with the platform, and it should not be pursued.

**Consequence - the two channels have clean, non-overlapping roles, and neither needs dom0:**
 - **PV console ring** (`guest-<vm>.log`): OUR structured telemetry. Clean channel, nothing else
   writes it, bidirectional if a human logs in. Use `guest/console-write.ps1` / an agent sink.
 - **Emulated serial via `qemu-extra-args`** (`guest-<vm>-dm.log`): WINDOWS' OWN output - EMS boot
   messages, SAC banner, and bugcheck text - with no forwarder to write. Write-only, and that is
   now understood to be the ceiling on Qubes, not a temporary limitation.
Both are captured by xenconsoled to files that survive the guest, and both are collected by the
wedge-forensics change made earlier today.

