# Packaging — shipping our QWT changes as one installable artifact

Status: **implemented** (option B, overlay package). Investigated and tested 2026-07-31.
Owner of this file and of `packaging/`: the packaging agent.

Goal (CLAUDE.md deliverable (e)): one downloadable CI artifact a user installs in a Windows
qube to get our improved QWT, instead of hand-swapping `gui-agent.exe`.

**Verdict up front: what we can honestly ship is an OVERLAY UPDATER for the GUI agent.**
It requires an existing, working QWT 4.2.2 install and replaces `gui-agent.exe` (optionally
`gui-watchdog.exe`) in place, with a byte-exact backup and a `-Restore` switch. It does not
and cannot ship Qubes Windows Tools itself. Sections 1–3 are the evidence for that call.

---

## 0. What was measured/verified, and how

Everything in §1–§3 was verified on this qube against the real artifacts:

* `~/win-iso/qwt-payload/installer.msi` — the inner MSI of the shipped
  `qubes-tools-4.2.2.exe` (WiX Burn bundle), extracted during provisioning
  (`mgmt/PROVISION-LOG.md`), sha256 `7049322128d1cf7d9dc2a48f69ef91a5893a8f779d3b2ad7d25fdfc8eee3baf4`.
* the live guest `win-idd-test` via `tools/qtest`.
* the `agent/` submodule at `2248d8f5` and the `gui-agent-package` CI artifact.

Nothing below is from memory of how MSIs "usually" work; each claim names its check.

---

## 1. Option A — patch the upstream MSI / bundle

### 1.1 It is *mechanically* possible — and the usual objection is wrong

The common objection ("the MSI is code-signed by ITL, repackaging breaks the signature") is
**false for this build**. Checked the PE/CFB structures directly:

| object | check | result |
|---|---|---|
| `qubes-tools-4.2.2.exe` (Burn bundle) | PE optional-header data directory #4 (Certificate Table) | **`rva=0, size=0` → NOT Authenticode-signed** |
| `installer.msi` | CFB streams `\x05DigitalSignature`, `\x05MsiDigitalSignatureEx` | **absent → NOT Authenticode-signed** |
| 40 PE files inside `cab1.cab` | Certificate Table per file | **all 40 signed**, each with an 8264-byte WIN_CERTIFICATE |

The per-file signer is a **self-signed** certificate, `CN=Qubes Windows Tools`, valid
2025-08-03 → 2035-08-01, RFC3161-timestamped by DigiCert. It chains to nothing public; the
MSI's `Wix4Certificate` table (`DriversCert`, `VchanCert`, `UtilsCert`, `DbCert`,
`AgentCert`, `GuiCert`) installs it into the machine `Root`/`TrustedPublisher` stores at
install time. The six certs are also on this qube at `~/win-iso/qwt-certs/`, and
`SigningCertGui.cer` is the one under which `gui-agent.exe` is signed.

So the trust anchor for the shipped bits is **the GPG signature on
`qubes-windows-tools-4.2.2-1.fc41.noarch.rpm` from the Qubes R4.3 dom0 repo** (verified
during provisioning), not Authenticode on the installer.

The payload swap itself is also tractable: `installer.msi` stores its files in one embedded
`cab1.cab` (LZX:18, 72 entries, WiX-style `fil…` keys). `gui-agent.exe` is
`filLz3zXtcvvpre1JRZGvP26wV0.sM` (80968 bytes) and `gui-watchdog.exe` is
`filsFmWg7xzGt35BXSLJ.Bzjw1uuV0` (24648 bytes) — sizes confirmed against the live guest's
`gui-agent.exe.orig` / `gui-watchdog.exe`. A Windows runner has everything needed to
rewrite it: `makecab.exe` for the cabinet, the `WindowsInstaller.Installer` COM automation
(or WiX `msidb.exe`) to `UPDATE` `File.FileSize`/`File.Version`, drop the `MsiFileHash` row,
and re-import the `Media`/`_Streams` cab. The MSI also has `FindRelatedProducts` /
`MigrateFeatureStates` / `RemoveExistingProducts` in its sequences, i.e. a WiX
`MajorUpgrade`, so a bumped `ProductVersion` + new `ProductCode` would upgrade cleanly
rather than collide.

### 1.2 Why we still do not do it

1. **CI cannot obtain the MSI honestly.** It is not in this repo (3.2 MB binary, and it is
   not ours), and there is no published standalone download — the only supported source is
   the `qubes-windows-tools` RPM in the Qubes **dom0** repo. A `package` job would have to
   fetch a 26 MB RPM from a Qubes mirror on every run and unpack ISO → Burn bundle → MSI.
2. **It would destroy the only real chain of trust.** A user installing our rebuilt MSI
   gets ITL's PV drivers, qrexec agent and qubesdb daemon from *us*, with no Qubes GPG
   signature to check and no ITL Authenticode on the container. That is strictly worse than
   "install upstream QWT from the signed RPM, then overlay one 86 KB file".
3. **It buys nothing.** 70 of the 72 payload files would be bit-identical copies. The delta
   we actually produce is one executable.
4. **It inherits QWT 4.2.2's test-signing launch condition anyway.** The MSI asserts
   `SYSTEMSTARTOPTIONS >< "TESTSIGNING"` (ASCII `TESTSIGNING` + `SystemStartOptions` are
   present in the MSI; behaviour confirmed during provisioning, which is why
   `mgmt/payload-setup.cmd` is two-stage). So a "one-step full installer" from us would
   still not be one step on a stock Windows qube.

**Kept as a documented fallback**, not built. If it is ever wanted, §1.1 is the recipe.

---

## 2. Option C — rebuild all of QWT from upstream source

**Not feasible in this CI, with evidence.**

`ci-notes/trackA-build.md` establishes that we build the *user-mode* agent with plain VS2022
v143 and no WDK, by deliberately **avoiding the one WDK-toolset project** in the dependency
tree: `xeniface/vs2022/xencontrol/xencontrol.vcxproj`
(`PlatformToolset = WindowsApplicationForDrivers10.0`), whose import library we synthesize
with `lib.exe /def:` instead. The same file records that building `pvdrivers.sln` fails
(MSB3073) because its `pvdrivers.vcxproj` custom build step compiles the KMDF drivers via
`build.ps1` and needs the WDK/EWDK we do not have.

QWT is mostly those drivers. The MSI payload contains `xenbus.sys`, `xenfilt.sys`,
`xeniface.sys`, `xenvif.sys`, `xennet.sys`, `xenvbd.sys`, `xendisk.sys`, `xencrsh.sys` plus
their `.inf`/`.cat` (read out of `cab1.cab`). Rebuilding them means: EWDK in CI, plus a
catalog + driver signature Windows will load — which for a stock Windows qube means an
EV/attestation-signed driver we cannot produce, and for a test qube means test-signing that
upstream already does. On top of that, the MSI itself is built from
`qubes-installer-windows-tools` (WiX v4 `Package.wxs`), which this repo does not vendor.

Cost: multiple sessions of EWDK-in-CI plumbing. Benefit over the overlay: zero, because we
changed no driver.

---

## 3. Option B — overlay updater (**chosen, implemented**)

One artifact, `qwt-improved-package`, containing our binaries, a manifest, hashes, a README
and an idempotent PowerShell installer that:

* auto-detects the QWT bin directory from
  `HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools` → `GuiAgentPath`, then `InstallDir`
  (verified on the live guest: `InstallDir = C:\Program Files\Qubes Tools\`,
  `GuiAgentPath = C:\Program Files\Qubes Tools\bin\gui-agent.exe`);
* stops `QubesGuiWatchdog`, kills `gui-agent.exe` (the watchdog respawns it, so it must go
  first), replaces the file, restarts, and **verifies** by SHA-256 + service state + process
  presence;
* keeps a `.orig` backup it never overwrites, so `-Restore` reproduces stock QWT byte for
  byte;
* is a true no-op on re-run (does not even bounce the service if the hashes already match).

This generalises `guest/swap-agent.ps1`, which does the same thing for one file with no
manifest, no hash verification and no idempotency.

### 3.1 Honest scope statement (also in the shipped README)

* Replaces `bin\gui-agent.exe`. Optionally `bin\gui-watchdog.exe`.
* Touches nothing else: not QWT, not the PV drivers, not `qrexec-agent.exe`, not
  `qubesdb-daemon.exe`, not services, not registry.
* Requires QWT 4.2.2 already installed. Fresh machines: install upstream QWT first (README
  gives the sequence), then overlay.

### 3.2 Why `gui-watchdog.exe` ships but is not installed by default

`git diff --name-status v4.2.2..HEAD` in `agent/` shows the watchdog's **only** change is
`vs2022/watchdog/watchdog.vcxproj` — build plumbing. `watchdog/watchdog.c` is untouched.
Installing our rebuild would swap an upstream-signed binary (24648 bytes) for a
functionally identical local one (16896 bytes; the size delta is build settings, both carry
`FileVersion 4.2.2.0`) and put the service that keeps the GUI alive on a less-tested
binary, for no gain. It is in the package for completeness and for developers testing a
watchdog change; `-Components all` opts in, and that path is tested (§5).

### 3.3 Code signing

Our binaries are not signed by `CN=Qubes Windows Tools` (we do not have that key). This
changes nothing functionally: Windows does not enforce Authenticode on user-mode EXEs, and
the watchdog does not verify the agent's signature — demonstrated by the fact that the
hand-swapped agent has been running on `win-idd-test` since Phase 1A. `SHA256SUMS.txt` and
`MANIFEST.json` are the integrity mechanism instead. The proposed `package` job has an
**optional, off-by-default** step that test-signs the two EXEs with the same throwaway cert
the `idd-driver` job uses (gated on `vars.SIGNING_ENABLED`), purely so
`Get-AuthenticodeSignature` reports a known publisher on `win-idd-test`.

### 3.4 Known wart: version resources are indistinguishable

Our `gui-agent.exe` carries `FileVersion 4.2.2.0`, identical to the shipped one (confirmed
on the guest: both report `4.2.2.0`, sizes 86528 vs 80968). Version number is therefore
useless for "is our build installed?"; the installer answers that by SHA-256 instead.
Worth fixing upstream-side eventually (the fork deleted `set_version.ps1`), but out of scope
here.

---

## 4. Files

| path | what |
|---|---|
| `packaging/payload/install-qwt-improved.ps1` | the installer that ships inside the artifact |
| `packaging/payload/README.md` | user-facing install/uninstall doc, ships inside the artifact |
| `packaging/make-package.ps1` | CI-side assembler: artifacts → staging dir + `MANIFEST.json` + `SHA256SUMS.txt` |
| `packaging/ci-package-job.yml` | the proposed `package:` job, as text (see §6) |

Artifact layout:

```
qwt-improved-package/
  install-qwt-improved.ps1
  README.md
  MANIFEST.json           package version, agent commit, dep refs, build time, per-file hashes
  SHA256SUMS.txt
  bin/                    gui-agent.exe, gui-watchdog.exe        <- installable
  symbols/                gui-agent.pdb, gui-watchdog.pdb        <- never installed
  tools/                  dump-windows.exe, ddaprobe.exe         <- never installed
  optional/idd-driver/    IddSampleDriver.*, IddSampleApp.exe, devcon.exe  <- never installed
```

`optional/idd-driver/` exists only so one artifact carries everything CI built; the
installer never references it. Phase 1B has not cleared the IDD for use on a real Windows
qube.

`MANIFEST.json` does **not** duplicate the dependency refs: `make-package.ps1` parses them
out of the `gui-agent` job's `env:` block in `.github/workflows/build.yml`, so it cannot
drift. Verified against the current workflow — it yields `WINDOWS_UTILS_REF v4.2.2`,
`VCHAN_REF v4.2.7`, `QUBESDB_REF v4.3.1`, `PVDRIVERS_REF v4.2.0-1`, `XENIFACE_SHA 9cd9a604…`,
`GUI_COMMON_REF v4.3.1`, `BUILDERV2_REF main`. If parsing ever fails the manifest says
`UNRESOLVED` rather than guessing.

---

## 5. Test evidence (live `win-idd-test`, 2026-07-31)

The package was staged locally (this qube has no `pwsh`; a Python stand-in reproduced the
exact layout `make-package.ps1` produces), pushed with `tools/qtest push`, and driven
through the full cycle with `guest/run-elevated.ps1` (qrexec lands unelevated as
`win-idd-test\user`, confirmed `IsInRole(Administrator) = false`).

| step | result |
|---|---|
| PowerShell 5.1 parse of both scripts (`[Parser]::ParseFile`) | `OK`, 0 errors each |
| `-Status` (unelevated) | correct detection: `state=package`, backup `3D2E6BCE…` (80968), service `Running` |
| `-Restore` (elevated) | `ok=true`, agent back to shipped `3D2E6BCE…` 80968, service `Running` |
| `qtest shot` after restore | live seamless Notepad window |
| install (default `-Components agent`) | `ok=true changed=true verified=true`, agent `E7D39E51…` 86528, exit 0 |
| `qtest shot` after install | live seamless Notepad window |
| install again | `already_current=true changed=false ok=true` — no service bounce |
| `-Components all` | watchdog backed up + installed (16896), `ok=true`, agent+service up |
| `qtest shot` with our watchdog | live seamless windows |
| `-Components watchdog -Restore` | watchdog back to shipped 24648, `ok=true` |
| final `-Components all -Status` | agent=`package` 86528, watchdog=`original` 24648, service `Running` |

The VM was left exactly as found (our agent installed, shipped watchdog), plus three benign
new files: `bin\gui-watchdog.exe.orig`, `Qubes Tools\qwt-improved-state.json`, and the
pushed package under `QubesIncoming`.

**Bug found and fixed by this testing:** the installer originally used a constant named
`$COMPONENTS`, which PowerShell resolves case-insensitively to the `$Components`
*parameter*; the assignment was rejected by the parameter's `ValidateSet`, leaving the
lookup table equal to the parameter array, so every component resolved to a null filename
and the script silently targeted the bin *directory* instead of `gui-agent.exe`. Renamed to
`$COMPONENT_FILES`. A static read would not have caught this.

---

## 6. Proposed `package` job (NOT applied — `.github/workflows/build.yml` is owned elsewhere)

Append the block below to the existing `jobs:` mapping. It adds one job and modifies
neither green job. Same text lives in `packaging/ci-package-job.yml`.

Design notes:
* `needs: [gui-agent, idd-driver]` plus `if: always() && needs.gui-agent.result == 'success'`
  — the package still builds if the driver job fails, and is correctly **skipped** when
  `vars.AGENT_BUILD != 'true'` (the `gui-agent` job is skipped, so there is nothing to ship).
* the idd-driver download is `continue-on-error: true` and the assembler degrades to an
  empty `optional/idd-driver/`.
* `fetch-depth: 0` + `submodules: true` so `git describe` in `agent/` resolves.

```yaml
  package:
    needs: [gui-agent, idd-driver]
    if: ${{ always() && needs.gui-agent.result == 'success' }}
    runs-on: windows-2022
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true
          fetch-depth: 0

      - name: Download gui-agent artifact
        uses: actions/download-artifact@v4
        with:
          name: gui-agent-package
          path: dl/gui-agent

      - name: Download idd-driver artifact (best effort)
        id: dl_driver
        continue-on-error: true
        uses: actions/download-artifact@v4
        with:
          name: idd-driver-package
          path: dl/idd-driver

      - name: Assemble package
        shell: pwsh
        run: |
          $mkArgs = @('-AgentArtifact', 'dl/gui-agent', '-OutDir', 'package-qwt')
          if ('${{ steps.dl_driver.outcome }}' -eq 'success') {
            $mkArgs += @('-DriverArtifact', 'dl/idd-driver')
          } else {
            Write-Warning 'idd-driver artifact unavailable; packaging without optional/idd-driver'
          }
          & .\packaging\make-package.ps1 @mkArgs

      - name: Test-sign installable binaries (optional)
        if: ${{ vars.SIGNING_ENABLED == 'true' }}
        shell: pwsh
        env:
          PFX_B64: ${{ secrets.SIGNING_PFX_B64 }}
          PFX_PASS: ${{ secrets.SIGNING_PFX_PASS }}
        run: |
          [IO.File]::WriteAllBytes('cert.pfx', [Convert]::FromBase64String($env:PFX_B64))
          $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe |
              Where-Object FullName -match 'x64' | Select-Object -First 1
          if (-not $signtool) { throw 'signtool.exe not found' }
          Get-ChildItem dl\gui-agent -Filter *.exe | ForEach-Object {
              & $signtool.FullName sign /fd sha256 /f cert.pfx /p $env:PFX_PASS $_.FullName
              if ($LASTEXITCODE -ne 0) { throw "signtool failed on $($_.Name)" }
          }
          Remove-Item cert.pfx
          $mkArgs = @('-AgentArtifact', 'dl/gui-agent', '-OutDir', 'package-qwt')
          if ('${{ steps.dl_driver.outcome }}' -eq 'success') { $mkArgs += @('-DriverArtifact', 'dl/idd-driver') }
          & .\packaging\make-package.ps1 @mkArgs

      - name: Show manifest
        shell: pwsh
        run: Get-Content package-qwt\MANIFEST.json

      - uses: actions/upload-artifact@v4
        with:
          name: qwt-improved-package
          path: package-qwt/
          retention-days: 14
```

**Untested in CI (UNVERIFIED):** `make-package.ps1` has been syntax-checked under PowerShell
5.1 on the guest and its workflow-parsing logic was verified against the real `build.yml`,
but it has never run on a GitHub runner — nobody has applied the job yet. The optional
signing step is likewise unrun; if `signtool.exe` is absent from the `windows-2022` image
without the WDK, drop the step (it is already off by default).

---

## 7. If someone wants a real "one-click full installer" later

In rough order of honesty/effort:

1. **Best:** get the agent change upstream (it is a Phase 2A deliverable anyway). Then the
   official, GPG-signed QWT contains it and no packaging problem exists.
2. **Middle:** build our *own small* MSI (WiX, new `UpgradeCode`) that carries only
   `gui-agent.exe` and declares a launch condition on QWT being present. Gains ARP entry and
   `msiexec /x` uninstall over the .ps1; costs a WiX toolchain in CI and a second product to
   version. Not obviously worth it.
3. **Worst:** §1's patched upstream MSI. Only if a fully offline, single-file QWT install is
   a hard requirement, and only with the trust caveat in §1.2 stated loudly.
