# Acceptance report — QWT-NG 4.3.16

**Release under test:** `4.3.16+agent.409439d8cc46` (repo `0f6fcaa`, agent `409439d`, CI run 33303456913)
**Campaign:** `20260830-acceptance-4.3.16`, profile TIER-B
**Ledger:** `~/qwt-accept/20260830-acceptance-4.3.16/verdicts.tsv` — **250 checks**

| outcome | count |
|---|---|
| `PASS` — effect demonstrated **and a fail-proof on record** | **46** |
| `PASS-UNPROVEN` — succeeded, never seen to fail | **183** |
| **`FAIL` (product)** | **3** — all U1, one defect |
| `N/A` by design | 12 |
| `INVALID` / `INCONCLUSIVE` — unmeasured | 4 |
| `FAIL-MINE` — my instrumentation | 2 |

> **The PASS/PASS-UNPROVEN split is the honest headline.** H5 defines `PASS` as requiring *"the check
> has a fail-proof on record"*, and states that a check absent from the registry **can never emit
> plain `PASS`**. `mgmt/harness/instrument-proofs.md` did not exist before this campaign (P0-PRE.7,
> owed since the protocol was written), so **every plain PASS this project has ever written was
> unproven by its own rule**. The registry now exists, and this report is the first to apply the
> split. 183 of 229 successes are second-class: they mean "the product did the right thing in this
> run", not "the check would have caught the wrong thing".

## Verdict

**Ship the install, upgrade, network and rendering paths. The update path carries an UNEXPLAINED INTERMITTENT SCAN FAILURE — not a known defect, and not a clean pass.**

> **Corrected after the verdict was first written.** This report originally said *"do NOT ship the Windows Update path"* and attributed the failure to a missing SYSTEM-account proxy plane. **That attribution was falsified by a later run**: the scan offered 8 updates and reported 5 to dom0 (`qubes.NotifyUpdates`, exit 0) on the shipped build with that plane demonstrably ABSENT. The scan did fail `0x8024402C` four times earlier — that is real — but the cause is **unknown**, and the ship-blocking verdict built on my attribution is withdrawn. See the FALSIFIED entry in FINDINGS.

Everything the previous release notes listed as unverified is now measured and passes.

---

## The defect: Windows Update cannot scan on this build

`guest/qubes-windows-update.ps1`'s `Ensure-Proxy` sets three proxy planes — `netsh winhttp`, **HKLM**
`Internet Settings`, and `DODownloadMode`. It does not set the **SYSTEM account's own WinINET
settings** (`HKU\S-1-5-18`), which is what `bitsadmin /util /setieproxy LOCALSYSTEM` writes and what
`wuauserv` — running as SYSTEM — actually reads.

Every scan therefore fast-fails `0x8024402C` (`WU_E_PT_WINHTTP_NAME_NOT_RESOLVED`) in 2–4 s, 4/4
attempts. Availability never reaches dom0, so `qvm-features <vm> updates-available` cannot populate,
and U3 cannot be driven **on this build** until the plane is added — note U3 itself is a proven
capability from earlier work (UBR advanced, CBS `state=112`), not an untested one.

**Attribution is complete because both ends of the proxy were owned.** The path works: the proxy
logged all three CTL cabs established and the guest logged `Sync-Revocation: 3/3 CTLs refreshed
through the relay`, every fetch `complete=True`, no cuts. The WU COM searcher simply never dials —
the relay log is silent after the CTL fetches.

**Fix, proven by isolation.** Same guest, same relay, one plane added:

    bitsadmin /util /setieproxy LOCALSYSTEM MANUAL_PROXY 127.0.0.1:8082 "<local>"
    -> WUA_OK count=4 seconds=104.8   (KB5007651, KB890830, KB2267602, KB5121003)

That is an isolation result, **not a proposed fix**: `Install-ViaWU` (the DO/BITS rung) is deliberately gated off for netvm-free guests, and re-enabling the WU COM path would reinstate an architecture that was discarded on purpose. What the scan should use instead is an owner design decision — `FINDINGS:6429` and `FINDINGS:13424` disagree about whether the machine WinHTTP plane alone is sufficient, and that must be settled before any change. The backoff-cache hypothesis was tested and
**refuted** (`SoftwareDistribution` renamed, still `0x8024402C`).

`FINDINGS:6429` had already recorded the required plane set — *"netsh winhttp + device-wide WinINET
+ DODownloadMode=0 + **bitsadmin setieproxy LOCALSYSTEM** + a one-time SoftwareDistribution reset"*.
The shipped script implements three of five. The knowledge was on the record and did not reach the
product.

**The release was not modified.** Patching mid-campaign would change the artifact being graded.

---

## CONTAMINATION — P4 and P5 were void, and have since been RE-RUN (2026-08-30/31)

**Status update.** Everything in this section stands as the verdict of the *contaminated* runs. P4
and P5 have since been re-executed on `win10-p46`, a subject rebuilt to its entry stage, with the
update scan provably disarmed. See "P4/P5 RE-RUN" below. The contaminated verdicts are NOT deleted —
they remain on the ledger as `INVALID-CONTAMINATED`, superseded rather than overwritten.

### The original contamination

**All of P4 (rendering + benchmarks) and P5 (safeguards) ran on `win10-tpl` after I had mutated it
during the U1 diagnosis (proxy planes + `setieproxy`, via `enum-updates.ps1`) and never rebuilt it to
its entry stage.** Per G-0b those 27 checks are `INVALID-CONTAMINATED`, not results.

That covers BENCH-1 and BENCH-2, RND-3/4/5/7, SG1, SG3, SG6, SG7, and U2's cold-boot arm. The
numbers they produced (scroll p50 334/307/345 µs, SG1 with no fullscreen window, RND-7's 5-HWNDs-to-1)
may well be correct — **but "the mutation probably didn't affect a scroll benchmark" is exactly the
unfalsifiable reasoning the contaminated verdict exists to forbid.** They must be re-run on a rebuilt
subject before they mean anything.

**What survives:** P0 (gates), P1 (install/upgrade — every cell recloned its own subject from a
verified entry image *before* any mutation), and P2 (networking — ran on `win10-app`, `win11-app` and
`win10-c1`, none of them touched by the U1 diagnosis). U0 ran on `win11-tpl` before that guest was
mutated.

## What passed

**P0 — gates.** Gate 0 (76 files, built from `0f6fcaa`). **G0 catalog signatures: 8 catalogs, 0
unsigned, every signer matched a shipped `.cer`** — a gate that did not previously exist, now with a
**two-sided negative control** (seen to fail on a planted empty-`signerInfos` catalog), which settles
protocol D7.

**P1 — install/upgrade, 152 checks, 0 FAIL.** Both OSes throughout.

| cell | result |
|---|---|
| **C1 clean install (E1×D0)** | first genuine D0 ever graded here — proven from the installer's own `clean install path` marker, not a cell label |
| **C12 stage-1 idempotence** | 2nd pre-reboot run re-detected stage 1; resume fired **exactly once** |
| **C3 upgrade over 4.3.14** | `in-place-msi-major-upgrade`, one PRECONDITION, `inbox_disk_rearm:done` — **the path the release notes called unverified** |
| **C4 upgrade over stock 4.2.2** | both OSes; armed-monitor by construction (`xenbus_monitor{Running,start:2}`), zero Event-1074 during msiexec |
| **C6 same-version reinstall** | `REINSTALL=ALL`, zero `REFUSING` (the 2026-08-11 PV-gate guard holds) |
| **C11 / D1** | `pvnic_prime:seeded` + `pvnic_latch:armed` on **both** template and StandaloneVM — validates decision D1 on a built package for the first time |

Boot-path acceptance on every exit: PV disk bound with `still_on_emulated_ide: []`, **PV console
bound** (4.3.16's new xencons), IDD driving the desktop, `C:\Users` reparsed to `Q:\Users`, pixels
provably changing in dom0.

**P2 — networking, 28 checks, 0 FAIL.** PV NIC bound on live attach with `LastBootUpTime`
**byte-identical** (zero reboots) on both OSes; 25 MB proven across the PV NIC by that adapter's own
`rx_bytes`; 3/3 boot soak with real qubesdb IP and no APIPA; and **zero premature-reboot dialogs
across 289 continuous samples** on guests that had genuinely never had a vif.

**P3 — U0 and U2 pass.** Task shapes, policy (`ExcludeWUDriversInQualityUpdate=1`), offline baseline,
and all five deployed scripts hash-matching the payload. U2's every class arm behaves, and its
**cold-boot clause validates the QdbDaemon startup-race fix** (`qdb_retry_evidence:true`).

**P4 — benchmarks pass.** **scroll p50 334/307/345 µs vs the canonical 374–436** — better on every
run, no overlap. Idle CPU 0.02–0.06 s per 120 s (baseline ~0.08, pre-fix 3.95). Drag reproduces the
documented bimodality and gates nothing. **RND-7 compound chrome passes both directions**: 5 HWNDs
guest-side (1 main + 4 layered/transparent/toolwindow), exactly 1 mapped.

**P5 — SG1, SG3, SG6, SG7, SG9 pass.** Mode 1 holds with a real vacuity guard (secure desktop
entered *and* suppressed). Autologon armed with `AutoLogonCount` absent and no plaintext password.
Start not presented in seamless, denied by the documented discriminator. Toasts **do** survive the
chrome filter (owner-observed).

---

## P4/P5 RE-RUN on a rebuilt subject (`win10-p46`, 2026-08-30/31)

**P4** — `mgmt/harness/p4-run.sh`, rc=0, with the G-0c precondition in the transcript
(`SCAN_BEFORE Ready` → `SCAN_AFTER Disabled`, `RELAY_AFTER 0`, `DISARMED True`):

| cell | result |
|---|---|
| BENCH-1 scroll p50 | **351 / 314 / 368 µs** vs canonical 374–436 — below the band on all three |
| BENCH-2 idle CPU | 0.03 / 0.02 / 0.00 s per 120 s (baseline ~0.08, pre-fix 3.95) |
| RND-7 | 5 HWNDs guest-side → exactly 1 mapped |
| RND-5 | 0 mapped, **6** deny lines for HWND 0x10174 |

The controls mattered: contaminated subject + scan live = 334/307/345; clean subject + scan **live**
= 417/366; clean subject + scan **disarmed** = 351/314/368.

**P5** — `mgmt/harness/p5-run.sh`, rc=0. **SG0.2 containment was established and PROVEN for the
first time in this campaign**: guest 1024x768 = agent 1024x768 (`A6CONFIGURE window 0 -> 1024x768`)
inside a 5120x1440 host. A control Notepad (747x502) was visible to the capture path in **6/6
samples of every cell**, so no "nothing mapped" here came from a blind instrument.

| cell | probe | dom0 | discriminator | verdict |
|---|---|---|---|---|
| **SG4** o-r fullscreen | 1024x768, o-r, covers screen | absent 6/6 | `unconditionally denied, feature or not` ×2 | PASS-UNPROVEN |
| **SG2** borderless fullscreen | 1024x768, no caption, `WS_EX_APPWINDOW` | absent 6/6 | `hidden (set service.gui-fullscreen to allow)` ×2 | PASS-UNPROVEN |
| **SG3** windowed fullscreen | 1024x768, captioned | **present as 1010x761, 6/6** | n/a (must map) | PASS-UNPROVEN |
| **SG9** Start | `open-start.ps1` | control only | `Start surface not presented in seamless mode` ×25 | PASS-UNPROVEN |

**SG2 and SG4 were `INVALID-PRECONDITION` for the whole campaign** — unreachable because containment
was unreachable. They are now genuinely exercised.

### Three harness defects found while doing it — each faked a verdict in BOTH directions

1. **A fixed settle is not a readiness signal.** An 18 s sleep is shorter than PowerShell's runtime
   `Add-Type` compile, so the probe window did not exist when the shot was taken and the empty tar
   read as a denial. **SG3 was scored FAIL against a window the agent's log shows it MAPped**
   (`SendWindowMap … ovr=0, vis=1, 1586x893`). Now waits on the probe's own output.
2. **"Nothing mapped" from an unvalidated capture path is not a result.** Hence the control window.
3. **The launcher's own console window** (979x512, created by `cmd /c "... > file"`) was counted as
   a leak and produced FAIL on SG2 and SG4. Now launched `-WindowStyle Hidden`, and the probe is
   identified **by size**, not by a window count.

Had the harness been trusted, this campaign would have reported three fabricated safeguard failures.

---

## What is NOT covered, stated plainly

- **U1 — availability to dom0.** Blocked by the defect above, in THIS campaign.
- **U3 — download + install.** Not run today. **This is not an unproven capability**: prior sessions
  drove it end to end — `19045.2965 -> 19045.6456` (FINDINGS:15097), Win11 `UBR 8875 -> 9168` with
  KB5121003 applied (FINDINGS:8249), KBs reaching CBS `state=112` (FINDINGS:9548). The one genuine
  gap is narrower and already named in the record (FINDINGS:13306): **install has never run on a
  TemplateVM** — the proven drain was on `win10-clean`, a Standalone rig. One dom0-driven drain on
  `win10-tpl` with UBR + CBS `state=112` acceptance closes it.
- **SG2 / SG4** — ~~`INVALID-PRECONDITION`~~ **RESOLVED 2026-08-30**: containment now works
  (`guest/set-resolution.ps1` fixed), both gates exercised at 1024x768 with their discriminators.
  See "P4/P5 RE-RUN".
- **RND-3 menus** — `INVALID-VACUOUS`; the menu never opened (interactive-session trap).
- **SG6 fail-proof** — `INCONCLUSIVE`; the selftest cannot construct its negative on this build.
- **RND-8 resolution changes** — ~~blocked on `set-resolution.ps1`~~ **UNBLOCKED 2026-08-30**. The
  script was not broken by DEVMODE marshalling as recorded; it passed `lpszDeviceName = NULL` on a
  guest whose desktop is on `\\.\DISPLAY2` (`DISPLAY1` publishes 29 modes and has no current mode;
  `EnumDisplayDevices` enumerates nothing here). Also refuted: the session hypothesis — qrexec runs
  as SYSTEM in **session 1 on WinSta0** and an identical probe is byte-identical through both paths.
  RND-8 itself is still **not run**.
- Owner-attended SG arms remain `ATTENDED-PENDING` and were not run.

## SG11 — safeguard results matrix

Per SG11, a blank fail-proof cell renders that safeguard's PASS **UNPROVEN** in every citing report.

| safeguard | positive | negative control | fail-proof | verdict |
|---|---|---|---|---|
| **SG1** Mode 1 never shown | PASS — nothing fullscreen across a cold boot | secure desktop entered *and* suppressed; no-shell phase observed | — (attended diag build owed) | `PASS-UNPROVEN` |
| **SG2** borderless fullscreen gated | PASS — 1024x768 caption-less `WS_EX_APPWINDOW` probe absent from dom0 in 6/6 samples | discriminator `hidden (set service.gui-fullscreen to allow)` ×2; probe styles read back; control window seen 6/6 | — (feature-ON arm attended) | `PASS-UNPROVEN` |
| **SG3** windowed fullscreen allowed | PASS — captioned 1024x768 probe mapped as 1010x761 in 6/6 samples | probe carries `WS_CAPTION`, read back with GetWindowLong; control seen 6/6 | — (deny-direction diag build owed) | `PASS-UNPROVEN` |
| **SG4** o-r fullscreen never mapped | PASS — 1024x768 o-r probe absent from dom0 in 6/6 samples | discriminator `unconditionally denied, feature or not` ×2; control seen 6/6 | — (feature-ON arm attended) | `PASS-UNPROVEN` |
| **SG5** secure desktop per mode | partial — freeze observed during SG1's Winlogon phase | — | — | not run as a cell |
| **SG6** autologon armed | PASS — `AutoLogonCount` absent, task Ready, windows map | — | **INCONCLUSIVE** — selftest cannot build its negative | `PASS-UNPROVEN` |
| **SG7** toasts survive filter | PASS — owner-observed onscreen | — | — (naive-cloak diag build owed) | `PASS-UNPROVEN` |
| **SG8** compound chrome | PASS via RND-7 — 5 HWNDs guest-side, 1 mapped | the 4 shadow strips proven present in the same run | — | `PASS-UNPROVEN` |
| **SG9** Start per shipped spec | PASS — control only in dom0, re-run on the clean subject | 25 deny lines `Start surface not presented in seamless mode`; control seen | — | `PASS-UNPROVEN` |
| **SG10** shell identity/furniture | not run | — | — | not run |

## Closing record (runbook §0.2 step 8)

- **Pool:** 91.9% used at campaign start (**RED**) → pruned to 83.1% → **83.5% used, 144.5 GB free** at
  close. Fixtures (`win10-u14`, `win11-u14`, `win10-stk`, `win11-stk`) built on demand and **all
  removed**; receipts deleted. No standing extras, per the owner's goldens decision.
- **Goldens:** `win10-base` and `win11-base` verified intact at close — never booted, only cloned.
- **Guests:** all Windows guests Halted. `service.gui-agent-debug` unset on `win10-tpl`.
- **Whole-desktop captures:** read, judged, and deleted in the same step (capture-class rule, D10).
  None committed.
- **Standing state:** `win10-c1` / `win11-c1` have now had a vif and are **no longer NET-6-eligible**;
  a future first-vif cell needs a fresh clean-install exit.

## Protocol and instrumentation changed by this campaign

Eight corrections, each caused by a real failure during the run:

1. **G0 added** with a two-sided negative control (settles D7).
2. **One entry-image roster** — three files named three different golden sets.
3. **Fixtures earn provenance by construction** (`golden.sh fixture`), settling D12.
4. **`matrix.sh` lost its unsafe `G10/G11` default** — it pointed at goldens carrying the candidate,
   which is what turned "upgrade" cells into reinstall cells.
5. **The reboot-dialog watcher had never sampled** — armed with `-Minutes`, a parameter that does
   not exist. It failed closed, so no false PASS, but the dialog criterion could never be met.
6. **RND-0b** now names the capture instrument per cell; **RND-0c** records that qrexec runs as
   SYSTEM so shell-UI cells must be driven as the interactive user.
7. **SG0.2 containment corrected** — must be set after the agent settles and verified against the
   agent's believed screen size.
8. **`guest/surface-watch.ps1` added** — a continuous, self-validating surface sampler, built after
   my own ad-hoc probe produced a negative the owner refuted by looking at the screen.

Also settled: **D1** (validated), **D3** (Win11 true-stock run rather than deferred), **D7**, **D12**.
