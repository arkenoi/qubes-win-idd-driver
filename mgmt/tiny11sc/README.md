# tiny11sc — tiny11 "serviceable core"

A Windows 11 install ISO stripped to about what tiny11 core removes, with two things core cannot do:

- **(a) it updates through our dom0-driven updater** like any other Windows qube (`guest/qubes-windows-update.ps1`, ADR-updater);
- **(b) anything it removed comes back from the command line**: `C:\Windows\tiny11sc\tiny11sc.cmd`.

It has **no Defender** (owner, 2026-11-21), with a best-effort way back (`tiny11sc -Component Defender`).

Built on Linux from the stock Microsoft ISO. No Windows machine, no root:

```bash
mgmt/tiny11sc/build-tiny11sc.sh ~/win-iso/Win11_26300_English_x64.iso
```

Output: `Tiny11SC_<build>_<lang>_x64.iso` next to the source (or the path given as the second argument), plus a `.vendor-delta.txt`
that lists every change. Tools: `7z wimlib-imagex hivexregedit hivexget xorriso` (Fedora: `p7zip-plugins wimlib-utils hivex xorriso`;
Debian/Ubuntu: `p7zip-full wimtools libhivex-bin libwin-hivex-perl xorriso`). Disk: about 3× the source ISO, for a few minutes (no recompression).

## Why core can't do (a) and (b), and what this does instead

tiny11 core deletes most of `WinSxS` and disables Windows Update. With the component store gone, CBS can't install a cumulative
update and DISM can't add a component back. The rule here is that **nothing deletes a file the component store owns**:

| step | when | how |
|---|---|---|
| one edition (`EDITION`, default `Windows 11 Pro`; name kept exact for answer files), LZX, split into `.swm` over 4 GiB (Pro is 4.68 GB even as LZMS solid, a solid WIM can't be split, and the rig's xorriso has no UDF) | build | wimlib |
| delete Edge, EdgeCore, **Evergreen WebView2**, EdgeUpdate | build | wimlib. Not CBS components. On 26300.9457 the three are one 870 MB payload hard-linked three times, so removing Edge alone frees nothing |
| delete `Windows\System32\Recovery\Winre.wim` (791 MB) | build | wimlib. Not a component; WinRE is useless in a qube |
| Defender, MDCoreSvc, Web Threat Defense, SecurityHealth, Sense, DiagTrack, dmwappush services off; Smart App Control off; Edge updater services and registrations gone; consumer content, Copilot, Recall, widgets, chat, OneDrive-at-logon, reserved storage off; OOBE `BypassNRO` | build | offline hives (`reg/*.reg`, hivexregedit), read back by the builder |
| Setup's TPM/Secure Boot/RAM/CPU checks off (boot.wim index 2) | build | `reg/boot-SYSTEM.reg` |
| **capabilities** (FoDs), **optional features**, **provisioned apps** | install | `strip.ps1` from `SetupComplete.cmd`, as SYSTEM before the first logon, through DISM on the running OS. Each removal goes into `C:\Windows\tiny11sc\removed.json` |
| `/StartComponentCleanup /ResetBase`, hibernation off, `reagentc /disable` | install | `strip.ps1` |

**Windows Update stays exactly as shipped**: wuauserv, UsoSvc, WaaSMedicSvc, BITS, DoSvc, CryptSvc, TrustedInstaller and Schedule
are compared against the original hive, and the build fails if any of them changed. The updater searches with the WU agent and
installs through it or through `DISM /Add-Package`. A StandaloneVM that has its own internet turns Windows' automatic updating back on
(ADR-updater §17), so USO and WaaSMedic must keep working too.

## What goes at install, and what deliberately stays

- **Capabilities removed:** Steps Recorder, Quick Assist, IE mode, Hello Face, handwriting/OCR/speech/TTS, Math Recognizer, Windows Media Player (legacy),
  extended wallpapers, legacy Paint, PowerShell ISE, WordPad, every Wi‑Fi client driver, Defender for Endpoint sensor, OneSync, OpenSSH client,
  Print Management/Fax/Scan, LA57 kernel, WMIC, XPS Viewer. A pattern that matches nothing is logged, not treated as an error.
- **Capabilities kept, each for a reason:** `VBSCRIPT` (our Start-menu shortcut runs a `.vbs`), `Microsoft.Windows.Notepad.System` (the harness runs `notepad.exe`; the Notepad *app* goes),
  `Language.Basic`, the DirectX database, the Ethernet drivers (networking before the PV drivers are in), and the inbox `Microsoft.Edge.WebView`
  (a CBS package, which OS components fall back to once Evergreen WebView2 is gone).
- **Optional features removed with their payload:** Recall, Work Folders, XPS services, Defender default definitions, PowerShell 2.0 where present.
- **Apps: everything goes except an allowlist.** That way an app added by a later build is removed too. The allowlist: Store, StorePurchaseApp and App Installer (winget), which are how apps come back;
  the frameworks they depend on; `SecHealthUI` (versioned `1000.<build>` and serviced by the cumulative update); and ApplicationCompatibilityEnhancements.
- OneDrive: `OneDriveSetup.exe` is a component hard-linked from WinSxS, so it stays (deleting it would free nothing). It just never runs at logon.

## Adding things back (b)

From an elevated prompt in the guest:

```
C:\Windows\tiny11sc\tiny11sc.cmd -List                       removed items and their state now
C:\Windows\tiny11sc\tiny11sc.cmd -Name Language.OCR*         capability/feature/app/task by wildcard
C:\Windows\tiny11sc\tiny11sc.cmd -Name * -Source D:\ -LimitAccess    from a local FoD/feature source only
C:\Windows\tiny11sc\tiny11sc.cmd -Component Defender         also: Edge, WebView2, OneDrive, Telemetry
C:\Windows\tiny11sc\tiny11sc.cmd -StoreId 9WZDNCRFHVN5       any Store app
C:\Windows\tiny11sc\tiny11sc.cmd -Cleanup                    drop superseded payload before sealing
```

Capabilities and features come from Windows Update unless you pass `-Source`. Apps come from the Store through winget, and Edge and
WebView2 from winget. All of that needs a network: a template has none, so run it in a qube made from the template, or give the template a
netvm for the duration. The updater's relay is not used, because it serves update passes only.

**Defender** is restored on a best-effort basis. The original service start values are recorded **from the image at build time**
(`C:\Windows\tiny11sc\services.orig`) and written back. If Windows refuses an elevated administrator, the write runs once as TrustedInstaller
through a one-shot scheduled task. The restore also turns its tasks, definitions, SmartScreen and the tray icon back on. **Smart App
Control cannot come back.** Windows re-enables it only through a reinstall, and the tool says so.

## Status: what has and hasn't been run

- **Built and statically verified** in a Linux container (wimlib 1.14.4, hivex 1.3.23, xorriso 1.5.6) on 2026-11-21, from the official
  `Win11_26300_English_x64.iso` (26300.9457, sha256 `bd4307df…6ea650`). The build took 3 min 19 s and produced
  `Tiny11SC_26300.9457_English_x64.iso`, 6978 MiB against the source's 8628 MiB. Checks that passed:
  - the hives read back and the WU services match the source hive;
  - Edge, EdgeCore, EdgeWebView, EdgeUpdate and Winre.wim are absent, and the tiny11sc files, wuaueng/wuapi, DISM, expand,
    powershell and csc are present;
  - the WinSxS (116,211) and servicing (7,365) entry lists are identical to the source;
  - one image named `Windows 11 Pro` as `install.swm` + `install2.swm`;
  - BIOS and UEFI El Torito entries, and LabConfig in boot.wim index 2.

  The image's total bytes went from 26.8 GB to 22.7 GB offline. The rest goes at install time, and that hasn't been measured yet.
- Known untested point: the three hives and the added files are written back by `wimlib-imagex update` from Linux, so they carry
  no security descriptor of their own and inherit their folder's ACL when Setup applies the image.
- **NOT yet run on the rig.** Install, `strip.ps1`, an updater pass and a restore have never executed on Windows. The PowerShell has not
  been parse-checked (no pwsh in that container). The acceptance below has to run before this becomes a golden. Until then
  `mgmt/goldens/` gets no record for it and `docs/PROCEDURE-recreate-goldens.md` doesn't list it: a listed golden that doesn't exist sends the
  recreate procedure at an intact pool (CLAUDE.md, Rig).

### Rig acceptance (owed)

1. Install like `tiny11-base` (`ROOT_GIB=30`, `PRIMER=1`, image name `Windows 11 Pro`). Screenshots every 15 minutes as usual.
   `strip.ps1` adds minutes to Setup.
2. Check `HKLM\SOFTWARE\tiny11sc` `StripResult=ok`, then read `C:\Windows\tiny11sc\strip.log`. Every capability pattern that matched nothing
   is listed there. Confirm Defender isn't running (`sc query WinDefend`) and that `C:\Program Files (x86)\Microsoft\Edge*` is absent.
3. **(a)** Install QWT, then run a dom0 `qubes-vm-update` pass. Pass when the cumulative installs and the count it reports comes back at
   zero after the restart. Watch the Defender platform offers (KB4052623, KB5007651): they are excluded from dom0's count by
   classification, but with Defender off they may still be attempted each pass.
4. **(b)** In a clone with a netvm: `tiny11sc -Name Language.OCR*`, `tiny11sc -Name *Calculator*`, `tiny11sc -Component Defender`, then
   restart and confirm each item is back (`-List`, `Get-MpComputerStatus`).

## The record behind the lists

`inventory/26300.9457/` is what the removal lists and the claims above were read from, taken from the stock ISO's
Pro image (index 6) on 2026-11-21:

- `windowsapps.txt`: every folder under `Program Files\WindowsApps`. The app allowlist in `strip.ps1` was written against it.
- `cbs-packages.txt`: every CBS package name under `Windows\servicing\Packages`. The capability patterns came from it, and so did
  the finding that Defender's engine has no removable package on a client SKU (only its default definitions do).
- `services.orig`: the start values the build recorded and shipped inside the image, which `restore.ps1` writes back.
- `vendor-delta.txt`, `build-2.log`: the build that produced the 6978 MiB ISO. It ran the tree at 53a218a plus the files committed in
  3ab923d, before that commit's final log-line cleanup.
- `build-1-lzms-over-4gib.log`: the first attempt, where solid LZMS gave 4.68 GB. That number is why the image is LZX and split.
- `source-iso.sha256`: the Microsoft ISO it was built from.

`tools/wimdu.py` (payload bytes per path, and how much is shared with the others) and `tools/regdump.py` (a whole hive
flattened to greppable lines) produced the Edge hard-link and Edge-registration findings. The ISO, the split WIMs and
the hives are not in the repo: they are Microsoft media, they exceed GitHub's 100 MB file limit, and the repo is public.
