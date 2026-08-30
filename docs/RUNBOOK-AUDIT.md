# RUNBOOK-AUDIT — logical-error audit of docs/ACCEPTANCE-PROTOCOL.md

Audited 2026-08-30 against repo HEAD `b8efe4d` (which landed §0.6b and the reprovision retraction
mid-audit; every line number below is against that revision). Ground truth for behaviour:
`mgmt/harness/matrix.sh`, `mgmt/harness/e2e-wait.sh`, `.claude/skills/win-guest-e2e/e2e-lib.sh`,
`mgmt/golden.sh`, `mgmt/reprovision-usb.sh`, `mgmt/build-answer-stick.sh`, `tools/assert-payload.sh`,
`tools/qtest`, `tools/winshot.py`, plus `packaging/setup/Install-QwtImproved.ps1` (the log format the
waits judge), `mgmt/autounattend.xml`, `dom0/04-install-screenshot-service.sh`, `losetup -l`, and the
two archived matrix runs under `~/qwt-matrix/`. Documentation-only audit: no VM was touched, no
mutating `qvm-*` command was run, ACCEPTANCE-PROTOCOL.md itself is unmodified.

Severity: **BLOCKER** = the runbook cannot be executed as written; **WRONG-RESULT** = it can produce
a false verdict; **FRICTION** = wastes time / forces improvisation but is self-correcting.

Findings are ordered worst first.

---

## RB-01 — BLOCKER — §0.2 step 2 is circular: no golden can ever verify, and every documented exit from that state is forbidden by another rule

Category: circular/unsatisfiable prerequisites (task cat. 3).

Doc side:

> "**Step 2 — golden custody.** … `mgmt/golden.sh verify win10-clean` … *On failure* (exit 2,
> `UNSEALED: ...` or `DRIFTED:` …): do NOT clone. Rebuild the golden, or re-seal deliberately with
> the change recorded." — ACCEPTANCE-PROTOCOL.md:68-77
>
> "*Standing state 2026-08-30:* `mgmt/goldens/` is EMPTY … seal each golden at its next accepted
> state (§0.4) and this step becomes the campaign gate." — ACCEPTANCE-PROTOCOL.md:78-80

Script side: `mgmt/golden.sh:90` — `[ -f "$seal" ] || { echo "UNSEALED: …"; exit 2; }`. Only
`mgmt/goldens/win10-gold0.json` exists (an ST0 park, not `win10-clean`/`win11-fresh`), so step 2
exits 2 for both named goldens.

Why it is wrong — each of the three documented ways out is barred by the document itself:

1. **Seal now:** the Win10 golden's current state is the contaminated scratch-guest state the doc
   itself records ("agent binary hot-swapped twice, xencons side-loaded by hand, `debug` toggled …
   and cells were then cloned from it" — line 759; same history at §0.4:216-217). Sealing it as-is
   launders exactly the contamination H5/P1.0 exist to catch. "Seal … at its next accepted state"
   requires an accepted state, which only a campaign can produce — and the campaign is stuck at
   step 2.
2. **Rebuild:** "rebuild the golden" is named as the failure action (lines 76, 229) but no rebuild
   procedure exists anywhere in the document. ST2G's producer is undefined; §11 D12 (line 939)
   explicitly leaves "golden refresh policy" undecided.
3. **Rebuild via R3:** §0.7:380-382 forbids it — "only on churn qubes — the sole Win10 R3 target
   is `win10-u10` (§2.2)" — while the golden roster names are `win10-clean`/`win11-fresh`.

The preamble (line 10-11: "when they disagree, stop and reconcile … do not improvise around
either") converts this into a hard stop.

Minimal correction: define the one legitimate bootstrap path in step 2 itself — e.g. "UNSEALED +
attestation matching the last recorded stage manifest (§2.4) ⇒ owner-approved initial seal with the
drift recorded in the note; UNSEALED + manifest mismatch ⇒ rebuild via <named procedure>" — and
write the golden-rebuild procedure (or resolve D12) so "rebuild the golden" refers to something.

---

## RB-02 — BLOCKER — three prescribed cell configurations have no producer: ST0T, "install into an ST0 clone", and the C10/C12 stick orchestrations

Category: unsatisfiable prerequisites / stage with no documented producer (task cat. 3), plus one
unreachable-success instance of the ST0 species (task cat. 1).

**(a) ST0T (C2's entry stage, hence TIER-A) cannot be built.**

Doc side:

> "**ST0T** | pristine + testsigning | ST0 with testsigning armed by the stick (legit field
> state)." — ACCEPTANCE-PROTOCOL.md:519
> "● **C2** | fresh-1stage (both) | E2×D0 | R3+ST0T → ST2" — line 772
> "**TIER-A** — every artifact | G0 + C2 on one OS …" — line 908

Script side: the only `bcdedit /set testsigning on` in `mgmt/build-answer-stick.sh` is inside the
`REAL_STOCK_EXE` heredoc (line 184). The RELEASE payload's generated `setup.cmd` (lines 114-121) and
the PRISTINE path arm nothing; `mgmt/autounattend.xml` contains no testsigning command (grep:
none). §0.6's variant list (doc lines 289-320) offers no testsigning knob either. Post-hoc arming
is impossible by ST0's own definition ("No qrexec — undriveable", line 518). A release-payload
stick cannot substitute: `Install-QwtImproved.ps1` itself arms testsigning as stage 1 and reboots
(lines 16-17, 808), which is the E1 path — i.e. C1, not C2. So the per-artifact TIER-A profile
names a cell whose entry stage nothing documented can produce.

Minimal correction: add a `TESTSIGNING=1` knob to the stick builder (a one-line
`bcdedit /set testsigning on` in the generated `setup.cmd` before/without payload, or a
FirstLogonCommands entry), document it as the ST0T variant in §0.6, and note in §2.1 that ST0T is
producible only at provisioning time, never from a parked ST0.

**(b) "Clone ST0 (R2) and install into the clone" has no execution channel.**

Doc side:

> "ST0 is the reusable base for every non-F cell: clone it (R2) and install into the clone." —
> ACCEPTANCE-PROTOCOL.md:518 (same claim §12 note 2, line 953)

versus, three sections earlier:

> "A pristine guest has no qrexec and takes neither [route] — it is stick-orchestrated (§0.6)." —
> ACCEPTANCE-PROTOCOL.md:239-240

Why it is wrong: stick orchestration is `FirstLogonCommands` (`mgmt/autounattend.xml:151`), which
fires once, at the park's own provisioning first logon — a clone of a parked ST0 boots straight to
the desktop with that trigger already consumed, no qrexec, no gui-agent, and both §0.5 delivery
routes closed. There is no documented way to get an installer to *execute* inside an ST0 clone.
The owner's build-once/clone-many instruction and the "undriveable" property are both real; the
missing piece — a boot-time payload scanner baked into the ST0 image before parking, or an explicit
"ST0 clones are only consumable by re-running Setup-style orchestration" caveat — is stated
nowhere.

Minimal correction: either (i) bake a benign boot task into ST0 before parking ("if a volume with
`install.cmd`+`MANIFEST.json` is present, run it and log") and record it as part of the ST0
definition/proof, or (ii) delete "install into the clone" from the ST0 row and state that
fresh-install cells remain stick-orchestrated R3s, with the parked ST0 usable only for cells that
need a pristine *observed* guest (NET-6-style), not an installed-into one.

**(c) C10 and C12 prescribe stick behaviour the builder cannot emit.**

Doc side:

> "C10 | noidd-carry | … R3+ST0 (stick-orchestrated: stage1 `/noidd` no `/auto`, manual reboot,
> stage2 bare)" — line 780
> "C12 | stage1-idempotent | E1 re-entry | inside C1's R3 run (stick runs installer twice
> pre-reboot)" — line 782

Script side: `mgmt/build-answer-stick.sh:119` generates exactly one invocation with `/auto`
hardcoded — `call "%~dp0release\install.cmd" /auto ${INSTALL_FLAGS-/idd}`. `INSTALL_FLAGS` can add
`/noidd`, but "no `/auto`" is impossible and no variant runs the installer twice.

Minimal correction: either extend the builder (an `INVOKE_TWICE=1` / `SETUP_CMD_OVERRIDE=` hook)
or rewrite C10/C12 to what the stick can do (C12's double-run could equally be driven over qrexec
after stage 1 *if* the guest is reachable then — decide and say which).

---

## RB-03 — WRONG-RESULT — `w_install`'s success exit is unreachable: the `^2026` filter drops the untimestamped `=== RESULT ===` line, so every completed in-place install is graded STALLED/FAIL

Category: unreachable success criterion (task cat. 1 — the exact ST0 species, inside the wait
primitive the whole of step 6 rests on).

Doc side:

> "`w_install <vm> …` | log line COUNT past the marker, fresh read per poll | **0 RESULT
> present**; 1 recovery; 2 deadline; 3 guest halted; 4 STALLED" — ACCEPTANCE-PROTOCOL.md:199

Script side, the three links of the chain:

- `packaging/setup/Install-QwtImproved.ps1:158` — every normal line is timestamped
  (`'{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') …`), **but** the trailer is written
  bare: `Add-Content … -Value "=== RESULT === $json"` (lines 168 and 953) — no timestamp prefix.
- `mgmt/harness/e2e-wait.sh:135` — the cumulative cell log is built from tail reads filtered by
  `grep -a '^2026'`, which **discards** the RESULT line.
- `mgmt/harness/e2e-wait.sh:142` — the success test is
  `grep -qa '=== RESULT ===' "$dir/$lbl-install.log"` — on the filtered file, so it can never match.

Consequence: on every install that completes in place (the normal case — matrix.sh:214-218 quotes
the installer's own "no final reboot" contract), the line count changes once more when RESULT is
appended, then freezes; after `STALL_SECS` (300 s) `w_install` exits 4 and `run_install` logs
`FAIL  …: install STALLED (no progress for 300s)` (matrix.sh:203). Every green cell therefore
carries one manufactured FAIL plus a 5-minute dead wait, and the step-6 footer
(`=== MATRIX: N passed, M failed ===`) can never read clean on a fully good release — the mirror
image of a manufactured PASS, and just as corrosive: it trains the operator to discount FAIL lines.
Neither archived matrix run reached this point (both were interrupted earlier), so the defect has
never been seen to fire — which is precisely why it survived. Bonus defect in the same line: the
literal `^2026` stops matching **any** log line on 2027-01-01.

Minimal correction: keep the RESULT line in the capture — either widen the filter
(`grep -aE '^20[0-9]{2}|^=== (RESULT|PRECONDITION) ==='`) or, better, timestamp the RESULT line at
the source via `Write-Log` so one format rule covers everything; and replace the year literal with
`^20[0-9]{2}`.

---

## RB-04 — WRONG-RESULT — §0.7 still teaches the PRISTINE completion criterion that §0.6b and HEAD's script retract; its Expect line and exit code no longer exist

Category: contradiction between sections and doc-vs-script (task cat. 2), stale reference (cat. 7).

Doc side, §0.7 (unchanged by `b8efe4d`):

> "With `PRISTINE=1` the criterion is instead a **settled desktop on screen** (two
> `VERDICT=DESKTOP` classifications 30 s apart …)" — ACCEPTANCE-PROTOCOL.md:399-401
> "*Expect (`PRISTINE=1`):* the same up to the reboot cycles, then `pristine desktop reached after
> <N>s (no qrexec expected - ST0)`, exit 0." — lines 407-408

Doc side, §0.6b (added by the same commit that rewrote the script):

> "Consequently `PRISTINE=1` **does not declare success**. It waits for a candidate screen, saves
> the capture, and exits **3 = NEEDS-VISUAL-CONFIRMATION**" — lines 371-373
> §0.8: "Gate anything on `VERDICT=DESKTOP` | The classifier called a … Setup dialog DESKTOP,
> twice." — line 439

Script side: `mgmt/reprovision-usb.sh:112-117` — the only non-FAIL pristine exit is
`exit 3` after `"NEEDS VISUAL CONFIRMATION - READ $SHOTDIR/latest.png …"`; the string
`pristine desktop reached` no longer exists in the script; the pristine FAIL line changed to
`FAIL: no candidate desktop within ${BUDGET}s (last capture in $SHOTDIR)` (line 127), which §0.7's
failure branch also does not mention.

Why it is wrong: an operator executing §0.7 verbatim will (i) treat exit 3 as a failure — §0.7
documents only exit 0 and a FAIL string — and discard a good ST0 build, or (ii) obey §0.7's ¶3 and
re-apply the retracted two-DESKTOP criterion by hand, reproducing the measured false pass
("pristine desktop reached after 137s" on a Setup error dialog, line 366). The same document
simultaneously mandates and prohibits the same gate; the preamble's stop-and-reconcile rule
(line 10) makes §0.7 unexecutable until fixed.

Minimal correction: rewrite §0.7's PRISTINE paragraphs to match HEAD — criterion "candidate
DESKTOP after ≥900 s", success = exit 3 + a human/agent reading `latest.png` before sealing, FAIL
string as in the script — and point at §0.6b instead of restating the retracted rule.

---

## RB-05 — WRONG-RESULT — the prescribed CELLS sequence violates H3.6: matrix.sh has no per-cell teardown, so every OS switch runs two Windows guests concurrently

Category: ordering hazard / resource rule violated by the prescribed sequence (task cat. 6).

Doc side:

> "**Step 4 — halt every Windows guest.** *(H3.6: one Windows guest at a time, and a campaign
> starts with zero)*" — ACCEPTANCE-PROTOCOL.md:96-97
> `CELLS="win10-1stage win10-2stage win10-stock win11-1stage win10-appvm win11-appvm"` — line 128
> "H3.6 Serial, one Windows guest up — concurrent runs have destroyed each other; three 8 GB
> guests starved qubesd." — line 677; same rule §0.8:433.

Script side: no cell function shuts its target down when the cell ends — `verify_installed`
(matrix.sh:208-278) finishes with the guest running; `reclone` (matrix.sh:58-74) halts only **its
own** target `$t`; `cell_appvm` (matrix.sh:431-482) halts its template and its AppVM but nothing
else, and leaves the AppVM running after boot 3.

Consequence with the doc's own example list: `win10-stock` ends with `win10-tpl` running;
`win11-1stage` then boots `win11-tpl` → **two guests** for the entire cell (~40 min);
`win10-appvm` halts `win10-tpl` but `win11-tpl` is still up while `win10-app` boots → two guests;
`win11-appvm` halts `win11-tpl` but `win10-app` is still up while `win11-app` boots → two guests.
Three of six prescribed cells run in the configuration H3.6 calls result-destroying, under a step-6
banner that says "nothing else touches any Windows guest". H3.6's "orchestrator refuses to start
over a live prior part" is likewise not implemented anywhere in matrix.sh.

Minimal correction: one line at the top of each cell (or in `reclone`/`cell_appvm`): halt every
other running `win1*` guest before `start_vm` — i.e. move step 4's sweep inside the harness where
it can hold for the whole campaign; at minimum, order the CELLS example so all cells of one OS,
including its appvm cell, complete before the other OS begins (`win10-* win10-appvm win11-*
win11-appvm`), which shrinks the violation to nothing.

---

## RB-06 — WRONG-RESULT — step 6's "FAIL state is preserved per H3.5" is unsatisfiable: the next cell reclones over the evidence, and the appvm cell grades whichever install happened to run last

Category: contradiction doc-vs-script (task cat. 2) + ambiguous qube targeting (cat. 5).

Doc side:

> "*On a FAIL cell:* the guest's state is evidence — preserved per H3.5; the campaign continues on
> other cells (H4.5)." — ACCEPTANCE-PROTOCOL.md:153-154
> "H3.5 … **preserve the guest** (its state is the only evidence). Quarantined name: no reclone
> over it; later parts targeting it record `SKIPPED-QUARANTINE`." — line 676

Script side: matrix.sh implements no quarantine of any kind — every install selector for one OS
uses the same target (`win10-tpl`, dispatch lines 509-518), and `reclone` unconditionally shuts
down and overwrites it (lines 58-127; it even kills and volume-reverts to *force* the overwrite
through). With the doc's example list, a `win10-1stage` FAIL is destroyed minutes later by
`win10-2stage`'s reclone. The two doc statements ("preserved" and "continues on other cells") are
jointly impossible on a shared target.

Same shared-target ambiguity, other direction: `cell_appvm` derives `win10-app` from `win10-tpl`
**as left by whichever install cell ran last** (the example order makes that `win10-stock`, the
upgrade-over-stock exit — not the fresh exit). If that last cell FAILed, the appvm cell cold-boots
an AppVM off a half-installed template and grades the product on it — a subject-identity error the
doc's step 6 never mentions.

Minimal correction: in matrix.sh, skip any selector whose target carries a FAIL from this run
(a per-target flag set by `no()` is enough) and record `SKIPPED-QUARANTINE`; in the doc, state that
the appvm cell's subject is "the template as left by the immediately preceding install cell of that
OS, which must have PASSed" and make that a checked precondition of `cell_appvm`.

---

## RB-07 — WRONG-RESULT — §0.6's stick examples re-manufacture the ST0 archetype: the pristine recipe overwrites the release stick in place, and the Win11 example builds a payload-free stick while calling itself the Win11 stick

Category: contradiction between sections (task cat. 2), ordering hazard (cat. 6), stale
inventory (cat. 7); the consequence is the archetype unreachable-criterion failure (cat. 1).

Doc side — the three colliding statements:

> Release stick: "`LOCALE=en-GB RELEASE_SETUP=… OUT=$HOME/win-iso/answer-usb.img
> mgmt/build-answer-stick.sh "Windows 10 Pro"`" — ACCEPTANCE-PROTOCOL.md:291-292
> Pristine stick: "`LOCALE=en-GB OUT=$HOME/win-iso/answer-usb.img mgmt/build-answer-stick.sh
> "Windows 10 Pro"`" — line 301 (the **same** OUT)
> "loop9 | `answer-usb.img` | release stick (our package, `/idd`)" — line 627
> "the image is rewritten in place, inode preserved, so already-attached loops keep serving
> current content" — lines 322-324

Why it is wrong: building the pristine stick per line 301 silently converts loop9's served content
into a QWT-free stick (the in-place rewrite guarantees it — the doc's own corollary). The next
`mgmt/reprovision-usb.sh win10-u10 loop0 loop9` (line 385, default mode) then provisions pristine
Windows and waits on the **qrexec** criterion, which that image cannot reach by construction —
`FAIL: never reached qrexec within 5400s` for a healthy install: the exact ST0-species failure this
audit was commissioned to find more of, manufactured this time by an OUT collision instead of a
missing mode. Reality already routes around it — `losetup -l` shows dedicated
`answer-pristine-win10.img` (loop15) and `answer-pristine-win11.img` (loop16), and §0.6b's new
Win11 example correctly uses `answer-pristine-win11.img` — but §0.6's Win10 pristine example, the
§2.7 inventory (which lists neither pristine loop), and §0.7's dangling `<pristine-stick-loop>`
placeholder (line 392) were never updated.

Second instance in the same block: the Win11 example (lines 304-305) sets no `RELEASE_SETUP`, so by
the builder's own semantics — and the doc's own trap two bullets down ("**`RELEASE_SETUP` unset
produces a QWT-free stick** … forgetting it silently provisions pristine Windows with no payload",
line 318) — it builds a pristine stick; yet §2.7:628 labels that image "Win11 stick" and §10:909
counts a "Win11 fresh chain" R3 that needs a payload stick. The example is the foot-gun its own
caption warns about.

Minimal correction: give the pristine example its real OUT (`answer-usb-pristine.img` /
`answer-pristine-win10.img`); add `RELEASE_SETUP` (and `UNATTEND=…win11.xml`, per §0.6b) to the
Win11 payload example or relabel it "Win11 PRISTINE stick"; add loop15/loop16 rows to §2.7 and
replace §0.7's `<pristine-stick-loop>` with the named loop.

---

## RB-08 — WRONG-RESULT — NET-2 cannot be entered from the roster as documented: the standing AppVM already has fw-net, so §1's worked example produces the vacuous grade its own ledger bans

Category: unreachable precondition given the prescribed configuration (task cat. 1/5).

Doc side — the three pieces that cannot all be true:

> NET-2: "Boot ST3A `netvm=''` → baseline … → **arm watcher BEFORE the vif exists** →
> `qvm-prefs <app> netvm fw-net`, no reboot" — ACCEPTANCE-PROTOCOL.md:802
> Roster: "`win10-app` | AppVM | **fw-net** | ST3A.10 / ST4.10 network vehicle" — line 539 (and
> §2.5:591 re-applies `netvm fw-net` to AppVMs after every restore)
> Worked example: "So: `qvm-start win10-app` (via `start_vm`), wait session, run NET-1
> attestation, then NET-2." — line 506 (referenced again at §0.3:208)

Why it is wrong: with the standing `netvm=fw-net`, `qvm-start win10-app` creates the vif **at
boot** — the watcher is armed after the vif exists and "PV NIC bound ≤120 s after attach" has no
attach to measure. The doc's own vacuity ledger names this exact shape a false-verdict producer:
"'no dialog' with watcher armed after attach" (line 810). The step that would make NET-2 real —
`qvm-prefs win10-app netvm ''` while Halted, *then* boot — appears nowhere: not in NET-2's row, not
in ST3A's definition (line 526, which says nothing about netvm), not in the worked example.
Followed verbatim, the runbook's one fully-worked network part yields `INVALID-VACUOUS`.

Minimal correction: add the detach-before-boot step to NET-2's row and to §1's example ("halt →
`qvm-prefs <app> netvm ''` → boot → … → attach"), define ST3A-for-NET-2 as "booted with
`netvm=''`", and note the restore obligation (re-attach fw-net per §2.5) at part end.

---

## RB-09 — WRONG-RESULT — §0.7's post-R3 aftercare destroys NET-6's only documented subject

Category: ordering hazard — a step mutates state a later step depends on (task cat. 6).

Doc side:

> §0.7 aftercare, to run "after success": "`qvm-prefs win10-u10 netvm fw-net # Standalones/AppVMs
> only; NEVER templates`" — ACCEPTANCE-PROTOCOL.md:418 (mirrored as a standing rule at §2.5:591)
> NET-6: "Subject: **persistent-root guest that has NEVER had a vif** — i.e. the churn qube
> straight off the C1 chain, **kept `netvm=''` since install** … an AppVM cannot be the subject,
> nor any recycled guest." — line 806

Why it is wrong: the C1 chain *is* an R3 on the churn qube (`win10-u10`). Executing §0.7's
aftercare block right after that provision — which is what "After success — the reset trap …
Re-apply the standing values" instructs — attaches fw-net, so the guest's next boot creates a vif
before any watcher can be armed, and NET-6's eligibility probe ("XENVIF enum empty incl. ghosts")
fails forever on that image. The only documented never-vif producer is consumed by the aftercare of
the very step that produced it; NET-6 then has no subject short of an extra reprovision, which
requirement 7 / §10 forbids ("no cell may substitute an R3 where a cheaper restore reaches its
entry stage" — and none does).

Minimal correction: mark the `netvm` line in §0.7's aftercare conditional — "NOT until NET-6 has
consumed this guest's first-vif state, when the campaign includes NET-6" — and add the same
sequencing note to NET-6's prereq column (currently "C1, fw-net for vif plumbing", which is
consistent only if fw-net is attached *by NET-6 itself*, a fact worth stating).

---

## RB-10 — WRONG-RESULT — golden verification cannot fail for two tamper classes the doc claims it covers: a boot ended by a kill, and a golden that is running right now

Category: a check that cannot fail (task cat. 4).

Doc side:

> "One careless boot contaminates every later clone silently" / "The tamper signal is the
> root-volume revision list — Qubes cuts a revision on every **clean shutdown**, so a booted
> golden gains one its seal never recorded" — ACCEPTANCE-PROTOCOL.md:214, 229-231
> Step 2: "both stay Halted — **verify never boots anything**." — lines 68-69

Script side: `mgmt/golden.sh` —
- `verify` never checks the qube's power state (only `seal` does, line 68-71): a golden that is
  **currently running** — mid-contamination — verifies `VERIFIED … matches its seal`, because its
  sealed revision list is still intact while it runs.
- drift comparison (lines 96-103) covers volume `size` + `revisions` + clone-relevant props only;
  `usage` is collected but deliberately excluded. Combined with the revision mechanism the script
  itself documents (revision on *clean* shutdown, line 18-19), a boot that ends in `qvm-kill`
  cuts no revision, changes no size and no prop — and verifies clean. The 2026-08-29/30
  contamination the tool was built in response to explicitly included "repeated hard restarts"
  (doc line 216), i.e. exactly the class the check cannot see.

Why it is wrong: step 2 treats `VERIFIED` as the campaign gate ("this step becomes the campaign
gate", line 80). A gate that passes a currently-booted golden and a boot-plus-kill golden satisfies
the letter of "verify never boots anything" while missing the substance of "a golden that has been
booted is not a golden any more". Under the doc's own instrument rule (H2: "a wait that cannot
fail is worthless"; H5's fail-proof requirement) this check's PASS is at best `PASS-UNPROVEN` for
those classes.

Minimal correction: in `verify`, (i) fail on a non-Halted target (one `qvm-ls` line, mirroring
`seal`), and (ii) compare `usage` for the root volume too, or record+compare a cheap content
fingerprint if usage proves too noisy; in the doc, state the residual blind spot explicitly if any
remains.

---

## RB-11 — WRONG-RESULT — the run-identity properties H1 promises are absent on the very path the runbook mandates: matrix.sh never verifies its log clear, and §0.3 describes `w_install` as marker-scoped when it has no marker

Category: doc-vs-script contradiction (task cat. 2) enabling a stale-data grade (cat. 4).

Doc side:

> H1: "Guest-side: `startrun` deletes `C:\qwt-improved-install.log`, **verifies the delete**
> (failed delete = instrument failure, refuses the run), writes `E2ERUN-<UTC>-<pid>`; all
> guest-log judgment via `_logtail` past the marker." — ACCEPTANCE-PROTOCOL.md:660
> §0.3 wait table: "`w_install …` | log line COUNT **past the marker**" — line 199

Script side: those properties belong to `e2e-lib.sh` (`startrun`, lines 90-102; `wait_install`
refuses to run without the marker, line 161-163) — but step 6's mandated path never calls them.
`matrix.sh:152` clears the guest log with
`qrun "cmd /c del /f /q $GLOG 2>nul & … & echo CLEARED" >/dev/null 2>&1` — result discarded,
delete unverified — and `w_install` (e2e-wait.sh:81-160) has no marker parameter at all: it counts
**all** lines of the guest log from line one.

Why it is wrong: if the delete fails (locked file, dead session at that instant — the class
`startrun` was hardened against after "a previous run's FATAL reported as this run's failure"),
`w_install` starts against a stale log whose old `=== RESULT ===`/content is judged as this cell's,
and `verify_installed`'s final grep (matrix.sh:249, `tail -1` of all RESULT lines) reads the stale
trailer; on a same-release rerun the agent-hash check then matches and the cell can PASS on data
from a run that never happened. §0.3's "past the marker" wording actively misleads the operator
into believing the protection exists on this path.

Minimal correction: make matrix.sh's clear verified (reuse `startrun`'s GONE check — three lines),
and fix §0.3's `w_install` row to say "log line COUNT, from line 1 — no marker; the cell relies on
the verified pre-install delete".

---

## RB-12 — FRICTION — the R3-scoping rules are mutually inconsistent: churn-only vs the win10-gold0 example vs the ST0 row's ONLY-clause vs the three-R3 cap vs TIER-C

Category: contradictions between sections (task cat. 2), ambiguous targeting (cat. 5).

The four statements, which cannot all hold:

> "only on churn qubes — the sole Win10 R3 target is `win10-u10` (§2.2)" — §0.7:380-382
> "`PRISTINE=1 mgmt/reprovision-usb.sh win10-gold0 loop0 <pristine-stick-loop>`" — §0.7:392
> (`win10-gold0`: not a churn qube, absent from §2.2's roster entirely — and since `b8efe4d` it is
> a *sealed golden*, `mgmt/goldens/win10-gold0.json`)
> "A full reprovision (R3) is warranted **ONLY** for the cell that actually tests
> Windows-install-plus-QWT-at-first-logon … nothing else may reinstall. Park one ST0.10 and one
> ST0.11" — §2.1:518 (but building those parks *is* an R3 that is not that cell — the ONLY-clause
> has no carve-out for the park build the same sentence mandates)
> "at most **three** R3 runs (Win10 fresh, Win10 stock, Win11 fresh)" — §10:913 (no allowance for
> the ST0/ST1 park builds, nor for TIER-C's C10, whose entry is its own R3 — line 780)

Minimal correction: restate the R3 rule once, with its real scope: "R3 is allowed for (a) the
first-logon install cells (one per chain: Win10 fresh, Win10 stock, Win11 fresh), (b) the one-time
ST0/ST1 park builds on `win*-gold*` names, (c) C10's noidd chain at TIER-C — everything else
restores"; add `win10-gold0`/`win11-gold0` rows (class, role: parked ST0 golden, never started
after seal) to §2.2.

---

## RB-13 — FRICTION — §0.9 items 3 and 4 (and their echoes in §0.2 and §0.8) describe pre-fix matrix.sh as current, under a "verified against source" banner

Category: stale references (task cat. 7).

Doc side:

> "an unset `CELLS` defaults to the string `seeded` … the run prints a header, does nothing, and
> ends `0 passed, 0 failed`" — §0.2:157-159, §0.9.4:460-461, §0.8:441 ("Trust a `0 passed, 0
> failed` matrix summary")
> "A missing `…gui-agent.exe` does not stop matrix.sh: `ASHA` ends up empty and the … check
> becomes vacuously green. §0.2 step 5's `ls` is the guard." — §0.9.3:457-459; step 5: "matrix.sh
> hard-fails only on a missing tarball" — line 118

Script side (both fixed, commit `2ce15c3`): `matrix.sh:491-494` — missing `gui-agent.exe` is now
`FATAL … exit 1`; `matrix.sh:502-505` — unset `CELLS` is now `FATAL: CELLS is unset … exit 1`.

Why it matters beyond tidiness: §0.9's header says "verified against source 2026-08-30", and the
preamble's stop-and-reconcile rule turns every false divergence claim into a mandatory halt for a
compliant operator. Also step 5's "the `ls` is load-bearing, not ceremony" is now half-ceremony
(the ASHA guard is in-script; the `ls` still usefully fails *earlier*).

Minimal correction: rewrite §0.9.3/§0.9.4 as "RESOLVED (2ce15c3) — kept for history", soften §0.8's
row to "a `0 passed, N failed` run whose only FAILs are `unknown cell` selector typos still prints
a normal footer" (that path still exists: dispatch line 523 counts a FAIL but does not exit), and
update step 5/step 6's wording.

---

## RB-14 — FRICTION — H0 and P0-PRE.1 still demand the e2e-wait promotion that has already happened; Part I and Part II disagree about it

Category: stale reference (task cat. 7), internal contradiction (cat. 2).

> H0: "wait primitives `mgmt/harness/e2e-wait.sh` (**must be promoted first — P0-PRE**; today
> `matrix.sh` sources it from a garbage-collectable session tmp path)" — ACCEPTANCE-PROTOCOL.md:656
> P0-PRE.1: "Promote `e2e-wait.sh` → `mgmt/harness/e2e-wait.sh`, re-point `matrix.sh`, commit" —
> line 712

Script side: done — the file lives at `mgmt/harness/e2e-wait.sh` and `matrix.sh:33` sources
`"$(dirname "${BASH_SOURCE[0]}")/e2e-wait.sh"` (with a comment saying exactly that); §0.1's own
table (line 39) already lists the repo path. Part II contradicts Part I and the source; P0-PRE's
completion state is misstated, which matters because P0-CORE (every campaign) lists P0-PRE as its
prerequisite. Note the *same defect class* genuinely persists in P0-PRE.8 — `cell_fresh`/
`cell_upgrade_stock` still pushrun `/home/user/.claude/jobs/c2a0f57b/tmp/guest/{uninstall-qwt,count-qwt}.ps1 [FIXED 2026-08-31]`
(matrix.sh:368, 383, 404 — verified present today, still GC-able) — so the fix is to mark item 1
done, not to delete the section.

Minimal correction: mark P0-PRE.1 done with the commit hash; rewrite H0's parenthetical to past
tense; leave P0-PRE.8 as the live item.

---

## RB-15 — FRICTION — "mgmt/goldens/ is EMPTY" is no longer true, and ST0T's "Never parked (same reason)" points at a retracted reason

Category: stale references (task cat. 7).

> "*Standing state 2026-08-30:* `mgmt/goldens/` is EMPTY — nothing has ever been sealed" —
> ACCEPTANCE-PROTOCOL.md:78 (repeated at 234, and §0.9.6:463)

Ground truth: `mgmt/goldens/win10-gold0.json` exists (committed in `b8efe4d`, the same commit that
touched this document elsewhere). Step 2 still fails closed for `win10-clean`/`win11-fresh`, so the
substance survives, but three "verified" standing-state statements are now false.

Also: ST0's standing column was corrected to "PARKED AND CLONED" (line 518), but ST0T's column
still reads "Never parked **(same reason)**" (line 519) — the referent of "same reason" is the
retracted never-parked rationale, so the note now points at an argument the document disavows
(ST0T not being parked is still right, but for the RB-02(a) reason: it has no producer at all yet).

Minimal correction: update the three standing-state lines to name `win10-gold0` as sealed; replace
"(same reason)" with the actual reason.

---

## RB-16 — FRICTION — with `mgmt/harness/instrument-proofs.md` nonexistent, H5 makes plain PASS impossible for every check, and the runbook never tells the operator to downgrade the harness's PASS lines

Category: vacuous/unsatisfiable gate applied to itself (task cat. 4), circular prerequisite
(cat. 3).

> "a check absent from the registry can never emit plain `PASS`" — ACCEPTANCE-PROTOCOL.md:697
> "**Registry:** `mgmt/harness/instrument-proofs.md` (checked in) …" — line 702
> P0-PRE.7: "Create/refresh `mgmt/harness/instrument-proofs.md` …" — line 718

Ground truth: the file does not exist (checked). Two consequences the doc does not draw:
(i) matrix.sh emits plain `PASS  …` lines (ok(), line 47) and step 6/7 instruct the operator to
read and transcribe them (lines 147-149, 175) with no mention that, per H5, every one of them must
land in `verdicts.tsv` as `PASS-UNPROVEN` until the registry exists; (ii) P0-CORE lists P0-PRE as
its prerequisite (line 726), and P0-PRE is incomplete (items 3, 7, 8 at least — `snap-regress.sh`
still in `scratchpad/`, registry absent, helpers in session tmp), so by the letter of §4 no
campaign can start at all — a statement the runbook part of the doc never surfaces.

Minimal correction: create the (even initially thin) registry file, and add one sentence to step 7:
"until `instrument-proofs.md` carries a fail-proof for a check, transcribe its harness `PASS` as
`PASS-UNPROVEN`"; state in §0.2 which P0-PRE items are hard gates versus advisories.

---

## RB-17 — FRICTION — the binding fullshot restriction is violated by the harness's own wait loop, and RND-0's blindness table contradicts the mechanism §0.6b now relies on

Category: contradiction doc-vs-script and doc-vs-doc (task cat. 2).

> H2: "`qtest fullshot` is restricted to override-redirect windows and dom0-compositing checks —
> never an escalation from an empty per-window tar." — ACCEPTANCE-PROTOCOL.md:666
> RND-0: "Whole-desktop (`fullshot` …) only for (a) o-r surfaces and (b) suspected dom0
> compositing defects; processed locally, cropped immediately, **never committed**" — line 842

Script side: `w_screen` (e2e-wait.sh:27-33) takes a **fullshot** on every call, and `w_session`
calls it every minute of every boot wait (line 46) — the standard harness path of step 6, storing
whole-desktop tars durably under `$MATRIX_OUT` (cropped PNG is produced, tar is not deleted). The
restriction and the harness cannot both stand; the harness has a real reason (an agentless/broken
guest is invisible to per-window capture), which the rule does not carve out. D10's privacy ruling
(line 937) applies to exactly these captures and is still pending.

Related doc-internal contradiction: RND-0's blindness table says `qtest shot` is "blind to …
agent-less guests" (line 840), yet §0.6b/PRISTINE grades a **never-agented ST0 guest** through
`qtest shot` (reprovision-usb.sh:98) — and measurably captured one (the Win11 Setup dialog,
doc line 366). Both statements cannot be true as written; the real distinction (a *never-agented*
HVM is served through the emulated/stubdom GUI path and IS capturable; a QWT-installed guest whose
agent is dead is NOT) is stated nowhere.

Minimal correction: add carve-out (c) to the capture-class rule — "harness boot-phase
classification of guests with no live gui-agent session (`w_screen`), tar processed locally and
deleted after the crop" — and fix the blindness table to distinguish never-agented from
agent-dead guests.

---

## RB-18 — FRICTION — NET-8's supersession was not propagated: §11 still lists the local endpoint as an owner dependency and §10 still schedules NET-8 into the owner-attended session

Category: stale references (task cat. 7).

> "~~D-local-endpoint~~ — **SUPERSEDED 2026-08-29: benchmark against a fast CDN instead** … NET-8
> rewritten; no owner setup required." — ACCEPTANCE-PROTOCOL.md:929
> vs "**Owner dependencies** … NET-8 local throughput endpoint (file served from fw-net or a
> neighbour qube)." — line 921
> vs "**Owner-attended session** | SG feature-ON arms, … dom0 GUI progress click, NET-8" — line 911

NET-8's own row (line 808) needs only "NET-2, fw-net up" — nothing attended. Two stale entries
keep a retired owner obligation alive and pad the attended session.

Minimal correction: delete the line-921 bullet; drop NET-8 from the attended profile (or replace
with "NET-8 only if the CDN is unreachable from fw-net").

---

## RB-19 — FRICTION — residual small defects

Category: mixed (task cats. 2, 4, 7).

1. **§2.6 arithmetic:** "875 GB, 80.0% used, ~163 GB free" (line 611) — 875 at 80.0% leaves
   175 GB; §2.1:520 and §2.2:549 say "~155 GB free" for the same date. Three figures for one
   snapshot; the watermark logic is unaffected but the numbers cannot all be right.
2. **Duplicate paragraph:** "Pin the release for the whole campaign rather than …" appears twice
   in P1.0, lines 757 and 761, verbatim but for one word.
3. **§0.1 wait table:** "The three-exit waits: `w_session` / `w_install` / `w_halt` / `w_screen` /
   `w_alive`" (line 39) — `w_screen` is a classifier and `w_alive` a one-shot probe (e2e-wait.sh:27,
   35), neither has exits; `w_install` has five and `w_halt` two. Mislabels the contract the row
   exists to teach.
4. **Hardcoded host geometry:** the appvm cell's "none fullscreen-sized" tripwire compares window
   PNGs against literal `5120 * 99 / 100` × `1440 * 99 / 100` (matrix.sh:475) — i.e. one specific
   dom0 monitor. On any other display the check can never fire (a check that cannot fail), and the
   doc's step-6 selector map (line 145: "judged from pixels: ≥1 window mapped, none
   fullscreen-sized") does not say which screen defines "fullscreen". Derive the bound from the
   actual dom0 geometry (`qtest resize query`) or the guest resolution, and say which in the map.
5. **H3.2 not applied where it is cited:** `cell_appvm` grades "notepad opened but dom0 got NO
   window" (matrix.sh:480) from an empty tar without the CAPTURE-FAILED/EMPTY discrimination
   H3.2 (doc line 673) mandates — a refused capture (untagged/renamed target) would be recorded as
   a product FAIL. e2e-lib has `_target_serviceable` for exactly this; matrix.sh does not use it.
6. **Gate-0 HEAD wording:** §1 ("With no commit argument it asserts against HEAD, which is what
   you want when testing what you just built", line 486) sits in the campaign-contract section
   while §0.1:42 calls a missing commit argument "wrong for a campaign" — same tool, opposite
   framings, only context distinguishing them. One clause in §1 ("for a campaign, always pass
   `$REL` — §0.2 step 1") would close it.

---

## Category coverage

Findings were sought in all seven requested categories and found in all seven: (1) unreachable
success criteria — RB-03, RB-04, RB-07 (consequence), RB-08; (2) doc-vs-doc and doc-vs-script
contradictions — RB-04, RB-06, RB-11, RB-12, RB-13, RB-14, RB-17; (3) circular/unsatisfiable
prerequisites — RB-01, RB-02, RB-16; (4) vacuous gates / grades from missing data — RB-10, RB-11,
RB-16, RB-19.4-5; (5) ambiguous qube targeting — RB-06 (appvm subject), RB-12 (win10-gold0);
(6) ordering hazards — RB-05, RB-07, RB-09; (7) stale references — RB-13, RB-14, RB-15, RB-18,
RB-19.

Checked and found sound (for the record): §0.2 step 1/5 staging paths and expect-lines match
`assert-payload.sh` and matrix.sh's inputs exactly; the §0.5 Route A/B commands match
`push_payload` verbatim; §0.6's placeholder/locale/SIZE_MB traps match the builder; the seeded-cell
double-opt-in (H3.11) matches `run_install`'s guard; the §0.2 step 6 selector map matches the
`case` dispatch line-for-line; `golden.sh` seal/verify message texts and exit codes match §0.4; the
`w_session`/`w_halt`/`bootwait`/`wait_install` exit tables in §0.3 match the scripts (with the
minor cpu=NA nuance: e2e-wait.sh:62-67 treats BLACK×3 with *unreadable* CPU as TERMINAL, while
H3.3 requires "CPU≈0" — fail-toward-terminal, noted but not filed); the RND/SG instrument scripts
named in §8-§9 all exist in `guest/` or `tools/viewcheck/`.
