# Forum 42717 — every issue GWeck reported, with fix status

Thread: <https://forum.qubes-os.org/t/shiny-new-qwt-has-landed-was-old-man-yells-at-a-cloud/42717>
His posts: 3, 24, 26, 27, 30, 33, 34, 35, 38, 44, 45, 49, 52, 54, 55, 56, 58. Complete pass
2026-08-15. Status vocabulary is deliberately strict:

- **PROVEN** — fixed, and demonstrated with a defect-present/defect-absent pair on one rig.
- **FIXED (unproven)** — fixed and correct by construction, but the failing condition was never
  reproduced here, so no pair exists.
- **CONFIRMED BY HIM** — he retested and reported it good.
- **NOT REPRODUCED** — walked his exact path on his exact build; it did not happen here.
- **NOT SHIPPED** — the fix exists in the tree but no release carries it, so he does not have it.
- **DROPPED** — deliberately not pursued (owner decision), with the alternative named.
- **NOT OURS** — a defect outside QWT.

| # | Post | Issue | Status | Evidence / note |
|---|---|---|---|---|
| 1 | 27 | `qvm-create-windows-qube` globs `qubes-tools-*.exe\|msi`, matches nothing in our ISO, fails **silently** | **FIXED** | We ship `qubes-tools-<ver>.exe` so the stock glob matches (tested: "install.cmd exited with 0"), plus a fork of `qvm-create-windows-qube` (branch `qwt-installer-tree`) for the tree layout |
| 2 | 27, 30 | Upgrading over QWT-on-PV-disk uninstalls first, falls back to emulated IDE, next boot **0x7B INACCESSIBLE_BOOT_DEVICE**; recovery needs safe mode | **PROVEN** | Root cause: 4.3.0/4.3.1 shared MSI ProductVersion 4.3.0, so no in-place path existed and the installer was forced to uninstall. Now `in-place-msi-major-upgrade`, never uninstalls. Re-walked today: 4.2.2 → 4.3.0 → 4.3.1, `pv_boot_disk: true` throughout, no crash |
| 3 | 27 | "It might be good to check for this situation and abort" | **CONFIRMED BY HIM** | Post 34: "The new version detected the previous installation using the PV disk driver correctly and shut down instead of running into trouble." Also a hard refusal on any PV-disk **downgrade** |
| 4 | 33 | PV disk installer's "should a shutdown be performed?" prompt not clickable | **PROVEN** | The xenbus_monitor modal. `AutoReboot=1` is now set *before* msiexec: 4.3.1 hung 70+ min on it, 4.3.2 installed in 1008 s; today's installs completed in ~60–90 s |
| 5 | 33 | `control.exe` still reports 4.2.2.0 | **CONFIRMED BY HIM** | Post 34: "control.exe now correctly shows version 4.3.0 of QWT and this in the installer, too" |
| 6 | 33, 34 | Windows Start menu renders partially / unusable | **DROPPED** | Owner decision 2026-08-15: the stock Start menu is not being chased. Open-Shell is the answer, and he confirms it works (post 55). Note the surface is not even stable across 25H2 UBRs: `Wnd_StartFeed` on his build, a titled `Windows.UI.Core.CoreWindow` on ours |
| 7 | 33 | Cannot reach Shutdown in the Start menu | **DROPPED** | Same as #6; via Open-Shell |
| 8 | 33 | Qube Manager shutdown shows the old warning | **NOT OURS** | Upstream qubes-issues #8090 |
| 9 | 35, 38, 44 | `install /idd` → "file not found" | **SHIPPED** | Three stacked causes: (a) `Start-Process -FilePath 'D:\idd'` asks Windows to launch a file named `idd` — no such file exists on any medium; (b) the `/iddonly` we announced was committed ~3.7 h *after* the 4.3.1 assets were uploaded, so his medium rejects it; (c) the README described pre-4.3.1 semantics. All three now correct and shipped in 4.3.2, including the `%HEREQ%` trailing-backslash bug that broke `/iddonly` |
| 10 | 44, 54 | **Mouse pointer ≈1 cm below where Windows believes it is** (Win10 and Win11) | **PROVEN** | Root cause found and fixed: his 1920×**1200** monitor is not in the IDD's mode list, the agent matched it against the list *as it was*, snapped to 1920×1080 and then published the **snapped** size — so the wanted mode never became available and every retry re-snapped. dom0 kept a 1920×1200 window over a 1920×1080 desktop → pointer low, dead band. 3 interleaved pairs + his shipped binary as control |
| 11 | 44 | Text caret position "lost" in a text window | **FIXED (expected)** | Downstream of #10 — clicks landing a line low. Needs his retest; if it survives the #10 fix it is a separate, unexplained defect |
| 12 | 44, 45 | dom0 dialog: "**invalid or suspicious GUI request**", both buttons end badly | **PROVEN (mechanism), FIXED** | `GetRealWindowRect` returns Win32 codes; two of its failures are *positive* (`ERROR_INVALID_DATA`, `win_perror`'s return) and `SUCCEEDED()` is TRUE for them, so `GetWindowData` skipped its error path, fell through with an **uninitialized** `RECT`, and returned success — announcing stack garbage as window geometry. Measured: 65 rejections → **1** reached the caller pre-fix, **65** after. A `SendWindowCreate` sanitizer independently refuses impossible geometry |
| 13 | 44 | Start menu renders as garbled graphics | **DROPPED** (mechanism understood) | Per #6. His screenshot also shows the *other* dom0 protection — the daemon unsetting `override_redirect` on a "very large window" — which is what leaves Start bordered and mis-drawn |
| 14 | 49, 55 | Qubes menu is not a substitute for a structured Start menu; Open-Shell is | **ACKNOWLEDGED** | No code change intended. Open-Shell is the supported answer |
| 15 | 52 | "How did you get Windows to use the Qubes updater at all?" | **ANSWERED** | Post 53 |
| 16 | 54 | After the IDD-activation reboot, Win10 shows **only a black inactive window**; Windows key dead; apps will not start | **NOT REPRODUCED** | Walked his exact sequence on Win10 22H2 (19045.2965): stock 4.2.2 → 4.3.0 (`09b643e`) → 4.3.1 (`c7ccb45`), release tarballs SHA-verified, `install.cmd` with no flags. The IDD activated and **disabled the emulated VGA** (that is why an IDD failure is fatal rather than cosmetic), and the guest came back healthy — apps map and render. One `AcquireNextFrame 0x887a0026` fired and recovered. Three fixes plausibly bear on it (#10, #12, capture-gate visibility) but none is demonstrated to be *the* cause. **What would settle it: his `Q:\Qubes Logs\gui-agent-*.log` from a black boot** — retrievable over qrexec with no display |
| 17 | 54 | Cannot shut the qube down from Qube Manager/panel; killing it restarts into the same black window | **NOT REPRODUCED** | Tied to #16 |
| 18 | 54 | Request: a `/noidd` switch | **SHIPPED + VERIFIED** | `/noidd`, `/iddoff` and `/iddonly` all verified against the published 4.3.2 package on Win10 22H2: `/noidd` -> `idd_driver: "skipped (/noidd)"` and the guest boots on the emulated adapter; `/iddoff` -> IDD device removed, `NoTopologyApply=1`, VGA re-enabled and primary |
| 19 | 56 | AppVM on the Win10 template starts, then silently shuts down / no GUI | **NOT REPRODUCED** | An AppVM on the 4.3.1 template booted, answered qrexec, and mapped its window correctly. It reproduced once out of three attempts in an earlier session, so it is intermittent. `fbf9368` self-heals a first boot with qrexec and no windows, but has never been seen to fire — **unproven** |
| 20 | 56 | Shutting down from the Open-Shell menu makes the qube unreliable | **OPEN** | Not investigated |
| 21 | 58 | "`/noidd` is not yet accepted" | **SHIPPED 2026-08-15** | His own JSON said `package_version 4.3.1+agent.c7ccb459aec9`: 4.3.2 was never published. Now released as `v4.3.2-agentbacfd2c`, and `/noidd` verified against the real package: `idd_driver: "skipped (/noidd)"`, guest boots on the emulated adapter |

## Fixed here, never reported by him — but they produce his symptoms

| Issue | Status | Note |
|---|---|---|
| Agent restarts **leak grant-table entries** until no vchan can be created (0x5aa) | **OPEN** (damage bounded) | The guest then answers qrexec and has **no GUI at all** until reboot — the same shape as #16/#19. The watchdog respawned once per second forever, making it worse; it now backs off. The leak itself (grants outlive the process) is unfixed |
| Zero host ceiling → `SelectSupportedMode` returned an arbitrary index-0 mode and persisted it | **PROVEN** | Injector knocked an available 5120×1440 down to 1920×1080; off, selection stays inside the real ceiling |
| `resize-sync.ps1` was a second writer of the agent's mode set, wiping target/LRU/host entries | **FIXED** | Deleted; the agent is the sole writer |
| Work-area rect refused by Windows was recorded as applied and never retried | **FIXED (unproven)** | Could not reproduce the 30 s refusal loop on the Win10 rig; ships without a pair |
| Capture-restart gate logged both edges below default level | **FIXED** | A frozen guest recorded nothing; now `CAPTUREGATE` at warning/info |

## What he should be asked for

1. The gui-agent log from a **black** boot (#16) — the single artifact that would close the worst item.
2. Whether the pointer offset (#10) and the caret (#11) survive a build carrying the mode-snap fix.
3. Confirmation that `/noidd` behaves once a release actually carries it (#18, #21).

## Added after the 4.3.2 release

| Issue | Status | Note |
|---|---|---|
| Window tracking is **suspended** whenever capture stops (`g_LocalScreenDestroyed`), so stale windows stay mapped and **no new window can ever appear** | **OPEN — root cause found** | main.c:6196-6199 discards window events while the screen window is down. RETRACTED 2026-08-15: the injector showed a window IS still announced in that state, so this does NOT explain #16/#17 as claimed. What it does cause is a session outage of at least 90 s when the daemon's confirm never arrives. The capture-error path that triggers it is CLAUDE.md's recorded `AcquireNextFrame 0x887a0026`. Not fixed; needs a bounded wait for the daemon confirm plus a sweep |
