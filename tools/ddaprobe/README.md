# ddaprobe — Desktop Duplication scoping probe

A single-file x64 console EXE that measures the Windows Desktop Duplication (DDA) path the
QWT gui-agent depends on. It exists to answer, with evidence, the two questions
`CLAUDE.md` marks as decisive:

1. **Track B (pivotal):** is `DXGI_OUTDUPL_DESC::DesktopImageInSystemMemory` **TRUE** for the
   output that carries the desktop? `agent/gui-agent/capture.c:176-183` **hard-fails** when it
   is FALSE ("TODO: desktop is not in system memory" → `DXGI_ERROR_UNSUPPORTED`). So if an
   IddCx monitor becomes primary and the flag flips, the entire existing capture + grant path
   dies and Track B becomes the much larger "IDD feeds its own grant path" project
   (Phase 1B Outcome B).
2. **Track A:** are move rects *ever* non-empty? `capture.c:441` says
   `// TODO: GetFrameMoveRects (they seem to always be empty when testing)` — an
   **unverified in-code note**. ddaprobe counts them per frame, so Phase 2A can decide
   move-rect work on data rather than folklore.

It deliberately mirrors `gui-agent/capture.c`'s own selection logic — `EnumAdapters1` →
`EnumOutputs` → first `AttachedToDesktop` output, `D3D11CreateDevice` with
`D3D_DRIVER_TYPE_UNKNOWN` and the identical feature-level list (11_1, 11_0, 10_1, 10_0, 9_1)
— so what ddaprobe sees is what the agent will see.

## What it measures, per DXGI output

| Field | Source |
|---|---|
| adapter description, output device name (`\\.\DISPLAYn`), desktop coordinates, rotation | `IDXGIAdapter1::GetDesc1`, `IDXGIOutput::GetDesc` |
| **attached to desktop** | `DXGI_OUTPUT_DESC::AttachedToDesktop` |
| **DesktopImageInSystemMemory** | `IDXGIOutputDuplication::GetDesc` |
| duplication mode: WxH, refresh, DXGI format, scanline order, rotation | same |
| `MapDesktopSurface` success + pitch + non-null pBits | the exact call `capture.c` uses to get the pointer it hands to `XcGnttabPermitForeignAccess2` — an independent corroboration of the flag |
| `AcquireNextFrame` latency: **min / mean / median / p95 / max** in ms | QPC around each successful call |
| timeouts (`DXGI_ERROR_WAIT_TIMEOUT`) and how long they actually blocked | counted separately, never treated as errors |
| errors, with **symbolic** DXGI names, plus `ACCESS_LOST` count and re-duplication count | see "Error handling" |
| dirty rects: total, frames-with, max per frame, **total area in px** | `GetFrameDirtyRects` |
| **move rects**: total, frames-with, max per frame, total area, `move_rects_ever_nonempty` | `GetFrameMoveRects` |
| presented vs mouse-only frames, `AccumulatedFrames`, pointer-shape updates | `DXGI_OUTDUPL_FRAME_INFO` |

Move rects are read **before** dirty rects (both share the single
`TotalMetadataBufferSize` buffer, move rects first) — required by the DXGI contract and by
the MSDN note quoted in `capture.c`.

## Usage

```
ddaprobe.exe [frames] [max_seconds] [options]

  frames         target successful AcquireNextFrame calls per output (default 100)
  max_seconds    wall-clock cap on the capture loop, per output    (default 30)

  --timeout MS   AcquireNextFrame timeout in ms (default 100)
  --output N     probe only global output index N (default: every attached output)
  --no-map       skip the MapDesktopSurface probe
  --json FILE    also write the JSON object to FILE
  --quiet        JSON only, suppress the human-readable table
  --help
```

Exit codes: `0` = at least one output was duplicated, `1` = none could be,
`2` = bad arguments. The JSON block is emitted for both 0 and 1.

**On an idle desktop `AcquireNextFrame` mostly times out**, so the run ends on the
`max_seconds` cap with far fewer than `frames` samples. That is not a failure — but for
meaningful latency/dirty-rect numbers, generate desktop activity while it runs (drag a
window, scroll). The Phase 1A scripted-drag harness and ddaprobe are meant to run together.

## Running it in the test VM

`tools/qtest` drives `win-idd-test` over `qubes.VMShell`. Per `mgmt/PROVISION-LOG.md`
(acceptance table), qrexec commands land as `win-idd-test\user` in the **interactive console
session 1 (Active)** — not session 0. That matters: Desktop Duplication requires a thread on
an interactive desktop, and `DuplicateOutput` returns `E_ACCESSDENIED` /
`DXGI_ERROR_SESSION_DISCONNECTED` from a session-0 service. ddaprobe prints its
`session_id`, `window_station` and `desktop` up front so this is never a guess, warns loudly
if `session_id == 0`, and has a rescue path (`OpenInputDesktop` + `SetThreadDesktop`, reported
in `desktop_attach_note`) for the case where it does land off-desktop.

```bash
export QTEST_INCOMING='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'

# from the CI package
gh run download -n idd-driver-package -D artifacts/
tools/qtest push artifacts/ddaprobe.exe
tools/qtest run "\"$QTEST_INCOMING\\ddaprobe.exe\" 100 30"
```

It is also invoked automatically by `guest/deploy-and-test.ps1` step 4, which does
`& $probe` and stuffs the whole stdout into `steps.ddaprobe` of its `=== RESULT ===` JSON.

## Reading the output

stdout is a human-readable per-output table, then a `=== SUMMARY ===` block, then:

```
=== DDAPROBE JSON ===
{ ...one single-line JSON object... }
```

Everything after that marker line is exactly one JSON object — take the text after the
marker and `json.loads` / `ConvertFrom-Json` it. Extraction from a `deploy-and-test.ps1`
result:

```python
import json
result = json.loads(stdout.split('=== RESULT ===', 1)[1])
probe  = json.loads(result['steps']['ddaprobe'].split('=== DDAPROBE JSON ===', 1)[1])
```

### The fields the decision actually turns on

```jsonc
"summary": {
  "any_duplicated": true,
  "desktop_image_in_system_memory_all": true,  // every duplicated output has the flag
  "agent_capture_would_work": true,            // == the capture.c:176-183 verdict
  "move_rects_ever_nonempty": false            // the capture.c:441 question
}
```

* `agent_capture_would_work: true` → **Phase 1B Outcome A**: an IDD-backed desktop keeps the
  desktop in system memory, the existing capture path slides underneath it, Phase 2B is
  incremental.
* `agent_capture_would_work: false` → **Phase 1B Outcome B**: STOP and present the
  staging-copy + xeniface-gnttab plan to the user, per CLAUDE.md.
* Per-output, `desktop_image_in_system_memory_ever_false` also flags the flag *flipping*
  mid-run (it is re-read after every re-duplication), which is the interesting case when a
  mode change or an IDD monitor arrives while the probe is running.
* `move_rects_ever_nonempty: true` anywhere → the `capture.c:441` note is wrong for this
  configuration and move-rect handling is worth implementing in Phase 2A.

Latency lives at `outputs[i].acquire_latency` (`min_ms`/`mean_ms`/`median_ms`/`p95_ms`/`max_ms`,
`n` = number of successful acquires) and rect volume at `outputs[i].metadata`.

## Error handling (none of these abort the run)

| Condition | Behaviour |
|---|---|
| `DXGI_ERROR_WAIT_TIMEOUT` (0x887A0027) | normal on an idle desktop; counted in `loop.timeouts`, never in `loop.errors` |
| `DXGI_ERROR_ACCESS_LOST` (0x887A0026) | release the duplication, `DuplicateOutput` again, re-read the desc (mode *and* the sysmem flag can change), continue. Counted in `loop.access_lost` / `loop.reduplications` |
| `DuplicateOutput` → `E_ACCESSDENIED` / `SESSION_DISCONNECTED` | try `OpenInputDesktop`+`SetThreadDesktop` once, retry; report in `desktop_attach_note` |
| any other failure | recorded in `loop.errors` and `errors_seen[]`, 20 ms backoff, bail out of that output only after 20 consecutive failures |
| `MapDesktopSurface` → `DXGI_ERROR_UNSUPPORTED` | expected when the flag is FALSE; recorded, not fatal |

**Note on 0x887A0026.** The live gui-agent log already shows
`AcquireNextFrame() failed with error 0x887a0026: The keyed mutex was abandoned.` at
seamless-mode switch / resolution change. That text comes from the agent's
`win_perror2()`, which runs `FormatMessage(FROM_SYSTEM)` on the HRESULT; `winerror.h`
defines **0x887A0026 = `DXGI_ERROR_ACCESS_LOST`**, whose documented remedy is exactly
"recreate the duplication interface" — not anything to do with keyed mutexes. ddaprobe
prints both the symbolic name and the `FormatMessage` text side by side so the two can be
compared directly. (The symbolic value is from `winerror.h`; that the OS message table maps
it to the keyed-mutex string is UNVERIFIED and is precisely what the side-by-side print
settles.)

## Build

CI: `msbuild tools\ddaprobe\ddaprobe.vcxproj /p:Configuration=Release /p:Platform=x64`
→ `tools\ddaprobe\x64\Release\ddaprobe.exe`, which the workflow copies into `package\`.

Plain VS2022 `v143` toolset (**not** the WDK `WindowsApplicationForDrivers10.0` toolset the
driver projects use) so the probe builds even if the WDK VSIX install is flaky, and `/MT`
static CRT so it has no VC++ redist dependency. Links only `d3d11.lib`, `dxgi.lib`,
`user32.lib`, `advapi32.lib`. It is not code-signed by the workflow's signing step (that
step only signs `*.dll` / `*.cat`); a user-mode console exe does not need to be.

### Verification status

**The C++ has never been compiled by MSVC** — this dev qube has no Windows toolchain. It
was instead validated on Linux with g++ against hand-written stub headers modelling the
DXGI 1.2 / D3D11 surface it uses:

* `g++ -fsyntax-only -std=c++17 -Wall -Wextra` — clean, zero warnings from `ddaprobe.cpp`.
* Linked against mock COM objects and **executed**, exercising: two outputs (one attached,
  one not), the sysmem-flag TRUE path and the FALSE path, injected `WAIT_TIMEOUT`, injected
  `ACCESS_LOST` with successful re-duplication and recovery, and `MapDesktopSurface`
  returning `DXGI_ERROR_UNSUPPORTED`. The emitted JSON was parsed with `json.loads` in every
  case.
* That harness caught one real portability bug: HRESULTs were being formatted through
  `(unsigned long)`, which is 32-bit on Windows but 64-bit on LP64; now everything goes
  through `(unsigned)`, correct on both.

The stubs are self-written, so they prove **internal** correctness (no typos, no unbalanced
control flow, correct arithmetic, well-formed JSON, correct error-path behaviour) — they do
**not** prove the real DXGI struct/method signatures are right. Those were cross-checked
against `agent/gui-agent/capture.c`, which uses the same structures from C
(`DXGI_OUTDUPL_DESC.ModeDesc.*`, `.DesktopImageInSystemMemory`,
`DXGI_OUTDUPL_FRAME_INFO.LastPresentTime.QuadPart`, `DXGI_MAPPED_RECT.pBits`,
`DXGI_OUTPUT_DESC.DeviceName`/`.AttachedToDesktop`, `GetFrameDirtyRects` size-in-bytes
semantics). `DXGI_OUTDUPL_MOVE_RECT { POINT SourcePoint; RECT DestinationRect; }` is the one
structure with no in-repo cross-reference — if the first CI build fails, look there first.
Expect the first CI run to be the real compile test.
