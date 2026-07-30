# Track A — building `qubes-gui-agent-windows` (user-mode agent) in GitHub Actions

Status: **GO.** Investigated 2026-07-30. Owner of this file: the Track A CI agent.
Scope: how to build `gui-agent.exe` / `gui-watchdog.exe` / `dump-windows.exe` from the
`agent/` submodule on a GitHub-hosted `windows-2022` runner.

**Headline verdict: no EWDK, no WDK, no `qubes-builderv2` orchestration is required.**
The entire Track A build is plain MSVC v143 + Windows SDK, plus five small Qubes
user-mode libraries built from source, plus **one** synthesized import library
(`xencontrol.lib`) that lets us skip the only WDK-toolset project in the dependency tree.

---

## 1. What the agent actually is

`agent/` is **100 % user mode**. There is no kernel component anywhere in the repo
(`agent/` file tree: `gui-agent/*.c`, `watchdog/watchdog.c`, `test/dump-windows/*`,
`vs2022/*.vcxproj`). Verified by reading every `.vcxproj`:

| project | file | `ConfigurationType` | `PlatformToolset` | `WindowsTargetPlatformVersion` |
|---|---|---|---|---|
| `gui-agent` | `agent/vs2022/gui-agent/gui-agent.vcxproj` | `Application` | `v143` | `10.0` |
| `gui-watchdog` | `agent/vs2022/watchdog/watchdog.vcxproj` | `Application` | `v143` | `10.0` |
| `dump-windows` | `agent/vs2022/dump-windows/dump-windows.vcxproj` | `Application` | `v143` | `10.0` |

`v143` + `WindowsTargetPlatformVersion 10.0` is the stock VS 2022 C++ toolchain that
`windows-2022` runners already ship. `agent/README.md` says "Microsoft EWDK iso mounted as
a drive" only because upstream drives *all* QWT components (including the Xen PV KMDF
drivers) through one script, `qubes-builderv2`'s
`qubesbuilder/plugins/build_windows/scripts/build-sln.ps1`, which unconditionally calls
`Find-EWDK` and hard-errors if it is missing. That script is a *build harness*, not a
requirement of these three projects. We bypass it and call `msbuild` directly.

Solution: `agent/vs2022/gui-agent-windows.sln` (3 projects, `Debug|x64` / `Release|x64`).
Build outputs land in `agent/vs2022/x64/<Config>/<ProjectName>/` — matching
`agent/.qubesbuilder`:

```yaml
    bin:
    - vs2022/x64/@CONFIGURATION@/dump-windows/dump-windows.exe
    - vs2022/x64/@CONFIGURATION@/gui-agent/gui-agent.exe
    - vs2022/x64/@CONFIGURATION@/gui-watchdog/gui-watchdog.exe
```

`dump-windows.exe` is worth keeping: it is a standalone window-tree dumper (links only
`dwmapi.lib`, no Qubes deps) and is directly useful for Phase 2A-chrome.

---

## 2. Dependency map (verified, not guessed)

### 2.1 What the link lines demand

`agent/vs2022/gui-agent/gui-agent.vcxproj`, `<AdditionalDependencies>`:

```
ws2_32.lib dxgi.lib d3d11.lib dxguid.lib dwmapi.lib sas.lib
xencontrol.lib windows-utils.lib libvchan.lib qubesdb-client.lib
```

`watchdog.vcxproj`: `wtsapi32.lib shlwapi.lib sas.lib windows-utils.lib`.
`dump-windows.vcxproj`: `dwmapi.lib` only.

The first six of the gui-agent list are Windows SDK libs (`sas.lib`/`sas.h` = `SendSAS`,
shipped in `Windows Kits\10\{Include,Lib}\<ver>\um`). The last four are Qubes.

### 2.2 Headers actually `#include`d (grep over `agent/gui-agent`, `agent/watchdog`)

| header | comes from |
|---|---|
| `log.h`, `config.h`, `exec.h`, `list.h`, `qubes-io.h`, `vchan-common.h` | `qubes-windows-utils/include/` |
| `libvchan.h` | `qubes-core-vchan-xen/windows/include/` |
| `qubesdb-client.h` | `qubes-core-qubesdb/include/` |
| `xencontrol.h` (→ pulls `xeniface_ioctls.h`) | `xeniface/include/` (submodule of pvdrivers) |
| `qubes-gui-protocol.h` | `qubes-gui-common/include/` |
| `qwt_version.h` | **generated at build time** (`agent/include/.gitignore` lists it) |

### 2.3 Include/library search paths the project expects

Both agent projects use (verbatim from the vcxproj):

```
IncludePath  = $(VC_IncludePath);$(WindowsSDK_IncludePath);$(ProjectDir)\..\..\include;
               $(QUBES_INCLUDES);
               $(QUBES_REPO)\vmm-xen-windows-pvdrivers\inc;
               $(QUBES_REPO)\core-vchan-xen\inc;
               $(QUBES_REPO)\windows-utils\inc;
               $(QUBES_REPO)\core-qubesdb\inc;
               $(ProjectDir)\..\..\..\gui-common\include;
               $(ProjectDir)\..\..\..\qubes-gui-common\include
LibraryPath  = $(VC_LibraryPath_x64);$(WindowsSDK_LibraryPath_x64);$(QUBES_LIBS);
               $(QUBES_REPO)\vmm-xen-windows-pvdrivers\lib;
               $(QUBES_REPO)\core-vchan-xen\lib;
               $(QUBES_REPO)\windows-utils\lib;
               $(QUBES_REPO)\core-qubesdb\lib
```

So the whole dependency contract is: **populate a `$QUBES_REPO` directory with
`<component>/inc` and `<component>/lib` subdirectories**, exactly as `build-sln.ps1` does
(it walks `$repo` and appends every `*/inc` to `QUBES_INCLUDES` and `*/lib` to
`QUBES_LIBS`). Nothing else is needed.

### 2.4 Transitive build order

Read from the deps' own `.vcxproj` `<AdditionalDependencies>`:

```
xencontrol.lib          (xeniface, WDK toolset — SYNTHESIZED, see §3)
  └─ libxenvchan.lib    (pvdrivers/vs2022/libxenvchan, v143)   ← needs xencontrol.lib
       └─ libvchan.lib  (core-vchan-xen/windows, v143)          ← needs libxenvchan+xencontrol
            └─ windows-utils.lib (windows-utils, v143)          ← needs libvchan.lib
                 └─ qubesdb-client.lib (core-qubesdb/windows, v143) ← needs windows-utils.lib
                      └─ gui-agent.exe / gui-watchdog.exe
qubes-gui-common: HEADERS ONLY, no build.
```

Every one of these is `<ConfigurationType>DynamicLibrary</ConfigurationType>` +
`PlatformToolset v143` + `WindowsTargetPlatformVersion 10.0` — i.e. ordinary VS 2022
user-mode DLLs. **The only WDK-toolset project in the entire tree is
`xeniface/vs2022/xencontrol/xencontrol.vcxproj`**, which declares:

```xml
<PlatformToolset>WindowsApplicationForDrivers10.0</PlatformToolset>
...
<EnablePREfast>true</EnablePREfast>
<TreatWarningAsError>true</TreatWarningAsError>
<AdditionalOptions>/INTEGRITYCHECK %(AdditionalOptions)</AdditionalOptions>
```

That toolset only exists once the WDK VS extension is installed. We avoid it entirely.

### 2.5 Nothing is a NuGet/vcpkg package

Zero `packages.config`, zero `vcpkg.json`, zero `PackageReference` in any of these
projects. All deps are git repos. `msbuild -restore` is unnecessary (harmless).

### 2.6 Does QWT 4.2.2 already ship the `.lib`/`.h` we need? **No.**

Checked both the extracted MSI and the live guest:

* `7z x /home/user/win-iso/qwt-payload/installer.msi` → 72 files, all binaries/scripts; no
  `.h`, no `.lib`. The MSI ships `xencontrol.dll`, `libxenvchan.dll`, `libvchan.dll`,
  `qubesdb-client.dll`, `windows-utils.dll` (identified by PE export-table name via
  `objdump -p`).
* On the live VM (`tools/qtest`), the runtime DLLs live in `C:\Windows\System32\` (plus
  `C:\Program Files\Qubes Tools\bin\pvdrivers\xeniface\xencontrol.dll`), and
  `C:\Program Files\Qubes Tools\bin\` holds only `.exe`s. No SDK-ish artifacts anywhere.

So headers must come from the source repos and libs must be built (or synthesized).

### 2.7 Version pinning — exact, read off the live guest

`tools/qtest ps "... VersionInfo.FileVersion ..."` on `C:\Windows\System32` in
`win-idd-test` (QWT 4.2.2 as installed):

| DLL | FileVersion | size | ⇒ source ref to pin |
|---|---|---|---|
| `windows-utils.dll` | 4.2.2.0 | 67144 | `QubesOS/qubes-windows-utils` **`v4.2.2`** |
| `libvchan.dll` | 4.2.7.0 | 24584 | `QubesOS/qubes-core-vchan-xen` **`v4.2.7`** |
| `qubesdb-client.dll` | 4.3.1.0 | 26120 | `QubesOS/qubes-core-qubesdb` **`v4.3.1`** |
| `libxenvchan.dll` | 4.2.0.0 | 30728 | `QubesOS/qubes-vmm-xen-windows-pvdrivers` **`v4.2.0-1`** |
| `xencontrol.dll` | 9.1.0.0 | 519176 | xeniface pinned by that tag: **`9cd9a604191bf26da18b564d1686e4ee0ccf3d32`** |
| `gui-agent.exe` | 4.2.2.0 | — | our `agent/` submodule (fork of `v4.2.2`) |

(`xeniface` SHA obtained from
`gh api repos/QubesOS/qubes-vmm-xen-windows-pvdrivers/contents/xeniface?ref=v4.2.0-1`.)

Pinning to these refs means our rebuilt `gui-agent.exe` imports exactly the symbol set the
already-installed DLLs export — no ABI risk, and **we deploy only `gui-agent.exe`, never
the DLLs**.

### 2.8 `qubes-gui-common` — a hard constraint you must not get wrong

`qubes-gui-protocol.h` uses `__attribute__((may_alias))` on ~20 structs. Only
**`release4.3` / `v4.3.1` / `main`** contain the MSVC shim:

```c
#ifdef _WIN32
// TODO: fix properly for Windows
#define __attribute__(x)
#endif
```

`release4.2` (= `v4.2.5`, protocol minor 7) does **not** — it guards on `WINNT`, which
nothing defines, so `cl.exe` fails on every struct. Verified by diffing the two headers.

⇒ **use `qubes-gui-common` `v4.3.1`.** Side effect: `QUBES_GUID_PROTOCOL_VERSION` becomes
`1.8` instead of `1.7`. That matches the shipped QWT 4.2.2 (a Qubes 4.3-era build), so it
is the status quo, not a change. Corroborating evidence from the guest's own agent log:
the daemon sends message types the 4.2.2 agent ignores —

```
[20260730.220432.804-3712-W] HandleServerData: got unknown msg type 149, ignoring
[20260730.220635.114-3712-W] HandleServerData: got unknown msg type 127, ignoring
```

With `MSG_MIN = 123`, 127 = `MSG_CROSSING` and 149 = `MSG_WINDOW_DUMP_ACK` — both present
in the 1.8 enum. (Side observation for whoever owns Phase 1A/2A, not a build issue.)

---

## 3. The one hack: synthesizing `xencontrol.lib`

`xencontrol.lib` is a plain **import library** for `xencontrol.dll`. `xencontrol.h`
declares every entry point as

```c
#ifdef XENCONTROL_EXPORTS
#    define XENCONTROL_API __declspec(dllexport)
#else
#    define XENCONTROL_API __declspec(dllimport)
#endif
```

— i.e. **functions only, zero data exports**, all `extern "C"`, and on x64 there is no
name decoration. An import lib produced by `lib.exe /def:` is therefore byte-equivalent in
effect to the one the WDK build emits.

Verified two ways, and they agree exactly (21 symbols):

1. `grep -A3 '^XENCONTROL_API' include/xencontrol.h` at the pinned xeniface commit
   `9cd9a60`.
2. `objdump -p` on the real `xencontrol.dll` extracted from `installer.msi`
   (`[Ordinal/Name Pointer] Table`, ordinals 1..21).

```
LIBRARY xencontrol.dll
EXPORTS
XcClose
XcEvtchnBindInterdomain
XcEvtchnClose
XcEvtchnNotify
XcEvtchnOpenUnbound
XcEvtchnUnmask
XcGnttabMapForeignPages
XcGnttabPermitForeignAccess
XcGnttabPermitForeignAccess2
XcGnttabRevokeForeignAccess
XcGnttabUnmapForeignPages
XcOpen
XcRegisterLogger
XcSetLogLevel
XcStoreAddWatch
XcStoreDirectory
XcStoreRead
XcStoreRemove
XcStoreRemoveWatch
XcStoreSetPermissions
XcStoreWrite
```

The agent uses `XcOpen`, `XcClose`, `XcSetLogLevel`, `XcGnttabPermitForeignAccess2`,
`XcGnttabRevokeForeignAccess` (`agent/gui-agent/capture.c:216,226,278,302,385`) — all in
the list.

`libxenvchan.vcxproj` looks for `xencontrol.lib` at a hardcoded path (its `LibraryPath` has
no `$(QUBES_LIBS)`):

```
$(ProjectDir)\..\..\xeniface\vs2022\x64\Windows10$(Configuration)\
```

so we drop the synthesized lib there, i.e. `deps-src/pvdrivers/xeniface/vs2022/x64/Windows10Release/`.

> **Why not just build xencontrol with the WDK?** We could — the repo's `idd-driver` job
> already installs `windowsdriverkit11` + `WDK.vsix` successfully. But it costs ~4 min of
> WDK install per run and drags in `/INTEGRITYCHECK`, `EnableAllWarnings` +
> `TreatWarningAsError` and PREfast against a WDK newer than the one xeniface `9cd9a60`
> was written for. That is a real warning-drift risk for zero benefit, since we only want
> the import lib. Documented as **fallback F1** in §7 if the `.def` route ever misbehaves.

---

## 4. `$(QB_SCRIPTS)` — the pre/post-build events

Every Qubes vcxproj (agent included) has:

```
PreBuildEvent : powershell $(QB_SCRIPTS)\local\prebuild.ps1 <srcdir> $(QUBES_REPO)
             && powershell $(QB_SCRIPTS)\set-version.ps1 <srcdir>\version <srcdir>\include\qwt_version.h
PostBuildEvent: powershell $(QB_SCRIPTS)\local\postbuild.ps1 <srcdir> $(QUBES_REPO) $(Configuration)
```

Read the scripts (`QubesOS/qubes-builderv2`,
`qubesbuilder/plugins/build_windows/scripts/local/{prebuild,postbuild}.ps1`): **both start
with**

```powershell
# Skip if running from Qubes Builder
if (! (Test-Path -Path env:QB_LOCAL)) { exit 0 }
```

So if we set `QB_SCRIPTS` to a checkout of `qubes-builderv2` and **do not** set `QB_LOCAL`:
`prebuild`/`postbuild` no-op (no `powershell-yaml`, no cert creation, no EWDK signing), and
`set-version.ps1` — which we genuinely need, it generates `qwt_version.h` consumed by
`include/version_common.rc` — runs normally. Clean, zero divergence from upstream.

Exception: `pvdrivers`'s `libxenvchan.vcxproj` calls its own repo-local
`$(ProjectDir)\..\..\set_version.ps1`, which exists at tag `v4.2.0-1`. Nothing to do.

Alternative if `qubes-builderv2` cloning ever becomes a problem: pass
`-p:PreBuildEventUseInBuild=false -p:PostBuildEventUseInBuild=false` to every `msbuild`
call and generate the `qwt_version.h` files yourself (4 lines of PowerShell). Documented as
**fallback F2**.

---

## 5. Upstream CI — is there anything to copy?

* **No GitHub Actions anywhere.** `QubesOS/qubes-gui-agent-windows` has only
  `.gitlab-ci.yml`, which is three lines of `include:` pointing at
  `QubesOS/qubes-continuous-integration` `/r4.3/gitlab-base.yml` and
  `/r4.3/gitlab-host-qwt.yml` — GitLab runners with a pre-provisioned Windows builder VM
  and EWDK. Not portable to GitHub-hosted runners.
* The only reusable artifacts are `qubes-builderv2`'s `build_windows` scripts, analysed in
  §4. `build-sln.ps1` is the canonical reference for what env vars a Qubes Windows vcxproj
  expects (`QUBES_REPO`, `QUBES_INCLUDES`, `QUBES_LIBS`, `QB_SCRIPTS`, `TEST_SIGN`) — the
  job below reproduces that contract without the EWDK requirement.
* `agent/README.md`'s "parallel directories" layout is honoured implicitly: the vcxproj
  reaches for `..\..\..\gui-common\include`, which we satisfy via `QUBES_INCLUDES` instead
  (msbuild silently ignores non-existent include dirs).

---

## 6. Is EWDK-in-CI viable? **No — and irrelevant, since we don't need it.**

For the record, so nobody re-litigates it:

* The EWDK for VS 2022 ships as a single ISO in the **~15 GB** class (mounted; the download
  itself is multi-GB). *Approximate — not re-measured here.*
* GitHub-hosted `windows-2022` runners have on the order of **~20-30 GB free on `C:`** and a
  small `D:` temp drive. Downloading + mounting + keeping an EWDK alongside the VS install
  is marginal at best.
* Decisive: **`actions/cache` has a hard 10 GB total limit per repository.** An EWDK ISO
  cannot be cached, so every run would re-download it. That alone kills the approach.
* And it is unnecessary: §1/§2.4 show the whole Track A chain is v143 user mode.

If a *future* Track B/Track A merge ever needs to build the Xen PV **drivers**, use the
already-proven `choco install windowsdriverkit11` + `WDK.vsix` recipe from the `idd-driver`
job, not the EWDK.

---

## 7. Proposed `gui-agent` job (ready to paste — replaces the current stub)

> I do not edit `.github/workflows/build.yml`. Hand this to whoever owns that file.
> It replaces the whole `gui-agent:` block; the `idd-driver:` job is untouched.

```yaml
  # ------------------------------------------- Track A: patched qubes-gui-agent-windows
  # Pure user-mode build: VS2022 v143 + Windows SDK only. NO WDK, NO EWDK.
  # See ci-notes/trackA-build.md for the evidence behind every pin and every step.
  gui-agent:
    if: ${{ vars.AGENT_BUILD == 'true' }}
    runs-on: windows-2022
    env:
      CONFIG: Release
      # Pinned to the component versions QWT 4.2.2 actually installed in win-idd-test
      # (FileVersion read off C:\Windows\System32 on the live guest, 2026-07-30).
      WINDOWS_UTILS_REF: v4.2.2
      VCHAN_REF: v4.2.7
      QUBESDB_REF: v4.3.1
      PVDRIVERS_REF: v4.2.0-1
      XENIFACE_SHA: 9cd9a604191bf26da18b564d1686e4ee0ccf3d32
      # MUST be >= v4.3.1: earlier tags lack the `#ifdef _WIN32 / #define __attribute__(x)`
      # shim in qubes-gui-protocol.h and do not compile with MSVC.
      GUI_COMMON_REF: v4.3.1
      BUILDERV2_REF: main

    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive        # brings in agent/

      - name: Locate MSBuild and lib.exe
        id: vs
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
          $msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild `
                       -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
          $vsroot  = & $vswhere -latest -property installationPath
          $tv      = (Get-Content "$vsroot\VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt").Trim()
          $lib     = "$vsroot\VC\Tools\MSVC\$tv\bin\Hostx64\x64\lib.exe"
          if (-not $msbuild -or -not (Test-Path $msbuild)) { throw "MSBuild.exe not found" }
          if (-not (Test-Path $lib)) { throw "lib.exe not found: $lib" }
          "msbuild=$msbuild" | Out-File -Append $env:GITHUB_OUTPUT
          "lib=$lib"         | Out-File -Append $env:GITHUB_OUTPUT
          Write-Host "msbuild: $msbuild"
          Write-Host "lib    : $lib"

      - name: Fetch Qubes dependency sources
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          function Clone($url, $ref, $dir) {
            git clone --quiet --depth 1 --branch $ref $url $dir
            if ($LASTEXITCODE -ne 0) { throw "clone failed: $url @ $ref" }
          }
          Clone https://github.com/QubesOS/qubes-windows-utils.git             $env:WINDOWS_UTILS_REF deps-src/windows-utils
          Clone https://github.com/QubesOS/qubes-core-vchan-xen.git            $env:VCHAN_REF         deps-src/core-vchan-xen
          Clone https://github.com/QubesOS/qubes-core-qubesdb.git              $env:QUBESDB_REF       deps-src/core-qubesdb
          Clone https://github.com/QubesOS/qubes-gui-common.git                $env:GUI_COMMON_REF    deps-src/gui-common
          Clone https://github.com/QubesOS/qubes-vmm-xen-windows-pvdrivers.git $env:PVDRIVERS_REF     deps-src/pvdrivers
          Clone https://github.com/QubesOS/qubes-builderv2.git                 $env:BUILDERV2_REF     deps-src/builderv2
          # xeniface: HEADERS ONLY (xencontrol.h / xeniface_ioctls.h). We never build it.
          git clone --quiet --no-checkout https://xenbits.xen.org/git-http/pvdrivers/win/xeniface.git deps-src/pvdrivers/xeniface
          if ($LASTEXITCODE -ne 0) { throw "xeniface clone failed" }
          git -C deps-src/pvdrivers/xeniface fetch --quiet --depth 1 origin $env:XENIFACE_SHA
          if ($LASTEXITCODE -ne 0) { throw "xeniface fetch $env:XENIFACE_SHA failed" }
          git -C deps-src/pvdrivers/xeniface checkout --quiet FETCH_HEAD
          Test-Path deps-src/pvdrivers/xeniface/include/xencontrol.h

      - name: Synthesize xencontrol import library
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          # xencontrol.dll's 21 exports are all __declspec(dllimport) cdecl functions with
          # no data exports, so `lib /def:` yields an import lib equivalent to the WDK one.
          # Cross-checked against objdump -p of the xencontrol.dll shipped in QWT 4.2.2.
          $out = "deps-src\pvdrivers\xeniface\vs2022\x64\Windows10$env:CONFIG"
          New-Item -ItemType Directory -Force $out | Out-Null
          @'
LIBRARY xencontrol.dll
EXPORTS
XcClose
XcEvtchnBindInterdomain
XcEvtchnClose
XcEvtchnNotify
XcEvtchnOpenUnbound
XcEvtchnUnmask
XcGnttabMapForeignPages
XcGnttabPermitForeignAccess
XcGnttabPermitForeignAccess2
XcGnttabRevokeForeignAccess
XcGnttabUnmapForeignPages
XcOpen
XcRegisterLogger
XcSetLogLevel
XcStoreAddWatch
XcStoreDirectory
XcStoreRead
XcStoreRemove
XcStoreRemoveWatch
XcStoreSetPermissions
XcStoreWrite
'@ | Set-Content -Encoding ascii "$out\xencontrol.def"
          & "${{ steps.vs.outputs.lib }}" /nologo /machine:x64 `
              /def:"$out\xencontrol.def" /out:"$out\xencontrol.lib"
          if ($LASTEXITCODE -ne 0) { throw "lib.exe failed building xencontrol.lib" }

      - name: Build Qubes user-mode dependencies
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          $ws      = "${{ github.workspace }}"
          $msbuild = "${{ steps.vs.outputs.msbuild }}"
          $cfg     = $env:CONFIG
          # Contract copied from qubes-builderv2 build-sln.ps1 (minus its EWDK requirement).
          $env:QUBES_REPO  = "$ws\qubes-repo"
          $env:QB_SCRIPTS  = "$ws\deps-src\builderv2\qubesbuilder\plugins\build_windows\scripts"
          # QB_LOCAL deliberately NOT set -> prebuild.ps1/postbuild.ps1 exit 0 immediately.

          function MB([string]$proj, [string]$target) {
            $a = @($proj, '-nologo', '-m', '-v:minimal',
                   "-p:Platform=x64", "-p:Configuration=$cfg")
            if ($target) { $a += "-t:$target" }
            & $msbuild @a
            if ($LASTEXITCODE -ne 0) { throw "msbuild failed: $proj $target" }
          }
          function Stage([string]$comp, [string[]]$inc, [string[]]$lib) {
            New-Item -ItemType Directory -Force "$env:QUBES_REPO\$comp\inc" | Out-Null
            New-Item -ItemType Directory -Force "$env:QUBES_REPO\$comp\lib" | Out-Null
            $inc | ForEach-Object { Copy-Item $_ "$env:QUBES_REPO\$comp\inc\" -Force }
            $lib | ForEach-Object { Copy-Item $_ "$env:QUBES_REPO\$comp\lib\" -Force }
          }

          # 1. libxenvchan (+ the synthesized xencontrol.lib) --------------------------
          #    Build ONLY the libxenvchan project out of the solution: the sibling
          #    'pvdrivers' project drives the KMDF driver packages and is not wanted here.
          MB "$ws\deps-src\pvdrivers\vs2022\vmm-xen-windows-pvdrivers.sln" 'libxenvchan'
          Stage 'vmm-xen-windows-pvdrivers' `
            @("$ws\deps-src\pvdrivers\include\libxenvchan.h",
              "$ws\deps-src\pvdrivers\include\libxenvchan_ring.h",
              "$ws\deps-src\pvdrivers\xeniface\include\xencontrol.h",
              "$ws\deps-src\pvdrivers\xeniface\include\xeniface_ioctls.h") `
            @("$ws\deps-src\pvdrivers\vs2022\x64\$cfg\libxenvchan\libxenvchan.lib",
              "$ws\deps-src\pvdrivers\xeniface\vs2022\x64\Windows10$cfg\xencontrol.lib")

          # 2. libvchan ---------------------------------------------------------------
          MB "$ws\deps-src\core-vchan-xen\windows\vs2022\core-vchan-xen.sln" 'libvchan'
          Stage 'core-vchan-xen' `
            @("$ws\deps-src\core-vchan-xen\windows\include\libvchan.h") `
            @("$ws\deps-src\core-vchan-xen\windows\vs2022\x64\$cfg\libvchan\libvchan.lib")

          # 3. windows-utils ----------------------------------------------------------
          MB "$ws\deps-src\windows-utils\vs2022\windows-utils.sln" ''
          Stage 'windows-utils' `
            @(Get-ChildItem "$ws\deps-src\windows-utils\include\*.h" | % FullName) `
            @("$ws\deps-src\windows-utils\vs2022\x64\$cfg\windows-utils\windows-utils.lib")

          # 4. qubesdb-client ---------------------------------------------------------
          MB "$ws\deps-src\core-qubesdb\windows\vs2022\core-qubesdb.sln" 'qubesdb-client'
          Stage 'core-qubesdb' `
            @("$ws\deps-src\core-qubesdb\include\qubesdb.h",
              "$ws\deps-src\core-qubesdb\include\qubesdb-client.h") `
            @("$ws\deps-src\core-qubesdb\windows\vs2022\x64\$cfg\qubesdb-client\qubesdb-client.lib")

          Get-ChildItem -Recurse "$env:QUBES_REPO" | Select-Object FullName

      - name: Build gui-agent
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          $ws  = "${{ github.workspace }}"
          $env:QUBES_REPO     = "$ws\qubes-repo"
          $env:QB_SCRIPTS     = "$ws\deps-src\builderv2\qubesbuilder\plugins\build_windows\scripts"
          # qubes-gui-protocol.h; the vcxproj also probes ..\..\..\gui-common\include,
          # which simply does not exist here - msbuild ignores missing include dirs.
          $env:QUBES_INCLUDES = "$ws\deps-src\gui-common\include"
          & "${{ steps.vs.outputs.msbuild }}" "$ws\agent\vs2022\gui-agent-windows.sln" `
              -nologo -m -v:minimal -p:Platform=x64 "-p:Configuration=$env:CONFIG"
          if ($LASTEXITCODE -ne 0) { throw "gui-agent build failed" }

      - name: Collect package
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          $cfg = $env:CONFIG
          $out = "agent\vs2022\x64\$cfg"
          New-Item -ItemType Directory -Force package-agent | Out-Null
          foreach ($p in 'gui-agent','gui-watchdog','dump-windows') {
            Copy-Item "$out\$p\$p.exe" package-agent\ -Force
            if (Test-Path "$out\$p\$p.pdb") { Copy-Item "$out\$p\$p.pdb" package-agent\ -Force }
          }
          # Provenance: which dep refs this binary was linked against.
          @{
            configuration     = $cfg
            agent_commit      = (git -C agent rev-parse HEAD)
            windows_utils_ref = $env:WINDOWS_UTILS_REF
            vchan_ref         = $env:VCHAN_REF
            qubesdb_ref       = $env:QUBESDB_REF
            pvdrivers_ref     = $env:PVDRIVERS_REF
            xeniface_sha      = $env:XENIFACE_SHA
            gui_common_ref    = $env:GUI_COMMON_REF
            built_utc         = (Get-Date).ToUniversalTime().ToString('o')
          } | ConvertTo-Json | Set-Content package-agent\build-manifest.json
          Get-ChildItem package-agent

      - uses: actions/upload-artifact@v4
        with:
          name: gui-agent-package
          path: package-agent/
          retention-days: 14
```

**Enable it with:**

```
gh variable set AGENT_BUILD --body true
```

(run from a clone of `arkenoi/qubes-win-idd-driver`; `gh` is already authenticated in this
qube. I did not run it — enabling CI is the repo owner's call.)

Optional, only if a run needs to be forced without a push:
`gh workflow run build.yml` then `gh run watch`.

### 7.1 Optional speed-up (safe to add later, not needed for first convergence)

Insert between "Locate MSBuild" and "Fetch Qubes dependency sources":

```yaml
      - name: Cache built Qubes dependencies
        id: depcache
        uses: actions/cache@v4
        with:
          path: qubes-repo
          key: qubes-deps-v1-${{ env.WINDOWS_UTILS_REF }}-${{ env.VCHAN_REF }}-${{ env.QUBESDB_REF }}-${{ env.PVDRIVERS_REF }}-${{ env.XENIFACE_SHA }}-${{ env.CONFIG }}
```

then add `if: steps.depcache.outputs.cache-hit != 'true'` to the three dependency steps
(fetch / synthesize / build). Cached payload is a few hundred KB of `.lib`+`.h` — nowhere
near the 10 GB repo cache limit. The agent build itself must always run.

---

## 8. Verdict, risks, fallbacks

### GO. Expected first-run friction, in likelihood order

| # | Risk | Symptom | Fix |
|---|---|---|---|
| R1 | `xenbits.xen.org` unreachable / rate-limited from Actions | `xeniface clone failed` | Only two headers are needed. Swap in the GitHub mirror `https://github.com/xenserver/win-xeniface.git` (verified to exist) at a commit with the same `xencontrol.h`, or vendor `xencontrol.h` + `xeniface_ioctls.h` into `ci-notes/vendor/`. Note: `xenbits.xen.org/gitweb` is behind an Anubis JS challenge — **`git clone` over `git-http` works, raw gitweb URLs do not.** |
| R2 | `TreatWarningAsError=true` + `WarningLevel4` in `gui-agent.vcxproj` trips on a newer MSVC than upstream used | `error C2220` / warnings-as-errors | Add `-p:TreatWarningAsError=false` to the "Build gui-agent" step **for the first convergence run only**, then fix the warnings, since our own instrumentation patch must stay warning-clean for upstreaming. |
| R3 | Solution-level `-t:<project>` target name mismatch | `MSB4057: target does not exist` | Project names are verbatim from the `.sln` files: `libxenvchan`, `libvchan`, `qubesdb-client`. If msbuild complains, build the whole `.sln` (all sibling projects are v143 and their deps are already staged) except for `vmm-xen-windows-pvdrivers.sln`, where the `pvdrivers` project must stay unbuilt. |
| R4 | `sas.lib` / `sas.h` missing from the runner's SDK | `LNK1104: cannot open file 'sas.lib'` | Both ship in `Windows Kits\10\{Include,Lib}\<ver>\um`. If a given SDK lacks it, pin `WindowsTargetPlatformVersion` to an SDK that has it, or `-p:WindowsTargetPlatformVersion=10.0.22621.0`. |
| R5 | `windows-2022` runner image retired | job won't schedule | Move to `windows-2025`; nothing in this job is image-specific beyond `vswhere`-discovered VS2022. Do the same for `idd-driver` at the same time. |
| R6 | `qubes-builderv2@main` drifts and `set-version.ps1` moves | prebuild event fails | Pin `BUILDERV2_REF` to a SHA, or apply fallback **F2**. |

### Fallbacks (in order, if the primary route fails)

* **F1 — build `xencontrol` properly.** Add the `idd-driver` job's WDK step
  (`choco install windowsdriverkit11` + `WDK.vsix` via `VSIXInstaller`), then
  `msbuild deps-src\pvdrivers\xeniface\vs2022\xencontrol\xencontrol.vcxproj
  -p:Platform=x64 "-p:Configuration=Windows 10 Release"
  -p:RunCodeAnalysis=false -p:EnablePREfast=false -p:TreatWarningAsError=false`.
  Cost: ~4 min/run. Removes the `.def` step entirely.
* **F2 — drop `qubes-builderv2`.** Add
  `-p:PreBuildEventUseInBuild=false -p:PostBuildEventUseInBuild=false` to every `msbuild`
  call and pre-generate `qwt_version.h` yourself at
  `deps-src/windows-utils/include/`, `deps-src/core-vchan-xen/windows/include/`,
  `deps-src/core-qubesdb/windows/vs2022/`, `deps-src/pvdrivers/include/`, `agent/include/`
  (logic is 6 lines, copied from `set-version.ps1`: version + ".0", comma form and quoted
  string form, emitted as `QWT_FILEVERSION` / `QWT_FILEVERSION_STR` /
  `QWT_PRODUCTVERSION` / `QWT_PRODUCTVERSION_STR`).
* **F3 — build locally in a Windows VM.** Only worth it if both F1 and F2 fail. `win-idd-test`
  itself is unsuitable (no VS, no network, and it is the *measurement* target — installing a
  toolchain on it contaminates the baseline). Would need a second, separate Windows qube.
  Explicitly *not* recommended: it destroys reproducibility and the artifact trail.
* **F4 — binary patching the shipped `gui-agent.exe`.** Rejected. Phase 1A needs new timing
  instrumentation threaded through `ProcessNewFrame`/`GetFrame` and a rotating log; that is
  not a binary patch. And Phase 2A output must be a reviewable upstream diff.

### What this job does NOT do (deliberate)

* Does not build or ship `windows-utils.dll` / `libvchan.dll` / `qubesdb-client.dll` /
  `libxenvchan.dll` / `xencontrol.dll`. Only import libs are used at link time; the guest
  keeps QWT 4.2.2's signed DLLs. Deploying rebuilt DLLs would be an unnecessary risk.
* Does not sign the executables. User-mode EXEs need no signature; `gui-watchdog` launches
  `gui-agent.exe` from the `GuiAgentPath` registry value
  (`agent/include/common.h`: `REG_CONFIG_AGENT_PATH_VALUE`). An optional signing step can be
  copy-pasted from `idd-driver` if ever wanted.
* Does not touch `driver/` or the `idd-driver` job.

---

## 9. Deployment note for whoever does Phase 1A step 3

The artifact ships a bare `gui-agent.exe`. On the guest it replaces
`C:\Program Files\Qubes Tools\bin\gui-agent.exe` (confirmed present, FileVersion 4.2.2.0).
Logs land in `C:\Program Files\Qubes Tools\log\gui-agent-<ts>-<pid>.log` (confirmed:
`gui-agent-20260730-220432-3708.log`), driven by `windows-utils`' `LogInit`, level from
`HKLM\Software\Invisible Things Lab\Qubes Tools`. Back up the original as `.orig` before
swapping.

Two things already visible in that log, for the Phase 1A owner (not build issues):

```
[20260730.220443.005-3760-E] GetFrame: duplication->AcquireNextFrame() failed with error 0x887a0026: The keyed mutex was abandoned.
[20260730.220443.005-3760-W] CaptureThread: failed to get frame
[...] HandleServerData: got unknown msg type 149, ignoring     # MSG_WINDOW_DUMP_ACK
[...] HandleServerData: got unknown msg type 127, ignoring     # MSG_CROSSING
```

---

## 10. Evidence index (files/commands actually read)

* `agent/README.md`, `agent/build.cmd`, `agent/vs.cmd`, `agent/.qubesbuilder`,
  `agent/.gitlab-ci.yml`, `agent/version`
* `agent/vs2022/gui-agent-windows.sln`, `agent/vs2022/{gui-agent,watchdog,dump-windows}/*.vcxproj`
* `agent/include/{common.h,version_common.rc,.gitignore}`, `agent/gui-agent/qga.rc`
* `agent/gui-agent/capture.c:196,216,226,278,302,385` (xencontrol API usage)
* `.github/workflows/build.yml` (read only; the `idd-driver` WDK recipe)
* `QubesOS/qubes-builderv2` @ main:
  `qubesbuilder/plugins/build_windows/scripts/{build-sln.ps1,common.ps1,set-version.ps1}`
  and `scripts/local/{build,prebuild,postbuild,functions,sign}.ps1`
* `.qubesbuilder` + relevant `.vcxproj` of `qubes-windows-utils`, `qubes-core-vchan-xen`,
  `qubes-core-qubesdb`, `qubes-vmm-xen-windows-pvdrivers`
* `xeniface` @ `9cd9a60` (cloned from `xenbits.xen.org/git-http/pvdrivers/win/xeniface.git`):
  `include/xencontrol.h`, `vs2022/{configs.props,targets.props,xencontrol/xencontrol.vcxproj,xeniface.sln}`
* `qubes-gui-common` `v4.2.5` vs `v4.3.1` `include/qubes-gui-protocol.h` (diffed)
* `7z x /home/user/win-iso/qwt-payload/installer.msi` + `objdump -p` on the extracted PEs
* Live guest via `tools/qtest run` / `tools/qtest ps`: QWT install layout, DLL FileVersions,
  `gui-agent.exe` version, agent log contents
