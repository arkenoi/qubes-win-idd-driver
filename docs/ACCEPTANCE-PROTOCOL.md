# QWT Acceptance Protocol

**Scope.** Full acceptance for the QWT-NG deliverable (installer, gui-agent, IDD driver, PV-NIC latch, updates agent, safeguards), runnable **as a whole or in parts**, starting from pristine Win10/Win11 vendor images. Every phase and cell below has a stable ID, a named entry stage, a named exit stage, and prerequisites by ID — start anywhere the prerequisites are met. Inherited and binding: CLAUDE.md's autonomy/instrument rules, the PV-network testing protocol (CLAUDE.md, 2026-08-29 — encoded here in P2, not reinvented), the memory rules (never `service.gui-fullscreen`, never resize-to-viewport, canonical benchmarks, roster names only).

**ID scheme.** Stages `ST*` (§2.1), restores `R0–R4` (§2.3), phases `P0–P5`, cells `G0`/`C1–C12` (install), `NET-0–8` (network), `U0–U6` (updates), `RND-0–9`+`BENCH-0–2` (rendering/perf), `SG0–SG11` (safeguards), harness rules `H0–H5` (§3). Per-OS stage suffix: `.10` / `.11` (e.g. `ST1.10`).

---

## 0. RUNBOOK — do exactly this (added 2026-08-30)

This section exists because the rest of this document is dense REFERENCE material with no executable
procedure, and the operational parts got improvised. Every failure of the 2026-08-30 attempt was
covered somewhere below and still happened: a hand-rolled runner was written instead of using the
harness (H0), the release was delivered by a cdrom route the harness does not use, bare `sleep`
polls replaced the three-exit waits (H2), two Windows guests ran at once (H3.6), and cells were
cloned from a golden that had been used all evening as a scratch guest (P1.0). Read this section
first; use the rest as reference.

**The harness already exists. Do not write another one.** `mgmt/harness/matrix.sh` implements every
cell (`cell_fresh_1stage`, `cell_fresh_2stage`, `cell_seeded`, `cell_upgrade_stock`, `cell_appvm`)
on top of `reclone / push_payload / run_install / verify_installed / start_vm`, with the waits from
`mgmt/harness/e2e-wait.sh`. If something is missing, ADD IT THERE and commit it (H0).

### Campaign, in order

    # 1. Pin the release. Never gate against HEAD - it moves under a campaign.
    REL=<commit>                      # the commit the artifacts were built from
    tools/assert-payload.sh <payload-dir> "$REL"        # Gate 0, must print PASS

    # 2. Golden custody. Refuses if a golden drifted; UNSEALED also fails.
    mgmt/golden.sh verify win10-clean
    mgmt/golden.sh verify win11-fresh

    # 3. One Windows guest at a time (H3.6). Halt everything before starting.
    for v in $(qvm-ls --raw-data --fields NAME,STATE | grep '^win1' \
               | grep -v Halted | cut -d'|' -f1); do qvm-shutdown --wait --timeout 300 "$v"; done

    # 4. Stage the artifacts the harness expects.
    #    $MATRIX_WORK/qwt-setup.tar.gz              <- tarball of the release package
    #    $MATRIX_WORK/dl/qwt-full-package/gui-agent.exe
    #    $MATRIX_WORK/dl/qwt-improved-iso/MANIFEST.json

    # 5. Run cells SERIALLY through the harness. Never two at once, never a hand-rolled loop.
    CELLS="win10-1stage win10-2stage win10-stock win11-1stage win10-appvm win11-appvm" \
      MATRIX_OUT=$HOME/qwt-matrix/$(date -u +%Y%m%d-%H%M%S) bash mgmt/harness/matrix.sh

    # 6. Verdicts are the harness's own PASS/FAIL lines plus $MATRIX_OUT/matrix.log.

### Hard prohibitions (each cost a real failure)

| Never | Because |
|---|---|
| Write a parallel runner / hand-rolled wait | H0/H2. The harness has three-exit waits; a bare `sleep N && continue` is prohibited outright. |
| Start a second Windows guest | H3.6. Concurrent runs have destroyed each other's results; three 8 GB guests starved qubesd. |
| Boot, log into, or "just check" a golden | It contaminates every clone made from it afterwards. Use a churn qube. See §Golden custody. |
| Grade a cell whose payload was not Gate-0 verified | A whole cell once ran against the commit BEFORE the fix under test. |
| Read a drive letter as "the release ISO" | An answer disc left attached from provisioning is picked up instead. Find media BY CONTENT. |
| Use `attach --persistent` to attach now | It is an alias for `assign --required` = applied at NEXT START. Use plain `attach` on a running guest. |
| Treat silence as absence | A watcher that never sampled is `INVALID-VACUOUS`, never PASS (H2 vacuity gate). |

### Golden custody (the rule, enforced)

A golden is **sealed**, then only ever **cloned**:

    mgmt/golden.sh seal   win10-clean "ST2G.10 - release <ver>"
    mgmt/golden.sh verify win10-clean      # exit 2 = drifted or unsealed -> do not clone

`seal` refuses a running qube; `verify` needs no boot (booting a golden to check it would BE the
modification) and keys on the root-volume revision list, which gains an entry on every clean
shutdown. Seals live in `mgmt/goldens/*.json` and are committed - a record that dies with the
session is not a record.

---

## 1. How to run one part

**GATE 0 — VERIFY THE PAYLOAD. Not optional, and it comes before everything else.**

    tools/assert-payload.sh <payload-dir-or-tar> [expected-commit]

It fails closed on: missing manifest, any file not matching `SHA256SUMS.txt` (catches a truncated
push before it reaches a guest), a `driver_repo_commit` that is not the commit you meant, or a
staged `Install-QwtImproved.ps1` that differs from the repo at that commit. With no commit argument
it asserts against HEAD, which is what you want when testing what you just built.

**Why it is Gate 0:** on 2026-08-29 a full cell was run against a payload built from `f777bec` — the
commit BEFORE the fix under test — and graded as if it were meaningful. The guest's own log named
the package in its first line. That is an acceptance-protocol breach, not a slip: an ungraded
artefact makes every number in the cell a number about a different build. **A cell whose payload
did not pass Gate 0 is `INVALID-PROVENANCE`, not a result.** Record the gate's PASS line in the
part transcript.


1. **Allocate a campaign id** even for a single part: `AP-<UTCdate>-<seq>` (a partial run is a campaign with one part). Part run id: `<campaign>/<part-id>` (e.g. `AP-20260830-1/NET-2.10`).
2. **Check prerequisites by ID.** Each cell lists `prereq:` — phase-level gates (always at least `P0-CORE`) and its entry stage. If the entry stage is standing on the roster and its manifest attestation matches (§2.4), start there; otherwise build it via the cheapest restore in §2.3. **No cell may reprovision (R3) where a cheaper restore (R0/R1/R2) reaches its entry stage** — this is a protocol rule, not advice.
3. **Write the five-line header** (`HYPOTHESIS / BASELINE / VARIABLE / INSTRUMENT / BUDGET`) into the part transcript before launching. A header with a blank line does not launch (H0.3).
4. **Run through the harness** (§3): e2e-lib + `mgmt/harness/e2e-wait.sh` waits only, `QTEST_VM=<qube>` always set, serial execution, one Windows guest running at a time.
5. **Evidence** lands under `~/qwt-accept/<campaign>/<part-id>/` (override `ACCEPT_OUT`), never under session tmp (H1.2). The part ends with verdict lines in the H5 grammar; a part that dies without a verdict line is recorded `ABORTED`, never inferred successful.
6. **Restore the entry stage or capture the exit stage** per §2.4 before releasing the qube, and record pool % if the part ran any R2/R3/R4.

Example — run just the AppVM zero-reboot network cell: prerequisites are `P0-CORE` + stage `ST3A.10` (fresh AppVM boot, free via R0). So: `qvm-start win10-app` (via `start_vm`), wait session, run NET-1 attestation, then NET-2. Total ~25 min, 0 GB, no reprovision.

---

## 2. Stage graph and restores

### 2.1 Stages

Three flavors of "pristine" exist and each carries a proof obligation recorded in its stage manifest (§2.4). One unified naming (this table supersedes the per-section aliases `PRISTINE-10`, `STOCK-10`, `OURS-N`, etc. — see §12 note 1):

| ID | Name | Definition | Proof of the stage | Standing? |
|---|---|---|---|---|
| **ST0** | pristine-OS | Windows from the untouched vendor ISO via `mgmt/reprovision-usb.sh`, answer stick with **no QWT payload**. No xen* service, no QWT registration ever. **No qrexec** — undriveable. | ISO sha256 pinned in FINDINGS re-checked against the loop backing file; stick assertions pass; post-hoc: no Qubes/xen services, no QWT Uninstall entry. | **PARKED AND CLONED — build ONCE per OS.** (Owner, 2026-08-29: "why do you run windows install each time, despite the fact process is determenistic and gives you the same disk image afterwards? ... when there is no qwt windows stays the same". This row previously said "never parked", which was wrong and cost ~20 min per avoidable reinstall.) A QWT-free Windows does not drift, so ST0 is the reusable base for every non-F cell: clone it (R2) and install into the clone. **A full reprovision (R3) is warranted ONLY for the cell that actually tests Windows-install-plus-QWT-at-first-logon via the answer file** — nothing else may reinstall. Park one ST0.10 and one ST0.11 and keep them pristine; never park a half-installed or mid-campaign image in their place. |
| **ST0T** | pristine + testsigning | ST0 with testsigning armed by the stick (legit field state). | As ST0 + `SystemStartOptions` shows TESTSIGNING post-hoc. | Never parked (same reason). |
| **ST1** | stock-QWT 4.2.2 | ST0 + genuine upstream QWT installed at provisioning (stock stick loop11; `STOCK_SETUP` = stock MSI via our installer for single-variable control, `REAL_STOCK_EXE` = vendor exe for field fidelity). | Stock MSI sha256 byte-identical to vendor bundle (`7049322128d1cf...`) before stick build; guest-read QWT **and** agent both 4.2.2.0 (the 4.2.2/4.3.3 hybrid was caught only by checking both); `xenbus_monitor` Start=2 + Running; testsigning on. | **PARKED AND CLONED, standing — one per OS.** (Owner, 2026-08-29: "so you can save at least two types of images: pristine and stock qwt".) Building a stock image costs a full reprovision (~18 min) and, like ST0, it does not drift once built, so it is parked and cloned rather than rebuilt. Together with ST0 that is FOUR standing images: ST0.10, ST0.11, ST1.10, ST1.11. Disk is the ONLY constraint (~20 GB each ≈ 80 GB against ~155 GB free); qube names are free — policy is tag-based, so create and tag churn qubes as needed. |
| **ST1F** | stock, testsigning off | ST1 + `bcdedit /set testsigning off` + reboot + verify qrexec answers and PV drivers still bound (stock binaries are production-signed — verify, don't assume). | ST1 proofs + testsigning inactive in PRECONDITION. | Transient (constructed for C5 only). |
| **ST2** | ours-installed (fresh lineage) | Stock-or-pristine lineage carrying the current CI package. | Package passed **G0**; guest-read MSI hash vs artifact; running agent hash vs `MANIFEST.json`. | Parkable on churn qube within a campaign. |
| **ST2G** | golden ours | Accepted release on the standing golden (`win10-clean` / `win11-fresh`). | ST2 proofs + stage manifest current (drift recorded — `win10-clean` is 4.3.15, no longer pristine-4.3.2; recorded, never read as pristine). | **Standing.** |
| **ST2NP** | ours, no PV disk | Current release installed `/nodisk` → `pv_boot_disk=false`. Enables C8. | ST2 proofs + PRECONDITION `pv_boot_disk:false`. | Transient. |
| **ST3** | template ours+latch | Golden → `mgmt/clone-to-template.sh` with `PRIME_NETVM=latch`, `XENVIF_PKG` set. Script self-verifies: latch readback across a boot cycle, net-identity scrub residue=0, xenvif sha256 in DriverStore. A template failing any gate is not shipped. | Script gates + NET-1 attestation. netvm='' **forever**. | **Standing** (`win10-tpl`/`win11-tpl`). |
| **ST3A** | AppVM fresh boot | AppVM boot off ST3; volatile root ⇒ bit-identical every boot. | NET-1 attestation. | Free, infinitely repeatable (R0). |
| **ST4** | network-bound AppVM | ST3A + live netvm attach. **Transient by design** — every boot re-runs the PV-NIC install; that one-boot completion *is* the acceptance property, not a state to park. | NET-2 acceptance. | Never parked. |
| **ST5** | post-update | Serviced image after a dom0-driven WU pass. | U3 §7 post-boot verdict. | Transient: promoted to new golden (owner sign-off) or reverted (R1) within the two-shutdown window. Never parked long-term (+5–15 GB drift). |

**Locale is part of pristineness.** Win10 media is `Win10_22H2_EnglishInternational` = **en-GB**; `build-answer-stick.sh` defaults en-US; a mismatch drops Setup silently to the interactive locale picker (tell: guest CPU ~1 s/40 s instead of ~45 s/40 s; proof: screenshot). Every Win10 stick build passes `LOCALE=en-GB`. Win11 24H2 eval media is en-US and matches the default — verify once per new media anyway.

### 2.2 Qube → role mapping (current allocation; names are NOT fixed — policy is tag-based, so create and tag new qubes freely)

| Qube | Class | netvm standing | Role / standing stage |
|---|---|---|---|
| `win10-clean` | StandaloneVM | fw-net | **ST2G.10** golden |
| `win10-u10` | StandaloneVM | fw-net | **churn** — sole Win10 R3 target; carries transient ST0/ST1/ST2 within campaigns |
| `win10-tpl` | TemplateVM | **'' always** | **ST3.10** |
| `win10-app` | AppVM | fw-net | **ST3A.10 / ST4.10** network vehicle |
| `win11-fresh` | StandaloneVM | fw-net | **ST2G.11** (25H2 current build) |
| `win11-24h2` | StandaloneVM | fw-net | Win11 churn + upgrade-path guest (older-ours lineage; no proven Win11 stock stage — owner decision D3, §11) |
| `win11-tpl` | TemplateVM | **'' always** | **ST3.11** |
| `win11-app` | AppVM | fw-net | **ST3A.11 / ST4.11** (the config that PASSED zero-reboot attach) |

Templates never get a netvm; Standalones/AppVMs must have one for any network cell. `fw-net` EXISTS and has been serving traffic throughout; this qube simply lacks policy to START or inspect it (`qvm-check` says `non-existent!` — a filtered view — while `qrexec-client-vm fw-net admin.vm.CurrentState` says `Request refused`, a POLICY refusal). Never report it as absent. Only if it is genuinely down is that an owner escalation; binding and dialog-watch need it not, traffic does.

**Parking allocation (2026-08-29) — NO owner action needed.** An earlier version of this note claimed qube names could not be invented because dom0 policy is name-based, and on that basis asked the owner for two extra names. **That was false and is retracted.** Policy is TAG-based (`@tag:win-idd-testbed`), verified by creating `qwt-probe-tmp` - a name on no roster - tagging it, and getting full Admin API access immediately. See `.claude/skills/rig-capabilities/SKILL.md`.

So: **create as many qubes as the pool affords, and tag each one `win-idd-testbed` at creation.** Park four standing images - `ST0.10`, `ST0.11`, `ST1.10`, `ST1.11` (~20 GB each, ~80 GB of the ~155 GB free) - and clone them into freshly-created churn qubes per cell. The only real limit is pool space, so prune churn qubes when a campaign ends and re-check `qvm-pool info vm-pool` before adding a park. The one hard rule that IS true: a new qube must be TAGGED before any policied call, which is why `qvm-clone` fails and `clone-to-template.sh` uses create -> tag -> copy.

**PRIVATE VOLUME SIZE — check it before every template/AppVM build.** README.md says it plainly:
QWT places user data on `Q:\Users` on the PRIVATE image (stock behaviour), and the Qubes default
private volume is **2 GiB**, which a bare Windows profile does not fit in. Extend to **20 GiB**:

    qvm-volume extend <vm>:private 20GiB

**The TEMPLATE must be extended too** — an AppVM's private volume follows its template's size.
Skipping this is silent and total: the guest boots, autologon works, `qtest run` works, and ONLY
file copy fails (`getting Documents path failed 0x80070002`), so no probe, health-check or payload
can reach it and the cell cannot be graded at all. Measured 2026-08-29: `win11-tpl`/`win11-app` at
20 GiB worked; `win10-tpl`/`win10-app` built at the 2 GiB default did not, and I misdiagnosed it as
a product defect for an hour before reading the README. `mgmt/clone-to-template.sh` now extends both
and fails loudly if it cannot. **Assert `private >= 20 GiB` in P0 preflight for every guest a cell
will push to.**

### 2.3 Restore mechanisms and costs

| # | Mechanism | Wall clock | Pool cost | Notes |
|---|---|---|---|---|
| **R0** | AppVM reboot (volatile root) | 2–4 min | 0 GB | THE workhorse: every AppVM cell starts bit-identical ST3A for free. |
| **R1** | `qvm-volume revert <vm>:root` | ~1 min | ≤0 (frees drift) | Qube Halted; `revisions_to_keep=2`, revision cut per clean shutdown ⇒ window = **two clean shutdowns** past capture. An upgrade cell (boot→install→reboot→verify→shutdown) fits exactly; one extra reboot forfeits the stage. Permission from this qube unverified — decision D5 (§11); if denied, R1 rows collapse into R3. |
| **R2** | Clone a parked master into a roster name (create → tag `win-idd-testbed` → prefs → volume clone; one-shot `qvm-clone` fails tag policy) | 5–10 min | **≈0 GB at creation** (lvm_thin CoW, measured 2.7 s for 80+20 GiB — §12 note 4); budget ~20 GB settled divergence | Master Halted. Re-apply reset-prone properties (§2.5). |
| **R3** | `mgmt/reprovision-usb.sh <vm> <iso-loop> <stick-loop>` | 17–20 min measured (Win10; 993–1108 s in-guest). **Win11 unmeasured — time once and record.** | ±0 GB (remove-then-recreate on the same name, never a sibling) | Stick rebuilt in place (inode-preserving, constant SIZE_MB); locale match; drain queued qrexec BEFORE the remove (§2.5). |
| **R4** | `mgmt/clone-to-template.sh <golden> <tpl> <app>` template-pair rebuild | 45–75 min (≈8 serial boots) | +~20 GB (replaces old template root) | Golden Halted; script self-verifies (see ST3). |

**Restore validation (every restore, every mechanism):** `qvm-ls` state sane → `QTEST_VM=<vm> tools/qtest run "echo ok"` → guest-read stage attestation (QWT version, agent hash vs MANIFEST, testsigning, `xenbus_monitor` state; for ST3/ST3A additionally latch readback `nics:1, vif_enum_key:true, task_main:true`). An empty `qtest shot` tar is NOT "no windows" — confirm the target exists and is tagged first. No network-shaped grading within ~90 s of qrexec up.

### 2.4 Capturing a stage

1. Finish in-guest work; **clean shutdown** (`qvm-shutdown --wait`, never `qvm-kill` — a kill mid-driver-transition half-switches the boot path, 0x7B on every later boot). If a driver-restart modal is on the console, shutdown is the only legal release.
2. Confirm the qube **stays Halted ≥60 s**. A flip to Transient = queued qrexec auto-starting it: stop calling, drain per §2.5, re-capture.
3. The capture is the halted qube; the freshest `-back` revision is its undo point.
4. Append a **stage manifest** to FINDINGS.md: date, qube, stage ID, guest-read QWT+agent versions, package/MSI sha256 + the CI run id whose G0 gate it passed, testsigning, monitor Start/state, netvm at capture, root usage bytes, pool %. A stage whose attestation no longer matches its manifest is **stale**: refresh it or downgrade the dependent cell's claim. Drift is recorded, never hidden.

### 2.5 The reset trap and the drain recipe

R2/R3 re-create the qube and **reset properties**. After qrexec is proven up, re-apply:

```
qvm-prefs <vm> qrexec_timeout 6000    # standing value; 15 is ONLY a drain tool
qvm-prefs <vm> netvm fw-net           # Standalones/AppVMs only; NEVER templates
qvm-prefs <vm> virt_mode   # hvm      qvm-prefs <vm> kernel  # ''
qvm-features <vm> os       # Windows  qvm-tags <vm> list     # win-idd-testbed
```

Also: **unassign the answer stick and clear `qemu-extra-args`** after provisioning — the `--required` block assignment makes every later boot depend on `win-idd-mgmt`'s loop layout, silently bricking parked stages when loops renumber (audit owed — decision D2, §11).

**Drain recipe** (before ANY kill/remove of a roster guest; queued qrexec calls outlive their caller and auto-start Halted qubes — a guest that "restarts forever" is being restarted by you):

```
qvm-prefs <vm> qrexec_timeout 15      # BEFORE the kill/remove
qvm-kill <vm>                         # queued calls now die in ~15 s each (measured: removal 5+ min → 7 s)
# watch: Transient blips as the queue drains, then Halted CONTINUOUSLY
qvm-prefs <vm> qrexec_timeout 6000    # restore ONLY after it stays Halted — restoring early re-pins 100 min/call
```

The protocol standardizes **6000** as the standing timeout everywhere, including harness reclones — `matrix.sh`'s `reclone` currently sets 600 and must be aligned (P0-PRE; §12 note 5).

### 2.6 Disk budget

vm-pool (2026-08-29): **875 GB, 80.0% used, ~163 GB free**. Six owned roots ≈122 GB + ×2 `-back` revisions + privates + volatiles. Budget **~20 GB per fully-diverged image**; clones are ~0 GB at creation (R2), the settled delta is what costs.

| Level | Pool state | Rule |
|---|---|---|
| GREEN | ≥150 GB free | normal; clones/reprovisions allowed |
| AMBER | <120 GB free | no new clone/template rebuild until the prune ladder runs |
| RED | ≥88% used (~105 GB free) | STOP all provisioning; prune; still red → owner |

These watermarks are canonical protocol-wide (they supersede the update draft's "60 GB free" floor — stricter wins, §12 note 7). Record pool % before/after every R2/R3/R4. The eight roster guests ARE the stage set; headroom exists for ~3 extra fully-materialized images before RED and the protocol uses **zero** standing extras — all additional state is transient within one campaign. Prune ladder when AMBER/RED: (1) reprovision-or-park `win10-u10`; (2) R1-revert drift on Standalones; (3) `revisions_to_keep 2→1` temporarily on expendable Standalones only — never templates or goldens; (4) removing any golden/template = owner sign-off.

### 2.7 Media / loop inventory (verify before every R3)

| Loop | Backing | Role |
|---|---|---|
| loop0 | `Win10_22H2_EnglishInternational_x64v1.iso` | Win10 ISO (**en-GB**) |
| loop3 | `win11-24h2-eval-x64-en-us.iso` | Win11 ISO (en-US) |
| loop9 | `answer-usb.img` | release stick (our package, `/idd`) |
| loop10 | `answer-usb-win11.img` | Win11 stick |
| loop11 | `answer-usb-stock.img` | stock-QWT stick |

`losetup -l` shows loops on **deleted inodes** (loop4, loop7): stale bytes, never use. The script asserts the stick loop's size/inode; extend the same eyeball to the ISO loop (script does not check that side).

---

**WEDGE CAPTURE — what to collect the moment a guest goes unresponsive (owner action).**
When the wedge hits, every in-guest channel dies at once: qrexec stops answering, no windows are
mapped so captures come back empty, and the event log records nothing for the whole window
(measured twice, 2026-08-29). Everything this qube can reach runs THROUGH those. What survives is
outside the guest:

- **`sudo tail -200 /var/log/xen/qemu-dm-<vm>.log`** in dom0 — the device model's own view. Shows
  whether the guest is still issuing device I/O, which separates "CPU spinning but alive" from
  "stopped issuing I/O entirely". Nothing measurable from inside can distinguish those.
- **`sudo xl dmesg`** — hypervisor-side messages for the same window.
- `admin.vm.CurrentState` cputime deltas — reachable from here, and the only in-scope signal.

**This dev qube CANNOT read either log** — tested 2026-08-29, not assumed: `admin.vm.Console` is
refused by policy and `/var/log/xen/` is unreadable here. So it is a genuine owner action, and it is
the highest-value evidence available for this failure class. `xencons` (now built in CI) is the
in-band complement: a PV console readable via `xl console` that does not depend on qrexec.

## 3. Execution rules (H) — every part runs through these

### H0 — Foundation

Build on the corrected libraries, never around them: e2e-lib (`.claude/skills/win-guest-e2e/e2e-lib.sh`), wait primitives `mgmt/harness/e2e-wait.sh` (**must be promoted first — P0-PRE**; today `matrix.sh` sources it from a garbage-collectable session tmp path), experimenter rules, `tools/winshot.py` classifier, `tools/qtest` (refuses unknown/untagged targets; **`QTEST_VM` mandatory, no default** — §12 note 6), and `mgmt/harness/matrix.sh` cell patterns (`reclone push_payload run_install verify_installed start_vm`). **No hand-rolled waits** — a missing wait is added TO the library with the three-exit contract, committed, then used. **Five-line header per part** (§1.3).

### H1 — Run identity

One id from dom0 log line to guest log byte. Durable results tree per §1.5, append-only transcript; a re-run is `<part-id>.2`, never an overwrite. Guest-side: `startrun` deletes `C:\qwt-improved-install.log`, **verifies the delete** (failed delete = instrument failure, refuses the run), writes `E2ERUN-<UTC>-<pid>`; all guest-log judgment via `_logtail` past the marker. Other accumulating state (MSI verbose log, event log) is cleared or timestamp-baselined the same way. **Build fingerprint asserted, not assumed:** campaign records `package_version` + binary sha256s once; each part re-asserts; **G0 re-checks the downloaded artifact** (the artifact, not the pipeline's promise); after any install, the RUNNING binary's hash vs manifest — a harness proceeding past a failed install reports numbers for a build never running: `INVALID-WRONGBUILD`, not FAIL.

### H2 — Waits, signals, grading gates

Every wait keys on a real signal, has exactly three exits, and says which it took: **GOAL** / **TERMINAL** (RECOVERY screen; BLACK×3 min with CPU≈0; Halted with restart budget spent — stops the part, preserves the guest) / **STALL/DEADLINE** (no progress for `STALL_SECS`, default 300, or budget spent — FAILS the wait, never falls through). Bare `sleep N && continue` is prohibited; the only fixed delay is a *declared settle window* attached to a grading step.

Signal inventory (cheapest that answers; prefer signals that survive dead qrexec): domain state (`w_state`); qrexec liveness (`w_alive`); **CPU rate** via `admin.vm.Stats` (works with qrexec dead; `verify_installed` waits on 3 consecutive quiet reads); install progress = guest-log line COUNT past marker (fresh read per poll — a stream once died at 28/104 lines); `MSI_POLL` tail of `C:\qwt-install.log`; `EVENT_POLL` 1074/1076/6008 with capture date (who rebooted, read while the guest lives); screen via `qtest shot` → `winshot.py`. **Screenshots are read, not counted** — real error text often exists only in pixels (`Unknown option: /iddonly`); `DESKTOP` means "something renders", never "step succeeded". `qtest fullshot` is restricted to override-redirect windows and dom0-compositing checks — never an escalation from an empty per-window tar.

Two standing grading gates: **90 s session settle** before any network-dependent observable (measured inversion at +90 s), logged as `settle: 90s before grading <what>`; and the **vacuity check** — a grader confirms the phenomenon CAN occur in this configuration (canonical: the premature-reboot dialog is a "Xen PV Network Class" event and is VACUOUS on `netvm=''`; first-vif is vacuous on any guest that ever had a vif). A vacuous grade is `INVALID-VACUOUS`, never PASS.

### H3 — Glitch resistance (measured failure modes, standing procedures)

- **H3.1 Queued-qrexec drain** — §2.5 recipe. Never `xl destroy`; never diagnose a "wedged" guest before checking `qrexec_timeout`; never leave a harness pointed at a guest with a known-dead qrexec agent.
- **H3.2 Empty-capture triage** — three causes, told apart before grading: target missing/untagged → `CAPTURE-FAILED` (fix `QTEST_VM`); tool bug on old checkouts; genuinely no mapped windows → `EMPTY` (normal in seamless with no app open; `cap` opens notepad and retries). Recording `CAPTURE-FAILED` as a guest observation is an instrument failure.
- **H3.3 Headless-but-alive** — BLACK + no qrexec ≠ dead (measured: steady CPU, half-installed QWT). TERMINAL needs BLACK×3 min AND CPU≈0; CPU flowing resets the counter.
- **H3.4 ACPI first, kill last, revert after kill** — recovery screen honours ACPI in ~10 s; hard kills leave dirty volumes that block the next clone; remedy is `admin.vm.volume.Revert` (seconds, no boot needed). `reclone` implements this; use it.
- **H3.5 Restart budget + quarantine** — `E2E_RESTART_BUDGET=2`. On exhaustion or TERMINAL: stop, classify (screen+CPU+state+events), **preserve the guest** (its state is the only evidence). Quarantined name: no reclone over it; later parts targeting it record `SKIPPED-QUARANTINE`; campaign continues on other qubes. Release policy = owner decision D11.
- **H3.6 Serial, one Windows guest up** — concurrent runs have destroyed each other; three 8 GB guests starved qubesd. Orchestrator refuses to start over a live prior part; never edit a running script.
- **H3.7 `qvm-start` is fire-and-poll** — foreground `qvm-start` blocks up to qrexec_timeout on a non-booting guest (15 min measured). Use `start_vm`.
- **H3.8 Transients retried, errors kept** — 3 attempts with backoff on guest calls right after boot (rc=46 "no session yet" measured at t+1 s); every attempt's rc/stderr into the transcript (`2>/dev/null` without capture prohibited).
- **H3.9 Poll cadence floor** — ≥15 s between qrexec calls steady-state, absolute floor 5 s: per-second churn triggered the IPI-shootdown wedge. Budget waits to the tested path's timeline, not a habit constant.
- **H3.10 Watchdog** — every backgrounded run gets an independent hard-stop at the campaign deadline; it logs when it fires. Backstop, not substitute for H2.
- **H3.11 Seeded defects opted into twice** — `SEED_CELL=1` per-run flag mandatory; inherited env alone = HARD ABORT; seed state (including "unset") always echoed into the transcript. Injection clock = code-under-test clock; injection-vs-target ordering checked before reading outcomes. (Inherited env voided a matrix; a pre-installer injection voided six cells.)

### H4 — Part contract

1. **Self-contained baseline** — a part never assumes a prior part ran; it builds its entry stage via §2.3 and records golden+stage.
2. **Preconditions asserted on the signal the code under test consults** (MSI registration for "fresh"; `SystemStartOptions` for testsigning; absence of `XENVIF\...DEV_NET` for "never had a vif"; netvm attachment for any network grade). A failed precondition ⇒ `INVALID-PRECONDITION`, not a product verdict.
3. **Idempotent re-runs** — new results dir, recreated baseline, never grades its previous self's leftovers.
4. **Declared outputs** — verdict lines or `ABORTED`; silence is never success.
5. **Continue-on-failure** at campaign level, except quarantine or an explicitly declared shared-baseline dependency.

### H5 — Verdict grammar and the fail-proof registry

One machine-greppable line per check into `verdicts.tsv` + transcript: `<campaign> <part> <check> <VERDICT> <evidence-paths> <proof-ref>`.

- `PASS` — intended EFFECT demonstrated against a control, artifact hash-verified, AND the check has a fail-proof on record.
- `PASS-UNPROVEN` — succeeded but never seen to fail; explicitly second-class, counted separately in the summary. **This is how requirement "no check whose PASS was never seen to fail" is enforced: a check absent from the registry can never emit plain PASS**, and its fail-proof is a mandatory TIER-C item.
- `FAIL` — product failed a valid check (guest preserved per H3.5 where relevant).
- `INVALID` (`-PRECONDITION -INSTRUMENT -WRONGBUILD -VACUOUS -CONTAMINATED`) — never folded into FAIL, never dropped: an invalid PASS is worse than a FAIL.
- `TERMINAL-PRESERVED`, `SKIPPED` (`-QUARANTINE`/`-SELECTOR`).

**Registry:** `mgmt/harness/instrument-proofs.md` (checked in) maps check id → date/run where it FAILED on a subject with the defect deliberately present. Entries require the failing run's evidence path, not "it would fail". Metrics additionally require stability: ≥3 runs on ONE unchanged build (≥5 for drag), comparisons interleaved with the control. Every PASS/FAIL line references an openable artifact; where the claim is about what the user sees, the evidence is **pixels** (`RecreateDuplication: recovered` was logged while every window was frozen). Cold boot is part of acceptance wherever a boot path is in scope. **Retraction:** wrong verdicts get `RETRACTED:<reason>` suffixed in place (line never deleted), summary corrected, FINDINGS note same session.

---

## 4. P0 — Preflight

### P0-PRE — adoption prerequisites (repo/config changes owed once, before any campaign)

*Entry: none. Exit: none. Cost: ~1 h dev-qube work, 0 GB.*

1. Promote `e2e-wait.sh` → `mgmt/harness/e2e-wait.sh`, re-point `matrix.sh`, commit (one commit).
2. Align `matrix.sh reclone` to `qrexec_timeout 6000`.
3. Promote `scratchpad/snap-regress.sh` → `tools/` (RND-8 driver).
4. Enable `.githooks/pre-commit` (`git config core.hooksPath .githooks`) — desktop-capture screening.
5. Confirm `dom0/10-install-resize-service.sh` is installed on the current dom0 (owner) — gates RND-8.
6. One-time audits: `qemu-extra-args`/stick assignment on parked guests (D2); R1 permission probe (D5).
7. Create/refresh `mgmt/harness/instrument-proofs.md` and the known-issue register (D9).

### P0-CORE — campaign preamble (every campaign, incl. single-part)

*Entry: current roster. Exit: unchanged. Prereq: P0-PRE. Cost: ~20–40 min, 0 GB.*

1. **G0 — catalog-signature gate** (dev qube, offline, before any guest work). Enumerate every `*.cat` in the setup payload AND inside `msi/installer.msi` (`7z x` — the five PV catalogs live in the MSI image). For each (DER PKCS#7): assert non-empty signerInfos via `openssl asn1parse` (or `osslsigncode` if sanctioned — D6); assert exactly ONE unique signer matching a shipped `.cer` (throwaway CI cert — match by shipped cer, never CN). **PASS:** N≥7 catalogs, 0 unsigned, 1 signer. Root cause this gate exists for: `patch-xenbus-inf.ps1` regenerated all catalogs but re-signed only `xenbus.cat` — 4/5 shipped unsigned, 27.9 min modal hang. **Negative control:** a defect-era unsigned `.cat` fixture substituted into a payload must FAIL the gate; until that run, G0's PASS is `PASS-UNPROVEN` (fixture sourcing = D7). **No guest cell runs on an artifact that has not passed G0.**
2. Build fingerprint recorded (H1); pool % + watermark check (§2.6); roster check (`qvm-ls --fields NAME,STATE,CLASS,NETVM` — classes match, templates netvm='', names exist).
3. fw-net status confirmed with the owner if any traffic cell is in scope (recorded in the run log; a traffic FAIL without this is unattributable).
4. Instrument validations in scope for the selected parts: `reboot-dialog-watch.ps1 -SelfTest` (before NET cells), pixel-differ known-change/known-no-change ×3 (before SG5/RND freeze checks), metric stability runs (before BENCH verdicts).

---

## 5. P1 — Install and upgrade matrix

Scope: every path through `packaging/setup/Install-QwtImproved.ps1` (`install.cmd`), defined from the installer's own branching. `/iddonly`, `/iddoff`, `/updatesonly` bypass this dispatch and are exercised in P3/P4.

### P1.0 — Authority rule (every cell)

The installer's first act writes `=== PRECONDITION === {json}` (run_id, testsigning, installed_qwt[], pv_boot_disk, xenbus_monitor{status,start,pids}, pending_request[], pv_drivers{}, reboot_already_pending, os_build) to `C:\qwt-improved-install.log`; the `=== RESULT ===` trailer carries `stage`, `ok`, `error`, `detail.upgrade_mode`. **The PRECONDITION line is the authority on found state; `upgrade_mode`+`stage` on the branch taken.** A harness probe disagreeing with either is the harness being wrong (the 2026-08-28 matrix was voided exactly this way, `c1f4312`). A log with no PRECONDITION line = **instrument failure**, never any scenario. Seed state is echoed per H3.11. **Preconditions are never constructed by uninstalling** — QWT *is* the qrexec agent; `msiexec /x` removes the control channel (it cost `win10-u10`). Cells run **serially**, each on a fresh restore of its entry stage on a **roster name** (churn qubes; never a sibling qube). PASS clones are consumed (restored over); FAIL states are preserved. Refusal cells (C7, C9) may share one restore in sequence if a fresh PRECONDITION before each run is byte-equivalent on decision-relevant fields.

Branch map (from source): entry **E1** two-stage (testsigning off → stage1 prepare/reboot/resume) vs **E2** stage-2-only (testsigning on; stage 2's `Import-PayloadCerts` is the only cert import — the path the hang lived on). Detection: **D0** clean; **D1** in-place MSI major upgrade; **D2** same-version reinstall (`REINSTALL=ALL`); **D3** uninstall-first → **D3r** hard refusal when `pv_boot_disk=true` / **D3c** continue / **D3b** rc-3010 uninstall-reboot + `-ResumeAfterUninstall`; **R2gate** PV-disk downgrade refusal (test hook `QUBES_FAKE_INSTALLED_PVDISK_VERSION`). Orthogonal: **I** `/noidd`, **P** template-vs-known-class pvnic priming. Note: upgrade-over-stock vs upgrade-over-ours is the **same code path, different data** (kept as separate cells because the data — monitor Auto+Running, no prior cert trust — is what the suppressor/kill logic exists for).

**Payload delivery — two routes, both legitimate (added 2026-08-30, CORRECTED same day).**

*Correction first:* an earlier version of this paragraph said the release must never be attached as a cdrom for an install cell. **That was wrong and is retracted.** Attaching the QWT ISO and running its installer IS a standard path — it is how a user actually installs QWT, so it is the realistic route and must stay covered. The failure that produced the bad advice was mechanical, and is worth recording because it is silent:

> `qvm-device block attach --persistent` is documented as **"Alias to `assign --required`"**. So `--persistent` on *attach* is not an attach at all — it is an assignment, which is applied **at the qube's next startup**. Against a running guest it therefore succeeds and changes nothing the guest can see; the ISO simply never appears. Worse, once assigned, a subsequent plain `attach` is refused with *"already assigned"*, so the obvious retry also fails. Correct usage: **`qvm-device block attach --ro --option devtype=cdrom <vm> <backend>:<devid>`** (no `--persistent`) to attach to a *running* guest, and `assign --required` *before* start when the disc must survive the install's own reboot. Verify by content in-guest, never by assuming a drive letter.

*Two different situations, do not conflate them (2026-08-30).* On an **installed, running Windows** an attached cdrom is perfectly visible — it has the PV drivers, and attaching the QWT ISO and running its installer is the standard way QWT is installed, including stock QWT onto a fresh VM. That is Route A and it is fully supported. The cdrom-invisibility caveat in `mgmt/reprovision-usb.sh` applies ONLY to **Windows Setup / WinPE**, which has no Xen PV drivers, which is why OS provisioning uses an emulated USB answer stick (WinPE does carry USBSTOR/USBXHCI inbox) rather than a second CD. Installing an OS and installing QWT onto a running guest are different problems with different media rules.

*Route A — ISO/cdrom (the user-realistic path).* Attach the release ISO, run `install.cmd` from it. Assert the disc's `MANIFEST.json` `source.driver_repo_commit` equals the release under test before running anything, and locate it by content (a drive carrying both `install.cmd` and `MANIFEST.json`) rather than by drive letter — an old answer disc still attached from provisioning will otherwise be picked up instead.

*Route B — `qtest push` (what `mgmt/harness/matrix.sh:push_payload` implements).* One tarball, pushed as a single file; `qtest push` is `qvm-copy-to-vm`, so it lands in `C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\` (`INC`). Extract guest-side into a per-cell directory (`rmdir /s /q C:\<dir>`, `mkdir`, `tar -xzf`), requiring its `EXTRACT_OK` echo — a stale directory from a previous cell is grading contamination. **Retry 3x with 20 s backoff keeping stderr** (H3.8): the first attempt fails in about a second on a session that has only just answered `QREADY` (`rc=46`).

Pristine-start cells are stick-orchestrated instead (no qrexec exists yet). Pin the release for the whole campaign rather than gating against `HEAD` — `HEAD` moves on every commit, so a campaign spanning any commit silently changes the artefact it gates against, which is what "single package for all tests" forbids.

**Golden provenance is a P0 assertion, not an assumption (added 2026-08-30).** Every install cell `reclone`s from a golden (`win10-clean` / `win11-fresh`), so the golden's state is inherited by every clone made from it. On 2026-08-30 the Win10 golden was used all evening as a scratch guest - agent binary hot-swapped twice, xencons side-loaded by hand, `debug` toggled, Windows Update enabled then disabled, private volume extended mid-life, repeated hard restarts - and cells were then cloned from it. Before any campaign, assert the golden matches its recorded stage manifest (§2.4); if it does not, either rebuild it or mark every cell derived from it `INVALID-CONTAMINATED` (H5). Diagnostic work belongs on a churn qube, never on a golden - and a golden that has been touched is no longer one, whatever its name says.

Pin the release for the whole campaign rather than comparing against `HEAD` — `HEAD` moves on every commit, so a campaign spanning any commit silently changes the artefact it gates against, which is what "single package for all tests" forbids.

**Common execution & acceptance for every install cell:** push via `qtest push` (qrexec-driven cells) or stick-orchestrated (pristine-start cells — a pristine guest has no qrexec, so the answer stick's firstlogon runs the scripted sequence; grading = external introspection during + durable logs after; §12 note 2). Watch actively: dialog watcher (~10 s sampling + screenshot on detection), CPU metering to distinguish installing from idle-at-a-prompt, **hard cap 20 min per in-guest stage** (the real hang ran 27.9; never wait forever). After any `ok:true` install: **cold reboot**, then qrexec up, `qtest shot` shows a live desktop (pixels, not logs), agent hash == `MANIFEST.json`, disk BUSTYPE=SCSI where PV disk expected, IDD controller present unless `/noidd`.

### P1 cells

Legend: ● covered by the 2026-08-29 campaign, ○ new. Costs exclude amortized stage builds unless noted.

| ID | Cell | Path | Entry → exit | Prereq | Cost | Branch authority (Br) |
|---|---|---|---|---|---|---|
| ● **C1** | fresh-2stage (10; ○ 11) | E1×D0 | R3+ST0 → ST2 (churn qube) | P0-CORE | 35–50 min, ±0 GB | PRECOND#1 `testsigning:false, installed:0` → `stage1-prepare ok` exit 10 → reboot → PRECOND#2 `testsigning:true` → `stage2-install ok`; "clean install path"; **two run_ids**; certs trusted both stages |
| ● **C2** | fresh-1stage (both) | E2×D0 | R3+ST0T → ST2 | P0-CORE | 30–45 min, ±0 GB | single PRECOND `testsigning:true, installed:0`; "clean install path"; `trusted N payload certs [stage 2, before msiexec]` |
| ● **C3** | upgrade-ours (both; + armed-monitor variant) | E2×D1 | ST2G at N−1 (or churn seeded older) → ST5-like transient; R1-restore after | P0-CORE, ST2G | 15–25 min, 0 GB | `upgrade_mode:in-place-msi-major-upgrade`; ONE precond line (no mid-reboot); `inbox_disk_rearm:done`; no `REFUSING` |
| ● **C4** | upgrade-stock (10; 11 pending D3) | E2×D1 (stock data) | ST1.10 → ST2.10 | P0-CORE, ST1.10 (one stock R3 per campaign, parked) | 20 min +20 min amortized R3, ±0 GB | PRECOND `installed: QWT 4.2.2.0, pv_boot_disk:true, monitor{Running,2}`; major-upgrade mode |
| ○ **C5** | upgrade-stock-2stage | **E1×D1** | ST1F.10 → ST2.10 | C4's ST1 + ST1F constructible (D4) | +15 min over C4 | PRECOND#1 `testsigning:false` **and** `installed:1` (the cell's identity); stage-1 early monitor disable; PRECOND#2 → major-upgrade |
| ○ **C6** | same-version (both) | E2×**D2** | ST2G, package N → R1-restore | P0-CORE | 15 min, 0 GB | `in-place-same-version-reinstall`; `REINSTALL=ALL` on the msiexec line; pnputil 259 accepted; **no PV-gate refusal** (2026-08-11 regression guard) |
| ○ **C7** | downgrade-refuse | E2×**D3r** | ST2G (pv_boot_disk true) + PKG(N−1) → unchanged | P0-CORE, PKG(N−1) located (D8) | 10 min, 0 GB | `uninstall-first` then `ok:false`, error `REFUSING to remove the installed QWT`, exit 1; **nothing mutated**: N still registered, clean reboot, agent hash unchanged |
| ○ **C8** | downgrade-run | E2×**D3c/D3b** | ST2NP.10 → N−1 installed (transient) | C7 pair; ST2NP (one extra install on churn) | 30–45 min, 0 GB | `uninstall-first`; on rc 3010: `stage2-uninstall-reboot ok` exit 10, new run_id "resumed after the uninstall reboot - skipping detection", **exactly one** such reboot; final agent hash == N−1 manifest; IDD rebind assertion visible |
| ○ **C9** | pvdisk-refuse | **R2gate** | ST2G → unchanged | P0-CORE | 10 min, 0 GB | `QUBES_FAKE_INSTALLED_PVDISK_VERSION=99.9.9.9` set in-process (SEED rules H3.11) → `ok:false`, `REFUSING: … OLDER Xen PV disk driver`; nothing mutated; **without the var the same run must proceed** |
| ○ **C10** | noidd-carry | E1×D0×I | R3+ST0 (stick-orchestrated: stage1 `/noidd` no `/auto`, manual reboot, stage2 bare) → ST2-noidd | P0-CORE | 40 min, ±0 GB | stage 2 logs `stage-1 switches restored: NoIddDriver`; `idd_driver:'skipped (/noidd)'`; boots on BDA with seamless working |
| ● **C11** | template-prime / class-skip | P | template: piggybacks R4; standalone control: any ST2 | P0-CORE | piggyback / 10 min | template: `pvnic_prime:seeded`, `pvnic_latch:armed` (NICS=1 readback); standalone: `pvnic_prime:skipped-non-template`. **Downstream acceptance (zero-reboot attach, transfer+rx_bytes) is owned by NET-2/NET-3 — cross-referenced, not duplicated** |
| ○ **C12** | stage1-idempotent | E1 re-entry | inside C1's R3 run (stick runs installer twice pre-reboot) → C1 continues | C1 | +5 min inside C1 | second run re-detects stage 1 ("DETECTED, not remembered"), `ok:true`, resume still fires exactly once on the next boot |

**Armed-monitor variants (C3/C4):** PRECOND must show `xenbus_monitor{Running, start:2}` (+ seeded `pending_request` for the seeded form, `SEED_CELL=1`). PASS adds: `SAMPLES_WITH_DIALOG=0`, **no guest-initiated restart** during msiexec (no Event-1074 from `xenbus_monitor*`; PRECOND `pids` vs kill log shows the survivor PROCESS was killed, not just the service disabled — the `81d2b79` brick, 5/5 reproduced, is why this observable exists).

**Dialog-vacuity clause (binding, from the PV protocol):** the premature-reboot dialog is a "Xen PV Network Class" event — it **cannot** appear on `netvm=''`. Any cell asserting "no dialog" runs on a guest with a netvm (StandaloneVM/AppVM, never a template), first-vif-naive where first-vif is the claim; otherwise that assertion is `INVALID-VACUOUS`. The definitive first-vif dialog cell is **NET-6**.

**P1 negative-control ledger** (status per H5.2): G0 ← unsigned-cat fixture (*unproven*; build-side form validated on the real 4×NotSigned). Dialog watcher ← the unsigned artifact hang / seeded-Request-no-suppressor (**validated**). Agent-hash-vs-manifest ← pre-planted same-name binary (**validated** 2026-08-06). Precondition-mismatch invalidation ← "fresh" cell on an ours clone (**validated** — contamination 1). `upgrade_mode` assertion ← wrong package fed (partially validated, 2026-08-11). D3r keys-on-pv_boot_disk ← C7's command on ST2NP must NOT refuse (*unproven until C7/C8*). R2gate ← C9 with/without env (*unproven until C9*). Flag-carry ← delete `qwt-improved-stage1.json` between stages, `idd_driver:'skipped'` must FAIL (*unproven*). Resume-task resilience ← kill guest between uninstall-reboot and resume; delete the task → detectable missing RESULT, never a false pass (*unproven*). Missing-data rule ← policy, enforced per cell.

---

## 6. P2 — Networking (PV NIC path)

Direct encoding of CLAUDE.md's PV-network testing protocol ("follow it or the result is meaningless"). Standing constraints: templates `netvm=''` always (network behaviour tested through their AppVMs); AppVMs/Standalones MUST have `netvm fw-net` for network cells; **fw-net cannot be STARTED from here** (policy refusal, not absence — it exists and serves traffic; binding and dialog-watch need it not, only traffic does); payload still ships via `qtest push`; **90 s grace** before grading; **never ping the gateway** (a Qubes netvm answers no ICMP — corroborating evidence only); **loopback adapters lie** (KM-TEST reports `PhysicalAdapter=true` — identify the PV NIC positively by `PnPDeviceID -like 'XENVIF\*'`, never "first adapter"); drain hygiene per §2.5.

Instruments (validate before trusting): `guest/pvnic-latch-readback.ps1`, `guest/reboot-dialog-watch.ps1` (`-SelfTest` proves it fires; JSONL sampling; `-Summary` grades with coverage gaps and blind samples), `guest/health-check.ps1`, `guest/nic-state.ps1`, `tools/netvm-bootwatch.sh` (works with qrexec dead), `tools/netvm-instrument.ps1`/`netforensics.ps1`, applier logs (`Q:\qwtng-netsetup.log`, `C:\ProgramData\QubesPvNic.log`, failure marker `QubesPvNic-FAILED.txt`).

| ID | Cell | Entry → exit | Prereq | Cost |
|---|---|---|---|---|
| **NET-0** | Preflight: roster/class check; templates netvm='' (a template with a netvm = STOP-and-report); fw-net confirmation for traffic cells; watcher `-SelfTest` (`detector_fires=true` required — a watcher never seen to fire proves nothing); timeout hygiene | any → unchanged | P0-CORE | 10 min |
| **NET-1** | Latch/applier audit: `nics=1, vif_enum_key=true, task_main=true, task_rearm=true, marker=false`; `payload_sha256` matches shipping `pvnic-boot.ps1` (stale payload invalidates all downstream NET results); `pvnic_applier` not `na` on template/AppVM (`na` = deployment FAILURE there; expected state on a bare Standalone — NET-7). Note: the seeded `Enum\XENBUS\VEN_XP0001&DEV_VIF` veto-bypass key is correct on a latched guest and does NOT mean a vif was seen | ST3/ST3A → unchanged | P0-CORE | 10 min |
| **NET-2** | **AppVM immediate live attach, ZERO reboots** (headline; owner 2026-08-29: a second boot is a FAILURE — the latch exists to make it one boot at problem 0). Boot ST3A `netvm=''` → baseline `nic-state` + `LastBootUpTime` → **arm watcher BEFORE the vif exists** → `qvm-prefs <app> netvm fw-net`, no reboot → poll ≤120 s. **Accept (all):** PV NIC bound ≤120 s (ref: 26 s); `LastBootUpTime` unchanged AND watcher JSONL gap-free (two independent zero-reboot proofs); `emulated_nics_still_present: []` (unplug is the bar); applier PASS with real qubesdb IP, default route on PV, `apipa_present: []`, no FAILED marker; watcher `-Summary` `samples>0, dialogs_seen=0, blind_samples=0, coverage_gaps=[]` | ST3A → ST4 | P0-CORE, NET-0, NET-1 | 20 min, 0 GB (R0) |
| **NET-3** | **Traffic by FILE TRANSFER cross-checked against the XENVIF adapter's own rx_bytes** (never ping; DNS/TCP = smoke only). ≥90 s after qrexec: read `Get-NetAdapterStatistics` on the XENVIF adapter (by PnPDeviceID); fetch ≥10 MB in-guest, verify byte count/hash; re-read. **Accept:** `XFER_OK=true` AND `PVNIC_RX_DELTA ≥ bytes` **on the XENVIF adapter** (ref: 16,192,808 B, delta 21,966,263). **Stack-sanity check, NOT a benchmark** — external throughput (0.2–0.7 MB/s, 3× spread) characterises the upstream; LinkSpeed 100 Gbps is meaningless. Throughput lives in NET-8 | ST4 → ST4 | NET-2, fw-net up (owner) | 10 min |
| **NET-4** | Per-boot reinstall soak: 3 serial AppVM reboots with netvm attached; each boot after grace: `pv_drivers_bound` PASS, applier converged (`SUCCESS` in log, no marker), exactly one boot per command (`LastBootUpTime` monotonic, one step each), NET-3 smoke. **Accept: 3/3.** Any self-halt, APIPA, or second boot = FAIL of the latch/applier chain, not noise | ST4 → ST4 | NET-2 | 30–45 min |
| **NET-5** | Live netvm change/reconciler: detach `netvm ''` → quiet handling (vif gone, no failure marker, ghost devnode ignored) → reattach → reconverge ≤120 s, zero reboots, reconciler evidence in `Q:\qwtng-netsetup.log` → NET-3 smoke | ST4 → ST4 | NET-2 | 15 min |
| **NET-6** | **First-vif premature-reboot dialog** (eligibility-gated). Subject: **persistent-root guest that has NEVER had a vif** — i.e. the churn qube straight off the C1 chain, kept `netvm=''` since install (this sequencing avoids a dedicated reprovision — requirement 7; an AppVM cannot be the subject, nor any recycled guest). Probe eligibility first: XENBUS enum shows `DEV_CONS|DEV_IFACE|DEV_VBD`, **no** `DEV_VIF`; XENVIF enum empty incl. ghosts (`-PresentOnly`). Steps: `-SelfTest` → sampling watcher with ≥20 pre-attach samples (**armed before the vif, or the negative is meaningless**) → attach → `-Summary`. **Accept:** `samples>0, dialogs_seen=0, blind_samples=0 (session-0 self-reports blind ⇒ void), coverage_gaps=[]`. Ref: ours 0/69 clean; STOCK first-logon DOES raise it (csrss/#32770/"Xen") and a dialog predating our installer's first log line is attributed to stock | C1-exit (ST2 on churn, never-vif) → ST2+vif | C1, fw-net for vif plumbing | 30 min |
| **NET-7** | **Standalone immediate live attach, ZERO reboots — VERIFIED PASSING 2026-08-29.** Carries NET-2's criteria verbatim on a StandaloneVM. Measured on `win10-u10` with the applier confirmed present first: PV NIC bound in **25 s**, `LastBootUpTime` byte-identical (zero reboots), 49 watcher samples with **0 dialogs**, emulated NIC unplugged, health-check `ok=True`, 1.25 GB rx. **Precondition that makes or breaks this cell:** assert `TASK QubesPvNic` + `APPLIER_SCRIPT` present BEFORE attaching — every earlier "hotplug is broken" result was a guest with no applier (pre-`cace671` package, or a template cloned from one), and that mistake cost three runs. The pre-fix PnP problem 14 state is this cell's seen-to-fail negative control. | ST2 standalone (latched) → ST4 | P0-CORE, NET-0, NET-1 | 20 min, 0 GB |
| **NET-8** | **PV throughput benchmark against a fast CDN.** SUPERSEDED 2026-08-29 (owner: "local-only benchmark is not needed in this case. you may benchmark against reasonably fast cdn") — no local endpoint required. Measured reference: `speed.cloudflare.com/__down?bytes=26214400` → **258.2 Mbit/s** (26,214,400 B in 0.81 s, adapter rx delta 29,054,236) versus 3–5 Mbit/s from a Debian mirror, which is why a mirror must never be used for this. Note a 100 MB request returns 403 (Cloudflare caps `__down`), so 25 MB is the working size. **Accept:** ≥3 runs, median well above mirror-class rates, every run cross-checked against the XENVIF adapter's own rx delta. A local endpoint remains blocked by the netvm inter-VM drop (tested: guest firewall was already accept-all, an explicit accept rule changed nothing, zero requests reached the listener) — but it is no longer needed. | ST4 → ST4 | NET-2, fw-net up | 20 min |

**Vacuity ledger** (each produced a false verdict at least once — graders must check against it): "no dialog" on `netvm=''`; "no dialog" with watcher armed after attach; any network grade <90 s; "physical NIC attached" (loopback); "no traffic" from gateway ping; "first-vif OK after two boots"; byte deltas on an unspecified adapter; throughput from an internet download; "guest unkillable/restarts forever" (= queued qrexec, drain per §2.5).

---

## 7. P3 — Updates (dom0-owned Windows Update path)

Sources of truth: `guest/qubes-windows-update.ps1`, `guest/wu-update.ps1`, `guest/install-updater-agent.ps1`, `dom0/14-install-qvm-windows-update.sh`, guest-introspection skill. Standing rules: roster names only; **serial** — never concurrent with a benchmark/rendering part, and before any BENCH part check `QubesWindowsUpdateScan`'s next run (6-hourly + boot+2 min) — a mid-benchmark scan raises the proxy and churns qrexec (wedge trigger); **detach long work** (`schtasks /run` via `qtest run`, never a live 2 h pushrun — it dies with the connection); **judge output not logs** — the only proof an update landed is `CurrentBuild.UBR` moving + KB in CBS packages (state=112) after a boot; `rc=3010` = STAGED; `phase=done` = ended, read `result[]`; **reboot semantics** — guest-initiated reboot destroys the domain (`on_reboot=destroy`): Halted within ~3 min of `done` is normal, `qvm-start` it yourself; drain hygiene per §2.5.

**Where U3 runs** (§12 note 8): primary — directly on the standing template with **R1 as rollback**, the pass fitting the two-shutdown window exactly (contingent on D5; the pre-update revision is the rollback point). Fallback if R1 is denied or the pass overruns the window: R2-materialize the lineage on the churn name **created TemplateVM-class** (classification reads qubesdb `/type`, so class must be genuine); retain at most one update-stage image per lineage (2 fleet-wide, ≤~40 GB settled), delete once ST5 is stamped. Never service a golden until the pass is accepted.

| ID | Cell | Entry → exit | Prereq | Cost |
|---|---|---|---|---|
| **U0** | Deploy-state assertions (read-only): artifacts present + agent script SHA256 vs repo (**verify installed content, never installer output** — the `$PSScriptRoot` silent death); tasks shaped right (`Scan` boot PT2M + 6-hourly SYSTEM PT20M `-Scheduled`; `Run`/`Download` no triggers PT2H no `-Scheduled`; `QubesAutologonGuard` boot PT30S); policy `NoAutoUpdate=1`, `ExcludeWUDriversInQualityUpdate=1` on latch templates (guards NET's latch against WU-delivered Xen packages); offline baseline: winhttp direct, no relay process (proxy is temporal + positional, both gates stay) | any rig → unchanged | P0-CORE | 2 min/rig |
| **U1** | Availability to dom0. **Precondition: own both ends** — one control fetch through the `qubes.UpdatesProxy` backend (small CTL cab) proves backend egress, else every guest verdict is vacuous. Scan: phases `ensure-proxy→sync-revocation→scan→done`; `Sync-Revocation 3/3 CTLs` + fresh cabs + `RootDirURL=file://C:\ProgramData\QubesCTL`; `available[]` populated; **`qvm-features <vm> updates-available` reflects it from the mgmt qube** (the dom0-observable output — a log line alone does not count); proxy torn down after. **Stability (binding):** 3 scans on the unchanged image, stable count, before any later stage quotes it; first status write ≤3 min of kick. **Honest-empty guard, seen to fail:** `QUBES_UPDATES_FAKE_EMPTY_SCAN=1` → exit 75 `phase=scan-failed`, NOT "0 to dom0" (the 2026-08-15 lie made fail-able). **Debounce:** re-fire scheduled scan → skips; `DEBOUNCE_MIN=0` → runs; dom0-requested Run never skipped. Win10: `esu`/`notice` present; `remaining` counts only actionable self-contained rows | ST3 (template, netvm='') → unchanged | P0-CORE, U0, proxy backend up (owner) | 30–45 min |
| **U2** | VM-class matrix (security half; witness = what changed, not what was logged): template → proxy pass runs (U1); AppVM → `skipped-appvm` exit 0, `proxy_unchanged=true, no_relay_started=true`, exits before Ensure-Proxy; standalone+netvm → `skipped-standalone`, `NoAutoUpdate` REMOVED, no relay; standalone−netvm → nothing; qubesdb unreadable → `skipped-unknown`, refuses to proxy, flagged. **Boot-path clause (binding):** classification proven on a COLD BOOT (`wu-boot-acceptance-arm/-check`) — the QdbDaemon startup race is exactly what a live re-run clears | ST3/ST3A/ST2 → unchanged | U0 | 30 min |
| **U3** | dom0-driven install end-to-end (the long stage). Baseline: UBR, no RebootPending, pool GB, autologon armed (unarmed + staged reboot = sign-in lockout). Kick `Run`; poll 60 s. Download: `pct/mb` advances between polls (ref rates 12.8 MB/s Win11 / 1.5–2.4 MB/s Win10 write path; stalls resume across ≤14 attempts; two flat polls → read relay log for `PLAIN REFUSED` before any verdict). Install: `rc∈{0,3010,2359302}`; `skipped/not-applicable` rows correct (superseded siblings never fed to CBS — the KB5043080 poisoning class); Win10 `rc=50 → expand to cabs` normal; **exactly ONE reboot-requiring package per session**, rest `deferred` (CBS discards a second staged session — measured twice); `reboot_pending_confirmed=true` + TiWorker settle before reboot. Progress protocol: shim stderr = bare invariant floats 0..100 monotonic, messages never ending in a number, `staged (completes at restart):` for 3010, exits 0/100/1 (GUI render = owner checkpoint). Reboot: `shutdown /r /t 60` → Halted → `qvm-start`; **shutdown timing is diagnostic**: 6.3 min = real apply, **77 s-class = staged package DISCARDED** → run `wu-boot-servicing.ps1`, don't proceed on vibes. **Post-boot verdict (the only one that counts):** UBR moved, KB state=112, RebootPending gone, DISM clean, **autologon survived** (qrexec answers interactively; shot shows a desktop, not sign-in), NoAutoUpdate=1, offline baseline restored; boot scan re-reports `remaining` ≤15 min, graded only after its `done_ts` postdates the boot. **Bounds:** ≈45 min measured full Win11 CU; outer bound 2 h 15 min, then collect evidence (U5) and declare FAIL — never "probably finishing" | ST3 (or lineage clone) → ST5 | P0-CORE, U0, U1, C-chain accepted on the lineage | 1–2.5 h; settled delta ~20 GB Win11 / ~10 GB Win10 (provisional — measure on first execution, D-open) |
| **U4** | Failure-mode drills (defect-reintroduced proofs; template rig; restore after each): (1) 0x80072F8F — delete CTL cabs, empty `RootDirURL`, resync chain cache → failure class fires; Sync-Revocation repairs through relay → scan succeeds (CDP CRLs proven irrelevant — do not re-derive). (2) Relay dead/8082 squatted mid-pass → probe kills/respawns or fails loudly — never 0x80072EFD blamed on "the network". (3) `FAKE_STAGED` + `FAKE_FALLBACK_KB` → defer paths fire visibly; `ALLOW_MULTISTAGE=1` only on a disposable image with `wu-boot-servicing` as judge. (4) Scan-vs-Run mutex → scan yields; shim's `action='scan'` filter never adopts a scan's `done`. (5) Exit contract: forced `phase=error` → exit 1; routeless `wuinstall` refused by the route gate (zero DO/BITS phantoms in a netvm-free pass). (6) ESU honesty (Win10 until MAK, D-open): ESU-gated CU = `severity=info`, excluded from `remaining`, no fail-loop | ST3 clone → restored | U1, U3 once green | 1–2 h |
| **U5** | Introspection discipline (embedded in U3/U4, and standing for any long servicing): never describe the guest without a ≤1-min-old measurement (`wu-what-is-it-doing.ps1`, `wu-busy-probe.ps1`, two samples 3–5 min apart). STUCK only when CBS.log mtime, worker CPU (~0.4 CPU-s/s during real apply), and status `ts` are ALL flat across 10 min with the task Running (largest legit idle gap: 468 s); collect before any kill and state what the kill destroyed. qrexec dropping mid-servicing = I/O starvation, not death — wait bounded 15 min re-probing first. A missing process is not a finished job | — | — | embedded |
| **U6** | Netvm truth table + budget: template pass/drills/NotifyUpdates/progress need **NO guest netvm** (proxy backend needs egress — U1 precondition); AppVM leg needs none; standalone self-update leg needs netvm (DO/BITS refuse routeless — proven gate) with egress proven per NET-3, never ping, never <90 s; WU-driver-exclusion check on a standalone protects the latch. Watermarks per §2.6. **Sequencing:** updates run AFTER install/upgrade acceptance on a lineage, BEFORE re-baselining benchmarks — a serviced image is a different benchmark subject; baselines are re-taken on ST5, never compared across the servicing boundary | policy | — | — |

---

## 8. P4 — Complex rendering and benchmarking

Every rendering verdict is judged from **pixels or the wire (QGAPROTO)** — never agent logs or guest state (the `RecreateDuplication` precedent; a fully green suite once shipped four defects the owner saw on sight). Each check names instrument, judge, and negative control; unproven controls demote to `PASS-UNPROVEN`.

### RND-0 — instruments, envelopes, capture-class rule

*Entry: any ST2/ST2G/ST3A with the build under test. Prereq: P0-CORE.*

Instrument blindness table (do not conclude from silence): `qtest shot` sees managed windows only — blind to override-redirect surfaces, decorations, agent-less guests; empty tar ⇒ triage per H3.2 first. `fullshot`+`winshot.py` sees everything incl. o-r and no-agent guests. `winshot --classify` = wait-loop terminator, not a correctness judge. `render-truth.ps1`+`rendercheck` = guest-vs-dom0 per-window diff with MISSING/EXTRA/GHOST — guest truth is a **composited** crop: compare unoccluded windows only; high `pct_differing` means "open the PNGs", not auto-FAIL (53% on a correct build measured). QGAPROTO+`check-protocol.py` = what the agent told the daemon — restart the agent before a trace run so every window has a traced CREATE; missing data fails. QGAPERF+`bench-agent.sh`/`bench-phases.sh`/`analyze-perf.py` = per-frame phase costs. `pixel-equality.ps1` = DDA-vs-PrintWindow (client-area spread = DO NOT SHIP). `check-chrome.py` = title/menu band presence (caught the 64px maximized-crop defect all numeric checks passed). Tracing on via `qvm-features <vm> service.gui-agent-debug 1` (agent ≥ ab36aef) — never registry pokes.

**Capture-class rule (binding):** per-window capture is the accepted class. Whole-desktop (`fullshot`; `qtest-geom` triggers one) only for (a) o-r surfaces and (b) suspected dom0 compositing defects; processed locally, cropped immediately, **never committed** — not even inside a tar (a name rule cannot see inside an archive). `tools/pre-commit-no-desktop-captures.sh` + the enabled `.githooks/pre-commit` (P0-PRE) screen commits. Privacy ruling on owner-attended windows for fullshot cells = decision D10.

### RND-1 … RND-9 — the battery

*Run per OS at minimum on: the fresh-install exit (ST2 on churn) and one upgrade exit (ST2G), seamless mode; RND-8 additionally in the fullscreen/IDD configuration. After any battery: **RND-cold** — one reboot, then RND-3/4/5 again (a live agent restart clears exactly the faults cold boot exposes). Settle rule: ≥20 s after scene setup before first capture; expected window counts derive from the scene's own window list — never hardcoded. Cost: ~1.5–2.5 h per OS per configuration, 0 GB.*

- **RND-1 drag** (replay/wobble/debris). Driver: scripted circle drag (`drag-harness.ps1` / `drag-measure.ps1`). Judges: *replay* — stationary ≤~1 s after release (`pos-sampler.ps1`; regression guard for the 2026-08-12 2 s playback, fixed in 336ccc7); *wobble* — from QGAPROTO `ax/ay` vs `lx/ly` at damage time, **never** cross-VM capture (capture skew invented "tearing"); shipped bar stale-origin ≤~4%, dx p95=0 px; *debris* — one mid-drag fullshot over overlapping windows (legitimate whole-desktop use), no fragments in the lower window. Trap: **never judge against a window whose content is not verified rendering** (a wedged white Notepad faked two regressions); if a window goes empty, capture guest truth before killing anything. Drag *quality* is owner-PARKED — read `docs/PLAN-drag-quality.md` before touching drag code; this cell only guards shipped behavior.
- **RND-2 scroll.** Bench scroll phase (400-line file, ±3 notches @20 Hz); judge: QGAPERF scroll p50 vs the canonical baseline + `damage-within-window` invariant.
- **RND-3 menus / override-redirect.** `menu-static-test.ps1`; judges: `popup-override-redirect` (else dom0 decorates menus — red-rectangle defect), `menu-announced` (*unproven — documented, not counted*), `no-damage-to-occluded-window` (proven). Pixel confirmation requires fullshot — `qtest shot` cannot photograph a menu (`_NET_CLIENT_LIST` excludes o-r; blindness was failure mode #1 of the broken protocol). VM-color border on menus is stock daemon behavior, never a defect; daemon-side bordering is never weakened.
- **RND-4 toasts.** `fire-toast.ps1` (persistent reminder toast). Judges: appears in dom0 (the standing guard that the chrome filter hasn't killed notifications — CLAUDE.md 2A-3c); positioned bottom-right; after dismissal `rendercheck` reports **no ghost** (`ghosts_in_dom0` exists because a mapped-forever toast was a real bug). Fail-proof lives in SG7.
- **RND-5 Start.** `open-start.ps1` (scheduled-task Win-key; direct keybd_event doesn't open Start on 25H2). Judges per the shipped spec — see SG9 for the seamless-spec cell; in the dev SeamlessStart=1 arm: mapped, cropped card, movable, no focus steal (`rendercheck` MISSING catches invisible-Start). 25H2 behavior is the accepted baseline — **fix 24H2 to match it, never the reverse** (owner). 24H2 uncropped at 5120-wide = known issue (register D9), not regression.
- **RND-6 occlusion.** `occlusion-test.ps1` + `check-occlusion.py`, **both directions**: no damage past the cover while covered (under-clip⇒corruption) AND damage past it once hidden (over-clip⇒blank) — both negative-control proven (`0eabb2b8a0fc`, `5598a2fbda93`). Z-order disagreement (`OVERLAP-IN-MOTION.md`) is a known open defect class (needs daemon z-order, Phase 3): grade reproductions as known-issue unless measurably worse than the recorded captures.
- **RND-7 compound chrome.** `tools/chromerepro`; judge via `qtest shot` count: exactly 1 bordered window (+1 o-r popup when open), not 5; `winenum` for attribute inventory when extending the predicate. Real Office only in the owner's Office qube, ask first. Fail-proof in SG8.
- **RND-8 resolution changes** (fullscreen/IDD config). Drivers: `qtest resize <WxH>` (needs dom0 resize service — P0-PRE.5) + `set-resolution.ps1` + the promoted snap-regress battery (near-half snaps + odd exacts, e.g. 2530x1359). Judges: arbitrary modes followed; `resize_ttfp_ms`/`resize_converged`; decisive, **from pixels**: after each resize a visible guest change changes dom0 pixels (the 0x887a0026 keyed-mutex abandonment historically killed capture exactly here). Binding: **never resize-to-viewport** — dom0 window is the source of truth.
- **RND-9 safeguard-rendering interactions** (each guard has regressed rendering once): (a) cold boot + autologon ⇒ ≥1 window maps (the invisible-guest regression); (b) LogonUI/boot fullscreen never reaches dom0 — checked passively during RND-cold; **never set `service.gui-fullscreen` to provoke it** (banned); (c) toasts still render (RND-4). Fail-proofs live in SG1/SG6/SG7.

**Pixel-judging rules (all cells):** geometry ground truth = DWM extended frame bounds, never `GetWindowRect` (7 px grips once flagged correct behavior); the 24 px center-crop matcher tolerance exists for this — don't tighten blindly. A comparison tool must not auto-align when misalignment IS the defect (wobble judged from QGAPROTO, never image alignment). Captures are seconds apart: compare quiet scenes. Missing data fails (`trace-present`, `origin-known-for-damaged-windows` — the latter *unproven*). New checks enter only after a seen-to-fail run. New P/Invoke string probes use `CharSet.Unicode` (Ansi truncated every title to one char for a session).

### BENCH — benchmarks

*Entry: the stage being baselined (ST2/ST2G/ST5), quiet host, no WU scan due (P3 rule). Prereq: P0-CORE, agent hash verified. Cost: ~45–60 min per baseline set, 0 GB.*

- **BENCH-0 — mint canonical baselines on the pristine-lineage rigs** (the protocol's first benchmarking act; §12 note 9). `tools/bench-agent.sh <label>` fixed workload (idle 5 s → drag 10 s → idle → scroll 10 s → idle → type 10 s → idle-post; SendInput proven to reach the input desktop; cadence+jitter reported so a loaded guest is visible). ≥3 runs (≥5 for drag) on ONE unchanged binary; record in FINDINGS with **raw files committed to `instrumentation/`** (standing rule — the b299011 raws were never committed). b299011 (613 µs drag etc.) is retired to a historical footnote; the 4.3.10 quiet-host set (`bench-4310-q1..q4`, scroll 374–436 µs) is the current-rig reference until BENCH-0 supersedes it.
- **BENCH-1 — comparison runs.** Against recorded canonical baselines only, never an intra-day build (owner rule; violating it burned ~1M tokens). ≥3 runs per side, **interleaved** with the control. **Scroll is the metric that can carry a verdict; drag p50 is bimodal (scene-state — the trap that voided a bisect) and gates nothing until its variance is re-established** (decision D-open). Guest-side cost counts even when dom0 corrections hide it. Host state recorded with every run.
- **BENCH-2 — always-on tripwires** (run with every benchmark): agent + IDD UMDF idle CPU (`cpu-bench.ps1`/`phase-cpu-bench.ps1`; baselines: workarea churn 0 applies / ~0.08 s CPU per 120 s idle — pre-fix control 1460 applies / 3.95 s; WUDFHost 0.000%); `idle-repaint-box.ps1` for ambient repaint dom0 never displays but capture pays for. Negative controls: the recorded pre-fix numbers are the seen-to-fail states.

---

## 9. P5 — Safeguards (SG suite)

Every safeguard is a filter with two failure directions — stops firing (the blocked thing returns: the 2026-08-28 class-only Mode-1 leak) or over-fires (eats UI it must keep: the 2026-08-07 title-bar clamp that passed every numeric check). Both directions are graded per safeguard; **no check counts until seen to FAIL against a deliberately reintroduced defect**; unproven cells carry `PASS-UNPROVEN` in the matrix.

### SG0 — ground rules (violating any voids the run)

1. **NEVER set `service.gui-fullscreen`, never signal the mode events** — owner: "never means never" (three screen-cover incidents). Every arm requiring the feature ON (feature-ON Mode 2, non-seamless sign-in view, end-to-end Progman) is **owner-attended only**, listed `ATTENDED-PENDING` in the matrix, never silently dropped; the unattended portion still covers every safeguard's default state.
2. **Screen-cover containment:** all per-window fullscreen-gate cells (SG1–SG4) run at a **sub-host guest resolution** (e.g. 1600x900 via the /idd path, `set-resolution.ps1`) — the gates compare against the *guest* screen, so even a broken gate maps a bounded 1600x900 bordered window. Exception: boot-phase defect arms run at boot size ⇒ attended. (Contingent on the rig carrying the IDD build — else those arms fall back to attended.)
3. **Judge at the dom0 boundary:** shot tar pixels + QGAPROTO trace. Agent deny-lines are discriminators and vacuity guards only, never the pass criterion.
4. **Vacuity guards mandatory:** "nothing appeared in dom0" passes only when the same run proves the stimulus existed guest-side (`winenum`, `toast-probe-uia.ps1`, or the deny line). Absent stimulus = run FAILS.
5. **Per run:** `set-loglevel.ps1 5` (sets global AND module keys — a stale module key swallows Debug), `verify-running-agent.ps1` (running-process hash), restore level after; empty-tar triage per H3.2.
6. **Pixel-differ validated in-session** (known change + known no-change, ×3) before any frozen/changed assertion.
7. **Cold boot, never just agent restart**, for autologon and Mode-1 cells.
8. **Rig discipline:** mutation+reboot arms (diag bits, SeamlessStart, autologon disarm, `PromptOnSecureDesktop` revert) on **StandaloneVM restores** (an AppVM's volatile root reverts HKLM before the reboot that would exercise it); positive boot-path checks on AppVMs (free reset). Never a template. Serial; drain per §2.5.
9. **Defect mechanics:** `DiagWindowFilterOff` bits (bit 0 shell-identity, bit 1 shell-furniture) are canonical; everything else uses a throwaway `defect/*` diag build deployed to a Standalone restore, torn down same session, never merged (extension of the DWORD to more bits = decision D-open, owner sign-off since each bit weakens filtering). Fail-proofs run **once per instrument version**, not per release.

### SG cells

*Entry for all: ST2G (or ST2) with build verified; SG1/SG6 need cold-boot capability; diag arms need a Standalone restore. Prereq: P0-CORE, SG0. Cost: unattended suite ~2–3 h per OS, 0 GB; diag-build fail-proof sessions separate (~2–4 h once per instrument version).*

- **SG1 — Mode 1: boot/shutdown/logon screen never shown.** Positive: cold boot + full shutdown watched by a ~1 s shot loop AND a protocol trace armed from agent start (`set-prototrace.ps1` pre-reboot — the trace catches sub-second flashes the loop can miss; pixel-level sub-second proof would need privacy-sensitive dom0 capture — D10). PASS: no MAP/CREATE of a ≥99%-guest-screen window during no-shell/secure phases, nothing fullscreen in any shot. Vacuity: the `unconditionally denied` line must appear (LogonUI is created every boot; no deny + no flash = void run). Negative control (not over-firing): Notepad maps normally within 60 s of settle; maximized Notepad maps (SG3); relock re-fires the deny. **Fail-proof (attended):** diag build with the phase test removed (the literal 2026-08-28 defect) + a captioned fullscreen window created pre-explorer → maps → checker red.
- **SG2 — Mode 2: borderless fullscreen gated (feature OFF).** Static: captionless popup at guest-screen size → never in shot/trace; discriminator `hidden (set service.gui-fullscreen to allow)`; vacuity via winenum. Dynamic: strip `WS_CAPTION` + resize on a mapped window → dom0 window disappears (unmap in trace) — no map-then-linger. Feature-ON arm: attended. **Fail-proof:** diag build dropping the caption clause → popup maps as a bounded 1600x900 window → red.
- **SG3 — windowed fullscreen always allowed.** Maximized Notepad at guest-screen size: present in shot AND `check-chrome.py` passes (this instrument already caught a shipped defect); repeat with a self-painted-caption app (Edge/Explorer). **Fail-proof (safe, deny-direction):** diag build extending the gate to captioned windows → maximized Notepad vanishes → red.
- **SG4 — override-redirect fullscreen never mapped** (even with the feature on — that half attended). Guest-screen-sized o-r popup → never in shot/trace, Mode-1 deny line fires; vacuity via winenum. **Fail-proof:** diag build → maps → red.
- **SG5 — secure desktop per mode.** Seamless freeze: animating window, validated differ baseline, `LockWorkstation` via scheduled task → shot pairs pixel-identical over ≥10 s; **no new standalone window** (no consent box, no dimming backdrop — the field black window); `QGADESKSTUCK` at ~30 s (its **absence is itself a regression** — it is the transient-vs-persistent announcement). Recovery via reboot+autologon: windows return, `secure desktop left after N s` + resync, Mode 1 keeps denying for `FS_BOOT_SETTLE_MS`. UAC positive: `elev-probe.ps1` → prompt appears as an ordinary bordered window, pixels keep flowing (`PromptOnSecureDesktop=0` is load-bearing). **Fail-proof A:** revert `PromptOnSecureDesktop=1` on a Standalone restore → elevation engages the freeze → proves both the freeze fires on real secure-desktop entry and our setting keeps UAC usable. **Fail-proof B:** diag build skipping the early-return → frames flow during lock → freeze checker red. Non-seamless arm: attended.
- **SG6 — autologon armed.** Positive (every release, cold boot): qrexec answers; ≤~60 s `secure desktop left`, windows map; `wu-autologon-selftest.ps1`/`pwdiag.ps1` healthy: **`AutoLogonCount` ABSENT** (presence = password being consumed toward lockout), re-assert task registered. **Fail-proof (the canonical measured 2026-08-28 defect):** on a Standalone restore, disarm BOTH `AutoAdminLogon=0` AND the re-assert task, cold boot → expected red: **0 windows mapped while qrexec answers**, QGADESKSTUCK in ~30–150 s. An autologon checker that does not go red here is not a checker. Re-arm over qrexec, reboot, confirm return. Never on a template or the only copy of a rig.
- **SG7 — toasts survive the filter.** Positive = RND-4 (vacuity first via `toast-probe-uia.ps1`). **Fail-proof:** diag build applying the naive cloak/layered/topmost filter CLAUDE.md 2A-3c warns about → toast vanishes from shot while UIA shows it → red. Before writing that build: **measure with winenum which style arm actually spares the toast** (toastcrop.h suggests CoreWindow TOPMOST|NOREDIRECTIONBITMAP; the assumed `!WS_EX_TOPMOST` clause must be measured, not assumed). dom0 click-through = owner-hand residual.
- **SG8 — compound chrome dropped, real UI kept.** Positive = RND-7 + the NetUI rule exercised on Explorer ribbon dropdowns (no transient bordered shadow flashes in a shot loop). Negative controls (must NOT be eaten): comctl32 tooltip maps; unowned layered splash/HUD maps; `#32768` menu maps as o-r — graded via check-protocol against a winenum snapshot. **Fail-proof:** diag build disabling rule 2 → chromerepro shows 5 bordered windows → red; during this run watch gui-daemon liveness — the admitted strips historically triggered the CONFIGURE-without-CREATE daemon exit, and daemon death during the defect run is a legitimate red, not a rig glitch.
- **SG9 — Start/menus per the SHIPPED spec** (Start is NOT presented in seamless; `SeamlessStart=0`, Super blocked — acceptance is the *opposite* of "Start maps"). Positive: `open-start.ps1` → no new window, no phantom (historical: 1201x919 wallpaper window; x=6063 offscreen); discriminator `Start surface not presented in seamless mode`; cardless gate: shell hosts with closed menus never MAPped in the trace. Dev arm (restore-only, not release acceptance): `SeamlessStart=1` → cropped card per the 25H2 baseline. Menus: app + context menus map as o-r popups. **Fail-proof:** diag build skipping the cardless gate → wallpaper phantom maps → red (trace: shell-host HWND mapped while guest truth says closed).
- **SG10 — shell identity / furniture (field Progman case).** Unattended defense-in-depth: boot a restore with `DiagWindowFilterOff=1` → Progman still rejected by the attribute rule (discriminator `uncapturable non-topmost toolwindow ... shell furniture`) — proves the second layer is load-bearing (the OpenShell field condition). Both-bits arm (`=3`): on our rigs Progman is still stopped by the Mode-2 gate; full end-to-end field reproduction needs the banned feature ⇒ attended; unattended evidence = discriminator chain + no MAP in trace.
- **SG11 — results matrix and evidence.** Each run emits `evidence/safeguards-<rig>-<date>/`: build sha, rig/mode/feature states, shot tars, trace, winenum snapshots, final `ACCEPT=PASS|FAIL reason=...`. Matrix = safeguard × {positive, negative-control, fail-proof}; each fail-proof cell carries the diag-build sha + date last seen red; a blank fail-proof cell renders that safeguard's PASS **UNPROVEN** in every citing report; attended arms listed `ATTENDED-PENDING`.

---

## 10. Campaign profiles and total costs

| Profile | Parts | When | Wall clock (serial) | Pool |
|---|---|---|---|---|
| **TIER-A** — every artifact | G0 + C2 on one OS (alternate) + C3 on the other + BENCH-2 tripwires | each CI package | ~1.5–2 h | 0 GB |
| **TIER-B** — every release cut | TIER-A both OSes + C1 (with C12 inside, then NET-6 on its exit), C4, C6, armed-monitor C3/C4, C11, NET-0/1/2/3/4, U0/U1/U2, RND battery (fresh + upgrade exits, both OSes) + RND-cold, SG unattended positives + SG6, BENCH-1 vs canonical | release | ~1.5–2.5 working days | transient only; R3 count: 2 (Win10 fresh chain, Win11 fresh chain) + 1 (Win10 stock, when C4 runs true-stock) |
| **TIER-C** — installer-logic or safeguard/instrument change | full matrix incl. C5, C7–C10, NET-5/6/7, U3+U4 per lineage, full SG suite incl. all owed fail-proof runs and every `PASS-UNPROVEN` registry row | logic changes | +1–2 days | + one ST5 delta (~10–20 GB) per serviced lineage, reverted or promoted |
| **Owner-attended session** | SG feature-ON arms, non-seamless view, Progman end-to-end, real-Office chrome, dom0 GUI progress click, NET-8 | scheduled with owner | ~2 h | 0 GB |

Reprovision discipline for a full pass: at most **three** R3 runs (Win10 fresh, Win10 stock, Win11 fresh) — everything else restores from parked state per §2.3 (the earlier "two per pass" figure omitted the stock chain; corrected here). No cell may substitute an R3 where R0/R1/R2 reaches its entry stage.

---

## 11. Owner dependencies and pending decisions

**Owner dependencies (cannot be executed or verified from this qube):**
- `fw-net` up (all traffic cells: NET-3/4/5/8, U6 standalone leg) — confirm per campaign, recorded; traffic FAILs are unattributable without it.
- NET-8 local throughput endpoint (file served from fw-net or a neighbour qube).
- dom0 resize service installed (RND-8); dom0-side wedge forensics (U5 terminal case).
- Qubes Update GUI progress click (U3 §5); real-Office validation (SG8/RND-7); all `ATTENDED-PENDING` SG arms.
- Any dom0/sudo/policy change; removing any golden or template (prune ladder step 4).

**Decisions pending (register; defaults noted where the protocol needs one to run):**
- ~~**D1** StandaloneVM latch~~ — **DECIDED 2026-08-29: the latch is ALWAYS ON, StandaloneVMs included.** Owner: "latch is always on (already told you about that), standaloneVM included". Implemented in `Install-QwtImproved.ps1` (`cace671`): the templates-only gate is gone, the class is read for the log line only. NET-7 is now a full acceptance cell carrying NET-2's criteria. **Not yet validated on a built package** — the first package containing it is the one under test as of this writing.
- **D2** Post-provisioning cleanup audit (`qemu-extra-args` / stick assignment) — confirmed step or script addition.
- ~~**D-local-endpoint** PV throughput needs a local file server~~ — **SUPERSEDED 2026-08-29: benchmark against a fast CDN instead.** Owner: "you may benchmark against reasonably fast cdn". NET-8 rewritten; no owner setup required.
- **D3** Win11 true-stock stage: required for parity or out of scope? (C4.11 is N/A-by-design, not skipped, until then; Win11 R3 wall clock unmeasured — time once.)
- **D4** ST1F constructibility (stock 4.2.2 drivers with testsigning off) — if not, C5 is unreachable without a field image: flag, don't drop.
- **D5** R1 (`qvm-volume revert`) and `revisions_to_keep` permission from this qube — unverified; if denied, R1 rows collapse into R3 and U3's primary rollback design falls to its fallback.
- **D6** G0 tooling: openssl-asn1parse form vs installing osslsigncode.
- **D7** G0 negative-control fixture source (pre-2026-08-29 archived package / evidence tree; else cut once from a deliberately un-resigned rebuild).
- **D8** Canonical PKG(N−1) artifact for C7/C8 (+ surviving MANIFEST.json).
- **D9** Known-issue register location (FINDINGS section vs dedicated file) — so "known" cannot silently absorb new regressions (24H2 Start, z-order class live there).
- **D10** Privacy ruling on whole-desktop fullshot cells (owner-away window vs crop-and-delete handling) and on any high-rate dom0 capture for sub-second flash proof.
- **D11** Quarantine release: campaign halts that OS lane until owner releases, or autonomous release once terminal state is fully captured?
- **D12** Golden refresh policy: in-place per accepted release (current practice) vs re-derived from stock lineage per release.
- **D13** `DiagWindowFilterOff` bit extension for the remaining SG fail-proofs (each bit weakens filtering — sign-off required).
- **D14** ESU MAK for Win10 19045 (until then Win10 CU acceptance capped at the honest ceiling); Win11 sibling-checkpoint-drop bug needs a pre-checkpoint 26100 image that doesn't exist on the rig.
- **D15** Commit `verdicts.tsv` + fail-proof registry into `evidence/` per campaign, or keep only under `~/qwt-accept/` (the 2026-08-29 near-loss argues for committing at least the ledger — default here: registry committed, per-campaign tsv copied into `evidence/` on release acceptance).
- **D16** Owner-attended arms: part of release acceptance or a separate scheduled session? (Carried `ATTENDED-PENDING` either way.)
- **D17** Drag-harness variance fix in scope for adoption, or scroll-only perf gating with drag record-only (default taken: record-only)? The designed-but-never-run dmg-hash A/B: named cell or separate Track A work?
- **D18** winshot classifier real-capture fixtures (RECOVERY/BLACK/DESKTOP) as a campaign Part 0, so TERMINAL verdicts stop being degraded-confidence.
- **D19** First execution must measure and record: actual settled ST5 pool deltas (replacing the 10/20 GB envelopes) and the Win11 R3 wall clock.

---

## 12. Resolution notes (where drafts disagreed, what was taken and why)

1. **Stage names unified** as `ST*` (§2.1); the install matrix's `PRISTINE-*/STOCK-*/OURS-*` aliases are retired, mapped by the property definitions.
2. **ST0 IS parked and cloned** (corrected 2026-08-29 on the owner's instruction; this note previously said the opposite and contradicted the ST0 row). A QWT-free Windows is deterministic and does not drift, so it is built ONCE per OS, parked, and cloned. What remains true is only that ST0 has no qrexec and so cannot be driven or attested from inside: pristine-start cells are executed by the answer-stick's firstlogon orchestration and graded externally (bootwatch/CPU/screenshots) plus post-hoc durable logs. A full reprovision is warranted ONLY for the cell that tests Windows-install-plus-QWT-at-first-logon.
3. **No standing stock golden** (lifecycle disk rule wins over "clone STOCK immediately"): ST1 parks on the churn qube within one campaign, R1 restores it inside its two-shutdown window; stock-based cells in a campaign share one provisioning.
4. **Clone cost:** the updates draft's measured lvm_thin fact wins (R2 ≈ 0 GB at creation; 2.7 s) — lifecycle's OQ1 is answered; the ~20 GB figure survives as the *settled-divergence* budget for watermark math.
5. **qrexec_timeout:** 6000 standing everywhere; 15 is only a drain tool, restored only after the qube stays Halted (networking/harness wording wins over "restore immediately"); `matrix.sh`'s 600-on-reclone is a defect to fix at P0-PRE, not a second standard.
6. **qtest default target:** the harness draft describes the corrected tool (refuses unknown/untagged, `QTEST_VM` mandatory) and wins over the lifecycle's "defaults to win-idd-test" (the old tool); the rule "always set `QTEST_VM`" stands regardless.
7. **Disk floor:** lifecycle watermarks (RED at ~105 GB free) supersede the updates draft's "refuse below 60 GB" — the stricter, dom0-wide-hazard-aware rule wins.
8. **U3 subject:** reconciled "no extra snapshot qubes" with "never service the golden": primary = standing template + R1 rollback within the two-shutdown window (contingent on D5); fallback = TemplateVM-class re-creation on the churn name via R2. The updates draft's own "pre-update parent is the rollback point" supports the primary.
9. **b299011 baseline retired** to a historical footnote; BENCH-0 mints fresh canonical numbers with committed raws as the protocol's first benchmarking act (the rendering draft's own lean, made explicit). Scroll gates; drag is record-only pending D17.
10. **C11 downstream acceptance** is owned by NET-2/NET-3 (cross-referenced from P1) — the orphan risk both drafts flagged is closed.
11. **"Two reprovisions per full pass"** corrected to **three** (Win10 fresh + Win10 stock + Win11 fresh): the lifecycle's figure omitted that fresh and stock chains need different sticks; the "one per OS per *chain*" principle is preserved and no cell may use R3 where a cheaper restore suffices (requirement 7 encoded in §1.2 and §10).
12. **Requirement "no check whose PASS was never seen to fail"** is enforced via H5: checks without a fail-proof registry entry can only emit `PASS-UNPROVEN`, counted separately, with their fail-proof runs mandatory at TIER-C — this keeps the drafts' honest ledger rather than silently dropping unproven checks.