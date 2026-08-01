# BOOTSTRAP — Win11 seamless-rendering session (start here after a session restart)

Written 2026-08-01. Read this, then `FINDINGS.md` (2026-08-01 session-4 entries) for detail.
This file is the working state of the **Windows 11 branch of the per-window capture work**.

## What we are solving

The agent's per-window capture build (branch `agent/perwindow`) was developed and validated
on **Windows 10**. It now also runs on **Windows 11 24H2**, where the shell presents window
shapes the Win10-tuned classifier never saw. Each of those shapes is a separate visible
defect in dom0. The mission of this session line: **make Win11 guests render as cleanly in
seamless mode as Win10 guests do**, without weakening any dom0-side security property
(never weaken daemon-side bordering; no protocol/daemon changes).

The recurring root pattern, worth holding in mind: Win11 draws most transient UI as
**separate top-level windows with `WS_EX_NOREDIRECTIONBITMAP`** (no GDI redirection
surface). PrintWindow structurally cannot capture those, so the agent falls back to
*slice-feeding* them from the composited desktop framebuffer — which is why every one of
these defects looks like "a window full of wallpaper / neighbouring windows' pixels".
The correct handling per window is one of: **synthesize** into its owner (borderless,
correct pixels), or **reject** it (never announce), or — only when it is genuinely
independent interactive UI — announce and slice-feed it.

## Environment (all in this qube, `~/qubes-win-idd-driver/`)

| Thing | Value |
|---|---|
| Win11 test VM | `win11-idd-test` — Win11 Enterprise Eval 24H2 **26100.1742**, offline, testsigning on |
| Win10 test VM | `win-idd-test` — Win10 LTSC 2021, owned by a *different* session (Edge fixes); coordinate before touching |
| Drive the VM | `QTEST_VM=win11-idd-test QTEST_INCOMING='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt' tools/qtest run/ps/push/pushrun/shot/fullshot` |
| Per-window shots | `tools/qtest shot out.tar` (service is a multi-VM allowlist, `+<qube>` argument) |
| **Full desktop shot** | `qrexec-client-vm dom0 local.WinFullScreen` → tar with `screen.png` + `geometry.txt`. **The only way to see override-redirect windows and dom0-side defects** — per-window shots cannot show them. Use it for every visual verdict. |
| Build | GitHub Actions; `gh run watch <id> --exit-status`, then `gh run download <id> -n qwt-improved-package -D artifacts/<name>` |
| Deploy | `qvm-copy-to-vm win11-idd-test artifacts/<name>` then run `install-qwt-improved.ps1 -Force` in the guest via VMShell; parse the `=== RESULT ===` JSON. `-Restore` reverts to stock. |
| Provisioning recipe | `mgmt/PROVISION-LOG.md` (2026-08-01 entry) — rebuild the VM from scratch if ever needed |

## State: what is deployed vs what is built

- **Deployed on win11-idd-test right now:** `qwt-improved 4.2.2+agent.d6ab61cf8659`
  (fallback owner + overhang 12 + small-popup acceptance).
- **Pushed but NOT yet built/deployed:** agent `3c12071` (snap-overlay rejection),
  driver-repo `f3837b3`. **First action in the new session: check that CI run, download
  `qwt-improved-package`, deploy, and verify the drag phantom is gone.**

## Fixes landed this session (all on `agent/perwindow`, all dom0-verified except the last)

1. `a5012a5` **same-process fallback owner** — Win11 XAML popups (`Xaml_WindowedPopupClass`
   "PopupHost": teaching bubbles, WinUI menus) carry no usable `GW_OWNER`, so composite
   synthesis could never match them. Fallback: topmost same-process window whose granted
   buffer contains the popup. `GW_OWNER` stays exclusive when tracked; synthesized windows
   never hop owners; `WINDOW_DATA.ProcessId` added.
2. `832ce97` **`SYNTH_OVERHANG_MAX` 4 → 12** — XAML menus align to the owner's OUTER rect
   while the buffer starts at the DWM frame (measured 5 px at 96 DPI), so the File menu
   missed containment by one pixel of tolerance.
3. `d6ab61c` **small override-redirect popups accepted** (token 4×4 floor instead of
   `SM_CXMIN/CYMIN`) — Alt-nav keytip badges (~40×46) were being swallowed whole.
   **This one is half-right — see OPEN #1.**
4. `3c12071` **reject click-through uncapturable shell overlays** — the drag phantom.
   Requires all of `WS_EX_TRANSPARENT` + `WS_EX_NOREDIRECTIONBITMAP` + `WS_EX_TOOLWINDOW`.
   *Built? Not yet verified — this is the first task.*

## OPEN defects, in priority order

### 1. Keytip badges are announced as individually bordered windows (REGRESSION-ish, user-visible)
After fix 3, Alt-nav keytips render as ~12 tiny windows each carrying dom0's red qube
border, and their slice-fed content bleeds pixels from whatever is behind them
(`instrumentation/win11/` + shots in `mgmt/shots-w11/keytip-now.png`). Before fix 3 they
were invisible except for fragments showing through the synthesized menu — also wrong.
**Neither state is acceptable; the user has flagged both.**

Planned fix (designed, not implemented): keep tracking sub-floor popups, but **announce
them only if they synthesize**. Concretely, in `AddWindow()` (and the re-check in
`UpdateWindowData()`), when a popup is below the `SM_CXMIN/CYMIN` floor and
`SynthQualifies()` fails → set `DeletePending` and drop it silently instead of announcing.
Result: badges inside the owner's buffer appear borderless and pixel-correct; badges
outside it simply do not appear (better than borders or fragments).
Do NOT "fix" this by widening `SYNTH_OVERHANG_MAX` further — the patch path clips to the
granted buffer, so anything genuinely outside gets cropped and reappears as the half-cut
badge the user already rejected.

Suspected complication to check while there: with two Notepad windows of the SAME process
open, the fallback owner picks the topmost same-process window that geometrically contains
the popup — which may not be the window the popup belongs to. Consider preferring the
foreground window / the popup's z-order neighbour before falling back to topmost-containing.

### 2. Synthesis flaps during drags
Log shows `owner geometry changed, materializing child` for every synthesized child on each
drag step, then re-attach afterwards — a full detach/announce/attach cycle per drag. Works,
but it is churn and it briefly shows bordered children mid-drag. Consider re-qualifying
against the owner's *live* geometry rather than materializing, or deferring materialization
until the drag settles.

### 3. `WorkAreaCreateListener: CreateWindowEx failed 0x5 (Access denied)` on Win11
Logged twice at every agent start; the event-driven work-area re-assert (`826ad82`) is
therefore dead on Win11. Not visually urgent, but the work-area feature is silently off.

### 4. `GetRealWindowRect failed 0x80070006` bursts
Recovers fine, but noticeably more frequent on Win11 than Win10 around window churn.

### 5. Win10 regression pass is OUTSTANDING for all four fixes
None of `a5012a5`, `832ce97`, `d6ab61c`, `3c12071` has been re-tested on Win10. The
fallback only fires where `GW_OWNER` is absent and Win10-validated owned popups take the
unchanged path, but this must be *verified*, not argued. `win-idd-test` is currently in use
by the Edge-fixes session which shares the `perwindow` branch — **coordinate before
deploying there**, and expect that session to pull these commits.

## How to test (the loop that works)

1. Deploy the package, confirm `ok:true` and the agent process is up.
2. Reproduce visually with `local.WinFullScreen` and *read the PNG*. Per-window shots hide
   exactly the windows under investigation.
3. Get the guest-side truth from the agent log (`C:\Program Files\Qubes Tools\log\gui-agent-*.log`):
   grep `PwAttachWindow|PwDetachWindow|SynthActivate|materializ`. A full-screen or
   oddly-sized `(slice-fed)` attach is the signature of a phantom.
4. For window taxonomy, `qwt-final/tools/dump-windows.exe` writes
   `windows-visible.txt`/`windows-invisible.txt` **into its CWD** — run it as
   `cmd /c "cd /d C:\Users\user & start /b ...dump-windows.exe & ping -n 3 127.0.0.1 >nul & taskkill /im dump-windows.exe /f"`,
   then `type` the file. It runs continuously; it must be killed.
5. For transient windows (drag overlays, keytips), use the high-rate recorder pattern in
   `/tmp/.../scratchpad/dragrec3.ps1` — EnumWindows loop **entirely inside C#** (PowerShell
   delegate marshaling of `EnumWindows` callbacks fails silently under `-NonInteractive`),
   writing to a guest file, then fetch the file. Ask the user to perform the interaction
   while it records; several interactions (drag-with-phantom) could not be reproduced with
   synthetic `SetCursorPos`/`mouse_event` input.

## Gotchas learned the hard way

- `qtest ps "..."` quoting is fragile; prefer `pushrun` with a script file.
- `Add-Type` + `FindWindowW` needs `CharSet=CharSet.Unicode`, else it never finds a window.
- The drag harness (`instrumentation/drag-harness.ps1`) aborts with "Notepad has no main
  window" on Win11 — it predates the Win11 shell; the minimal repro script is the fallback.
- Never probe state-changing admin methods (an `admin.vm.Start` probe once booted a VM).
- dom0 policy for `win11-idd-test` is name-scoped for `qubes.VMShell`/`qubes.Filecopy` and
  tag-scoped for lifecycle + `admin.vm.device.block.*`; the kit scripts in `dom0/` are still
  behind what is installed live (documented at the end of `mgmt/PROVISION-LOG.md`).
