# STOCK-QWT control ISO build (2026-08-01, local prep only — guest untouched)

Purpose: media for the MANDATORY stock-QWT control experiment
(SESSION-HANDOFF-qwt-full.md — prove whether the netvm starvation reproduces with
stock QWT 4.2.2, or only with our from-source build).

## Command used

```
cd /home/user/qubes-win-idd && \
env -u QWT_MSI -u QWT_MSI_SHA256 \
  OUT=/home/user/win-iso/win-idd-unattended-stock.iso \
  mgmt/build-unattended-iso.sh \
  /home/user/win-iso/Win10_22H2_EnglishInternational_x64v1.iso \
  "Windows 10 Pro" --with-key
```

Exit code 0. Build log: `stock-iso-build.log` (same directory as this file).
`QWT_MSI`/`QWT_MSI_SHA256` explicitly unset via `env -u` — the log contains
`payload += installer.msi` from the plain payload loop and NO
`payload += installer.msi (OURS: ...)` line.

## What the script stages when QWT_MSI is unset (confirmed from script text)

`mgmt/build-unattended-iso.sh` line 56-60: the payload loop copies
`~/win-iso/qwt-payload/installer.msi` into `payload/` (plus vc_redist, certs,
qubesidd-test.cer). The QWT_MSI block (lines 64-73) that would overwrite it with our
CI MSI and write `installer.msi.sha256` is skipped when the variable is unset.
Default answer file (line 18): `mgmt/autounattend.xml` — the en-GB one; confirmed
identical to what the current install used (see below).
`guest/install-qwt.cmd` line 56 skips its sha256 re-check when `installer.msi.sha256`
is absent (`goto hash_done`), so the stock media installs without modification; the
msiexec line (`ADDLOCAL=PvDriversCore,Core,Gui,PvDriversNetwork`, same flags) is the
identical file byte-for-byte on both ISOs.

## Staged MSI = vendor stock, bit-identical (PASS criterion)

```
7049322128d1cf7d9dc2a48f69ef91a5893a8f779d3b2ad7d25fdfc8eee3baf4  /home/user/qubes-win-idd-driver/vendor/qwt-4.2.2/installer.msi   (reference, computed this session)
7049322128d1cf7d9dc2a48f69ef91a5893a8f779d3b2ad7d25fdfc8eee3baf4  ~/win-iso/qwt-payload/installer.msi                              (build input)
7049322128d1cf7d9dc2a48f69ef91a5893a8f779d3b2ad7d25fdfc8eee3baf4  payload/installer.msi            extracted from built ISO
7049322128d1cf7d9dc2a48f69ef91a5893a8f779d3b2ad7d25fdfc8eee3baf4  sources/$OEM$/$1/payload/installer.msi  extracted from built ISO
```

The `$OEM$` copy is the one FirstLogonCommands actually installs from (CD is gone by
first logon); both locations verified.

## Output ISO

- Path: `/home/user/win-iso/win-idd-unattended-stock.iso`
- sha256: `b723e656ed596cfce08cf7e0b0bce067df661eddad13186cfd67e57d5a34864f`
- size: 6150332416 bytes (built 2026-08-01 23:48)
- Attach: `qvm-start win-idd-test --cdrom=win-idd-mgmt:/home/user/win-iso/win-idd-unattended-stock.iso`
  (or udisksctl loop-setup per session-6 rules)

## Diff vs the current install's media (comparability statement)

Current install media = `/home/user/win-iso/win-idd-unattended.iso` (our-MSI build,
20:44, sha size 6150389760 — loop-attached to the running VM, NOT touched: stat
before/after identical, see `protected-iso-stat-before.txt` / `-after.txt`).

Full `7z l` listing diff of the two ISOs (`iso-listing-diff.txt`) shows EXACTLY three
file deltas and nothing else:
1. `payload/installer.msi` 3350528 B (ours, ff89da3c...) -> 3325952 B (stock, 70493221...)
2. `sources/$OEM$/$1/payload/installer.msi` — same swap
3. `payload/installer.msi.sha256` + `sources/$OEM$/$1/payload/installer.msi.sha256`
   (80 B) present only on the our-MSI ISO; `install-qwt.cmd` handles absence.

Per-file sha256 of autounattend.xml + entire payload from BOTH ISOs
(`current-iso-payload.sha256`, `stock-iso-payload.sha256`,
`stock-iso-oem-payload.sha256`): every file identical except installer.msi:
- `autounattend.xml` `717b03fc...` on both — and equals mgmt/autounattend.xml (en-GB)
  rendered with image name "Windows 10 Pro" + the generic Pro key (--with-key), i.e.
  the exact answer file the current install used.
- setup.cmd / setup2.cmd / firstboot-setup.ps1 / install-qwt.cmd / vc_redist.x64.exe /
  qubesidd-test.cer / 6x SigningCert*.cer: identical hashes on both ISOs.

Windows media content (boot files, sources/, split install*.swm) has identical
name+size listing on both ISOs; both were repacked from the same source ISO
(`Win10_22H2_EnglishInternational_x64v1.iso`) by the same script version (incl. the
bootfix.bin removal and wimlib .swm split).

Conclusion: the two installs will differ ONLY in which installer.msi is executed —
stock QWT 4.2.2 vs our from-source rebuild. Same unattend, same ADDLOCAL, same
firstboot flow, same certs. This satisfies the handoff's "keep the two installs
comparable" requirement on the media side. (vCPU/memory/netvm-attach procedure are
runtime parameters for the experiment session, not media.)

## Caveats

- The .swm chunks were NOT hash-compared between the two ISOs (would need ~10 GB of
  extraction); comparability rests on same source ISO + same script + identical
  name/size listing. The wimlib split was verified by the script itself
  (`wimlib-imagex verify`, in build log).
- ISO-level sha256 of the two ISOs necessarily differ (different MSI + timestamps).
- Nothing was booted or attached: this was local prep only. Guest untouched.
