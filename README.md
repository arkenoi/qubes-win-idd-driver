# QWT-NG 4.3

Qubes Windows Tools, next generation — for Qubes OS 4.3.

A reworked GUI agent, a Xen PV network driver that actually binds, an IddCx display driver
that becomes the guest's real display, and Windows updates that dom0 drives like any other
qube's. Validated on clean end-to-end installs of Windows 10 22H2 and Windows 11 (build 26300),
and the update path on a German Windows 11 25H2 template.

### On the name and version

Upstream Qubes Windows Tools has **no 4.3-versioned build**. Verified against
`QubesOS/qubes-installer-qubes-os-windows-tools`: the highest tag is `v4.2.2-1`, there are no
published GitHub releases, and `qubes-gui-agent-windows` likewise tops out at `v4.2.2`.
`qvm-create-windows-qube` says the same thing independently — on 4.3 it refuses to proceed
with *"Qubes OS does not currently offer an official build of Qubes Windows Tools for 4.3"*.

Anywhere this README says "stock", it means unmodified upstream QWT 4.2.2 as shipped for Qubes.

---

## Download

Release **[v4.3.39-agentf0dd19f](https://github.com/arkenoi/qubes-win-idd-driver/releases/tag/v4.3.39-agentf0dd19f)** — agent `f0dd19f`, package `4.3.39`, built from commit `ab0c1994`. See
[`docs/RELEASE-NOTES-4.3.39.md`](docs/RELEASE-NOTES-4.3.39.md) for what changed and what was
verified.

> **Read this before you install it.** 4.3.39 is the first release in this series cut on a **CLEAN
> acceptance record and no override**. On these exact bytes the **full eight-cell matrix** ran —
> clean install, same-version reinstall, in-place upgrade and template→AppVM derivation, on both
> Windows 10 and Windows 11 — **89 checks passed, 0 failed**, and **all five feature tests passed**
> (`crop-before-map`, `notify-errors-guest-test`, `supervision-gate`, `template-update`,
> `updater-component`).
>
> **The change-scoped gate is still not met.** It requires **19 suites** for this range and the
> receipt names **16** — the highest any release here has recorded, and still short. What the
> missing four actually are, because the summary matters:
>
> * `p3a-etw-gate` — **all four of its failing drills are defects in the suite, not in the
>   product.** An earlier version of this section called two of them a real product defect and a
>   *"double-notification mechanism"*. That was wrong, and wrong in the direction that matters:
>   it reported shipped, specified behaviour as a bug.
>   * `T7a` asserted that a toast whose sender is not on the forward allowlist must never be
>     forwarded. The shipped contract is the opposite:
>     [`docs/ADR-toasts.md`](docs/ADR-toasts.md) §2 is *"the route is decided per toast; the
>     allowlist is a shortcut, not the gate"*, and a toast that is not allowlisted is classified
>     from its own content and bridged when its own verdict says so. The ten forward attempts the
>     drill counted were five informational toasts routed exactly as the ADR requires.
>   * `T7b` reported the allowlisted forward broken. It had happened: the delivery counter had
>     gone blind to an `[INFO]` level tag inserted in front of the lines it matches, and read zero
>     where there were five.
>   * `T5`/`T8c` kill the ETW proxy and then wait for the agent to relaunch it, but
>     [`docs/ADR-supervision.md`](docs/ADR-supervision.md) §5 (owner, 2026-10-07) is *"nothing of ours
>     relaunches anything"*. The agent behaved exactly as the ADR requires. The drills assert a
>     retired contract.
> * **One known issue, already declared**: `toast-hold-test` failed one row of twenty-one,
>   `S3ii-1=PREEMPTED` — `TOASTPREEMPTLOSESBANNER`, listed under *Known issues shipped knowingly*
>   in the release notes.
> * **Two uncovered**, not failed: `failproof-gates` and `failproof-faultinject` aborted at their
>   own control step on a reused test subject and have not been re-run clean.
>
> Because the full set requires `p3a-etw-gate`, and that suite could not pass while four of its
> drills contradicted the product's own ADRs or misread its own logs, this gate has been
> unsatisfiable by construction — which is the real reason no release here has ever met it.
> `T7a` and `T7b` are now fixed. `T5`/`T8c` are not: whether to re-point them at what ADR §5
> actually promises or retire them is the owner's call. The suite has not been re-run either
> way, so 16 of 19 is what is measured, not what is expected.
>
> The gate that should have refused this cut did not run: it matches the *command text* for
> `gh release create`, and the sanctioned cut script runs that from inside itself, where the
> matcher cannot see it. That check now lives inside the cut tool. This release predates the fix
> and so carries no override banner; it is written out in
> [`docs/RELEASE-NOTES-4.3.39.md`](docs/RELEASE-NOTES-4.3.39.md) instead.

**The change you will notice: a Windows qube can no longer lose its entire desktop.**
A guest would keep answering `qvm-run`, keep writing its log, and show nothing at all for the rest
of that boot. What dies is dom0's `gui-daemon`, and nothing restarts it — deliberately, because it
parses bytes a guest controls, so `exit(1)` is fail-closed and that is not being changed. Which
makes every path by which *our* bytes can kill it our defect. The daemon looks window 0 up like any
other window id, so a screen-scoped message with no outstanding `CREATE(0)` is answered with
`exit(1)`; the agent entered that window on **every capture reinitialisation**. Three senders
reached the wire unguarded. The check now lives at the single send-side choke point, so every
screen-scoped sender inherits it. And the thing that walked us in is gone too: the ETW proxy's
helper launch ran on the agent's main loop and was measured at **14.2 s, 15.2 s and 16.5 s** under
a Winlogon secure desktop against 0.14–0.27 s normally — tripping a 15 s watchdog whose reinit is
exactly the destructive window. It now runs on its own thread, and the watchdog measures main-loop
*progress* rather than elapsed duration, which could not tell *blocked* from *slow*.

**A failed capture initialisation reported success**, because the status really was zero and the
caller believed it. **Two dom0 notifications for one broker death** is fixed — the standing P1 on
double notifications. The boot clock pull is gone, and the installer's log no longer depends on a
channel the install itself holds closed: it mirrors to `Q:\Qubes Logs\qwt-improved-install.log`,
written through rather than buffered, so a hung or killed install still leaves a log that ends on
the step it hung in. If you have hit the installer leaving a dead empty window, **that log is now
worth sending.**

**Carried forward from 4.3.38: "updates available" stops coming back a minute after you updated.**
Windows Defender republishes its virus definitions several times a day, and the guest was reporting
them to dom0 exactly like a cumulative update — so a freshly updated qube went back to *updates
available* almost immediately, forever. Definitions no longer raise that flag, so it means
*servicing work is pending*, which is something you can act on. They are still installed, just on
whatever pass runs rather than by prompting one. The long version, including why this is keyed on
WU's classification GUID and not on the update's title, is a few paragraphs down.

**And a crash in our own code is gone.** On a service stop, the pipe server freed its server object
— lock, memory and all — while a per-client thread was still on its way into that same lock. An
18 ms window, measured in the source, that produced an `0xc0000005` in `qubesdb-daemon` at shutdown.
The object is now retained with its lock valid and calls that arrive after the destroy are answered
"no such client". The unhandled-exception filter also learned to put the faulting address in the one
line it actually writes, which is the only reason that crash was diagnosable at all.

Underneath, the de-slice supervisor stopped measuring from a stale clock. When a window no longer
needs the sliced capture path, a supervisor gives the broker a grace period to come up before it
stands the slicing down — and that grace was being counted from a tick taken *before* the launch, in
two places (the second being a "fix" for the first that was itself placed above `WgcLaunch()`, so it
was inert too). A slow broker launch could therefore eat its own grace. Both anchors are now read
after the launch returns, and a teardown no longer leaves the supervisor armed with nothing to
supervise. `E_ACCESSDENIED` at capture init is also handled as the ordinary desktop-switch transient
it is — a UAC prompt or the sign-in screen appearing exactly as capture starts no longer fails it.

Everything 4.3.37 brought — the Start menu as a movable framed window, the broker's per-window crop,
the shadow-restore and spawn-path failures that stopped being silent — is carried forward unchanged.

**What was verified, and what was not.** The matrix — clean install, same-version reinstall, in-place
upgrade and template→AppVM derivation, on **both Windows 10 and Windows 11**, eight cells — ran
against this exact package: **89 checks passed, 0 failed.** The build the captures declare is
`4.3.39+agent.f0dd19fe65d1`, so these measurements are of these bytes and not of a neighbouring
build. **All five feature tests ran and passed.** The acceptance record for ISO `19dcd1bd…` reads
CLEAN and the release carries no `--acceptance-override`.

The change-scoped gate ([`docs/ADR-acceptance.md`](docs/ADR-acceptance.md)) is a separate question
and it is **not met**: 19 suites required, 16 covered. No product defect sits in there: the four
`p3a-etw-gate` failures are all defects of that suite — two drills asserting a contract ADR §5
retired, one asserting the opposite of ADR-toasts §2, one reading a log line whose format had
moved — alongside one already-declared known issue and two suites that aborted on a reused
subject. Each is broken out in the release notes.

The one failure, named: `win11-upgrade`'s guest log sweep, one breach, **zero P1**,
`signatures_unclassified = 1`, on a stock `qubesdb` line — `QpsWrite: [N] client is disconnected`.
That is the daemon cancelling a write to a client that had already closed the pipe, the write-side
twin of five sibling lines our sweep dictionary already settles as normal teardown; the twin's
wording is not in it. The gate counts an unclassified warning because classification is a debt we
owe, not because anything misbehaved: the same cell measured zero dom0-visible failures, zero
crashes, zero bugchecks, zero unrequested agent deaths, zero lost notifications. The churn that
produces those teardowns is ours and stays open as `QUBESDBCONNECTPERREAD` (P2) — we open a fresh
qubesdb connection per read instead of one per process.

One thing this run did settle: the `win10-reinstall` cell, which is where the pipe-server crash above
was caught, **swept CLEAN on a package carrying the fix** — `crash_lines=0`, `wer_crashes=0`,
`error_lines_undeclared=0`. That was the one measurement that fix still owed.

One thing 4.3.38 owed and 4.3.39 settles: the `win11-upgrade` cell that breached on the `qubesdb`
classification debt now sweeps with **zero failures**, on all eight cells.

**On "updates available" reappearing right after an update — this is Windows Defender, and dom0 is telling you the truth.**
On a freshly updated guest, dom0's updates-available can go back to "available" within a minute of clearing. We chased this as a
possible defect and it is not one: the guest's own scan record names what it found — `KB2267602`, a Microsoft Defender Security
Intelligence update, flagged actionable with a download URL. Microsoft republishes Defender definitions several times a day, so
by the time a scan runs there genuinely is a new one. A Windows qube with Defender enabled will therefore show "updates
available" again shortly after you update it, indefinitely, and that is correct rather than a bug — the definitions are real
updates, they are simply published faster than anyone installs them.

**Up to and including 4.3.37 the product did nothing about it, by omission.** The guest scanned with
`IsInstalled=0 and IsHidden=0` and no category filter, so Defender Security Intelligence definitions
were offered, counted and reported to dom0 exactly like a cumulative update, and raised
`updates-available` like one. Nothing suppressed, filtered or deferred them. On those releases the
only lever is Defender itself.

> **Fixed in 4.3.38, and carried forward unchanged.** Definition updates no longer raise dom0's `updates-available`. The
> flag now means *servicing work is pending*, which is a thing an operator can act on. Three
> properties of that change are worth stating, because each is a way it could have been done wrong:
>
> * **Definitions are identified structurally, never by title.** WU classifies every offer, and
>   "Definition Updates" is a fixed classification GUID carried in `Categories`. A title match would
>   have been locale-dependent — the field reporter runs a German edition, where the same offer reads
>   *"Definitionsupdate für Microsoft Defender Antivirus"* — and would have stopped excluding
>   anything the day a product name changed.
> * **The Defender platform update still counts.** The antimalware engine/platform updates are
>   classified as ordinary servicing, not definitions, and they remain real work an operator should
>   see. Neither a KB number nor a title can separate those two; the classification can.
> * **An offer we cannot classify still counts.** If the categories are unreadable, the update is
>   reported. An exclusion that swallowed what it failed to classify would hide real servicing.
>
> Definitions are still *installed* — only the count dom0 reads is narrowed, and the excluded offers
> are counted and named in the guest log rather than silently vanishing. Because installs here are
> dom0-driven, the practical consequence is that definitions now install on whatever pass runs
> instead of prompting one.

What the agent already carries is each offer's **identity** — `UpdateID` plus `RevisionNumber`, taken
straight off the COM object rather than parsed out of a localised title — which is what makes "the
offer the last pass already resolved" distinguishable from "a genuinely new one" at all. Our own
acceptance check does not yet use it: it compares whether dom0 and the guest agree that *any*
update is pending, which catches the two sides disagreeing but makes no judgement about an update
coming back. So a definition republished mid-campaign and an update we claimed to have resolved
reappearing are, to the gate, the same event. That is a gap in our testing, not in the build.

| file | use it for |
|---|---|
| [`qubes-windows-tools-ng-4.3.39-1.agentf0dd19fe65d1.noarch.rpm`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.39-agentf0dd19f/qubes-windows-tools-ng-4.3.39-1.agentf0dd19fe65d1.noarch.rpm) | **dom0** — installs the ISO at `/usr/lib/qubes/qubes-windows-tools.iso`, auto-patches `qvm-create-windows-qube` to use it, and runs nothing in dom0 |
| [`qwt-improved-setup.iso`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.39-agentf0dd19f/qwt-improved-setup.iso) | attach to a running Windows qube as a CD and run `install.cmd` elevated |
| [`qubes-tools-4.3.39.exe`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.39-agentf0dd19f/qubes-tools-4.3.39.exe) | the installer on its own, if you already have a way to get a file into the guest |
| [`SHA256SUMS.txt`](https://github.com/arkenoi/qubes-win-idd-driver/releases/download/v4.3.39-agentf0dd19f/SHA256SUMS.txt) | checksums for all of them |

The dom0 RPM is unsigned, so `qubes-dom0-update` will refuse it; install it directly:

```
sudo rpm -i qubes-windows-tools-ng-4.3.39-1.agentf0dd19fe65d1.noarch.rpm
```

With the RPM in place, dom0 can attach the media itself — `qvm-start <vm> --install-windows-tools`
hands the guest exactly this ISO as a CD.

Upgrading a guest that already runs stock QWT or an older build of this package is a
plain in-place upgrade — run the installer, it detects the older version and lets the
MSI replace it in one transaction. Validated end to end for an upgrade **from an older
build of this package** — 4.3.39's acceptance ran the in-place upgrade cell on both
Windows 10 and Windows 11 and **both swept clean**, 13 checks each, zero failures. An
upgrade from **stock QWT 4.2.2** uses the same unchanged
MSI machinery but has not been exercised on our testbed since August 2026, because the
test images themselves carry a newer build.

**Hand-created qube?** Run `qvm-features <qube> vmexec 1` and `qvm-prefs <qube> qrexec_timeout 1800`
in dom0 (on the template; AppVMs inherit), or the Qubes Update tool fails against it.

**What changed in 4.3.39 — a Windows qube could lose its whole desktop, and we were the ones closing it.**
Two paths by which our own bytes could make dom0's `gui-daemon` call `exit(1)` are closed at a
single send-side choke point, and the thing that drove the agent into that window — a 14–16 s
synchronous helper launch under the secure desktop tripping a 15 s watchdog — is off the main loop.
The watchdog now measures main-loop progress rather than elapsed time, because elapsed time cannot
tell *blocked* from *slow*. A failed `CaptureInitialize` no longer reports success; one broker death
no longer produces two dom0 notifications; the de-slice supervisor stopped reporting deaths already
repaired; the boot clock pull is gone; and the installer's log mirrors to `Q:\Qubes Logs\`
write-through, so a hung install still leaves a log ending on the step it hung in. No driver change
and no security-model change in this range. Full story, and what was not verified, in
[`docs/RELEASE-NOTES-4.3.39.md`](docs/RELEASE-NOTES-4.3.39.md).

**What changed in 4.3.38 — Defender definitions stop raising dom0's update flag, a shutdown crash in
our own pipe server is gone, and the de-slice supervisor measures its grace from a fresh tick.**
Definition updates are identified by WU's classification GUID rather than by title (the reporter runs
a German edition, where a title match would have failed), the Defender *platform* update still
counts as real servicing, and an offer we cannot classify still counts. `QpsDestroy` no longer frees
the server object out from under a per-client thread that is on its way into its lock, and the
unhandled-exception filter now writes the faulting address in the one line it emits. The de-slice
stand-down's grace is anchored after `WgcLaunch()` returns on both paths, a teardown disarms the
supervisor, and `E_ACCESSDENIED` at capture init is treated as the desktop-switch transient it is.
Its notes are [`docs/RELEASE-NOTES-4.3.38.md`](docs/RELEASE-NOTES-4.3.38.md).

**What changed in 4.3.37 — the Start menu is a window you can move, and three things that failed silently now say so.**
The Start menu is an ordinary framed window with a title bar you can drag, and its expanding cards are drawn as their own
windows that dismiss when they should. The reason it used to render partly black or show the desktop through itself was found:
the broker's per-window crop was dead code, because nothing in the agent ever wrote the field the broker reads to locate a
shell surface's pixels, so it had been falling back to a whole-surface crop the entire time. A failed restore of window
shadows on leaving seamless mode used to be discarded, latched "done", and logged as if a retry would follow — the retry was
gated on the other direction and never ran, so guest windows could stay shadowless for a whole session with nothing saying
why; it is now reported as an error naming what you would see. Three spawn paths that returned without logging anything now
say which failed and why, instead of the caller blaming "no usable interactive session yet" for a session that was
demonstrably usable. Applying an exact resolution on the sign-in screen no longer burns a 12-second deadline on a pre-flight
query that cannot see modes on the secure desktop. And `DXGI_ERROR_ACCESS_LOST` — which Windows renders as "The keyed mutex
was abandoned", a message about an object that is not involved — is routed through one reporter across all seven calls, so
nobody chases that phantom again. Its notes are
[`docs/RELEASE-NOTES-4.3.37.md`](docs/RELEASE-NOTES-4.3.37.md); earlier releases:
[4.3.36](docs/RELEASE-NOTES-4.3.36.md), [4.3.35](docs/RELEASE-NOTES-4.3.35.md), [4.3.34](docs/RELEASE-NOTES-4.3.34.md), [4.3.33](docs/RELEASE-NOTES-4.3.33.md), [4.3.32](docs/RELEASE-NOTES-4.3.32.md).

**Provenance.** Every asset above is built by GitHub Actions from this repository at the tagged
commit; the agent is `f0dd19f` on
[arkenoi/qubes-gui-agent-windows](https://github.com/arkenoi/qubes-gui-agent-windows). The
Windows build is not timestamp-reproducible, so binary hashes differ across rebuilds of identical
source; `MANIFEST.json` inside each asset records the exact source commits the build came from.

---
## Read this first

**The binaries are TEST-SIGNED.** The installer runs `bcdedit /set testsigning on`, which
weakens driver-signature enforcement for the whole guest until you turn it off. Stock QWT
signs with its own self-signed "Qubes Windows Tools" certificates, which its installer adds to
the guest's Root store - so stock needs testsigning for its kernel drivers too. Ours is the same
mechanism with our certificate. It is inherent to an unofficial build,
not a defect — but it is a real change to your guest's security posture, so decide about it
deliberately.

**If you install onto an existing qube, check the private volume size first.** Windows Tools
has always placed user data on `Q:\Users` on the private image — that is stock behaviour, not
a change here. But the Qubes default private volume is 2 GiB and a bare Windows profile
already uses ~550 MB, so it is worth extending before it fills:

```
qvm-volume extend <vm>:private 20GiB
```

---

## What you will actually notice

### Dragging a window stops tearing itself apart

On stock QWT, dragging a window in seamless mode leaves visible artifacts — smeared or
stale regions that persist until something forces a repaint. It is **worse on Windows 11**
than on Windows 10. Stock also shows a **z-order dependency**: whether a window repaints
correctly during a drag depends on where it sits in the stacking order, so the same drag
looks fine on a top window and broken on one underneath.

This build's per-window capture removes that artifact class structurally, and each item
was verified against the stock baseline on the same guest (evidence in `FINDINGS.md`):

- **No overlap corruption / occlusion bleed** — every window has its own buffer, so an
  overlapped window renders complete instead of showing debris from whatever covered it.
  Stock's z-order dependency disappears with it.
- **No tearing** — content is byte-fed per window, never sliced out of a half-updated
  composited frame.
- **No wobble** — window content no longer drifts against the frame during a drag
  (scripted 10 s drag: 2 of 219 damage events with any origin drift, max 5 px).
- **No stray border rectangles or double titles** on compound windows (see the Office
  item below).

### CPU cost against stock — measured, and platform-dependent

On **Windows 10** the agent costs a fraction of stock: scroll −88 %, typing −87 %, idle
−70…−87 %, drag −45 %, every repetition of one side beating every repetition of the other. On
**Windows 11** no workload is distinguishable from stock — every difference is inside the
run-to-run spread and none carries a verdict. Stock is an order of magnitude cheaper on
Windows 11 than on Windows 10 to begin with, so there is far less to recover there. Its
working set stays flat where stock's grows ~87 MB per workload. Numbers, method and
caveats: "Performance" below.

### The whole desktop in one window, and back, while the qube runs

Qube Manager's seamless toggle (`qubes.SetGuiMode`) used to do nothing unless
`service.gui-fullscreen` happened to be set, and nothing told you it had refused. Since 4.3.33 it
works on any guest: the guest's whole desktop appears in one dom0 window, switching back returns to
seamless, and the choice survives a reboot. Inside the desktop, applications keep their own title
bars, and resizing the dom0 window resizes the guest's screen to match, including to arbitrary
sizes. It cannot take over your display: the desktop view never comes up covering your screen, and
the guest cannot pick the host's full size on its own — maximizing the window yourself still works.
A guest that never switches never holds a whole-desktop grant, exactly as before.

### Guest notifications appear in dom0

A Windows application's notification is forwarded to dom0's own notification service and shown
there, with the in-guest banner suppressed — so a guest toast reaches you the same way a
notification from any other qube does. It is on by default as of 4.3.30 (it existed earlier but
shipped switched off).

Since 4.3.31 the decision is made **per notification**, not per application: a notification that
needs no answer from you is forwarded, and one carrying buttons stays a guest window so the buttons
still work - unless every one of its buttons is one the bridge can press for you (a link, or a classic
Windows application's own notification hook), in which case it is forwarded with its buttons and your
click in dom0 is carried out in the guest (built, not yet proven on a guest: `docs/ADR-toasts.md` §11).
An allowlist (`NotifyBridgeAllow`) remains as a shortcut for applications whose
notifications are known to be informational, and with none configured a conservative built-in seed
is used — Snipping Tool, Camera, Photos, Security & Maintenance, the backup reminder. See what a
guest actually emits with `notifhost --dump-aumids`.

Anything undecided keeps the ordinary window path: an unhealthy bridge, a notification the
classifier cannot place within about six seconds, or a Windows build whose notification database
does not match what the classifier expects. Fail-open by construction — a notification may lose its
dom0 rendering, never its delivery. `qvm-features <vm> service.legacy-toasts 1` forces the old
behaviour regardless.

Notification cards no longer show black bars between them when several stack up.

### Windows no longer blink black when they are resized

Rebuilding a window's capture buffer — on a resize or a mode change — used to paint the newly
exposed area black for a frame or two. The previous pixels are now carried across the rebuild.

### One mouse cursor instead of two

Stock Windows Tools shows a doubled mouse cursor — dom0 draws its own pointer over the guest
window while the guest also paints one into the captured frame, in every mode. This build
blanks the guest-side cursor so only dom0's is visible.

### No black flash while Windows boots, shuts down or switches sessions

Windows renders its login, lock, "shutting down" and initial-desktop screens through a single
full-screen `LogonUI` window. Mapping it produced a black or blue frame that took over the qube's
window at every boot and shutdown. It is now denied outright — and permanently: the Windows
**secure desktop is never presented to dom0**, which is a deliberate security decision, not a
cosmetic one. A guest that reaches a *visible* Windows login screen is a misconfiguration to fix
(autologon), not something this build will render for you.

### The Windows key and the Start menu in seamless mode

In seamless mode the Windows key is blocked by default, and the Windows Start menu itself is not
shown: on Windows 11 25H2 it cannot be reproduced acceptably as a seamless window. Set
`qvm-features <vm> service.enableWinKey 1` to let the key through for a third-party start menu such
as Open-Shell, which is shown like any other window. If the Windows Start menu is opened anyway
(Shift+Win, or the Windows key with no third-party menu installed), **4.3.35 closes it at once** and
says so once per session — before, it stayed open and invisible and took your clicks. The Qubes app
menu in dom0 is the other way to start programs.

### A qube built from a Windows template boots the first time

Attaching a netvm to a Windows guest used to make its first boot install the PV network drivers and
then reboot itself. Where the root volume persists that is one surprising restart with a black
window for ~30 s; where the root volume is a **discarded CoW overlay — every app qube** — the same
work is redone on every boot, so the qube never finishes starting. Priming now happens once, in the
template, with no network attached at any point. App qubes built from a primed template reach a
logged-in desktop with a netvm attached and no restarts.

### Office windows render as one window

Post-2013 Office surrounds its frame with layered, click-through shadow HWNDs. The agent
used to map each as a separate window, so dom0 drew a border around every fragment. Measured
on real Office in seamless mode: **8 visible Word windows in the guest, 4 in dom0** — the
three real document frames plus a genuine dialog. All four shadow strips dropped, no real
window lost.

### Windows updates work from the Qubes Update GUI, like any other qube

The qube reports available updates through `qubes.NotifyUpdates`, so it appears in the Qubes
Update tool with the same "updates available" marker as a Fedora or Debian template, and
updating it is the same click. No separate command, and no networking for the guest: update
traffic goes over `qubes.UpdatesProxy`, and the proxy is raised only for the duration of a
pass. Windows' own automatic updates are turned **off** — dom0 decides when the qube updates,
exactly as it does for Linux qubes.

This needed work on our side because dom0's updater does not call an agent in the guest, it
*injects* a Python one per run — which is why every Linux qube is updatable with nothing
preinstalled, and why Windows never could be. The guest now answers dom0's own command
sequence and runs the Windows updater where dom0 expects its injected agent. Details, the
replay harness and every measurement behind it are in `FINDINGS.md`.

What dom0 shows is what happened. The result lists each update — installed, staged to complete
at the restart, deferred to the next pass, informational, or failed with its reason — and a fresh
scan after the pass decides whether the qube still shows "updates available". An update installed
by Windows Update's own installer (Defender, the Malicious Software Removal Tool, the Windows
Security platform) counts as installed only when the installer's result and a check of what the
update changes agree, not on an exit code alone; until 4.3.33 the Security platform update was
reported current while its installer had been run with a switch that installs nothing.

Two things to know. **Two settings live in dom0** and cannot come from the guest — the dom0
package applies NOTHING and runs nothing in dom0 - apply them yourself to each Windows qube, including one created
later: the `vmexec` feature (or dom0's update commands arrive as shell text at `cmd.exe` and the
run aborts) and a raised `qrexec_timeout` (a Windows boot *applying* an update took 259 s to
answer qrexec, against a 60 s default). And **the qube shuts down after installing an update** —
that is not a failure: Qubes destroys a domain on a guest-initiated reboot, and Windows finishes
the update during its next boot, which happens by itself the next time the qube is started or
updated. For a template, that boot is exactly what commits the update to the template root.

### Networking runs over the PV path

Stock QWT 4.2.2 silently falls back to an emulated Realtek NIC (see below). This build binds
the Xen PV network device properly and the emulated NIC is unplugged.

### Attaching a netvm no longer needs a reboot

QWT applies the qubesdb-driven static IP only at boot, so attaching a netvm to a running
guest left it on an APIPA address. A SYSTEM task triggered by "network connected" re-runs the
network setup when an interface arrives. Verified: detach then attach restored the address by
itself in 15 s.

### Upgrading from an earlier build of this package?

Three defects that earlier builds of *this package* introduced — PV disk drivers dropped, a
double cursor, and user profiles left on the root volume — are fixed. Stock QWT never had
any of them, so they are not improvements over stock and are not listed here as such; see
"Three regressions this package had introduced against stock" below.

### A real display driver, which stock does not have at all

Stock Windows Tools ships **no display driver**. The guest runs on the emulated Basic Display
Adapter, whose mode list is fixed — so an arbitrary size like 2566x1022 is simply never
offered, and matching the guest resolution to a dom0 window is unreachable by construction.

This package installs and **activates the Qubes IddCx display driver by default** — an IddCx
monitor becomes the guest's **sole active output** and the emulated VGA is disabled, so the
guest resolution follows the dom0 window with no fixed-mode snapping. (If activation ever
fails the install still completes so the guest is usable, and the failure is flagged loudly in
the install log for retry.)

It can be turned off. Arbitrary resolutions are the only thing that depends on it, so a guest
on the Basic Display Adapter is a reduced configuration, not a broken one — and on hardware or
a Windows build where the IDD misbehaves, being able to say so beats a guest with no display:

- `install.cmd /noidd` — fresh install, never activate it;
- `install.cmd /iddoff` — a guest that already has it: back to the Basic Display Adapter and
  reboot. This is also the **recovery** path when a guest comes up with a black, unresponsive
  window, and it works over qrexec with no usable display in the guest;
- `install.cmd /iddonly` — (re)activate it later.

Two things are worth knowing about how it behaves, because they are not obvious:

- An IddCx monitor arrives **connected but INACTIVE**. It is not attached to the desktop
  until something performs a display-topology apply naming its path. The agent does this at
  startup, in the interactive session — the installer cannot, because its boot-resume task
  runs as SYSTEM in session 0 where the apply returns `ERROR_ACCESS_DENIED`. (Windows 11
  happens to perform an apply on its own; Windows 10 does not. The driver itself has no
  OS-build branch. An earlier build of this package shipped without that apply, so `/idd`
  worked on 11 and silently did nothing on 10.)
- Every other display is **detached**, not merely deprioritised. An additional active display
  enlarges the desktop bounding box the agent maps as the screen, which lets Windows place
  windows in a region dom0 never sees and breaks seamless coordinates.

---

## Upstream defect: PV networking could never bind

This is the one genuine defect in stock Windows Tools that this build fixes. Everything else
below is either a capability stock does not have at all, or a regression this package had
introduced against stock and has since corrected.

QWT 4.2.2 ships a Xen PV network stack that **cannot bind**. Its `xenvif` publishes VIF
interface revision `0x09000004` at most, while its own `xennet` requires `0x09000005`. No
hardware ID intersects, the `XENVIF\…&DEV_NET` child sits at code 28
(`CM_PROB_FAILED_INSTALL`), and Windows silently falls back to the QEMU-emulated Realtek NIC.
Networking *works*, which is why it went unnoticed — but never over the PV path.

Upstream `xennet` raised its requirement in July 2024; upstream `xenvif` only gained revision
5 in June 2025. The pin Qubes carries sits in that eleven-month window, identically on `main`,
`release4.3` and `v4.2.0-1`. This build ships `xenvif` built from xenbits master.

```
before:  Realtek RTL8139C+ Fast Ethernet NIC   (emulated)
after:   Xen PV Network Device #0              (emulated NIC UNPLUGGED)
         10.137.0.70 -> gateway reachable
```

---

## Performance

gui-agent CPU, % of one core, median of 3 (2026-09-03, `tools/bench-stock-vs-ours.sh`, run as
part of 4.3.18 acceptance). ONE guest per platform, ONE install, ONE display stack — only
`gui-agent.exe` is swapped, and both binaries are built by the same CI job from the same
toolchain, so neither the compiler nor the install is a variable. Stock is this fork's upstream
merge-base (`431e4517`, three commits after `v4.2.2`). 3 repetitions per side, interleaved,
45 s settle after every swap; each session 6 repetitions, 6 valid, 0 invalid, the running
binary's hash read back from the guest every repetition. Both guests at 5120x1440. **The
Windows 10 result was reproduced in a second independent session the same day** — the check
that matters, because an earlier run at a short settle produced a within-session result that a
second session overturned.

**Windows 10** (19045) — every row has disjoint ranges, i.e. every repetition of one side
beat every repetition of the other:

| workload | stock 4.2.2 | this build | delta |
|---|---:|---:|---:|
| scroll | 44.283 | **5.351** | −87.9 % |
| typing | 23.991 | **3.164** | −86.8 % |
| idle   | 3.426–4.879 | **0.653–0.976** | −71.5…−86.6 % |
| drag   | 32.519 | **17.928** | −44.9 % |

The second session read scroll −87.6 %, typing −84.5 %, drag −50.6 % — again every row disjoint.

**Windows 11** (24H2, 26100) — stock is an order of magnitude cheaper here to begin with, and
nothing carries a verdict. Two sessions again, and the differences that looked real in one were
absent or inverted in the other — between-session variance swamps them all:

| workload | stock 4.2.2 | this build | delta | |
|---|---:|---:|---:|---|
| drag   | 15.813 | 13.758 |  −13.0 % | inside noise; +36.5 % and disjoint in the other session — sign flips, no verdict |
| scroll |  3.747 |  3.463 |  −7.6 % | inside noise — no verdict |
| typing |  2.496 |  2.664 |  +6.7 % | inside noise; +200 % and disjoint in the other session — not reproduced, no verdict |
| idle   |  0.660 |  0.330 | | spread up to 284 %, several phases read 0.000 — no verdict |

The acceptance gate is OS-aware for exactly this reason: on Windows 10 the fork's win must show
(scroll disjoint, ours better) or the build fails; on Windows 11 indistinguishability from stock
is the pass condition, because the platform bounds every agent there. The first-session Windows
11 drag reading is being root-caused, but two sessions disagreeing on its sign is not a verdict.

Read the Windows 10 margin as scaling with screen area and with how many top-level windows the
session has: stock re-enumerates every window on every captured frame (its own source says
`TODO: don't enumerate all windows every time, use window hooks`) and never drops a frame whose
pixels did not change, both of which this build does. That is per-frame fixed cost, not pixels
moved — the transport is identical on both sides. Where stock's per-frame cost is already low,
as on Windows 11, there is nothing for that to recover and our added machinery shows up instead.

This measures agent CPU for a fixed workload, not frames delivered. The earlier "2× stock on
typing" result was real for the build and guest it measured and is superseded — typing carries
no verdict on Windows 11. Method, per-repetition values, what this does not measure, and
every retraction: [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

---

## Windows updates

dom0 drives every pass (Qube Manager); the guest never installs on its own (`NoAutoUpdate=1`).
All content travels over a qrexec relay that serves an allowlist of Microsoft's update hosts and
refuses every other host with a final `403` — no netvm, no general egress. Windows Update's own
online search, through the same relay, decides what is offered. How an update is then installed
depends on what it is:

- **What the Microsoft Update Catalog serves as an `.msu`** — the cumulative updates for Windows
  and .NET — is fetched by the pass and installed from that package.
- **Everything else** — Defender signatures and platform, the Malicious Software Removal Tool, the
  Windows Security platform — is installed by **Windows Update's own installer**, which runs the
  update's own command line. The pass fetches the content through the relay and hands it over
  (`IUpdate2.CopyToCache`); no code of ours runs a vendor installer or chooses its switches.
- Windows Update's **downloader** is never used: it needs egress for Delivery Optimization, cannot
  be told which package to fetch, and crawled at 120–150 KB/s where it did run (never
  root-caused).

**A qube cannot restart itself.** A guest-initiated reboot leaves a Qubes HVM halted, so when an
installed update needs a boot, the pass ends by shutting the qube down and Windows completes the
update at its next start. Autologon is re-checked first: a qube that would come back to a sign-in
screen, where qrexec has nobody to run as, is left running and says so. When Windows Update's
first contact through the proxy fails with `0x8024402C`, the qube does not restart on its own:
dom0 is told exactly that and asked for one restart, which clears it (measured) — asked once per
boot, never in a loop.

The proxy is **template-only**: an app qube, a disposable or a standalone never acquires a proxy
and never starts the relay. A standalone with real internet turns the proxy updater off *and*
lifts `NoAutoUpdate`, so it is not left with updates disabled and nobody driving them.

Three failure modes that made this unreliable are fixed in 4.3.3: `0x80072F8F` (schannel could not
fetch Microsoft's certificate trust lists on a guest with no direct route — the CTLs are now
mirrored through the relay); a truncated response being served to Windows as a success (the relay
now answers `502` rather than hand over a short body); and the tail of a long command's output
being lost when the qrexec channel closed. Updates that genuinely cannot be installed — post-EOS
packages, express-only packages with no route, WU-client blobs DISM will not take — are now
reported as informational rather than counted as failures.

The catalog returns every file bundled with an update. For KB5121003 it also returned superseded
KB5043080 — DISM rejects it (rc=552), poisoning CBS so the cumulative rolled back at boot
(`0x80070490`). Filtering by KB before download fixes it; bandwidth is secondary.

Measured (KB5121003, 26100.8875 → 9168): offered 5,376 MB, transferred 4,867 MB — 509 MB (9.5%)
avoided — at 12.8 MB/s, ~45 min end to end. The catalog ships full cumulatives, not deltas:
5,029 of 9,036 payload packages are inapplicable (86.7% language variants of server FoDs)
≈ 24% of bytes, the price of a closed egress surface.

---

## Configuration

Everything optional is a Qubes feature, set from dom0 and read by the guest — nothing to edit
inside Windows. The full reference, including precedence, defaults and the guest-local registry
overrides, is [docs/QVM-FEATURES.md](docs/QVM-FEATURES.md). The short version:

| set in dom0 | what it does |
|---|---|
| `qvm-features <vm> service.enableWinKey 1` | let the Windows key through, so a third-party start menu (Open-Shell, for example) opens. The Windows Start menu itself is not shown in seamless mode and is closed if opened. Default: blocked in seamless mode |
| `qvm-features <vm> service.gui-fullscreen 1` | allow a **borderless true-fullscreen app window** (a game, a video, a presentation taking over the screen). A maximized app with a title bar is always allowed; the boot/shutdown screen is never allowed, feature or not. It no longer gates the **non-seamless desktop**: dom0 asking for the whole desktop in one window is honoured on any guest — the desktop surface is plugged in like a monitor when you switch and unplugged when you switch back, so a seamless guest still never holds a whole-desktop grant |
| `qvm-features <vm> service.hideGuestTitleBar ""` | keep the guest's own title bars. Stripping them so only dom0's decoration shows is the **default since 4.3.21** — set the feature to an empty value to opt out |
| `qvm-features <vm> service.notify-bridge 0` | turn **off** the forwarding of guest notifications to dom0. Default: **on** since 4.3.30 |
| `qvm-features <vm> service.legacy-toasts 1` | keep the old in-guest toast windows for this qube. It **wins over** `service.notify-bridge`, so it holds even if the bridge is enabled or becomes default-on later |
| `qvm-features <vm> service.notify-errors 0` | turn **off** the agent reporting its own error conditions to dom0. Default: **on** since 4.3.30 |
| `qvm-features <vm> service.gui-agent-debug 1` | full diagnostic logging in one switch: per-frame performance records, protocol traces and debug level. Set this before collecting a log for a bug report, unset it afterwards — a normal log is tens of KB, a debug log is megabytes |
| `qvm-features <vm> service.uac-disable 1` | turn UAC **off** in the guest — the Windows equivalent of passwordless sudo, so use with care: anything running in the qube reaches admin/kernel without asking, and that is the surface facing the hypervisor. Reboot required. Only an explicit `1` acts; clearing the feature puts UAC back. **Set it on the TEMPLATE** — an AppVM's system drive is restored from its template at every boot and Windows reads this setting at boot, so a value applied inside an AppVM can never take effect |

They are ordinary Qubes service features — any non-empty value enables, `qvm-features --unset`
turns them off — and all are read **once, when the agent starts**, so restart the qube after
changing one.

Not configurable, deliberately: **where a UAC prompt is drawn**. It is always the normal
desktop, which makes the prompt an ordinary window — a standalone dom0 window in seamless mode,
or a window inside the desktop window in non-seamless mode. Windows' secure desktop is never
shown to dom0 in any mode; a prompt drawn there would be one nobody could see or answer (that
was the "unclosable black window").

One thing is configured **inside the guest**, because it is about the guest's own file system:
**persistent directories**. An AppVM's `C:` is restored from its template at every boot; list
the directories that must survive in `Q:\config\qubes-bind-dirs.d\50_user.conf` — same syntax
and same names as Linux Qubes' `qubes-bind-dirs`, with Windows paths — and they are copied to
the private volume once and re-attached as junctions at every boot, before any service starts.
See [docs/BIND-DIRS.md](docs/BIND-DIRS.md) for the syntax, the exact differences from the Linux
feature and what it refuses.

Two settings are required rather than optional, and the dom0 RPM applies them for you
(apply them yourself in dom0; this package ships no script that does it): the `vmexec` feature, without
which dom0's update commands arrive at `cmd.exe` as shell text and the run aborts, and a raised
`qrexec_timeout`, because a Windows boot that is *applying* an update can take minutes to answer
qrexec against a 60 s default.

### Persistent directories on an AppVM (`bind-dirs`)

A Windows AppVM's system drive is restored from its template at every boot, so anything an
application writes under `C:` is gone at the next start. `bind-dirs` is the Windows counterpart of
Linux `qubes-bind-dirs`: it makes named directories live on the qube's own private volume (`Q:`)
while still appearing at their normal path on `C:`.

Create `Q:\config\qubes-bind-dirs.d\50_user.conf` **in the AppVM** and reboot:

```bash
# Keep this application's state across reboots.
binds+=( 'C:\ProgramData\SomeVendor\SomeApp' )
binds+=( 'C:\Program Files\SomeVendor\Plugins' "C:\Data\Shared" )
```

The syntax is the subset of bash the Linux `.conf` files actually use — `binds+=( … )` to append,
`binds=( … )` to replace, and the documented removal idiom — so a file written for the Linux
feature reads the same here.

What happens at the next boot, before any service starts: each listed directory is **seeded once**
(its current content on `C:` is copied to `Q:\bind-dirs\…`, only if no `Q:` copy exists yet), then
the `C:` path is replaced by an NTFS directory junction pointing at the `Q:` copy. Every later boot
only re-creates the junction — the copy on `Q:` is never overwritten, whatever the template now
contains. That is the Linux semantics exactly: first-use seeding from the template, then the
private copy wins.

| Linux | Windows |
|---|---|
| `/rw` (private volume) | `Q:` |
| template root, reset every boot | `C:` (an AppVM's system volume) |
| `mount --bind` | NTFS directory junction |
| `/rw/config/qubes-bind-dirs.d/NAME.conf` | `Q:\config\qubes-bind-dirs.d\NAME.conf` |
| `/rw/bind-dirs/<path>` | `Q:\bind-dirs\<path without "C:">` |
| `qubes-bind-dirs.service` (early boot) | Session Manager `BootExecute` (before any service) |

`fsutil reparsepoint query C:\ProgramData\SomeVendor\SomeApp` shows the junction; the data is
readable at both paths. With **no** config file present nothing is bound and boot is unchanged —
the binary is registered on every guest but does nothing until you ask it to.

It runs at `BootExecute` because that is the only point before services start, which is what makes
it work for directories an early service opens. The cost, the failure handling, and every place it
deliberately differs from the Linux script are in [docs/BIND-DIRS.md](docs/BIND-DIRS.md).

## Known limitations

- **qrexec runs in the interactive user session.** A logged-off guest loses clipboard and
  file-copy until someone logs in. This is how QWT is built, not something this build changed.
- **The PV console needs `-t pv`.** Since 4.3.16 we ship `xencons`, so `XENBUS\…&DEV_CONS`
  binds (`err=0`, `svc=xencons`) and the guest runs an interactive `cmd.exe` on the Xen PV
  console ring. Reach it with `qvm-console <vm>` or `sudo xl console -t pv <vm>` — a fresh
  attach is BLANK until you press Enter, because a pty has no scrollback. Plain
  `sudo xl console <vm>` can never work on any Qubes HVM: with no `<serial>` in the libvirt
  XML the stubdomain has no serial console for libxl to redirect the default to
  (qubes-issues #3039).
- **mirage-firewall as netvm hangs Windows HVM domain creation** (dom0/mirage side — the
  guest never starts). Use `core-net`, or install offline.
- **Audio is emulated, not paravirtualised.** The guest gets QEMU's Intel HD Audio device
  (`PCI\VEN_8086&DEV_2668&SUBSYS_11001AF4`, i.e. Red Hat/QEMU) driven by an inbox Windows
  driver, with Speakers and Line In endpoints present and `err=0`; Qubes routes it via the
  qube's `audiovm`. Windows Tools contains no audio component because it does not need one —
  the path is entirely QEMU-side. Nothing here changes that, and there is no PV audio driver
  in Xen's Windows family to move to.
- **An intermittent guest stall** can still happen in a qube's first minutes: QEMU in the qube's stub domain stops answering
  the guest's requests, which Windows Tools cannot fix. 4.3.34 removes the install window where the recorded install stalls
  happened (none in its acceptance), but one is on record in the first start after an install and one on a qube with no
  Windows Tools at all.
- **A template with both a .NET and a cumulative update to install asks dom0 for a restart
  twice**: the updater stages one update package per restart. Removing the second request is the
  next step.
- **On Windows 11 24H2 and later, the repaint after a keystroke is sent to dom0 a little later
  than before the event-driven capture**: measured on Windows 11 build 26300 with a pre-release
  build of the same capture, about 9 ms later at the median over all keys and about 20 ms on the
  second key of a sequence typed one per second. The cause is not established; it is tracked.

---

## Test status

A release is cut only after an acceptance gate has passed against the exact package it ships, on
Windows 10 22H2 and Windows 11 (build 26300 for 4.3.34). Four cells per platform:

- **clean install** onto a guest that never had Windows Tools (the installer's own marker must
  say it took the clean-install path);
- **same-version reinstall** over that install;
- **in-place upgrade** from the previous release;
- **template→AppVM**: the installed state restored into a template, an AppVM derived from it
  fresh, and three cold boots, each required to map windows with none fullscreen-sized.

Each install cell checks that the running agent is the release binary, restarts the guest, and
then runs the package's own health check — 25 checks, among them the agent binary hash and
process, Qubes services and their recovery settings, the IDD bound and carrying the desktop with
its modes published, a clean PnP sweep, a healthy agent log, the guest cursor hidden, user data on
the private volume, PV disk and PV console bound, updates owned by dom0, a clean boot and previous
shutdown, and a clipboard round trip — plus a visible change in dom0's pixels and window chrome
present. The gate's guests have no netvm, so its two network checks (PV NIC bound, traffic
carried) are recorded as not applicable, not as passed.

On top of the matrix: the error-notification and crop-before-map feature tests. 4.3.34 also passed
the template update test on the field reporter's environment (German Windows 11 25H2, no network,
no `user` account).
