# `packaging/` — source of the `qwt-improved-package` CI artifact

This directory builds the **one downloadable thing** a user installs in a Windows qube to
get our improved Qubes GUI agent, instead of hand-swapping `gui-agent.exe`.

It is an **overlay updater**: it requires a working Qubes Windows Tools 4.2.2 install and
replaces `gui-agent.exe` (optionally `gui-watchdog.exe`) in place, reversibly. It is not a
QWT installer and does not ship the Xen PV drivers.

**Read `ci-notes/packaging.md` for the decision record** — why not a patched upstream MSI,
why not a full QWT rebuild, what is signed and what is not, and the live test evidence.

## Contents

| file | role |
|---|---|
| `payload/install-qwt-improved.ps1` | the installer; ships inside the artifact |
| `payload/README.md` | user-facing install/uninstall doc; ships inside the artifact |
| `make-package.ps1` | CI-side assembler: CI artifacts → staging dir + `MANIFEST.json` + `SHA256SUMS.txt` |
| `ci-package-job.yml` | the proposed `package:` job for `.github/workflows/build.yml`, **as text** |

`ci-package-job.yml` is inert where it sits — GitHub Actions only reads
`.github/workflows/*`. It has not been applied; `build.yml` is owned by another agent.

## Building the artifact by hand

On a machine with PowerShell, from the repository root, with both CI artifacts unpacked:

```powershell
.\packaging\make-package.ps1 -AgentArtifact .\artifacts-agent -DriverArtifact .\artifacts -OutDir package-qwt
```

`-DriverArtifact` is optional; without it `optional/idd-driver/` is left empty and the
manifest records `idd_driver_included: false`.

## Adding another replaced binary later

Add one line to `$COMPONENT_FILES` in `payload/install-qwt-improved.ps1` (logical name →
file name) and copy the file into `bin/` in `make-package.ps1`. Everything else — planning,
backup, hashing, verification, `-Restore`, the state file — is driven off that table.

Do **not** name a variable after a parameter, even in different case: PowerShell resolves
variable names case-insensitively, and that exact collision was a real bug here (see
`ci-notes/packaging.md` §5).
