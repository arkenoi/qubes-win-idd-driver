# QWT Acceptance Protocol

**Scope.** Full acceptance for the QWT-NG deliverable (installer, gui-agent, IDD driver, PV-NIC latch, updates agent, safeguards), runnable **as a whole or in parts**, starting from pristine Win10/Win11 vendor images. Every phase and cell below has a stable ID, a named entry stage, a named exit stage, and prerequisites by ID — start anywhere the prerequisites are met. Inherited and binding: CLAUDE.md's autonomy/instrument rules, the PV-network testing protocol (CLAUDE.md, 2026-08-29 — encoded here in P2, not reinvented), the memory rules (never `service.gui-fullscreen`, never resize-to-viewport, canonical benchmarks, roster names only).

**ID scheme.** Stages `ST*` (§2.1), restores `R0–R4` (§2.3), phases `P0–P5`, cells `G0`/`C1–C12` (install), `NET-0–8` (network), `U0–U6` (updates), `RND-0–9`+`BENCH-0–2` (rendering/perf), `SG0–SG11` (safeguards), harness rules `H0–H5` (§3). Per-OS stage suffix: `.10` / `.11` (e.g. `ST1.10`).

**Structure.** Part I (§0) is the executable runbook: ordered steps with the command, the expected
output, and the failure action, every command verified against the script it invokes. Part II
(§1–§12) is the reference and remains the authority on cells, stages, and rules — nothing in it
was weakened when Part I was written. Execute Part I; consult Part II; when they disagree, stop
and reconcile (and record the divergence in §0.9) — do not improvise around either.

---

# Part I — Runbook

## 0. RUNBOOK — do exactly this (added 2026-08-30; expanded same day into the full Part I)

This section exists because the rest of this document is dense REFERENCE material and the
operational parts got improvised. Every failure of the 2026-08-30 attempt was covered somewhere in
Part II and still happened: a hand-rolled cell runner was written instead of using the harness (H0
names `mgmt/harness/matrix.sh` explicitly); the release was delivered by attaching it as a cdrom —
a route the harness does not implement — and three attempts were then lost because
`qvm-device block attach --persistent` is an alias for `assign --required` (applied at NEXT VM
start) and because a stale answer disc from provisioning was picked up by drive letter; bare
`sleep N` polls replaced the three-exit waits H2 prohibits outright; two Windows guests ran at
once against H3.6; cells were cloned from a golden that had served as a scratch guest all evening
against P1.0; and cells ran with no P0 preflight at all. Read this section first and execute it
verbatim; use Part II as the authority on what each step means.

**The harness already exists. Do not write another one.** If a primitive is missing, ADD IT to
`mgmt/harness/` with the three-exit contract, commit it, then use it (H0).

### 0.1 The instruments (verified against source 2026-08-30)

| Script | What it provides | The guard to respect |
|---|---|---|
| `mgmt/harness/matrix.sh` | The cell driver: `reclone / push_payload / run_install / verify_installed / start_vm`, cells `cell_fresh_1stage`, `cell_fresh_2stage`, `cell_fresh`, `cell_seeded`, `cell_upgrade_stock`, `cell_appvm`; selected via `CELLS=`, run strictly serially. Inputs: `MATRIX_WORK` (default `$HOME/qwt-matrix-work`), `MATRIX_OUT` (default `$HOME/qwt-matrix/<UTC-timestamp>`). | It sets the ambient `QTEST_VM` to an impossible name and passes `QTEST_VM=<vm>` per call — a forgotten target fails loudly instead of hitting a real guest. Do not weaken that. |
| `mgmt/harness/e2e-wait.sh` | The three-exit waits: `w_session` / `w_install` / `w_halt` / `w_screen` / `w_alive` (exit table in §0.3). `STALL_SECS=300`, `POLL_SECS=20` (floor ~5 s, H3.9), `MSI_POLL=1` default, `EVENT_POLL` opt-in. | Every wait says which exit it took; a wait that cannot fail is worthless. |
| `.claude/skills/win-guest-e2e/e2e-lib.sh` | `qrun`/`qpr`/`alive`/`cap`/`screenverdict`/`startrun`/`_logtail`/`bootwait`/`wait_install`, `E2E_RESTART_BUDGET=2`. | **Refuses to load when `QTEST_VM` is unset — deliberately, no default.** A default target once routed a whole run at whatever qube it named, and dom0 refuses an unknown target by writing NOTHING, which reads exactly like "the guest has no windows". Export `QTEST_VM` explicitly, always. |
| `tools/qtest` | `run`/`ps`/`push`/`pushrun`/`synctime`/`start`/`shutdown`/`kill`/`state`/`shot`/`fullshot`/`resize`/`wedge`. `push` lands files in `C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\`. | Refuses a nonexistent target and prints the tagged roster. Its baked-in fallback name `win-idd-test` is a dead qube by design, so an unset `QTEST_VM` fails loudly here too. |
| `tools/assert-payload.sh` | Gate 0 (§0.2 step 1). | Fails closed; no commit argument means "assert against HEAD", which is wrong for a campaign. |
| `mgmt/golden.sh` | seal / verify / list (§0.4). | `verify` exits 2 for UNSEALED as well as DRIFTED — both mean "do not clone". |
| `mgmt/reprovision-usb.sh` | R3 rebuild from vendor media (§0.7). | Removes and recreates the named qube; leaves `qrexec_timeout=300` and the stick assigned — §0.7's reset-trap block undoes both. |
| `mgmt/build-answer-stick.sh` | Answer-stick construction (§0.6). | Arg 1 is the Windows EDITION NAME; the output path is the `OUT` env var. `LOCALE` must match the media. |

### 0.2 The campaign, in order

Every step names the qube(s) it touches. Do the steps in this order; do not start a later step
while an earlier one is unresolved.

**Step 1 — pin the release and pass Gate 0.** *Dev qube only; no guest involved.*

    cd /home/user/qubes-win-idd-driver
    REL=<commit>                              # the commit the artifacts were built from.
                                              # Never gate against HEAD - it moves under a campaign.
    export MATRIX_WORK=$HOME/qwt-matrix-work  # matrix.sh's default work area
    gh run download <run-id> -D "$MATRIX_WORK/dl"   # CI artifacts: qwt-improved-setup,
                                                    # qwt-full-package, qwt-improved-iso
    tools/assert-payload.sh "$MATRIX_WORK/dl/qwt-improved-setup" "$REL"

*Expect:* `PASS: payload verified — <N> files, built from <sha12> (<REL>), installer matches repo`,
exit 0. Record the PASS line in the campaign transcript.
*On failure:* exit 1 (file/hash mismatch, wrong `driver_repo_commit`, installer drift) or exit 2
(unusable input) — stop; rebuild or fix `REL`. Any cell run on an ungated payload is
`INVALID-PROVENANCE` (§1 Gate 0 — the 2026-08-29 `f777bec` incident).

**Step 2 — entry-image custody.** *Targets `win10-base` and `win11-base`; both stay Halted — verify
never boots anything.*

    mgmt/golden.sh verify win10-base
    mgmt/golden.sh verify win11-base
    mgmt/golden.sh fixture <any campaign fixture a cell will enter from>

> **Roster corrected 2026-08-30.** This step used to name `win10-clean` / `win11-fresh`. Those were
> the historical goldens; they were never sealed, `win10-clean` had served as a scratch guest for a
> whole evening, and both were **removed** with owner sign-off (§2.6 prune ladder step 4) when the
> pool hit RED. The canonical goldens are the two pristine bases of §0.7c.

**Two acceptable provenances, both strict** (owner decision 2026-08-30, §0.7c): a **sealed golden**
passes `golden.sh verify`; a **campaign fixture** passes `golden.sh fixture`, which reads the
receipt `mgmt/harness/prime-run.sh` wrote when it built the fixture *and re-verifies the base
golden's seal at that moment* — so a fixture whose base has since drifted stops being acceptable.
Only the two pristine bases are ever sealed; everything carrying software (a previous release of
ours, stock 4.2.2, the nopvdisk shape) is a fixture, built on demand and removed at campaign end.

*Expect:* `VERIFIED <vm> matches its seal (sealed <UTC>)`, exit 0.
*On failure* (exit 2, `UNSEALED: ...` or `DRIFTED:` + `REFUSE to clone from <vm>`): do NOT clone.
Rebuild the golden, or re-seal deliberately with the change recorded. Every cell derived from an
unverified golden is `INVALID-CONTAMINATED` (H5; P1.0 golden-provenance clause).
*Standing state 2026-08-30:* `mgmt/goldens/` is EMPTY — nothing has ever been sealed, so this step
currently fails closed for every golden. That is correct behaviour, not an error to route around:
seal each golden at its next accepted state (§0.4) and this step becomes the campaign gate.

**Step 3 — P0 preflight. Never skipped** (cells ran with none on 2026-08-30). *Dev qube plus
read-only roster queries.* Run P0-CORE (§4): the G0 catalog-signature gate on the payload; the
build fingerprint (H1); pool and roster:

    qvm-pool info vm-pool                                # record %, compare §2.6 watermarks
    qvm-ls --raw-data --fields NAME,STATE,CLASS,NETVM    # roster per §2.2

*Expect:* templates carry `netvm=''` (a template with a netvm = STOP-and-report, NET-0); classes
match §2.2; every guest a cell will push to has `private >= 20 GiB` (§2.2 — the silent
file-copy-failure trap); fw-net confirmed with the owner if any traffic cell is in scope;
instrument self-tests for the selected parts (§4 P0-CORE.4).
*On any mismatch:* fix it first. A cell run against a failed precondition is
`INVALID-PRECONDITION`, not a product verdict (H4.2).

**Step 4 — halt every Windows guest.** *Targets every `win1*` qube (H3.6: one Windows guest at a
time, and a campaign starts with zero).*

    qvm-ls --raw-data --fields NAME,STATE | grep '^win1' | grep -v 'Halted'
    # for each name printed:
    qvm-shutdown --wait --timeout 300 <name>

*Expect:* re-running the first command prints nothing.
*On a guest that will not halt or flips back to Transient:* that is queued qrexec restarting it —
drain per §2.5 (`qrexec_timeout 15` → kill → Halted CONTINUOUSLY → restore 6000). Never
`xl destroy`; never diagnose a "wedged" guest before checking `qrexec_timeout` (H3.1).

**Step 5 — stage the harness inputs.** *Dev qube.* `matrix.sh` consumes exactly three paths:

    tar -czf "$MATRIX_WORK/qwt-setup.tar.gz" -C "$MATRIX_WORK/dl/qwt-improved-setup" .
    ls -l "$MATRIX_WORK/qwt-setup.tar.gz" \
          "$MATRIX_WORK/dl/qwt-full-package/gui-agent.exe" \
          "$MATRIX_WORK/dl/qwt-improved-iso/MANIFEST.json"
    tools/assert-payload.sh "$MATRIX_WORK/qwt-setup.tar.gz" "$REL"

The tarball's root must hold `install.cmd` (`run_install` executes `C:\<dir>\install.cmd`); the
`-C <payload-dir> .` form produces exactly that shape.
The `ls` is load-bearing, not ceremony: matrix.sh hard-fails only on a missing tarball; a missing
`gui-agent.exe` leaves its `ASHA` variable empty and the "installed agent == release binary" check
then matches ANY result line — a vacuous PASS (verified in source; §0.9.3). Re-gating the tarball
proves the artifact actually pushed is the artifact that was gated.
*Expect:* all three files listed; a second Gate-0 PASS line.
*On failure:* re-download the artifacts; never substitute a file from another build.

**Step 6 — run the cells, serially, through the harness.** *Clones the entry image named by
`G10`/`G11` into `win10-tpl`/`win11-tpl` and installs there; AppVM cells cold-boot
`win10-app`/`win11-app`.*

`G10`/`G11` have **no default** since 2026-08-30 — the run refuses to start until they are named.
The old default was `win10-goldr`/`win11-goldr`, which carried the release under test, so every cell
called "fresh" or "upgrade" silently took the same-version-reinstall branch. The right entry differs
per cell: a pristine base for a clean install, an N−1 fixture for C3, a stock fixture for C4, the C1
exit for C6.

    CELLS="win10-1stage win10-2stage win10-stock win11-1stage win10-appvm win11-appvm" \
      MATRIX_OUT=$HOME/qwt-matrix/$(date -u +%Y%m%d-%H%M%S) \
      bash mgmt/harness/matrix.sh

(`MATRIX_WORK` was exported in step 1. Seeded cells additionally need `SEED_DELAY=<secs>` AND
`SEED_CELL=1` both exported — H3.11; an inherited `SEED_DELAY` without the per-run opt-in
hard-aborts the cell, by design.)

Selector map (verified against the `case` dispatch in matrix.sh, 2026-08-30):

| Selector (`win11-*` analogous) | Function | Golden → target | What it actually exercises |
|---|---|---|---|
| `win10-1stage` | `cell_fresh_1stage` | `$G10` → `win10-tpl` | Push + install with testsigning already on. NOTE the name: over a golden that already carries QWT this takes the in-place-upgrade branch (C3-like), NOT C2 — the installer's `PRECONDITION` line is the authority on the branch taken (P1.0). |
| `win10-2stage` | `cell_fresh_2stage` | same | Turns testsigning OFF, reboots, asserts `SystemStartOptions` really lost TESTSIGNING, then installs — the E1 two-stage entry. Same PRECONDITION caveat. |
| `win10-fresh` | `cell_fresh` | same | Constructs a no-QWT precondition by uninstalling, rebooting, asserting `QWTPRODUCTS=0`, then installs. Diverges from P1.0's "preconditions are never constructed by uninstalling" — read §0.9.2 before treating its verdict as C1/C2-grade. |
| `win10-seeded` | `cell_seeded` | same | Armed monitor (`sc config xenbus_monitor start= auto`) + optional mid-MSI Request injection (only with `SEED_DELAY` + `SEED_CELL=1`; without `SEED_DELAY` it is the armed-monitor-only variant, and the transcript records the seed state either way). |
| `win10-stock` | `cell_upgrade_stock` | same | Uninstall ours → install `vendor/qwt-4.2.2/installer.msi` → assert 4.2.2 → install ours over it (C4 shape; ST1 constructed in-cell — §0.9.2). |
| `win10-appvm` | `cell_appvm` | (no clone) points `win10-app` at `win10-tpl` | 3 cold boots; judged from pixels: ≥1 window mapped, none fullscreen-sized. |

*Expect:* `=== MATRIX for <version> (agent <sha12>) ===` and `cells: ...`, then per cell a
`######## CELL <name> ########` banner, timestamped progress, and the harness's own
`PASS  ...`/`FAIL  ...` lines; footer `=== MATRIX: N passed, M failed ===` then `=== DONE ===`.
`FATAL no setup tarball at ...` at startup means step 5 was skipped.
*While it runs:* nothing else touches any Windows guest; never edit the running script (H3.6);
watch by tailing `$MATRIX_OUT/matrix.log`, not by poking guests.
*On a FAIL cell:* the guest's state is evidence — preserved per H3.5; the campaign continues on
other cells (H4.5). A `could not reclone` that survives the built-in dirty-volume revert retries:
stop and read the logged clone error; do not hand-clone around it.

Three operational facts about this driver, all verified in source (details §0.9): an unset `CELLS`
defaults to the string `seeded`, which matches NO selector — the run prints a header, does
nothing, and ends `0 passed, 0 failed`; never read that as a passed campaign. `reclone` sets
`qrexec_timeout=600`, not the standing 6000 (P0-PRE.2 owed). The install cells CONSUME the
standing ST3 templates — after a matrix run `win10-tpl`/`win11-tpl` contain this campaign's
install result, so re-establish ST3 with R4 (`mgmt/clone-to-template.sh`) when standing
template/AppVM stages are needed next.

**Step 7 — read the verdicts.** *Dev qube.*

- `$MATRIX_OUT/matrix.log` — every PASS/FAIL line; the exit summary counts them.
- Per cell: `<label>-install.log` (cumulative, deduplicated installer log), `<label>-msi.log`
  (msiexec verbose tail), `<label>-monitor.log` (xenbus_monitor probe), `<label>-final.log`,
  shot tars and PNGs.
- Before believing any cell's label, check its `=== PRECONDITION ===` line matches the identity
  the label claims — the PRECONDITION line is the authority on found state, `upgrade_mode`+`stage`
  on the branch taken; a harness probe disagreeing with either is the harness being wrong (P1.0,
  the `c1f4312` voiding).
- Transcribe one H5 verdict line per check into the campaign's `verdicts.tsv`; a cell that died
  without a verdict line is `ABORTED`, never inferred successful (H4.4).

**Step 8 — restore and record.** Restore entry stages or capture exit stages per §2.4 before
releasing any qube; record pool % if any R2/R3/R4 ran; append stage manifests and dated findings
to FINDINGS.md.

### 0.3 Runbook: one part outside the matrix

§1 defines the contract (Gate 0 → campaign id → prerequisites by ID → five-line header → harness →
evidence → verdict lines). The executable skeleton for a scripted part:

    cd /home/user/qubes-win-idd-driver
    export QTEST_VM=<the ONE qube this part targets>   # e2e-lib refuses to load without it
    source .claude/skills/win-guest-e2e/e2e-lib.sh
    source mgmt/harness/e2e-wait.sh

Waits — use these and only these. A bare `sleep N && continue` poll is prohibited (H2); the only
fixed delay allowed is a *declared settle window* attached to a grading step (e.g. the 90 s
network settle).

| Primitive | Keys on | Exits |
|---|---|---|
| `w_session <vm> <deadline> <label> <outdir> <logfn>` | qrexec liveness + per-minute screen classify | 0 session up; 1 TERMINAL (RECOVERY, or BLACK ×3 min with cpu≈0); 2 DEADLINE |
| `w_install <vm> <deadline> <label> <outdir> <logfn> <guest-log>` | log line COUNT past the marker, fresh read per poll | 0 RESULT present; 1 recovery; 2 deadline; 3 guest halted; 4 STALLED (`STALL_SECS`, default 300) |
| `w_halt <vm> <deadline> <label> <logfn>` | domain state | 0 halted; 2 deadline (never kills — the caller decides) |
| `bootwait [min] [logfn] [dir]` (e2e-lib) | `alive` + `screenverdict` + restart budget (`E2E_RESTART_BUDGET`, default 2) | 0 alive; 3 terminal, guest preserved; 1 timed out |
| `wait_install [min] [logfn]` (e2e-lib) | `_logtail` past the `startrun` marker | 0 ended; 2 failed; 1 stalled/timeout. Requires `startrun` first — refuses otherwise, because a stale log would be judged |

Poll cadence ≥15 s steady-state, absolute floor 5 s (H3.9 — per-second qrexec churn triggered the
IPI-shootdown wedge). Starting a guest: `qvm-start` blocks up to `qrexec_timeout` on a non-booting
guest (15 min measured) — fire-and-poll instead (H3.7), as matrix.sh's `start_vm` does.
A missing wait is added to `mgmt/harness/e2e-wait.sh` with the three-exit contract, committed,
then used (H0). Worked example: §1's NET-2 walk-through (`win10-app`, ~25 min, no reprovision).

### 0.4 Runbook: golden custody (`mgmt/golden.sh`)

A golden is **sealed**, then only ever **cloned** — never started, never logged into, never "just
checked"; diagnostics belong on a churn qube (`win10-u10`, `win11-24h2`). One careless boot
contaminates every later clone silently: on 2026-08-29/30 the Win10 golden served as a scratch
guest all evening (agent binary hot-swapped twice, xencons side-loaded by hand, `debug` toggled,
Windows Update enabled then disabled, private volume extended mid-life, repeated hard restarts) —
and cells were then cloned from it.

    mgmt/golden.sh seal    win10-base "pristine ST0.10 + primer"
    mgmt/golden.sh verify  win10-base      # exit 2 = drifted OR unsealed -> do not clone
    mgmt/golden.sh fixture win10-c1        # the OTHER provenance: a receipt + a live base seal
    mgmt/golden.sh list

- `seal <vm> [note]` — target must be Halted. *Expect:* `SEALED <vm> -> mgmt/goldens/<vm>.json`.
  Refuses a running qube (`REFUSING: <vm> is <state>`). **Commit the JSON** — a record that dies
  with the session is not a record.
- `verify <vm>` — needs no boot (booting a golden to check it would BE the modification).
  *Expect:* `VERIFIED <vm> matches its seal (sealed <UTC>)`, exit 0. Exit 2 is either `UNSEALED`
  (fails closed — "no record" must never read as "unchanged") or `DRIFTED` with the changed fields
  printed; either way rebuild, or re-seal deliberately with the change recorded. The tamper signal
  is the root-volume revision list — Qubes cuts a revision on every clean shutdown, so a booted
  golden gains one its seal never recorded; volume sizes and the clone-relevant qube properties
  are compared too.
- `list` — every sealed golden with date and note.
- `fixture <vm>` — the provenance check for a **campaign fixture**, which by decision is never
  sealed. Reads the receipt `prime-run.sh` wrote (base golden, its seal timestamp, job, flags, build
  time) and RE-VERIFIES the base's seal now. Exit 2 for a missing/unreadable receipt or a drifted
  base — a qube built by hand is refused exactly as loudly as an unsealed golden.
- *Standing state 2026-08-30:* `win10-base` and `win11-base` are sealed and verify intact. The four
  older seals (`*-gold0`, `*-goldr`) are superseded and are not the roster.

### 0.5 Runbook: delivering a release to a RUNNING guest

Two legitimate routes (P1.0 "Payload delivery"). A pristine guest has no qrexec and takes
neither — it is stick-orchestrated (§0.6).

**Route A — attach the release ISO as a cdrom (the user-realistic path).** Works on any
*installed, running* Windows: it has PV drivers, so the disc is visible. (The WinPE invisibility
caveat does NOT apply here — §0.6.) The backend is this qube; serve the ISO from a loop device
that `losetup -l` shows backed by the intended file and NOT `(deleted)`.

    qvm-device block attach --ro --option devtype=cdrom <running-vm> win-idd-mgmt:<loopN>

*Expect:* silent success (exit 0); the disc appears in the guest within seconds — verify from the
guest, never from the attach's exit code.
**Never `--persistent` on attach:** it is documented as an alias for `assign --required`, i.e.
applied at the qube's NEXT startup — against a running guest it succeeds and changes nothing the
guest can see, and a subsequent plain `attach` is then refused with "already assigned" (three
attempts lost to exactly this on 2026-08-30). When the disc must survive the install's own reboot,
use `qvm-device block assign --required ...` BEFORE starting the qube instead.
In-guest, locate the disc BY CONTENT, never by drive letter — a stale answer disc still attached
from provisioning gets picked up otherwise. The check has this shape (a drive carrying both
`install.cmd` and `MANIFEST.json`):

    QTEST_VM=<vm> tools/qtest run 'cmd /c for %d in (D E F G H I) do @if exist %d:\install.cmd if exist %d:\MANIFEST.json echo RELDISC=%d:'

Then assert that disc's `MANIFEST.json` `source.driver_repo_commit` equals `$REL` before running
anything from it. *On failure* (no RELDISC): check the qube's block assignments and the loop's
backing file; do not fish drive letters by hand.

**Route B — `qtest push` (what `mgmt/harness/matrix.sh:push_payload` implements).** One tarball,
pushed as a single file, extracted guest-side into a fresh per-cell directory (the harness uses
`C:\q4315`):

    QTEST_VM=<vm> tools/qtest push "$MATRIX_WORK/qwt-setup.tar.gz"
    QTEST_VM=<vm> tools/qtest run 'cmd /c "rmdir /s /q C:\q4315 2>nul & mkdir C:\q4315 & tar -xzf C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\qwt-setup.tar.gz -C C:\q4315 && echo EXTRACT_OK"'

*Expect:* `EXTRACT_OK`. The fresh directory is mandatory — a stale directory from a previous cell
is grading contamination.
*On failure:* retry up to 3× with 20 s backoff KEEPING stderr (H3.8) — the first attempt reliably
fails about a second after a session first answers `QREADY`. Three failures = the cell fails;
never retry forever.

### 0.6 Runbook: media — answer sticks, and which medium reaches which consumer

The rule that decides the medium (measured twice, 2026-08-07): **Windows Setup / WinPE carries no
Xen PV drivers, so a PV cdrom is INVISIBLE to it.** OS provisioning therefore boots the untouched
vendor ISO plus an **emulated USB answer stick** (WinPE does carry USBSTOR/USBXHCI inbox). **An
installed, running Windows has PV drivers**, so a cdrom attach is fine there — it is the standard
QWT install path (§0.5 Route A). Installing an OS and installing QWT onto a running guest are
different problems with different media rules; never carry the caveat from one to the other.

Builder: `mgmt/build-answer-stick.sh`. Read its header before first use of a new variant.

    # Win10 RELEASE stick (Win10 media here is en-GB - see the locale trap below):
    LOCALE=en-GB RELEASE_SETUP="$MATRIX_WORK/dl/qwt-improved-setup" \
      OUT=$HOME/win-iso/answer-usb.img mgmt/build-answer-stick.sh "Windows 10 Pro"

    # Win10 STOCK stick (stock package dir installed via OUR installer; its MANIFEST.json must
    # have reference_binaries removed - the builder enforces both):
    LOCALE=en-GB STOCK_SETUP=<stock-package-dir> \
      OUT=$HOME/win-iso/answer-usb-stock.img mgmt/build-answer-stick.sh "Windows 10 Pro"

    # Win10 PRISTINE (ST0) stick: leave RELEASE_SETUP / STOCK_SETUP / REAL_STOCK_EXE all unset
    # -> a QWT-free stick, deliberately. NOTE THE DISTINCT OUT PATH - writing a pristine stick to
    # the RELEASE stick's filename overwrites it in place while its loop keeps serving that file,
    # so the next default reprovision silently installs no payload and dies on "never reached
    # qrexec". Measured 2026-08-30: answer-usb.img was clobbered exactly this way.
    LOCALE=en-GB OUT=$HOME/win-iso/answer-pristine-win10.img \
      mgmt/build-answer-stick.sh "Windows 10 Pro"

    # Win11 PRISTINE (ST0.11): the WIN11 TEMPLATE IS MANDATORY - see §0.6b(a). Without it Setup
    # halts at "This PC doesn't currently meet Windows 11 system requirements".
    UNATTEND=$PWD/mgmt/autounattend-win11.xml LOCALE=en-US \
      OUT=$HOME/win-iso/answer-pristine-win11.img \
      mgmt/build-answer-stick.sh "Windows 11 Enterprise Evaluation"

    # Win11 (eval media is en-US, matching the builder default; image name confirmed by wiminfo):
    UNATTEND=mgmt/autounattend-win11.xml OUT=$HOME/win-iso/answer-usb-win11.img \
      mgmt/build-answer-stick.sh "Windows 11 Enterprise Evaluation"

The traps, each of which has cost a real debugging cycle:

- **The first positional argument is the Windows EDITION/IMAGE NAME** (default
  `Windows 10 Pro`), not an output path. **The output path is the `OUT` env var** (default
  `~/win-iso/answer-usb.img`). A path passed as arg 1 builds a stick whose answer file names a
  nonexistent edition, and Setup stops at the image picker.
- **LOCALE must match the media or Setup silently ignores the answer file** and drops to the
  interactive locale picker — indistinguishable from "the answer file was never found". The Win10
  media here is `Win10_22H2_EnglishInternational` = **en-GB**; the builder defaults to **en-US**.
  Every Win10 stick build passes `LOCALE=en-GB`. Tell of the mismatch: guest CPU ~1 s per 40 s
  poll instead of ~45 s; proof is a screenshot (§2.1).
- **`RELEASE_SETUP` unset produces a QWT-free stick.** That is how ST0 is built — a feature and a
  foot-gun: forgetting it silently provisions pristine Windows with no payload.
  `RELEASE_SETUP` / `STOCK_SETUP` / `REAL_STOCK_EXE` are mutually exclusive (enforced).
- **Keep `SIZE_MB` constant (default 96).** The image is rewritten in place, inode preserved, so
  already-attached loops keep serving current content; a size change would be served truncated.
  `reprovision-usb.sh` asserts exposed-vs-actual size and refuses `(deleted)` backings. Corollary:
  replace a loop's backing file CONTENT in place (truncate/cp to the same path); never
  rm-and-recreate under an attached loop.
- `INSTALL_FLAGS` defaults to `/idd`; `WITH_KEY` defaults to 1 (generic key — retail
  multi-edition media needs one to select the edition).

*Expect from a good build:* `locale: <l> (input <kbd>), image: <name>` → `answer file: all
placeholders substituted, XML well-formed` → `payload: ...` (absent on a pristine stick) → a
directory listing → `built <OUT> (<size>)` plus the attach recipe. All failure paths are loud
(placeholder assert, XML parse, `mcopy -Q`, Autounattend-presence check).
Loop inventory and the deleted-inode rule: §2.7. Attaching a NEW loop from this qube: consult
`.claude/skills/rig-capabilities/SKILL.md` first — this qube has no sudo, and the standing loops
exist precisely so new ones are rarely needed.

### 0.6b Two failures that cost a provisioning run (2026-08-30) — read before building any stick

**(a) Windows 11 REQUIRES its own answer template. `UNATTEND` is not optional.**

    UNATTEND="$PWD/mgmt/autounattend-win11.xml" LOCALE=en-US \
      OUT=/home/user/win-iso/answer-pristine-win11.img \
      ./mgmt/build-answer-stick.sh "Windows 11 Enterprise Evaluation"

`build-answer-stick.sh` defaults to `mgmt/autounattend.xml`, the **Win10** template. Only
`mgmt/autounattend-win11.xml` carries the windowsPE `LabConfig` registry writes
(`BypassTPMCheck`, `BypassSecureBootCheck`, `BypassRAMCheck`, `BypassCPUCheck`,
`BypassStorageCheck`) that let Setup proceed on a Qubes HVM. Build a Win11 stick without it and
Setup stops at **"This PC doesn't currently meet Windows 11 system requirements"** and installs
nothing — measured 2026-08-30 on `win11-gold0`.

*Verify before provisioning* (note the capital A — the file on the FAT image is `Autounattend.xml`,
and a lowercase `7z e` silently extracts nothing, which reads as "no bypasses"):

    7z e -y -o/tmp/stickx <stick.img> Autounattend.xml
    grep -oE 'Bypass[A-Za-z]+Check' /tmp/stickx/Autounattend.xml | sort -u   # expect all five
    grep -c '@[A-Z_]*@' /tmp/stickx/Autounattend.xml                          # expect 0

Also required for the eval media: `"Windows 11 Enterprise Evaluation"` as the image name — the
positional argument is the Windows EDITION, not a filename (§0.6).

**(b) The screen classifier is ADVISORY. Never gate on `VERDICT=`.**

`tools/winshot.py`'s verdict answers "is something rendering", not "did this step succeed" — H2 says
so, and it was still built into a completion gate. Measured the same day: a pristine `win11-gold0`
build reported **"pristine desktop reached after 137s"** while the screen showed the Windows 11
Setup error dialog above. The classifier saw a light window on a dark ground and returned `DESKTOP`;
sampling twice 30 s apart changed nothing, because a static error dialog is identical 30 s later.
137 s is also not a Windows install, and no elapsed-time floor was checked.

Consequently `PRISTINE=1` **does not declare success**. It waits for a candidate screen, saves the
capture, and exits **3 = NEEDS-VISUAL-CONFIRMATION**; a human or agent must READ that PNG before the
qube is sealed. An ST0 guest has no qrexec and the capture carries no window titles, so nothing
available can separate "finished desktop" from "Setup error" automatically — an honest "cannot
decide" beats a gate that decides wrongly. **Any claim that a guest reached a desktop must cite an
image that was read, not a verdict string.**

### 0.6c Building a golden from scratch (RB-01/RB-02 resolution, 2026-08-30)

The audit found that "rebuild the golden" had **no procedure anywhere**, so every documented exit
from an UNSEALED or drifted golden was blocked by some other rule — the runbook could not start.
It also found that the prescribed "clone ST0 and install into the clone" has **no execution
channel**: a pristine guest has no qrexec, and the answer stick's `FirstLogonCommands` are consumed
at its own provisioning, so there is nothing left to drive an install with. That gap is also why
`cell_fresh` reaches for `msiexec /x` — the standing goldens carry QWT *because* that is the only
way to have a control channel, so "fresh" gets faked by uninstalling, which P1.0 forbids.

**Do not solve it by cloning. Build the golden in one pass with a PAYLOAD stick.** One R3 per OS
installs Windows *and* the release at first logon, yielding a golden that already has qrexec — which
every later cell can clone and drive normally. Once per OS, not once per cell.

    # 1. Payload stick (release staged under \payload\release). Win11 needs its own template.
    LOCALE=en-GB RELEASE_SETUP=$MATRIX_WORK/dl/qwt-improved-setup \
      OUT=$HOME/win-iso/answer-usb.img mgmt/build-answer-stick.sh "Windows 10 Pro"

    # 2. Fresh NAME - never over a standing golden, so a failed build cannot destroy the last
    #    good one, and §0.7's "no R3 on golden names" is respected.
    mgmt/reprovision-usb.sh win10-goldN loop0 <payload-stick-loop>     # expects: qrexec alive

    # 3. READ the screen and the install log before believing it (§0.6b).
    # 4. Halt, then seal.
    mgmt/golden.sh seal win10-goldN "ST2G.10 - release <ver>"

**ST0 parks remain worth building** — they are the cheap base for re-cutting an ST2G when only the
package changes, and they are the only honest subject for "what does Windows look like with nothing
of ours on it". They are simply not a clone-and-install source. Until a driveable path into a
pristine clone exists (owner decision), treat ST0 as a reference image, not a production base.

**Retired by this section:** the instruction to reach an ST2G by cloning ST0 and installing into the
clone. It cannot be executed as written.

### 0.7 Runbook: reprovision from vendor media (R3)

Only for the cell that actually tests Windows-install-plus-QWT-at-first-logon (ST0 row, §2.1; at
most three R3 per full pass, §10), and only on churn qubes — the sole Win10 R3 target is
`win10-u10` (§2.2). The script REMOVES AND RECREATES the named qube.

    mgmt/reprovision-usb.sh win10-u10 loop0 loop9    # <vm> <vendor-iso-loop> <answer-stick-loop>

Before it: build/refresh the stick (§0.6) and verify the loops (§2.7). The script self-asserts
the STICK loop (size + non-deleted inode) but NOT the ISO loop — eyeball that side yourself.
`BUDGET` bounds the wait (default 5400 s; Win10 measured 17–20 min; Win11 unmeasured — time once
and record, D19). Drain queued qrexec BEFORE it removes the qube (§2.5).
**Building an ST0 (pristine, QWT-free) image: set `PRISTINE=1`.**

    PRISTINE=1 mgmt/reprovision-usb.sh win10-gold0 loop0 <pristine-stick-loop>

This is not optional decoration. §2.1 defines ST0 as having **no qrexec — undriveable**, because the
stick carries no QWT payload, so no qrexec agent is ever installed. The script's default completion
test is `qrexec alive`, which such an image **cannot reach by construction**: it will run to a clean
desktop and then sit until `BUDGET` (5400 s) expires and report `FAIL: never reached qrexec` for a
perfectly good install. Measured 2026-08-30 — `win10-gold0` reached a clean Win10 desktop in ~20 min
and the provisioner was still waiting 17 minutes later, having logged nothing since boot. With
`PRISTINE=1` the criterion is instead a **settled desktop on screen** (two `VERDICT=DESKTOP`
classifications 30 s apart, so one frame caught mid-OOBE cannot pass) — the screen being the only
channel a pristine guest has, and pixels being the standing evidence rule.

*Expect (default, payload stick):* `answer stick verified: /dev/loopN -> <file> (<bytes> bytes)` →
shutdown/remove/create lines → `booting the vendor ISO (...) with the answer stick (...)` → several
`install-phase halt -> restarting without CD` cycles → `qrexec alive after <N>s`, exit 0.
*Expect (`PRISTINE=1`):* the same up to the reboot cycles, then periodic
`t+<N>s screen=VERDICT=<X> (advisory)` lines, and finally — no earlier than 900 s —
`candidate desktop after <N>s` plus `NEEDS VISUAL CONFIRMATION - READ <dir>/latest.png`,
**exit 3**. Exit 3 is NOT success: READ that image before sealing anything. An earlier draft of
this line promised `pristine desktop reached ... exit 0`; that criterion was retracted in §0.6b
after it passed a Setup error dialog, and the script no longer implements it.
*On `FAIL: never reached qrexec within <BUDGET>s`:* triage with screenshots (`w_screen`,
`qtest shot`) BEFORE any retry — the classic silent cause is a locale or image-name mismatch
(§0.6). One retry after a diagnosed cause; never blind-loop reprovisions.

After success — the reset trap (§2.5): the script leaves `qrexec_timeout 300` and the stick
assigned `--required`, which makes every later boot depend on this qube's loop layout (D2).
Re-apply the standing values and remove the boot-time dependency:

    qvm-prefs win10-u10 qrexec_timeout 6000
    qvm-prefs win10-u10 netvm fw-net          # Standalones/AppVMs only; NEVER templates
    qvm-device block unassign win10-u10 win-idd-mgmt:loop9
    qvm-features --unset win10-u10 qemu-extra-args

(The assign side is scripted; the unassign side is not — the `unassign` verb exists in
`qvm-device block --help`, but if it argues about the assignment form, read the help output
rather than forcing, and record the working form here.)
Then run restore validation (§2.3): state sane → `QTEST_VM=win10-u10 tools/qtest run "echo ok"` →
guest-read stage attestation.

### 0.7b Getting a Windows guest, and getting QWT onto it (added 2026-08-30 — three wasted reinstalls)

**Cloning a sealed golden takes ~2 seconds. A reprovision takes 17-20 minutes.** Measured the same
session: `dst.volumes[v].clone(src.volumes[v])` for root+private completed in **1.8 s**, against a
reprovision that also resets `netvm`, `qrexec_timeout` and tags. R3 is warranted for exactly one
cell - the one testing Windows-install-plus-QWT-at-first-logon via the answer file. **Reaching for
`reprovision-usb.sh` for any other reason is a 20-minute mistake**, and it was made three times in
one night despite the ST0 row already saying so.

**To put the QWT installer in front of a guest, use the mechanism that exists.**
`qvm-start <vm> --install-windows-tools` = "temporarily attach Windows tools CDROM to the domain".
It needs dom0; from the mgmt qube it fails with *"Existing block device identifier needed when
running from outside of dom0 (see qvm-block)"*, so here the equivalent is attaching the ISO as a
cdrom block device (§0.5 Route A). A custom answer stick with a staged installer, a testsigning
reboot and a SYSTEM onstart task was built in this session as a parallel mechanism to this one,
before anyone checked whether Qubes already had it. **Check for the knob before building the
machine.**

**Channel reality — and this section previously contained a FABRICATION, not a rediscovery.** §2.1 already states that ST0
is "No qrexec - undriveable", and the rig skill already records the queued-qrexec trap: calls fired
at a guest with no agent queue up, auto-start it, outlive the caller, and produce the "unkillable
qube" that was once reported as a defect. **Do not aim qrexec at a guest that has no qrexec agent** -
it is not merely futile, it actively wrecks the qube's state and your understanding of it.

**The correction that matters: the earlier draft of this paragraph was INVENTED.** "Attaching media
does not run it" appeared in no document, was never true, and was written here as if it were a
finding. It is a hallucination that was then used to justify building a custom answer stick around a
constraint that does not exist. The tools ISO **AUTORUNS**. That is the point of `qvm-start --install-windows-tools`. Attaching it to a
pristine guest installs QWT without any qrexec, without an answer stick, and without a human at the
console. The claim "attaching media does not run it" was invented here and is false; it is what made
the stock-install path look impossible for an entire session.

So the channels into a Windows guest are: **an autorunning attached ISO** (works on a pristine
guest - the supported route), the answer file's FirstLogonCommands (only during a fresh install),
and qrexec (only once QWT is already installed).

### 0.7c TWO BASE GOLDENS AND THE PRIMER CHANNEL (added 2026-08-30, owner: "we need just two goldens for e2e all matrix")

**The whole matrix derives from two images, and nothing else is kept:**

| golden | what it is | what it is NOT |
|---|---|---|
| `win10-base` | pristine Win10 22H2, no QWT, testsigning **OFF**, primer hook installed | not a release carrier, not stock-QWT |
| `win11-base` | pristine Win11 24H2 Eval, same | same |

Testsigning stays OFF on purpose: that is what makes these valid preconditions for the two-stage
(E1) clean-install cell, where stage 1 must be observed turning it on.

**Why a primer at all.** A pristine guest has no QWT, therefore no qrexec, therefore no way to run
anything in it. `FirstLogonCommands` fire only at the first logon of a fresh install and never
again, so *cloning* a pristine golden does not get you a second shot at them. That is why every
"install some QWT into a clean guest" job kept collapsing into a 17-20 minute Windows REINSTALL: the
reinstall was never needed for Windows, it was needed for the one execution channel such a guest
has. §0.7b's autorunning ISO is the supported end-user channel; the primer is the rig's, and it
depends on no AutoPlay behaviour at all.

**The channel.** `mgmt/primer/qubes-prime.cmd` is baked into both base goldens as a SYSTEM `onstart`
task (`QubesPrime`). At every boot it looks for `<removable>:\qubes-prime\onboot.cmd`. Attach a job
stick carrying that path and it runs, once, as SYSTEM.

    # build a job stick (payload staged at \qubes-prime\, must contain onboot.cmd)
    PRIME_JOB=mgmt/prime-jobs/stock-422 OUT=~/win-iso/job.img SIZE_MB=96 mgmt/build-answer-stick.sh
    # clone a base golden, attach the stick the same way reprovision-usb.sh does, boot it
    qvm-features <clone> qemu-extra-args -- '-drive file=/dev/xvdi,...usb-storage...'

Clone (~2 s) + boot beats reprovision (~20 min) for every precondition except the one cell that is
genuinely about installing Windows itself.

**CONTAMINATION RULES — the reason this is safe to leave in a golden every clone inherits.**

1. **Inert by default.** With no primer media attached the hook performs `if exist` tests and exits.
   It writes nothing: no log, no marker, no registry, no file. A boot without a stick is
   indistinguishable from a boot without the primer.
2. **One shot.** It unregisters its own task *before* running the job, so a job that reboots (they
   all do) cannot re-trigger, and a guest that has been primed is no longer primed.
3. **Auditable.** Having fired leaves `C:\qubes-prime\fired.mark`.
4. **Non-colliding.** It looks for `\qubes-prime\onboot.cmd`. Every other stick this rig builds uses
   `\payload\setup.cmd`, so no answer stick can trigger it by accident.
5. **Rig-only.** It is baked into golden IMAGES at provisioning time. It is not part of the QWT
   package and must never ship in one.

**Grading gate (H5 fail-proof registry):** any guest whose result is being graded must be asserted
to have **no `C:\qubes-prime\fired.mark`**, unless its cell declares that it was primed (`CELL_PRIMED=1`).
A primed guest has had arbitrary SYSTEM code run in it and must never be silently mistaken for a
clean one. Implemented as `_assert_not_primed` in `mgmt/harness/matrix.sh`, called from
`verify_installed`; an unreadable marker is `INVALID-INSTRUMENT`, never "clean".

> **FAIL-PROOF OWED — this check's PASS is UNPROVEN until then.** Per H5, a check counts as evidence
> only once it has been seen to FAIL with the defect deliberately present. Owed test: create
> `C:\qubes-prime\fired.mark` on a throwaway guest, run the cell without `CELL_PRIMED=1`, and
> confirm it reports `INVALID-PRECONDITION`. Until that is recorded here, treat every
> "guest is not primed" PASS as unverified.

**Prime jobs (`mgmt/prime-jobs/<name>/onboot.cmd`) — the preconditions worth building this way:**

| job | builds | why it matters |
|---|---|---|
| `stock-422` | genuine upstream QWT 4.2.2 | the rare one-shot upgrade-from-stock check |
| `ours-nopvdisk` | our MSI with `ADDLOCAL` **minus `PvDriversDisk`** | **the better upgrade target** — see below |

**`ours-nopvdisk` is the higher-value upgrade precondition** (owner, 2026-08-30: *"this half-broken
install makes better target to test upgrade paths"*). Our own releases in the regression window
(`FINDINGS:5578`) shipped without `PvDriversDisk`, so there is a real installed base in exactly that
state: QWT working, every disk on emulated ATA (`FINDINGS:5350`). Upgrading one means the boot disk
must switch **from emulated to PV** — the dangerous direction, and the one the in-place path only
survives because the first boot stays on the emulated stack while xenvbd re-binds on the second
(`FINDINGS:6253`). That is a path we own and our users will actually take, unlike stock->ours.

Build the precondition by driving the CURRENT MSI with the feature omitted, rather than by hunting
down an old release binary: it reproduces the same installed state and stays reproducible as the
package moves. It is a TEST FIXTURE — do not add a product flag for it.

**Stock QWT 4.2.2 goldens are deliberately NOT kept** (owner, 2026-08-30: *"if we implement it, we
do not need preinstalled 4.2.2 goldens because testing upgrade from stock is rare enough one-shot"*).
Upgrade-from-stock is a one-shot: clone a base golden, drive `mgmt/prime-jobs/stock-422` into it,
then install ours over that. The job is two passes either side of a testsigning reboot and it seeds
the six vendor `SigningCert*.cer` into Root **and TrustedPublisher** before running the bundle —
without that seeding the install returns **1603**, measured on win10-u10 2026-08-30, because PnP
raises a driver-trust dialog that nothing in session 0 can answer.

### 0.7d COMPLETION AND HONESTY GATES (added 2026-08-30 — owner: *"correct your runbook so a) this wont happen again b) none of your hallucinations and misinterpretations are going to repeat"*)

Every rule here is a failure committed in the 4.3.16 campaign. They are gates, not intentions.

**G-0c. BEFORE ANY BENCH OR RND PART, POSITIVELY DISARM THE UPDATE SCAN.** *(owner, 2026-08-30:
"how come you run UPDATES and gui performance benchmark overlapping? thats total bs")*

P3's standing rules already say it: *"**serial** — never concurrent with a benchmark/rendering part,
and before any BENCH part check `QubesWindowsUpdateScan`'s next run (6-hourly + boot+2 min) — a
mid-benchmark scan raises the proxy and churns qrexec (**wedge trigger**)"*. The rule existed; what
was missing was an executable step, so it was read and not applied.

**The step, before any BENCH/RND cell:**

    schtasks /query /tn QubesWindowsUpdateScan /v /fo LIST | findstr /i "Next Run Time"
    schtasks /change /tn QubesWindowsUpdateScan /disable      # and re-enable at the end of the part

and **record the disarm in the cell's evidence**. A benchmark whose transcript does not show the scan
disarmed is `INVALID-PRECONDITION` — not a slow number, not a wedge worth investigating: an
unmeasured cell.

**Note the boot+2min trigger specifically.** Cold-booting a guest and starting a benchmark within a
few minutes puts the workload directly on top of the scheduled scan. That is the single easiest way
to hit this, and it is what happened: `win10-p45` booted ~17:52 UTC with the scan due ~17:54, and
BENCH-2 started ~17:53.

*Failure that produced this gate:* every BENCH number taken on 2026-08-30 — on both the contaminated
and the rebuilt subject — was measured inside a window where a scheduled scan may have been running,
so none of them is citable. The rebuilt subject then wedged mid-benchmark, i.e. the documented
consequence of the documented trigger. The rule had been read into the session transcript hours
earlier.

**G-1. The completion verdict is ARITHMETIC, not prose.** Run `tools/campaign-verdict.sh <verdicts.tsv>`
and paste its output as the summary's first block. A campaign is COMPLETE only with **zero FAIL, zero
INVALID-\*, zero INCONCLUSIVE, zero BLOCKED, and every PASS carrying a fail-proof registry entry**.
Anything else is **"EXECUTED WITH GAPS"** and the gaps go in the first paragraph.
*Failure:* I reported "acceptance protocol complete" for a run containing a product FAIL, two
INVALID-PRECONDITION cells, one INVALID-VACUOUS, one INCONCLUSIVE, two blocked cells and 183 passes
with no fail-proof. Every gap was honestly in the ledger; the prose averaged them away.

**G-0. DO NOT TOUCH THE SYSTEM UNDER TEST UNTIL THE FAILURE IS WRITTEN OFF.** *(owner, 2026-08-30:
"you are explicitly prohibited to mess with the tested system before you wrote off a failure")*
This gate comes first because every other gate depends on the evidence still existing.

When a check FAILS: **STOP.** Before any other action — no re-run, no "just try one thing", no
registry poke, no reboot, no service restart:
1. Write the H5 verdict line with the failing evidence paths.
2. Capture the state: logs, status files, screen, relevant registry, process list.
3. Leave the guest EXACTLY as it is (H3.5 already says FAIL states are preserved; this is the
   operational form of it).

**Diagnosis begins only after the write-off, and it happens on a CLONE or a restored copy — never on
the failed subject.** The failed subject is the only instance of the fault that exists; it is
evidence, not a workbench.

*Failure that produced this gate:* the U1 scan failed `0x8024402C` four times. Instead of writing it
off I began mutating the subject immediately — renamed `C:\Windows\SoftwareDistribution`, set and
later cleared proxy planes, ran isolation passes, and let it cold-boot repeatedly. When it later
scanned successfully, **no attribution was possible**: at least three variables had changed on the
one guest carrying the fault. A root cause that was merely UNKNOWN became UNKNOWABLE on that subject,
and a false root cause plus a ship-blocking verdict were published from the wreckage. The same guest
was then used for further cells, compounding it.

**Test for whether this gate applies:** if the answer to *"could I still reproduce the failure on
this guest right now?"* is no, and you changed something to make it so, you violated it.

**G-0b. AFTER A FAILURE, REBUILD TO THE ENTRY STAGE BEFORE RUNNING ANYTHING ELSE ON THAT GUEST.**
*(owner, 2026-08-30: "you needed to rebuild it to original state, all subsequent results on it are
contaminated")*

Writing the failure off is not enough to resume. The guest carrying a fault — and any guest you
touched while diagnosing one — is **out of service** until it is rebuilt to its entry stage (R2/R4
reclone, or a fresh install). Until that rebuild, **every subsequent result on that guest is
`INVALID-CONTAMINATED`**, and the protocol already says so for goldens: *"either rebuild it or mark
every cell derived from it INVALID-CONTAMINATED (H5)"*. This extends the same rule to any subject.

**Contamination is NOT judged by whether the change plausibly affected the later cell.** "I only
changed proxy settings, that cannot affect a rendering benchmark" is precisely the reasoning the
verdict exists to forbid — it is unfalsifiable, it is always available, and it is how a contaminated
run gets reported as clean. If the guest was mutated and not rebuilt, the later results are
contaminated. Full stop.

*Failure that produced this gate:* after the U1 scan failure I mutated `win11-tpl` (SoftwareDistribution
rename, proxy planes) and `win10-tpl` (proxy planes, `setieproxy`), restored *some* of it by hand, and
then ran the entire P4 rendering battery, the BENCH suite and the P5 safeguard cells on `win10-tpl`
without rebuilding it. Those results are now contaminated — not because proxy settings plausibly
affect a scroll benchmark, but because the subject's state was no longer the entry stage and I cannot
prove what else changed.

**G-2. No causal claim without the REVERSE control.** A root cause is established only when the
defect has been removed AND re-introduced, both observed. One positive after one change is a
correlation.
*Failure:* I added a proxy plane, the scan worked once, and I published that as the root cause and a
ship-blocking verdict. A later run scanned successfully with the plane absent — falsifying it. I
applied seen-to-fail to every product check and exempted my own diagnosis.

**G-3. The output that DISAGREES is the finding.** When an instrument prints something that does not
fit the hypothesis, stop and explain that line before continuing. Writing "…so this does not block
the conclusion" about a disagreeing line is the tell that the conclusion was chosen first.
*Failure:* `bitsadmin` printed *"There's a policy in effect that disables the storage of proxy
settings per user."* I quoted it and glossed it as "not an argument against the fix". It was the
statement that the fix was unnecessary — `ProxySettingsPerUser=0` already makes HKLM cover SYSTEM.
The refutation was inside output I had pasted into the record myself.

**G-4. Any claim about project history REQUIRES a citation.** Before writing *never tested*,
*unproven*, *not run*, *missing*, *known gap*, or *first time*: `grep FINDINGS.md` and the ledger,
and put the line number in the text. **An uncited claim about what this project has or has not done
is a fabrication**, however plausible.
*Failure:* I wrote that download+install was untested. `FINDINGS:15097` records `19045.2965 ->
19045.6456`, `FINDINGS:8249` a Win11 UBR move, `FINDINGS:9548` CBS `state=112`. All predate me.

**G-5. Read the DESIGN before proposing a change to it.** Before suggesting a fix, grep for the
decision that produced the current behaviour. A component that looks missing is often removed on
purpose.
*Failure:* I predicted an accepted "known gap" was my defect and implied re-enabling `Install-ViaWU`.
`FINDINGS:13513` records the content-class router that deliberately gates that path off for
netvm-free guests, and states the self-contained route already fixed that class. I was arguing to
reinstate a discarded architecture.

**G-6. A defect report states the defect and its measured blast radius. It does not propose scope
changes.** "Should we still support X?" is an owner decision and requires evidence about X, not about
a bug near it.
*Failure:* a one-line omission became "maybe cut Windows TemplateVM support", invented from nothing.

**G-7. A negative requires a detector seen to fire IN THAT SESSION.** No "X did not appear" from an
instrument that has not been shown detecting a known-present X in the same run. Absent that, the cell
is `INVALID-VACUOUS`.
*Failure:* I reported "the toast never rendered" from a narrow, unvalidated, point-sampling probe.
The owner was watching the screen; the toast was there.

**G-8. Once a finding is RECORDED, restate it from the record — never re-derive it in conversation.**
Re-deriving produces a new framing each time and destabilises settled work.
*Failure:* three different framings of the same update-path facts in consecutive messages, after the
finding had already been written to FINDINGS and the protocol.

**G-9. Verify the probe before believing the probe.** A probe that reads the wrong key, filters too
narrowly, or names a variable PowerShell already owns returns a confident wrong answer.
*Failures, all in one campaign:* `$pid` (a PowerShell automatic) made every window report the
sampler's own process; a `bitsadmin` state was first read from the string values instead of the
`DefaultConnectionSettings` blob; `Marshal::SizeOf` silently returned nothing and `[int16]` of it
produced a plausible 124.

### 0.10 RUNBOOK — P3 (updates), step by step

*Subject: a TEMPLATE (netvm=''). Every step names its command, its expected output, and what to do
when it fails. Part II §7 remains the authority on what each cell means.*

**P3-1. Own the proxy backend.** The guest reaches the internet only through
`qubes.UpdatesProxy`, which on this rig is served by THIS qube: `/etc/qubes-rpc/qubes.UpdatesProxy`
is a symlink to `/dev/tcp/127.0.0.1/8082`, and a tinyproxy runs there **permanently** from
`/home/user/updates-tinyproxy.conf`.

    ss -ltnp | grep 8082          # expect: tinyproxy LISTENING

*It is standing rig infrastructure — a long uptime is normal.* **Do not kill it.** If you need a
clean evidence window, append a marker line to `/home/user/updates-tinyproxy.log` and slice from
there; if you need `LogLevel Connect`, change it in the canonical config and restart in place.
*On absence:* start tinyproxy from the canonical config — never invent a second proxy on another port.

**P3-2. U0 — deploy state, read-only.** Push and run:

    tools/qtest pushrun guest/wu-verify-stack.ps1        # hashes of the deployed stack
    tools/qtest pushrun <task/policy probe>              # task shapes + policy + offline baseline

*Expect:* `QubesWindowsUpdateScan` boot PT2M + PT6H repeat, SYSTEM, `-Scheduled`;
`Run`/`Download` with **no triggers** and no `-Scheduled`; `QubesAutologonGuard` boot PT30S;
`NoAutoUpdate=1`; `ExcludeWUDriversInQualityUpdate=1`; no relay process; winhttp Direct.
**Compare the stack hashes against the SHIPPED PAYLOAD, not the repo** — the build rewrites LF to
CRLF, so a raw repo comparison always "differs" (measured: 4 of 5 files, purely line endings).

**P3-3. U1 — availability to dom0.** Kick the scan **detached**, never through a live pushrun:

    tools/qtest run 'cmd /c schtasks /run /tn QubesWindowsUpdateScan'

then poll `C:\ProgramData\Qubes\update-status.json` every 30 s. *Expect* phases
`ensure-proxy → sync-revocation → scan → done`, `Sync-Revocation: 3/3 CTLs`, `available[]` populated,
and — the dom0-observable half — `qvm-features <vm> updates-available` set.
*The status file's fields are `testsigning_active` / `installed_qwt_count`, and PRECONDITION lines
carry a `[INFO]` timestamp prefix while the RESULT trailer does not — do not anchor a grep with `^`
on the former.*

**P3-4. On a scan FAILURE — this is where a whole campaign was lost.** **G-0 applies: write the
failure off BEFORE touching anything.**
1. Record the H5 verdict line and copy out `update-status.json`, the agent log, the relay logs and
   your own proxy log slice.
2. **Change nothing on the guest.** No `SoftwareDistribution` rename, no proxy-plane experiment, no
   reboot, no "just try one thing".
3. **Clone the guest**, and diagnose on the clone with the reverse control in both directions (G-2).
4. Per **G-0b** the original is out of service until rebuilt to its entry stage; anything run on it
   before that rebuild is `INVALID-CONTAMINATED`.

*Attribution aid, since both ends are yours:* if the CTL cabs appear in the proxy log but nothing
else does, the WU COM searcher never dialled. **Do not "fix" that by re-enabling `Install-ViaWU`** —
`FINDINGS:13513` records the content-class router that gates it off for netvm-free guests
deliberately (G-5).

**P3-5. U2 — the class matrix, witnessed by what CHANGED.** Run the agent with `-Action scan` on one
guest of each class and read the new agent-log lines:

| class | expect |
|---|---|
| TemplateVM | classified from qubesdb, runs the proxy pass |
| AppVM | `not a template; updates are the template's business`, exit 0, **relay count 0**, `ProxyEnable 0` |
| StandaloneVM + netvm | `updates ITSELF via Windows Update`, **`NoAutoUpdate` REMOVED**, relay 0 |

Then the binding half: **classification must be proven on a COLD BOOT**
(`wu-boot-acceptance-arm.ps1` → reboot → `wu-boot-acceptance-check.ps1`), because a live re-run
clears the QdbDaemon startup race the cell exists to catch. *Expect* `rebooted:true`,
`class_correct:true`, `saw_empty_class:false`, `qdb_retry_evidence:true`.

**P3-6. Before recording anything as "we don't ship X":** run the same query on a **StandaloneVM with
a netvm**, with `IsInstalled=0` and **no `Type` filter**. If stock does not offer it either, it is
**not a defect** (§7, the standalone control). Dynamic Updates are already settled this way.

---

### 0.11 RUNBOOK — P4 (rendering + benchmarks), step by step

**P4-1. DISARM THE UPDATE SCAN. First. Always.** Nothing else in this part may run until this
passes — see G-0c.

    mgmt/harness/p4-run.sh <vm>      # does the disarm, ASSERTS it, and re-enables on exit

*Expect:* `SCAN_AFTER state=Disabled`, `RELAY_AFTER 0`, `DISARMED True`.
*On failure:* **run nothing.** An unmeasured cell beats a bad number.
**The trap:** cold-booting a guest and benchmarking within a few minutes lands the workload on the
boot+PT2M scan. Measured 2026-08-30 — booted 17:52, scan due 17:54, BENCH started 17:53, guest
wedged mid-benchmark, every number void.

**P4-2. Confirm the subject.** `golden.sh fixture <vm>` (or `verify` for a sealed golden), agent
hash == manifest, and tracing on via `qvm-features <vm> service.gui-agent-debug 1` — **never a
registry poke**.

**P4-3. BENCH-2 tripwire.** `guest/cpu-bench.ps1 -IdleSec 120`, **three runs**.
*Expect:* idle CPU ≈ 0.08 s per 120 s or better (pre-fix control: 3.95 s).

**P4-4. BENCH-1.** `tools/bench-agent.sh <label>` ×3, then `instrumentation/bench-phases.sh <label>`.
**Scroll p50 is the only metric that may carry a verdict**; compare ONLY against the recorded
canonical baselines (4.3.10 quiet-host set, 374–436 µs) — never an intra-day build. **Drag p50 is
bimodal and gates nothing.** Commit the raw `instrumentation/bench-*.txt` files.
*If a run returns nothing:* stop the part, preserve the guest (G-0), and check whether the agent is
still alive before assuming a slow number.

**P4-5. Pick the capture instrument PER CELL (RND-0b) — this is not a judgement call:**

| subject | instrument |
|---|---|
| managed windows (RND-6/7/8, Start's "nothing maps") | `qtest shot` window count |
| **override-redirect** (menus RND-3, toasts RND-4) | **`fullshot` + `winshot.py`** — `qtest shot` is structurally blind |
| wobble / drag replay | QGAPROTO trace, never cross-VM capture |

A `qtest shot` negative on an o-r subject is `INVALID-VACUOUS`. **Whole-desktop captures are read and
DELETED in the same step** — they contain the owner's entire desktop.

**P4-6. Drive shell UI as the interactive USER, not over qrexec (RND-0c).** qrexec runs as
`NT AUTHORITY\SYSTEM` here; toasts, Start and shell flyouts are per-user and a SYSTEM-fired one
renders for nobody.

    schtasks /create /tn <t> /sc once /st 00:00 /ru user /rl LIMITED /it /f /tr "<cmd>"
    schtasks /run /tn <t>

**P4-7. Prove the detector before citing a negative (G-7).** `guest/surface-watch.ps1 -SelfTest`
must report `detector_fires:true` **in the same session**; then sample continuously
(`-DurationSeconds N -IntervalSeconds 1`) and read `-Summary`. `coverage_gaps` must be empty.

---

### 0.12 RUNBOOK — P5 (safeguards), step by step

**P5-1. Read SG0 and obey it.** **Never set `service.gui-fullscreen`.** Every arm needing it ON is
owner-attended and is listed `ATTENDED-PENDING` — never silently dropped.

**P5-2. Disarm the update scan** exactly as P4-1. The SG cells drive the same qrexec/SendInput load.

**P5-3. ESTABLISH CONTAINMENT — after the agent settles, and verify it against the AGENT.**
The agent re-applies dom0's geometry at startup (`RESREQ … src=lastapplied`,
`RESDRIFT … adopting the actual mode`), so **a resolution set before a reboot does not survive it**.

    # boot, wait for the agent, THEN set a sub-host mode and read it back
    tools/qtest run '<read Win32_VideoController>'          # the guest's view
    <agent log>  HandleXconf / SetVideoMode / ResolutionAdoptCurrent   # the AGENT's view

Both must agree on the sub-host size **before any fullscreen-gate probe is sized**. Measured
2026-08-30: probes were built for 1600x900 while the agent had re-adopted 5120x1440, so they were
31% of the screen, the gate was never exercised, and the cell was `INVALID-PRECONDITION` — while
looking exactly like a serious gate failure.
**Use `guest/set-resolution.ps1 -Contain`** (fixed 2026-08-30). It scans `\\.\DISPLAY1..8` for the
device reporting a current mode, cross-checks it against `GetSystemMetrics` before trusting any
read, refuses a size the adapter does not offer, and verifies by read-back. Then confirm the AGENT
followed, in its log: `SendWindowConfigure … hwnd=0x0,w=<W>,h=<H>` and `A6CONFIGURE window 0 -> WxH`.

Two corrections to what this section said before, both measured on win10-p46:
* The script was **not** broken by DEVMODE marshalling. It passed `lpszDeviceName = NULL`, and on
  these guests the desktop is on **`\\.\DISPLAY2`** — `DISPLAY1` publishes 29 modes and has NO
  current mode. `EnumDisplayDevices` enumerates nothing here, so the wrong device was invisible.
  The prior "fix" hard-coded `dmSize=156` to reconcile `Marshal::SizeOf` with `Marshal::OffsetOf`;
  that silenced a symptom and left the wrong argument in place.
* It is **not** a session problem either. qrexec runs as SYSTEM but in **session 1 on WinSta0**
  (`sessionId=1`, `winsta=WinSta0` measured through both qrexec and `schtasks /ru user /it`), so
  display APIs and window mapping work from `qtest run`. `guest/run-as-user.ps1` is for running as
  the USER PRINCIPAL (toasts, Start, HKCU) — not for display work.

*`tools/qtest resize` is NOT the fallback it was described as: on 2026-08-30 it returned
`GEOM ok=0 err=no_window` while `local.WinScreenshot` returned 2 windows for the same VM in the same
second. That string named a guest condition for a dom0-side tooling fault; the service now reports
`empty_client_list` / `no_window` / `geometry_unreadable` separately (`dom0/10-install-resize-service.sh`
v5), but **dom0 must reinstall it** before the new strings appear.*

**P5-3b. THE CAPTURE PATH MUST BE PROVEN ALIVE IN THE SAME MEASUREMENT.** Run
`mgmt/harness/p5-run.sh <vm>`, which encodes P5-3 through SG9. Three harness defects were found on
2026-08-30 by grading a cell against the agent's own log instead of trusting the harness; each is
now structural, and each would silently reappear in a hand-run cell:

1. **A fixed settle is not a readiness signal.** An 18 s sleep is shorter than PowerShell's runtime
   `Add-Type` C# compile, so the probe window did not exist when the shot was taken, `qtest shot`
   returned an empty tar, and the harness read that as "the gate denied it". **SG3 was scored FAIL
   against a window the agent had MAPped** (`SendWindowMap ... ovr=0, vis=1, 1586x893`). Wait on the
   probe's own `"visible":true` output, then sample dom0 repeatedly.
2. **"Nothing mapped" from an unvalidated capture path is not a result.** A small Notepad now stays
   mapped for the whole run; **a cell whose shot cannot see the control is `INVALID-INSTRUMENT`,
   never a pass.** Without this, a blind tool manufactures safeguard passes.
3. **Count the PROBE, not the windows.** Launching via `cmd /c start "" cmd /c "... > file"` gives
   the redirection a console window, and that console (979x512) is itself mapped — the harness
   counted it and reported SG2 and SG4 as **FAIL, "a screen-sized window reached dom0"**, when the
   only extra window was its own launcher. Launch with `powershell -WindowStyle Hidden` and
   `-OutFile`, and identify the probe **by size** (>=93% width, >=88% height of its reported rect;
   the agent trims the invisible resize border, measured 1600x900 -> 1586x893).

**The probe is `guest/fsgate-probe.ps1`.** It sets exact styles, reads them BACK with
`GetWindowLong`, and prints hwnd/style/exstyle/rect/covers_screen as the cell's vacuity proof. On
the borderless arm `WS_SYSMENU|WS_EX_APPWINDOW` is load-bearing: without it `IsPopup()`
(`agent/gui-agent/main.c:1221`) classifies the window override-redirect, so it is denied by the
**Mode 1** branch and the cell passes without ever reaching the Mode 2 gate it exists to test.

**P5-4. Run the "must not map" cells** (SG1 Mode-1, SG2 borderless, SG4 override-redirect, SG9
Start, SG10 furniture). For each, the verdict needs **two** things: nothing mapped in dom0 **and**
the agent's own deny line proving the surface existed and was evaluated. A silent absence is
`INVALID-VACUOUS`.

**P5-5. Run the "must map" cells** (SG3 maximized captioned window, SG7 toasts). These put windows on
the OWNER'S DISPLAY — containment from P5-3 is what keeps them bounded, and a cell that maps at or
near host size without it will steal focus mid-work.

**P5-6. SG6 and its fail-proof.** Positive: `AutoAdminLogon=1`, **`AutoLogonCount` ABSENT**, registry
`DefaultPassword` absent (the credential is the LSA secret), guard task Ready, windows map after a
cold boot. Fail-proof: `mgmt/harness/sg6-failproof.sh <standalone>` — control first, then disarm
`AutoAdminLogon` **and** the guard task, cold boot, expect **qrexec answering while ZERO windows
map**, then re-arm. **StandaloneVM only** (SG0.8): an AppVM reverts HKLM before the reboot.

**P5-7. Fill in the SG11 matrix** (safeguard × {positive, negative control, fail-proof}). **A blank
fail-proof cell renders that safeguard's PASS `UNPROVEN` in every citing report** — record it, do
not quietly upgrade it.

---

### 0.13 RUNBOOK — closing a campaign

**C-1.** `tools/campaign-verdict.sh <verdicts.tsv>` and paste its output as the summary's first
block. COMPLETE requires zero FAIL / INVALID / INCONCLUSIVE / BLOCKED **and** every PASS carrying a
fail-proof entry in `mgmt/harness/instrument-proofs.md`. Anything else is **EXECUTED WITH GAPS**.
**C-2.** Restore or rebuild every subject; remove transient fixtures and their receipts.
**C-3.** Record pool % before and after; verify both goldens still match their seals.
**C-4.** Append dated findings to FINDINGS.md, and suffix any wrong verdict `RETRACTED:<reason>`
**in place** — never delete a line.

### 0.8 Hard prohibitions (each row is scar tissue)

| Never | Because |
|---|---|
| Write a parallel runner / hand-rolled wait | H0/H2. The harness has three-exit waits; a bare `sleep N && continue` is prohibited outright. |
| Start a second Windows guest | H3.6. Concurrent runs have destroyed each other's results; three 8 GB guests starved qubesd. |
| Boot, log into, or "just check" a golden | It contaminates every clone made from it afterwards. Use a churn qube. §0.4. |
| Grade a cell whose payload was not Gate-0 verified | A whole cell once ran against the commit BEFORE the fix under test (2026-08-29, `f777bec`). |
| Run a cell with no P0 preflight | 2026-08-30: cells ran with none; a precondition discovered failed afterwards voids the cell (`INVALID-PRECONDITION`). |
| Read a drive letter as "the release ISO" | An answer disc left attached from provisioning is picked up instead. Find media BY CONTENT (§0.5). |
| Use `attach --persistent` to attach now | It is an alias for `assign --required` = applied at NEXT START; three attempts lost 2026-08-30. Plain `attach` on a running guest; `assign --required` before start when the disc must survive a reboot. |
| Gate anything on `VERDICT=DESKTOP` | The classifier called a "PC doesn't meet requirements" Setup dialog DESKTOP, twice. It is advisory; READ the image (§0.6b). |
| Build a Win11 stick without `UNATTEND=...autounattend-win11.xml` | No LabConfig bypasses -> Setup refuses to install on a Qubes HVM (§0.6b). |
| `pushrun` a guest that may have no logged-on session | `qtest push` is `qubes.Filecopy`, whose destination is `QubesIncoming` under the **logged-on user's** Documents; with no session `GetFolderPath('MyDocuments')` is empty for SYSTEM and the copy fails **producing no output at all** — indistinguishable from "the probe found nothing". Measured 2026-08-31: the SG6 fail-proof's defect probe AND its re-arm both used `pushrun` after disarming autologon, so the re-arm never ran and the subject was left at LogonUI. Use inline `tools/qtest run` for anything at the sign-in screen, mid-update, pre-autologon, or with autologon deliberately off. |
| Treat an empty `local.WinScreenshot` result as decisive, in EITHER direction | It exits 1 with an empty body **both** when zero windows are mapped and when the service itself fails, writing the distinction to a stderr qrexec does not forward. Reading it as "zero windows" lets a blind capture path manufacture a safeguard pass; gating on it as "instrument broken" refuses every legitimate zero-window result (both shipped, hours apart, 2026-08-30/31). Decide on a positive assertion — a control window that must be visible, or in-guest state like `query user` — and record the count as corroboration. |
| Sleep a fixed interval and call it settled | 2026-08-30: an 18 s settle was shorter than PowerShell's runtime `Add-Type` compile; the probe window did not exist yet, the shot came back empty, and the harness scored **SG3 FAIL against a window the agent had MAPped**. Wait on the thing's own readiness output, then sample. |
| Reinstall Windows when a sealed golden exists | Clone is 1.8 s, reprovision is 17-20 min and resets netvm/timeout/tags. Done three times in one night (§0.7b). |
| Build a delivery mechanism before checking for a Qubes knob | An entire custom stick was built parallel to `qvm-start --install-windows-tools` (§0.7b). |
| Record your own failed attempt as a product property | "stock QWT does not install" was written after MY setup failed; stock installs reliably. A wrong record outlives the session. |
| Treat silence as absence | A watcher that never sampled is `INVALID-VACUOUS`, never PASS (H2 vacuity gate). |
| Trust a `0 passed, 0 failed` matrix summary | An unset `CELLS` matches no selector; the run does nothing and still prints a normal-looking footer (§0.9.4). |
| Reprovision (R3) where R0/R1/R2 reaches the entry stage | Protocol rule (§1.2, §10): ~20 min each, and it destroys the qube's history. |
| Grade a guest carrying `C:\qubes-prime\fired.mark` | It has had arbitrary SYSTEM code run in it by a primer job. Only a cell that DECLARES it was primed may grade one (§0.7c). |
| Write a second route to a result the rig already reaches | The stock install already had a working route; a parallel one was written for the upgrade cell, inherited none of its workarounds, and returned 1603 (§0.7c, FINDINGS 2026-08-30). Change the one variable instead. |
| Act on a guest an orchestrator already owns | `reprovision-usb.sh` holds `/tmp/reprovision-<vm>.lock` and restarts the guest on every halt. Two ad-hoc monitors were added beside it and one rebooted a guest mid-MSI. Check `fuser -v` on the lock first; watchers must be PASSIVE. |
| Report the status of `cmd \| tee log` | You get **tee's** exit code. A refused reprovision was reported as success this way. Use `PIPESTATUS`. |

### 0.9 Where the scripts and this protocol disagree today (verified against source 2026-08-30 — fix at P0-PRE, do not paper over)

1. `matrix.sh reclone` sets `qrexec_timeout=600`; the protocol standard is 6000 (§2.5, §12
   note 5). P0-PRE.2 still owed.
2. `cell_fresh` and `cell_upgrade_stock` construct their preconditions by UNINSTALLING, which
   P1.0 forbids for protocol-grade verdicts ("preconditions are never constructed by
   uninstalling — QWT *is* the qrexec agent"; it cost `win10-u10`). They also invoke helper
   scripts from a SESSION TMP path (`guest/uninstall-qwt.ps1 [FIXED 2026-08-31 — was a session-tmp path]`,
   `guest/count-qwt.ps1` [FIXED 2026-08-31]) — garbage-collectable, the exact path class H0 banned for the wait
   library. Promote both scripts into the repo (P0-PRE.8) before relying on the `*-fresh` /
   `*-stock` selectors; protocol-grade C1/C2 and ST1 still enter via the stick (R3+ST0/ST0T,
   stock stick loop11).
3. A missing `$MATRIX_WORK/dl/qwt-full-package/gui-agent.exe` does not stop matrix.sh: `ASHA`
   ends up empty and the "installed agent == release binary" check becomes vacuously green.
   §0.2 step 5's `ls` is the guard.
4. An unset `CELLS` defaults to the string `seeded`, which matches no `case` arm: a 0-cell run
   with a normal-looking summary. Always set `CELLS` explicitly.
5. The matrix's install cells write into `win10-tpl`/`win11-tpl`: a campaign consumes the
   standing ST3 templates. Re-establish ST3 with R4 (`mgmt/clone-to-template.sh`) afterwards
   when standing template/AppVM stages are needed.
6. ~~`mgmt/goldens/` is empty~~ — **RESOLVED 2026-08-30.** Both pristine bases are sealed and
   verify intact. `matrix.sh`'s `G10`/`G11` default (`*-goldr`) is also gone: it pointed at goldens
   carrying the candidate, so "fresh"/"upgrade" cells were reinstall cells. Naming the entry is now
   mandatory, and it is checked as a sealed golden OR a campaign fixture (§0.4).
7. `reprovision-usb.sh` leaves `qrexec_timeout=300` and the answer stick assigned
   `--required` — §0.7's reset-trap block undoes both.
8. `tools/qtest`'s baked-in fallback target `win-idd-test` is a dead name by design (the tool
   refuses it loudly and prints the tagged roster); the true no-default guard lives in
   e2e-lib.sh. Export `QTEST_VM` explicitly in every context regardless.

---

# Part II — Reference

Everything below is the authority on cells, stages, and rules. The runbook (Part I) tells you
what to type; nothing here was weakened when it was added.

## 1. How to run one part (executable skeleton: runbook §0.3; whole-campaign order: §0.2)

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
| **ST2G** | fixture ours | An accepted release of ours, installed into a clone of a pristine base by `prime-run.sh`. | `golden.sh fixture` passes (receipt present, base seal still verifies) + the installer's own `PRECONDITION` line confirms the version the cell claims. | **TRANSIENT** — built on demand, removed at campaign end (owner 2026-08-30). Never sealed: a golden built from the candidate turned every upgrade cell into a reinstall cell. |
| **ST2NP** | ours, no PV disk | Current release installed `/nodisk` → `pv_boot_disk=false`. Enables C8. | ST2 proofs + PRECONDITION `pv_boot_disk:false`. | Transient. |
| **ST3** | template ours+latch | Golden → `mgmt/clone-to-template.sh` with `PRIME_NETVM=latch`, `XENVIF_PKG` set. Script self-verifies: latch readback across a boot cycle, net-identity scrub residue=0, xenvif sha256 in DriverStore. A template failing any gate is not shipped. | Script gates + NET-1 attestation. netvm='' **forever**. | **Standing** (`win10-tpl`/`win11-tpl`). |
| **ST3A** | AppVM fresh boot | AppVM boot off ST3; volatile root ⇒ bit-identical every boot. | NET-1 attestation. | Free, infinitely repeatable (R0). |
| **ST4** | network-bound AppVM | ST3A + live netvm attach. **Transient by design** — every boot re-runs the PV-NIC install; that one-boot completion *is* the acceptance property, not a state to park. | NET-2 acceptance. | Never parked. |
| **ST5** | post-update | Serviced image after a dom0-driven WU pass. | U3 §7 post-boot verdict. | Transient: promoted to new golden (owner sign-off) or reverted (R1) within the two-shutdown window. Never parked long-term (+5–15 GB drift). |

**Locale is part of pristineness.** Win10 media is `Win10_22H2_EnglishInternational` = **en-GB**; `build-answer-stick.sh` defaults en-US; a mismatch drops Setup silently to the interactive locale picker (tell: guest CPU ~1 s/40 s instead of ~45 s/40 s; proof: screenshot). Every Win10 stick build passes `LOCALE=en-GB`. Win11 24H2 eval media is en-US and matches the default — verify once per new media anyway.

### 2.2 Qube → role mapping (current allocation; names are NOT fixed — policy is tag-based, so create and tag new qubes freely)

| Qube | Class | netvm standing | Role / standing stage |
|---|---|---|---|
| `win10-base` | StandaloneVM | — | **ST0.10** sealed golden — pristine Win10 22H2, no QWT, testsigning OFF, primer hook. The ONLY Win10 golden. |
| `win10-u10` | StandaloneVM | fw-net | **churn** — sole Win10 R3 target; carries transient ST0/ST1/ST2 within campaigns |
| `win10-tpl` | TemplateVM | **'' always** | **ST3.10** |
| `win10-app` | AppVM | fw-net | **ST3A.10 / ST4.10** network vehicle |
| `win11-base` | StandaloneVM | — | **ST0.11** sealed golden — pristine Win11 24H2 Eval, no QWT, testsigning OFF, primer hook (proven 2026-08-30). The ONLY Win11 golden. |
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

### 2.7 Media / loop inventory (verify before every R3; stick construction runbook: §0.6)

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
8. Promote the helper scripts `matrix.sh`'s `cell_fresh`/`cell_upgrade_stock` invoke from session
   tmp (`guest/uninstall-qwt.ps1 [FIXED 2026-08-31 — was a session-tmp path]`, `guest/count-qwt.ps1` [FIXED 2026-08-31]) into the
   repo — same defect class as item 1, found 2026-08-30 (§0.9.2); until then those selectors
   depend on garbage-collectable files.

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

**Payload delivery — two routes, both legitimate (added 2026-08-30, CORRECTED same day; executable form: runbook §0.5).**

*Correction first:* an earlier version of this paragraph said the release must never be attached as a cdrom for an install cell. **That was wrong and is retracted.** Attaching the QWT ISO and running its installer IS a standard path — it is how a user actually installs QWT, so it is the realistic route and must stay covered. The failure that produced the bad advice was mechanical, and is worth recording because it is silent:

> `qvm-device block attach --persistent` is documented as **"Alias to `assign --required`"**. So `--persistent` on *attach* is not an attach at all — it is an assignment, which is applied **at the qube's next startup**. Against a running guest it therefore succeeds and changes nothing the guest can see; the ISO simply never appears. Worse, once assigned, a subsequent plain `attach` is refused with *"already assigned"*, so the obvious retry also fails. Correct usage: **`qvm-device block attach --ro --option devtype=cdrom <vm> <backend>:<devid>`** (no `--persistent`) to attach to a *running* guest, and `assign --required` *before* start when the disc must survive the install's own reboot. Verify by content in-guest, never by assuming a drive letter.

*Two different situations, do not conflate them (2026-08-30).* On an **installed, running Windows** an attached cdrom is perfectly visible — it has the PV drivers, and attaching the QWT ISO and running its installer is the standard way QWT is installed, including stock QWT onto a fresh VM. That is Route A and it is fully supported. The cdrom-invisibility caveat in `mgmt/reprovision-usb.sh` applies ONLY to **Windows Setup / WinPE**, which has no Xen PV drivers, which is why OS provisioning uses an emulated USB answer stick (WinPE does carry USBSTOR/USBXHCI inbox) rather than a second CD. Installing an OS and installing QWT onto a running guest are different problems with different media rules.

*Route A — ISO/cdrom (the user-realistic path).* Attach the release ISO, run `install.cmd` from it. Assert the disc's `MANIFEST.json` `source.driver_repo_commit` equals the release under test before running anything, and locate it by content (a drive carrying both `install.cmd` and `MANIFEST.json`) rather than by drive letter — an old answer disc still attached from provisioning will otherwise be picked up instead.

*Route B — `qtest push` (what `mgmt/harness/matrix.sh:push_payload` implements).* One tarball, pushed as a single file; `qtest push` is `qvm-copy-to-vm`, so it lands in `C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\` (`INC`). Extract guest-side into a per-cell directory (`rmdir /s /q C:\<dir>`, `mkdir`, `tar -xzf`), requiring its `EXTRACT_OK` echo — a stale directory from a previous cell is grading contamination. **Retry 3x with 20 s backoff keeping stderr** (H3.8): the first attempt fails in about a second on a session that has only just answered `QREADY` (`rc=46`).

Pristine-start cells are stick-orchestrated instead (no qrexec exists yet). Pin the release for the whole campaign rather than gating against `HEAD` — `HEAD` moves on every commit, so a campaign spanning any commit silently changes the artefact it gates against, which is what "single package for all tests" forbids.

**Entry-image provenance is a P0 assertion, not an assumption (added 2026-08-30).** Every install cell `reclone`s from the image named by `G10`/`G11`, so that image's state is inherited by every clone made from it. It must pass ONE of the two custody checks — `golden.sh verify` (sealed golden) or `golden.sh fixture` (campaign fixture with a receipt whose base seal still verifies). On 2026-08-30 the Win10 golden was used all evening as a scratch guest - agent binary hot-swapped twice, xencons side-loaded by hand, `debug` toggled, Windows Update enabled then disabled, private volume extended mid-life, repeated hard restarts - and cells were then cloned from it. Before any campaign, assert the golden matches its recorded stage manifest (§2.4); if it does not, either rebuild it or mark every cell derived from it `INVALID-CONTAMINATED` (H5). Diagnostic work belongs on a churn qube, never on a golden - and a golden that has been touched is no longer one, whatever its name says.

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
| ● **C11** | template-prime / class-skip | P | template: piggybacks R4; standalone control: any ST2 | P0-CORE | piggyback / 10 min | template: `pvnic_prime:seeded`, `pvnic_latch:armed` (NICS=1 readback); standalone: **also** `pvnic_prime:seeded` + `pvnic_latch:armed` — **corrected 2026-08-30.** This row used to expect `skipped-non-template`, which predates decision **D1** ("the latch is ALWAYS ON, StandaloneVMs included", owner 2026-08-29; the templates-only gate was removed in `cace671` and the class is read for the log line only). D1 was recorded as *not yet validated on a built package* — it is now: measured on `win10-c1` (StandaloneVM) and `win10-tpl` (TemplateVM), both `seeded`+`armed`. A standalone reading `skipped-non-template` would today be a REGRESSION, not a pass. **Downstream acceptance (zero-reboot attach, transfer+rx_bytes) is owned by NET-2/NET-3 — cross-referenced, not duplicated** |
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
| **NET-6** | **First-vif premature-reboot dialog** (eligibility-gated). Subject: **persistent-root guest that has NEVER had a vif** — i.e. the churn qube straight off the C1 chain, kept `netvm=''` since install (this sequencing avoids a dedicated reprovision — requirement 7; an AppVM cannot be the subject, nor any recycled guest). Probe eligibility first: **XENVIF enum absent/empty including ghosts** (`-IncludeHidden`), and zero `XENVIF\*` PnP devices. **Corrected 2026-08-30:** this used to also require *no* `DEV_VIF` in the XENBUS enum. That is unsatisfiable on any guest carrying our package — the PV-NIC latch SEEDS `Enum\XENBUS\VEN_XP0001&DEV_VIF` as a veto-bypass key, which NET-1 already documents as *correct on a latched guest and not evidence that a vif was seen*. Measured on `win10-c1`, a guest that had never had a vif: `XENBUS_KEYS` contained `DEV_VIF` while `XENVIF_ENUM` was `<absent>` and ghosts were 0. The XENVIF side is the real discriminator; the XENBUS key is not. Steps: `-SelfTest` → sampling watcher with ≥20 pre-attach samples (**armed before the vif, or the negative is meaningless**) → attach → `-Summary`. **Accept:** `samples>0, dialogs_seen=0, blind_samples=0 (session-0 self-reports blind ⇒ void), coverage_gaps=[]`. Ref: ours 0/69 clean; STOCK first-logon DOES raise it (csrss/#32770/"Xen") and a dialog predating our installer's first log line is attributed to stock | C1-exit (ST2 on churn, never-vif) → ST2+vif | C1, fw-net for vif plumbing | 30 min |
| **NET-7** | **Standalone immediate live attach, ZERO reboots — VERIFIED PASSING 2026-08-29.** Carries NET-2's criteria verbatim on a StandaloneVM. Measured on `win10-u10` with the applier confirmed present first: PV NIC bound in **25 s**, `LastBootUpTime` byte-identical (zero reboots), 49 watcher samples with **0 dialogs**, emulated NIC unplugged, health-check `ok=True`, 1.25 GB rx. **Precondition that makes or breaks this cell:** assert `TASK QubesPvNic` + `APPLIER_SCRIPT` present BEFORE attaching — every earlier "hotplug is broken" result was a guest with no applier (pre-`cace671` package, or a template cloned from one), and that mistake cost three runs. The pre-fix PnP problem 14 state is this cell's seen-to-fail negative control. | ST2 standalone (latched) → ST4 | P0-CORE, NET-0, NET-1 | 20 min, 0 GB |
| **NET-8** | **PV throughput benchmark against a fast CDN.** SUPERSEDED 2026-08-29 (owner: "local-only benchmark is not needed in this case. you may benchmark against reasonably fast cdn") — no local endpoint required. Measured reference: `speed.cloudflare.com/__down?bytes=26214400` → **258.2 Mbit/s** (26,214,400 B in 0.81 s, adapter rx delta 29,054,236) versus 3–5 Mbit/s from a Debian mirror, which is why a mirror must never be used for this. Note a 100 MB request returns 403 (Cloudflare caps `__down`), so 25 MB is the working size. **Accept:** ≥3 runs, median well above mirror-class rates, every run cross-checked against the XENVIF adapter's own rx delta. A local endpoint remains blocked by the netvm inter-VM drop (tested: guest firewall was already accept-all, an explicit accept rule changed nothing, zero requests reached the listener) — but it is no longer needed. | ST4 → ST4 | NET-2, fw-net up | 20 min |

**Vacuity ledger** (each produced a false verdict at least once — graders must check against it): "no dialog" on `netvm=''`; "no dialog" with watcher armed after attach; any network grade <90 s; "physical NIC attached" (loopback); "no traffic" from gateway ping; "first-vif OK after two boots"; byte deltas on an unspecified adapter; throughput from an internet download; "guest unkillable/restarts forever" (= queued qrexec, drain per §2.5).

---

## 7. P3 — Updates (dom0-owned Windows Update path)

Sources of truth: `guest/qubes-windows-update.ps1`, `guest/wu-update.ps1`, `guest/install-updater-agent.ps1`, `dom0/14-install-qvm-windows-update.sh`, guest-introspection skill. Standing rules: roster names only; **serial** — never concurrent with a benchmark/rendering part, and before any BENCH part check `QubesWindowsUpdateScan`'s next run (6-hourly + boot+2 min) — a mid-benchmark scan raises the proxy and churns qrexec (wedge trigger); **detach long work** (`schtasks /run` via `qtest run`, never a live 2 h pushrun — it dies with the connection); **judge output not logs** — the only proof an update landed is `CurrentBuild.UBR` moving + KB in CBS packages (state=112) after a boot; `rc=3010` = STAGED; `phase=done` = ended, read `result[]`; **reboot semantics** — guest-initiated reboot destroys the domain (`on_reboot=destroy`): Halted within ~3 min of `done` is normal, `qvm-start` it yourself; drain hygiene per §2.5.

**Where U3 runs** (§12 note 8): primary — directly on the standing template with **R1 as rollback**, the pass fitting the two-shutdown window exactly (contingent on D5; the pre-update revision is the rollback point). Fallback if R1 is denied or the pass overruns the window: R2-materialize the lineage on the churn name **created TemplateVM-class** (classification reads qubesdb `/type`, so class must be genuine); retain at most one update-stage image per lineage (2 fleet-wide, ≤~40 GB settled), delete once ST5 is stamped. Never service a golden until the pass is accepted.

| ID | Cell | Entry → exit | Prereq | Cost |
|---|---|---|---|---|
| **U0** | Deploy-state assertions (read-only): artifacts present + agent script SHA256 vs **the shipped payload** (**verify installed content, never installer output** — the `$PSScriptRoot` silent death). **Corrected 2026-08-30:** this said *vs repo*, which can never pass — the build rewrites LF to CRLF, so every deployed script hashes differently from its repo source while being byte-identical in content. Compare against the payload (what actually shipped), or against the repo *after CRLF normalisation*. Measured on `win11-tpl`: all five (`qubes-windows-update.ps1`, `wu-update.ps1`, `vmupdate-shim.ps1`, `ensure-autologon.ps1`, `VMExec.ps1`) match the payload exactly and match the repo once normalised; a raw repo comparison showed 4 of 5 'differing' purely from line endings; tasks shaped right (`Scan` boot PT2M + 6-hourly SYSTEM PT20M `-Scheduled`; `Run`/`Download` no triggers PT2H no `-Scheduled`; `QubesAutologonGuard` boot PT30S); policy `NoAutoUpdate=1`, `ExcludeWUDriversInQualityUpdate=1` on latch templates (guards NET's latch against WU-delivered Xen packages); offline baseline: winhttp direct, no relay process (proxy is temporal + positional, both gates stay) | any rig → unchanged | P0-CORE | 2 min/rig |
| **U1** | Availability to dom0. **Precondition: own both ends** — one control fetch through the `qubes.UpdatesProxy` backend (small CTL cab) proves backend egress, else every guest verdict is vacuous. Scan: phases `ensure-proxy→sync-revocation→scan→done`; `Sync-Revocation 3/3 CTLs` + fresh cabs + `RootDirURL=file://C:\ProgramData\QubesCTL`; `available[]` populated; **`qvm-features <vm> updates-available` reflects it from the mgmt qube** (the dom0-observable output — a log line alone does not count); proxy torn down after. **Stability (binding):** 3 scans on the unchanged image, stable count, before any later stage quotes it; first status write ≤3 min of kick. **Honest-empty guard, seen to fail:** `QUBES_UPDATES_FAKE_EMPTY_SCAN=1` → exit 75 `phase=scan-failed`, NOT "0 to dom0" (the 2026-08-15 lie made fail-able). **Debounce:** re-fire scheduled scan → skips; `DEBOUNCE_MIN=0` → runs; dom0-requested Run never skipped. Win10: `esu`/`notice` present; `remaining` counts only actionable self-contained rows | ST3 (template, netvm='') → unchanged | P0-CORE, U0, proxy backend up (owner) | 30–45 min |
| **U2** | VM-class matrix (security half; witness = what changed, not what was logged): template → proxy pass runs (U1); AppVM → `skipped-appvm` exit 0, `proxy_unchanged=true, no_relay_started=true`, exits before Ensure-Proxy; standalone+netvm → `skipped-standalone`, `NoAutoUpdate` REMOVED, no relay; standalone−netvm → nothing; qubesdb unreadable → `skipped-unknown`, refuses to proxy, flagged. **Boot-path clause (binding):** classification proven on a COLD BOOT (`wu-boot-acceptance-arm/-check`) — the QdbDaemon startup race is exactly what a live re-run clears | ST3/ST3A/ST2 → unchanged | U0 | 30 min |
| **U3** | dom0-driven install end-to-end (the long stage). Baseline: UBR, no RebootPending, pool GB, autologon armed (unarmed + staged reboot = sign-in lockout). Kick `Run`; poll 60 s. Download: `pct/mb` advances between polls (ref rates 12.8 MB/s Win11 / 1.5–2.4 MB/s Win10 write path; stalls resume across ≤14 attempts; two flat polls → read relay log for `PLAIN REFUSED` before any verdict). Install: `rc∈{0,3010,2359302}`; `skipped/not-applicable` rows correct (superseded siblings never fed to CBS — the KB5043080 poisoning class); Win10 `rc=50 → expand to cabs` normal; **exactly ONE reboot-requiring package per session**, rest `deferred` (CBS discards a second staged session — measured twice); `reboot_pending_confirmed=true` + TiWorker settle before reboot. Progress protocol: shim stderr = bare invariant floats 0..100 monotonic, messages never ending in a number, `staged (completes at restart):` for 3010, exits 0/100/1 (GUI render = owner checkpoint). Reboot: `shutdown /r /t 60` → Halted → `qvm-start`; **shutdown timing is diagnostic**: 6.3 min = real apply, **77 s-class = staged package DISCARDED** → run `wu-boot-servicing.ps1`, don't proceed on vibes. **Post-boot verdict (the only one that counts):** UBR moved, KB state=112, RebootPending gone, DISM clean, **autologon survived** (qrexec answers interactively; shot shows a desktop, not sign-in), NoAutoUpdate=1, offline baseline restored; boot scan re-reports `remaining` ≤15 min, graded only after its `done_ts` postdates the boot. **Bounds:** ≈45 min measured full Win11 CU; outer bound 2 h 15 min, then collect evidence (U5) and declare FAIL — never "probably finishing" | ST3 (or lineage clone) → ST5 | P0-CORE, U0, U1, C-chain accepted on the lineage | 1–2.5 h; settled delta ~20 GB Win11 / ~10 GB Win10 (provisional — measure on first execution, D-open) |
| **U4** | Failure-mode drills (defect-reintroduced proofs; template rig; restore after each): (1) 0x80072F8F — delete CTL cabs, empty `RootDirURL`, resync chain cache → failure class fires; Sync-Revocation repairs through relay → scan succeeds (CDP CRLs proven irrelevant — do not re-derive). (2) Relay dead/8082 squatted mid-pass → probe kills/respawns or fails loudly — never 0x80072EFD blamed on "the network". (3) `FAKE_STAGED` + `FAKE_FALLBACK_KB` → defer paths fire visibly; `ALLOW_MULTISTAGE=1` only on a disposable image with `wu-boot-servicing` as judge. (4) Scan-vs-Run mutex → scan yields; shim's `action='scan'` filter never adopts a scan's `done`. (5) Exit contract: forced `phase=error` → exit 1; routeless `wuinstall` refused by the route gate (zero DO/BITS phantoms in a netvm-free pass). (6) ESU honesty (Win10 until MAK, D-open): ESU-gated CU = `severity=info`, excluded from `remaining`, no fail-loop | ST3 clone → restored | U1, U3 once green | 1–2 h |
| **U5** | Introspection discipline (embedded in U3/U4, and standing for any long servicing): never describe the guest without a ≤1-min-old measurement (`wu-what-is-it-doing.ps1`, `wu-busy-probe.ps1`, two samples 3–5 min apart). STUCK only when CBS.log mtime, worker CPU (~0.4 CPU-s/s during real apply), and status `ts` are ALL flat across 10 min with the task Running (largest legit idle gap: 468 s); collect before any kill and state what the kill destroyed. qrexec dropping mid-servicing = I/O starvation, not death — wait bounded 15 min re-probing first. A missing process is not a finished job | — | — | embedded |
**THE STANDALONE CONTROL — binding for any "our updater does not ship X" claim (added 2026-08-30, owner: *"just compare: will they install on StandaloneVM? if no, then it is not a defect"* / *"write this explicitly into protocol"*).**

Before recording any update class as missing, unshipped, or filtered-out, run the SAME query on a **StandaloneVM with a netvm**. Per the class carve-out that guest updates ITSELF through stock Windows Update — no relay, no proxy, no `.msu` filter, **none of our code in the path** — so it is the control that separates *"our product drops it"* from *"Windows never offered it"*. Query with `IsInstalled=0` and **no `Type` filter**, or classes that are not `Type='Software'` are invisible and the comparison is vacuous.

- If stock does **not** offer it either → **NOT A DEFECT.** Record it as matching stock and move on.
- If stock offers it and we do not → that is the real finding, and only then.

**Settled this way already — do not re-litigate:** *Dynamic Updates.* These are a Windows **Setup** mechanism, not servicing: *Setup Dynamic Update* (KB5106084) patches Setup's own binaries and *Safe OS Dynamic Update* (KB5121002) patches the WinRE image, both shipped as `.cab` and consumed by the setup process during a feature update. Measured on `win10-c1` (StandaloneVM, direct WU, no Type filter): **zero Dynamic-Update rows offered, none in history**, and the offered set was the SAME eight KBs our agent enumerates on `win10-tpl`. So the `\.msu` filter and the KB-specific catalog search hide nothing a normal Windows machine would have installed. Server variants (KB5120233 cumulative, KB5120708 .NET) are likewise never offered to a client SKU.

**Also worth keeping from that measurement:** our updater's *offered set is identical to stock Windows'* on the same guest. Whatever else is wrong in the update path, it is not a disagreement about which updates apply.

| **U6** | Netvm truth table + budget: template pass/drills/NotifyUpdates/progress need **NO guest netvm** (proxy backend needs egress — U1 precondition); AppVM leg needs none; standalone self-update leg needs netvm (DO/BITS refuse routeless — proven gate) with egress proven per NET-3, never ping, never <90 s; WU-driver-exclusion check on a standalone protects the latch. Watermarks per §2.6. **Sequencing:** updates run AFTER install/upgrade acceptance on a lineage, BEFORE re-baselining benchmarks — a serviced image is a different benchmark subject; baselines are re-taken on ST5, never compared across the servicing boundary | policy | — | — |

---

## 8. P4 — Complex rendering and benchmarking

Every rendering verdict is judged from **pixels or the wire (QGAPROTO)** — never agent logs or guest state (the `RecreateDuplication` precedent; a fully green suite once shipped four defects the owner saw on sight). Each check names instrument, judge, and negative control; unproven controls demote to `PASS-UNPROVEN`.

### RND-0 — instruments, envelopes, capture-class rule

*Entry: any ST2/ST2G/ST3A with the build under test. Prereq: P0-CORE.*

Instrument blindness table (do not conclude from silence): `qtest shot` sees managed windows only — blind to override-redirect surfaces, decorations, agent-less guests; empty tar ⇒ triage per H3.2 first. `fullshot`+`winshot.py` sees everything incl. o-r and no-agent guests. `winshot --classify` = wait-loop terminator, not a correctness judge. `render-truth.ps1`+`rendercheck` = guest-vs-dom0 per-window diff with MISSING/EXTRA/GHOST — guest truth is a **composited** crop: compare unoccluded windows only; high `pct_differing` means "open the PNGs", not auto-FAIL (53% on a correct build measured). QGAPROTO+`check-protocol.py` = what the agent told the daemon — restart the agent before a trace run so every window has a traced CREATE; missing data fails. QGAPERF+`bench-agent.sh`/`bench-phases.sh`/`analyze-perf.py` = per-frame phase costs. `pixel-equality.ps1` = DDA-vs-PrintWindow (client-area spread = DO NOT SHIP). `check-chrome.py` = title/menu band presence (caught the 64px maximized-crop defect all numeric checks passed). Tracing on via `qvm-features <vm> service.gui-agent-debug 1` (agent ≥ ab36aef) — never registry pokes.

**Capture-class rule (binding):** per-window capture is the accepted class. Whole-desktop (`fullshot`; `qtest-geom` triggers one) only for (a) o-r surfaces and (b) suspected dom0 compositing defects; processed locally, cropped immediately, **never committed** — not even inside a tar (a name rule cannot see inside an archive). `tools/pre-commit-no-desktop-captures.sh` + the enabled `.githooks/pre-commit` (P0-PRE) screen commits. Privacy ruling on owner-attended windows for fullshot cells = decision D10.

### RND-0b — WHICH CAPTURE TOOL, PER CELL (added 2026-08-30; owner: *"cover the protocol gap, it is all consequences of 'instructions not a runbook'"*)

RND-0 states the blindness table and RND-3 warns that `qtest shot` "cannot photograph a menu", but no cell NAMES the instrument it must be judged with — so the choice is left to judgement at the moment it is easiest to get wrong. It was got wrong here: RND-4 (toasts) was first judged with `qtest shot`, which sees **managed windows only** and is structurally blind to the override-redirect surface a toast IS. The dom0 half of that cell was therefore measured with a tool that could not have seen a pass. **This table is now part of the cell, not advice next to it.**

| cell | dom0 instrument | why |
|---|---|---|
| RND-1 drag (replay/wobble) | QGAPROTO trace; `qtest shot` for window presence | wobble is judged from `ax/ay` vs `lx/ly`, NEVER cross-VM capture |
| RND-1 debris | **`fullshot`** (declared legitimate whole-desktop use) | fragments appear between windows, not inside one |
| RND-2 scroll | QGAPERF only | a metric, not a picture |
| **RND-3 menus / o-r** | **`fullshot` + `winshot.py`** | `_NET_CLIENT_LIST` excludes o-r; `qtest shot` is blind by construction |
| **RND-4 toasts** | **`fullshot` + `winshot.py`** | a toast is topmost + layered + often DWM-cloaked — an o-r surface |
| RND-5 Start | `qtest shot` **plus** the agent deny line | acceptance is that NOTHING maps; the discriminator is the vacuity proof |
| RND-6 occlusion | `qtest shot` per-window + `check-occlusion.py` | both windows are managed |
| RND-7 compound chrome | `qtest shot` window COUNT + guest-side `EnumWindows` | both sides are managed windows; the count is the verdict |
| RND-8 resolution | `qtest shot` + `snap-regress` | managed windows; pixels must change |
| RND-9 boot/LogonUI | `qtest shot` + protocol trace armed pre-reboot | sub-second flashes need the trace |

**Binding rules that follow from it:**
1. **A cell whose subject can be override-redirect MUST use `fullshot`.** A `qtest shot` negative on such a cell is `INVALID-VACUOUS`, never a PASS and never a FAIL — the instrument could not have seen the thing.
2. **Whole-desktop captures are deleted in the same step that reads them** (capture-class rule, D10). They contain the owner's entire desktop. Read, decide, delete — never commit, never retain, not even inside a tar.
3. **Guest-side existence is proven with `EnumWindows` (`CharSet.Unicode`), not with the capture.** The two halves answer different questions: did the surface exist, and did it reach dom0.

### RND-0c — THE INTERACTIVE-SESSION TRAP (added 2026-08-30)

**qrexec on this testbed runs as `NT AUTHORITY\SYSTEM`** (dom0 policy — see the `presession-qrexec-system` memory). Shell UI is PER-USER. So anything driven directly over qrexec that needs the logged-in user's session — **toasts, Start, shell flyouts, notification surfaces** — is accepted by the API and rendered for nobody. Measured: `fire-toast.ps1` returned `{"fired": true}` while no window existed in the guest at all.

Such cells must be driven **as the interactive user** (`schtasks /ru user /it`, which is why `open-start.ps1` and `toast-probe-uia.ps1` already schedule tasks). A cell that fired its stimulus as SYSTEM has not established the stimulus, and its result is `INVALID-VACUOUS` under SG0.4 regardless of what the capture shows.

### RND-1 … RND-9 — the battery

*Entry precondition, same as BENCH: **`QubesWindowsUpdateScan` DISARMED and recorded** (G-0c) — the RND battery drives the same SendInput/qrexec load and shares the wedge exposure. Run per OS at minimum on: the fresh-install exit (ST2 on churn) and one upgrade exit (ST2G), seamless mode; RND-8 additionally in the fullscreen/IDD configuration. After any battery: **RND-cold** — one reboot, then RND-3/4/5 again (a live agent restart clears exactly the faults cold boot exposes). Settle rule: ≥20 s after scene setup before first capture; expected window counts derive from the scene's own window list — never hardcoded. Cost: ~1.5–2.5 h per OS per configuration, 0 GB.*

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

*Entry: the stage being baselined (ST2/ST2G/ST5), quiet host, **`QubesWindowsUpdateScan` DISARMED and the disarm recorded in the cell evidence** (P3 rule; G-0c). Prereq: P0-CORE, agent hash verified. Cost: ~45–60 min per baseline set, 0 GB.*

> **MANDATORY FIRST STEP OF EVERY BENCH AND RND CELL — not advice, a step:**
>
>     schtasks /query /tn QubesWindowsUpdateScan /v /fo LIST | findstr /i "Next Run Time"
>     schtasks /change /tn QubesWindowsUpdateScan /disable
>     ... run the cell ...
>     schtasks /change /tn QubesWindowsUpdateScan /enable
>
> A BENCH/RND transcript that does not show the disarm is **`INVALID-PRECONDITION`** — an
> unmeasured cell, never a slow number and never a wedge worth chasing. **The boot+2min trigger
> is the trap**: cold-booting a guest and starting a benchmark within a few minutes puts the
> workload directly on top of the scheduled scan. Measured 2026-08-30: guest booted ~17:52,
> scan due ~17:54, BENCH started ~17:53, guest wedged mid-benchmark — the documented
> consequence of the documented trigger, and every number from that session was void.
> `mgmt/harness/p4-run.sh` performs the disarm, asserts it, and re-enables at the end.

- **BENCH-0 — mint canonical baselines on the pristine-lineage rigs** (the protocol's first benchmarking act; §12 note 9). `tools/bench-agent.sh <label>` fixed workload (idle 5 s → drag 10 s → idle → scroll 10 s → idle → type 10 s → idle-post; SendInput proven to reach the input desktop; cadence+jitter reported so a loaded guest is visible). ≥3 runs (≥5 for drag) on ONE unchanged binary; record in FINDINGS with **raw files committed to `instrumentation/`** (standing rule — the b299011 raws were never committed). b299011 (613 µs drag etc.) is retired to a historical footnote; the 4.3.10 quiet-host set (`bench-4310-q1..q4`, scroll 374–436 µs) is the current-rig reference until BENCH-0 supersedes it.
- **BENCH-1 — comparison runs.** Against recorded canonical baselines only, never an intra-day build (owner rule; violating it burned ~1M tokens). ≥3 runs per side, **interleaved** with the control. **Scroll is the metric that can carry a verdict; drag p50 is bimodal (scene-state — the trap that voided a bisect) and gates nothing until its variance is re-established** (decision D-open). Guest-side cost counts even when dom0 corrections hide it. Host state recorded with every run.
- **BENCH-2 — always-on tripwires** (run with every benchmark): agent + IDD UMDF idle CPU (`cpu-bench.ps1`/`phase-cpu-bench.ps1`; baselines: workarea churn 0 applies / ~0.08 s CPU per 120 s idle — pre-fix control 1460 applies / 3.95 s; WUDFHost 0.000%); `idle-repaint-box.ps1` for ambient repaint dom0 never displays but capture pays for. Negative controls: the recorded pre-fix numbers are the seen-to-fail states.

---

## 9. P5 — Safeguards (SG suite)

Every safeguard is a filter with two failure directions — stops firing (the blocked thing returns: the 2026-08-28 class-only Mode-1 leak) or over-fires (eats UI it must keep: the 2026-08-07 title-bar clamp that passed every numeric check). Both directions are graded per safeguard; **no check counts until seen to FAIL against a deliberately reintroduced defect**; unproven cells carry `PASS-UNPROVEN` in the matrix.

### SG0 — ground rules (violating any voids the run)

1. **NEVER set `service.gui-fullscreen`, never signal the mode events** — owner: "never means never" (three screen-cover incidents). Every arm requiring the feature ON (feature-ON Mode 2, non-seamless sign-in view, end-to-end Progman) is **owner-attended only**, listed `ATTENDED-PENDING` in the matrix, never silently dropped; the unattended portion still covers every safeguard's default state.
2. **Screen-cover containment (CORRECTED 2026-08-30 — it does not survive a reboot).** The guest resolution must be set **AFTER the agent has started and settled**, and verified against the **agent's believed screen size** (its `HandleXconf` / `SetVideoMode` / `ResolutionAdoptCurrent` lines), not merely against `Win32_VideoController`. Measured: the agent re-applies dom0's geometry at startup (`RESREQ 5120x1440 src=lastapplied`, `RESDRIFT ... adopting the actual mode`), so a resolution set before a cold boot is silently undone and every probe sized to it is then a fraction of the real screen — the gate is never exercised and the cell is `INVALID-PRECONDITION`, not a pass. All per-window fullscreen-gate cells (SG1–SG4) run at a **sub-host guest resolution** (e.g. 1600x900 via the /idd path, `set-resolution.ps1`) — the gates compare against the *guest* screen, so even a broken gate maps a bounded 1600x900 bordered window. Exception: boot-phase defect arms run at boot size ⇒ attended. (Contingent on the rig carrying the IDD build — else those arms fall back to attended.)
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
- **SG9 — Start/menus per the SHIPPED spec** (Start is NOT presented in seamless; `SeamlessStart=0`, Super blocked — acceptance is the *opposite* of "Start maps"). Positive: `open-start.ps1` → no new window, no phantom (historical: 1201x919 wallpaper window; x=6063 offscreen); discriminator `Start surface not presented in seamless mode`; cardless gate: shell hosts with closed menus never MAPped in the trace. Dev arm (restore-only, not release acceptance): `SeamlessStart=1` → cropped card per the 25H2 baseline. Menus: **SYNTHESIZED, not mapped** (corrected 2026-08-31). `SynthActivate` (main.c:1774) paints the
popup into its OWNER's framebuffer and emits no further protocol traffic; measured, there are ZERO
`msg=MAP ... ovr=1` in an entire log. Acceptance is `msg=SYNTH` onto the right owner **plus a change
in the owner's dom0 pixels**. Requiring a separate override-redirect window in dom0 produced a false
product FAIL on 2026-08-31. OPEN: a menu overhanging the owner may be clipped (`PwPatchSynthChildClipped`) — untested. **Fail-proof:** diag build skipping the cardless gate → wallpaper phantom maps → red (trace: shell-host HWND mapped while guest truth says closed).
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
- ~~NMI dump on a wedge reproduction~~ — **POSTPONED by the owner 2026-08-30**: *"we postponed wedge, and you collected enough of nmi dumps, one more would not help much."* Two dumps are already on record and the class attribution rests on them. Do NOT propose another NMI capture, and do not treat a wedge encountered in passing as a reason to reopen it — write it off (G-0), note the trigger, and continue.
- `fw-net` up (all traffic cells: NET-3/4/5/8, U6 standalone leg) — confirm per campaign, recorded; traffic FAILs are unattributable without it.
- NET-8 local throughput endpoint (file served from fw-net or a neighbour qube).
- dom0 resize service installed (RND-8); dom0-side wedge forensics (U5 terminal case).
- Qubes Update GUI progress click (U3 §5); real-Office validation (SG8/RND-7); all `ATTENDED-PENDING` SG arms.
- Any dom0/sudo/policy change; removing any golden or template (prune ladder step 4).

**Decisions pending (register; defaults noted where the protocol needs one to run):**
- ~~**D1** StandaloneVM latch~~ — **DECIDED 2026-08-29: the latch is ALWAYS ON, StandaloneVMs included.** Owner: "latch is always on (already told you about that), standaloneVM included". Implemented in `Install-QwtImproved.ps1` (`cace671`): the templates-only gate is gone, the class is read for the log line only. NET-7 is now a full acceptance cell carrying NET-2's criteria. ~~Not yet validated on a built package~~ — **VALIDATED 2026-08-30** on release `4.3.16+agent.409439d8cc46`: `pvnic_prime:seeded` + `pvnic_latch:armed` on both a TemplateVM (`win10-tpl`, NICS=1 readback) and a StandaloneVM (`win10-c1`). The C11 standalone row was stale and has been corrected.
- **D2** Post-provisioning cleanup audit (`qemu-extra-args` / stick assignment) — confirmed step or script addition.
- ~~**D-local-endpoint** PV throughput needs a local file server~~ — **SUPERSEDED 2026-08-29: benchmark against a fast CDN instead.** Owner: "you may benchmark against reasonably fast cdn". NET-8 rewritten; no owner setup required.
- ~~**D3** Win11 true-stock stage~~ — **SETTLED 2026-08-30 by running it.** C4.11 is no longer N/A-by-design: `mgmt/prime-jobs/stock-422` is OS-agnostic, so the Win11 stock precondition costs one primer build (~5 min) rather than an R3. Measured: stock 4.2.2 installs on Win11 with `pv_boot_disk:true` and `xenbus_monitor{Running, start:2}`, and our package upgrades over it `in-place-msi-major-upgrade`. Win11 stock parity is now standard, not pending.
- **D4** ST1F constructibility (stock 4.2.2 drivers with testsigning off) — if not, C5 is unreachable without a field image: flag, don't drop.
- **D5** R1 (`qvm-volume revert`) and `revisions_to_keep` permission from this qube — unverified; if denied, R1 rows collapse into R3 and U3's primary rollback design falls to its fallback.
- **D6** G0 tooling: openssl-asn1parse form vs installing osslsigncode.
- ~~**D7** G0 negative-control fixture source~~ — **SETTLED 2026-08-30.** No archived package needed: the defect is a STRUCTURE (a PKCS#7 SignedData with an empty `signerInfos` SET), so the fixture is synthesised to it. `tools/tests/g0-negative-control.sh` is two-sided — the untouched payload must PASS, the same copy with one catalog replaced must FAIL *and name that catalog*. Measured: PASS 8/0, then FAIL naming `iddsampledriver.cat`. G0's PASS is now evidence, no longer `PASS-UNPROVEN`.
- **D8** Canonical PKG(N−1) artifact for C7/C8 (+ surviving MANIFEST.json).
- **D9** Known-issue register location (FINDINGS section vs dedicated file) — so "known" cannot silently absorb new regressions (24H2 Start, z-order class live there).
- **D10** Privacy ruling on whole-desktop fullshot cells (owner-away window vs crop-and-delete handling) and on any high-rate dom0 capture for sub-second flash proof.
- **D11** Quarantine release: campaign halts that OS lane until owner releases, or autonomous release once terminal state is fully captured?
- ~~**D12** Golden refresh policy~~ — **DECIDED 2026-08-30, in a third way neither option named:** goldens are not refreshed per release at all, because **only the two pristine bases are goldens**. Owner: *"installing our qwt is cheap, and full upgrade test is rare, so we can build those images but we are not going to keep them forever as golden untouchables"*. Every software-carrying precondition is a transient fixture built by `prime-run.sh` and removed at campaign end; its provenance is checked with `golden.sh fixture` (§0.4). This also kills the circularity that voided the previous campaign — a golden built from the candidate made "upgrade" cells into reinstall cells.
- **D13** `DiagWindowFilterOff` bit extension for the remaining SG fail-proofs (each bit weakens filtering — sign-off required).
- **D14 ESU MAK for Win10 19045 — POSTPONED by the owner 2026-08-30** (*"same for ESU"*). Win10 template CU acceptance therefore stays capped at the honest ceiling, by decision rather than by omission. **Consequence for cell design: do NOT pick a post-EOS security CU as an install-path test** — CBS refuses it without entitlement and the cell measures licensing, not the product. KB5066791 was chosen that way on 2026-08-30 and staged/applied anyway, but the choice was wrong. Original: ESU MAK for Win10 19045 (until then Win10 CU acceptance capped at the honest ceiling); Win11 sibling-checkpoint-drop bug needs a pre-checkpoint 26100 image that doesn't exist on the rig.
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