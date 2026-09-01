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
- P2 forensics-kit fixes (console `-t pv`, grant-capture-incomplete marker) are in-repo but NOT deployed to dom0 — the next wedge capture is degraded until the owner pulls. [also: debug-introspection] [verified 2026-09-01]
- P2 staging grant per agent start (7200 pages) is never reclaimed — ~144 restarts to exhaustion; needs an owner outliving the agent (holder service or IDD-granted framebuffer). [also: architecture] [verified 2026-08-16]
- P2 `VchanSendBuffer` spins unbounded when the daemon dies with a full ring, and a window flip-storm can fill the vchan and kill the capture thread (S1b) — last recorded open; re-verify live, then fix with bounded/non-blocking writes. [also: architecture] UNVERIFIED
- P3 ~3085 of 3445 agent starts once died before StagingEnsure, unexplained (2026-08-20 record; history erased) — re-derive from live telemetry before investigating. UNVERIFIED
- P3 WUDFRd event 219: recovered-transient today; whether it EVER fails to recover is under observation across acceptance runs (one non-recovery on record, 0xC0000365). [verified 2026-08-29]
- P3 win11-24h2 qrexec-agent death while the guest lived — n=1, plausible wedge-class, unproven. [verified 2026-08-29]
- P3 sporadic first-boot reset attribution (xenvbd reboot-request) — prompt path removed by monitor-disable; resetter never caught in the act. [also: network] UNVERIFIED

### graphics-performance
- P2 task #26 resize replug: every novel size = monitor hot-replug (re-enumeration + duplication teardown); IddCxMonitorUpdateModes tried and reverted; next = IddCx research on re-parse without arrival, or fix only the capture death (#23). [also: user-facing, architecture] [verified 2026-08-28]
- P3 drag residual: announce-quantisation + dom0 apply-lag tail keeps ~11% direction reversals worst-drag; accepted by design (owner), numbers on record — compare against 11%, not 0. [verified 2026-09-01]
- P3 scroll/typing damage-cost attribution vs b299011 baseline recorded closed but closing evidence lost — re-derive from tools/bench-stock-vs-ours.sh before any regression claim. UNVERIFIED

### user-facing
- P1 task #31: autologon arming for managed/domain/Windows-Hello images — no LSA-secret path there; deferred, needs a design. [verified 2026-08-28]
- P2 task #28: `service.uac-disable` cannot work on AppVMs (EnableLUA boot-latched, volatile root) — direction: apply in template + loud log; feature acceptance never run. [also: installer] [verified 2026-08-27]
- P2 a pending UAC elevation is invisible in seamless (by design today); UAC visibility is declared future work. [verified 2026-08-28]
- P2 video-modes-during-update: hide or shrink+decorate the guest desktop during servicing, restore on every exit path — planned, not started. [also: updates] UNVERIFIED
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
- P2 emulated-serial last link: confirm SERIALMARK lines land in dom0's guest-<vm>-dm.log (one dom0 grep); then arm EMS on a persistent guest for bugcheck-headline insurance. [verified 2026-09-01]
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
