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

**Ship the install, upgrade, network and rendering paths. Do NOT ship the Windows Update path.**

Everything the previous release notes listed as unverified is now measured and passes. One material
defect was found, in a subsystem the previous campaign never exercised.

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

## What is NOT covered, stated plainly

- **U1 — availability to dom0.** Blocked by the defect above, in THIS campaign.
- **U3 — download + install.** Not run today. **This is not an unproven capability**: prior sessions
  drove it end to end — `19045.2965 -> 19045.6456` (FINDINGS:15097), Win11 `UBR 8875 -> 9168` with
  KB5121003 applied (FINDINGS:8249), KBs reaching CBS `state=112` (FINDINGS:9548). The one genuine
  gap is narrower and already named in the record (FINDINGS:13306): **install has never run on a
  TemplateVM** — the proven drain was on `win10-clean`, a Standalone rig. One dom0-driven drain on
  `win10-tpl` with UBR + CBS `state=112` acceptance closes it.
- **SG2 / SG4** — `INVALID-PRECONDITION`. The agent re-applies dom0 geometry at boot, so the SG0.2
  sub-host containment did not survive the reboot and the probes were 31% of the real screen; the
  gate was never exercised. Not run uncontained, because a real failure would put a full-screen
  window on the owner's display.
- **RND-3 menus** — `INVALID-VACUOUS`; the menu never opened (interactive-session trap).
- **SG6 fail-proof** — `INCONCLUSIVE`; the selftest cannot construct its negative on this build.
- **RND-8 resolution changes** — blocked on `set-resolution.ps1`, which is broken.
- Owner-attended SG arms remain `ATTENDED-PENDING` and were not run.

## SG11 — safeguard results matrix

Per SG11, a blank fail-proof cell renders that safeguard's PASS **UNPROVEN** in every citing report.

| safeguard | positive | negative control | fail-proof | verdict |
|---|---|---|---|---|
| **SG1** Mode 1 never shown | PASS — nothing fullscreen across a cold boot | secure desktop entered *and* suppressed; no-shell phase observed | — (attended diag build owed) | `PASS-UNPROVEN` |
| **SG2** borderless fullscreen gated | not exercised | — | — | `INVALID-PRECONDITION` |
| **SG3** windowed fullscreen allowed | PASS — maximized captioned window mapped | — | — (deny-direction diag build owed) | `PASS-UNPROVEN` |
| **SG4** o-r fullscreen never mapped | not exercised | — | — | `INVALID-PRECONDITION` |
| **SG5** secure desktop per mode | partial — freeze observed during SG1's Winlogon phase | — | — | not run as a cell |
| **SG6** autologon armed | PASS — `AutoLogonCount` absent, task Ready, windows map | — | **INCONCLUSIVE** — selftest cannot build its negative | `PASS-UNPROVEN` |
| **SG7** toasts survive filter | PASS — owner-observed onscreen | — | — (naive-cloak diag build owed) | `PASS-UNPROVEN` |
| **SG8** compound chrome | PASS via RND-7 — 5 HWNDs guest-side, 1 mapped | the 4 shadow strips proven present in the same run | — | `PASS-UNPROVEN` |
| **SG9** Start per shipped spec | PASS — denied with the documented discriminator | Start surface genuinely created and evaluated | — | `PASS-UNPROVEN` |
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
