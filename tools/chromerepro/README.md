> **ACCEPTANCE METHOD CORRECTED — do not count screenshot PNGs.**
> `local.WinScreenshot` runs `import -window <id>`, which silently FAILS on
> WS_EX_LAYERED/WS_EX_TRANSPARENT windows, so the tar contained 1 PNG while the agent had
> actually mapped 5 windows. Counting PNGs would have reported a false PASS before the fix
> was even installed.
>
> Count `SendWindowMap` in the agent log instead — it measures exactly what the agent
> presents to dom0:
> ```
> tools/qtest ps "Get-Content (Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent-*.log' | Sort LastWriteTime -Desc | Select -First 1).FullName | Select-String SendWindowMap"
> ```
>
> **Measured result on win-idd-test (Win10 LTSC 2021, seamless):**
> | agent | windows mapped |
> |---|---|
> | shipped QWT 4.2.2 | **5** (main + 4 shadow strips) |
> | with the 2A-chrome fix | **1** (main only) |

# chromerepro — Office compound-window repro, without Office

Phase 2A-chrome test harness (see `../../CLAUDE.md` and
`../../instrumentation/PHASE2A-SCOPE.md` §3).

Office 2013+ draws its frame shadow with **extra top-level windows** around the real frame:
`WS_POPUP` + `WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`,
click-through, **owned** by the main frame. The unpatched gui-agent maps every one of them,
and `qubes-gui-daemon` draws a qube border around each — one Office window turns into five
separately bordered fragments in dom0.

`chromerepro.exe` builds exactly that layout out of nothing but user32, so the fix can be
tested and regression-tested on a guest with no Office installed.

## What it creates

| role | style / exstyle | owned by | expected in dom0 **before** the fix | **after** |
|---|---|---|---|---|
| `main` | `WS_OVERLAPPEDWINDOW` | — | bordered window | bordered window |
| `shadow0..3` | `WS_POPUP` + `LAYERED\|TRANSPARENT\|TOOLWINDOW\|NOACTIVATE` | `main` | 4 bordered windows | **gone** |
| `popup` (`--popup`, or F2) | `WS_POPUP\|WS_BORDER`, not layered | `main` | 1px-bordered (override_redirect) | unchanged |
| `ghost` (`--ghost`, or F3) | `WS_OVERLAPPEDWINDOW` + `LAYERED`, alpha **0** | — | bordered window showing nothing | **gone** |
| `control` (`--control`) | `WS_POPUP\|WS_BORDER` + `LAYERED` alpha 200 + `TOOLWINDOW`, **not** `TRANSPARENT` | `main` | bordered window | bordered window (**must not disappear**) |

`control` is the regression canary: it is layered, owned, undecorated and non-taskbar, i.e.
it matches every clause of the agent's chrome rule *except* `WS_EX_TRANSPARENT`. If a future
loosening of the predicate makes `control` vanish, the predicate has gone too far.

### Why the strips are fat

Real Office shadow strips are ~8 px thick. `ShouldAcceptWindow()` has always rejected
anything smaller than `SM_CXMIN × SM_CYMIN` (~136×39 on a 96 DPI Win10 guest) **in both
dimensions**, so an 8 px strip would be dropped by the pre-existing size filter and the
"before" case would never reproduce. chromerepro therefore sizes each strip at
`max(SM_CXMIN, SM_CYMIN) + 24` px in its thin dimension — computed at runtime, printed in
the inventory file. The strips are visually fatter than Office's, but they exercise the same
code path in the agent, which is the point.

(Corollary, **UNVERIFIED**: whatever Office actually creates must be bigger than
`SM_CXMIN × SM_CYMIN`, otherwise the old size filter would already have hidden it and the
bug would not exist. Worth confirming with a `dump-windows` / `winenum` capture in the
user's real Office qube before claiming the fix covers the real thing.)

## Build

CI builds it in the existing **`idd-driver`** job exactly like `tools/ddaprobe` — plain
v143, `/MT`, output at `tools\chromerepro\x64\Release\chromerepro.exe`. `build.yml` was **not**
edited by this change; add the step below (mirrors the `Build ddaprobe` step, and the
`Add unsigned tools to package` step so the exe ships in `idd-driver-package`):

```yaml
      - name: Build chromerepro
        shell: pwsh
        run: |
          # tools/chromerepro: Phase 2A-chrome repro app (CLAUDE.md 2A-chrome.3).
          # Plain v143 toolset + /MT, no WDK dependency -> its own msbuild invocation.
          $msbuild = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
              -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe |
              Select-Object -First 1
          & $msbuild tools\chromerepro\chromerepro.vcxproj /p:Configuration=Release /p:Platform=x64 /t:Build
          if ($LASTEXITCODE -ne 0) { throw "chromerepro msbuild failed" }
          Get-ChildItem tools\chromerepro\x64\Release\chromerepro.exe
```

and, inside the existing `Add unsigned tools to package` step (after signing, so it never
lands in the directory `Inf2Cat` catalogs):

```yaml
          $repro = Get-ChildItem tools\chromerepro -Recurse -Filter chromerepro.exe -ErrorAction SilentlyContinue |
              Where-Object FullName -match 'x64.*Release' | Select-Object -First 1
          if ($repro) { Copy-Item $repro.FullName package\ -Force } else { Write-Warning 'chromerepro.exe missing from package' }
```

Local build (on a machine with VS2022):

```
msbuild tools\chromerepro\chromerepro.vcxproj /p:Configuration=Release /p:Platform=x64
```

## Run the acceptance test

All commands from the dev qube, repo root, with
`export QTEST_INCOMING='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'`.

```bash
# 0. get the exe (from the CI artifact, or build it locally)
gh run download -n idd-driver-package -D artifacts/
tools/qtest push artifacts/chromerepro.exe

# 1. start it. `start ""` so qubes.VMShell returns immediately instead of blocking
#    on a GUI app that never exits.
tools/qtest run 'start "" "%USERPROFILE%\Documents\QubesIncoming\win-idd-mgmt\chromerepro.exe" --popup'

# 2. what it actually created (class/styles/owner/rect/alpha per window)
tools/qtest run 'type %TEMP%\chromerepro.txt'

# 3. the measurement: one PNG per window the daemon knows about
tools/qtest shot /tmp/chrome-before.tar
tar tf /tmp/chrome-before.tar        # count the PNGs
mkdir -p /tmp/chrome-before && tar xf /tmp/chrome-before.tar -C /tmp/chrome-before

# 4. stop it
tools/qtest run 'taskkill /f /im chromerepro.exe'
```

`local.WinScreenshot` returns **one PNG per top-level window the GUI daemon has**, so the
tarball's file count *is* the number of separately bordered windows — that is the acceptance
measurement, no pixel-peeping required. Ignore the PNGs that belong to other things running
in the guest (explorer's tray windows etc.); baseline the count with chromerepro **not**
running and diff.

### Acceptance

Run once with the **stock** agent binary (`gui-agent.exe.orig` from the Phase 1A swap) and
once with the patched one, same command line.

| run | chromerepro windows in the `qtest shot` tar |
|---|---|
| `chromerepro.exe` — **before** fix | **5** (main + 4 shadow strips) |
| `chromerepro.exe` — **after** fix | **1** (main only) |
| `chromerepro.exe --popup` — after fix | **2**: main (normal border) + popup (1 px border, `override_redirect`) |
| `chromerepro.exe --ghost` — before / after | 2 / 1 |
| `chromerepro.exe --control` — before / after | 2 / **2** (control must survive) |

Cross-check in the agent log (`C:\Program Files\Qubes Tools\log\gui-agent.log`, debug level):
each rejected strip should log exactly one

```
0x....: rejecting compound-window chrome (class 'QubesChromeReproShadow', owner 0x...., style 0x........, exstyle 0x........, alpha 160)
```

and the ghost one `rejecting fully transparent layered window`. It should appear **once per
window**, not once per frame — the Phase 2A reject cache remembers them, and a repeat every
frame means the cache signature is being invalidated (a bug worth chasing).

### Interactive keys (main window focused)

* `F2` — toggle the popup
* `F3` — toggle the alpha-0 ghost (only if started with `--ghost`)
* `F5` — re-dump the inventory to `%TEMP%\chromerepro.txt`
* `Esc` — quit

Dragging the main window moves the strips with it, so the same app doubles as a
compound-window drag test for the Phase 2A performance harness.

## Note on borders

The fix is entirely guest-side: the agent stops *presenting* chrome fragments as windows.
Nothing here weakens or bypasses the daemon-side qube border — every window the guest does
present still gets bordered by dom0, exactly as before.
