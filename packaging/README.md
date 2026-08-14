# `packaging/` — the downloadable artifacts

Two different deliverables live here. Pick by what the target guest already has.

| you want | artifact | built by | assembler |
|---|---|---|---|
| install on a **clean** Windows guest | `qwt-improved-setup` (dir) and `qwt-improved-iso` | `.github/workflows/release-package.yml` | `make-setup.ps1` + `make-iso.sh` |
| update the agent on a guest that **already runs QWT 4.2.2** | `qwt-improved-package` | the `package:` job in `build.yml` | `make-package.ps1` |

## The clean-guest installer — `qwt-improved-setup` / `qwt-improved-iso`

A **full QWT install**, not an overlay. `release-package.yml` calls `qwt-full.yml` (which
rebuilds the genuine `installer.msi` from the upstream WiX v4 sources with OUR gui-agent
and every other component bit-identical to the shipped ITL MSI), then stages:

```
install.cmd                entry point, self-elevating
Install-QwtImproved.ps1    two-stage installer (testsigning+certs -> reboot -> msiexec)
README.txt                 what it installs, what it does NOT, and the netvm caveat
MANIFEST.json              commit / agent commit / CI run id / per-file sha256
SHA256SUMS.txt             verified by the installer BEFORE it touches the machine
msi/installer.msi          our rebuilt MSI (QWT-NG 4.3, from upstream QWT 4.2.2 sources)
msi/vc_redist.x64.exe      the Burn bundle's prerequisite package
certs/                     6 ITL component certs + our CI test-signing cert
idd-driver/                the IddCx driver + devcon.exe (staged and ACTIVATED by default;
                           /noidd skips it, /iddoff undoes it on an installed guest)
reference/                 the gui-agent binaries embedded in the MSI, for hash checks
```

`qwt-improved-iso` is that same tree as an ISO 9660 + Joliet + Rock Ridge image (not
bootable) plus `README.txt`, `MANIFEST.json` and `SHA256SUMS.txt` beside it — attach it as
a CD to a qube with no networking. `make-iso.sh` extracts the image back out and re-checks
every file against `SHA256SUMS.txt` under **both** the Rock Ridge and the Joliet names, so
a truncated or mangled payload fails in CI rather than on the user's guest.

Guest install command: `D:\install.cmd` (elevated), or `D:\install.cmd /auto` for a fully
unattended two-reboot install. See `packaging/setup/README.txt` for the rest, including the
standing **networking blocker** (attaching a netvm starves the guest; not yet attributed to
this package vs the upstream PV drivers).

## The overlay updater — `qwt-improved-package`

It requires a working Qubes Windows Tools 4.2.2 install and replaces `gui-agent.exe`
(optionally `gui-watchdog.exe`) in place, reversibly. It is not a QWT installer and does not
ship the Xen PV drivers. It stays because it is the fast path for iterating on the agent.

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
