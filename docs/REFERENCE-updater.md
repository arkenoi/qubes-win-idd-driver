# Reference - the Windows updater (Track C)

Everything `docs/ADR-updater.md` held that is not a design decision: context, reasons, costs, evidence, open
questions, measurements and history. Moved out of the ADR on 2026-11-17 on the owner's order; the section
numbers are the ADR's. Where a paragraph mixed a decision with its evidence, the paragraph is kept here whole
and its decision sentences stay in the ADR, whose wording governs. Nothing here decides anything.

## In plain English

dom0's updater does not call an agent living in the guest - it INJECTS one on every run
(`qubes-core-admin-linux`, `vmupdate/qube_connection.py`): untar a tarball into `/run/qubes-update/`, run
`/usr/bin/python3 .../entrypoint.py <flags>`, collect the log. That is why any Linux qube is updatable with
nothing preinstalled, and exactly why Windows never can be: no `python3`, no dnf/apt, no Windows branch in
`get_os_data()`. So the shim answers those command shapes and runs our updater where dom0 expects the
injected agent to run; the injected Python is accepted and discarded.

Those floats must be formatted in the INVARIANT culture. PowerShell's `-f` formats with the current one,
where `.` in a numeric format string is the decimal-separator placeholder - so on a German guest it emitted
`75,0`, `float()` raised on every progress line from the first, and each was displayed as a message instead
of moving the bar. Only formatting that crosses this protocol needs that care; log text does not.

No service definition of ours is involved. The fifteen the package ships are `qubes.ClipboardCopy`,
`ClipboardPaste`, `Filecopy`, `GetAppMenus`, `GetAppmenus`, `GetImageRGBA`, `OpenInVM`, `OpenURL`,
`SetDateTime`, `SetGuiMode`, `StartApp`, `SuspendPostAll`, `VMExec`, `VMShell` and `WaitForSession`.
`wu-update.ps1` is deployed into `qubes-rpc-services\` and reached by the shim, not by a service
definition; its own file header still calls itself an rpc handler, which is stale.

**The dom0 side applies nothing and runs nothing.** Until 2026-10-07 the dom0 RPM installed three scripts
into `%{_bindir}` and its `%post` EXECUTED two of them: one walked every qube whose `os` feature read
Windows and changed its features and prefs, one rewrote `qvm-create-windows-qube`'s files, and one was a
`qvm-windows-update` wrapper. All three are removed, along with the `%post` execution. What a Windows qube needs from dom0 is stated, not done: `qvm-features <qube>
vmexec 1` and `qvm-prefs <qube> qrexec_timeout 600`, which the `%post` message and `docs/QVM-FEATURES.md`
spell out for the admin to apply. Neither can be set from inside the guest - the Windows build of
`qubesdb-cmd` cannot write to QubesDB at all - which is why they are a prerequisite rather than part of
the install.

## The decisions in detail

Where the details live:

| record | content |
|---|---|
| `findings/updates.md` | standing facts about the update path, and retracted approaches |
| `findings/issues.md` | the open issue register (P1/P2/P3), maintained in place |
| `findings/rig.md` | rig and harness behaviour, including instrument traps |
| `findings/install.md` | getting a build onto a guest |
| `guest/qubes-windows-update.ps1`, `guest/qubes-updates-relay.cs`, `guest/wu-update.ps1`, `guest/install-updater-agent.ps1` | the components (§12.1) |
| `tools/wu-pass-judge.py`, `tools/wu-log-judge.py`, `mgmt/harness/wu-e2e.sh` | the judges and the end-to-end harness (§9) |

## 1. dom0 owns updates; the guest never installs on its own

**Why.** This is the Qubes model: the admin decides when a template changes, and a template with no netvm
cannot be left to update itself.

## 2. The invariant: dom0's reported state must be true

**Status:** ACCEPTED; amended 2026-10-07 (point 1, which had said the opposite); amended 2026-11-01 (point 5:
the ESU exception generalised to a verified no-route rule - PROPOSED to the owner, who asked for it); amended 2026-11-06
(point 5: an offer that carries no KB is verified by its exact title - owner); amended 2026-11-14 (point 6: the
owner's Defender decision of 2026-10-16, kept until now only in the register, where it was reworded and then
dropped in 4.3.40 on a misreading of point 2 - point 2 is about updates this path failed to install or cannot
install, and never covered it).

1. "Offered" and "actionable" are different numbers, and BOTH are reported. dom0 is told the OFFERED
   count - what Windows is offering - and the actionable split rides in `update-status.json` (`offered`,
   `actionable`) with a reason per item.
2. An item that cannot be installed on this path is `severity=info` with a reason, and is still COUNTED:
   what we cannot install is not the same as nothing being available, and an update we failed to install is
   never dropped from the count to hide the failure. A classification may narrow what a PASS acts on; it may
   not narrow the count because this path cannot install an applicable update. Point 5 is the one exception
   to this point, earned by measurement on every pass, never by classification. This point is about failed
   and uninstallable updates only; Defender definitions are decided by point 6.
3. An offer whose own identity a pass installed and proved installed is GONE, and does not count. That is
   not the same as point 2, and besides points 5 and 6 only this one may reduce the number: Windows re-presents satisfied
   signatures under one KB, and counting them makes dom0's marker oscillate.
4. The invariant breaks in two directions: too little (silence about a pending update) and too much (a count
   that can never clear). They are one defect class. Fixing one direction does not close the other, and the
   open direction may not be re-filed at a lower priority in order to call the work done.
5. ONE exception, and it is MEASURED, not declared: an offer this pass VERIFIED cannot be installed by any
   route this guest has is left out of the number dom0 hears, and the verification is repeated on every
   pass. Verified means all three of: the Update Catalog answered with a valid results page and resolved no
   package for this KB on this build and architecture; the offer's content is not self-contained (Windows
   Update serves it only as express or Delivery Optimization streams); and the guest has no default route
   for Windows Update's own downloader. The row says so (`severity=info`, a reason naming the three facts),
   the status carries the set (`unroutable`), and NOTHING IS REMEMBERED: a scan that would leave an offer
   out of dom0's count asks the Catalog first, in that scan. Nothing here keys on a build number, a release
   date, a content class alone, a KB list or a switch. So the day the Catalog publishes the package, the
   guest gains a route, or an entitlement makes Windows offer the real update, the next pass measures that
   and the offer counts and installs: an ESU-entitled Windows 10 guest is offered the monthly cumulative,
   the Catalog serves it, and it installs by the ordinary `.msu` route with no change on our side. An
   UNRESOLVED Catalog answer is not verification - the offer stays counted. The ESU licence state is read
   live on every pass (`esu`) and reported beside the count as information; it decides nothing.
   (Owner, 2026-11-01: the decision is "we detected that we cannot install this update now, so we
   legitimately verified the reason and skipped it", not "we blacklisted ESU by class". This replaces the
   2026-08-20 ruling that keyed on Windows 10 22H2 and the express class.)
   An offer that carries no KB is verified by its exact title, used whole and never parsed (section 6), where
   the KB would stand: the Catalog answered a valid results page for that title, every entry bearing exactly
   that title was inspected and none of their packages declares this guest's architecture; a candidate that
   could not be inspected leaves the search UNRESOLVED, and an offer with no title cannot be verified at all -
   both stay counted. The second and third facts are unchanged: the offer's content is not self-contained (no
   direct URL) and the guest has no default route for Windows Update's own downloader. The verification runs
   in the scan, like the KB case, and the row, the status set and the notice name such an offer by its title.
   (Owner, 2026-11-06: extend p5 to a no-KB offer verified by its title in the same pass.)
6. DEFENDER DEFINITION UPDATES DO NOT COUNT toward dom0's updates-available. The owner, 2026-10-16: «can we
   make a knob to exclude defender update notifications from reaching dom0? so defender will keep updating on
   schedule, just not raising this flag every few hours». Microsoft republishes them several times a day, so
   counting them raises the flag again within minutes of every pass and the flag stops meaning anything. A
   definition is an offer that carries Windows Update's own "Definition Updates" classification, and nothing
   else decides it: not a title (section 6), and not a KB number (owner, 2026-11-14: «i do not like
   classification by kb number. it may be a subject to change.»). An offer whose classification cannot be
   read counts. EVERY number dom0 is told leaves definitions out - the scan, the reboot-pending report and the
   post-install rescan - and the dom0 summary line says so. They are still offered, recorded
   (`definitions_offered`) and installed by every install pass.
   THE CLASSIFICATION IS WIDER THAN THE SIGNATURES. Windows Update files the Defender platform update
   (KB4052623) and the Windows Security platform update (KB5007651) under it too (measured over 275 captured
   scans: exactly three KBs carry it - the signatures, KB2267602, and those two). So both leave the number
   with the signatures.
   THE COST. Only dom0 starts an install pass; the scheduled pass scans and installs nothing. So on a qube
   whose own updating is off (a template, an AppVM), definitions and the two platform updates arrive with the
   next update dom0 runs for another reason, and a clear flag asks for none. Point 2 does not override this
   point.

**Why.** dom0's reported state is the product. Every other rule in this file exists to keep it true - and a
count reduced by our own inability to install something is the "too little" direction of this very
invariant, which is how a field reporter came to see "no updates available" while his own Windows Update
window listed one. On the exception: an unenrolled Windows 10 22H2 guest is offered ONLY the ESU-enrollment
out-of-band (KB5071959, measured 2026-08-20; since parked as informational, on the RETIRED/PARKED list
`tools/hooks/retired-names.txt`) - express-only and absent from the Catalog - while Windows
withholds the real cumulative from it, so that one offer can never be placed from this guest and counting it
pins dom0 at "updates available" for work no admin can do. The class test that stood in for this ("under the
notice, count self-contained offers only") was keyed on build 19045 and a hardcoded date, and the 2026-11-01
run showed why a class cannot carry the decision: the Windows 11 cumulative KB5127648 was offered as
`content_class=none` and installed from the Catalog (4553.8 MB). The route is the fact; the class is a hint.

**Mechanism for point 3, decided 2026-11-08 (Jev, three verdicts above floor).** Point 3 needs the
offer's own identity on the row that says a pass installed it. `uid`/`rev` ARE the Windows Update
API's own `Identity.UpdateID` and `Identity.RevisionNumber` (`guest/qubes-windows-update.ps1:1133`),
not a key of ours. The 17 `$script:St.result` writers split 8/8/1: eight hold the offer (`$u` in the
offer loop at `:3193`, `$e.u` inside `Install-MsuPlan`), eight hold only a KB string taken off
`$script:WuFallbackKbs` - a `[string[]]` fed `$u.kb` at `:3365` and then `Sort-Object -Unique`'d at
`:3420`/`:3443`, which collapses two distinct offers that share a KB - and one assigns the whole
list `Install-ViaWU` returns.

1. Identity is stamped INSIDE `Install-ViaWU`, which enumerates the live WU session and already
   holds each update's identity (`identity_on_the_fallback_path` = stamp_inside_install_viawu, conf
   1.00, every alternative 0.00). The queue stays a KB list and its de-duplication is untouched.
   This is SUFFICIENT, and that is measured rather than assumed: every one of those eight KB-string
   writers emits `ok=$false`, so `Test-RowInstalled` (`:531`, which requires `ok -eq $true`, rejects
   `severity=info` and requires `state` absent or `installed`) rejects all eight. The only fallback
   rows that can ever enter `satisfied` are the ones `Install-ViaWU` hands back.
2. `Install-ViaWU` takes an `-OnlyUids` selector keyed on the enumerated update's own identity,
   mirroring the existing `-OnlyUid` field comparison at `:3141` (conf 0.91). `-OnlyKbs` (`:1178`,
   selecting at `:1224`) cannot name a no-KB offer at all, which is why WU-NOKB has no routed branch
   today and why `-OnlyKbs` could not be given one.
3. Re-keying the queue's de-duplication by identity instead was scored a REAL RISK needing a named
   guard or a measurement before it lands (`dedup_semantics_change` 1.01 of 2, conf 0.91): Windows
   Update could be asked for one KB twice in a pass. That risk is the REASON point 1 leaves the
   queue alone - it is not a cost accepted alongside it.

`-OnlyUid` (`:41`) already restricts a pass by identity and is documented as the only way to name a
KB-less offer, but it narrows `$avail` at the top of the pass and never reaches `Install-ViaWU`. It
is the shape to follow here, not a case already covered.

**Landed 2026-11-08**, with the identity read put in one place (`Get-WuIdentity`) and `rev` kept an
`[int]` so a stamped result row and a scan offer carry the same JSON type. Three inline copies of
that read (`:984`, `:1030`, `:1152`) were deliberately NOT folded in: they are the same read but not
the same empty value, and both differences are load-bearing - `:1030` prints `$wrev` in the
sweep-parsed `WUSIZE uid= rev=` line, where a failed read would turn `rev=` into `rev=0`, and
`:1152` serialises `uid`/`rev` into `$script:St.available`, i.e. into JSON dom0 reads, where `''`
and `0` are not `null` and a rev of 0 could collide with a genuine revision 0. Folding them in is a
separate change owing its own measurement. Jev scored the remaining duplication
`redundant_with_hit` 0.77 at conf 0.66 - UNDER FLOOR, so no verdict, and it is recorded here rather
than resolved by deleting the helper.

## 3. Verify by effect, never by exit code

**Why.** An installer that returns 0 and changes nothing is the exact shape of a silent failure. It reaches
dom0 either as "pending forever" or as "nothing to do", and both break §2.

## 4. Sanctioned paths hard-fail; never a timeout instead of an answer

**Why.** A transient answer sends Windows Update into its "network is not connected" wait, which parks a
synchronous search until something kills the pass. A refusal is an answer; a timeout is not.

## 5. Routeless by construction

**Context.** A guest with no netvm has no default route, so Delivery Optimization and BITS cannot work. The
guest is offline by design, and that is not going to change.

**Cost.** Some offers are structurally uninstallable here and must be classified under §2.

## 6. Structured data only; no title parsing

**Why.** The catalog's response language is not deterministic: one KB comes back German, English or French,
and the reporter's environment is German. Any logic keyed on a title is a defect waiting for a locale to
expose it.

## 8. Reboots are counted: performed must equal requested

1. No speculative reboots. Every power cycle traces to a request: the guest powered itself off, or
   `update-status.json` said `reboot_needed=true`.
2. A reboot counts as PERFORMED only when the guest has gone down and come back with qrexec answering. An
   issued command is not a cycle.
3. If `reboot_needed` cannot be read it is UNKNOWN, and missing data fails. It is never read as false.
4. The harness fails the run on a mismatch in either direction: an extra cycle nobody asked for, or a
   requested cycle skipped.
5. A CUMULATIVE COSTS MORE THAN ONE CYCLE, and the extra one is CORRECT, not a defect. Where the work can
   be ordered so a single cycle serves - the cumulative installs online, before anything is pending
   (`GUARD:cumulativefirst`) - it is ordered that way. Where it cannot, Windows' own servicing completion
   takes a cycle we never issued: measured 2026-11-08 on win11de-wufix, boot at 13:55:02 and
   TrustedInstaller's 1074 at 13:56:25 - **+83 s**, reason "Betriebssystem: Aktualisierung (geplant)" -
   against our boot scan's `PT2M` trigger. That is a race we lose by 37 s and must not try to win, and no
   documented policy reaches TrustedInstaller's completion restart (`NoAutoRebootWithLoggedOnUsers` is
   inert under our `NoAutoUpdate=1`). What makes the cycle ACCOUNTED under point 1 is the STANDING
   ANNOUNCEMENT: the pass reports the count still pending - what has not applied yet -
   (`guest/qubes-windows-update.ps1:3690-3698`, whose rule is exactly "count what is not applied" and
   nothing more, Jev `count-staged` 0.97; dom0 read `1` on that run). Owner 2026-11-08: «so yes, we need
   a reboot -- we announce the count still pending (what has not applied yet)», and «we collapse reboots
   when we can, if we can not, it is the right way to do until new api would allow a guest to
   self-announce a reboot». So no new channel and no dom0 service are to be built for this; the count IS
   the channel. **NORMAL DOM0 IS NOT OUR HARNESS, and the two must never be conflated here.** Normal
   dom0 reads `updates-available` and nothing else: it never opens `update-status.json`, keeps no reboot
   ledger, and does not power-cycle a Windows guest. So in the field the standing announcement makes the
   remaining work VISIBLE - Qube Manager shows the qube as having updates - and the ADMIN acts on it. A
   qube that Windows' completion restart has halted stays Halted until the admin starts it: that is the
   user-visible cost of this decision, and it is accepted, not hidden. Only inside OUR harness does the
   announcement also account the cycle - there, a power cycle taken while `remaining > 0` traces to the
   standing announcement and satisfies point 1, and a CHANGE-NOTHING measurement must never be taken in
   that window because the guest has declared itself unfinished. Settled until an API lets a guest
   self-announce a reboot; not to be re-argued.

**Why.** Rebooting until things settle is unfalsifiable (reboot often enough and something eventually works),
and it conceals the defect that needed the extra cycle. It also stops reproducing what a user gets, because a
user reboots when Windows asks.

## 9. The test is the product

**Context.** Every wrong verdict in this track came from an instrument, not from the code under test. The
known instrument traps are recorded in `findings/rig.md` and `findings/updates.md`, and kept out of this file on
purpose: they are observations, and they change.

Why: the item this was built for - an audio-driver offer the field reporter's environment presents on every
pass - had no measured artefact, so every acceptance run ended INSTRUMENT on it. Given the Catalog measurement
by hand on 2026-11-08 the judge answered correct-exclusion 0.49, 0.57 and 0.63 and insufficient-evidence 0.51
in four calls, none above the floor; given all three measurements on 2026-11-10 it answered
insufficient-evidence 0.48 and 0.49 in two. Jev on the design itself: `verdict_source` =
code-gates-judge-supplementary at conf 0.37 (0.53 against judge-gates 0.24) - UNDER FLOOR, so the choice is
mine and not a verdict; `catalog_agreement_sufficient` noul 0.31, which is why the Catalog fact alone does not
pass an item; `missing_measurement` = self-contained-content at conf 0.85, which is the agent read.

**2026-11-12, a round whose own read cannot hold the offer.** The content read follows the restart a pass
staged (`mgmt/harness/wu-e2e.sh` takes it at the next round's start). After the restart that completed the
November cumulative the agent's offline store held no offer at all (template-update re-run, round 2: 0 offers
on 26200.9974 - why it was empty is not measured), and a read inside the guest's own 60 s restart window
returned nothing (rel-43099265433, round 2). Such a round takes the content of the identity its OWN status
lists for the title from the harness's reads in the other excluding rounds of the run - only when every such
read shows that UpdateID at the same RevisionNumber with no node that carries content. `needed` and
`downloaded` are the round's state and the bundle tree is the identity's metadata, so a bundle without content
cannot be self-contained in any download state. The evidence names the substitution. An identity with content,
at another revision, read without a revision, or read in no other round stays a gap (INSTRUMENT); a
self-contained reading in any round still contradicts. The harness read carries the RevisionNumber from this
date (`wu-evidence-facts.sh`, the last field of an `EV|offer` line). Jev: `missing_measurement` =
revision-number at 0.77 - a verdict, hence the field; `fix_path` identity-from-another-round 0.59 [0.67] and
`substitution_sound` noul 0.56 are UNDER FLOOR, so the rule is my choice and not a verdict.

Not covered, and judged as before: an unroutable offer that HAS a KB (the Windows 10 ESU case), for which no
host-side Catalog measurement by KB exists. The comparison's contradiction legs have been driven only by
fixtures derived from one real capture; no run has yet produced a real self-contained offer in the agent read.

## 10. The guest cannot restart itself; a restart is REQUESTED, never taken

**Context.** A Qubes HVM is `on_reboot=destroy` / `on_poweroff=destroy`. A guest-initiated restart leaves the
qube Halted, and only dom0 can start it again. So when the guest needs a boot, it cannot take one.

**Why.** A guest that halts itself to fix its own problem takes the machine away from the admin without being
asked, and §8's accounting cannot tell that cycle from a requested one.

## 11. A cause outside our code, with a measured remedy, is CLOSED BY DECISION

1. A decision to stop states four things: what is ESTABLISHED, what is NOT, the REMEDY that makes the residue
   tolerable, and what would REOPEN it.
2. An item parked this way does not remain in `findings/issues.md` as open work. "Still open" there reads as
   unfinished work and invites the next session to re-derive it, which this project has paid for more than
   once.
3. The remedy is in the product and FAILS LOUDLY if it stops working. A parked cause with no remedy is not
   parked, it is ignored.

### Applied: Windows Update's own proxy selection (`0x8024402C` on a routeless guest)

**Established.** On a guest whose updater was installed and which has not restarted since, Windows Update's
request omits the proxy configuration (WebIO request option 10, `ProxyConfig`), goes to an endpoint with
`Proxyendpunkt: 0x0`, resolves the hostname itself and gets `11001`, which surfaces as `0x8024402C`. Both
polarities were traced on one guest and reproduced on a second. Everything outside Windows Update is excluded
by measurement: the relay and qrexec path; .NET *and* WinHTTP through the same proxy at the same instant; the
machine WinHTTP configuration (re-applied); the service account's WinINET configuration (populated); WPAD
(off); the autoproxy inputs and the proxy arbiter's answers (identical on both sides); the update datastore
(moved aside); network adapters; servicing state; and nine services actually cycled.

**Not established.** Why Windows Update omits the proxy early and attaches it later. Jev: `wu-internal-state`
0.80, `trigger_known` 0.11. A fixed delay must NOT be claimed: the subjects only bracket a quarter of an hour
(`timer_claim` 0.25).

**Reopens if** the state survives a restart on any guest (the pass already says so, and stops asking rather
than looping); if the once-per-boot guard is seen to fire twice in the field; or if a Windows change makes the
state persist. Reporting it outside this project is the other live option, since this is Windows Update
declining a proxy the system is handing it.

**Reopened, 2026-11-14.** On the field reporter's 4.3.43 guest the state survived a full restart twice:
findings/issues.md WU8024402CSURVIVESARESTART, docs/GWECK-STATUS.md row 47.

## 12. Architecture: who does what, and who may touch which process

**Status:** ACCEPTED (owner, Jev), 2026-10-03, after the KB5007651 failure. Implemented in QWT-NG 4.3.33
(released 2026-10-03). Before it, the updater ran installer-type packages itself with `/q`, and adopted and
killed relays by name. Every fork below was put to Jev with the owner's rules as its premise; the measurements
behind it are in `findings/updates.md` and `findings/issues.md`.

### 12.2 Install routes

- **No code of ours runs a vendor installer, and no code of ours chooses an installer's switches.** No switch
  table, no per-package special case.
- **The agent's downloader is never called on this path.** It needs Delivery Optimization / BITS (§5).
- If the update is not complete in the agent's cache after `CopyToCache`, the row FAILS and names the leaves
  that are missing.
- **A vendor payload is never carved, repacked, extracted or provisioned by us.**
- **The size dom0 shows is a measured number or no number - never the offer's `MaxDownloadSize`** (added
  2026-11-01; Jev 0.99 on the decision; PROPOSED to the owner - this bullet widens an accepted section and
  says so). MEASURED on one pass (win11de-tup, 2026-11-01; the `WUSIZE` line at scan against the same pass's
  `THROUGHPUT` records): where WUA exposes content leaves, the NEEDED leaves' sizes summed were exactly the
  bytes moved (83.7, 21.7, 207.9 MB); where it exposes the offer as a single node with no `DownloadContents`
  and no `BundledUpdates` - the cumulative, .NET, a driver - its `MaxDownloadSize` was 92,637.7 MB for a
  4,553.8 MB .msu (20.3x; 92,399.7 against 4,424.5 in the 2026-09-17 capture), 184.6 for 92.3 (2.0x) and 28.6
  for 28.6 (1.0x): sometimes right, never knowable from the offer. Those offers are catalog-delivered
  (`Resolve-Catalog`), and their size is first known when the pass opens the content and reads its
  `Content-Length`. So the row carries `size_mb` = the leaf sum with `size_src=leaves`, or `size_mb=null`
  with `size_src=unresolved` until the fetch writes a MEASURED size in (`size_src=content`: the file's
  `Content-Length`, or the verified local copy's length when the server answers the resume with 416 - a cache
  hit; MEASURED 2026-11-01 round 2: KB5127648 re-offered after round 1 deferred it, 4553.8 MB on disk, row
  still unresolved until this clause); the
  offer's own number travels as `bundle_max_mb`, under its own name. The pass logs one `WUSIZE` line per offer
  at scan (UpdateID+RevisionNumber, §6) and one `WUSIZE-RESOLVED` line per fetched file, beside its
  `THROUGHPUT` record, so the claim is checked by every pass and never by a standalone probe (§12.4: the pass
  owns the only relay). The dom0 handler's own line, `downloading KB (total_mb MB)`, reads the live block's
  Content-Length and was honest already; nothing in the repo reads `size_mb` (census 2026-11-01).

**Why.** The switches are not ours to know. Where we guessed them we were wrong twice: `/q` made the Security
platform installer exit 0 and do nothing; running the Defender delta ourselves, bare and with `/q`, failed,
and we concluded it "cannot self-apply", while the agent applies it through Microsoft's installer stub
(`MpSigStub ... /program <delta> WD /q`). Where a guessed switch happened to work (MRT, the signature package),
it still was not the package's own command line: the agent runs MRT with `/Q /W`. The workaround built on the
first wrong guess, carving the app out of the Security platform installer, made the app current while the
platform stayed uninstalled, and the updater then reported the update ALREADY CURRENT (§2 broken: too little).
The update's metadata is the authoritative source, and the agent is the only component that reads it. So the
agent runs the package, and we only supply the bytes it cannot fetch for itself.

### 12.3 Verdicts

**Why.** The agent's result says the package ran to completion; the probe says the thing dom0 is told about
changed. Either alone has read as success on a failed install (§3), and the case where they disagree is exactly
the case that needs saying.

**The effect is waited for, never assumed to be there** (decided 2026-10-03). The agent's `Install()` can
return before the package's work is done: for KB5007651 it returned ResultCode 2 after 2 s, the platform read
1 s later was still the inbox one, and the platform had switched within 10 s. The rz38b validation pass
therefore failed an update that had installed.

- **Mechanism:** a registry change notification on the probe's own artefact key (`RegNotifyChangeKeyValue`, as
  the CBS settle uses), armed before every read; the artefact is re-read on every wake. Jev 0.72.
- **Scope:** only the rows the verdict would otherwise fail as a disagreement. Every other row is decided on its
  first read, and there is no per-package list. Jev 0.92.
- **Bound:** 60 s after the agent returned. Jev 0.55. Measured with the wait on a fresh clone of the German
  golden: the platform switched 2.8 s after the agent returned. Every wait logs the latency it saw.
- **The expiry passes nothing.** The read taken after the expiry decides, so "never a timeout as a fix" holds.
  Jev 0.83.
- **A wait that cannot be armed is an ERROR.** The read decides, and no poll takes its place.
- The Defender probes read the service's view (`Get-MpComputerStatus`), not the key that is watched, so their
  wake can come early. The cost is lateness up to the bound, never a wrong row (Jev 0.93).

### 12.4 Process ownership

**Context.** Measured 2026-10-03: the boot-time scan adopted a relay another process had started, and at the
end of its pass `Remove-Proxy` TerminateProcess'ed every process with that name, mid-transfer, leaving no log
line and no crash record. A process found by name is any process with that name. Killing it is a decision about
something we did not start and cannot identify, and adopting it hands our traffic to it. This hazard was listed
by the 2026-10-02 process audit and left in place, which is why it is a rule here now.

### 12.5 Network channels: what each one needs to reach the relay

**Status:** RECORD, 2026-11-17, on the owner's order. It records what the shipped code does and what was measured
on the rig. It decides nothing. Line numbers are `guest/qubes-windows-update.ps1` unless a file is named. The runs
are the row-47 rig runs of 2026-11-17 (run16-run20) and reads of `win11de26-t54` and its AppVM `win11de26-a54`.
Every cell was checked against its source by an independent read-only verifier.

Only the search (rows 1-2) needs a Windows proxy setting. Rows 4-8 name the proxy in each request. The shipped code
gives the search that setting machine-wide, at every pass (`Ensure-Proxy` `:821-856`). This is what it leaves in
the template's root, and so in every AppVM at every start:

| setting | after a clean pass | after a pass cut by a shutdown | evidence |
|---|---|---|---|
| per-machine policy `ProxySettingsPerUser=0` | stays | stays | run17c; t54 and a54 |
| machine `ProxyOverride` `<local>` | stays (code `:946-956`) | stays | a54 |
| machine `ProxyEnable` / `ProxyServer` | 0 / deleted (code) | 1 / `127.0.0.1:8082` | t54, a54 |
| WinHTTP (`netsh`) | reset (code) | `127.0.0.1:8082` | t54, a54 |
| `RootDirURL` to the local mirror | stays, by design (`:883`) | stays | code; not read on an AppVM |
| `DODownloadMode` 99 | restored (row 9 only) | left (inferred from code, `:1385`) | code `:1228-1234` |

On a54 with a network (measured once), requests that follow the system proxy failed, and the same URL fetched
directly returned 200.

**Not known:**

- row 1 with nobody signed in;
- how long a seeded SLS result lasts, and what refreshes it;
- the row 5-6 installs with no machine proxy;
- whether Defender (row 10) or anything else uses the relay during a pass today.

## 13. The installer waits for a running scan, and a refused updater deploy is never quiet

**Context.** Field report (4.3.33, a German Windows 11 25H2 template): dom0 showed no updates while Windows Update
listed one. Reproduced 2026-10-04 on the reporter's registered environment with the released 4.3.34: stage 2 of
the installer reached the updater deploy about three minutes after boot, inside the previous updater's boot scan
(`QubesWindowsUpdateScan`, boot + 2 min, limit PT20M), which held the updater mutex. The deploy refused
(`QWTUPDMUTEXHELD`); the installer recorded one WARN line and `updater_agent='error: ...'` in a RESULT that said
`ok:true`, printed INSTALL COMPLETE, and never told dom0; the guest kept its old updater. A 4.3.32 updater never
recorded its owner and 4.3.29 has no owner field, so the status record alone cannot name those holders.

**Why.** A scan is the one holder that installs nothing and ends on its own; refusing it made the ordinary sequence
(boot the template, run the installer) keep the previous updater. Jev: loud refusal + wait for a running scan over
a boot-time retry; four reviews of the diff - fixes the reporter's path 0.84, the wait is a legitimate wait on an
observed event 0.95, scan misidentification 0.19, move after the release 0.99.

**Cost.** An install that meets a running scan waits for it: measured 18 s and 28 s; the bound is the scan task's
limit (PT20M) less its run time plus PT3M, with a line every 30 s. A real scan that holds the mutex in its first
second, before its first record write, is refused (loudly) instead of waited for.

**Evidence.** Seen to fail: 4.3.34 on the reporter's environment, RESULT `ok:true` with `updater_agent=error
QWTUPDMUTEXHELD` (2026-10-04). Seen to pass (4.3.35 RC, release-package 37230058013, 2026-10-06): witness B - a fresh
clone of the 4.3.29 golden, its old Scan task Running with its own fresh record: the deploy waited 18 s, took the
mutex at the release, deployed; witness A - the upgraded 4.3.35 guest, its own scan (owner pid alive): waited 28 s,
deployed. Offline: `tools/tests/wu-deploy-loud-selftest.sh` (a real second process holding the real named mutex,
the shipped notify route, the real grader), 42 checks, 11 defect knobs each failing.

**Open.** The dom0 notification of a REFUSED deploy arriving in dom0 is not measured (no refusal occurred on the
rig); a scan reaching its limit during the wait is tested offline only.

## 14. The cumulative goes first, and Windows is asked whether it registered it

Decided 2026-10-04. Jev: picking the cumulative by DISM's identity 0.63 (Q1); a registration check is
needed 0.88 (Q3); the order rule itself unsettled at 0.49 (Q2) - which is why the check, not the rule,
carries the invariant. In `guest/qubes-windows-update.ps1` as `WU-PASS-ORDER`, `WU-INSTALL-MSUS`,
`WU-CUMULATIVE-REGISTERED` and `WU-MSU-VERDICT`; replayed offline by
`tools/tests/wu-cumulative-order-test.ps1`. (Written as 13 on its own branch; main had taken that number for the scan-wait section, so it is 14 here.)

- **Only the `.msu` route is reordered.** The offer loop still resolves and fetches every offer in offer
  order, and the Windows Update agent route (Defender, the Security platform, MSRT, no-KB offers with
  static content) and the drivers resolved from the catalog by title still install inline, where they
  always did and where 4.3.33 was measured working (Jev review 2026-10-04: moving them behind a staged
  cumulative was the biggest risk, 0.78; the narrow design 0.73). The catalog `.msu` are queued and
  installed after the loop: the cumulative first, then every other `.msu` in offer order.
- **The inline routes are not CBS packages** and are NOT EXPECTED to set CBS `RebootPending` - not
  measured. If one ever does, the gate below defers the cumulative truthfully, at the cost of one extra
  restart; nothing is concealed.
- **Which package is the cumulative is DISM's answer** - the package identity it reports for the file
  (`OnePackage` or `RollupFix`) - never the title and never the filename (§6).
- **The cumulative is installed only while nothing is pending.** CBS `RebootPending` is read at that
  moment. Set - by Windows or by an earlier pass - the cumulative is DEFERRED with exactly that reason
  and the restart is requested through `reboot_needed` (§8, §10). Unreadable, the cumulative proceeds
  and the pass says so (§10: an unmeasured guard is announced, never assumed in either direction).
- **The one-package-per-pass rule has exactly one relaxation.** A package that is not itself a
  cumulative may stage behind a cumulative that this pass staged AND Windows registered. A second
  cumulative is deferred. With no registered cumulative the rule stands as it was.
- **For the cumulative, DISM's 3010 is not the answer; the package list is.** It is read before and
  after the DISM call as structured data - `Get-WindowsPackage -Online`, the package name and the
  `PackageState` enum, never `dism /format:table`, whose state words are localized (§6). A `RollupFix`
  package must be NEWLY `InstallPending`: absent before, or not pending before. If it is not, the KB
  FAILS, and its reason says that DISM accepted the package, that Windows did not register it, that it
  is not staged, and that the pass after the requested restart retries it. An unreadable list is the
  same failure with "unknown" in place of "did not register": missing data fails, and nothing
  unverified is ever reported as staged.

**Why:** measured on the reporter's German 25H2 template with 4.3.33, four fresh clones. .NET staged
first and the cumulative second: DISM returned 3010 for both, no `RollupFix` package was ever
registered, the build did not move at the restart and the update was re-offered - so DISM's 3010 alone
would have had the updater report it staged, a §2 break in the direction that conceals. (That run lifted
the one-package rule on purpose; shipped 4.3.33 defers the cumulative behind .NET instead - its second
restart - and a cumulative it stages alone was verified to land, UBR 9457.) The same two packages
in one DISM call: the same loss. The cumulative alone: its servicing stack installed online at once and
the rollup registered `InstallPending`. The cumulative first and .NET second: both landed at one
restart. The mechanism - the cumulative's bundled servicing stack must install online, and a pending
restart blocks it - is inferred, not established, so the design does not rest on it: any miss of the
order rule ends in a truthful deferral or a failed row that requests the restart. The cost is at most
one extra restart, and dom0 is told once that work is pending and a restart is required - the owner's
rule - never that something will complete when it will not.

## 15. Outside data never becomes a command

1. **No shell, anywhere on this path.** The relay spawns with `UseShellExecute = false`
   (`guest/qubes-updates-relay.cs`, the `ProcessStartInfo` block); PowerShell calls native tools with `&` and
   an argument array (`pnputil` takes `@('/add-driver', $inf.FullName, '/install')`). Nothing on this path
   builds a string and hands it to `cmd /c`. A metacharacter in outside data therefore has nothing to mean.
2. **A requested host decides a verdict; it never reaches an argument.** The relay parses the destination out
   of `GET http://host/path` or `CONNECT host:443` only to answer the one question `Allowed(target)` asks,
   and a disallowed one gets a FINAL 403 (§4). The spawn's four fields are
   `target|qubes.UpdatesProxy|user|<self> --relay <port> <token>`: `<port>` is an int we bound, `<token>` is
   one we minted, and the pass starts the relay with `--target @default --user SYSTEM` explicitly. **The host
   the caller asked for appears in none of them** - that is the claim this section makes, and it is the one
   that matters, because the relay is the one component whose input comes from whatever on the guest can
   reach `127.0.0.1:8082`.
   Two surfaces here are OURS rather than the caller's, and are written down so they are not mistaken for
   guarantees:
   - `target` falls back to the `QUBES_UPDATES_TARGET` environment variable when `--target` is absent, so
     whoever can set this process's environment selects the qrexec target. The shipped path never relies on
     that fallback, and dom0's qrexec policy - not this code - decides whether a call to any target is
     allowed at all; that policy is the boundary, and this is a convenience inside it.
   - the fields are joined with `|` and qrexec-client-vm splits on `|` without stripping quotes, so **no
     field may contain a `|`** - including `<self>`, our own installed path. Nothing checks this today; it
     holds because the path is `C:\Program Files\Qubes Tools\bin\...`.
3. **A catalog file name is a path in our own working directory, passed as one argument.** `DISM /Online
   /Add-Package /PackagePath:"$f"` quotes it, and `$f` is a file this pass fetched into `$WorkDir` - the name
   comes from outside, the location does not.
4. **dom0's arguments narrow, they do not compose.** `-OnlyKb` / `-OnlyUid` are matched against the offers a
   pass already has; they are never interpolated into a command line, and they never narrow what dom0 is told
   (§2.2).
5. **Where a native tool's own parser forces a shape, the shape is documented at the call site AND asserted
   by a test.** Two of ours have a parser of their own and both have bitten us:
   `qrexec-client-vm.exe` splits its RAW command line on `|` and does not strip quotes, so the pipe string is
   passed UNQUOTED and no field may contain a `|`; and `sc.exe failure <svc> ... actions=` rejects an empty
   argument, which Windows PowerShell 5.1 silently produces from a bare `""`. The second one shipped three
   times because its suite stubbed `sc.exe` as a PowerShell function - which cannot reproduce native argument
   passing - and asserted the broken form as acceptable.
6. **The verdict on such a call is the effect, not the exit code** (§3). A command line that a tool rejected,
   or accepted and ignored, returns indistinguishably from one that worked; only reading back what it was
   supposed to change tells them apart.

**Why.** Our code never runs a vendor installer and never chooses its switches (§12): the vendor's own command
line comes from the update's metadata and is executed by Windows Update's own installer. That rule removes the
largest surface by construction. What remains is the handful of native tools we do call, and the rule for them
is the same one: outside data is an argument or a decision, never syntax.

## 16. The updater is graded in TWO PHASES: deterministic gates first, the dom0-driven sequence second

**Why.** `template-update-test.sh` asserted nothing about the relay — `grep -i relay` over it
returned nothing. So when `fa5b416a` (2026-10-19) turned the relay compile into a discarded
ScriptBlock, the resulting silence reached this gate as an update-OUTCOME symptom and was attributed
to four causes in turn (a squatter on 8082, a self-perpetuating `GUARD:vouchexe` refusal, a stale
staged payload, and a commit that could never have fired) before the cause was found. Each round of
that costs about an hour and locks the operator out of dom0 for the dom0-driven passes. Two minutes
of gates in front of it names the fault the first time.

**The base is GWeck's sealed German 25H2 TemplateVM** (`win11de-qwt`), and that is not
interchangeable with an English image: the proxied updater serves TemplateVMs only — a StandaloneVM
answers *"the qubes proxy updater is template-only and never runs here"* and does nothing (measured
on `win11r-relayval`, 2026-10-22) — and every gate therefore reads OUR OWN log lines or a number,
never a Windows string, because Windows speaks German there.

**Verified, not asserted.** `tools/tests/updater-component-selftest.sh` (33 assertions, offline, in
the estate) drives all seven gates against the REAL captures of 2026-10-22: the post-fix pair must
PASS, the **pre-fix pair must FAIL**, each gate must fail ALONE when only its own evidence is
removed, and missing evidence must read INSTRUMENT rather than pass.
`tools/compare-acceptance-gates.sh` extracts the functional comparison of the two gates from the
scripts themselves, so it cannot drift from them.

## 17. Windows never restarts a guest on its own; a restart waits for the user, and a policy that overrides this is detected and warned about

**Status:** ACCEPTED (owner, 2026-11-13; Jev accept 0.89); built in `guest/qubes-windows-update.ps1`. Decision
2 is measured on a guest; decision 1's measurement is still owed (Evidence).

**Context.** A StandaloneVM with direct internet updates itself. The updater removes `NoAutoUpdate` there
(`guest/qubes-windows-update.ps1:3043`), and Windows Update may then restart the guest on its own. The qube is
`on_reboot=destroy` (§10), so such a restart leaves it Halted. In seamless mode the restart is also an end
whose losses are collateral (`docs/ADR-supervision.md` item 2b). Windows documents a setting that keeps
updates on and leaves the restart to a signed-in user: `AUOptions=4` with `NoAutoRebootWithLoggedOnUsers=1`
under `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU` (learn.microsoft.com
`windows/deployment/update/waas-restart`). It holds only while a user is signed in, because Microsoft restarts a
device that has none.

1. Windows Update may stay on, but it is set never to restart the guest by itself, so a restart waits for the
   user. The gaps are under Open. The updater writes the two values where it turns updates on, before it
   removes `NoAutoUpdate`, and nowhere else (Jev 0.79, confidence 0.68, no verdict). When they cannot be
   written, `NoAutoUpdate` stays.
2. If a policy overrides them, so that an automatic restart is possible after all, the updater's pass detects
   it from what is in force, on every class and after that write, and warns loudly through the ONE reporter
   (ADR-supervision §3; Jev 0.74 for the updater's pass, confidence 0.68, no verdict). It counts a restart as
   possible where updates can install by themselves and either the two values are not both in force or a
   deadline policy is set (Jev 0.81, confidence 0.72). Each source counts on its own, so a device-management
   value counts even where Group Policy turns updates off (chosen: Jev split 0.40 against 0.41 for "the
   documented winner", no verdict):
   * Group Policy that sets `NoAutoUpdate` or `AUOptions`, where `NoAutoUpdate` is not 1 and `AUOptions` is
     neither 2 nor 3 (both only notify) nor 4 with `NoAutoRebootWithLoggedOnUsers=1`;
   * device management, where `AllowAutoUpdate` is 1 to 4;
   * a deadline, unless `NoAutoUpdate=1` or `AllowAutoUpdate=5` turns updates off;
   * neither source setting automatic updates at all, since Windows then installs and restarts by default.

   Microsoft's restart page gives the scheduled-time restart, active hours and the older restart deadline no
   effect while `NoAutoRebootWithLoggedOnUsers` is on. That setting needs option 4 of Configure Automatic
   Updates, and the deadline policies are documented to override Configure Automatic Updates.
3. Managed guests (domain or device-management policy) are future work. Until then they are detected and
   warned about, nothing more.

**Cost.** An update that needs a restart stays pending until the user restarts, however long that takes.

**Evidence.** Decision 2, measured 2026-11-13 with 4.3.43 (`8f58e403`), one cell per boot, on a clone of the
retail Win11 26H2 StandaloneVM. It was offline, so Group Policy held `NoAutoUpdate=1`. As installed, the pass
logged `WUAUTORESTART none`. With device management `AllowAutoUpdate=2` it logged `WUAUTORESTART possible:
device management AllowAutoUpdate=2` at ERROR and sent one notice, which dom0's notification server
acknowledged ("Windows may restart this qube by itself"). With the value removed it logged `none` again and sent
no notice. On the 25H2 template, both passes that ran logged `none`.

Decision 1 is owed before this ships. A StandaloneVM clone with updates on and the two values set installs a
cumulative while the autologon user is signed in; read who logs a 1074 and when, against a control without the
values. Microsoft's caveats: the policy "was never created as a CSP", "in Group
Policy this policy doesn't work exactly as per description", and a restart the user schedules from the
notification overrides it.

**Open.** TrustedInstaller's servicing-completion restart (2026-11-08, `findings/updates.md`; §8 point 5) comes
from the servicing stack, and no documented policy is known to reach it. On a self-updating StandaloneVM it
would still be an automatic restart. A guest sitting at its logon screen has no signed-in user, so the setting
does not hold there; the owner: *"we always have someone signed in"*. Where `NoAutoUpdate=1` holds (templates
and their AppVMs), nothing installs on its own, so the two values matter only where updates are on. A guest
installed with `/noupdates` has no updater, so neither the values nor the warning reach it (Jev 0.87,
confidence 0.80).
