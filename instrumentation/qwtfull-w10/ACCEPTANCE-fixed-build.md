# Acceptance plan — clean install of the FIXED package (agent a459f0e)

Build under test: `qwt-full` CI run 30720827585, `installer.msi f590c878…`,
`gui-agent.exe 663d7e9b…`, agent submodule `a459f0e` = perwindow + `2c5dad2`
(workarea listener 0x5 + lifecycle + drift check) + `d64bca6` (drag move-only
recapture suppression + single-flush mask). Installed by the unattended ISO on a
**wiped disk** — not overlaid on stock, no `.orig` backups expected.

## Gate 0 — install identity (must pass before anything else)
1. `C:\qubes-win-idd-setup.log` + `C:\qwt-install.log`: `installer.msi sha256 OK: f590c878…`,
   `QWT_INSTALL_OK`.
2. `certutil -hashfile "C:\Program Files\Qubes Tools\bin\gui-agent.exe" SHA256` == `663d7e9b…`.
3. Zero `*.orig` in `bin\` (MSI-installed, never overlaid).
4. ARP shows `Qubes Windows Tools v4.2.2.0`; testsigning Yes; Qubes services Running.
5. Record `QubesIncoming` path (handoff step 5.3).

## Gate 1 — regression checks that were BLOCKED by the wedge
- **Win10 protocol/acceptance regression** for the five win11-line fixes
  (a5012a5/832ce97/d6ab61c/3c12071/d610454). Rerun pitfalls, already learned:
  `LogLevel=4` is required for the `rejecting` (main.c:1924) and sub-floor
  (main.c:1175) LogDebug lines; `check-protocol.py`'s `menu-announced` invariant
  predates synthesis and will flag a *correctly* synthesized menu.
- **Edge ULW first-run** (five points: agent pid stable, no daemon-kill/vchan
  signatures, ULW→legacy markers, non-black window pixels, clean unmap on close).

## Gate 2 — the two fixes must be PROVEN by measurement, not by code review
- **Work area**: no `WorkAreaCreateListener … 0x5` lines at agent start (the listener
  must now be created); `WorkAreaApply` value survives an Explorer overwrite (16-min
  soak); maximized Notepad's dom0 bottom edge on-screen (was 16 px off).
  Negative control available: the pre-fix build's own log lines in
  `workarea-check.md`.
- **Drag**: `tools/bench-agent.sh` A/B vs `bench-qwtfull-w10.txt` (17.2 ms p50) and
  the accepted `bench-e2e-final.txt` (0.917 ms). Bar: drag `tot` p50 < 5 ms.
  Engagement proof required from the new markers: `QGADRAG,ev=suppress` at frame
  rate during motion, `ev=settle` after motion stops. A p50 win WITHOUT suppress
  markers means the bench didn't exercise the path — not a pass.
- **Menu-over-drag**: `QGADRAG,ev=maskpush` must be ABSENT during joint owner+child
  motion (the v1 defect the single-flush design fixes).
- **OVERLAP-IN-MOTION**: no debris/corruption AND its own perf A/B.

## Gate 3 — durability
Cold `shutdown`/`start` survival with agent up on the boot path, zero `EnumWindows
failed`, windows attaching (`tools/viewcheck/coldboot-test.sh`).

## Explicitly NOT claimed by this suite
Networking. The netvm blocker is unresolved and is measured separately; a build that
passes every gate here is still not a shippable QWT until the xenvif chain works or
is proven upstream/environmental by the stock-QWT control install.
