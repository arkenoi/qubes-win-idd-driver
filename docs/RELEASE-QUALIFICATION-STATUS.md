# Release qualification status — 2026-08-06

Goal (user): E2E install test Win10+Win11, regression, networked qube / Windows Update,
Office behaviour, benchmark vs stock QWT, user-facing write-up, installable package (+ISO)
on GitHub, then feature freeze.

## DONE

| item | state | evidence |
|---|---|---|
| Installable package (real MSI, not an overlay) | **built, green on main** | CI `release-package.yml`; upstream WiX MSI with our agent inside — verified by extracting both MSIs and diffing payloads against stock 4.2.2 |
| ISO artifact | **built** | `qwt-improved-setup.iso` 29.7 MB, ISO9660+Joliet+RockRidge, sha256 verified after download (997cc27d…) |
| Package integrity | **verified locally** | setup dir 19/19 sha256 OK; ISO checksum OK; MANIFEST carries commit/run provenance |
| User-facing write-up | **written** | `docs/WHAT-CHANGED-FOR-USERS.md` (behaviour + measured numbers + honest "not fixed" section) |
| Tag-based testbed policy | **installed by user** | `dom0/12-install-policy-tagged.sh`; new qubes now admissible without a dom0 visit (the old per-NAME rules gave fresh qubes zero access) |
| Fresh-guest install attempt | **ran, found a real bug** | see below |
| Installer bug (ours) | **fixed + rebuilt** | `Clear-BootResume`: `schtasks /Delete` on a missing task writes to stderr; `ErrorActionPreference=Stop` turned that no-op into a FATAL, aborting the install before the MSI. Both schtasks sites now judge the exit code (0859dbb). Fix present in the new artifact. |
| Track B gating record (exp-9) | **PASS 6/6** | 3 interleaved rounds, cold boot per side; flag TRUE, pitch tight, dup clean on the IDD |

## UPDATE (session close)

Since the table above: **networking + Windows Update verified with zero issues** on
`core-net` (NIC/DNS/HTTPS, WU search+download+install all orcSucceeded, no CPU burn) and the
historical netvm blocker re-attributed to mirage-firewall (stale claim purged from
GOAL-STATUS.md). **Office 365 evaluation installs unattended** and Word launches.
**Benchmark harness bug fixed** (bash `set -u` rejects `local a="$1" b="$a"`); both sides now
run, but the comparison is NOT valid yet (stock has no QGAPERF by construction; the dom0
pixel fallback saturates). Genuine stock agent for future controls:
sha256[0:16] `3D2E6BCEC9F5BD89` from `vendor/qwt-4.2.2/installer.msi`.

## RESOLVED SINCE (both former blockers are gone)

1. **The ISO-attach failure was never an attach bug.** Root cause: the xenstore node quota in
   `win-idd-mgmt` was exhausted (994/1024), so blkback could not write the feature nodes for a
   fourth device — visible only as `-28` (ENOSPC) in the backend's dmesg and as
   `libxenlight failed to create new domain` at the top. Raising the quota fixed CD boot.
   A second, independent cause had already bitten earlier: a new qube inherits `fw-net`
   (mirage-firewall), whose vif backend never comes up, so the stubdom times out and the
   domain fails to create. `scratchpad/reprovision.sh` now sets `netvm ''` explicitly.
2. **Networking and Windows Update: verified, zero issues** on `core-net`.

## UPGRADE PATH — VERIFIED ON A GUEST (2026-08-06)

The defect that made the first E2E worthless — the MSI reporting success while leaving stock
`gui-agent.exe` in place, because Windows Installer will not overwrite a same-version file — is
fixed and the fix is demonstrated, not assumed. On `win10-e2e` (stock QWT 4.2.2.0 registered):
payload 19/19 verified → existing QWT detected → runtime stopped → uninstall rc=3010 → reboot →
resumed run → install rc=3010 → **manifest hash gate PASS**, agent `4B4CE2B1` → `77607793`, and
the guest came back from its own reboot with that binary running. Full log in
`C:\qwt-improved-install.log`; detail in FINDINGS.md.

Caveat carried forward: the package under test was the previous CI artifact with the fixed
`Install-QwtImproved.ps1` swapped in (CI copies it verbatim), because GitHub's Windows runners
kept the build queued for hours. The gate must be re-run against a real CI artifact before this
counts as release evidence.

## NOT DONE / KNOWN GAPS

- **Clean path: in progress.** A `NO_QWT=1 RELEASE_SETUP=…` image is building — Windows plus our
  package only, no stock QWT anywhere on the media, so "qrexec answers at all" is itself the
  pass condition. Not yet run.
- **Benchmark vs stock: not valid yet.** The harness bug is fixed and both sides run, but idle
  CPU is identical (0.05 %) and the loaded metric needs an interactive-session scene generator —
  a load driven from session 0 does not exercise the display path.
- **Win11 E2E: not started.**
- **Regression suite on a clean system: not run.** The suites are in place: `snap-regress.sh`,
  `soak-drag.sh`, `storm-soak.sh`.
- **Office window behaviour: blocked** on the seamless host-mode fix (`t2/seamless-hostmode`,
  cb1fa4b, unbuilt) — the M6 mode set does not contain the host size, so seamless mode fails
  `ChangeDisplaySettings` with BADMODE on an IDD-equipped guest.
- **Visual confirmation is unavailable**: `qtest shot` returns an empty tar for both the test
  guest and the control, so the dom0 screenshot service — not the guest — is what is broken.
  Every visual acceptance in this phase is therefore unproven, including the ones that would
  otherwise have passed.

## Feature freeze

Code is effectively frozen: everything since the goal was set is test infrastructure, one
installer bug fix, and documentation. No new features were added.
