# App hardware-acceleration pre-tweak (`guest/disable-hw-accel.ps1`)

Status: script updated 2026-08-09 from a dedicated research pass; **not** wired into any
installer — see [Proposed installer integration](#proposed-installer-integration), which
needs owner approval.

## Why this exists

A Qubes Windows guest has no GPU. Apps that insist on "hardware" acceleration land on
slow emulation/fallback paths and, worse for us, repaint far more than they need to —
every excess pixel crosses the desktop-duplication capture path to dom0. The one
A/B-measured case in this project (FINDINGS.md, 2026-08-02): Word typing at 3430x1379
with Office HW accel ON = 257 ms p50 frame interval and ~237k dirty px per keystroke;
OFF = 31 ms and ~3.4k px. The agent was measured at 98–182 µs per frame — never the
bottleneck. (The original "8.3x fps" framing was later corrected as confounded by the
harness input cadence — FINDINGS.md 2026-08-03 — but the cause and remedy stand.)

Prior art: VMware OSOT and Citrix Optimizer GPU-less-VDI templates set essentially this
exact registry stack. No existing Qubes guidance covers it — this is new ground for QWT.

The script is **order-independent**: policy keys are read by apps at runtime, so it can
run before any of the software is installed, and installers do not remove policy keys.

## Every key the script sets

### Machine-wide (HKLM — no per-user delivery problem)

| Key / value | Apps | Confidence (research pass) | Notes |
|---|---|---|---|
| `HKLM\SOFTWARE\Policies\Google\Chrome` → `HardwareAccelerationModeEnabled=0` (DWORD) | Chrome, all profiles | verified-in-docs (official Chrome Enterprise policy) | Settings toggle becomes "Managed"; video decode goes software (was SwiftShader anyway on a GPU-less box). |
| `HKLM\SOFTWARE\Policies\Microsoft\Edge` → same | Edge | verified-in-docs (learn.microsoft DeployEdge) | Does **not** affect WebView2-embedded Edge runtime. |
| `HKLM\SOFTWARE\Policies\Chromium` → same | plain Chromium | key-path verified, policy-under-key commonly-documented | Chromium builds are historically stricter about requiring enrollment for some policies — verify once. |
| `HKLM\SOFTWARE\Policies\BraveSoftware\Brave` → same | Brave | carried over from the previous script revision (same Chromium policy set) | Not in the research pass; same caveat as Chromium. |
| `HKLM\SOFTWARE\Policies\Mozilla\Firefox` → `HardwareAcceleration=0` (DWORD) | Firefox 60+/ESR | verified-in-docs (official Firefox admin docs) | Locks the about:preferences checkbox. Modern FF (89+) still composites via WebRender; this forces WebRender-on-software — the deterministic version of what a GPU-less guest falls back to anyway. |
| `HKLM\SOFTWARE\Policies\Slack` → `HardwareAcceleration=0` (DWORD) | Slack desktop 4.31+ | verified-in-docs (Slack's official managed-configurations article, ADMX exists) | The **only** mainstream Electron app with a real policy surface. Enforced variant: removes the user's Preferences toggle. (A softer `\Defaults` subkey variant exists if the owner prefers a changeable default.) |
| `HKLM\SOFTWARE\Policies\Microsoft\Internet Explorer\Main` → `UseSWRender=1` (DWORD) | IE / embedded MSHTML WebBrowser control (old LOB apps, installers) | commonly-documented (standard GPO, inetres.admx) | Pre-IE9 GDI path; locks the Internet Options checkbox. Standard in VDI images. |
| `HKLM\SOFTWARE\Microsoft\Avalon.Graphics` → `DisableHWAcceleration=1` (DWORD) | every WPF app (LOB apps, PowerShell ISE, parts of VS) | HKCU location verified-in-docs (aa970912); the HKLM mirror is commonly-documented practice (VDI optimizers set it) | Forces WPF Tier 0. Largely redundant on the Basic Display Adapter (WPF already detects no D3D9 HW) but makes it deterministic. Known interaction: WebView2CompositionControl inside WPF fails to render with this set (WebView2Feedback #5281). |
| `HKLM\SOFTWARE\Policies\Microsoft\office\{16.0,15.0,14.0}\common\graphics` → `disablehardwareacceleration=1`, `disableanimations=1` (DWORD) | Office | **unverified — likely inert.** The Office ADMX defines this policy under **HKCU only**; research found no HKLM path Office documents reading. | Kept as free insurance for builds that do consult HKLM; the delivery that is known to work is the per-user set below. Do not count on this row. |

### Per-user (delivered to invoking user + every existing S-1-5-21 profile + Default profile)

| Key / value (relative to user hive) | Apps | Confidence | Notes |
|---|---|---|---|
| `Software\Microsoft\Office\{16.0,15.0}\Common\Graphics` → `DisableHardwareAcceleration=1` (DWORD) | Office 2013+ (16.0 = 2016/2019/2021/2024/365) | **A/B-measured in this project** (FINDINGS.md 2026-08-02) + verified-in-docs | The Microsoft-supported switch (same as the Options > Advanced checkbox). Requires app restart. |
| `Software\Microsoft\Office\{16.0,15.0}\Common\Graphics` → `DisableAnimations=1` (DWORD) | Office | measured (part of the same remedy) + documented (Oracle Smart View docs et al.) | Kills smooth-cursor/cell animations — continuous repaints that are poison for desktop-duplication capture. |
| `Software\Microsoft\Office\{16.0,15.0}\Common` → `UseAnimations=0` (DWORD) | Office | **measured but sparsely documented** — part of the set that fixed Word typing; type/effect not independently verified | Kept because it was in the demonstrated remedy. Open question below. |
| `Software\Policies\Microsoft\office\{16.0,15.0}\common\graphics` → `disablehardwareacceleration=1`, `disableanimations=1` (DWORD) | Office | verified-in-docs (Office16 ADMX, **User Configuration** — the policy hive Office actually reads is HKCU) | The policy variant additionally greys out the UI checkbox so users can't re-enable. |
| `Software\Microsoft\Avalon.Graphics` → `DisableHWAcceleration=1` (DWORD) | WPF | verified-in-docs for HKCU | Per-profile complement of the HKLM mirror above. |

Per-user delivery mechanism (chosen per the research pass's preference order — Default-hive
seeding + existing-profiles loop, over Active Setup):

1. HKCU of the invoking user (under qrexec that is SYSTEM's hive — harmless, and the next
   two steps are what reach real users; this fixes the previous revision's defect where a
   qrexec-driven run silently configured only SYSTEM).
2. ProfileList walk over every `S-1-5-21-*` profile: hives of logged-on users are written
   in place via `HKEY_USERS\<SID>`; offline hives are `reg load`-ed under a PID-unique
   mount name, written, and unloaded (with GC + retry; an unload failure is counted as a
   failure because it leaves the profile locked).
3. `C:\Users\Default\NTUSER.DAT`, so accounts created later inherit everything.

Failed hive loads/unloads now count toward `failed` and force exit 1 (previously a WARN
that let the script exit 0 having skipped inheritance). The dry run (`-WhatIfOnly`,
aliases `-DryRun`/`-WhatIf`) now also enumerates and reports the per-profile writes it
previously hid. Writes are idempotent: already-correct values log `OK` and don't count as
changes, so `changed=0` on a re-run means "nothing drifted".

## Deliberately NOT covered (Electron reality)

Electron does not include Chromium's enterprise-policy machinery (it lives in
`chrome/browser`, not the content layer), so `HKLM\Software\Policies\*` is ignored by
virtually every Electron app — Slack being the lone exception, handled above. The rest
keep the toggle in per-user JSON that the app/updater rewrites; installer-seeding it is
unsupported and fragile, so the script doesn't. Manual per-app notes (also in the script
header):

- **VS Code**: `%APPDATA%\Code\argv.json` → `"disable-hardware-acceleration": true`
  (official mechanism; the VSCode HKLM policy allowlist does not include HW accel).
- **Discord**: `%APPDATA%\discord\settings.json` → `"enableHardwareAcceleration": false`;
  shortcut `--disable-gpu` unreliable (args filtered, self-relaunch).
- **Teams classic** (Electron, retired): `%APPDATA%\Microsoft\Teams\desktop-config.json`
  → `appPreferenceSettings.disableGpu = true`.
- **Teams new / any WebView2 host**: no toggle at all. The one central lever is
  `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--disable-gpu` (REG_SZ,
  `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`) — Microsoft labels
  it unsupported/troubleshooting-only and it hits **every** WebView2 app (new Outlook,
  installers, shell surfaces). In a GPU-less guest that blast radius may actually be
  desirable, but it stays opt-in-manual until someone tests Teams video/screen-share with
  it set.
- **Signal**: nothing documented/stable; skipped.
- Note Electron's own caveat (electron#17180/#51363): even with `--disable-gpu` some
  versions still spawn a GPU process — pixels go software, the process exists.

Also deliberately absent: `TdrLevel=0` and any "global GPU off" switch. TDR disabling
does not disable acceleration (it disables hang recovery — actively harmful if a virtual
GPU/IDD render path ever appears), and no modern global HW-accel switch exists; the
per-app/per-framework keys above *are* the mechanism.

## Open questions

1. **Office HKLM Policies path**: research says Office reads the policy from HKCU only;
   our HKLM writes under `Policies\Microsoft\office` are probably inert. Kept as
   no-cost insurance. Could be settled with one A/B on the test VM (delete HKCU
   variants, keep HKLM, check the Options checkbox state).
2. **`UseAnimations=0`**: in the measured remedy but sparsely documented; unknown whether
   it contributes anything beyond `DisableAnimations=1`. Low-cost to keep.
3. **Chrome/Chromium policy trust off-domain**: `HardwareAccelerationModeEnabled` is not
   in the cloud-only/sensitive set and is the standard VDI recipe, but Chromium warns
   some registry policies need enrollment. Verify once per image: `chrome://gpu` should
   show software rendering and `chrome://policy` should list the policy as applied.
4. **No measurements exist for anything except Office.** Chrome/Firefox/IE/WPF entries
   are extrapolations from the Office result plus VDI prior art. If a browser-scroll
   benchmark ever matters, A/B it with the existing harness before crediting these keys.
5. **Slack enforced vs default**: script uses the enforced key (removes the user toggle).
   If that's too heavy-handed, move the value under `HKLM\SOFTWARE\Policies\Slack\Defaults`.
6. **WebView2 env-var hammer**: worth an opt-in switch (`-IncludeWebView2`) once its
   effect on new-Teams media paths is tested? Currently manual-only.
7. **Win11 image**: all of this was researched/measured on Win10; the profile-walk
   delivery is untested against a Win11 profile set (no reason to expect differences,
   but per project rules that's not evidence).

## Installer integration (WIRED 2026-08-09 — owner approved: default ON, `/noapptweaks` opts out)

The full installer now runs the script in stage 2, after the QWT install proper and
before the stage is declared complete (`packaging/setup/Install-QwtImproved.ps1`):
default ON, `-NoAppTweaks` / `install.cmd /noapptweaks` skips it, the switch survives
`-Auto` boot-resume, the child's `=== RESULT === changed=N failed=N` trailer is parsed
into the RESULT JSON (`detail.app_hwaccel`), and any failure is a WARN, never a failed
install. `packaging/make-setup.ps1` stages `guest/disable-hw-accel.ps1` (single source
of truth) into the payload where `Test-Payload`/SHA256SUMS cover it. The owner's earlier
concern about running it unconditionally was resolved by making it a documented default
with a first-class opt-out rather than a silent side effect.

The script is also hooked in the *provisioning* flow: `mgmt/autounattend.xml` runs it
at FirstLogonCommands Order 8, and `mgmt/build-answer-stick.sh` stages it. That placement
stays authoritative for fresh installs.

The overlay-package (pkg8-style) path is NOT wired and keeps the original opt-in
proposal below, for reference:

1. Ship the script in the package (precedent: `pkg8/optional/` for
   shipped-but-not-auto-installed content), listed under `installs_optional` in
   `MANIFEST.json`.
2. Add one optional step to `pkg8/install-qwt-improved.ps1` — a plain switch parameter
   (the `$COMPONENT_FILES`/backup machinery is file-swap-shaped and shouldn't be bent
   around a registry step), defaulting to off:

   ```powershell
   [switch]$TweakAppRendering
   ```

   and, immediately after the component install/verify phase succeeds (before the final
   summary), the exact call:

   ```powershell
   if ($TweakAppRendering) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'disable-hw-accel.ps1') }
   ```

   The child's `=== RESULT === changed=N failed=N` line surfaces in the installer log;
   a nonzero exit should mark the step failed without rolling back binaries (registry
   tweaks are independent of the file swap).
3. This is now safe from qrexec/SYSTEM context — the 2026-08-09 revision's profile walk
   is exactly what makes the installer hook viable (the previous revision would have
   configured only SYSTEM's hive from there).

Not proposed: running it unconditionally from the installer (it changes user-visible app
behavior and greys out UI toggles — that's a policy decision the owner should make), or
seeding Electron per-user JSON files (unsupported surface, updater churn).
