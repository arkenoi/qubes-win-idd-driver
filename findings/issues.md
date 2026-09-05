# issues — prioritized register by tag

## CURRENT STATE

AUTHORITATIVE — and the ONLY content of this file. The owner-required standing view
(2026-09-01): every open issue, tagged and prioritized, maintained IN PLACE — close by
DELETING the bullet, never by appending. P1 = owner action needed or top product risk;
P2 = next engineering work; P3 = background/watch. Tags: graphics-performance,
guest-stability, user-facing, rendering, test-framework, network, debug-introspection,
updates, installer, architecture, upstream. Session reports lead with the P1/P2 deltas
of this file.

### guest-stability
- P1 the IPI/TLB-shootdown wedge's last mile is open — WHY the IPI never lands (Xen scheduling vs LAPIC delivery); needs Xen-side instrumentation at repro time, and no validated reproducer exists (wedge-hunt.sh unproven). Blocks any .13/.15 A/B. [also: upstream] UNVERIFIED
- P2 forensics-kit fixes (console `-t pv`, grant-capture-incomplete marker) are in-repo but NOT deployed to dom0 — dom0 cannot be pushed to; the one-paste pull procedure was handed to the owner 2026-09-02, and after it runs one `qtest wedge` capture verifies the fixed kit end-to-end. [also: debug-introspection] [verified 2026-09-02]
- P2 staging grant per agent start (7200 pages) is never reclaimed — ~144 restarts to exhaustion; needs an owner outliving the agent (holder service or IDD-granted framebuffer). [also: architecture] [verified 2026-08-16]
- P2 `VchanSendBuffer` spins unbounded when the daemon dies with a full ring, and a window flip-storm can fill the vchan and kill the capture thread (S1b) — last recorded open; re-verify live, then fix with bounded/non-blocking writes. [also: architecture] UNVERIFIED
- P3 ~3085 of 3445 agent starts once died before StagingEnsure, unexplained (2026-08-20 record; history erased) — re-derive from live telemetry before investigating. UNVERIFIED
- P3 WUDFRd event 219: recovered-transient today; whether it EVER fails to recover is under observation across acceptance runs (one non-recovery on record, 0xC0000365). [verified 2026-08-29]
- P3 win11-24h2 qrexec-agent death while the guest lived — n=1, plausible wedge-class, unproven. [verified 2026-08-29]
- P3 sporadic first-boot reset attribution (xenvbd reboot-request) — prompt path removed by monitor-disable; resetter never caught in the act. [also: network] UNVERIFIED

### graphics-performance
- P1 PACKAGING GAP: `wgcbroker.exe` + `notifhost.exe` + `wgcprobe.exe` are BUILT in CI (gui-agent-package artifact) but NEVER staged into the installable package — `qwt-full`/stage-qwt-repo `agent-bins` = only gui-agent.exe+gui-watchdog.exe (release-package.yml qwt-full step ~L374); `make-setup.ps1`/`make-package.ps1` copy only those two; `Install-QwtImproved.ps1` `$OurBinaries=@('gui-agent.exe','gui-watchdog.exe')`. PROVEN on win11-app (base64 Test-Path): gui-agent/gui-watchdog PRESENT, wgcbroker/notifhost/wgcprobe ABSENT; Qubes-WgcBroker task armed but NO broker process. CONSEQUENCE: the shipped-4.3.18 "de-slice broker default-on (24H2+)" is INERT on any release install (WgcBrokerActive()=false → DDA-slice fallback; win11 still renders, so it was invisible). Any win11 de-slice/materialized-menu broker verdict from a release install measured the fallback; if it passed, it was validated with a dev-pushed binary (violates the release-only acceptance rule). FULL-INSTALL PATH FIXED (the release): qwt-full builds+signs+exports wgcbroker.exe+notifhost.exe in helper-bins/; make-setup stages them into the setup tree bin/ (THROWs if absent); Install-QwtImproved's existing bin-overlay installs them next to gui-agent.exe. Agent now HARD-FAILS loudly: QGADESLICEDOWN (WARNING, 30s then 120s) + DesliceBrokerDown registry flag (0 ready/opt-out, 1 present-not-running, 2 binary-missing) when broker expected-but-absent on an eligible system (owner 2026-09-04: "hard fail on eligible system", "silent fallbacks with no diag" was the worry). RESOLVED + VALIDATED: win11-a0tb primed from the FIXED release package (agent b8fbe9a / e5da449) 2026-09-04 — wgcbroker.exe + notifhost.exe PRESENT, broker process serving the agent, `DesliceBrokerDown=0` (ready), health-check ok:true, `desktop_on_idd` PASS, pixels render. The de-slice broker now runs end-to-end from a clean release install — the gap is closed and proven, no dev-pushed binary. Measurement note: `Get-Process wgcbroker` false-negatives (the task launches via 8.3 short path `WGCBRO~1.EXE`); assert by Win32_Process path / DesliceBrokerDown / heartbeat, never by process name. RESIDUALS: (a) the OVERLAY installer (packaging/payload/install-qwt-improved.ps1, dev path) still deploys gui-agent only — new-file helpers need plan/backup/default-selection work [task #8, P2]; (b) health-check could assert DesliceBrokerDown directly [P3]. [also: architecture, installer, test-framework] [verified 2026-09-04]
- P2 task #26 resize replug: every novel size = monitor hot-replug (re-enumeration + duplication teardown); IddCxMonitorUpdateModes tried and reverted; next = IddCx research on re-parse without arrival, or fix only the capture death (#23). [also: user-facing, architecture] [verified 2026-08-28]
- P2 win11-24H2 resolution-change capture FREEZE (0x887a0026 keyed-mutex-abandoned) — on a resolution change or seamless↔fullscreen switch the agent "recovers" (RecreateDuplication, thread survives, QGAPERF seq keeps advancing) but re-sends STALE frames: captured pixels frozen. win10 recovers correctly (passing control). Different code path from de-slice; NOT hit in steady-state seamless (resize/mode-switch only), so out-of-de-slice-scope (owner ruling 2026-09-04, tracked separately). Fix (owner-endorsed shape): one-time FULL DDA teardown+rebuild (output duplication + shared surface + keyed mutex + D3D ctx) + re-grant framebuffer + full-screen damage, on the resolution-change event — cheap because rare. This is the CLAUDE.md Phase 2B-resize prerequisite bug, now characterized as recovered-but-stale (not thread-death) on 24H2. win11 25H2: UNTESTED (no 25H2 guest on the rig) but EXPECTED AFFECTED — 25H2 (build 26200) ships as an enablement package on the same 24H2 base (26100, Germanium), so it inherits the identical DWM/DXGI DesktopDuplication resolution-change code; confirm with an rnd8 run once a 25H2 image exists. Detector: P4 rnd8 (win11-24H2 FAIL / win10 PASS, judges pixels not logs). [also: rendering, user-facing] [verified 2026-09-04]
- P3 drag residual: announce-quantisation + dom0 apply-lag tail keeps ~11% direction reversals worst-drag; accepted by design (owner), numbers on record — compare against 11%, not 0. [verified 2026-09-01]
- P3 scroll/typing damage-cost attribution vs b299011 baseline recorded closed but closing evidence lost — re-derive from tools/bench-stock-vs-ours.sh before any regression claim. UNVERIFIED

### user-facing
- P1 task #31: autologon arming for managed/domain/Windows-Hello images — no LSA-secret path there; deferred, needs a design. [verified 2026-08-28]
- P2 task #28: `service.uac-disable` cannot work on AppVMs (EnableLUA boot-latched, volatile root) — direction: apply in template + loud log; feature acceptance never run. [also: installer] [verified 2026-08-27]
- P2 a pending UAC elevation is invisible in seamless (by design today); UAC visibility is declared future work. [verified 2026-08-28]
- P2 video-modes-during-update: hide or shrink+decorate the guest desktop during servicing, restore on every exit path — planned, not started. [also: updates] UNVERIFIED
- P2 toast-bridge A0 (docs/DESIGN-toast-bridge.md Proposal C): C++ resident shipped — notifhost `--bridge` + agent NotifyBridge gate/supervision (0c9f5eb/05b5bdd); gate default OFF, allowlist HKLM gui-agent `NotifyBridgeAllow`. Acceptance EXISTS and has run: standalone suite `mgmt/harness/a0-toast-bridge.sh` (P1-P8) + `a0-lib.sh` shared instruments + `a0-selftest.sh` live instrument floor. The floor caught a REAL crash regression: the bridge silently terminated on ~2/3 of forward→dismiss cycles — `AgentGone()`'s 5s `CreateToolhelp32Snapshot` stalled the sole worker loop past the agent supervisor's 15s heartbeat deadline, and the supervisor's delete-task-first relaunch killed the live bridge artifact-free; A/B-bisected (250b007f 8/8 clean vs ~2/3 crashing), fixed with snapshot-free `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` liveness + 30s throttle (71d609c). Instrument overhaul landed after audits (blog_len constant-10, self-matching heartbeat probes, unconfirmed fires graded as bridge behavior — f45a65e/3f6bffa/294d351/4a0ff74); P6c relay-kill RETIRED — no separate relay process exists to kill (the vchan rides a WMI-unidentifiable qrexec-wrapper), reconnect is asserted by P6b's consent Deny→FATAL-exit→Allow→reconnect cycle (c529171/c8012e2); P8 stale pre-boot-heartbeat race fixed (c8012e2). Latest full run stands at 11-12 PASS — UNCONFIRMED until the owner finalizes the green count from the completed run's verdicts.txt. REGISTERED in the canonical protocol as part `p6-toast-bridge` (wrapped suite + floor gate, 6 scenarios, dry fail-proofs harvested, `a0-instrument-floor` live-proofed via the bisect; protocol/selftest.sh ALL GREEN incl. the regenerated whole-campaign walk); harnesses now honor `A0_OUT` and emit INSTRUMENT-class P1c/P1d verdicts. Phase 2 (synthetic "default"/Open action) stays queued behind A0. [also: architecture, test-framework] UNVERIFIED
- P3 dom0-menu click of the new Terminal / File Explorer app-menu entries after qvm-sync-appmenus — guest half verified, dom0 half not. [verified 2026-09-01]
- P3 Start-in-seamless stays off by owner decision; re-enable path is SeamlessStart=1 + docs/PLAN-start-menu.md when wanted. [verified 2026-09-01]

### rendering
- P2 guest title-bar hiding parked opt-in OFF: dom0 WM sends WINDOW_FLAG_MINIMIZE to caption-stripped windows after a raise — dom0-side mechanism unexplained. [verified 2026-09-01]
- P2 drag distortion when an override-redirect modal appears mid-drag — never reproduced; needs the exact modal + winwatch (shots are o-r-blind); plain overlap exonerated by measurement. (2026-08-16 record; history erased.) UNVERIFIED
- P2 menu-overhang clipping: synthesized menu painted into the owner's buffer would truncate an overhanging menu in dom0 while looking right in-guest — never measured either way. UNVERIFIED
- P3 DWM_CLOAKED_SHELL fullscreen ApplicationFrameWindow once mapped as a blank fullscreen rectangle — last recorded unfixed; check the current predicate before re-deriving (blanket cloak filters stay banned). [verified 2026-08-27]
- P3 work area under-margined for first ~3.5 min of boot until dom0's feed arrives; Explorer fights the work-area value forever (converges, churns 2 s). [verified 2026-09-01]
- P3 field "exit status 46" on seamless switch: localized to the qrexec launch path, exact Win32 error unknown — needs the reporter's qrexec-wrapper log. [verified 2026-08-29]

### test-framework
- P2 first LIVE campaign through protocol/run.py is the single forward item (owner, 2026-09-01: the Fable-rewritten, Sonnet-eval-verified runner IS the framework; the legacy bash-harness lineage, its meltdown-era campaign bookkeeping, and its lint backlog are PURGED). The runner's own gates subsume the old debt: falsifiability at load time, PASS refused without a recorded fail-proof, live-grade proofs required in live mode. Whatever matters gets re-established by that campaign, not by re-running old cells. [verified 2026-09-01]
- P3 legacy lint findings (40) are BASELINED in tools/lint-baseline.txt — not open work; editing a legacy harness re-exposes its findings (line-anchored), so touched code gets fixed and NEW findings still fail the gate. Never add entries to the baseline. [verified 2026-09-01]

### network
- P2 live netvm handling: raw admin.vm.property.Set on a running guest strands the vif without changing the property (qubesd aborts replyless) — dom0-side question, candidate upstream report. [also: upstream] [verified 2026-08-23]
- P3 Windows PV TCP connect tail ~5x vs Linux qube (p99 65 vs 49 ms) + ~8 ms DNS overhead; IPv6 hypothesis disproven. [verified 2026-08-24]
- P3 goldens/checkpoint restores may carry another lineage's stale `Q:\qwtng-netcfg.txt` L3 cache — never measured. UNVERIFIED
- P3 mirage upstream PRs (mirage-net-xen#121, qubes-mirage-firewall#232) status unknown since 2026-08-24 — re-check before relying. [verified 2026-08-24]

### debug-introspection
- DONE: EMS armed (both templates, AppVM-inherited) and the serial channel proven end-to-end — SERIALMARK x3 land in guest-<vm>-dm.log. EMS/SAC silence on a healthy client boot is expected (SAC is Server-only); the bugcheck-time payoff is unprovable from userspace and EMS won't diagnose the IPI wedge regardless — insurance only. [verified 2026-09-02]
- P3 does `/var/log/xen/console/guest-<vm>.log` survive a domain restart — one cheap check with the existing HELPER VALIDATION marker. [verified 2026-09-01]
- P3 kernel heartbeat writer (would timestamp wedge onset in a dom0 log) — not built. [verified 2026-09-01]
- P3 OWNER GATES: gui-agent log sink onto the console writer; unauthenticated SYSTEM console shell. Both security tradeoffs, not technical ones. [verified 2026-09-01]

### updates
- P3 U1 (update availability to dom0) is UNMEASURED post-void — the 08-30 "scan failure" was ruled a meltdown hallucination by the owner; one clean live scan verifies the cell when convenient. [verified 2026-09-01]
- P2 open deployment items: win11-fresh relay/updater deploy returned empty (cause unknown); `-Scheduled` missing from scan tasks on 3 guests; live large-download acceptance for the relay truncation fix never re-run. UNVERIFIED
- P2 WU dialog defects: cannot be moved (jumps back — not root-caused) and its modality is invisible to dom0 (transient_for=0) — three options pending with the owner. [also: rendering, user-facing] [verified 2026-08-30]
- P3 plain-HTTP qrexec/vchan transport loss (~1/3 of responses) — not our code, not yet established as an upstream defect; needs a repro from a Linux qube or after a proxy restart. [also: upstream] [verified 2026-08-14]
- P3 Win10 ESU: real 2025-11 CU resolves and is installable; the gate is CBS ESU entitlement — owner MAK/licensing decision. [verified 2026-08-20]
- P3 U3 dom0-driven install drain has never run on a TemplateVM proper (close with UBR + CBS state=112 on win10-tpl). [verified 2026-08-20]

### installer
- P2 the media insertion path (release ISO attached, autorun launches installer) has never been tested live; the primer-task-in-goldens claim also needs re-verification. UNVERIFIED
- P2 most user-facing switches (`/nonet` `/nodisk` `/noapptweaks` `/reboot` `/noupdates`, `/updatesonly` success path) have never been executed by an automated gate; `/iddonly` `/iddoff` `/updatesonly` bypass Test-Payload (no SHA verification of the medium). [verified 2026-09-01]
- P3 non-`/auto` runs keep the console open at the end — a qrexec-driven `/iddoff`//`/iddonly` without `/auto` hangs on a display-less guest; recorded 2026-08-16, never investigated. [verified 2026-09-01]
- P3 the %~f0/shift elevation fix has no regression check that can fail here (all rigs run EnableLUA=0, the relaunch path is structurally unreachable). [verified 2026-08-16]

### architecture
- P2 leak-free agent exit needs an ack-gated revoke handshake (guest cannot safely revoke while dom0 maps) — Phase 3: design writeup + owner review before code. [verified 2026-08-05]
- P2 the public/internal repo split (findings/, mgmt/, internal docs/ out of the public repo) — awaiting the owner's boundary definition; until then internal-material commits are not pushed. [verified 2026-09-01]
- P3 per-window WGC revisit (would kill the PrintWindow limitations class structurally) — must survive total WGC absence in SYSTEM/session-1 context. [verified 2026-08-09]

### upstream
- P1 reports drafted and BLOCKED ON OWNER TEXT APPROVAL: xen winpv gnttab revoke-spin (docs/upstream-xen-pv-grant-revoke-spin.md — driver versions TODO), xl console overflow (docs/upstream-xl-console-overflow.md), gui-daemon vchan-EOF + restart_guid UAF (DESIGN-gui-daemon-restart-survival.md §3), xenvif ctrl-ring (patches/xenvif-ctrl-ring-fix.patch — last recorded unsent), qubesdb-cmd optind write bug. The IPI-wedge class qualifies but has NO draft yet. [verified 2026-09-01]
