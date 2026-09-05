# toastfire — deterministic synthetic unpackaged-toast sender

Test fixture for the toast-bridge (A0 acceptance + the P3 per-toast split). It replaces
ad-hoc uses of `guest/fire-demo-toast.ps1` wherever a test needs reproducibility: the PS
fixture stamps a **random** GUID tag per fire (`fire-demo-toast.ps1:44`) and can only fire
under PowerShell's borrowed Start-shortcut AUMID; toastfire makes payloads **byte-stable**
and the unpackaged registration method an explicit, hermetic choice.

Build: `msbuild tools\toastfire\toastfire.vcxproj /p:Configuration=Release /p:Platform=x64`
(v143, /MT, /std:c++17, SDK-only C++/WinRT — mirrors `tools/notifhost`). Ships in the
`gui-agent-package` CI artifact next to wgcprobe/notifhost (build.yml "Build toastfire" +
"Collect package"). Runs in the interactive user session (toasts need one); per-user
registration only, no admin.

## Determinism contract

* Identical arguments ⇒ **byte-identical** toast XML. The payload is a pure function of
  `--class/--title/--body`: no GUIDs, no timestamps, no rand, no locale-dependent
  formatting. Title/body escaping is `&` `<` `>` in that order — byte-parity with
  `fire-demo-toast.ps1:25`, so default payloads equal the hand-written fixtures in
  `tools/notifhost/toastclassify_fixtures.h`.
* Every `FIRED` line prints `payload_sha256=` — SHA-256 (lowercase hex) of the UTF-8 bytes
  of the exact XML handed to `XmlDocument.LoadXml`. Assert it across fires/boots/builds.
* Tags/groups are **caller-supplied, never auto-random** (omitted ⇒ the fixed literal
  `toastfire`). A burst (`--count N`) derives per-toast tags as `<tag>-<index>` (0-based);
  the payload is identical for every toast in the burst (Tag is a notification property,
  not payload XML).
* **Coalescing:** Windows treats same AUMID + Tag + Group as one notification slot — a
  re-fire REPLACES the toast in place and is not raised as a new listener id. The harness
  controls tags precisely so it can choose: vary the tag per fire it wants counted, reuse
  a tag to test replacement.
* Self-check: every payload runs through the real classifier
  (`tools/notifhost/toastclassify.h`) before firing; a row mismatch refuses to fire, so
  the shapes can never drift from the decision table (`docs/DESIGN-toast-bridge.md:165-177`).

## CLI

```
toastfire --register   --method start-shortcut|com-activator|bare [--aumid A]
toastfire --unregister --method ... [--aumid A]        # removes exactly what --register made
toastfire --fire [--method M] [--aumid A] [--class C] [--title S] [--body S]
          [--tag S] [--group S] [--count N] [--interval-ms M]
toastfire --print-xml [--class C] [--title S] [--body S]   # offline: payload + sha, no fire
```

Classes → decision-table rows (defaults `title='demo toast' body='demo body'`):

| `--class` | shape | route/row |
|---|---|---|
| `informational` | `<toast>` text-only (fire-demo-toast.ps1:35) | bridge, row 6 |
| `realchoice` | `scenario="reminder"` + OK/Later buttons (:29) | window, row 3 |
| `persistent` | `scenario="reminder"` + one OK button (:32) | window, row 3 |
| `long` | `<toast duration="long">` text-only | bridge, row 6 |

Output: `FIRED method=.. aumid=.. class=.. tag=.. group=.. row=.. payload_sha256=..`
(exit 0 ok, 1 usage, 2 runtime failure).

## Registration methods (genuinely distinct — the point of the tool)

| method | mechanism | default AUMID |
|---|---|---|
| `start-shortcut` | Start-menu `.lnk` carrying `System.AppUserModel.ID` (PowerShell's method) at `%APPDATA%\...\Start Menu\Programs\toastfire-<sanitized-aumid>.lnk` | `QubesToastfire.StartShortcut` |
| `com-activator` | ToastNotificationManagerCompat scheme (Slack/Discord/Electron): `HKCU\Software\Classes\AppUserModelId\<AUMID>` (`DisplayName`, `CustomActivator={CLSID}`) + `HKCU\Software\Classes\CLSID\{CLSID}\LocalServer32`. CLSID derived deterministically from the AUMID (SHA-256-based), so the keys are predictable. AUMIDs containing `\` are refused (would nest keys). Activation callbacks are out of scope; a COM launch (`-Embedding`) exits 0. | `QubesToastfire.ComActivator` |
| `bare` | nothing — fire on a never-registered AUMID | `QubesToastfire.Bare` |

`--register`/`--unregister` are idempotent (re-running is a no-op success) and hermetic
(unregister removes exactly the one `.lnk` / the two registry trees; already-absent is
success). The three methods may legitimately differ in NotificationChanged/ETW/wpndatabase
AUMID attribution — measuring that difference is what the tool is for.
