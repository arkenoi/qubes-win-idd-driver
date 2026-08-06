# Session handoff — 2026-08-06

Goal in force (user, /goal): end-to-end install test for Win10 and Win11, regression test,
zero issues with Windows Update / networked qube, MS Office behaviour on both, first
automated then visual, performance benchmark vs stock QWT, a "what changed from the user's
perspective" write-up, an installable QWT package on GitHub (ISO too), then feature freeze.

**Status: NOT met. Two of the install paths are proven; the rest is open.** Read
`docs/RELEASE-QUALIFICATION-STATUS.md` for the gap list and `FINDINGS.md` (2026-08-06
entries) for the evidence behind every claim here.

## No background work is running

All watchers were stopped before writing this. Nothing is polling, nothing will restart a
VM under you. `git status` is clean on `main`; everything below is committed and pushed.

## What is actually proven

| claim | evidence |
|---|---|
| Upgrade over an existing QWT delivers OUR agent | `win10-e2e`: stock 4.2.2.0 registered, agent `4B4CE2B1` → `77607793`, manifest gate PASS, survived its own reboot. Guest log `C:\qwt-improved-install.log` |
| Same, with a REAL CI artifact | `win-idd-test`: package `4.2.2+agent.cb1fa4bddadb` (run 31126324112), agent → `CFB27B14`, gate PASS |
| Shipped installer == the one tested | CI vs repo `Install-QwtImproved.ps1` identical after stripping CR (`a6c130a8…`) |
| Clean install on a guest that never had QWT | `win10-clean`: built from `NO_QWT=1 RELEASE_SETUP=…` media (no stock QWT anywhere on it), agent `77607793`, gate PASS |

## What is NOT proven — read this before trusting any green above

1. **The clean guest is degraded and the gate did not notice.** `win10-clean` runs
   `Microsoft Basic Display Adapter` at 3440x1440 — **no Qubes IDD driver**. The firstboot
   payload calls `install.cmd /auto` WITHOUT `-InstallIddDriver`, so a default clean install
   has no arbitrary-resolution support at all, and every check still passed. Also two Xen PV
   devices at `ConfigManagerErrorCode=28` (`XENBUS CONS`, `XENBUS VBD`); VBD is plausibly by
   design (`ADDLOCAL` omits `PvDriversDisk`) but this was NOT verified.
   **The acceptance criterion was the bug**: "installed binary hash == manifest" cannot see a
   guest missing half its function. Replace it with a real health assertion — IDD present and
   bound, zero PnP error codes, agent mapping windows, pixels changing.
2. **The seamless fix was never exercised.** `t2/seamless-hostmode` (`cb1fa4b`) is built and
   installed on `win-idd-test`, but the agent stayed in fullscreen (`mode=f`); `badmode=0
   m6seamless=0` means the code path was never entered, NOT that it works. Setting
   `SeamlessMode=1` in the registry does nothing until the agent restarts, and
   `Restart-Service QubesGuiWatchdog` does not restart it (same log file persists).
3. **No visual acceptance anywhere.** Screenshots work (see retraction below); they simply
   were not taken.
4. Win11 E2E, clean-system regression suite, Office behaviour, and a valid loaded benchmark:
   not started / not valid.

## Guest states, left deliberately as-is

- `win-idd-test` — **WEDGED, and now CAPTURED** (user installed the dom0 service; forensics
  archived in `evidence/wedge-2026-08-06/`). Measured at the moment of the wedge, domid 846:
  **3 of 4 vCPUs spinning** (vcpu0 +10.0 s and vcpu2 +10.1 s over a 10 s sample, i.e. pinned
  ~100 %; vcpu1 +5.9 s; vcpu3 idle) with **zero active grant entries** — so the guest is
  burning CPU in a loop while the framebuffer grant is gone, which is exactly why the pixels
  froze at 23:07 while the domain stayed Running. Signature of the revoke-spin class in
  `docs/upstream-xen-pv-grant-revoke-spin.md`, now with live evidence instead of inference.
  Triggered by my forcing `Stop-Process gui-agent`. **The evidence is saved — the guest can
  be killed freely now.** An `--nmi` capture would name the spinning code, but that
  bugchecks the guest and is deliberately a human decision.
- `win10-clean` — clean install, agent `77607793`, degraded as in (1).
- `win10-e2e` — upgrade-path guest, agent `77607793`.
- `win11-fresh`, `win11-idd-test` — Halted, untouched.

## Wedge forensics are now automatic — but need ONE dom0 install

dom0 cannot be pushed to; it must pull BOTH files:

    mkdir -p ~/win-idd-dom0 && cd ~/win-idd-dom0
    for f in 11-wedge-forensics.sh 13-install-wedge-forensics-service.sh; do
        qvm-run --pass-io win-idd-mgmt "cat /home/user/qubes-win-idd-driver/dom0/$f" > "$f"
    done
    sudo bash 13-install-wedge-forensics-service.sh win-idd-mgmt win-idd-test win10-clean win10-e2e

After that: `tools/wedge-guard <vm>` runs alongside any test and captures a screenshot plus
the full dom0 state the moment a guest wedges, leaving the guest untouched. No human action.
`--nmi` is deliberately NOT reachable from the caller.

## Tooling fixed this session (all committed)

- Installer removes an existing QWT before installing (`REINSTALLMODE=amus` as a second
  guard); the manifest hash check is the gate. This was the bug that made the first E2E
  worthless.
- ISO builder derives the answer-file locale from the media (`*EnglishInternational*` →
  en-GB) and hard-fails on an unsubstituted placeholder. An en-US answer file on en-GB media
  is silently ignored by Setup — recorded in 2026-08-01 but never committed, so it recurred.
- Release stage 2 deletes its own `QWTStage2` ONSTART task. Without it the task re-fired on
  every installer reboot and ran concurrent installers (two stacked setup dialogs, guest
  wedged).
- `reprovision.sh` takes a per-VM `flock`; two instances used to fight over the same guest.
- `cpu-bench.ps1` drives its load through an interactive scheduled task — over qrexec it ran
  in session 0, where nothing composites, which is why both benchmark sides read 0.05 %.
- `mgmt/build-answer-disc.sh`: stock Windows ISO on CD 1 + a ~1 MB answer disc on CD 2
  (`devtype=cdrom` verified accepted; must be assigned persistently). **Never install-tested.**

## Retraction

I claimed the dom0 screenshot service was broken and wrote it into FINDINGS and the status
doc. **It is not, and I did not break it** — `fullshot` 1,269,760 bytes, per-VM shot 890,880
bytes, verified. The empty tars came from guests that had no mapped windows at the time.
Both documents are corrected.

## Suggested order next session

1. Add `-InstallIddDriver` to the release firstboot payload, rebuild media, re-run the clean
   acceptance **with the health assertion from (1)** — not the hash check alone.
2. Decide the `win-idd-test` wedge: install the dom0 service and capture, or kill and move on.
3. Gate B properly: reboot the guest (not a service restart) with `SeamlessMode=1`, confirm
   `mode=s`, zero BADMODE, and `M6SEAMLESS host WxH added to set`, then merge
   `t2/seamless-build` to main.
4. Office, Win11 E2E, regression suite, benchmark; then the final release build and freeze.

## Process note, kept deliberately

Four defects this session were mine and the user caught three before I did: a `pgrep` guard
that matched its own monitor (so a watcher "ran" while nothing ran), the screenshot
misdiagnosis, an acceptance gate too weak to see a missing driver, and a dom0 installer
referencing a file its own install command did not copy. The pattern is checks that cannot
fail. Prefer assertions that have been seen to fail on a deliberately broken build.
