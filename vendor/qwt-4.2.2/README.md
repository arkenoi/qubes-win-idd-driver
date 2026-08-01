# vendor/qwt-4.2.2 — shipped QWT 4.2.2 inputs for the qwt-full workflow

- `installer.msi` — the inner MSI of `qubes-tools-4.2.2.exe` (WiX Burn bundle) from
  `qubes-windows-tools-4.2.2-1.fc41.noarch.rpm`, Qubes R4.3 dom0 repo. The RPM's GPG
  signature was verified during provisioning (mgmt/PROVISION-LOG.md); the bundle was
  extracted with 7z. sha256:
  `7049322128d1cf7d9dc2a48f69ef91a5893a8f779d3b2ad7d25fdfc8eee3baf4` (asserted by CI).
- `certs/SigningCert*.cer` — the six per-component public certs (all CN="Qubes Windows
  Tools", self-signed, 2025-08-03→2035-08-01) extracted from the MSI's Binary table.
  Staged as each unchanged component's `sign.crt` when rebuilding the installer.

Purpose: `qwt-full.yml` rebuilds installer.msi from the upstream WiX sources with OUR
gui-agent; every component we did NOT change is harvested bit-identical (ITL signatures
kept) from this MSI via `msiexec /a`. See ci-notes/qwt-full-build.md.

QWT is GPLv2; redistribution of these unmodified build inputs inside this development
repo is within license.
