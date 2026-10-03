# ADR — the Windows updater (Track C)

**Status: accepted.**

This file records DECISIONS: how the Windows update path is built, and how it is tested.
It is not a status report. It does not say what works today, what is broken, or what any
guest measured. Those belong in:

| record | content |
|---|---|
| `findings/updates.md` | standing facts about the update path, and retracted approaches |
| `findings/issues.md` | the open issue register (P1/P2/P3), maintained in place |
| `findings/rig.md` | rig and harness behaviour, including instrument traps |
| `findings/install.md` | getting a build onto a guest |

Rule for editing this file: add a section only when the WAY WE WORK changes. If a sentence
would go stale once a guest is fixed, it is an observation and belongs in `findings/`.

Each section states **the decision**, then **why**.

---

## 1. dom0 owns updates; the guest never installs on its own

Guest auto-update is off (`NoAutoUpdate=1`). dom0 drives every install. The guest reports
availability to dom0 over `qubes.NotifyUpdates`. A guest with no netvm reaches Windows Update
only through `qubes.UpdatesProxy`, and only while a pass is running.

**Why:** this is the Qubes model. The admin decides when a template changes, and a template with
no netvm cannot be left to update itself.

## 2. The invariant: dom0's reported state must be true

dom0 must never be told that a template is up to date when it is not, and must never be held at
"updates available" by an item this path can never install.

Rules that follow:

- "Offered" and "actionable" are different numbers. dom0 is told the actionable one.
- An item that cannot be installed on this path is reported as `severity=info` with a reason and
  left out of the count — but only when that classification is correct for that item.
- The invariant can break in two directions: too little (silence about a pending update) and too
  much (a count that can never clear). They are one defect class. Fixing one direction does not
  close the other, and the open direction may not be re-filed at a lower priority in order to call
  the work done.

**Why:** dom0's reported state is the product. Every other rule here exists to keep it true.

## 3. Verify by effect, never by exit code

- If an installer's effect can be measured, `rc=0` without that effect is not success.
- A probe that ran and measured no change is a NEGATIVE RESULT, not missing data. It means the
  install failed. It does not mean there was nothing to do.
- A probe must measure the artefact the installer actually changes, and must be proven on a
  known-good install before a negative from it is believed.
- Where no probe exists the row says `probe=none`. It never implies verification.

**Why:** an installer that returns 0 and changes nothing is the exact shape of a silent failure.
It reaches dom0 either as "pending forever" or as "nothing to do", and both break §2.

## 4. Sanctioned paths hard-fail; never a timeout instead of an answer

The relay serves a sanctioned host, or refuses with a final 403. Never a reset, a 5xx, or a hang.

**Why:** a transient answer sends Windows Update into its "network is not connected" wait, which
parks a synchronous search until something kills the pass. A refusal is an answer; a timeout is not.

## 5. Routeless by construction

A guest with no netvm has no default route, so Delivery Optimization and BITS cannot work. The
updater fetches content itself through the proxy: a catalog `.msu`, or a self-contained static URL.
A path that needs DO/BITS is classified, not retried.

**Why:** the guest is offline by design, and that is not going to change. Consequence to hold in
mind: some offers are structurally uninstallable here and must be classified under §2.

## 6. Structured data only; no title parsing

Match rows by key, KB content by filename family, and an offer by its identity
(`UpdateID` + `RevisionNumber`). Never on displayed title text.

**Why:** the catalog's response language is not deterministic — one KB comes back German, English
or French — and the reporter's environment is German. Any logic keyed on a title is a defect
waiting for a locale to expose it. A version number inside a title is an exception only because
digits are language-free.

## 7. A field report is reproduced on the reporter's measured environment

The reporter's environment is data: `mgmt/reporters/<name>.json`. `mgmt/harness/env-assert.sh`
measures a guest against it and exits non-zero on any mismatch, and on any fact it could not
measure. "Diagnostically similar" is not an environment. If the environment does not exist on the
rig, building it is the first task.

## 8. Reboots are counted: performed must equal requested

- No speculative reboots. Every power cycle must trace to a request: the guest powered itself off,
  or `update-status.json` said `reboot_needed=true`.
- A reboot counts as PERFORMED only when the guest has gone down and come back with qrexec
  answering. An issued command is not a cycle.
- If `reboot_needed` cannot be read it is UNKNOWN, and missing data fails. It is never read as
  false.
- The harness fails the run on a mismatch in either direction: an extra cycle nobody asked for, or
  a requested cycle skipped.

**Why:** rebooting until things settle is unfalsifiable — reboot often enough and something
eventually works — and it conceals the defect that needed the extra cycle. It also stops
reproducing what a user gets, because a user reboots when Windows asks.

## 9. The test is the product

- Passes are judged by code, not read by eye: `tools/wu-pass-judge.py` at workflow level (did the
  pass tell dom0 the truth) and `tools/wu-log-judge.py` at engine level (did the search enter the
  transient wait). `mgmt/harness/wu-e2e.sh` drives repeated passes through dom0's own
  `qubes-vm-update` sequence and judges every one.
- Before grading, prove the artefact under test is the one on the guest: compare the installed file
  against the package by byte count and guard markers. An installer's own success message is not
  evidence.
- A wait must key on a property that DISTINGUISHES the new artefact from the old one. A marker both
  builds carry is not a wait.
- An excluded item is an open question until it is judged individually, against evidence measured
  outside the updater. The updater's own reason string is not evidence for itself. `wu-e2e.sh`
  exit codes: **0** every round passed and every excluded item is positively judged (or nothing was
  excluded); **3** a round failed; **4** rounds passed but exclusions are unjudged. A verdict file
  must cover every excluded item; one that omits an item says nothing about that item.
- Missing data fails. A check that cannot fail is not a check: every gate here must have been seen
  to FAIL on a build with the defect put back.

**Why:** every wrong verdict in this track came from an instrument, not from the code under test.
Known instrument traps are recorded in `findings/rig.md` and `findings/updates.md`, and are kept
out of this file on purpose — they are observations, and they change.

## 10. The guest cannot restart itself; a restart is REQUESTED, never taken

A Qubes HVM is `on_reboot=destroy` / `on_poweroff=destroy`. A guest-initiated restart leaves the
qube Halted, and only dom0 can start it again. So when the guest needs a boot, it cannot take one.

- A state the guest cannot leave on its own is REPORTED as a request (`reboot_needed=true`) with a
  message naming the action, and the pass stops there. It is not worked around by powering the
  guest off, and not hidden by retrying.
- The guest powers itself off only where an admin-driven install or update pass asked for it (§8).
- A guard that cannot measure what it needs says so and lets the pass proceed. An unmeasured guard
  is announced, never assumed in either direction.

**Why:** a guest that halts itself to fix its own problem takes the machine away from the admin
without being asked, and §8's accounting cannot tell that cycle from a requested one.

## 11. A cause outside our code, with a measured remedy, is CLOSED BY DECISION - and the decision is recorded here

We chase a cause until either it is NAMED, or it is BOUNDED to a component that is not ours **and**
a remedy is measured. In the second case we stop deliberately, and the stop is recorded here rather
than left in the issue register.

- A decision to stop must state four things: what is ESTABLISHED, what is NOT, the REMEDY that makes
  the residue tolerable, and what would REOPEN it.
- An item parked this way does not remain in `findings/issues.md` as open work. "Still open" there
  reads as unfinished work and invites the next session to re-derive it, which this project has paid
  for more than once.
- The remedy must be in the product and must FAIL LOUDLY if it stops working. A parked cause with no
  remedy is not parked, it is ignored.

**Applied: Windows Update's own proxy selection (`0x8024402C` on a routeless guest).**

*Established.* On a guest whose updater was installed and which has not restarted since, Windows
Update's request omits the proxy configuration (WebIO request option 10, `ProxyConfig`), goes to an
endpoint with `Proxyendpunkt: 0x0`, resolves the hostname itself and gets `11001` - which surfaces
as `0x8024402C`. Both polarities were traced on one guest and reproduced on a second. Everything
outside Windows Update is excluded by measurement: the relay and qrexec path, .NET *and* WinHTTP
through the same proxy at the same instant, the machine WinHTTP configuration (re-applied), the
service account's WinINET configuration (populated), WPAD (off), the autoproxy inputs and the proxy
arbiter's answers (identical on both sides), the update datastore (moved aside), network adapters,
servicing state, and nine services actually cycled.

*Not established.* Why Windows Update omits it early and attaches it later. Jev:
`wu-internal-state` 0.80, `trigger_known` 0.11. A fixed delay must NOT be claimed - subjects only
bracket a quarter of an hour (`timer_claim` 0.25).

*Remedy (`GUARD:proxystateremedy`).* The pass reports the reason it MEASURED in that same pass -
WinHTTP through our proxy reaching the same endpoint, with the HTTP status carried in the message -
and requests the restart that is measured to clear the state, once per boot, through the existing
`reboot_needed` channel that section 8 counts and section 10 keeps a request. dom0 is told no
availability number either way.

*Reopens if* the state survives a restart on any guest (the pass already says so, and stops asking
rather than looping), if the once-per-boot guard is seen to fire twice in the field, or if a Windows
change makes the state persist. Reporting it outside this project is the other live option, since
this is Windows Update declining a proxy the system is handing it.

## 12. Architecture: who does what, and who may touch which process

Decided 2026-10-03 after the KB5007651 failure. Every fork below was put to Jev with the owner's rules as its premise. The
measurements behind it are in `findings/updates.md` and `findings/issues.md`, not here.

**Implemented in QWT-NG 4.3.33** (released 2026-10-03). Before it, the updater ran installer-type packages itself with `/q`, and
adopted and killed relays by name.

### 12.1 Components

| component | file | role |
|---|---|---|
| the pass | `guest/qubes-windows-update.ps1` | one scan or install pass; passes are serialized by the updater mutex (a second one refuses, `QWTUPDMUTEXHELD`) |
| the relay | `guest/qubes-updates-relay.cs` | the pass's only way out: `127.0.0.1:8082` → `qubes.UpdatesProxy`; serves sanctioned hosts, refuses others with a final 403 (§4) |
| the dom0 handler | `guest/wu-update.ps1` | dom0's `qubes-vm-update` entry point: kicks the pass's task, tails `update-status.json`, cleans up after a pass that was killed |
| the scheduled tasks | `QubesWindowsUpdateScan` / `…Run` | the boot-time and periodic scan; the install pass dom0 asks for |
| the installer | `guest/install-updater-agent.ps1` | installs or upgrades the above (compiles the relay in place) |

### 12.2 Install routes

1. **Search** is always the Windows Update agent's own online search, through the relay.
2. **What the Update Catalog serves as an `.msu`** (cumulatives and other express-content updates, which the agent could only fetch
   through Delivery Optimization) is fetched by us and installed from the `.msu`, as before.
3. **Every other offered update whose NEEDED content is static** (`download.windowsupdate.com`, not express) is installed by the
   **Windows Update agent's own installer**.
   - We walk the update's bundle tree recursively. A needed leaf has content, is not installed and is not downloaded.
   - We fetch each needed leaf's files through the relay and hand them to the agent with `IUpdate2.CopyToCache`.
   - We call `IUpdateInstaller.Install`.
   - The agent then runs each package with **the update's own command line** and interprets its exit code by the update's own
     rules.
4. **Anything else** gets a row that says why: FAILED, or informational under §2. It never gets a guess.

Rules that follow:

- **No code of ours runs a vendor installer, and no code of ours chooses an installer's switches.** No switch table, no per-package
  special case.
- **The agent's downloader is never called on this path.** It needs Delivery Optimization / BITS (§5).
- If the update is not complete in the agent's cache after `CopyToCache`, the row FAILS and names the leaves that are missing.
- **A vendor payload is never carved, repacked, extracted or provisioned by us.**

**Why:** the switches are not ours to know.
- Where we guessed them we were wrong twice:
  - `/q` made the Security platform installer exit 0 and do nothing.
  - Running the Defender delta ourselves, bare and with `/q`, failed, and we concluded it "cannot self-apply". The agent applies
    it through Microsoft's installer stub (`MpSigStub … /program <delta> WD /q`).
- Where a guessed switch happened to work (MRT, the signature package), it still was not the package's own command line. The
  agent runs MRT with `/Q /W`.
- The workaround built on the first wrong guess, carving the app out of the Security platform installer, made the app current
  while the platform stayed uninstalled. The updater then reported the update ALREADY CURRENT (§2 broken: too little).

The update's metadata is the authoritative source, and the agent is the only component that reads it. So the agent runs the
package, and we only supply the bytes it cannot fetch for itself.

### 12.3 Verdicts

A row's result is the agent's per-update result AND our effect probe where one exists (§3).
- **Agent succeeded and the artefact moved:** installed.
- **Agent failed:** FAILED, with its HRESULT.
- **Agent succeeded but the artefact stayed below the offered version:** FAILED, logged loudly as a disagreement.
- **The probe measures what the update changes.** For the Windows Security platform that is the platform's own registration
  (`Windows Security Health\Platform\CoreLocation` and `\Updates\wu`), never the Security app.
- **ALREADY CURRENT** means the measured artefact is at or above the version the offer carries. Nothing else qualifies.

**Why:** the agent's result says the package ran to completion; the probe says the thing dom0 is told about changed. Either
alone has read as success on a failed install (§3), and the case where they disagree is exactly the case that needs saying.

**The effect is waited for, never assumed to be there** (decided 2026-10-03). The agent's `Install()` can return before the
package's work is done: for KB5007651 it returned ResultCode 2 after 2 s, the platform read 1 s later was still the inbox one,
and the platform had switched within 10 s. The rz38b validation pass therefore failed an update that had installed.
- **Mechanism:** a registry change notification on the probe's own artefact key (`RegNotifyChangeKeyValue`, as the CBS settle
  uses). It is armed before every read, and the artefact is re-read on every wake. Jev 0.72.
- **Scope:** only the rows the verdict would otherwise fail as a disagreement. Every other row is decided on its first read,
  and there is no per-package list. Jev 0.92.
- **Bound:** 60 s after the agent returned. Jev 0.55. Measured with the wait on a fresh clone of the German golden: the platform
  switched 2.8 s after the agent returned. Every wait logs the latency it saw.
- **The expiry passes nothing.** The read taken after the expiry decides, so "never a timeout as a fix" holds. Jev 0.83.
- **A wait that cannot be armed is an ERROR.** The read decides, and no poll takes its place.

The Defender probes read the service's view (`Get-MpComputerStatus`), not the key that is watched, so their wake can come
early. The cost is lateness up to the bound, never a wrong row (Jev 0.93).

**A reboot left pending: at most ONCE** (the owner, 2026-10-03). The normal dom0-initiated update may leave the reboot pending.
"It is ok if we show that updates are still pending and reboot is required to dom0 once, we just want to avoid doing that more than
once." So dom0 may be told once that work is staged or deferred and a reboot is required. A second such report for the same update
cycle is a defect: a repeated reboot request, or a pending count that comes back after the reboot because the work did not land.
The test judges the count of those reports; no special machinery is built for the pending state itself.

### 12.4 Process ownership

- **A component touches only processes it started, and holds them by handle** (`Start-Process -PassThru`; identity = pid +
  start time).
- **Nothing is ever killed or adopted by process name.**
- **The pass owns exactly one relay,** the one it started, and stops exactly that one. It never uses a relay it did not start.
  If `127.0.0.1:8082` is held by any other process, the pass refuses with a named reason. Under the mutex that is an anomaly,
  not a race to win.
- **A relay lives only as long as its pass.** It is started with `--parent-pid` and its own watchdog ends it within seconds of
  the pass's process going away.
- **The handler's dead-pass cleanup kills nothing.** It waits for that watchdog (bounded, every exit reported) and reports a
  relay that outlives it as an anomaly, naming its pid and parent.
- **The installer kills nothing.** Holding the mutex, it waits for any relay to exit. If one remains, it keeps the previous relay
  exe and says why.
- A commit-time lint refuses kill-by-name and adopt-by-name in shipped guest scripts.

**Why:** measured 2026-10-03. The boot-time scan adopted a relay another process had started, and at the end of its pass
`Remove-Proxy` TerminateProcess'ed every process with that name, mid-transfer, leaving no log line and no crash record. A
process found by name is any process with that name. Killing it is a decision about something we did not start and cannot
identify, and adopting it hands our traffic to it. This hazard was listed by the 2026-10-02 process audit and left in place,
which is why it is a rule here now.
