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

## BLOCKED ON THE USER (small, specific)

1. **Clean-install acceptance cannot proceed**: attaching the install ISO now breaks domain
   creation (`libxenlight failed to create new domain`) for ANY new qube, while the same
   qube starts fine without the CD. Loop device recreated (allowed, worked) — no change.
   Need one line: `sudo tail -20 /var/log/libvirt/libxl/libxl-driver.log`.
2. **Networking / Windows Update**: my policy exposes only the testbed qubes, so I cannot
   see or start a netvm. Start one (`qvm-start sys-firewall`) and I can attach it myself
   (`qvm-prefs <vm> netvm …` is permitted) and run the WU test.
3. **Office evaluation** depends on (2): install rig is written and committed
   (`guest/install-office-eval.ps1`, `guest/office-window-check.ps1`).

## NOT DONE / KNOWN GAPS

- **Benchmark vs stock: not run.** `scratchpad/benchmark.sh` has an argument-passing bug
  (`side: unbound variable`) — it was authored without the ability to execute it. Needs a
  debug pass; the metric design and the isolation precondition (refuses to run while
  another Windows qube is up) are sound.
- **Win11 E2E: not started.** Blocked by the same ISO-attach failure; the Win11 ISO also
  still needs a loop device.
- **Regression suite on a clean system: not run** (same blocker). The suites themselves are
  in place: `snap-regress.sh`, `soak-drag.sh`, `storm-soak.sh`.
- **Nobody has yet installed the release package successfully end to end.** The one attempt
  found the installer bug; the fixed build is unverified on a guest.

## Feature freeze

Code is effectively frozen: everything since the goal was set is test infrastructure, one
installer bug fix, and documentation. No new features were added.
