# grantprobe — guest-side grant budget / re-grant latency probe

Answers **Q2** of `DESIGN-QUESTIONS-per-window-capture.md` (Step 4 of
`SESSION-PLAN-per-window-capture.md`): what is the practical ceiling and latency of
`XcGnttabPermitForeignAccess2` when granting per-window framebuffers instead of one
whole-desktop buffer, and what does the resize path (revoke + re-grant) cost?

## What it measures

The grant call replicates the gui-agent's framebuffer grant **exactly**
(`agent/gui-agent/capture.c:528`): same `XcOpen(logger, &xc)` handle pattern
(`capture.c:357`), grant-in-place of an existing page-aligned VA, `notifyOffset=0`,
`notifyPort=0` (both ignored — no `XENIFACE_GNTTAB_USE_NOTIFY_*` flag is set),
`flags=XENIFACE_GNTTAB_READONLY`, revoke via
`XcGnttabRevokeForeignAccess(xc, sharedAddress)` (`capture.c:246,419`).

Two modes:

- `grantprobe ceiling <domid> [maxwins]` — allocates page-aligned buffers cycling
  {1280×720, 1920×1080, 3840×2160} × 4 B/px (900 / 2025 / 8100 pages), grants each
  read-only to `<domid>`, stepping until a grant fails or `maxwins` (default 64).
  Prints per-grant latency (QPC µs), running page totals, and on failure the failing
  Windows status + the ceiling reached. Then revokes everything, timing revokes too.
- `grantprobe regrant <domid> <iters>` — grant+revoke one 1920×1080 buffer `<iters>`
  times; p50/p95 (plus min/max/mean) for grant and revoke separately. This is the
  price of a window resize under a per-window-buffer scheme.

Output: human-readable lines, then `=== GRANTPROBE JSON ===` followed by exactly one
single-line JSON object (same convention as `tools/ddaprobe`). Exit codes: `0` probe
completed (**a discovered ceiling is a successful measurement**), `1` could not run
(e.g. `XcOpen` failed — xeniface not present), `2` bad arguments.

## The no-dom0-consumer caveat (read before quoting numbers)

No dom0-side consumer ever maps these grants — dom0 experiments are out of scope for
this qube. The ceiling and latencies here are therefore **guest-side numbers only**:
they price the xeniface IOCTL path (page locking + grant-table entry setup) and find
the guest/Xen grant-entry budget, but say nothing about dom0's mapping cost or about
grant-table pressure from dom0 holding mappings open. That half belongs in the design
writeup as an open item.

## `<domid>` argument

The agent obtains the GUI domain id from qubesdb (`/qubes-gui-domain-xid`,
`agent/gui-agent/main.c:2815 GetGuiDomainId`). grantprobe deliberately does not link
qubesdb-client; **the harness passes `0`** (dom0 is the GUI domain in the default
Qubes setup and on win-idd-test). If you ever run this in a GUI-domain setup, read
the xid from qubesdb yourself and pass it.

## Safety

Runs on a live guest that must stay healthy. Every exit path — normal, error, `atexit`,
Ctrl-C/console-close handler — revokes every grant made; grants are **not** auto-revoked
when the xeniface handle closes (see `agent/gui-agent/capture.c:417` comment). Per the
session plan: run this **last** of the VM steps, one instance at a time, and verify VM
health afterwards (qrexec answers, `qtest shot` shows a live desktop).

## Building

Not in the Windows SDK: `xencontrol.h` / `xeniface_ioctls.h` and the `xencontrol.lib`
import library come from the CI job's existing steps (`.github/workflows/build.yml`):
the xeniface clone (build.yml:200–207) provides the headers; the
"Synthesize xencontrol import library" step (build.yml:209–227) produces the lib the
agent build also links. The vcxproj consumes both **only** via msbuild properties and
fails with a clear message if they are missing:

```powershell
msbuild tools\grantprobe\grantprobe.vcxproj /p:Configuration=Release /p:Platform=x64 `
  /p:XenIncludes="$ws\deps-src\pvdrivers\xeniface\include" `
  /p:XenLibs="$ws\deps-src\pvdrivers\xeniface\vs2022\x64\Windows10Release"
```

Output is pinned to `tools\grantprobe\x64\Release\grantprobe.exe`. Plain C, v143, /MT
(no VC++ redist needed in the guest). At runtime the guest must have `xencontrol.dll`
(installed by the Xen PV drivers / QWT — the same DLL the agent uses).

CI wiring of this invocation into build.yml is done by the orchestrator, not here.

## Usage in the guest

```
grantprobe.exe ceiling 0          # step to 64 windows or the ceiling
grantprobe.exe ceiling 0 128      # push further
grantprobe.exe regrant 0 100      # resize-path price, 100 iterations
```

Session-plan acceptance: 3 runs, stable stats, VM verified healthy afterwards.
