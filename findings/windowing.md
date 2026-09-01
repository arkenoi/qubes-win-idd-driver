# windowing — findings

## CURRENT STATE

AUTHORITATIVE. Supersedes everything under History below. A correction belongs HERE,
not only as a new dated section — the whole reason this file exists is that 654
correction lines were buried chronologically in a 25k-line log, so reading a topic
top-down returned the stale answer.

- Not yet distilled from the history below. UNVERIFIED

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

## gui-daemon died again — and it was self-inflicted, by agent restarts

After ~9 gui-agent restarts in 20 minutes, the agent parked at `Awaiting for a vchan client`,
`qtest shot` returned **zero windows**, and it never recovered on its own. Sequence in
`gui-agent-20260804-134924-7504.log`: `libxenvchan_send: vchan not open` on `MSG_MAP`/
`MSG_SHMIMAGE`, then `WatchForEvents: vchan disconnected`.

**The sends failed because the vchan was already closed — the daemon went first. This is not a
protocol violation by the build under test**, and must not be recorded as one.

### Sharpened after a cold boot: ONE agent restart is enough

The first read of this was "~9 restarts wore it down". That is wrong and understated. After a
full qube shutdown/start the GUI came back healthy (fresh daemon, `SendWindowMap` x2, `qtest
shot` normal). **The very next gui-agent restart — stop watchdog, kill agent, copy the SAME
binary back, start watchdog — lost the daemon again**: `awaiting_vchan=1`, `total_mapped=0`,
`qtest shot` = 0 windows. Two for two, from a known-good starting state.

So the rule is: **gui-daemon does not survive a gui-agent restart, and nothing brings it back.**
Reproducible on demand, no Windows Update or other confound involved (guest offline throughout).

Practical consequences:
- **In-place binary swapping is not a viable test method for this component**, which invalidates
  the harness design used earlier today and in previous sessions. Each A/B side now installs its
  binary and *cold-boots the qube*, measuring the agent instance the fresh daemon connected to.
  Slower (~4 min/side), but it is the only sound method — and it makes every run a boot-path
  test, which CLAUDE.md requires anyway.
- Any "restart the agent to apply a fix" instruction in this repo or in QWT docs is, on this
  build, an instruction to take the qube's GUI down until it is rebooted.
- It strengthens the case that daemon fragility, not any one crash cause, is the real robustness
  gap — dom0-side, so Phase 3 discipline (design writeup before code). Worth an upstream issue
  on its own: an agent restart is a normal, expected event (upgrades, crashes, watchdog action)
  and should not be terminal for the qube's GUI.

---

## Retraction 1: "there is no graceful shutdown path for gui-agent.exe"

There is. `Global\QGA_SHUTDOWN` (`include/common.h:46`) is created at `main.c:3848` and is
`watchedEvents[0]` in `WatchForEvents` (`main.c:3483`); signalling it sets `exitLoop` and the
agent runs its real exit path. I concluded "force-kill is the only way" after `taskkill` without
`/F` left the process running for 20 s — but that posts `WM_CLOSE`, and gui-agent is windowless,
so of course it ignored it. **I tested the wrong mechanism and generalised from it.**

## Retraction 2: "one gui-agent restart kills gui-daemon" — too broad

Measured with the supported mechanism (`scratchpad/graceful-stop.ps1`):

```
STEP1 signalled=True event=Global\QGA_SHUTDOWN
STEP2 exited=True after_s=1            <- "WatchForEvents: exiting"
STEP4 respawned_pid=6492 new_log=True
STEP5 maps=6 awaiting=1 connected=1    <- a vchan client CONNECTED
qtest shot -> 3 windows in dom0
```

**The GUI survived an agent restart.** The correct statement is:

> A **force-killed** (`TerminateProcess`) agent restart loses gui-daemon. A **graceful** restart
> via `Global\QGA_SHUTDOWN` does not.

Every harness in this project used `Stop-Process -Force` / `taskkill /F`, so every GUI loss I
attributed to "restarting the agent" was **self-inflicted by the stop method**, not inherent.

## The limitation, stated not buried

**A scratch desktop is not Winlogon's secure desktop.** The real lock case is NOT measured, and
cannot be with the tools available: unlocking needs an interactive password we cannot supply, so
the state *after* a real lock is unobservable, and measuring only *during* the lock does not
discriminate (both builds are quiet then, for different reasons). So this result says "no effect
under the only desktop transition we can raise and return from", not "no effect ever".

If that path is ever shown to matter, reinstate the commit **with logging on both edges** so the
next person can actually test it — the absence of that logging is most of why this one cost so
much to adjudicate.

# 2026-08-06 (cont) — side borders: our own w0 configure carried (0,0) and MOVED the window

User pinpointed it: side borders vanished after the AGENT's snap following their resize.
Cause: the post-resize w0 MSG_CONFIGURE sent x=0,y=0 (upstream fullscreen semantics) and
the daemon obligingly moved the client to origin - left frame border at x=-5, off-screen.
Fix (agent bd6e8b8, deployed 110A4D46): remember dom0's window position from its own w0
configures (g_ScreenWinX/Y) and echo it back - the daemon resizes in place, never
repositions. Verified: snap 2544x1374 → 2550x1379 with client at x=5 (frame flush to the
screen edge, border visible). Also: resize service v4 (user-installed) nudges frames fully
on-screen after scripted resizes (windowsize never moves; stale positions clipped borders).

# 2026-08-06 (Office, visual) — Word runs; window-behaviour check needs SEAMLESS mode

Visual capture with Word open (instrumentation not needed - the screenshot is the evidence):
- Word 365 (evaluation) renders correctly through the agent: ribbon, styles gallery, the
  document surface and Office's own sign-in modal all paint cleanly, no tearing, no stale
  bands. **That modal is Office's activation prompt** - it is what blocked the unattended
  flow the user observed, not an installer defect.
- **The compound-window (shadow-strip) question cannot be answered in this configuration**:
  the guest is in FULLSCREEN mode (SeamlessMode=0, the T2 configuration), so dom0 receives
  ONE window containing the whole desktop - there are no per-window frames to count. The
  2A-chrome acceptance (Office shadows dropped, toasts kept) is a SEAMLESS-mode test and
  must be run with SeamlessMode=1.
- Tooling note: `dump-windows.exe` is INTERACTIVE ("Press ESC to exit"), so it produces no
  output when run from a scheduled task - it needs a non-interactive/oneshot flag before it
  can serve as an automated probe. The session-0 limitation is real but secondary to this.

## 2026-08-07 — seamless maximize overflows the dom0 workspace (user-reported); mechanism measured

User: "why is the window maximized beyond workspace area (same as the snapping bug we fixed
in non-seamless mode)?" All numbers below measured on win-idd-test (live guest + agent log).

Three separate mechanisms, two real defects:

1. **First ~3.5 min after boot the work area is INFERRED and under-margined.** Until dom0's
   real work area + frame extents arrived (23:54:52), WaCompute fell back to origin
   inference: `(0,31)-(5120,1440)` — zero bottom/right margin. Windows maximized during
   that window overflow the dom0 workspace bottom. Self-corrects only when the next apply
   fires WaRefitProc; windows launched later use the good value.
2. **Maximized windows carry Windows' invisible resize borders (~7 px at 96 dpi, ~10 px at
   150 %) that overhang ALL screen edges** - measured: work area `(5,56)-(5115,1435)`,
   Word zoomed rect `(-6,45)-(5126,1446)` (DPI-descaled). The agent maps the RAW rect
   into dom0, so even a correctly maximized window paints past the dom0 screen/workspace
   edges. The Linux agent clamps zoomed windows to the work area; ours does not yet.
   **Fix class: clamp IsZoomed windows' reported geometry to the applied work area.**
3. **Permanent Explorer-vs-agent work-area battle**: Explorer recomputes
   `(0,0)-(5120,1380)` from its own taskbar and overwrites the agent's value; the drift
   check re-asserts every 2 s. Converges but churns; the log shows the fight continuing
   for minutes. Also transient `SPI_SETWORKAREA` 0x57 during resolution changes (rect
   validated against the old screen) - benign, self-healing, but noisy.

Also answered: Word comes up maximized because Office persists its window state - normal.
The DPI part of the report is already fixed in source (EDID image size undefined, pending
driver rebuild in the queued release build).

Disposition: recorded as KNOWN ISSUE for this release cycle; the clamp fix (2) reopens the
agent binary during release qualification, so it goes in the next agent build together with
a re-run of the seamless gate. (1) is mitigated by the same clamp; (3) tracked.

## 2026-08-07 — CORRECTION to the seamless-maximize entry above: two claims RETRACTED, one confirmed

An in-source + live investigation (scratchpad/seamless-office-defects.md) refuted the two
loudest claims in the previous entry and in my report to the user:

- **RETRACTED: "the desktop window is mapped in seamless mode".** It is NOT - window 0 is
  unmapped by SetSeamlessMode at boot (main.c:1942 path; boot log confirms). The claim came
  from an instrument bug: the fullshot geometry list enumerates X windows via
  `xwininfo -root -tree` WITHOUT reading Map State, so a withdrawn window is
  indistinguishable from a mapped one. Harness fixed (dom0/07, new `mapped` column) -
  dom0 needs a one-time re-install of that script.
- **RETRACTED: "Word's main frame is never mapped".** All Word frames were mapped with
  per-window buffers; the hwnd I chased (0x2032C) is a 5 px MSO_BORDEREFFECT shadow strip,
  CORRECTLY rejected - silently, because that rejection logs at Verbose while the deployed
  level is Info. (Also noteworthy: these strips were UNOWNED on this build, so the
  style-based rule would not catch them; the class rule is load-bearing.)
- **CONFIRMED (the real defect): the WS_MAXIMIZE clamp used screen bounds, not the applied
  work area** - maximized Word reported 5120x1395 against dom0's 5120x1384 work area
  (~11 px overflow + CONFIGURE ping-pong + grant rebuild), and before the dom0 work-area
  feed lands (~3 min into a boot) maximized windows genuinely ignore the dom0 workspace.
  This is the mechanism behind the user's "maximized beyond workspace" report. Fixed:
  agent branch workarea-clamp-maximize (WorkAreaGetApplied + clamp), needs build + gate
  re-run before it ships.

## 2026-08-07 — toast notification: mapped borderless over a maximized window (user-reported)

User: "a toast popped up in notepad window on win-idd-test, it certainly should not happen."

Measured, not inferred:
- dom0 geometry at that moment: `0x740018e 1524 667 396 373 ovr=1 "New notification"` -
  its OWN X window, override-redirect (borderless), at the bottom-right of the work area
  (work area (5,56)+1915x984 ends at 1920,1040; the toast ends at exactly 1920,1040).
- **Notepad's per-window buffer is CLEAN** (`qtest shot` -> win-0.png shows no toast pixels),
  so this is NOT capture contamination - per-window capture behaved correctly.
- Classification path: `IsPopup` (main.c:812) marks any visible window without WS_CAPTION
  (and without SYSMENU+APPWINDOW) as override-redirect. A toast has no caption -> borderless.

So the toast is drawn exactly where Windows draws toasts, but WITHOUT a Qubes border, which
makes it visually indistinguishable from the content of the window it covers.

**Open question the spec does not settle.** CLAUDE.md 2A-chrome 3c says toasts "must be KEPT,
mapped override_redirect" - what the code does today. But the same section's NOTE says that on
Linux qubes a notification arrives "as a normal bordered window". The user's report sides with
the NOTE. Not changed unilaterally: making toasts bordered is a one-line predicate change, but
the safe discriminator needs the toast's live in-guest attributes (owner, class, styles), and
an attempt to re-fire one for capture did not render (unregistered app id). Next step: catch a
naturally occurring toast with the winenum probe, then decide between "unowned windows are
never override-redirect" (principled: synthesis already assumes popups are owned) and a
narrower shell-notification class rule.

## 2026-08-07 — the two-disc "clean room" route is IMPOSSIBLE on Qubes HVM (measured, decisive)

Attempted per the user's directive ("if we can run unattended install with stock images, why
rebuild ISOs at all?"). It does not work, and the reason is at the platform level, not ours.

Run 1 - `qvm-start --cdrom=<stock ISO>` + answer disc assigned persistently
(`qvm-device block assign --option devtype=cdrom --ro`, assignment VERIFIED by a second
assign reporting "already assigned"): Windows Setup stopped at the **locale picker**, i.e.
`autounattend.xml` was never found. (Screenshot evidence.)

Run 2 - the decisive one. BOTH discs assigned as cdrom, VM started with NO `--cdrom`:

    SeaBIOS (version 1.16.2-1.fc41)
    Booting from Hard Disk...  Boot failed: not a bootable disk
    Booting from Floppy...     Boot failed: could not read the boot disk
    No bootable device.

The firmware sees **no CD-ROM whatsoever**. So `qvm-device block assign --option
devtype=cdrom` does NOT create an emulated IDE CD-ROM; it creates a Xen PV (xvd*) device.
Only `qvm-start --cdrom=` produces the QEMU-emulated, bootable CD. WinPE carries no Xen PV
drivers, so any assigned device is invisible to Windows Setup - which is exactly why run 1
found no answer file.

**RETRACTION of the 2026-08-06 entry** "stock ISO + separate answer disc ... a second virtual
CD is available". That conclusion rested solely on the assign COMMAND being accepted (rc=0,
"already assigned" on a repeat). Command accepted != device present in the guest - the same
"a check that cannot fail" pattern this file keeps recording. The route was recorded as
designed-and-verified when only its dom0 half had ever been exercised.

CONSEQUENCE: on Qubes HVM the answer file must live on the ONE booted CD, so unattended
install requires a repacked ISO. What can still be protected is how MUCH is changed - see
the minimal-repack note below.

## 2026-08-07 — OFFICE COMPOUND-WINDOW CHECK: PASSES in seamless mode (2A-chrome acceptance)

Blocked all session by an instrument bug, not by the product. `guest/office-window-check.ps1`
launches Word over qrexec, i.e. in **session 0**, which has no interactive desktop - WINWORD
starts and exits in ~2 s (`WORD_EXITED after 2s exitcode=0`), so the enumeration reported
`n=0` every time and the check silently proved nothing. Third instance of this trap today
(cpu-bench's load generator, the toast probe, this).

Fixed with `guest/office-window-check-interactive.ps1`: the enumeration is handed to a
scheduled task with `/ru user /it` so it runs in the interactive session.

**Measured, seamless mode, win-idd-test:**

    guest: OFFICE_HWNDS n=8   office_main_frames=3  office_shadow_candidates=4
    dom0 : Document3 - AutoRecovered - Word
           Document1 - AutoRecovered - Word
           Document3 - Word
           Sign in to set up Office          (a REAL Office dialog, correctly mapped)

Eight visible Word windows in the guest; **four** in dom0 - the three real document frames
plus the genuine sign-in dialog. **All four shadow-strip windows were dropped**, and no
document frame was lost. That is exactly the 2A-chrome criterion (Office chrome fragments
must not be presented as separate bordered qube windows), demonstrated on the real
application rather than on `tools/chromerepro`.

Note this could ONLY be shown in seamless mode - in fullscreen the whole desktop is one dom0
window and there are no per-window frames to count, which is why every earlier attempt at
this check was inconclusive.

## 2026-08-07 — SNAP REGRESSION: PASS in the fullscreen config (and why the first run "failed")

Ran `scratchpad/snap-regress.sh` against `win-idd-test` while it was still in SEAMLESS mode
(SeamlessMode=1, left over from Gate B) and got **FAIL on all three resize tests** - every
requested size came back 1920x1080.

That was NOT a regression, it was the wrong configuration: in seamless mode `SetSeamlessMode`
forces the HOST resolution on every StartFrameProcessing, so the guest cannot follow
per-window resize requests at all. The battery targets the T2 FULLSCREEN configuration where
the guest resolution follows the dom0 window. The tell was that T4 (position preservation)
PASSED while the three size tests failed identically - the agent working, simply not honouring
resize in that mode.

Switched to `SeamlessMode=0` in both registry keys, rebooted (back in 18 s), re-ran:

    feed: 0 31 5120 1409 5 5 25 5 -> bordered half = 2550x1379
    T1 near-half snap : PASS (2544x1375 -> 2550x1379)
    T2 20px-off no-snap: PASS (2530x1359 exact)
    T3 arbitrary no-snap: PASS (1803x957 exact)
    SNAP-REGRESS PASS

One item flagged, NOT swept up: **T4 position CHANGED** (x=3195,y=355 -> x=2565,y=56) on this
run, where it was preserved on the seamless run. The harness itself annotates it "WM may
legitimately clamp" - a dom0-window move to the snapped half can legitimately reposition it.
Recorded as unexplained rather than as a pass: it needs one run where the requested position
is inside the work area to distinguish "we moved it" from "the WM clamped it".

Process point, third time today: a check run in the wrong configuration produces numbers that
look exactly like a product failure. Same shape as the session-0 traps (benchmark load, toast
probe, Office check). Before reporting any FAIL, establish that the configuration under test
is the one the check was written for.

## 2026-08-07 — There is NO newer Qubes PV driver set; we are already on 4.3 sources

Checked instead of assuming, per the user's "check if there is a 4.3 qwt build first":

- **QWT installer: we already build R4.3.0.** `INSTALLER_SHA=14c189e4...` is exactly what
  `refs/tags/R4.3.0^{}` and `refs/heads/release4.3` point at in
  `qubes-installer-qubes-os-windows-tools`. The "4.2.2" string is QWT's product version, not
  its Qubes target. So the installer is NOT stale.
- **PV drivers: `release4.3` IS our pin.** `refs/heads/release4.3` = `388c821c` =
  `v4.2.0-1^{}`, i.e. the tag we already pin. And `main` (8cffcc09) pins the SAME driver
  submodules: xenbus `e76d03e3`, xennet `ad7717f6`, xenvif `9fd1afe4`. There is nothing newer
  to pull - main, release4.3 and our pin are identical for drivers.

So the "we are on 4.2 software on a 4.3 host" worry does not hold for the sources: they are
the current 4.3 ones.

**Where the inconsistency actually sits.** Fetched the pinned submodules from xenbits:
`xennet@ad7717f6` source declares `DEV_NET&REV_09000005` - matching the SHIPPED xennet binary.
So the shipped xennet is faithful to the pinned source. `xenvif@9fd1afe4` carries no literal
`0900000x` in its `src` tree (its published revision is constructed elsewhere - INF template
or version macro), so source alone did NOT settle what it publishes.

The one hard fact remains the runtime measurement: the SHIPPED xenvif binary enumerates the
NET child at `REV_09000004`. Two possibilities remain, and they are distinguishable by ONE
experiment:
  A. The pinned xenvif source publishes rev 5, and the PREBUILT binary in the QWT 4.2.2 RPM
     was built from an older tree -> **building xenvif from the pinned SHA fixes PV**, and
     the bug is that the RPM ships a stale xenvif.
  B. The pinned xenvif source publishes rev 4 -> the pinned PAIR itself is inconsistent and
     the bug is upstream in what Qubes pins.

**Next step (not done - needs an EWDK build):** build xenvif and xennet from
`9fd1afe4`/`ad7717f6` in CI, read the built xenvif's published NET revision, and if it is 5,
stage OUR built pair instead of the RPM's prebuilt drivers. That is a real change to
`qwt-full.yml` (it currently stages PV drivers bit-identical from the RPM and builds only
libxenvchan from this repo) and it forfeits the bit-identical property for a
security-relevant component - a deliberate tradeoff the user has now directed
("upgrade the driver instead").

## 2026-08-07 — media build: extract-and-repack replaced by graft-onto-mount (qvm-create-windows-qube's method)

User asked how `qvm-create-windows-qube` automates answer files. It repacks too - there is no
second-media trick - but its method is far better (windows/create-media.sh):

    genisoimage -udf -b boot.bin -no-emul-boot -allow-limited-size -graft-points \
        -o out.iso "$iso_mntpoint" "boot.bin=$boot_img" "Autounattend.xml=$answer_file"

i.e. loop-MOUNT the vendor ISO read-only and overlay files with `-graft-points`. Two wins:
no extraction, and `-udf` removes the >4 GiB file limit so `install.wim` is never split.
Our entire splitting apparatus existed ONLY because this box's xorriso has no UDF writer.

`mgmt/build-media.sh` implements it (genisoimage installed by the user). Measured:

    old builder: ~14 GiB transient, ~15 min, install.wim SPLIT to .swm
    new builder:  5.8 GiB output, 2m50s, install.wim UNSPLIT

Verified on the produced ISO, not assumed:
    autounattend.xml / diskprep.cmd / payload/release/install.cmd / sources/$OEM$/$1  present
    sources/install.wim  5,166,935,814 bytes, ORIGINAL 2023-05-05 timestamp (byte-identical)
    El Torito boot img   platform BIOS, bootable=y   (SeaBIOS-compatible)

**The vendor delta is now purely ADDITIVE** - previously the .swm split was a real change to
vendor content, and it is gone. This is as close to the untouched vendor media as the
platform allows.

TWO DEFECTS OF MINE, caught before use (both invisible to "the build succeeded"):
1. Passing `$MNT` as a plain path AND using -graft-points emitted the tree TWICE: 12 GiB
    output from a 5.8 GiB source. Fixed by grafting as `/=$MNT`.
2. The boot image was chosen with `find *.img | head -1`, which picked
    `eltorito_img2_uefi.img`. Qubes HVMs boot SeaBIOS and need `boot/etfsboot.com`, so that
    media would very likely not have booted. Fixed to take the BIOS image explicitly.
Neither was visible in the exit code or the log; the SIZE was the only tell, and the timing
alone looked like a success.

Still to prove: that this media boots and installs end to end. A correct-looking ISO that
does not boot is a failure mode this project has already hit (`CDBOOT: Couldn't find
BOOTMGR` after a layout change). The acceptance queued on it was refused by reprovision's
per-VM flock because the older-builder run still holds win10-clean - the lock working as
intended.

## 2026-08-07 — AUDIO: not shipped by QWT 4.2.2 at all, and Xen has no Windows audio path

User asked whether audio and clipboard are in the release, then whether Xen offers a better
audio path. Pinned down rather than assumed.

**Clipboard: IN, and asserted.** `clipboard_works` passes in the acceptance gate - the Qubes
handler runs (part of QrexecAgent/gui-agent, not a separate MSI feature) and the Windows
clipboard round-trips a marker. Scope limit kept in the check's own output: the dom0<->guest
transfer needs Ctrl+Shift+C/V, a human keystroke pair, so that last hop is NOT asserted.

**Audio: NOT SHIPPED, and it is not our ADDLOCAL dropping it.** Scanned the release MSI for
feature identifiers in BOTH ascii and utf-16:

    PvDriversCore   ascii      <- our selected features are present as plain strings,
    Autologon       ascii         so the scan can see feature names
    Audio           ABSENT (both encodings)
    Sound           ABSENT
    Wave / Mixer / Endpoint / pacat   ABSENT

So QWT 4.2.2 contains no audio component to select. On the guest this shows as the
QEMU-emulated `High Definition Audio Device` present and OK, with only QdbDaemon /
QrexecAgent / QubesGuiWatchdog running - nothing bridges that device to dom0.

**Xen's PV sound is not the route.** The complete Windows PV driver family on xenbits is
xenbus, xencons, xenhid, xeniface, xennet, xenvbd, xenvif, xenvkbd - **no audio driver**.
Xen's `sndif` (vsnd) protocol exists with Linux frontends (embedded/automotive), but no
Windows frontend, and Qubes does not use sndif anyway: Linux guests run pulseaudio over
**vchan** (`pacat-simple-vchan` <-> the dom0 audio daemon). dom0 expects a vchan stream, not
a Xen sound ring.

**Therefore a Windows audio agent is a vchan user-mode program, not a driver** - a sibling of
gui-agent, not a PV driver port. Encouragingly the hard parts already exist here: vchan from
Windows is proven (every frame ships over it) and `libxenvchan` is already built by our CI
for the agent. Shape: WASAPI loopback capture of the default render endpoint -> PCM over
vchan for playback; a capture path for the microphone. Before committing to a protocol,
read what `qubes-audio-daemon` expects on the dom0 side.

POST-FREEZE. This is a feature, not a fix, and needs a dom0-side counterpart to be useful.

## 2026-08-08 — RETRACTION: "QWT 4.2.2 has no audio" was wrong

I concluded on 2026-08-07 that audio is "absent from QWT 4.2.2 entirely" after scanning the
MSI for audio-related strings in both ASCII and UTF-16 and finding none. The scan was correct;
the CONCLUSION did not follow. Absence of an audio component in Windows Tools says nothing
about whether the guest has audio, because the audio path is not QWT's at all.

Measured on win10-clean (Get-CimInstance Win32_SoundDevice / Win32_PnPEntity):

    SND   High Definition Audio Device    OK  err=0
          HDAUDIO\FUNC_01&VEN_1AF4&DEV_0022&SUBSYS_1AF40022
    MEDIA High Definition Audio Controller    err=0
          PCI\VEN_8086&DEV_2668&SUBSYS_11001AF4
    MEDIA Speakers (High Definition Audio Device)   err=0
    MEDIA Line In (High Definition Audio Device)    err=0

VEN_1AF4 is Red Hat/QEMU: this is QEMU's emulated Intel HDA, bound by an inbox Windows driver,
with working endpoints. `qvm-prefs <vm> audiovm` is set (dom0), and the stubdom QEMU carries
`-qubes-audio:audiovm_xid=` to route it.

So: audio EXISTS and is emulated. QWT ships no audio component because it does not need one.
The earlier "post-freeze: build an audio agent" note was premised on a non-existent gap; what
would actually be on the table is PV audio to replace an emulated path that already works,
which is a performance/latency question, not a missing-feature one.

Also corrected in the same pass, per the user: the DOUBLE CURSOR is a genuine stock QWT
defect in all modes, not merely a regression this package introduced. Seeding DisableCursor=0
made it unconditional here, but stock exhibits it too, so the fix belongs in the user-facing
list as an improvement over stock rather than only in the self-inflicted-regressions list.

---

## 2026-08-08 — the coalescing fix was unmeasurable; RDP's plug points; z-order

### The counter that could never pass its own acceptance criterion

`g_PwSkippedCaptures` — added with the screen-content coalescing fix — was incremented in the
frame loop (`main.c:3344`) and **read by nothing**, under a comment claiming it was "exposed so
the effect is measurable". It was not. QGAPERF's existing `skip` field is a *different*,
pre-existing counter (`g_SkippedFrames`: capture-thread frames that arrived with no dirty
rects), so nothing in the record ever reflected the fix.

Worse, `validate-coalesce.sh` listed "1. `g_PwSkippedCaptures` > 0 — the new path actually
fired" in its header as a PASS requirement and **never implemented it as a check**. The run
could only ever compare CPU. This is the exact failure mode CLAUDE.md warns about: a check that
cannot fail is worthless, and one that was never written is worse, because the header made it
look covered.

Fixed with `PerfNotePwDecision(BOOL skipped)` recording BOTH outcomes as `pwskip`/`pwcap`
(`PERF_RECORD_VERSION` 2 → 3). Both halves are required: the claim is a RATE — captures avoided
over captures considered — and a skip-only counter cannot express one, since it only grows with
how long the workload ran.

### Where RDP actually plugs in (design question from the user)

The premise "remote windows do not have occlusions" needs one correction, and the correction is
the useful part: **RemoteApp does not eliminate occlusion, it synchronizes z-order.** The client
reports the stacking it shows; the server orders its session windows to match. Remote windows
look non-occluding because a RemoteApp session normally contains *only* the remoted apps. The
known artifact proves it — interleave a LOCAL window between two remote ones and RemoteApp
cannot represent it, because the server holds a single z-order.

We already stand in two of RDP's three plug points: pixels (a remote session's display path is
an indirect display driver — the IddCx framework Track B builds; TO VERIFY by enumerating
adapters inside a live RDP session) and window metadata (RAIL sends per-window orders over a
virtual channel; our agent does the same over vchan).

### Z-order: the transport exists, the information does not

Checked in source rather than assumed:

- **Bidirectional messaging already exists.** `vchan-handlers.c:783-810` dispatches daemon →
  agent `MSG_KEYPRESS`, `MSG_BUTTON`, `MSG_MOTION`, `MSG_CONFIGURE`, `MSG_FOCUS`, `MSG_CLOSE`,
  `MSG_KEYMAP_NOTIFY`, `MSG_WINDOW_FLAGS`, `MSG_DESTROY`, `MSG_WINDOW_DUMP_ACK`.
- **No stacking message exists** in the protocol enum (`qubes-gui-protocol.h:136-166`).
- **dom0 manages stacking only among its own X windows**: `restack_windows()`
  (`xside.c:3449`) does `XQueryTree` + `XRestackWindows` locally, for override-redirect windows
  on map, and sends nothing to the guest. The guest never reports its z-order either. The two
  orders are independent and coincide only because both follow the user's clicks.
- **The one exception is `MSG_FOCUS`**, handled at `vchan-handlers.c:689` with
  `SetForegroundWindow(window)` — and a commented-out `BringWindowToTop(window)` on the next
  line.

So full N-window sync is a protocol addition (Phase 3), but partial sync already exists. Since
`PwScreenUnchanged` refuses the fast path for any covered window, occlusion IS the fix's
ceiling — making this measurable rather than arguable. Put the raise behind registry DWORD
`FocusRaise` (default 0 = historic) so both conditions measure on ONE binary, and logged
`QGAFOCUSRAISE on|off` so every captured log states its own condition. A nil result is expected
and is a result: `SetForegroundWindow` usually raises already.

Design written up in `DESIGN-nonoccluding-desktop.md`, including the user's strongest objection
— allocation that scales with desktop size — which reordered the experiment list so the
desktop-size sweep is kill-first. Of the three candidates, the two that do NOT enlarge the
desktop (per-window WGC capture, z-order sync) are the ones worth pursuing.

### Harness defects found and fixed the same day

1. `validate-coalesce.sh` asserted the agent hash ~4 minutes after first qrexec contact —
   racing the firstboot QWT install and its reboots. Logged `up after 2006s`, then an empty
   hash and a vchan timeout, and reported it as "running agent != fixed". The build was fine.
   Replaced with a deadline poll that tolerates qrexec dropouts (the expected signature of the
   reboot), without weakening the gate.
2. CI failed with `upload-pack: not our ref` — the `agent/` submodule commit was never pushed.
   Not a compile error, which the first read of the log had assumed.
3. `win11-fresh` then wedged: Running, qrexec dead ~30 min, `qtest shot` returning an EMPTY tar
   (no mapped windows, so no gui-agent). Recovered by kill + restart. Judge output, not logs.
4. A binary-content probe reported `pwskip`/`pwcap`/`QGAFOCUSRAISE` ABSENT from a green build.
   False alarm: the literals are UTF-16 in the PE and `strings` was reading ASCII. Retained the
   check in `run-fix-validation.sh` with `strings -e l`, because a green build whose binary
   lacked the counters would yield an empty hit rate that reads like "the path never fired".

### Operational hazard: never edit a bash script that is currently running

Caught before it caused damage, recorded because this project runs multi-hour harnesses while
their scripts are still being iterated on, so it will recur.

`scratchpad/run-fix-validation.sh` was executing (pid 1268334, 26 minutes in, inside step 1)
when it was edited to add a fourth step. Bash does **not** read a script into memory up front:
it reads lazily and remembers a byte offset. Inserting lines shifts every later offset, so when
the interpreter next reads, it resumes mid-token and executes whatever now sits at that
position - silently, and with the shell's full privileges.

The file was restored to its committed bytes (`git checkout --`) while the run continued
unharmed. The follow-on step was then run as a SEPARATE invocation instead.

Rules that follow:
- an edit to a script is safe only when nothing is executing it - check with `ps` first;
- to extend a running pipeline, launch the new stage as its own process when the current one
  finishes, rather than appending to the file it is reading;
- committing the script first makes `git checkout --` an exact byte-level undo, which is what
  made this recoverable at all.

---

## 2026-08-08 (late) — the Windows 11 overhead is mostly AMBIENT

### The number that reframes the whole chase

Windows 11 presents **18.75 fps with no input at all** (30 s idle, 3 reps: 563/603/460
frames), each carrying ~350k real dirty pixels, `empty=0` — genuine repaints, not cursor-only
frames the agent already drops for free.

That is **77% of Windows 11's own 24.4 fps workload rate**, and more than Windows 10's *entire*
workload rate of 12.9 fps. So the 488-vs-259 controlled comparison that started this
investigation was largely measuring background repaint, not input handling. The surplus is
ambient: it happens whether or not anyone is touching the machine.

It also explains the idle CPU row that had looked anomalous — ours 0.343 vs stock 0.000. Stock
captures one composited screen and shrugs at ambient repaint; our per-window `PrintWindow` pays
for every one, at idle, indefinitely.

The load-bearing comparison is *within* Windows 11, so no Windows 10 idle number is needed. An
earlier note calling the finding "one-sided" because `win10-clean` never answered was
overstated and is withdrawn.

### Desktop effects are ruled out

Frame counts with effects off moved +2% to +9% — inside 9–25% run-to-run noise, and in the
*wrong* direction. Transparency/Mica/animations do not cause the surplus.
`guest/disable-visual-effects.ps1` stays in the tree (it is harmless and arguably correct on a
GPU-less guest) but it is not the lever, and must not be presented as a performance fix.

### The mechanism, now separable

    our CPU  ~  (presents Windows generates)  x  (our per-present, per-window cost)
                 ~19/s ambient + workload         PrintWindow, 15-18 ms on WARP

Stock is cheap in the second term, so the first barely hurts it. We are expensive in the
second, so the first dominates us. Both are worth attacking; neither substitutes for the other.

### The coalescing fix was never actually tested

`PwScreenUnchanged` opened with `if (!fb || pitch == 0 || !g_ZOrderValid) return FALSE`.
`CollectZOrder` (`main.c:2754`) deliberately skips its `EnumWindows` pass unless an
override-redirect popup is visible — "a second or two at a time" — because paying it per frame
cost roughly 4x the Phase 2A drag figure, and sets `g_ZOrderValid = FALSE` when it skips.

So in any ordinary workload the check refused **every single call**: 0 skips in 5557 decisions.
The null CPU result (all three deltas inside their own run-to-run spread) was measuring
nothing, not measuring a small effect. The premise is untested, **not** falsified — an earlier
reading that it might be falsified is withdrawn.

Replaced with an order-free test: if no other visible window's rectangle intersects this one,
nothing can cover it whatever the order is; paired with "is the foreground window" so a
full-screen window *below* (the shell desktop) cannot veto everything.

### Instrument defects found the same evening

1. **A `0.0%` that meant "the code never ran".** Fixed by counting refusals per cause
   (`pwnofb/pwnoz/pwoff/pwocc/pwnofg/pwovl/pwfirst/pwchg`), so an undifferentiated zero cannot
   recur. Only `pwchg` supports "the present was real"; everything else is the check declining
   to look.
2. **All four analyzers mis-parsed the phase markers.** The real format is
   `### PHASE-START <name> <ts>` — with a `###` prefix. Every one assumed field 0 was the
   keyword and field 1 the name, so phase lookups silently found nothing and reported "No usable
   data" for the win11 idle run whose data was perfect. The shell side used `awk '{print $NF}'`
   and was correct throughout, which is why the harnesses ran happily while analysis came back
   empty. Re-running the fixed parser over already-collected data cost no guest time and
   produced the 18.75 fps result above.
3. **A PASS criterion that could not fail.** `validate-coalesce.sh` compared single medians
   against a historical, non-interleaved baseline with no noise test, and printed
   "typing improved AND drag not regressed: True" for deltas of −1.8%, −9.9% and −3.6% against
   spreads of 9.7%, 15.6% and 29.2%. That verdict was retracted.
4. **An A/B that produced zero valid points**, because qrexec runs unelevated on clean-room
   guests — a wall documented in `win11-idd-vs-bda.ps1` months earlier and walked into anyway.
   The harness refused to fabricate numbers, which is the one thing that went right.

---

## 2026-08-11 — qubes.NotifyUpdates from Windows: the payload crosses; the bug was ARGUMENT QUOTING

The in-VM updater's `Report-Availability` (report the available-update count to dom0 so Qube Manager
lights up "updates available") appeared unfixable across a long thrash — every attempt returned
qrexec exit 0 but the flag never set. VERDICT: not a payload/stdio problem, not `_dom0`, not policy.
It was that `qrexec-client-vm.exe`'s argument was being wrapped in double quotes.

Mechanism, from source (upstream/ro/qubes-core-agent-windows + qubes-windows-utils):
- `qrexec-client-vm.c` parses FOUR fields via `GetArgument()`: domain|service|user|localprogram.
  It does NOT bridge its own stdin; it hands a trigger to the local qrexec-agent over the named pipe
  `\\.\pipe\qrexec_trigger` and returns ERROR_SUCCESS(0) immediately. So **exit 0 means "told the
  agent", NOT delivered/allowed** - it is worthless as a success signal. The agent then does policy +
  vchan asynchronously and spawns the localprogram, whose STDOUT is the vchan to the dom0 service.
- `exec.c:GetArgument()` reads the RAW `GetCommandLineW()`, skips the exe path, then splits the REST
  on `QUBES_ARGUMENT_SEPARATOR` = `L'|'`. **It never strips quotes from fields.**

The bug: passing `qrexec-client-vm.exe "dom0|qubes.NotifyUpdates|user|cmd /c echo N"` (whole string
quoted, the natural instinct + what the relay does with @default) makes GetArgument split
`"dom0|...|cmd /c echo N"` INCLUDING the wrapping quotes -> field1 = `"dom0` (literal leading quote),
field4 = `cmd /c echo N"`. The daemon gets target `"dom0`, which is not a VM, and REFUSES it.
Proven in the guest agent log (Q:\Qubes Logs\qrexec-agent-*.log):
  req: domain '"dom0'  ... local command 'cmd /c echo 4242"'  -> HandleServiceRefused   (BROKEN)
  req: domain 'dom0'   ... local command 'cmd /c echo 4343'   -> (accepted, flag set)   (FIXED)
(The updates-proxy relay has the same latent artifact - it sends `"@default` - and only works because
@default tolerates the junk prefix; a literal `dom0` does not.)

FIX - pass the fields UNQUOTED so the command line reaches qrexec-client-vm clean:
- cmd/batch: escape the pipes, no wrapping quotes:  `qrexec-client-vm.exe dom0^|qubes.NotifyUpdates^|user^|cmd /c echo N`
- PowerShell (re-quotes any single arg with spaces, which would re-leak the quote): pass SPLIT tokens
  so the pipe-bearing token has no spaces and is emitted verbatim:
    & $qr 'dom0|qubes.NotifyUpdates|user|cmd' '/c' 'echo' "$count"
  -> command line `...\qrexec-client-vm.exe dom0|qubes.NotifyUpdates|user|cmd /c echo N`, fields clean.
The localprogram writes the count to STDOUT (cmd `echo N`); dom0's qubes-notify-updates `.strip()`s the
line, so CRLF is harmless. VERIFIED end to end 2026-08-11: user confirms Qube Manager shows updates
available for win11-fresh after the unquoted call. Wired into guest/qubes-windows-update.ps1
Report-Availability (split-token form). Policy is the stock default (@anyvm -> dom0 allow); no dom0
change was needed or made. The dom0 target is literal `dom0`, never `_dom0` (that underscore came
only from throwaway test scripts notify4/5.ps1, since deleted from the guest).

## 2026-08-11 (cont.) — **GHOST WINDOWS: dom0 keeps painting shell surfaces the guest has closed**

The user opened Start by hand and reported "on screen, but old one is there too" and "announced
geometry does not match REAL geometry either". Both are one defect, now captured with evidence.

STATE AT CAPTURE (win11-24h2, 24H2):
  dom0 (qtest fullshot geometry.txt)        |  guest (render-truth.ps1 EnumWindows)
  0x1c0018b 123,129  1426x746 or=0 mapped=1 |  Notepad        (123,129) 1426x746   <- real
  0x1c0018e 1524,700  396x332 or=1 mapped=1 |  ** ABSENT **                        <- GHOST (toast)
  0x1c00190  531,142  858x890 or=1 mapped=1 |  ** ABSENT **                        <- GHOST (Start)
The guest has ONLY Notepad + a cloaked 1905x4 strip + Progman. The Start menu and the toast were
closed/dismissed minutes earlier, yet dom0 still has them MAPPED and is still painting them.

MECHANISM (agent log, same guest): three windows were mapped and NEVER unmapped -
  20:22:43/45 SendWindowMap 0x60058   (twice)
  20:27:28    SendWindowMap 0x50086
  20:30:05    SendWindowMap 0x10184
with the last SendWindowUnmap at 20:22:12 (for a different hwnd, 0x2002a). So the agent announces
MAP for these override-redirect shell surfaces and never announces UNMAP when they go away. The
likely cause: Start/toast surfaces are not DESTROYED when dismissed - Start's CoreWindow goes back
to 1x1 + DWM-cloaked (measured: cloak=2 when closed). If the tracker drops a window that stops
being enumerable/visible WITHOUT sending UNMAP first, dom0 is left holding a mapped ghost forever.
That is the "double windows" artifact class in the QWT docs, and it is a strong candidate for
GWeck's S1a "garbled Start" (a stale Start ghost overlapping a freshly opened one).

CONSEQUENCE FOR EARLIER CONCLUSIONS: the 24H2 "Start renders correctly, geometry exact 858x890"
measurement stands as a measurement of the LIVE menu, but it must NOT be read as "Start is fine on
24H2" - the very window I measured is now a ghost. Correct rendering includes disappearing when
the guest's window disappears.

INSTRUMENT: `tools/rendercheck` now detects this automatically - any dom0 MAPPED window with no
guest counterpart is reported under `ghosts_in_dom0` and FAILS the run. Verified it catches both
ghosts above. This is the regression test the fix must flip to PASS, and it is exactly the kind of
defect a per-window pixel diff can never see.

FIX DIRECTION (fits the overhaul as a new rank, agent-side): the window-acceptance predicate must
treat "was mapped, is now cloaked / 1x1 / not enumerable" as an UNMAP event rather than a silent
drop; unmap-before-forget must be structural, the same way rank 3 made CREATE-once structural.
Note this interacts with the toast requirement (toasts must be KEPT while visible) and with the
user's two new requirements recorded below.

## 2026-08-11 (cont.) — INSTRUMENT: guest PIXELS are trustworthy, guest WINDOW LISTS are not

Built `guest/render-watch.ps1`: a resident sampler that decouples SAMPLING from RETRIEVAL. It runs
hidden and detached, writing a timestamped JSON sample (and optionally a PNG) every N seconds into
C:\ProgramData\Qubes\rendertruth; a later qrexec fetch cannot retroactively disturb a sample already
on disk. This removes the flaw that produced today's retracted "ghost window" claim (the on-demand
probe stole focus and closed the very menu it was measuring). Verified: samples every 2 s, Notepad
stays foreground across them, and both rects are recorded per window (Notepad dwm 1426x746 vs raw
1440x753 - the Win11 invisible border).

DEFINITIVE TEST of the ghost question, using the sampler's own PNG (no focus theft):
- dom0 geometry.txt: `New notification` 396x332 override_redirect=1 mapped=1  -> present
- guest EnumWindows sample at the same time                                   -> ABSENT
- guest FRAMEBUFFER at the same time                                          -> **the OneDrive
  toast is right there, fully drawn**
So dom0 is CORRECT and the toast is real. **The ghost claim is dead for good** (it was already
retracted; this closes it with positive evidence rather than doubt).

WHAT IS ACTUALLY BROKEN IS THE INSTRUMENT: our guest-side EnumWindows cannot see shell popup
surfaces. `SetThreadDesktop` fails for us even from a fresh windowless thread (tried: unloading
System.Windows.Forms, then running the whole enumeration on a dedicated STA thread inside the C#
helper - both still fail), so we never attach to the input desktop the way the agent does
(AttachToInputDesktop, main.c). Notably GDI CopyFromScreen DOES return the real composited desktop
including the toast, which is why the pixel evidence above is sound.
RULES GOING FORWARD:
 1. Guest truth for "is it displayed" = PIXELS (sampler PNG). Proven.
 2. Guest window LISTS are incomplete for shell surfaces (toasts, Start) - never conclude "the guest
    does not have it" from an empty list. `tools/rendercheck`'s ghosts_in_dom0 stays a hint only.
 3. dom0's `qtest fullshot` geometry.txt remains the authoritative list of what dom0 shows.
 4. To make the list trustworthy the sampler would have to run with the agent's privileges/desktop
    (a service, or launched via the agent) - deferred, not needed for pixel comparison.

## 2026-08-11 (cont.) — TOAST CROP: BUILT, DEPLOYED, MEASURED — WORKS MECHANICALLY, **OVERCROPS**

CI: run 31526572625, all three jobs green (gui-agent, idd-driver, package) - first proof the
toastcrop/UIA/COM code compiles at all (it cannot be built locally; both reviewers could only
inspect it). Artifact gui-agent.exe sha256 5b80f2e100aae67eb158bff04a924049aebec918c97af3dda264cbd50f22f79d.

DEPLOYED to win11-24h2 via guest/swap-agent.ps1 (elevated, .orig backup kept). **Installed binary
hash verified equal to the CI artifact before any measurement was taken.**

A/B ON THE SAME LIVE WINDOW (the persistent OneDrive "Turn On Windows Backup" toast - it outlives
an agent restart, so this is a real before/after on one window, not two similar ones):
    before (shipped agent): 1524,700  396x332
    after  (CI build)     : 1540,730  364x289
    => insets applied 16 / 30 / 16 / 13 - EXACTLY the values the plan's original guest probe
       measured on a collapsed banner. The mechanism works end to end: classifier, UIA query,
       cache, GetWindowData crop, and every downstream consumer followed it.

**BUT THE RESULT IS WRONG (defect, do not ship).** Judged by pixels, inside the new announced rect:
 - the toast's HEADER ROW is gone - the "OneDrive ... X" bar, including the CLOSE BUTTON;
 - a strip of desktop wallpaper + the Windows build watermark appears along the BOTTOM.
So the announced rect is offset down relative to the real card: FlexibleToastView is the CONTENT
element, not the visible card. This is exactly the "silent overcrop clipping the 40x40 action
buttons" failure the plan named as the DANGEROUS one, realised on the header instead. The
plausibility guard did not catch it (364/396 = 92%, 289/332 = 87%, both far above the 40% floor)
and it cannot: an offset crop of the right SIZE is invisible to a size-ratio test.
Corroborating measurement from the earlier uncropped capture: the visible card's left edge is at
1526 (inset ~2), not 1540 (inset 16) - so the horizontal insets are wrong too, in the same way.

FAIL-SOFT CHECK PASSED (the plan's acceptance check, run for real): setting
HKLM\...\Qubes Tools\gui-agent\ToastCropDisable=1 and restarting the agent returned the toast to
1524,700 396x332 - today's uncropped-but-visible behaviour. **The escape hatch works, and the
guest has been left in that state**, so it is not sitting on the overcrop.

NEXT (measured, not guessed): the crop target must be the outermost visible XAML element (the card
including its header), not FlexibleToastView. Choosing it needs a UIA tree dump WITH bounding
rects from the live banner - and `guest/toast-uia-tree.ps1` (written today) CANNOT get it, because
a qrexec-launched process cannot see shell surfaces at all (the same input-desktop blindness
documented above: it printed NO-TOAST-WINDOW while dom0 had the toast mapped). The dump therefore
has to come from inside the agent, which is already on the input desktop - i.e. add a one-shot
"log every descendant + rect" debug flag to toastcrop.c and read it from the agent log.

## 2026-08-11 (cont.) — SEPARATE DEFECT: stale window border left on the dom0 screen
After the agent restart, the dom0 screen showed TWO red borders around the toast area: the live
one at the new 1540,730 rect AND a stale rectangle at the OLD 1524,700-1919,1031 coordinates,
persisting across captures ~1 min apart. dom0's geometry.txt lists ONLY the live window, so this
is not a mapped ghost - it is unrepainted pixels left behind when the old X window was destroyed.
This is very likely what the user saw earlier and described as "old one is there too". Not yet
diagnosed: whether the daemon fails to trigger a repaint of the exposed area, or the WM/compositor
does. Worth a dom0-side look before assuming it is ours - and if it is the daemon's, it falls under
the CLAUDE.md exception for defects outside QWT scope (report upstream, user approves the text).

## 2026-08-11 (cont.) — TOAST CROP IS CORRECT (two retractions closed)

UIA tree dump of the live banner, taken by handle (0x50086, read from the agent log - our
EnumWindows still cannot see shell surfaces, but UIA ElementFromHandle on a KNOWN handle works):
    window            1524,700 396x332
    ScrollViewer      1524,718 396x314
    FlexibleToastView 1540,730 364x289   <- insets 16/30/16/13
      OneDrive text   1580,742      |  Settings button 40x40 @1817,733
      X button 40x40  @1857,733     |  ... body, combo, action buttons
The header row and BOTH 40x40 header buttons are INSIDE FlexibleToastView. Overlaying that rect on
the guest's own framebuffer shows it hugging the drawn card exactly - rounded corners on the line,
header included, bottom edge just under the buttons.

**RETRACTION 1:** "the crop overcrops and clips the header/close button" - WRONG. The crop rect was
right; the render I judged was taken seconds after an agent restart, mid-recomposition.
**RETRACTION 2:** "the outer rectangle is a stale unrepainted border" - WRONG. It survived a forced
repaint (Notepad dragged over the area and back). It is **win11-fresh's toast**: the other test VM
is running the OLD agent, both guests are 1920x1080, and Windows places toasts at the same
bottom-right offset, so its uncropped 1524,700 396x332 window sits exactly around win11-24h2's
cropped 1540,730 364x289 one. geometry.txt filters by _QUBES_VMNAME, so each VM's list showed only
its own window and the overlap looked like a ghost.
METHOD NOTE: with two guests running, ALWAYS check the other VM's window list before calling
anything on the dom0 screen a ghost.

VERIFIED RESULT: with the CI build and the crop enabled, dom0 borders the toast at exactly
1540,730 364x289 = the visible card. The defect the user reported ("thin border, extra stuff within
rectangle") is FIXED on win11-24h2, and win11-fresh alongside it is the untouched control.
Still open: the crop keys on the undocumented class names FlexibleToastView/ToastView. A
name-independent rule (largest descendant strictly inside the window, or the union of descendant
rects) would pick the same element here and survive a rename - worth doing before this ships.

## 2026-08-14 — consumer-nag policies now re-assert at boot (and a correction)

Correction to what I said earlier today: `quiet-desktop.ps1` was NOT missing from the package.
`Install-QwtImproved.ps1` has always run it by default (`/noapptweaks` skips it). The OneDrive
popup seen in every experiment came from the pristine `win11-24h2` SOURCE IMAGE, which predates
that step - every clone inherits it. Not a packaging defect.

The real gap: the installer ran the script out of the setup payload, kept no persistent copy and
never re-asserted it. A feature update rewrites consumer surface (the reason the autologon guard
exists), and a TEMPLATE's AppVMs get fresh user profiles whose per-user half of these settings was
never written. Nothing existed to put any of it back.

Fix: persist `quiet-desktop.ps1` to `C:\Program Files\Qubes Tools\bin` and register
`QubesQuietDesktopGuard`, a SYSTEM boot task (PT1M) that re-asserts it.
`guest/apply-quiet-desktop.ps1` mirrors the installer block so tests exercise the shipped path.

    before           policy_key_exists=False  onedrive_running=1  adverts=unset
    after + reboot   DisableFileSyncNGSC=1    onedrive_running=0  adverts=0    (29 changed, 0 failed)
    guard validated  deleted the policy key + set adverts=1 -> rebooted -> both restored,
                     QubesQuietDesktopGuard Last Result 0

The probe was seen in BOTH states before being trusted, per the "no result counts until the
instrument is validated" rule.

## 2026-08-14 — LOCALIZED: bytes are lost in the qrexec/vchan hop to the Windows guest

Done the way it should have been from the start: instrument BOTH ends here rather than speculate
about qubes that do not exist. (For the record: the netvm is `core-net`; there is no `sys-net` and
no `sys-firewall`, and naming them wasted the user's time. See the `updates-proxy-bisect` skill.)

Setup: `/etc/qubes-rpc/qubes.UpdatesProxy` in this qube is a symlink to `/dev/tcp/127.0.0.1/8082`,
where a USER-owned tinyproxy already runs (`tinyproxy -c /home/user/updates-tinyproxy.conf`). Moved
it to 8083 and put `tools/proxy-bytecount-shim.py` on 8082, counting bytes both directions per
connection. tinyproxy does not log response sizes, which is why the shim was necessary.

CONTROL - this qube, through the same shim+tinyproxy: 80043 every time (3/3, then 6/6 earlier).

THE MEASUREMENT - guest with OUR RELAY REMOVED (guest/proxy-probe.cs: synchronous, no pool, no
drain, no teardown), fetching through the same instrumented path:

    this qube SENT    80454  80453  80457  80454  80454  80454     (all full, endU2C=eof)
    guest RECEIVED    80454  29044  80457  80454  80454  65644     (two truncated)

We sent 80453, the guest received 29044. We sent 80454, it received 65644. Every send completed
with a clean EOF in both directions. So the bytes leave this qube intact and arrive short: the loss
is INSIDE the qrexec/vchan hop, with no QWT updater code, no relay, no pool and no drain in the path.

ELIMINATED, all by measurement: tinyproxy (same instance serves a Linux client perfectly), the
network (control is 100% clean), dom0 policy (traffic flows), our relay and its pool/drain/teardown
(removed entirely), and any of today's edits (the known-working 61f0bcc build fails identically).

### Important correction to "NOT our code"

The transport here is the WINDOWS side of qrexec - `qrexec-client-vm.exe` and the vchan handling in
Qubes Windows Tools, which is precisely the component this project forks. So this is not a Linux
Qubes defect to report upstream; it is plausibly OURS in the QWT sense.

MECHANISM HYPOTHESIS, fitting all the evidence and not yet tested: a close-race that discards
in-flight bytes. A plain-HTTP response with `Connection: close` ends with the SERVER closing
immediately after the body, so any bytes still buffered in the vchan when that close propagates are
dropped. CONNECT/TLS never shows it because the client closes first and the stream is long-lived -
which is exactly why our own 4.8 GB .msu download was byte-perfect with zero resumes through this
same transport, while an 80 KB plain-HTTP fetch loses a random tail.

Predictions if true: loss grows with response size and with upstream speed, is absent when the
client closes first, and is absent for CONNECT. All are testable.

### Two process corrections from this episode

* I claimed "both ends instrumented" while my tinyproxy had never started - it could not bind 8082
  because the user's instance already held it, and `ss` showed THAT process, not mine. Check that
  the thing you started is the thing you are measuring.
* I reported "nothing in the guest's window" from a grep that silently found nothing because the
  log contains NUL bytes and grep treated it as binary. Use `grep -a` on proxy logs.

## 2026-08-14 (evening) — post 56 does NOT reproduce: an AppVM on a Windows template works

GWeck: "Starting an AppVM based on the Windows 10 template seems to start normally, but just
after finishing the startup, it shuts down silently." That path had never been exercised here -
every test in this project uses standalone qubes - so it was worth running before theorising.

    qvm-create --class AppVM --template win11-tpl --label red win11-app
    qvm-tags win11-app add win-idd-testbed
    virt_mode=hvm, kernel='', memory 8192, vcpus 4, qrexec_timeout 6000, netvm ''

RESULT: started at 17:52:55, Running and stable through five state polls over 2 minutes and for
the rest of the session; `qubes.VMShell` answered (`APPVM_OK`, hostname win11-idd-test); the IDD
was the sole active display at 1920x1080; Notepad opened and rendered in dom0 (screenshot).
Nothing about being an AppVM broke the guest.

Features are NOT copied to an AppVM and do not need to be: `qvm-features win11-app` is empty
while os/gui/qrexec/stubdom-qrexec/vmexec all resolve through the template.

WHAT THIS DOES AND DOES NOT SETTLE. It rules out "an AppVM on a Windows template is structurally
broken", which was the cheapest explanation. It does NOT clear his case: this template is
Win11 26100 carrying only the updater stack, not a Win10 template that has had the 4.3.1 package
installed. The remaining candidates are Win10-specific behaviour, or template state (a pending
servicing operation, or a profile that MoveUsers relocated onto the template's private volume,
which an AppVM does not inherit). The Win10 rig now provisioning is what can test those.

## 2026-08-14 (evening) — stock QWT is NOT Microsoft-signed either, so signing is not what costs us the extra reboot

Question raised by the user: do we need proper signing to collapse our two-reboot install to
one, and does stock QWT have it? Measured on the shipped stock artifact rather than assumed
(`/usr/lib/qubes/qubes-windows-tools.iso` from `qubes-windows-tools-4.2.2-1.fc41.noarch.rpm`):

  * the ISO contains exactly one file plus a README: `qubes-tools-4.2.2.exe` - which is why
    qvm-create-windows-qube globs for `qubes-tools-*.exe`;
  * that bundle has **no Authenticode signature at all** (PE certificate table size 0);
  * carving its Burn attached container out and extracting `installer.msi` gives 40 PE files,
    **all 40 signed**, and the signer of a native (kernel-mode) one is
    **CN="Qubes Windows Tools"** - a private certificate. DigiCert appears only as the
    TIMESTAMP authority, not as the issuer.

A kernel-mode driver signed by a private CA does not load on Windows 10/11 without testsigning,
exactly like ours. So stock QWT is in the same position we are, and an EV certificate or
Microsoft attestation signing is NOT what would buy a single reboot.

CONSEQUENCE. Our second reboot is a design choice, not a signing consequence. Stage 1 already
imports our cert into Root and TrustedPublisher, which is what makes driver INSTALLATION
succeed; only LOADING needs testsigning, and any single reboot that enables it satisfies that.
What actually forces our split is that the installer VERIFIES its own work inline - `devcon
install` then wait for the IDD to bind with ConfigManagerErrorCode 0 before disabling the VGA,
plus the PV-drivers-bound assertions - and none of that can pass before the drivers can load.

So collapsing to one reboot means moving activation and verification to a one-shot task on the
next boot, and accepting that the qube is handed back on emulated IDE/NIC and the Basic Display
Adapter until it is started again. That is what stock does, and it is what makes an UNPATCHED
qvm-create-windows-qube work: its flow restarts the qube exactly once and then waits forever
for os=Windows, which hangs on any installer that needs a second reboot.

## 2026-08-14 (night) — post 56 REPRODUCED, and it is ours: an AppVM's first boot has no GUI

Built the configuration nobody here had ever run - `mgmt/clone-to-template.sh win10-clean
win10-tpl win10-app`, i.e. a Windows 10 AppVM on a Windows 10 template carrying 4.3.2.

MEASURED, three fresh AppVMs (create -> start -> open Notepad -> screenshot):

    first boot   qrexec answers in ~40 s, session up, explorer.exe and notepad.exe running,
                 gui-agent.exe running in session 1 - and dom0 maps ZERO windows.
                 Agent log ends at: "WatchForEvents: Awaiting for a vchan client"
    second boot  windows map normally, Notepad renders (screenshot)

So the qube is alive and completely invisible. That is GWeck's post 56 shape ("starts
normally, but just after finishing the startup it shuts down silently") seen from our side:
a qube that appears to do nothing.

### Whose fault - answered by experiment, not by reading

On the failing first boot, with the qube otherwise untouched:

    net stop QubesGuiWatchdog & taskkill /IM gui-agent.exe /F & net start QubesGuiWatchdog
    -> windows appear immediately (screenshot, 20 KB tar vs 0 bytes before)

The dom0 gui-daemon is therefore present and willing the whole time. What is dead is the
vchan SERVER this agent opened on that first boot. Plausible mechanism, not yet proven: the
Xen devices are re-enumerated while Windows specialises itself into a new qube identity
(new SMBIOS/UUID, fresh private volume) AFTER the agent opened the server, leaving it
waiting on something the backend no longer knows about.

FIX (agent): after 90 s with no client that has ever connected, log why and exit so the
watchdog respawns the agent - the exact recovery the experiment performed, rather than a
narrower guess at re-initialising the vchan alone. A persisted counter
(`VchanFirstClientRestarts`) bounds it to three attempts so a guest that legitimately has no
daemon is not restarted forever; it is cleared when a daemon attaches.

NOT yet done: confirming the fix on a fresh AppVM built from a template carrying the FIXED
agent. Until that runs, this is a fix with a proven mechanism and an unproven end state.

### Also measured, same run

  * A Win10 AppVM's private volume is a FRESH empty disk: `dir Q:\` fails while
    `wmic logicaldisk` lists Q:, i.e. the volume exists but is unformatted, and MoveUsers'
    relocation therefore does not carry the template's profile over. The guest still logs
    in and works, so this is not the GUI defect, but it is worth its own look.
  * `GetWindowData: GetRealWindowRect failed with error 0x80070006` appears on the AppVM's
    working boot - windows disappearing between enumeration and query. Noise, but recorded.

### CORRECTION, same night: the variable was the TEMPLATE never having been booted

The acceptance run for the self-heal passed - and passed for the wrong reason, which the log
says plainly:

    [20260814.223900.252] WatchForEvents: Awaiting for a vchan client
    [20260814.223900.252] WatchForEvents: A vchan client has connected
    VchanFirstClientRestarts = 0

Same millisecond, and the restart counter never moved. The self-heal DID NOT FIRE, so it is
not what made this first boot work.

What actually changed between the 3/3 failures and this success: to install the fixed agent I
had to START win10-tpl, i.e. the template was booted for the first time. Every failing AppVM
had been created from a template that had NEVER been booted - it was built by cloning volumes
straight out of a standalone qube. And it fits the one case that always worked: win11-app came
from win11-tpl, a template that had been booted many times as the updater rig.

So the defect I reproduced is: **an AppVM created from a never-booted Windows template comes up
with no GUI on its first boot** - the guest still has to complete the specialisation its
template never did, and the agent's vchan server does not survive it. Booting the template once
removes it.

CONSEQUENCE FOR POST 56: this is probably NOT GWeck's bug. His template was certainly booted -
he installed QWT inside it. My reproduction shares the SHAPE of his report (a qube that starts
and then does nothing visible) but not necessarily its cause, and I am not going to present it
as his. What it is: a real defect in a path this project had never exercised, found by building
the configuration he described.

STATUS OF THE FIX: the self-heal in the agent (exit for a watchdog respawn after 90 s with no
client that ever connected, bounded to three attempts) is a defensible guard against an agent
that would otherwise wait forever - the manual version of exactly that recovery was measured to
work, 20 KB of window vs 0 bytes. But it has NOT been seen to fire on its own, so its PASS is
UNPROVEN and it must not be reported as fixing anything yet. Proving it needs a never-booted
template plus the fixed agent, which is the run to do next.

### SECOND CORRECTION: the never-booted-template explanation is dead too, and the trigger is unidentified

A never-booted template was rebuilt from the same standalone (this time carrying the fixed
agent) and two fresh AppVMs were started from it. Both connected instantly:

    [20260814.224329.489] Awaiting for a vchan client
    [20260814.224329.489] A vchan client has connected     VchanFirstClientRestarts = 0

So "the template had never been booted" does not explain it either, and the self-heal again
did not fire. Scoreboard for a fresh AppVM's FIRST boot:

    template cloned 19:15 (from a standalone that had just been through the
      SoloFaultInject runs and restore-rig's VGA devnode cycling)   3/3 NO GUI
    template cloned 19:42 (from the same standalone after a clean boot,
      an agent swap and a clean shutdown)                           2/2 GUI, instantly

The failure is real - it was observed three times, with the agent log stopping at "Awaiting
for a vchan client" and a manual agent restart curing it on the spot - but its TRIGGER is not
identified, and the most likely remaining suspect is the state my own display experiments left
in the source image before the first clone (devnode cycling, a disabled/re-enabled VGA, a
topology apply history), not anything about templates or AppVMs as such.

RECORDED AS: an unexplained, currently non-reproducible first-boot GUI failure with a known
recovery. Not offered as an explanation of post 56. The self-heal stays in as a guard against
an agent that would otherwise wait forever, with its PASS explicitly unproven - it has never
been seen to fire.

Next run that would settle it: clone a template from a standalone that has NOT been through
the display experiments, and separately clone one that has, and start a fresh AppVM from each.

## pre-logon window, which is exactly when he sees the pointer offset and the dead dialog

Rig rebuilt with `4.3.1+agent.c7ccb459aec9` - the identical package GWeck downloaded. The only
rig-side change is pre-setting xenbus_monitor AutoReboot from the answer-stick payload, without
which 4.3.1 cannot finish installing here at all.

FIRST RESULT, and it settles post 33 on his build: with the modal suppressed the same 4.3.1
package installed in **1008 s (~17 min)**, against a 70+ minute hang that never completed when
the modal was allowed to appear. Same package, same media, same rig, one variable. The dialog
was the blocker, not a symptom of something else.

SECOND RESULT, measured on 4.3.1 while the guest was still at the Welcome screen:

    ATTACHED=2
    SCREEN \\.\DISPLAY2 primary=True  {X=0,   Y=0,    W=5120, H=1440}   <- the IDD
    SCREEN \\.\DISPLAY3 primary=False {X=1920,Y=-768, W=1024, H=768}    <- the emulated VGA
    VIRTUAL 5120x2208

Two attached displays, the second at NEGATIVE Y, and a virtual desktop 768 px taller than the
screen the agent maps. Windows is free to place windows in that region, and dom0 never sees it -
which is precisely the stray 1024x40 override window (the guest's taskbar at x=1920) observed on
the dom0 desktop earlier today, and a mechanism for a pointer that does not land where it is
aimed.

After the user session starts, 4.3.1 converges to ATTACHED=1 on its own: the agent restarts into
the new session and its one-shot solo apply runs there. So on 4.3.1 the two-display state is
confined to the PRE-LOGON window - during the install and the boot that follows it.

WHY THAT MATTERS: that window is exactly when GWeck reports trouble. Post 54 says the pointer is
wrong on Windows 10 "only before the reboot after activation of the IDD driver", and post 33 is
a modal raised during the install that he could not click. One cause - a second display attached
while the agent maps only the first - accounts for both.

BEFORE/AFTER, same rig, same media:

    4.3.1   ATTACHED=2, second display at (1920,-768), persists through pre-logon
    4.3.2   the same arrival is detached within ~1.5 s, from the install itself:
              19:10:12  IDD solo: detach '\\.\DISPLAY3' -> 0
              19:10:12  IDD solo: OK - '\\.\DISPLAY2' is the sole active display
            post-install: ATTACHED=1, virtual 5120x1440

The WM_DISPLAYCHANGE re-assert is therefore doing the job it was written for, demonstrated
against the build that lacks it rather than only against itself.

STILL NOT REPRODUCED on 4.3.1: the black inactive window of post 54. This guest, on his exact
build, comes up at the Welcome screen and then to a working seamless desktop.

## 2026-08-15 — post 27.2 RESOLVED on a real stock guest, and the 0x7B mechanism is now pinned

The first stock-QWT baseline this project has ever built: Win10 19045, genuine Qubes Windows
Tools v4.2.2.0 from the vendor MSI, with the boot disk on the PV path -

    QWT      Qubes Windows Tools v4.2.2.0
    BOOTDISK bus=SCSI model=PVDISK
    SVC xenvbd Start=0

i.e. exactly the precondition Test-BootDiskOnPvPath exists to detect, which its own comment
admitted had never been seen live.

UPGRADE WITH THIS PACKAGE (4.3.2), single run, nothing hand-held:

    pv_boot_disk: true
    upgrade_mode: "in-place-msi-major-upgrade"   <- stock is NOT uninstalled at all
    INSTALL COMPLETE (no reboot from the installer - the single-shutdown change)
    reboot 1 -> guest boots. BOOTDISK bus=ATA  model="QEMU HARDDISK"
    reboot 2 -> BOOTDISK bus=SCSI model=PVDISK, QWT v4.3.2.0

So the upgrade DOES drop the boot disk back to emulated IDE for one boot - which is precisely
what the reporter described - and it returns to the PV path on the next boot. No 0x7B here.

WHY IT SURVIVED, and why his did not: on this image atapi, intelide, pciide and storahci were
all still Start=0, so a boot-start inbox driver was available the moment the PV path went away.
Windows demotes those drivers once xenvbd owns the disk; on a guest where that has happened,
the same intermediate boot has NO boot-capable storage driver and bugchecks 0x7B
INACCESSIBLE_BOOT_DEVICE - recoverable only through safe mode, exactly as reported.

FIX: the installer now re-arms the inbox ATA/AHCI drivers before msiexec on the IN-PLACE path.
An inline re-arm already existed, but only in the remove-then-install branch - which is not the
branch a version-bumped MSI takes, so it never ran here.

AND THE SECOND HALF OF WHY HE HIT IT: 4.3.0 and 4.3.1 shipped at the SAME MSI ProductVersion
(4.3.0), so Windows Installer could not treat the newer build as a major upgrade and the
installer had to REMOVE stock first - the dangerous path, with the PV disk driver going away
while nothing had re-armed the fallback. tools/cut-release.sh already enforces the version bump
that makes the in-place path possible; this run is what shows why that invariant matters.

Also observed, unchanged from 2026-08-14: the domain hung in Transient for ~3 minutes at the
post-upgrade reboot. Kill-and-start was safe and the guest came back correctly.

### VERIFICATION OF THE 0x7B FIX: the defect does NOT reproduce, so the fix is UNPROVEN

The user asked for the fix to be verified before moving on. It is not verified, and the
attempt is worth recording because it corrects my own claim from an hour earlier.

First attempt was VOID by construction: I ran it on win10-app, an AppVM, whose root volume is
discarded at every shutdown. The upgrade and the demotion were both wiped before the boot that
was supposed to crash, and the guest "booted fine" because it had reverted to stock
(QWT 4.2.2.0, atapi Start=0, marker file gone). An AppVM cannot test anything that spans a
reboot. Redone on the standalone guest, restoring the stock baseline by cloning win10-tpl's
root volume back over it.

    run 1  inbox drivers Start=0 (armed)    upgrade -> reboot -> BOOTDISK bus=ATA
                                            second reboot      -> bus=SCSI (PV), QWT 4.3.2
    run 2  inbox drivers Start=3 (demoted)  upgrade -> reboot -> BOOTDISK bus=SCSI, BOOTED,
                                            QWT 4.3.2.0, atapi still Start=3

So the boot disk's excursion to emulated ATA happened ONCE OUT OF TWO, and in the run where a
demoted fallback would have mattered it did not happen at all - the PV driver bound
immediately and the demotion was irrelevant.

WHAT THAT MEANS. My earlier statement - "the upgrade moves the boot disk off the PV path for
one boot" - was drawn from a single observation and is not reliable: it is intermittent. A
0x7B needs BOTH halves at once (the excursion AND a demoted inbox driver) and I have now seen
each separately, never together. The re-arm therefore stays in as cheap, idempotent insurance
against a transition that is real but not reproducible on demand - NOT as a demonstrated fix,
and it must not be described as one.

Still true and independently measured: the upgrade takes the in-place major-upgrade path and
never uninstalls stock, which is what removes the whole class of risk. The reporter's build
could not take that path, because 4.3.0 and 4.3.1 shipped at the same MSI ProductVersion.

### PROOF ATTEMPT, and the fix is REFUTED as written: there is no emulated disk to fall back to

Deterministic harness instead of waiting for the intermittent excursion: put the guest in the
state an uninstall of the PV disk driver leaves - inbox ATA drivers demoted, xenvbd disabled -
and see whether the shipped re-arm saves the boot. Baseline restored from a snapshot between
every run (win10-tpl root cloned back over win10-clean), so each run starts from identical
stock 4.2.2.

    RUN A  demoted inbox + xenvbd disabled, NO re-arm
           -> domain starts and is DESTROYED within ~50 s, twice in a row. 0x7B reproduced.
    RUN B  same + the shipped re-arm (atapi/intelide/pciide/storahci back to Start=0)
           -> ALSO fails. Domain up, executing (~4% of a core), qrexec never appears.

Why B failed is the part I had wrong. The disk inventory on a healthy stock guest:

    DISK \\.\PHYSICALDRIVE0 | XENSRC PVDISK SCSI Disk Device | SCSI | 80GB
    CTRL Intel(R) 82371SB PCI Bus Master IDE Controller | OK      <- controller present...
                                                                  ...with NO disk behind it

The Xen PV drivers UNPLUG the emulated disk: XENFILT masks the IDE channel
(XENFILT\Parameters!Internal_IDE_Channel = IDE). So when xenvbd does not load there is no disk
at all, and re-arming ATA drivers cannot help - there is nothing for them to bind to. The fix
as written addresses the wrong half of the problem.

    RUN C  re-arm + remove XENFILT's Internal_IDE_Channel (un-mask the emulated disk)
           + xenvbd disabled
           -> reaches WINDOWS AUTOMATIC REPAIR (user observed it on screen). Strictly further
              than A or B: WinRE loads, so a disk is visible again - but Windows still does not
              boot normally.

CONCLUSION. On this platform the 0x7B is not "no boot-start ATA driver"; it is "the PV disk
driver is gone AND the emulated disk it replaced has been unplugged". Nothing we can set from
inside the guest turned that back into a normal boot in these runs. The robust remedy is the
one already measured to work: DO NOT REMOVE THE PV DISK DRIVER during an upgrade - which is
exactly what the in-place major upgrade does, and what the ProductVersion bump makes possible.

The re-arm stays (it is idempotent and costs nothing, and it is a precondition for any recovery
that does restore the emulated disk) but it is NOT the fix and must not be described as one.
The claim "the installer now prevents the 0x7B" is WITHDRAWN.

### RUN E closes it: nothing from inside the guest recovers a removed PV disk driver

RUN D reached Windows Automatic Repair, which left open whether a normal boot would have
worked if Windows had not been diverting to recovery after repeated failures. RUN E removed
that confound (bootstatuspolicy ignoreallfailures + recoveryenabled No, so Windows attempts
the real boot) with the same arming - inbox ATA boot-start, whole Xen bus stack out of the
boot path. Result, seen on screen: "Your device ran into a problem and needs to restart".
Still 0x7B.

So the answer is not "re-arm ATA", not "un-mask the emulated IDE channel", and not "keep the
Xen bus stack out of the way". Once the PV disk driver is gone from a guest whose emulated
disk has been unplugged, nothing available from inside the guest brings it back.

### THE FIX: never remove the PV disk driver, and refuse the path that would

/acceptpvdiskupgrade is now inert; the gate is a hard refusal naming the reason and the
remedy. The design justification, which the user put more directly than I had: on an in-place
upgrade we do not touch the PV disk drivers at all - they are the same drivers. Our MSI is
rebuilt from the same upstream WiX sources as stock, so it carries the same UpgradeCode and
the same PV drivers, which is exactly why Windows Installer accepted it as a MAJOR UPGRADE
over genuine stock 4.2.2 today and the boot disk stayed on the PV path throughout. The
uninstall would have removed a driver the very next step reinstalls, unchanged.

The uninstall path is therefore reachable only when an in-place upgrade is impossible - the
installed product being NEWER than the package. There the correct answer is "install a newer
package", which is what the refusal says.

### The rule made explicit in code: the PV disk driver only goes UP or stays the SAME

User's framing, and it is the right invariant: an in-place upgrade never touches the PV disk
drivers because they ARE the same drivers. The only way a package can force them to change
downwards is a downgrade, and that is a real uninstall - the operation measured to leave the
guest with no boot disk.

So the installer now reads the version of xenvbd.sys FROM THE MSI'S OWN File table (no
extraction, stays correct when the payload changes), compares it with the running driver, and
refuses before touching anything if the package is older. Both halves tested on the guest:

    positive  PV disk driver: installed 9.1.0.0, package 9.1.0.0   -> INSTALL COMPLETE
    negative  PV disk driver: installed 9.9.9.9, package 9.1.0.0
              REFUSING: this package carries an OLDER Xen PV disk driver (9.1.0.0) than the
              one already running (9.9.9.9) ...
              guest untouched afterwards: QWT still installed, BOOTDISK still bus=SCSI

The negative case needs a hook (QUBES_FAKE_INSTALLED_PVDISK_VERSION) because our package and
stock carry the SAME xenvbd 9.1.0.0 - a real downgrade cannot be produced from the artifacts
that exist. Dead code when the variable is unset.

Bug found and fixed while testing, exactly the kind a dry read would have missed: the MSI File
table query emitted InvokeMember's return value into the pipeline, so the function returned
@($null,'9.1.0.0') and the [version] cast failed - the check degraded to a warning and let the
install continue. Visible only because the result JSON printed the array.

## 2026-08-16 — the Windows key: we killed the menu we recommended

`g_BlockMenuKey` shipped **ON** in 4.3.2 (`perf.c`, compiled default AND registry fallback). In
`HandleKeypress` it drops Super key presses and every key carrying the Mod4 bit, in seamless, before
`SendInput`. In seamless the taskbar HWND is never mapped, so that key is the ONLY entry point to a
Start menu — stock or Open-Shell.

We had already dropped the stock Start menu as unsupported (GWECK-STATUS #6/#7) and told the
reporter Open-Shell was the answer; he confirmed it working in post 55. Then we shipped a flag that
suppressed the menu we do not support by removing the one we recommend. Post 64: *"Neither the
Windows nor the Open-Shell menu can be used at all."*

Now opt-in. The mechanism is retained and is still correct for anyone who wants stock Start
suppressed. This is exactly the blast-radius gate: a change that DISABLES something must enumerate
what must still work, and everything we have ever recommended as a workaround is a permanent test
case.

## 2026-08-16 — window header experiments: what can be removed, and what it costs

Owner asked whether guest window controls can be removed without the window going unmanaged.

**Mechanism (why the first attempt unmanaged the window).** `IsPopup()` (`main.c:1181`):

    BOOL isPopup = !( HasFlags(entry->Style, WS_CAPTION) ||
                      (HasFlags(entry->Style, WS_SYSMENU) && HasFlags(entry->ExStyle, WS_EX_APPWINDOW)) );

A window becomes a popup -> `override_redirect` -> dom0 does not manage or decorate it, and it leaves
`_NET_CLIENT_LIST`. The earlier experiment stripped `WS_CAPTION` **and** `WS_SYSMENU`, i.e. BOTH
branches at once. **The earlier conclusion "removing the caption unmanages the window" is therefore
too strong and is corrected here**: either branch alone is enough to stay managed.

**Results on Notepad (standard Win32):**

| variant | styles | outcome |
|---|---|---|
| no controls, no icon | caption, **no** sysmenu | clean title bar, text only; **managed** (dom0 captured 20480 B) |
| no controls, **with icon** | caption + sysmenu, no min/max | icon kept, min/max gone, **close ✕ REMAINS** |
| **no title bar at all** | **no caption** + sysmenu + `WS_EX_APPWINDOW` | no guest header; menu bar becomes the top row; **managed** (888x594 captured) |

Icon-without-close is NOT achievable with styles: the icon IS the system menu, so it needs
`WS_SYSMENU`, and Windows always renders the close button when that bit is set. Only
`EnableMenuItem(SC_CLOSE, MF_GRAYED)` exists, which greys the ✕ rather than hiding it.

**dom0-initiated close still works** with `WS_SYSMENU` stripped - tested, because `HandleClose`
posts `WM_SYSCOMMAND/SC_CLOSE` and removing the system menu could plausibly have broken it:

| trial | closed |
|---|---|
| normal window, SC_CLOSE (control) | yes |
| sysmenu stripped, SC_CLOSE | yes |
| sysmenu stripped, plain WM_CLOSE | yes |

**Per-app behaviour - this CANNOT be a global default:**
- **Notepad** (standard caption): works as above.
- **Explorer** (`CabinetWClass`, standard caption + ribbon): caption strip removes the OS buttons
  cleanly; its Quick Access strip remains as the top client row. Acceptable result.
- **Edge** (`Chrome_WidgetWin_1`): **the minimise/maximise/close buttons are drawn INTO the tab strip
  as client content** (captured and confirmed visually). No style change can remove them, so a
  global rule yields a mixed look: Notepad/Explorer lose their header while Edge keeps a full one.

**UNPROVEN, flagged not asserted**: in the first Edge attempt the process count went 8 -> 0 right
after the style change, suggesting the strip kills Chromium. I could NOT reproduce it cleanly - a
control/strip pair was inconclusive because Edge would not reliably present a window with a fresh
`--user-data-dir` (control: 8 procs alive, window never found in 30 s of polling). So "stripping the
caption kills Edge" is a single observation, not a result. Do not repeat it as fact.

Harness note: an early enumeration returned one-character class names because `GetClassNameW` was
declared without `CharSet=CharSet.Unicode` and marshalled as ANSI. That is what made the Explorer
window look absent when it was present the whole time.

## 2026-08-16 — Edge's 3-dot menu: not synthesized, and it costs 46 full repaints/s

Owner's observation, confirmed and quantified. Captured live with the menu open (Alt+F):

    Edge main  hwnd=0x8039C   300,200  900x600
    menu       hwnd=0x120222  855,275  329x695   class Chrome_WidgetWin_2
               style=0x96000000 (WS_POPUP|VISIBLE|CLIPSIBLINGS|CLIPCHILDREN)
               ex=0x8000088    (NOACTIVATE|TOOLWINDOW|TOPMOST)   owner=0x8039C

**Why it is not synthesized.** `SynthOwnerQualifies` requires the popup to sit inside the owner's
GRANTED geometry within `SYNTH_OVERHANG_MAX` (12 px). The menu is **695 px tall against a 600 px
owner** and its bottom edge overflows by **170 px**, so containment fails and it can never be
composited into the parent buffer. It is announced as its own window instead. `IsPopup` then
correctly makes it override_redirect (no caption, no sysmenu, and far under the 90% screen guard), so
it should render borderless - the classification is right, the COST is the problem.

**The cost, measured from the agent log for that hwnd:**

| metric | value |
|---|---|
| damage events | 2889 |
| full-window (329x695) | 2889 - **100%** |
| span | 62.75 s |
| **rate** | **46 events/s** |

A static menu is therefore re-reporting its entire surface ~46 times a second, ~228k px per event.
Nothing in the menu is changing. Two mechanisms should have prevented this and did not: per-window
capture (the window appears not to be WGC-attached, so damage falls back to whole-surface) and the
redundant-frame detector (`g_RedundantFrames`, "damage reported, pixels identical").

**Design consequence for the header work**: any popup larger than, or hanging outside, its owner is
structurally excluded from synthesis. Menus that exceed the parent are normal in Chromium, so this is
not an edge case - it is the common path for browser menus on small windows.

Directions, none implemented or verified:
1. relax containment (synthesize with clipping, or grant the owner a buffer big enough for overhang);
2. attach per-window capture to override_redirect popups so damage is real instead of whole-surface;
3. find out why redundant-frame suppression does not fire here - if it worked, the 46/s would cost
   almost nothing regardless of the rect size.

## 2026-08-16 — winwatch on Explorer's ribbon: two synthesis races, and a hole in the 2A-chrome filter

Ran `tools/winwatch.cs` (new) while the owner drove Explorer. Explorer's Win10 ribbon is built on
**NetUI - the same framework Office uses** (`Net UI Tool Window`, `Net UI Tool Window Layered`,
`SCENIC_DROPSHADOW_WINDOW_CLASS`, all pid=explorer), so this is a genuine proxy for Office chrome
without an Office install.

**Churn**: 36 window creations in 92.8 s (~23/min) - 18 `Net UI Tool Window`, 17
`SCENIC_DROPSHADOW_WINDOW_CLASS`, 1 layered. Each is CREATE + MAP + repeated full-window DAMAGE.

**RACE 1 - shadows are orphaned ~117 ms after birth.** Six drop-shadow windows were created WITH an
owner (`synth=yes`, compositable into the parent) and lost it shortly after:

    0x000A0326  after 133 ms      0x000F0326  after 112 ms
    0x000B0326  after 131 ms      0x001403CA  after 117 ms
    0x000C0326  after 117 ms      0x001803CA  after 117 ms

Consistent to ~20 ms, so this is deliberate NetUI behaviour, not jitter. **This is the owner's
observed "synthesized with a lag, not right away"**: for the first ~117 ms the shadow is a child that
CAN be composited; after that it is an orphan that cannot. Whether the agent synthesizes it is
therefore a race against when it samples.

**RACE 2 - containment changes during life.** `0x00120326` (`Net UI Tool Window`) flipped
`synth yes -> NO` at +4650 ms when its owner moved, so a popup that was compositable stopped being so
mid-life. Synthesis eligibility is not a property of a window; it is a property of a MOMENT.

**They reach dom0.** Confirmed in the agent log - every orphaned shadow is announced:

    CREATE hwnd=0xc0326 ovr=1 style=0x8e000000 ex=0x08180028
    MAP    hwnd=0xc0326 ovr=1 transient=0x0
    DAMAGE hwnd=0xc0326 w=1123 h=93   (x15 more, ~17 log lines per shadow)

`ovr=1` so at least they are borderless, and `transient=0x0` confirms dom0 sees them as OWNERLESS.

**HOLE IN THE PLANNED 2A-CHROME FILTER (design finding).** The predicate documented at
`main.c:3055-3070` requires **`Owner != NULL`** to drop chrome, on the reasoning that "an unowned
top-level window is somebody's real UI (splash screens, HUD overlays) and is left alone". But these
shadow strips are orphaned ~117 ms in, so by the time they are long-lived they have **no owner** -
and the filter as designed would KEEP exactly the windows it exists to drop. The ownership test must
either be evaluated at CREATE time (before orphaning) or dropped in favour of the style/class shape,
which is unambiguous here: `WS_POPUP|LAYERED|TRANSPARENT|NOACTIVATE` with `alpha=ulw`.

**Likely visible artefact**: these are `UpdateLayeredWindow` surfaces (`alpha=ulw`), i.e. per-pixel
alpha drop shadows. Captured without alpha they render as opaque rectangles - which matches the
"weird override window on screen" the owner reported earlier in this session. NOT yet confirmed by
pixels; do not state it as established.

## 2026-08-16 — OWNER DECISION: popups rendering outside the parent are CORRECT, leave them

Owner, after driving Explorer: "right-click menu renders outside the window border so we can leave
it be."

So a popup that falls outside its owner is NOT a defect. It is announced as its own
override-redirect (borderless) window, which is exactly how the Linux agent and X11 menus behave.
This **retracts direction 1 from the Edge-menu entry earlier today** ("relax containment - synthesize
with clipping, or grant the owner a buffer big enough for overhang"). Do not pursue it:
`SYNTH_OVERHANG_MAX` stays at 12, containment stays strict, and the Edge 3-dot menu being
unsynthesizable is working as intended.

Synthesis is for popups that sit INSIDE the owner (Notepad's File menu: measured `synth=yes`), where
compositing avoids a separate window for something that is visually part of the parent. Outside that,
a separate window is the right answer.

**What remains actionable from the whole popup investigation is therefore ONE thing**: the 25
`SCENIC_DROPSHADOW_WINDOW_CLASS` decoration windows per session, which are pure `UpdateLayeredWindow`
per-pixel-alpha shadow with no alpha channel available in dom0, and which cost CREATE + MAP +
repeated full-window DAMAGE each. Those should be DROPPED, not synthesized. Everything else in the
synthesis path is behaving correctly.

Still open and NOT chased (owner: it was intended layout, not an artefact): the "rendering error"
seen mid-session was a false alarm. No pixel-level artefact from the shadow windows has been
demonstrated - the cost is measured, the visual harm is not.

## 2026-08-16 — guest title-bar hiding: BLOCKED, the agent cannot restyle user windows

Implemented as asked (default ON, `service.guestTitleBar` knob, inset-based discriminator), and it
does not work. Flipped to default OFF with the reason in the source.

**The discriminator is right and is proven**, from the agent's own log:

    HideGuestCaption: 0x20244: own-frame app (top inset 0), keeping its caption   <- Explorer, skipped
    HideGuestCaption: 0x1b0320: guest caption hidden (was inset 51)               <- Notepad, acted on

So Edge/Explorer/UWP (inset 0, but all carrying WS_CAPTION) are correctly excluded and only
OS-drawn captions are touched. That part stands and is reusable.

**The mechanism is refused.** After adding a read-back (the first build logged success while the
window kept its caption - intent, not outcome):

    caption strip DID NOT STICK (style 0x14cf0000 -> 0x14cf0000, prev 0, err 5)

`err 5` = ERROR_ACCESS_DENIED, on every window. Identities:

    agent   session=1 user=NT AUTHORITY\SYSTEM
    notepad session=1 user=WIN-IDD-TEST\user

**Control that identifies the cause**: the same `SetWindowLong` from a process running as
`WIN-IDD-TEST\user` succeeds (it is how the manual experiments earlier today stripped Notepad's
caption). Same session, same desktop - the difference is the account.

The agent is SYSTEM by DESIGN: `watchdog/watchdog.c:105-132` duplicates its own SYSTEM token,
sets `TokenSessionId` to the console session, and `CreateProcessAsUser`s the agent, so it can
attach to the input desktop. Running it as the user would break that.

**Routes, none taken:**
1. Impersonate the user around the call (`WTSQueryUserToken` + `ImpersonateLoggedOnUser`). Cheap to
   try, but USER32 validates cross-process window access against the PROCESS, not the thread token,
   so this is likely a no-op. UNTESTED - do not assume either way.
2. A per-user helper process the agent asks to restyle. New process, IPC and lifecycle - a real
   architectural addition for a cosmetic feature.
3. **CROP the caption out of what we announce** instead of touching the app: shift the announced
   rect down by the caption height, offset the capture, and translate injected input by the same
   amount. Needs no permissions we lack, cannot be fought by the app, and works uniformly.
   `toastcrop.c` is in-tree precedent for cropping a window's visible rect. This is the recommended
   route and it is a real piece of work, not a tweak.

The knob and the inset discriminator stay wired so route 3 (or a different identity) can reuse them.

## 2026-08-16 — guest title-bar hiding WORKS: helper runs as the window's owner

Retraction first: I concluded this was blocked and recommended the crop route. **Wrong.** The owner
pointed at an Explorer window (`0x102CA`) that had been sitting caption-less AND dom0-managed for
hours since a hand experiment - proof the end state was fine and only the caller's identity was
wrong. I had read past my own evidence.

**Three mechanisms tried, measured, in order:**

| attempt | result |
|---|---|
| in-process as SYSTEM | `ERROR_ACCESS_DENIED`, every window |
| impersonate the owner's token around the call | **also err 5** - USER32 validates window access per-PROCESS, not per-thread |
| one-shot copy of the agent launched under the owner's token | **works** |

So `HideGuestCaption` duplicates the target window's own process token as a primary token and
`CreateProcessAsUser`s the agent itself with `--restyle-caption <hwnd>` on `winsta0\default`.
Handled at the top of `WinMain` before any init: same signed binary, no new component to build,
sign or install. Fire and forget - the restyle keeps the outer rect (`SWP_NOMOVE|SWP_NOSIZE`), so
the geometry announced immediately after is correct either way.

**Verified end state**, all three app classes at once:

| window | inset | agent decision | outcome |
|---|---|---|---|
| Notepad `0x210320` | 51 | restyle helper launched | `cap=False app=True UNMANAGED=False`; menu row is now the top line |
| Edge `0x2E02B6` | 0 | own-frame app, keeping its caption | untouched, **8 processes alive**, tabs + its own controls intact |
| Explorer `0x20244` | 0 | own-frame app, keeping its caption | untouched |

Edge surviving is not luck: the inset discriminator never touches it, which makes the earlier
unreproduced "strip kills Edge" observation structurally moot rather than merely unrepeated.

**Keep-managed invariant, enforced in the helper too**: add `WS_EX_APPWINDOW` and VERIFY it before
removing `WS_CAPTION`, because `IsPopup()` calls a window an override-redirect popup unless it has
`WS_CAPTION` *or* `WS_SYSMENU|WS_EX_APPWINDOW` - so a partial failure would strand it outside dom0's
managed set with no decoration to move or close by. That state was produced accidentally today by a
TEST SCRIPT of mine that copied the style half and omitted the exstyle half (Notepad cap=0 sys=1
app=0, restored by hand). The invariant makes it unreachable.

Default ON; `qvm-features <vm> service.guestTitleBar 1` keeps the guest's own caption.

## 2026-08-16 — guest title-bar hiding: BLOCKED, the agent cannot restyle user windows

Implemented as asked (default ON, `service.guestTitleBar` knob, inset-based discriminator), and it
does not work. Flipped to default OFF with the reason in the source.

**The discriminator is right and is proven**, from the agent's own log:

    HideGuestCaption: 0x20244: own-frame app (top inset 0), keeping its caption   <- Explorer, skipped
    HideGuestCaption: 0x1b0320: guest caption hidden (was inset 51)               <- Notepad, acted on

So Edge/Explorer/UWP (inset 0, but all carrying WS_CAPTION) are correctly excluded and only
OS-drawn captions are touched. That part stands and is reusable.

**The mechanism is refused.** After adding a read-back (the first build logged success while the
window kept its caption - intent, not outcome):

    caption strip DID NOT STICK (style 0x14cf0000 -> 0x14cf0000, prev 0, err 5)

`err 5` = ERROR_ACCESS_DENIED, on every window. Identities:

    agent   session=1 user=NT AUTHORITY\SYSTEM
    notepad session=1 user=WIN-IDD-TEST\user

**Control that identifies the cause**: the same `SetWindowLong` from a process running as
`WIN-IDD-TEST\user` succeeds (it is how the manual experiments earlier today stripped Notepad's
caption). Same session, same desktop - the difference is the account.

The agent is SYSTEM by DESIGN: `watchdog/watchdog.c:105-132` duplicates its own SYSTEM token,
sets `TokenSessionId` to the console session, and `CreateProcessAsUser`s the agent, so it can
attach to the input desktop. Running it as the user would break that.

**Routes, none taken:**
1. Impersonate the user around the call (`WTSQueryUserToken` + `ImpersonateLoggedOnUser`). Cheap to
   try, but USER32 validates cross-process window access against the PROCESS, not the thread token,
   so this is likely a no-op. UNTESTED - do not assume either way.
2. A per-user helper process the agent asks to restyle. New process, IPC and lifecycle - a real
   architectural addition for a cosmetic feature.
3. **CROP the caption out of what we announce** instead of touching the app: shift the announced
   rect down by the caption height, offset the capture, and translate injected input by the same
   amount. Needs no permissions we lack, cannot be fought by the app, and works uniformly.
   `toastcrop.c` is in-tree precedent for cropping a window's visible rect. This is the recommended
   route and it is a real piece of work, not a tweak.

The knob and the inset discriminator stay wired so route 3 (or a different identity) can reuse them.

## 2026-08-17 — REGRESSION: the caption strip makes dom0 minimize the window. Default OFF.

Owner: "some movement of explorer window made notepad window switch to minimized."

**dom0 initiated it, not the guest.** From the protocol trace:

    HandleWindowFlags: 0x1a0284: set 0x4, unset 0x0     <- dom0 -> guest, WINDOW_FLAG_MINIMIZE
    HandleWindowFlags: 0x102ca: set 0x4, unset 0x0
    HandleWindowFlags: 0x1a0284: set 0x0, unset 0x4     <- later restored
    HandleWindowFlags: 0x102ca: set 0x0, unset 0x4

The agent obeyed (`ShowWindowAsync(SW_MINIMIZE)`), which is why it then logged
`UpdateWindowData: 0x1a0284 became minimized` and reported the state back. The guest never minimized
anything on its own - by the time it was inspected, `IsIconic=False` on every window.

**It hit exactly the restyled windows.** `0x1a0284` (Notepad) and `0x102ca` (Explorer "addins") both
carry `style=0x140f0000 ex=0x00040110`, i.e. caption removed + `WS_EX_APPWINDOW` added by the
title-bar feature. `0x20244` ("ANSWER (D:)", inset 0, own-frame app, never touched) was NOT
minimized.

**Mechanism - CORRECTED, my first attribution was wrong.** I wrote that the style change causes the
re-map. It does not. The re-map comes from the raise-on-foreground path, which fires for EVERY
window regardless of styles:

    AddAllWindows: foreground -> 0x1a0284, re-mapping to raise it in dom0

The timeline is what matters:

    100936  raise 0x20244                     <- the UNTOUCHED window
    100955  MINIMIZE 0x1a0284, 0x102ca        <- both RESTYLED windows, from dom0
    101008  restore (owner, by hand)

Raising the UNTOUCHED window preceded dom0 minimizing the two restyled ones, and `0x20244` was
itself raised three times without ever being minimized. So the restyled windows are the VICTIMS,
not the trigger.

PROVEN: only caption-stripped windows were minimized, and it follows a raise of some other window.
NOT established: why dom0's WM answers that with a minimize for caption-less windows specifically -
that lives in gui-daemon / the dom0 WM, outside this repo's reach. Treat as open, not solved.

**Action: `g_HideGuestTitleBar` defaulted OFF.** Windows spontaneously minimizing is worse than the
duplicate title bar the feature removes. What is proven and kept: the inset discriminator (own-frame
apps correctly untouched), the owner-context helper that makes the restyle possible at all, and the
keep-managed invariant. What is unsolved: doing it WITHOUT provoking a re-map.

That is also an argument for the crop route in `docs/PLAN-composition-layer.md` stage 3 - announced
geometry independent of the OS window rect changes no window styles at all, so there is no re-map to
provoke.

## 2026-08-17 — guest shadows off in seamless (kept), and the synth fix that never fired (retracted)

**Shadows: shipped and verified.** `ApplyGuestShadows` runs a one-shot helper under the interactive
user's token (the agent is SYSTEM and cannot write HKCU) to clear the DropShadow bit in
`UserPreferencesMask`, mirror it in `VisualEffects\DropShadow`, and broadcast `WM_SETTINGCHANGE`.
Applied from `SetSeamlessMode`, which `StartFrameProcessing` calls with `forceUpdate` on every
capture start, so it covers agent startup as well as mode switches; the fullscreen direction
restores rather than leaving the guest altered. Measured on the rig:

    agent log: "guest window shadows disabled (seamless)"
    UserPreferencesMask byte1 = 0x1A   (DropShadow bit clear)

Worth it on its own: shadow pixels were crossing the capture path and being drawn under a window
dom0 already decorates. Owner: *"the shadow tweak was worth it separately."*

**The bonus I predicted did NOT materialise.** I expected the extended frame bounds to collapse
toward the window rect, simplifying the invisible-border crop. Measured after the change:

    win=(400,300)-(1200,900)  efb=(407,300)-(1193,893)   inset L7 T0 R7 B7

The 7 px inset survives - DWM's invisible resize border is a separate thing from the drop shadow, so
the crop math and the black-band class are untouched. Claim retracted.

Also unchanged, as expected: NetUI's `SCENIC_DROPSHADOW_WINDOW_CLASS` surfaces are the APP's own
shadow windows, not DWM's, so this preference does not reach them - the class-drop rule shipped
2026-08-16 is still what handles those.

**RETRACTED: the drag-freeze synthesis fix never ran.** Instrumented after a real drag with a menu
open:

    materialize_before_freeze = 0     <- the new code
    freeze_deferred           = 0
    dom0_hold_deferred        = 0
    containment_materialize   = 1     <- the OLD path did the work

Both hooks sit on freeze transitions (`PwDragFrozen`, `DaemonDamageHeld`) and a dom0-driven move
reaches NEITHER, so the fix was dead code for the case the owner actually exercises. The improvement
he reported ("damage significantly reduced and self-healed fast") came from other changes, NOT from
this - do not attribute it here.

Replaced with a MEMBERSHIP test in the owner-geometry-changed block of `UpdateWindowData`, which is
the path that does run: we only reach it because the owner moved, so a child whose absolute position
is unchanged did not travel with the owner and was never part of the compound window. Containment
stays as the fallback. Not yet verified - the acceptance is a NON-ZERO count of
"owner moved and this child did not" on the next hand drag.

## 2026-08-17 — the "two Explorer windows" resolved: Explorer's ribbon modes, plus one real bug

Owner reported two Explorer windows behaving differently - one with a menu that "stays in and moves
with the window" (ideal), one rendering over the work area and dismissing on the slightest mouse
move. Three separate things were tangled here; only one was ours.

**1. Explorer's own ribbon mode (not a bug).** The chevron at the top-right pins or collapses the
ribbon:
- pinned -> the ribbon is part of the window's CLIENT AREA. Always visible, above the work area,
  moves with the window because it IS the window.
- collapsed -> clicking a tab drops the ribbon as a transient overlay OVER the work area, which
  auto-dismisses when focus moves. Native behaviour.

These map exactly onto the membership distinction: a pinned ribbon is part of the compound window,
an overlay ribbon is a transient popup. Window 1's behaviour cannot be given to window 2 - they are
different objects. Owner confirmed: *"so yes, they are the same"* once the confound below was gone.

**2. My confound.** Window 2 had no title because I stripped its caption BY HAND during the caption
experiments (`0x102CA`); the feature itself is default-off and shipped nothing. Restored. A
caption-stripped window's client area also grows by the caption height, which is the likely cause of
the misplaced menu geometry he saw. Lesson: leftover manual experiment state on the rig produced a
false A/B that cost real debugging time.

**3. A real bug, ours, now fixed.** The menu dismissal I added fired on EVERY quiet tracking pass.
The synth-children block is entered whenever an owner has synthesized children, NOT only when the
owner moved - my comment asserted the opposite and the code relied on it. Measured before/after with
a menu held open and idle 15 s:

| build | dismissals while idle |
|---|---|
| previous | **18** |
| gated on `coordsChanged` | **0** |

**Outcome accepted by the owner**: the overlay menu now stays out ~1 s after moving away and then
vanishes (the settle-time recapture), *"okayish ... it is fine as is"*. Pinning a transient popup
into the owner's buffer to avoid that is explicitly NOT wanted - it is what produced the orphaned
ribbon panel in the first place. Thread closed; no further work on menu behaviour.

**Scoreboard for this bug, worth remembering**: three attempts, two of them wrong in the same way -
asserting which conditions a code path runs under instead of measuring. Every correction came from
the owner's observation, not from my analysis.

## 2026-08-19 — fullscreen boot/shutdown "flash": characterized, three theories killed, real cause found

Owner reports a full-desktop (5120x1440) flash at guest startup AND shutdown, wants it hidden
unless a qvm-feature opts in. Investigated properly (design workflow + adversarial review +
on-guest ProtoTrace). THREE plausible causes were disproven, in order:

1. NOT `gui-emulated`. Owner set gui-emulated=0 by hand and the flash remained (their eyes).
   So it is not the emulated-VGA/stubdom window shown before the agent connects.
2. NOT the agent's boot-fullscreen default. Source said g_SeamlessMode defaults FALSE when the
   registry value is absent (main.c:6835) -> boot fullscreen -> SendWindowMap(NULL). BUT: an
   adversarial review flagged, and measurement CONFIRMED, that firstboot seeds SeamlessMode=1
   in the ROOT config key and CfgOpenKey falls back module->root (config.c line ~35), so the
   agent reads 1 and boots SEAMLESS. ProtoTrace on a real boot proves it: at capture start the
   agent does CREATE(hwnd=0x0) then immediately UNMAP(0x0) then maps the real per-window
   0x2003c, "Seamless mode changed to 1". The agent NEVER maps window 0. The whole first
   design (force g_SeamlessMode=TRUE) was a no-op on the shipped guest - killed before coding.
   (That design also carried a real heap-corruption bug the review caught: free() vs qdb_free()
   on the Windows qubesdb client - do not free qdb_read results with the CRT free().)
3. NOT the daemon mapping window 0. gui-daemon handle_create sets is_mapped=0 (xside.c:2931);
   it does not show the screen window on CREATE either.

REAL CAUSE: a legitimate FULLSCREEN GUEST WINDOW mapped transiently during the seamless
transition. At steady state EnumWindows shows two host-sized windows the agent correctly
FILTERS in seamless: `Program Manager`/class Progman (the Windows desktop, 5120x1440) and a
5120x1400 ApplicationFrameWindow (UWP frame). The boot/shutdown flash is one of these (the
0x2003c mapped at transition is the prime suspect = the desktop) being briefly MAPPED before
the window-acceptance predicate settles (boot) or as tracking tears down (shutdown). This is
the window-FILTER / transition-timing class (CLAUDE.md 2A-chrome territory), NOT a mode toggle.

CONSEQUENCE FOR THE FIX: the real fix is agent-side, feature-gated, in the window-acceptance
path - suppress mapping the desktop/Progman (and transitional fullscreen shell frames) during
the seamless transition, opt-in via a qvm-feature to restore. It is a proper piece of work
(like the chrome predicate), not a one-line toggle, and it needs the exact transitional window
(0x2003c) confirmed at the flash instant before coding - which requires catching a sub-second
transient (a few targeted captures) or accepting the Progman hypothesis and testing a filter.
Not implemented this session; characterized and de-risked. gui-emulated restored to 1;
ProtoTrace disabled; win10-clean left Halted.

## 2026-08-19 (later) — boot/shutdown fullscreen flash FIXED end to end (feature-gated)

Supersedes the "characterized, not fixed" entry above. Owner-directed design, verified on
win10-clean by the owner's own eyes (the reliable instrument for a transient visual).

ROOT CAUSE was TWO paths, not one (the class-based first attempt failed because it only
imagined one):
1. per-window fullscreen-sized window mapped transiently during the seamless transition at
   BOOT (a full-screen guest window slipping through ShouldAcceptWindow before the shell/
   filter settles);
2. the whole-screen "window 0" mapped via a seamless->fullscreen switch during teardown at
   SHUTDOWN (SendWindowMap(NULL) in SetSeamlessMode's !seamless branch) - which the per-window
   filter cannot reach because window 0 is not a per-window.

FIX (agent commits 742b7bd + 515c4e3; ARCHITECTURE DECISION recorded in CLAUDE.md): the guest
is never granted a fullscreen presentation unless opted in via service.gui-fullscreen.
- ShouldAcceptWindow rejects fullscreen-sized windows (>= ~99% of guest screen) by SIZE, not
  class; override-redirect + fullscreen is rejected UNCONDITIONALLY.
- SetSeamlessMode refuses any switch OUT of seamless when the feature is off (coerces back to
  seamless: per-window mapping stays alive = no black screen, window 0 never maps).
- Feature read once at Init from qubesdb /qubes-service/gui-fullscreen (dom0 wins) over the
  guest-local registry ShowFullscreenScreen base.

VERIFIED (owner eyes, win10-clean, agent af70658):
- feature OFF: boot = normal small window, NO fullscreen flash; shutdown = clean, NO fullscreen.
- feature ON: fullscreen startup screen returns (bidirectional causality proof).
- normal app windows (notepad) unaffected either way.
Accepted tradeoff: a maximized (fullscreen-sized) app is also suppressed with the feature off -
intended per the deny-outright decision.

Process note, recorded honestly: this took FIVE attempts (resolution guess, gui-emulated,
force-g_SeamlessMode [no-op, killed by adversarial review before shipping], Progman class
filter [failed live], then the owner's size-based + SetSeamlessMode-refusal design which
worked). The lesson repeats one already in CLAUDE.md: a source-only theory is not a mechanism
until measured; ProtoTrace (the agent's own log) and the owner's eyes were the instruments
that actually settled it, not screenshots. Parked: suppressing the residual normal-size boot
window (owner: "probably not now").

## 2026-08-19 (final) — fullscreen flash: CORRECT design, owner-verified across the full matrix

Consolidates and CORRECTS the earlier "FIXED end to end" entry (whose mechanism was wrong -
it blamed window 0 / SetSeamlessMode; the real culprit was per-window LogonUI). Took several
wrong turns (recorded honestly above); the thing that finally settled it was the filter's OWN
debug log naming the window class, not any source-only theory.

FINAL DESIGN (agent commits through 4cf7588; CLAUDE.md "TWO INDEPENDENT FULLSCREEN MODES"):
in ShouldAcceptWindow, for a fullscreen-sized guest window (>= ~99% of the guest screen):
1. class contains "LogonUI"  OR  override-redirect  -> DENIED UNCONDITIONALLY. This is the
   boot/shutdown/logon SCREEN (login, lock, "shutting down", initial desktop all render through
   LogonUI, class "LogonUI Logon Window"). The secure desktop is never granted, in any config
   (owner decision, CLAUDE.md). A lock/UAC LogonUI is a bug to log/report, not to show; recovery
   is a working autologon, not a visible guest login.
2. has WS_CAPTION (a maximized normal app - "windowed fullscreen") -> ALWAYS allowed, feature or
   not. It is just a large normal window.
3. borderless (no WS_CAPTION - a game/video/presentation "true fullscreen") -> feature-gated by
   service.gui-fullscreen (guest qubesdb /qubes-service/gui-fullscreen; registry base
   ShowFullscreenScreen). Default off = hidden.
Plus: an already-announced window that becomes ineligible (an app animating INTO borderless
fullscreen with the feature off) is UNMAPPED immediately (main.c ~3455) instead of on the next
RemoveWindow pass, so there is no map-then-unmap flash. Windows born fullscreen (LogonUI) are
rejected before the first MAP and were always clean.

VERIFIED by the owner's eyes (win10-clean, agent 766942f), full matrix:
- feature OFF: boot clean, shutdown clean (LogonUI); maximized app SHOWS (windowed); borderless
  true-fullscreen denied cleanly (no flash).
- feature ON: boot/shutdown STILL clean (LogonUI unconditional); borderless true-fullscreen SHOWS.
The golden image win10-clean now carries this agent (hot-deployed; also in the committed source
and future QWT builds). FUTURE (parked, owner "will see"): distinguish a genuine lock/UAC LogonUI
(persists, awaits input) to log/report it as the bug it is; convert UAC to an in-desktop dialog
or dom0-gate. Also parked earlier: the residual small normal boot window (owner: "probably not now").

## 2026-08-19 — RETRACTION: qubesdb IS readable in a Windows guest; it was a P/Invoke bug

**Retracting, loudly, a claim this project repeated for weeks and built workarounds around:
"qubesdb value reads are unavailable / unreadable inside a Windows guest" is WRONG.** It was a
glue bug, not a platform limit. The C gui-agent has always read qubesdb natively
(`qdb_open(NULL)`/`qdb_read` against `qubesdb-client.dll`, which ships in `C:\Windows\System32`);
PowerShell reads it identically once the P/Invoke uses `CallingConvention=Cdecl` + `CharSet=Ansi`
and passes the NULL vmname as `IntPtr.Zero`. Every earlier "qdb_open fails / reads return empty"
probe was broken by MY marshaling (wrong signature; one probe's C# never even compiled because a
nested `@"..."` verbatim string used `\"` escaping). Measured working in plain user context
(`WIN-IDD-TEST\user`) 2026-08-19 on both a StandaloneVM and a TemplateVM.

What IS still broken and stays retracted-to only for the CLI: the `qubesdb-cmd.exe` **CLI** read
returns empty (`/type`,`/name` -> `[]`), and CLI **writes** are broken (the `_WIN32 optind -= 2`
hack in `client/qubesdb-cmd.c`). We do NOT rebuild that stock binary (qwt-full stages it from the
GPG-verified MSI and only rebuilds gui-agent); every consumer of ours is routed onto the reliable
DLL read instead, which is strictly better. Recorded as a known stock bug; not reported upstream
(QWT-scope, held per the standing policy).

Canonical reader: **`guest/qubesdb-read.ps1`** (`Get-QubesDbValue`, `Get-QubesVmClass`,
`Test-QubesService`; self-tests when run directly). The updater and the installer carry inline
mirrors for self-containment.

Key facts (core-admin source, verified live):
- `/type` = the exact Python class name (`StandaloneVM`/`TemplateVM`/`AppVM`/`DispVM`) - the ONLY
  key that separates StandaloneVM from AppVM. `/qubes-vm-type` collapses both to `AppVM`
  (r3compatibility.py maps StandaloneVM -> "AppVM"); `/qubes-vm-updateable` (True for
  Template/Standalone) is the fallback splitter.
- Network L3 keys populate when a netvm is attached and are readable directly: measured on a
  networked StandaloneVM `/qubes-ip=10.137.0.70 /qubes-netmask=255.255.255.255(/32)
  /qubes-gateway=10.138.25.43 /qubes-primary-dns=10.139.1.1 /qubes-secondary-dns=10.139.1.2`.
- The proxy feature exports to `/qubes-service/yum-proxy-setup` (Linux checks `qsvc
  yum-proxy-setup || qsvc updates-proxy-setup`); we key template-only off `/type` instead.

Improvements harvested from the reliable read (all implemented + tested):
1. **Updater** (`guest/qubes-windows-update.ps1`): classifies LIVE from qubesdb - TemplateVM ->
   proxy pass; StandaloneVM -> skipped-standalone (never proxies, networked or offline);
   AppVM/DispVM -> skipped-appvm. Replaces the deploy-time VmClass/RootIdentity stamp discriminator
   (stamps demoted to a fallback for the impossible unreadable case). Tested on win10-clean
   (StandaloneVM -> skipped-standalone, zero proxy) and win10-tpl (TemplateVM -> proxy path).
2. **Installer** (`Install-QwtImproved.ps1`): netvm-free PV NIC priming is now DEFAULT-ON for
   TEMPLATES, gated on `/type=='TemplateVM'` read live at install (owner: default-on, not opt-in).
3. **install-start-shortcut.ps1**: was reading `enableWinKey` via the broken CLI -> ALWAYS saw
   "unset" -> never suppressed the Start shortcut for a third-party-shell guest. Now DLL read.
   Proven: CLI `/type`,`/name` -> `[]`; DLL -> `StandaloneVM`,`win10-clean`.
4. **pvnic-selfprime.ps1 applier**: reads `/qubes-ip //qubes-netmask //qubes-gateway` directly
   from qubesdb (QdbValues), with the network-setup.exe log parse kept as a fallback. Tested:
   QdbValues on the networked guest returned `ip=10.137.0.70 prefix=32 gw=10.138.25.43`; the
   nested here-string (double-quoted Add-Type inside the single-quoted per-boot payload) PARSES
   clean on the guest.

netvm test policy (owner, corrected here): **core-net is a normal healthy netvm - fine to attach
for TESTING** anything that is not a netvm-free template; **fw-net is the Mirage one, do not touch
unless debugging mirage itself** (ci-notes/mirage-netback-incompat.md). Attaching a netvm as a
FIX/dependency is forbidden (templates must live without one); attaching to TEST is encouraged.
Test rig here: win10-clean (StandaloneVM) + core-net, restored to offline (netvm='') after.

Baked into CI (release-package.yml -> make-setup.ps1): pvnic-selfprime.ps1 + qubesdb-read.ps1 +
health-check.ps1 now staged; pvnic-selfprime.ps1 + qubesdb-read.ps1 added to the required-files
self-check; the syntax-check now parses EVERY staged .ps1 (was: only Install-QwtImproved.ps1), so
the nested-here-string class of bug fails the build, not a booted VM.

NOTE for the flash-boot seen on win10-tpl this session: the agent submodule (4cf7588) HAS the
fullscreen fix and the repo pointer is on it, so CI builds it - win10-tpl flashed only because it
runs an OLDER deployed agent. Re-deploy it from a fresh release artifact to clear the flash.

## 2026-08-19 — qubesdb-cmd CLI bug pinned; shipped qubesdb-read.exe instead

The stock qubesdb-cmd.exe read is NOT uniformly broken - it mis-parses '/'-prefixed keys. Measured
on win10-clean: `qubesdb-cmd -c read /qubes-vm-type` -> `AppVM` (works), but `-c read /name` ->
"-n valid only for watch command" - the Windows getopt reads the leading '/' of the key as a
slash-option, so `/name` becomes `/n`. Flaky per key (whatever letter follows '/'), plus the
`optind -= 2` hack. A bare `qubesdb-cmd read` (no -c) never sets the command either.

Owner chose (over patching that getopt, which only validates via the ~2h qwt-full build) to ship a
tiny purpose-built reader: **tools/qubesdb-read/qubesdb-read.{c,vcxproj}**. It LoadLibrary's
qubesdb-client.dll (System32) and calls qdb_open/qdb_read at runtime - no getopt, no build-time
core-qubesdb dependency, plain v143 console exe. `qubesdb-read <key> [key...]` prints each value;
exit 0 all read, 1 some absent, >=2 setup error. Built in build.yml (idd-driver-package) AND
release-package's setup job (staged to the setup tree's tools\ via make-setup -QubesdbReadExe,
required by the self-check). VALIDATED on win10-clean: /name->win10-clean, /type->StandaloneVM,
/qubes-vm-type->AppVM, absent key->stderr+rc1. This is the CLI counterpart to guest/qubesdb-read.ps1.

## 2026-08-20 (cont) — U12 closed on a real cold boot, U8 on, and the debounce taught us something on its first boot

### U8 — TaskScheduler Operational log enabled (and immediately useful)

`Microsoft-Windows-TaskScheduler/Operational` was OFF (enabled: false -> true), which is why no pass
trigger could ever be attributed. First boot with it on already named the task, the instance GUID
and the return code - and that is what let the next item be diagnosed instead of guessed.

### The debounce skipped the BOOT scan - caught on the first real boot

First cold reboot after shipping the debounce:

    22:11:09 started   \QubesWindowsUpdateScan  (SYSTEM)
    22:11:12 completed return code 0            <- 3 seconds
    new_log_bytes = 0                           <- wrote nothing at all

A download pass had completed at 22:02, so the boot scan fell inside the 30-minute window and was
suppressed. Two conclusions, and the second is a defect:
1. The debounce WORKS on the real boot path, in real SYSTEM context - better evidence than the
   synthetic suite, and unplanned.
2. Suppressing the BOOT scan is only correct when the previous pass actually left an availability
   answer. The boot scan is the recovery for a pass whose own post-install rescan failed (the
   updater logs exactly that case: "availability will be re-reported by the next scan"). As
   written, a guest could sit up to a full scan interval with nothing to tell dom0.
FIXED: the debounce now also requires the previous pass to have left an `available` list with
phase=done. Everything else unchanged - only `-Scheduled` passes are skippable, explicit passes
always run.

### U12 — QdbDaemon startup-race fix VALIDATED on a cold boot

The fix (wait the daemon out instead of believing the first empty read) had never been exercised on
a real boot; restarting the agent in a live session clears the very state that produces the fault.
Second cold reboot, with the completion stamp cleared so the pass would actually run:

    rebooted=true  new_log_bytes=1101  class_lines=1  classes_seen=TemplateVM
    class_correct=true  saw_empty_class=false  refused_to_classify=false  ok=true
    boot scan 22:15:39 -> 22:16:45 (66 s of real work, not a 3 s skip)

The boot pass classifies the template CORRECTLY instead of reading an empty class and skipping it
as a standalone. U12 is closed. Harness kept: `guest/wu-boot-acceptance-arm.ps1` +
`guest/wu-boot-acceptance-check.ps1`.

### PRE-SESSION QREXEC ALREADY EXISTS - no code required (answers the standing "no session = no RPC" problem)

Read from the vendored source rather than inferred:

  `src/qrexec-agent/qrexec-agent.c:336`
      if (!wcscmp(*userName, L"SYSTEM") || !wcscmp(*userName, L"root"))
          { free(*userName); *userName = NULL; }
  `src/qrexec-wrapper/qrexec-wrapper.c:145`
      @param userName  If NULL, this process' user token will be used (normally SYSTEM).
      @param interactive  Run the child in the interactive session (a user must be logged in).

The service call format is `user:[nogui:]command`. Requesting user **SYSTEM** (or root) nulls the
user name, so the child runs on QrexecAgent's OWN LocalSystem token - no WTSQueryUserToken, no
logon, no session. `QrexecAgent` is confirmed `StartName=LocalSystem, State=Running` on the guest,
and `qubes.WaitForSession` exists precisely because ordinary calls DO wait for a session (that is
the rc=117 path measured 2026-08-13).

Consequence: the "a Windows qube at the sign-in screen is unmanageable" problem is a POLICY gap,
not a missing capability. One dom0 line enables it:

    qubes.VMShell  *  dom0  <vm>  allow user=SYSTEM

Proposed shape (dom0 policy is the owner's to add):
  - a dedicated `qubes.WinEarlyDiag` service so normal calls keep the safer user context;
  - its guest handler reads `/qubes-service/win-early-diag` from qubesdb and exits unless set, so
    `qvm-features <vm> win-early-diag 1` arms it - policy AND feature must agree;
  - off by default. It does not weaken Qubes isolation (dom0 is already fully trusted toward the
    guest) but it does bypass the guest's INTERNAL user boundary and works while the secure desktop
    is up, so it stays debug-gated. Execution, not display - consistent with "the secure desktop is
    never granted".

This would have answered the win11-fresh case directly: it is unreachable right now while burning
~1.7 cores, and we are reduced to inferring what it is doing.

### Addendum — the SYSTEM user field: dom0-only from the caller side, but a POLICY line still delivers it

Owner pushed back on the claim that this needs dom0 ("did you even try it?"). Tried, and the answer
is now empirical rather than reasoned:

    qubes.VMShell            win10-tpl rc=0     win11-fresh rc=124 (hang)
    qubes.VMShell+SYSTEM     win10-tpl rc=0     win11-fresh rc=124 (hang)   <- '+SYSTEM' is a
                             service ARGUMENT passed to the handler (cmd.exe ignores it); it is
                             NOT a user, proven by identical behaviour to plain on both guests
    SYSTEM:qubes.VMShell     rc=126 refused on both                          <- parsed as a
                             service name; no such service
    qvm-run -u SYSTEM ...    ValueError: non-default user not possible for calls from VM
                             (qubesadmin/app.py:1058, the in-VM run_service)

`qrexec-client-vm` has no user option at all (only --source-qube/--prefix-data/buffer/escape). The
user is not in the VM-side protocol: MSG_EXEC_CMDLINE carries the service, and dom0 fills the user
in during policy evaluation. So a CALLER can never choose it - from dom0 `qvm-run -u` works because
that path goes through the socket/dom0 implementation, which builds the `user:[nogui:]command`
string the Windows agent parses.

THE USEFUL COROLLARY: because `user=` is imposed by dom0's qrexec-daemon at policy evaluation, a
POLICY line grants it to calls that come FROM A VM too - the caller neither needs nor is able to
ask. One line gives this qube pre-session access to the testbed with no new code and no new service:

    qubes.VMShell  *  win-idd-mgmt  @tag:win-idd-testbed  allow user=SYSTEM

Retracted along the way: `qubes.WaitForSession` as a session probe. It exists and is installed
(guest service file -> wait-for-logon.exe, 23112 bytes; source in the vendored tree), and the
rc=126 seen for it was policy, not absence - the control against healthy win10-tpl returned the
same 126. But it only EXPLAINS a failure without granting access, and the action is "wait" either
way, so it is not worth a policy line. Dropped.

---

## 2026-08-20 (cont) — the "fullscreen splash is back" report: NOT a regression, plus a stuck AppVM autologon

Owner saw the boot/logon fullscreen splash that was supposed to be gone for good (2026-08-19,
Mode 1 "unconditionally OFF"). It is not a regression of that fix. Two separate facts, both measured
on win11-app:

1. **The fix is not deployed there.** `gui-agent.exe` on win11-app is dated **2026-08-11**, 195,072
   bytes. The LogonUI denial shipped in the AGENT BINARY on 2026-08-19 (agent e2d7356/225058d/
   4cf7588) and was only ever deployed to win11-fresh. win11-app is an AppVM of win11-tpl and
   inherits that template's QWT, which predates the fix by eight days. Nothing in that binary can
   reject LogonUI.
2. **There is genuinely no user session, so LogonUI is really on screen.**
       query session -> console, ID 1, state ConnQ, NO USERNAME  (steady 90+ s)
       zero Winlogon events for THIS boot (the Winlogon lines in the log belong to the TEMPLATE's
       last run at 23:08 - an AppVM inherits the template's event log along with its root volume)
   Autologon is configured CORRECTLY: AutoAdminLogon=1, DefaultUserName=user, DefaultPassword
   present, and AutoLogonCount correctly ABSENT (that key is the one that consumes the password and
   drops the guest to the sign-in screen). It simply does not complete.
   Ruled out: the profile-moved-to-private-disk theory - ProfilesDirectory is `%SystemDrive%\Users`
   and C:\Users\user exists, so profiles were never moved on this guest.

So the splash = a real logon screen, shown by an agent too old to hide it. On a guest with the
current agent, this same condition would be invisible.

Per CLAUDE.md the stuck logon is itself a BUG to report rather than paper over. It matches the open
I3 "AppVM first-boot no-GUI" item, which until now had "trigger unidentified"; it can now be stated
as: **the AppVM's autologon does not complete, the console session stays in ConnQ with no user, and
Winlogon logs nothing for that boot.**

### Two operational consequences discovered here

- **Pushes into a pre-session guest FAIL SILENTLY.** `qubes.Filecopy` still runs as the default USER
  (the new policy line covers qubes.VMShell only), so with no session a push reports
  `sent 0/3 KBEOF` and rc=0 while delivering nothing. Every script I pushed to win11-app vanished.
  Check the destination, never trust the exit code.
- **Workaround that DOES work pre-session:** `powershell -NoProfile -EncodedCommand <base64 utf-16le>`
  over the SYSTEM shell. No file needed, and it sidesteps the inline-quote mangling that has broken
  so many one-liners in this project. This is now the way to introspect a guest with no session.

### win11-tpl agent refreshed 2026-08-20 — the stale-agent root of the "splash is back" report

win11-tpl carried gui-agent.exe **195,072 bytes, dated 2026-08-11** - the same binary win11-app
inherits, and eight days older than the LogonUI-denial fix. Replaced with the CI build of the
current submodule pointer:

    package 4.3.2+agent.4cf7588186f3   agent 4cf7588
    old 195,072 (83B69F62E532944A)  ->  new 235,256 (EB03126568FAE68B)
    running image verified as the NEW binary (pid 8656, same size+hash), .orig backup kept

Managed by the `QubesGuiWatchdog` SERVICE (gui-watchdog.exe spawns gui-agent.exe into session 1), so
the swap order is: stop the service, kill the agent, swap, start the service.

HARNESS DEFECT FIXED IN THE SAME BREATH: the deploy script waited a fixed 8 s and then reported
`agent_running=false` on a deploy that had actually SUCCEEDED - the watchdog restarts the agent on
its own polling interval and the process appeared ~30 s in. A false negative like that sends the
next reader chasing a failure that never happened. It now POLLS for up to 90 s and records
`agent_wait_secs`.

Incidental but important: win11-tpl's console session is `user ... Active`, i.e. **autologon works
on the TEMPLATE**. The failure is specific to the AppVM (win11-app), which strengthens the case that
I3 is an AppVM-specific defect rather than anything about the Win11 image.

### U6 (AppVM branch) is BLOCKED BY I3, and I3 is worse than recorded: it is not Win11-specific

Attempted the AppVM cell of the VM-class matrix on both AppVMs. It cannot be run, and the reason is
itself the finding:

    win11-app  boot 1  console session ConnQ, NO USER  (autologon configured correctly)
    win11-app  boot 2  console session ConnQ, NO USER  (after the agent refresh)
    win10-app  boot 1  console session ConnQ, NO USER
    -> 3/3 across BOTH lineages. I3 was recorded as one lineage and "trigger unidentified";
       it is not Win11-specific and it is reproducible.

Consequences measured, not assumed:
  - `qubes.Filecopy` runs as the default USER, so with no session every push into these guests
    reports `sent 0/3 KBEOF` with rc=0 and delivers NOTHING. Trust the destination, never the code.
  - On win10-app even `powershell -Command "Write-Output PSOK"` returns nothing over the SYSTEM
    shell, so the updater never ran: no WorkDir, no status file, no agent.log. The `exit 0` I first
    reported was meaningless anyway - in cmd, `A & echo %errorlevel%` expands BEFORE A runs.
  - win11-app additionally lacks `qubesdb-read.exe` (shipped 2026-08-19 to win10-tpl only), and
    returned "The remote procedure call failed" for tasklist - a degraded guest.

So the honest status of U6 is BLOCKED, not failed: the AppVM branch cannot be exercised on an AppVM
that never reaches a user session. **I3 must be fixed first**; U6 is downstream of it.

What is NOT the cause (ruled out this session): profiles moved to the private volume
(ProfilesDirectory is `%SystemDrive%\Users` and C:\Users\user exists), a missing autologon config
(AutoAdminLogon=1, DefaultUserName=user, DefaultPassword present, AutoLogonCount correctly ABSENT),
and the template itself (win11-tpl's console session is `user ... Active` - autologon works there).

### The splash question, answered with a measurement

After refreshing win11-tpl's agent to 4cf7588 and rebooting the AppVM (which inherited it - template
-> AppVM propagation verified, 235,256 bytes):

    win11-app sitting at LogonUI with the CURRENT agent -> windows mapped to dom0: 0

i.e. the fixed agent suppresses the logon screen even in exactly the state that produced the report.
Caveat stated honestly: the "before" side is the owner's observation, not a count I measured; a
strict A/B would re-run with the kept `.orig` binary.

---

## 2026-08-21 — I3 ROOT CAUSE IDENTIFIED: xenagent reboots every AppVM boot, forever (a PV-driver boot loop)

I3 was recorded as "AppVM first-boot no-GUI, trigger unidentified". The trigger is now named, from
the guest's own System log rather than inference:

    05:08:15  6005  Event log started                      <- boot N
    05:08:19  7045  A service was installed  (x3)          <- PV drivers install AGAIN
    04:44:35  1074  C:\WINDOWS\System32\xenagent_9_1_0_0.exe has initiated the shutdown ...
    04:44:01  6005  Event log started                      <- boot N-1
    04:35:37  1074  xenagent ... has initiated the shutdown
    04:33:48  6005  Event log started                      <- boot N-2
    23:44:12  1074  xenagent ... has initiated the shutdown
    23:08:36  1074  xenagent ... has initiated the shutdown

**The Xen PV driver agent reboots the guest on EVERY boot.** Each cycle it re-installs its services
(three 7045s) and asks for the reboot that a driver install requires - and the next boot does it all
again. Nothing else in the guest is broken.

### Why it hits AppVMs and never templates

An AppVM's ROOT volume is a discarded copy-on-write overlay: whatever xenagent writes to record
"drivers installed, reboot completed" is thrown away at shutdown, so the next boot is, from its point
of view, the first one. A TEMPLATE's root is persistent, so there the reboot happens once and the
state sticks - which is exactly why this is 3/3 on AppVMs (win11-app twice, win10-app once, both
lineages) and never on the templates that log on fine.

### Everything else was a consequence, including things I chased

  - console session stuck at ConnQ, no user   -> the machine restarts before Winlogon finishes
  - Winlogon/ProfSvc operational channels EMPTY (and verified ENABLED, so that was real evidence)
  - boot-triggered tasks never run: QubesAutologonGuard could not re-arm autologon, and my own
    QwtI3Probe (BootTrigger, 45 s delay) showed "Last Run Time 11/30/1999, has not yet run" because
    the guest reboots before the delay elapses
  - qrexec answers for about a minute after each boot, then goes silent - that is the cycle, not a
    wedge
  - "0.00 cores while unreachable" - I was sampling ACROSS restarts; cputime DECREASING between
    samples (53.5 -> 50.4 -> 57.5 s) is what finally gave it away, since CPU time only resets when
    the domain restarts

### Hypotheses this kills (all mine, all measured away)

  missing user profile ....... profile is full and intact on Q:
  private-volume/profile path  C:\Users -> Q:\Users symlink is fine, ACLs and SID match
  bad credentials ............ net use with user/qubes succeeds, rc=0
  consumed DefaultPassword ... restored it, rebooted, no change
  display configuration ...... the TEMPLATE has the identical IDD-started/VGA-disabled config and
                               logs on fine - the control refuted it
  the IPI wedge .............. wedged guests burn ~2.8 cores; this one does not spin at all

### Consequence for U6

U6 (the AppVM branch of the VM-class router) is untestable on an AppVM that reboots every ~90
seconds. It is blocked on I3 as a matter of fact, not of scheduling. The fix direction is to make
xenagent's completion state survive - it must live somewhere persistent for an AppVM (the private
volume) or be satisfied by the template having already done the install - and that is a change to
the PV driver agent, i.e. qubes-vmm-xen-windows-pvdrivers, not to anything in this repo.

---

## 2026-08-21 (later) — RETRACTION + real root cause: the Windows frontend closes BEFORE it connects

**RETRACTED, loudly: the fix recorded in the entry above is the wrong shape and is withdrawn.**
Making `read_frontend_configuration` FAIL on Closing/Closed stops the wedge but **forecloses the
attach** - the failure unwinds into `disconnect_backend`, which parks the backend at Closed and
removes the backend directory, and neither is a state the frontend can reconnect from; the
dispatcher admits each (domid,devid) exactly once (dispatcher.ml:503/518) so `make_backend` never
re-runs. It turns a wedged guest into a guest with permanently no PV networking. The owner's call
- "until we get guest PV-attached it is pointless" - was correct. Do not ship it.

**Real root cause** (Fable workflow, 5 lenses -> 14 candidates -> 2 adversarial refuters each -> 7
refuted -> synthesis; confidence "strong", traced but not yet run on the rig):

mirage-net-xen implements only the FORWARD half of the vif xenbus handshake. **xenvif begins every
device bring-up with a close cycle**, which the backend never answers:

- At PDO creation, before any attempt to connect, `__FrontendResume` calls
  `FrontendSetState(FRONTEND_CLOSED)` (frontend.c:2659-2668). There is no direct UNKNOWN->CLOSED
  edge, so the walk runs FrontendPrepare (instant - backend already at InitWait, frontend.c:1537)
  then FrontendClose.
- FrontendClose writes frontend **Closing(5)** and loops until the backend answers Closed
  (frontend.c:1471-1501). Against a backend parked at InitWait none of its exits can fire.
- Both sides therefore stop for ever at **backend=2 / frontend=5** - exactly the measured snapshot.
- That loop polls at DISPATCH_LEVEL under `Frontend->Lock` **inside PdoCreate**, so PnP never
  completes: 2 cores burnt, no qrexec, no ACPI. The wedge is a symptom of the same deadlock.

This is the first explanation that survives both discriminators: the STUBDOM vif connects on the
same unikernel because its frontend is a Linux netfront that only does the forward handshake; a
Linux netvm works because xen-netback's `frontend_changed`/`set_backend_state` implements the full
machine including the Closed->InitWait reconnect edge.

**Refuted, do not re-propose:** missing/extra backend keys (every key xenvif reads pre-connect is
optional with a safe default; it never reads hotplug-status, mac or handle); late or misordered
InitWait (all six feature keys were present on the measured boot, proving init_backend completed
early; and xenvif has no timeout-to-Closing transition - Closing is only ever written
deliberately); FrontendConnect failing early (unreachable - the wedge holds the lock inside
PdoCreate before any start IRP); the same-IP collision as the wedge (the guest client never
reached Client_eth - no "Waiting for old client" line in the log).

**Fix applied and built**: answer the cycle - Closing->Closing, Closed->Closed, then re-arm at
InitWait once the frontend leaves Closed (mirroring xen-netback). No Windows-side change needed.
Upstream head builds reproducibly (951b4aff... == qubes-firewall.sha256); with the fix
be71a900..., new runtime string present 2x vs 0x in the control.

**Held back deliberately**: the qubes-mirage-firewall traffic-layer patch (vif_type discriminator,
identity-safe remove_client, PV-takeover of the shared IP). An HVM's two vifs share one IP and
ownership is supposed to resolve serially via the emulated-NIC unplug; whether that handover
completes on this testbed is unknown, and a takeover rule firing wrongly would hijack an IP from a
live interface. Ready, not applied on a guess - the rig discriminator decides.

Full write-up + patch + test plan (incl. the control that must fail): `/home/user/mirage-gso/`.

**Layer 3 closed by the owner (2026-08-21):** "only pv vif remains, emulated realtek gets
disconnected". The serial-handover contract holds, so the proposed vif_type discriminator and
PV-takeover arm are DROPPED, not deferred - there is no case needing one, and a takeover firing
wrongly would hijack an IP from a live interface. It also explains the measured snapshot: on the
wedge boot the PV NIC never started, so the unplug was never armed, so both vifs were still there.

That fact makes two OTHER defects routine, because the unplug is armed by a boot that then demands
a reboot (pdo.c:1440-1454, STATUS_PNP_REBOOT_REQUIRED), and every successful attach passes through
"stubdom vif holds the IP, guest vif still parked in add_client, both torn down at once":
1. `remove_client` removed by IP WITHOUT checking identity, so cleanup for the never-admitted guest
   vif evicted the LIVE stubdom client; the assert then fired on the next removal, and
   `Cleanup.cleanup` is a bare `List.iter` with no containment, so that exception aborted every
   remaining cleanup handler. `Dao.VifMap.iter` walks in key order -> the guest (lower domid) is
   cleaned first, i.e. exactly the bad order.
2. A parked admission outlived its vif: when the IP was freed it registered an interface whose
   device was gone, and the next client for that IP then waited behind a dead one for ever.
Both fixed (0002-qmf-client-handover-safety.patch): remove only our own entry; cancel the admission
from cleanup (handlers run last-registered-first, so the cancel precedes the removal).

Built with all three changes: 8071def9... vs upstream 951b4aff... (reproducible). Ready for the
rig: `/home/user/mirage-gso/qubes-firewall-FIX.xen`.

---

## filter leg (why the fullscreen gate did not fire on his rig) is still unidentified. What follows
## is an engineered simulation of the failure STATE via DiagWindowFilterOff. The predicate covers
## Explorer window; every reproduction arm we control renders it CORRECTLY on our rigs.

His gui-agent-20260827-110828 log (agent 4.3.7.0, Win11 25H2 AppVM, host 1920x1200, boot at
11:08:28, pulled 11:23): clean session — no vchan errors, no capture errors, normal map/unmap
churn. The only persistent window is 0xa0042: per-window buffer 1054x752 attached 11:17:17,
never unmapped, sticky-foreground (re-raised after every other window's unmap — matches "the
black one keeps Windows-key response"), owns a synthesized tooltip child 0x3028e (279x50,
three text-line paints: an Explorer item tooltip). 1054x752 equals the DWM bounds of the
CabinetWClass window in his earlier winenum (1068x759 outer − 7px borders). Conclusion: the
black window on THIS boot is (almost certainly) his File Explorer window, NOT Progman — the
earlier Progman identification does not hold for this boot (no fullscreen window was ever
attached; slabs top out at 775 pages).

**Why the log is structurally blind here.** wincapture.cpp (the per-window engine, PrintWindow
+ PW_RENDERFULLCONTENT) contains not a single log statement. A channel goes dead after 5
consecutive PrintWindow failures — silently. WcPrefill failure is LogDebug (invisible at his
level); its own comment says failure "just means a black window until the first frame".
QGAPERF's pwcap counts capture REQUESTS (WcMarkDirty), not engine outcomes. Therefore his log
is IDENTICAL under three states: (a) PrintWindow succeeds but renders the window black (WinUI/
DirectComposition blind spot), (b) PrintWindow fails 5x and the channel dies with the granted
buffer never written (dom0 keeps showing the zero-filled = BLACK pages), (c) healthy capture.
His eyes rule out (c). The DDA overlay explains the rest of his report: during a drag the DDA
slice path paints real desktop fragments into the buffer (his 11:18:08 burst: ddacap=1,
sends=2/frame, area≈4480px), and the settle capture re-blacks them — content flashes during
drag, black on release.

Dead ends closed while reading the log (each looked like the smoking gun and was not):
- sends=0 in QGAPERF frames: g_PerfSendCount is __declspec(thread); the engine sends from the
  capture thread, invisible to the main loop's counter. Retracted.
- ddmov=1 per frame at log end: one real drag in progress; only ONE QGADDAMOVE in the whole
  session (at attach). Not a stuck-moving state. Retracted.
- "unknown msg type 127" x43: MSG_CROSSING — our handler switch simply has no case for it
  (enter/leave ignored). Benign, worth adding a case someday.
- "no shell window" at init: GetShellWindow()==NULL when the agent starts on 25H2 — the
  filter's shell-window identity check can never match at that point. Noted, not this bug.

**Reproduction attempts (all NEGATIVE — the defect is not reproducible with the deltas we
control).** Instrument: exp-probe.ps1 (schtasks /it into the session; PrintWindow both flags
on a CabinetWClass window; black-pixel ratio + PNG). Instrument validated in BOTH directions
on win11-fresh 26200.9168: fullcontent arm 0.1% black (real content), plain arm 21.5% black —
PrintWindow WITHOUT the flag reproduces exactly the failure shape (WinUI islands black), so
the probe detects the defect class when present. Arms tested, Explorer content CORRECT in
dom0 pixels (qtest shot) every time:
- plain 25H2 StandaloneVM (win11-fresh), agent 4.3.9 — correct;
- + OpenShell 4.4.198 incl. ClassicExplorer injected (his setup; classic status bar visible
  in the shot) — correct, probe still 0.1% black;
- Win11 AppVM (win11-app on win11-tpl), agent 4.3.9 swapped into the template — correct.
- Engine code identical 4.3.7→4.3.9 (git: no wincapture.cpp/perwindow.c/capture.c commits in
  24cf973..33f3109), so his 4.3.7 is not the delta.
Remaining unknowns on his side: his exact Windows build/update level, the actual identity of
0xa0042 (Explorer inference is strong but unproven), and his dom0 guid log (grant-map failures
on MSG_WINDOW_DUMP would also render black and are invisible to the agent).

Actions this produced (in flight): (1) pwdiag.ps1 — a one-command field diagnostic for GWeck:
enumerate visible top-level windows, PrintWindow each with both flags, report class/title/rect
/styles + black ratios + PNGs; (2) wincapture.cpp telemetry: log channel death (5 failures,
with GetLastError), WcPrefill failure at warning level, and a one-shot per-channel all-black
capture detector — so the NEXT field log answers (a)-vs-(b) outright; (3) draft forum reply
(user must approve text) asking him to run pwdiag and attach dom0 guid.log.
Baseline note: win11-fresh now has OpenShell 4.4.198 installed (uninstall before using it as
a clean-shell baseline); win11-tpl carries the 4.3.9 agent binary (was 4.3.2).

## 2026-08-28 — 4.3.12 SHIPPED (v4.3.12-agent2adbd57): non-seamless is finally a WINDOW, and
## 2026-08-28 — seamless-mode switch failing with "exit status 46": localized to the LAUNCH path,
## not to set-gui-mode

WHAT dom0 DOES (qubes-manager settings.py:1229): the "Disable seamless mode" button calls
run_service_for_stdio("qubes.SetGuiMode", input=b"FULLSCREEN"), and CalledProcessError prints the
guest's exit code verbatim. So 46 is genuinely what the guest returned.

WHAT 46 CANNOT BE. Measured on win10-app/win11-app against the STOCK binary, harness validated in
the same run (a known-46 process reports 46; the binary's own bad-input path reports 87):

    SEAMLESS   EXIT=0   (x3)      FULLSCREEN EXIT=0      GARBAGE EXIT=87

set-gui-mode.exe returns only 0, 2 (event absent), 87 (bad input), or a SetEvent failure. It never
returns 46. My earlier claim that it returns stale GetLastError() garbage on success is retracted
above.

WHAT 46 IS. qrexec-wrapper.c's cleanup path sends `status` - a WIN32 ERROR CODE - through the data
vchan AS the exit code whenever child setup fails:

    if (!piped || status != ERROR_SUCCESS) { VchanSendHello(...); VchanSendExitCode(child, status); }

Proven by experiment: renaming qubes.VMExec's service file away made dom0 see rc=2
(ERROR_FILE_NOT_FOUND) on three consecutive calls, and rc=0 again once restored. So the guest
reports launch failures as Win32 errors in the exit-code field, and 46 (ERROR_SHARING_PAUSED) is
**[UNPROVEN — uncited gloss, and probably wrong: `ERROR_SHARING_PAUSED` is 70 in winerror.h; 46 is
unassigned there. Audited 2026-08-29. The surrounding localisation of 46 to the LAUNCH path is
separately supported; only the name attached to the number is in doubt.]**
one of those - from StartChild's CreatePipedProcessAsUser / CreateNormalProcessAsUser /
CreateChildPipes, not from the service.

CONCLUSION: on the reporter's guest the qubes.SetGuiMode SERVICE NEVER RAN - the wrapper could not
create the process. That is consistent with his other symptom (an empty app menu: qubes.GetAppmenus
would fail the same way) and with a partially-installed QWT, which is exactly what the other
reporter described in post 104.

THE EVIDENCE THAT WOULD NAME IT: qrexec-wrapper writes a per-call log,
Q:\Qubes Logs\qrexec-wrapper-<timestamp>-<pid>.log, and StartChild's failures go through
win_perror2, so the failing API and its code are IN THAT FILE. On a healthy guest there are no
such lines (checked). Ask for the wrapper log from the minute he clicked the button - not the
gui-agent log, which would only show the switch that never arrived.

HARNESS NOTE: set-gui-mode.exe is a GUI-subsystem binary (wWinMain), so `cmd /c prog & echo
%ERRORLEVEL%` reports nothing useful - cmd does not wait for it. qrexec gets a real code because it
waits on the process handle. Measure with Start-Process -Wait -PassThru, and validate the harness
with a known non-zero first.

## 2026-08-28 — seamless-switch 46: the "no interactive session" hypothesis is FALSIFIED (owner)

My leading explanation was that on the reporter's guest the service could not be LAUNCHED (no user
session to launch into), and that qrexec-wrapper reported the launch failure as the exit code -
consistent with my measurement that a missing service file surfaces as rc=2.

The owner falsified it directly: an unreachable guest makes the call WAIT, it does not return a
weird rc. So "no session" produces a hang, not 46, and the hypothesis is dead. What survives from
the measurements is narrower than I claimed:

  * set-gui-mode.exe returns 0 on BOTH branches on a healthy guest (measured, harness validated
    with a known-46 control and the binary's own 87 path);
  * the wrapper does report Win32 setup failures in the exit-code field (measured: rc=2 for a
    renamed-away service file);
  * therefore 46 is a Win32 status from somewhere in the guest-side launch path - but WHICH one is
    still unknown, and "the guest had no session" is now excluded.

Standing lesson for me: I built a causal story out of two true facts and one assumption, then
presented it as a diagnosis. The assumption (no session -> nonzero rc) was never measured, and it
was the load-bearing one.

## 2026-08-28 (evening) — the WIN10 brick, ROOT CAUSE NAMED BY WINDOWS ITSELF

> # RETRACTED IN FULL 2026-08-29 — THIS SECTION NAMES NO ROOT CAUSE.
> The next section (f530d2c) withdraws it. Adding the Date field to the same event query showed the
> restart was initiated at 00:20:10Z, **five seconds BEFORE the installer's first log line at
> 00:20:15**: my harness wrote `xenbus_monitor\Request\xenvbd\Reboot=1` and the already-running idle
> monitor acted on it at once. The "four reproductions" and the six later "FAIL BRICKED" results all
> measured that injection, not the product. No fix to `Install-QwtImproved.ps1` or `xenbus.inf` could
> have changed them. **The cause of the WIN10 brick is OPEN and unnamed.** The paragraphs below are
> kept as a record of the wrong reading; do not cite any of them. Per-claim status:
> * event 1074 as proof our install path restarts the guest — RETRACTED;
> * "reproduced FOUR times" — RETRACTED (four measurements of my own injection);
> * "why the suppressor does not save it" / the 1 Hz race — RETRACTED, never demonstrated;
> * the xenagent shutdown 1074s (#29) — RETRACTED as a product of this run; dated capture shows
>   those events are from 20 and 23 August, i.e. the golden image's own history, not this install;
> * STILL STANDS: black-screen-with-CPU is not a dead guest, and the harness-defect list at the end.

Not inference. Windows event 1074, captured live from the guest during the install (the guest is
alive right up to the moment, so this had to be read while it lived - afterwards there is nothing
left to ask):

    The process C:\Windows\System32\xenbus_monitor_9_1_0_0.exe has initiated the RESTART of
    computer WIN-IDD-TEST on behalf of user NT AUTHORITY\SYSTEM for the following reason:
    Operating System: Recovery (Planned)   Reason Code: 0x80020002

So: with a pending `xenbus_monitor\Request\<driver>\Reboot=1` and the monitor able to run, the
monitor RESTARTS the guest roughly 28-30 s into msiexec - in the middle of the PV driver install -
and the interrupted install leaves the guest unusable. Reproduced FOUR times (t+66, 68, 72, 80 s);
the seed-off control on the same package and image completes in 90 s and stays healthy.

> **RETRACTED 2026-08-29:** the restart was initiated BEFORE the installer started; these four
> "reproductions" measured my own injection. Only the seed-OFF control in this sentence stands.

**Why the suppressor does not save it.** `Start-XenbusPromptSuppressor` sweeps once a SECOND:
disable the service, stop it, kill `xenbus_monitor*`, delete the Request key. But the monitor
reboots the machine the instant it starts with a request pending, and the MSI both re-registers
and STARTS that service mid-install. A 1 Hz poll against "starts and immediately reboots" is a race
by construction, not a tuning problem - it ran for 28 s before the reboot landed and still lost.
The fix therefore has to make the reboot impossible during the MSI window (deny the service start,
or otherwise remove its ability to act), not sweep faster.

**The outcome varies, and BOTH forms are unusable.** Run A came back to "Automatic Repair couldn't
repair your PC". Run B booted past winload (spinner, then black) and stayed black - but
`admin.vm.Stats` showed it consuming CPU steadily (cpu_time 92755 -> 119257 in 40 s, 8 GB resident).
That guest was RUNNING, headless and unreachable: half-installed QWT, no qrexec, and the desktop no
longer drawn to the emulated framebuffer dom0 can see. A user in this state has a qube that looks
dead and is not.

Consequence for the harness, corrected immediately: a black screen ALONE is not a terminal state.
The rule now requires black AND no CPU, or it declares a live guest dead.

**Bonus, and direct evidence for the open "unattended AppVM reboots" task (#29):** the same event
query returned three more 1074s from `C:\Windows\System32\xenagent_9_1_0_0.exe` initiating
SHUTDOWNS (reason code 0x8000000c). That task has been theorising about which component shuts the
guest down; Windows names it.

> **RETRACTED 2026-08-29 as evidence from this run.** The dated capture shows those three xenagent
> 1074s are stamped 2026-08-20 and 2026-08-23 — the golden image's own history, carried in the
> image, not produced by this install. The events exist; they say nothing about what this run did,
> and quoting them as "direct evidence" for #29 was the same undated-capture mistake. Task #29 is
> back to where it was.

**Harness defects fixed in the same session, each measured, not guessed:**
* `qvm-start` BLOCKS until qrexec connects. With the clone's `qrexec_timeout=6000` that is 100
  minutes of total silence on a guest that never boots - 15 minutes of an apparently hung harness
  was simply sitting inside it. Now fired in the background with our own polling; clones get
  `qrexec_timeout=600`.
* `qvm-kill` was never needed: a guest in the recovery screen, and even the black/Transient one,
  honours ACPI shutdown (10 s and 20 s measured). The kill was actively harmful - it leaves the
  volume dirty and qubesd then refuses the next clone outright ("Cannot import to dirty volume ...
  start and stop a qube to cleanup"), which is how a cell that HAD reproduced the bug died with
  "could not reclone". Kill is now the last resort and announces its cost.
* Errors were being discarded. "could not reclone" said nothing; the real message named the cause.
  Clone and push now log their actual error text, and push retries three times - its first attempt
  failed one second after boot with rc=46, i.e. no session yet (the same 1326 truncation as the
  field's "exit status 46").

## 2026-08-30 — MSG_CROSSING (127) is NOT HANDLED by the Windows agent; candidate cause of cursor artifacts

Found from an owner observation while Explorer was on screen: *"explorer DID appear. but
override-redirect did not go and while it was visible the window was full of occlusion and cursor
artifacts"*. (The override-redirect half is expected - the IsPopup fix was still building and was
not deployed; that window was the pre-fix baseline.)

The agent log was filling with, at roughly 10 lines per second while the pointer moved:

    HandleServerData: got unknown msg type 127, ignoring

**127 is MSG_CROSSING.** From the vendored protocol header
(`upstream/ro/qubes-gui-common/include/qubes-gui-protocol.h`): `MSG_MIN = 123`, so KEYPRESS=124,
BUTTON=125, MOTION=126, **CROSSING=127**, FOCUS=128.

**It is unimplemented, not handled elsewhere.** `grep -rn MSG_CROSSING` over the whole agent returns
NOTHING. `MSG_KEYPRESS`, `MSG_BUTTON` and `MSG_MOTION` are dispatched at
`gui-agent/vchan-handlers.c:1293/1296/1299`; there is no CROSSING case, so every pointer
enter/leave notification from dom0 falls through to the default branch at line 1364.

**Why this plausibly produces the reported artifacts.** MSG_CROSSING carries EnterNotify/LeaveNotify
- it is how the agent learns the pointer has ENTERED or LEFT a window. Dropping it means the guest
is never told the pointer left: hover state, cursor shape ownership and capture are never released
for the window the pointer has departed. Stale hover highlighting and a cursor still being drawn for
a window the pointer is no longer over is exactly "cursor artifacts". UNPROVEN as the cause - stated
as the leading hypothesis, not a conclusion.

**A second, independent cost: the log flood itself.** A LogWarning per crossing event, at input
rate, is file I/O on the input path - directly relevant to Track A, where the whole point is
measuring what makes the guest feel slow. 185 warnings had accumulated in a 35 KB log largely from
this and from `GetRealWindowRect ... inverted DWM bounds ... rejecting`.

**Not yet fixed.** The right handler behaviour needs deciding (on leave: release hover/capture and
stop asserting a cursor for that window; on enter: the converse), and the Linux agent's treatment of
XCrossingEvent is the reference. Recorded now because it was found now, and because an unhandled
input-path message flooding the log at 10/s is worth knowing about regardless of whether it turns
out to be the artifact's cause.

## 2026-08-30 — CAMPAIGN 20260830-035153: 32 passed, 0 failed, incl. the seeded reboot condition

Six runnable cells on release 6022427 (4.3.16), from sealed goldens verified intact BEFORE and
AFTER, payload Gate-0 verified, one Windows guest at a time enforced by the harness.

    WIN10-fresh-1stage   6/6    WIN11-fresh-1stage   6/6
    WIN10-seeded         7/7    WIN11-seeded         7/7
    WIN10-appvm          3/3    WIN11-appvm          3/3     = 32 passed, 0 failed

**The seeded cells are the result that matters.** They arm `xenbus_monitor` to auto-start and write
the pending PV reboot Request MID-MSI - the field state the suppressor exists to defeat, and the
cell its own header calls "the suspected brick". On BOTH OSes the guest came back with a session,
kept the release binary (hash-verified against the package), armed autologon, and left
xenbus_monitor DISABLED and not running *despite having been armed to auto-start*. That is the
suppressor winning against an injected state, not a clean guest staying clean.

**The dialog criterion is now measured rather than assumed.** Previous campaigns asserted
"xenbus_monitor disabled", which is the MECHANISM; nothing looked for the dialog. Every install cell
now runs `guest/reboot-dialog-watch.ps1` throughout, and the grade distinguishes
no-summary / NO-SAMPLES / BLIND / COVERAGE-GAP / DIALOG-OBSERVED / clean-with-samples. Only the last
passes, and it reads "the watcher proves it looked". Fail-proof on record (H5 plain PASS, not
PASS-UNPROVEN): `-SelfTest` returned
`{"matched":["You must restart your computer to apply these changes"],"detector_fires":true}`,
writing to a SEPARATE file with injected records tagged - the direct fix for the 2026-08-28
retraction where a cell measured its own injection.

**Cells swapped, and why.** The previous campaign's win10-2stage and win10-upgrade-stock were
INVALID because neither could build its own entry state (testsigning-off on a clone whose boot disk
driver is test-signed; a precondition built by uninstalling QWT, which P1.0 forbids). They were
replaced by the seeded cells, which are runnable AND test the goal's own criterion adversarially.
The two INVALID cells remain unfixed and are NOT claimed - see below.

**What this campaign does NOT establish**, stated so the 32 greens are not over-read:
 - the TWO-STAGE install path (needs an ST0 entry via stick; ST0.10/ST0.11 are sealed and ready)
 - UPGRADE-OVER-STOCK (needs a legal precondition, not an uninstall)
 - PV NETWORKING - no NET cell ran; "network present" is untested here
 - xencons in-cell (it binds, proven separately, but no cell asserts it)

## 2026-08-30 — FINAL CAMPAIGN 20260830-062519: 36 passed, 0 failed, all assertions live

Release 6022427 (4.3.16), sealed goldens verified intact before AND after, Gate-0 payload, one
Windows guest at a time enforced by the harness.

    WIN10-fresh-1stage  7/7      WIN11-fresh-1stage  7/7
    WIN10-seeded        8/8      WIN11-seeded        8/8
    WIN10-appvm         3/3      WIN11-appvm         3/3      = 36 passed, 0 failed

Every install cell now asserts all seven: session, agent==release (hash-compared), **no premature
reboot dialog with the watcher proving it looked**, **PV console bound (CONS err=0 svc=xencons)**,
autologon armed, xenbus_monitor disabled by the shipped INF, xenbus_monitor not running.

The seeded cells add an eighth (monitor armed, Request lands mid-MSI) and are the load-bearing
result: with xenbus_monitor armed to auto-start and a pending PV reboot Request written MID-MSI,
both guests came back, kept the release binary, showed no dialog, and left the monitor disabled and
not running. That is the suppressor beating an injected state.

### Criteria status against the goal

| criterion | status | evidence |
|---|---|---|
| 6 cells, no regressions | MET | this campaign, 36/0 |
| premature reboot dialogs gone | MET | watched in all 4 install cells incl. both seeded; detector fail-proof on record |
| all drivers present | MET | CONS/IFACE/VBD bound in-cell; xennet/PV NIC proven on both AppVMs by transfer |
| network present | MET | 25 MB moved on win10-app and win11-app, each adapter's own RX accounting for it |
| two-stage (E1) install | MET | tools/grade-twostage.sh 9/0 - both stages, two run_ids, testsigning-off precondition |
| upgrade-over-stock | **NOT MET** | MY provisioning attempt failed; stock QWT itself installs fine. Leading cause: no reboot after phase 2, so stock is installed but inactive |

### The one open item, stated precisely

`REAL_STOCK_EXE=qubes-tools-4.2.2.exe` provisions Windows and reaches a desktop (Test Mode
watermark, so the stick's firstboot ran), but `qrexec alive` never fires in 51 minutes.
`admin.vm.CurrentState` works on that guest while `qubes.VMShell` returns "Request refused", which
means the GUEST's qrexec agent never connected - policy is fine.

SUPERSEDED. The 4.2-vs-4.3 protocol theory was hallucinated and is retracted (see the retraction
entry). The mundane candidate: the stick installs stock from an onstart task and never reboots, and
QWT needs a reboot before its drivers load - so stock ends up installed but inactive.

## 2026-08-30 — C1.11 ACCEPTED: clean install on Windows 11 24H2

**23 PASS, 2 N/A, 0 FAIL.** Guest `win11-c1`, cloned from the sealed `win11-base`, same primer route
as Win10. This closes the second of the three paths RELEASE-NOTES-4.3.16 listed as untested
(*"Clean install on Windows 11. Only Win10 was graded on pristine media."*).

Four PRECONDITION lines: three at `testsigning_active:false, installed_qwt_count:0` (the two C12
repeats plus the `/auto` run — the stage re-detected each time) and the fourth at
`testsigning_active:true` for stage 2 after the single reboot. `stage2-install ok:true`.
`restarts=1`, so the resume fired exactly once.

Cold-boot acceptance identical in shape to Win10: `pv_disk_bound`, `pv_console_bound` (xencons),
`idd_device_bound` + `desktop_on_idd` + modes `5120x1440, 1024x768`, `user_data_on_private` (reparse
to `Q:\Users`), `pnp_no_unexpected_errors`, `boot_events_clean`, agent hash == manifest, pixels
change in dom0, `CHROME=OK 3826x1016`. Same two honest N/A (`pv_drivers_bound`,
`network_carries_traffic`) — the guest is offline by design.

**Timing difference worth recording for future waits:** Win11 is consistently slower through this
path than Win10 — stage-1 reboot at t+234s vs t+142s, qrexec back at t+410s vs t+309s, and stage 2
still writing its RESULT after qrexec answered on both. That gap is exactly what made the old
timer-based selftest exit early on Win11 and call a working primer broken. Wait on the SIGNAL
(`stage2-install ok:true`), never on an elapsed-time guess.

## 2026-08-30 — RND-7 PASSES with both directions proven; RND-4 is UNMEASURABLE on this rig

**RND-7 (compound chrome) PASS, and this is the cell the 2A-chrome work exists for.** `chromerepro`
creates a main window plus four layered/transparent/toolwindow "shadow strips" owned by it — the
Office border artefact in miniature. Measured on `win10-tpl`:

    guest-side (EnumWindows, CharSet.Unicode):  5 visible top-level HWNDs
      QubesChromeReproMain    layered=False transparent=False toolwin=False owner=0x0
      QubesChromeReproShadow  layered=True  transparent=True  toolwin=True  owner=0x60130   x4
    dom0 (qtest shot):                          1 window mapped, 612x446

Exactly the acceptance shape: before = 5 bordered windows, after = 1. The vacuity guard is
satisfied positively — the four strips were *proven present in the guest* in the same run, so
"only one reached dom0" is a filter result and not an absence of stimulus.

**RND-4 (toasts) cannot be graded on this rig, and that is recorded as INVALID-VACUOUS rather than
as either verdict.** SG0.4 is explicit: *"nothing appeared in dom0" passes only when the same run
proves the stimulus existed guest-side; absent stimulus = run FAILS.* No toast ever rendered:

| attempt | result |
|---|---|
| `fire-toast.ps1` over qrexec | `{"fired": true}` — but that is the API accepting the call |
| enumerate for 16 s after firing | no new window; the only CoreWindows are pre-existing and unchanged |
| scheduled task `/ru user` | `TOAST_NEVER_VISIBLE` |
| scheduled task `/ru user /it` | `TOAST_NEVER_VISIBLE` |

**The reason the first attempt could never have worked** is worth keeping: qrexec on this testbed
runs as **`NT AUTHORITY\SYSTEM`** (dom0 policy, see the presession-qrexec-system memory). Toasts are
PER-USER. A toast fired from SYSTEM is accepted by the API and rendered for nobody — which is
exactly why `fired:true` and an empty screen are consistent. That trap applies to every shell-UI
cell, not just this one: **anything needing the interactive user's session (toasts, Start, shell
flyouts) must not be driven directly over qrexec.** Scheduling it as the user, with and without
`/it`, still produced nothing, so the remaining cause is in the image or the toast payload and the
instrument needs work before RND-4 or SG7 can carry a verdict.

Consequence: **SG7 (toasts survive the filter) inherits this** — its positive arm is RND-4, so it is
`PASS-UNPROVEN` too. Recorded, not skipped.

## 2026-08-30 — RETRACTION: "the toast never rendered" was WRONG. It rendered; my detection failed.

**Owner, watching the actual display: *"during the test, the toast WAS onscreen."*** That is direct
evidence and it overrides every negative I recorded. The earlier entry claiming
`TOAST_NEVER_VISIBLE` — and the RND-4 `INVALID-VACUOUS` built on it — are **withdrawn**. The product
criterion PASSES: a toast fires, renders, and reaches dom0, so the compound-chrome filter is not
eating notifications (the CLAUDE.md 2A-3c guard holds). SG7's positive arm is satisfied by
observation; its diag-build fail-proof remains owed.

**Three compounding instrument errors, all mine:**

1. **`qtest shot` for an override-redirect surface.** It sees managed windows only. Its "0 windows"
   was never evidence of anything — the very trap RND-0's blindness table exists to prevent, and
   which I then wrote into the protocol as RND-0b *after* falling into it.
2. **My `EnumWindows` filter was too narrow.** It required the owning process to match
   `ShellExperienceHost|explorer|...` or the class to match `CoreWindow|Toast|Flyout`. A Win10 toast
   that does not present under those names is invisible to it. I treated a filter miss as an absence.
3. **`fullshot` timing.** I captured at ~6 s and ~10 s after kicking a scheduled task that has its
   own start latency. A transient toast can be gone, or not yet up, at both instants. One sample
   either side of an unmeasured latency is not a search.

**The methodological failure underneath all three:** I asserted a NEGATIVE from instruments I had
not validated against a KNOWN-PRESENT instance of the thing. The protocol's own rule covers this —
a check counts only once it has been seen to FIRE on a positive — and I applied it to the product's
checks while exempting my own ad-hoc probes. A "not found" from an unvalidated detector is not a
finding; it is an unmeasured cell.

**Second, unrelated harm in the same run.** SG3 maximized a guest Notepad to 5088x1368, which mapped
onto the owner's real display and **stole keyboard focus mid-work**: *"some shitty window captured
focus in front of my keyboard so this exact run is spoiled."* Window-mapping cells are not
background work — they put windows on the owner's actual screen. Guest halted immediately.
**SG0.2 already anticipates this** ("all per-window fullscreen-gate cells run at a sub-host guest
resolution ... so even a broken gate maps a bounded 1600x900 bordered window") and I did not apply
it. Any cell that maps a window at or near host size must either set a sub-host guest resolution
first, or be scheduled with the owner. Recorded as a standing precondition, not as a one-off
apology.

## 2026-08-31 — the first DIAG-BUILD fail-proof, and a fabricated FAIL that took an hour to write off

### SG2's fail-proof is EARNED (`borderless-fullscreen-gated`)

The Mode-2 gate — a borderless screen-sized window is mapped only when `service.gui-fullscreen` is
set — had never been seen to fail, so under H5 every row citing it could only say PASS-UNPROVEN. It
is now proven, by the first diag build of this campaign:

| | binary | SG2 probe (1024x768 borderless) | verdict |
|---|---|---|---|
| release | `20cab4c5…` | `mapped=no`, agent logged `hidden (set service.gui-fullscreen to allow)` | PASS |
| diag `diag/sg2-mode2-gate-removed` | `c507ed21…` | `mapped=yes`, present in dom0 in **6/6** samples | FAIL — "the gate leaked" |

Same harness, same probe, same guest, running image hash asserted on both sides. **SG4, SG3 and SG9
all still passed on the diag build**, so the change moved exactly the check it targeted and nothing
else — which is what makes the red attributable. The release binary was restored afterwards and its
running image hash re-verified.

The procedure is now written down as protocol §0.13b (D-1..D-9) so the remaining ~19 safeguard
clauses do not have to rediscover it.

### A FAIL I fabricated, and how it was written off

The D-9 restore-confirm run scored **SG2 = FAIL: "a 1600x900 window reached dom0 — the gate
leaked"** on the *restored release* binary. Taken at face value that would have retracted the proof
above. It was mine, not the product's:

* I launched the runner with `nohup … &` *inside* an already-backgrounded task. The wrapper exited
  instantly, the harness reported **exit code 0**, and the teardown killed the process group — but
  the `nohup`'d runner **survived**, which is exactly what `nohup` is for.
* Believing it dead, I `rm -rf`'d its output and started a second run **against the same guest and
  the same directory**. The two interleaved.
* Tells, all present in the log: doubled banners (`=== SG4 ===` at 08:29:59 *and* 08:32:04), and a
  probe JSON whose `"mode"` disagreed with the banner above it.
* The FAIL was scored against the *other* run's **captioned** probe, which maps legitimately at
  1586x893 — within the ≥93%/≥88% size tolerance the harness uses to identify its own probe.

This is CLAUDE.md's "run VM-mutating jobs serially", broken in a new way. Two durable fixes, not a
resolution to be more careful:

* **protocol rule 14** — never background a runner twice; and an `exit 0` whose `verdicts.tsv` is
  absent or empty is a *killed* run, never a clean one.
* **protocol rule 15 + `mgmt/harness/vmlock.sh`** — every guest-touching runner now takes a per-VM
  `flock`. A second runner refuses to start and names the holder's pid. Re-entrant within one job so
  a harness can still call another as a subroutine. **Validated the same day**: with a run in
  flight, a second invocation printed `REFUSING TO START`, named the holder, and created nothing.

**Provenance of the SG2 proof was then audited for this failure mode and it is clean**: the red run
has exactly one banner per cell; the green run's directory holds three runs 30 minutes apart with no
overlap, and the surviving rows are the last one's. Neither side carries the signature.

*Lesson worth more than the proof: when a verdict surprises you, look for a second runner before you
believe it.*

### Fault-injection build is up (`diag/faultinject`)

`agent/gui-agent/faultinject.c` was already written but had never been built. CI now produces an
agent with `QGA_FAULT_INJECTION=1` (`gui-agent.exe` sha `a6da96e9…`), via a one-line flip of the
msbuild default on a diag branch — no workflow input needed.

This vehicle is **stronger than SG2's pairing**: every fault defaults to OFF and needs an explicit
registry value, so the unarmed fault build is behaviourally identical to the release and *both*
sides of a proof come from **one artifact**. Green→red→green is then attributable to the registry
value alone, not to a build difference.

`mgmt/harness/failproof-faultinject.sh` drives it for `keyed-mutex-recovered` and
`capture-thread-survives-resize`, reusing RND-8 as the instrument rather than writing a second one
that would itself need validating. One subtlety it encodes: RND-8 counts thread deaths by grepping
for `/capture thread|…/`, and **FI_CAPTURE_EXIT's own trigger message contains "capture thread"** —
so the log half of the red is self-referential. The harness therefore treats the **pixel** half as
primary evidence and refuses to record a log-only red.

### The capture fail-proof was ATTEMPTED and NOT earned — and that is the more useful result

With the fault build installed on `win10-p46`, `FI_CAPTURE_EXIT` produced a textbook cycle on one
artifact, changing nothing but a registry value:

| | abandonments | RecreateDuplication | thread deaths | verdict |
|---|---|---|---|---|
| unarmed | 20 | 46 | 0 | PASS |
| **armed** | 0 | 0 | **1** | **FAIL** |
| disarmed | 9 | 21 | 0 | PASS |

The harness refused to count it, and it was right. Two checks, neither satisfied:

1. **The log half is self-referential.** A direct grep of the agent log showed the *only* line
   matching RND-8's death pattern (`/capture thread|thread exiting|giving up/`) was
   **the injector's own message**, whose old wording contained "capture thread". The check scored
   a death it had detected from the injector announcing itself.
2. **The pixel half did not corroborate.** It reported "pixels changed" on all three mode changes
   *with the fault armed* — so it did not witness a wedge either.

So `keyed-mutex-recovered` and `capture-thread-survives-resize` **stay PASS-UNPROVEN**, and are now
known to be **vacuous for the defect they name**: neither half detects a silent capture-thread
death. That is worth more than the proof would have been — it is precisely the "a check that cannot
fail is worthless" case, caught by building the instrument that could expose it.

Fixed: the injector message now says "the DDA worker", so it can no longer trip the check it
exists to validate. *An injector that manufactures the evidence is worse than no injector.*

**OPEN QUESTION, recorded as a question and not a conclusion:** with the fault armed the run logged
**zero** abandonments and **zero** recreates across three mode changes (against 20/46 unarmed), which
reads as capture being inactive — yet the dom0 pixel hash changed three times with the same ~25–28 s
first-pixel latency as the healthy run. Either capture recovered by a path that logs nothing, or
RND-8's pixel comparison does not actually prove capture is alive. Both possibilities matter, and
neither is established. Do not cite the pixel half as independent evidence until this is resolved.

Subject restored: running hash back to the release `20cab4c5…`, and the fresh agent log contains
**0** `QGAFAULT` lines — a release binary has no injector compiled in at all.

### FI_GATE_OFF: the remaining safeguard proofs no longer need a build each

`FiGateOff()` (agent `6eb3ff4`) turns each `ShouldAcceptWindow` safeguard into a registry bit:
`FI_GATE_MODE1`, `FI_GATE_MODE2`, `FI_GATE_START`, `FI_GATE_SHELLOVERLAY`. Every pairing then comes
from **one artifact** differing only by that value — strictly stronger than SG2's two-binary proof,
and no CI round trip per clause.

Deliberately **not** added to `main.c`'s `DiagWindowFilterOff`, which was the obvious place: that
bitmask ships in RELEASE binaries as a field-diagnosis knob, and widening it would put every new
safeguard bypass into shipped code. These are deliberate defects, so they live behind
`QGA_FAULT_INJECTION` and compile out to a constant `FALSE`.

`mgmt/harness/failproof-gates.sh` drives them, and gets its specificity control for free: P5 grades
four cells at once, so an armed run must redden the **targeted** cell while the other three stay
green. A bit that moves more than its own clause is reported NOT PROVEN.

### A measurement that had been silently returning nothing

RND-8's keyed-mutex counter was a nested-quote `cmd /c powershell -Command "... \"...\" ..."`
one-liner. Measured today: it returns **nothing at all** — cmd echoes the command, no output, no
error. `km`/`rec`/`died` came back empty, `[ "" -eq 0 ]` failed, and the harness wrote
`keyed-mutex-recovered FAIL` detailed " abandonments,  recreates,  thread deaths". A product defect
invented by a broken query. Through `-EncodedCommand` the same query returns `KM=10 RC=23 DIED=0`.

Fixed, and **missing data now reports `INVALID-INSTRUMENT`, never `FAIL`** — failing it is right,
putting it on the product's record is not. Protocol rule 16 names the three harnesses still
carrying the pattern (`u2-coldboot.sh`, `sg1-u2-coldboot.sh`, `stability-e2e.sh`); their verdicts
should not be trusted until converted.

### FI_GATE_OFF results — one proof earned, and a check found blind to its own defect

`FaultGateOff` bits armed one at a time on the gate build `f143f0f1`, each run's startup banner
confirming the bit was live (`gateoff=0x1`, `0x2`, `0x4`):

| bit | cell | result |
|---|---|---|
| `FI_GATE_MODE2` (0x2) | SG2 | **PROOF EARNED** — SG2 FAIL with the bit set, green with it cleared, SG4/SG3/SG9 green throughout |
| `FI_GATE_MODE1` (0x1) | SG4 | not red — **defence in depth**, confirmed from the log |
| `FI_GATE_START` (0x4) | SG9 | not red — **defence in depth**, confirmed by direct measurement |

**`borderless-fullscreen-gated` is now proved from ONE artifact.** Baseline all four cells green;
`FaultGateOff=0x2` made SG2 fail while the other three stayed green; clearing it restored green.
Only a registry value differed across the three runs — strictly stronger than the two-binary SG2
proof, and it validates the whole `FI_GATE_OFF` mechanism end to end.

**Defence in depth, measured rather than assumed.** Both non-reds were investigated instead of
being written off:
* Mode 1 bypassed alone: the agent log shows the probe rejected by the **Mode-2** clause
  (`borderless fullscreen ... hidden (set service.gui-fullscreen to allow)`).
* Start clause bypassed alone: with the bit live and Start opened, `Start surface not presented`
  logged **0** times while `shell surface with no card` logged **5** — the genuine-open gate
  rejects it independently — and dom0 showed only the control window.

#### The serious finding: SG4 could not see the leak it asserts against

With **both** fullscreen clauses bypassed (`FaultGateOff=0x3`), the agent's own log shows it
offered dom0 a full-screen override-redirect window — the precise thing the check forbids:

```
SendWindowCreateInternal: 0x3601e6, (0,0) 1920x1080, override=1
SendWindowMap: QGAPROTO,msg=MAP,hwnd=0x3601e6,ovr=1,style=0x84000000,w=1920,h=1080
SendWindowDamageEvent:   QGAPROTO,msg=DAMAGE,hwnd=0x3601e6,w=1920,h=1080
```

…and `qtest shot` returned **only the control window**, so SG4 scored "not mapped". Override-
redirect windows are undecorated and never appear in that enumeration. **The check would have
passed a build that leaks a fullscreen takeover surface** — the exact class the whole Mode-1/Mode-2
design exists to prevent. (Consistent with the standing note that an empty shot tar is not evidence
of no windows; here a *non-empty* tar was equally misleading.)

Fixed: every `nomap` cell now requires **two witnesses** — no matching window in dom0 **and** no
`msg=MAP` from the agent for that hwnd. Guest-side log evidence does not replace pixels; it catches
what the screenshot structurally cannot see.

This is what H5 is for. The fault build did not just fail to earn a proof — it exposed a check that
could not fail, which is worth considerably more.

**Caveat recorded, not yet fixed:** `p5-since.ps1` marks a LINE OFFSET into "the newest agent log"
and re-resolves "newest" when counting, so an agent restart between mark and count makes the offset
meaningless. Suspected cause of a 3-hit count that a clean direct measurement showed should be 0.
Deny-hit counts spanning a restart should not be trusted until this is reworked to pin the file.

### Audit: a third of the "unproven" rows are not checks at all

Prompted by two class-conditional proofs that both failed for the same reason — I designed them
from the ledger's *detail string* instead of from the check's code — I swept every unproven check
name against `mgmt/harness/`, `tools/` and `guest/`:

* **23 are implemented** by a harness that emits the verdict. H5 applies: each needs a fail-proof.
* **~15 have no implementing harness at all.** They are names written into the ledger by hand from
  a one-off observation. H5 does not apply to them, because there is no deployed check that could
  be "seen to fail" — proving one would mean inventing a check first, and then the proof would be
  about the new check, not about the campaign's evidence.

Those rows need **reclassifying, not proving**: either promote them to real checks (and then earn
the proof) or record them explicitly as observations with the evidence that backs them. Counting
them as "verification gaps to close" overstates what is missing; counting them as PASS would
overstate what is verified.

The two failed class-pair attempts are recorded honestly as `PASS-UNPROVEN` and are worth keeping
as worked examples of the error:

| check | I assumed | measured |
|---|---|---|
| `standalone-nau-removed` | Standalone removes `NoAutoUpdate`, Template keeps it | **both** read `PRESENT=1` — the detail describes a *transition* during a scan, not a steady state |
| `appvm-private-reformatted` | only an AppVM has a formatted `Q:` | `Q:\Users` exists on the **StandaloneVM too** |

Now protocol **rule 17**: design a fail-proof from the check's code, never from its ledger detail;
and `grep -rl <check-name>` first — if nothing emits it, it is an observation, not a check.

### Defence in depth changes how these proofs must be built

Two properties could not be falsified by clearing a single clause, because a second clause defends
the same thing — established from the agent's own log, not inferred:

* `or-fullscreen-never-mapped`: Mode 1 bypassed → the **Mode-2** clause rejected the probe.
* `start-not-presented`: Start clause bypassed → `Start surface not presented` logged **0** times
  while the genuine-open gate logged **5**.

So `failproof-gates.sh` now arms **combinations** (`MODE1|MODE2`, `START|NOCARD`) and takes a
declared list of companion cells that are expected to move with the target. Undeclared movement
still fails the proof — that is what keeps a red attributable.

Two new injector bits invert the direction entirely. Every `FI_GATE_*` bit REMOVES a safeguard,
which can only falsify a check asserting a window is **denied**; the negative control, a maximized
app, and a toast surviving the chrome filter all assert the opposite. `FI_DROP_CAPTIONED` and
`FI_DROP_SHELLSURFACE` add a reject at the very end of the predicate instead. The regression they
reproduce is real: the 2A-chrome filter aimed at Office shadow strips would have silently killed
every Windows notification.

### Gate round 2: one proof earned, two routes measured unusable

Extended injector (`fd01cf82`) adding `FI_GATE_NOCARD`, `FI_DROP_CAPTIONED`, `FI_DROP_SHELLSURFACE`.
Baseline all four P5 cells green; each case armed, then cleared.

| bits | target | result |
|---|---|---|
| `MODE1\|MODE2` 0x3 | SG4 | **PROOF EARNED** — SG4 FAIL, SG2 FAIL as the *declared* companion, SG3/SG9 green, all four green again after clearing |
| `START\|NOCARD` 0x14 | SG9 | **not earned** — bypassing the cardless reject destabilises the WINDOW SET: SG4/SG2/SG3 returned INVALID-INSTRUMENT with `dom0 dims:` **empty**, the control window itself gone |
| `FI_DROP_CAPTIONED` 0x20 | SG3 | **not earned** — the bit works, but P5's own control is a **captioned Notepad**, so it disables the instrument's control. P5 aborted: *"the control window never became visible … the capture path is blind"* |

Both failures are recorded with their reason rather than worked around. The second is the more
interesting: **a fault bit that disables the harness's own control cannot prove anything through
that harness.** Proving `windowed-fullscreen-allowed` needs a control that is not captioned — the
bit is fine, the pairing is not.

`start-not-presented` remains genuinely hard: it is defended by two clauses, and removing the
second one takes the whole measurement with it.

Subject restored and verified twice over: running hash back to `20cab4c5…`, **0** `QGAFAULT` lines
in the fresh log, and a clean P5 with all four cells green.

### Where the campaign actually stands

429 checks — **PASS 299, PASS-UNPROVEN 61, N/A 20**. The 61 split into two very different things:

* **22 rows are hand-recorded observations with no deployed check.** H5 cannot apply. They are
  annotated in the ledger as `NO DEPLOYED CHECK` and deliberately left PASS-UNPROVEN: upgrading
  them would overstate verification, and "proving" one would mean writing a new check and proving
  *that* instead.
* **39 rows are genuinely unproven deployed checks.** These are the real remaining gap.

**The session goal — all verification gaps decisively closed — is NOT met.** What was closed is
the *method*: two proofs earned, the vehicle for the rest built and validated, and four instrument
defects removed that were producing false verdicts. What remains is 39 rows, of which the window
cluster now has a measured obstacle (defence in depth, and control-window interference) rather
than an unknown one.

### PAUSED 2026-08-31 (owner request) — state at the stop

Nothing in flight; both subjects (`win10-p46`, `win10-app`) verified back on the RELEASE agent
`20cab4c5…` with `FaultGateOff` cleared. Tree clean.

**Ledger: PASS 304 / PASS-UNPROVEN 56 / N/A 20 of 429.** The 56 split into 22 hand-recorded
observations with no deployed check (H5 inapplicable — annotated `NO DEPLOYED CHECK`) and 34
genuine rows.

**Resume point.** A build carrying `FI_NOSCREENCONFIG` (0x100) is already built and downloaded at
`~/qwt-accept/20260830-acceptance-4.3.16/diag-gates5/gui-agent.exe`, sha `24d75cd1…`. It suppresses
the screen-window CONFIGURE after a resolution change, aimed at the six-row resolution cluster
(`mode-followed-*`, `pixels-change-after-resize-*`), which reads the `A6CONFIGURE window 0 -> WxH`
line and takes the LAST one. Untested. To resume: deploy it, `gate-preflight.sh <vm> 0x100`, then
armed/cleared runs of `rnd8-resolution.sh`.

**Three checks are measured VACUOUS and need rewriting, not proving** — this is the campaign's
main open item, and it is more valuable than the remaining proofs:
1. `or-fullscreen-never-mapped`'s original detection (screenshot only) could not see an
   override-redirect leak — FIXED by the two-witness change, proof then earned.
2. `keyed-mutex-recovered` / `capture-thread-survives-resize` — the death counter matched only the
   injector's own log line; no independent evidence of a silent capture-thread death exists.
3. `menu-synthesized-onto-owner` / `owner-window-renders` — with `SYNTHPAINT 0` (not one synth
   paint), the cell still reported "the owner's dom0 pixels changed".

**Open scope decision for the owner:** accept documented `PASS-UNPROVEN` with a measured reason
for the observational and vacuous rows (≈1–2 sessions of remaining work), or require PASS
everywhere (weeks, dominated by check rewrites).

### Tractable set, part 1: resolution cluster earned — after repairing the check

`mode-followed-1024x768 / -1600x900 / -1920x1080` are **PASS**, proved on one artifact with
`FaultGateOff=0x100` (`FI_NOSCREENCONFIG`, build `24d75cd1`): armed → all three FAIL
(*"the guest adopted <M> but the agent last told dom0 none — dom0 is on stale geometry"*);
cleared → all three PASS (*"AGENTSCREEN <M> … they agree"*).

**It could not have been earned without fixing the check first.** `mode-followed` was emitted from
inside the *pixel* branch with the detail string *"guest+agent both report <M>"* while `ag` was
logged and never compared. With `AGENTSCREEN none` on every mode it still recorded agreement — and
two of the three rows weren't emitted at all, because the pixel judge went INVALID first and took
the mode verdict with it. **Fourth vacuous check found by the injector.** Now graded on its own.

`pixels-change-after-resize-*` is explicitly **not** earned: the defect destroyed the capture, so
all three reported INVALID-INSTRUMENT rather than FAIL, and INVALID is never folded into a proof.
Open limitation: the harness cannot distinguish *"my instrument broke"* from *"the product broke my
instrument"*.

### Tractable set, part 2: the install-time cluster is not what it looked like

Built a disposable clone (create → tag → copy, per the rig-capabilities skill — a bare `qvm-clone`
is refused because it copies volumes before tags exist; the documented order took **1.8 s**), and
installed a setup tree with `pvnic-selfprime.ps1` removed. Result:

**`pvnic_prime: not in payload`**, `stage2-install / ok:true`. So the defect state *does* exist,
which **narrows a claim previously recorded as "negative proven unreachable by measurement"** — that
finding was about the LATCH (unseeding `NICS`, which the PV stack re-seeds below the task layer).
The PAYLOAD route reaches it.

But it earns no proof, because of a correction to my own earlier audit:

**AUDIT CORRECTED.** The earlier sweep used loose PREFIX matching and wrongly reported six checks as
implemented. Exact-literal grep finds **nothing** emitting `emulated-unplugged`,
`standalone-pvnic-seeded`, `template-pvnic-seeded`, `standalone-nau-removed`,
`maximized-window-maps` or `secure-desktop-left-cleanly`. They are hand-recorded observations; H5
cannot apply. 14 rows re-annotated.

Revised split of the 53 unproven: **36 rows are observations with no deployed check**, **17 rows
across 12 checks are genuine**.

### Incidental: payload verification demonstrated, not assumed

Two independent defects, both refused *before* `msiexec`, and a consistent tree then installed
normally:

* file deleted but still listed → `payload verification FAILED: MISSING pvnic-selfprime.ps1`
* `MANIFEST.json` edited → `MISMATCH MANIFEST.json (got fb598f…, want 7eee93…)` — the manifest is
  itself covered by the sums, so tampering with it is self-detecting.

The installer will not install a partial or tampered payload. That is now measured rather than
believed, from two different directions, as a side effect of trying to build a negative.

### Both remaining vacuous checks repaired and then proven

Neither could be earned until the check itself was fixed — which is the point of the exercise.

**`keyed-mutex-recovered` / `capture-thread-survives-resize`.** Its death counter was a log grep
(`/capture thread|thread exiting|giving up/`) whose only match, with the fault armed, was **the
injector's own message**; a silently dead capture thread emits no such line at all. Frame liveness
is now the primary criterion — `QGAPERF`'s monotonic `seq` must advance across a visible guest
change, which no log line can satisfy. Proven: armed `seq 3 -> 3` → FAIL; cleared `seq 190 -> 237`
→ PASS.

*This also settled an open question recorded earlier today.* With `FI_CAPTURE_EXIT` armed the old
pixel probe reported "pixels changed" and I could not explain it. Now measured: capture really was
dead (`seq` frozen), so **that probe was never measuring live capture** — it was seeing dom0
re-render the window frame on resize. The ambiguity is resolved, not left open.

**`menu-synthesized-onto-owner`.** It hashed the *whole* owner window, so a caret blink satisfied
it — it passed with `SYNTHPAINT 0`, not one paint having occurred. Evidence is now cropped to the
exact rect the agent reports painting (`SYNTHPAINT rx,ry,w,h` are owner-relative), and
SYNTH-without-SYNTHPAINT is FAIL: accounted onto the owner but never drawn there is precisely the
invisible-menu defect. Proven: armed → FAIL on the missing paint; cleared → painted rect
`1,50 229x196` changed `6f477934 -> 228e6e7d` → PASS.

**All four vacuous checks found this campaign are now repaired and proven.** The repairs share one
shape, now protocol rule 18: *bind the evidence to the narrowest thing the property is about.* Not
"a window exists" but "no MAP for THIS hwnd"; not "pixels changed" but "the pixels in the rect the
agent says it painted"; not "no death string" but "the frame counter advanced".

Runbook synced: rules 18–21 (the vacuity test; an injector must not emit text the checks grep for;
classify by exact-literal grep, never prefix; triage by how loud the failure is) and runbook steps
D-0 preflight, D-0b cross-guest parallelism, D-0c repair-before-proving.

### Promotions: 8 rows earned, 5 promoted-but-honestly-unproven, 2 new defects found

The owner selected the silent-failure observations (rule 21) for promotion into real checks.
`mgmt/harness/promoted-checks.sh` is that promotion; every check in it states its route to red in
the header, because one that ships without a route to red is just a longer sentence in the ledger.

**EARNED (8 rows).**
* `standalone-pvnic-seeded` (3) + `emulated-unplugged` (4) — red on `win10-noprime`, a disposable
  clone with the latch tasks, applier and `NICS` removed and then rebooted: `task_main=false
  task_rearm=false`, applier absent → FAIL; and `Realtek RTL8139C+ … | Up` present alongside a PV
  NIC that is not connected → FAIL. Green on `win10-app`: tasks registered, applier `c98dfc40`,
  only `Xen PV Network Device #0 | Up`.
  **This RETRACTS the recorded "NEGATIVE PROVEN UNREACHABLE BY MEASUREMENT".** It is reachable.
  The earlier attempts only unset `XEN\Unplug NICS`, which the PV stack re-seeds; removing the
  TASKS and the APPLIER as well makes it stick.
* `uac-off-secure-desktop` (1) — `PromptOnSecureDesktop=1` → FAIL, restored → PASS. Reversible
  registry plant, no build.

**PROMOTED BUT NOT PROVEN (5 rows), each with a specific reason rather than a shrug.**
* `template-pvnic-seeded` (3) — same code path as the standalone proof, but no TemplateVM run was
  obtained (the probe was not delivered to `win10-tpl`: `PROBE=False`, and that template is flagged
  contaminated). Deliberately **not** upgraded on the strength of the standalone proof.
* `secure-desktop-left-cleanly` (1) — now a real check reading ENTERED/LEFT/QGADESKSTUCK; its red
  needs an injector bit suppressing the desktop re-attach (the v3 deadlock), not yet built.
* `shadow-strips-dropped` (1) — see below.

**Two new defects found, both worth more than the proof would have been.**

1. **The 2A-chrome repro never reaches the chrome filter.** With `FI_GATE_SHELLOVERLAY=0x8` armed
   (banner `gateoff=0x8` confirmed) dom0 still gained exactly one window. The agent log says why:
   chromerepro's shadow strips are rejected by `GetRealWindowRect` as *"inverted DWM bounds
   (0,0)-(0,0) and no usable GetWindowRect"* — **geometrically degenerate, before any chrome
   predicate runs**. So the cell demonstrates that zero-area windows are dropped, not that the
   2A-chrome filter works — and the whole 2A-chrome acceptance rests on this repro. Fix owed: give
   the strips real rects.

2. **`pvnic-latch-readback.ps1` could not describe the defect it exists to find.** On the unseeded
   guest it printed `MARKJSON` and nothing else — `.Hash.ToLower()` on the missing applier threw and
   killed the whole object, so the check that detects a *missing applier* could only ever report
   INVALID-INSTRUMENT for it. Made null-safe.

**Protocol rule 22** added from a restore that silently did nothing: an AppVM's `C:` is volatile, so
a backup in `C:\ProgramData` does not survive a reboot — and conversely a plain reboot is the
cleanest restore for an AppVM, which is how `win10-app` was recovered. Caught only because the
restore is hash-verified.

**Ledger: PASS 319 / PASS-UNPROVEN 41 / N/A 20.** The 41 are 23 observations with no deployed check
and 18 rows across 12 deployed-but-unproven checks.

---

