# PLAN-updates-proxy.md — Windows Update via qubes.UpdatesProxy, netvm=none

**Goal:** Windows guests update through the `qubes.UpdatesProxy` qrexec service with `netvm=none` — Windows Update works end-to-end, general networking is structurally impossible. Test guest: `win11-fresh` (QWT-NG 4.3.0), driven via `QTEST_VM=win11-fresh tools/qtest`. All stages serial, one Windows guest at a time.

**Ordering principle:** every stage kills one named risk with the cheapest probe that can produce a decisive verdict; no stage builds more than the next verdict needs. The one genuine unknown — does wuauserv dial a loopback proxy with literally zero NICs — is killed first, before any relay code exists, because its answer can change the design (loopback adapter as an install step) and the docs (the "no NIC at all" claim).

**Risk register (retired in this order):**
- **R1** — wuauserv/DO hard-gates on NLM/NCSI with zero network interfaces.
- **R2** — Windows qrexec stdio is not 8-bit clean / deadlocks under bidirectional binary streaming.
- **R3** — process-per-connection qrexec spawn is too slow for WU's parallel connection fan-out.
- **R4** — some WU sub-plane (WinINET vs WinHTTP vs DO/BITS) bypasses all three proxy planes on current Win11.
- **R5** — TemplateVM-class assumptions (qubesdb `/type`, stock `@type:TemplateVM → sys-net` policy match) don't hold for a real Windows TemplateVM.

---

## User-gated preconditions — batch into ONE dom0 ask, up front

- **G1** — `qvm-prefs win11-fresh netvm none` **now, not later**: every subsequent "bytes flowed" observation then doubles as evidence for the no-NIC end state, and nothing can silently leak around the proxy during development.
- **G2** — dom0 policy line (win11-fresh is a StandaloneVM, denied by the default policy): `qubes.UpdatesProxy * win11-fresh @default allow target=sys-net` (owner picks the actual netvm). Needed from Stage 2 on.
- **G3** — confirm the `qubes-updates-proxy` service (tinyproxy on 8082) is enabled and running on sys-net. Verify, don't assume — e.g. does a Linux template currently update through it.
- **G4** (Stage 9, much later) — create a real Windows TemplateVM from the packaged installer. Reuse a policied qube name per the house roster rule; do not invent names.

Stages 0–1b need only G1; ask for G1–G3 together so nothing blocks mid-run. Queue work behind the gates per the established wedge-queue pattern.

### Debug proxy target (owner-provided 2026-08-10)

`core-update` is the torified update-proxy qube on this rig and may be used as the `qubes.UpdatesProxy` **target** for debugging. This removes the G2 blocker from the debug loop: instead of relying on the default `@type:TemplateVM → sys-net` rule (which does not match the StandaloneVM `win11-fresh`), the forwarder can call with an explicit target, or a one-line debug policy `qubes.UpdatesProxy * win11-fresh core-update allow` routes there. Two caveats to fold into the gates:
- **Tor path ≠ plumbing.** A stall or slow/odd CDN behaviour through `core-update` is a Tor-exit artifact (Akamai/DO endpoints misbehave over Tor), NOT a proxy-plumbing bug. Stage 1's guest-local **mock proxy** isolates plumbing from network path — always reproduce a stall against the mock before blaming the forwarder.
- **Stronger isolation baseline.** Testing egress through a Tor-only proxy first is a *harder* bar than sys-net; passing there is good evidence. Confirm `core-update` actually runs the `qubes-updates-proxy` tinyproxy (it is torified, so verify its config allows the same CONNECT 443 + plain-HTTP :80 the WU CDNs need) as part of G3.

---

## Stage 0 — Baseline + instrument validation (~1 rig-h, no new code beyond two scripts)

**Build:**
- `guest/wu-scan.ps1` — WU scan via COM (`Microsoft.Update.Session` → `IUpdateSearcher.Search("IsInstalled=0")`), emitting HRESULT + update count as `=== RESULT ===` JSON (house pattern). COM, **not** `UsoClient`: UsoClient is fire-and-forget and cannot fail visibly; COM returns concrete HRESULTs.
- `guest/nic-state.ps1` — `Get-NetAdapter`, NLM connectivity via `INetworkListManager`, NCSI state, emitted as JSON.

**Gate (this is the defect-present control for every later stage):** with G1 applied and no proxy configured, `wu-scan.ps1` **fails** with a connectivity-class HRESULT (expect `0x80240438`/`0x8024402C` family) and `nic-state.ps1` shows zero adapters, NLM disconnected. Additionally: a deliberately wrong-named qrexec service call returns a visible denial (proves policy is evaluated, not open). If the scan *succeeds* here, the instrument is broken (cached/offline scan source) — fix before proceeding.

**Unblocks:** a trusted scan instrument plus a recorded failure signature to compare every later run against. **Kills:** nothing — this stage exists so later PASSes count as evidence under the house rule that a check must have been seen to fail.

---

## Stage 1 — THE kill probe: does wuauserv dial a loopback proxy with zero NICs? (retires R1; ~2–3 rig-h; guest-only, no qrexec, no dom0 gates beyond G1)

**Build:**
- `guest/mock-proxy.ps1` — pure-loopback listener on `127.0.0.1:8082`: accepts, logs first request line + Host per connection to a file, answers `502 Bad Gateway`, closes.
- `guest/wu-proxy-config.ps1 -Enable` (elevated via house `run-elevated.ps1`; **reused verbatim later, not throwaway**) — sets **all three planes**: (1) `netsh winhttp set proxy 127.0.0.1:8082`; (2) device-wide WinINET: `ProxySettingsPerUser=0` policy + HKLM `ProxyEnable=1`/`ProxyServer=127.0.0.1:8082`; (3) `DODownloadMode=0` policy. Script FAILS if `UseWUServer` or `DoNotConnectToWindowsUpdateInternetLocations` are set (they must stay unset). `-Disable` reverts every key it touched, restoring prior state from a JSON sidecar it wrote at `-Enable` time (a dead device-wide 127.0.0.1 proxy bricks all guest HTTP — the revert path is not optional).

**Run:** apply planes, start probe, trigger `wu-scan.ps1` and, as a second independent WinHTTP client, a Defender signature update (`MpCmdRun -SignatureUpdate`).

**Why decisive without any upstream:** the unknown is not "can WU finish" (it can't, through a 502) — it is "does wuauserv/DO attempt TCP to the configured proxy at all when NLM reports no connectivity." Connection attempts naming real WU endpoints settle the architecture; 502-then-error is mere plumbing; silence is an NLM gate.

**Gate:** within ~5 min, the probe log shows ≥1 connection targeting a WU endpoint (`CONNECT sls.update.microsoft.com:443` / `*.update.microsoft.com`, `GET http://*.windowsupdate.com/...`, `ctldl.windowsupdate.com`). Record NLM/NCSI state alongside either way.
- **PASS** → NLM does not hard-gate the dial; remaining WU risk collapses to proxy-chain debugging. Skip 1b.
- **FAIL** (zero connections + Stage-0-identical HRESULT) → NLM hard gate confirmed → Stage 1b.

---

## Stage 1b — Conditional: NLM mitigation ladder (0 rig-h if skipped; 2–6 rig-h if entered)

Rungs in order, re-running the Stage 1 probe after each; stop at first PASS:
1. **NCSI registry overrides** (`EnableActiveProbing` variants, probe host/path redirected to content the mock proxy can serve) — cheapest, reversible.
2. **Microsoft KM-TEST loopback adapter**: push `devcon.exe` via `qtest push`, `devcon install netloop.inf *MSLOOP`, static IP, **no gateway, no DNS**. A virtual adapter with no peer is still structurally offline — but the docs lose the "literally no NIC" phrasing; flag this to the user.
3. NCSI active probe answered *through* the proxy (mock serves the probe URL correctly to flip NLM; the real forwarder will serve it via tinyproxy later).

**Gate:** same as Stage 1. Whichever rung passes becomes a required installer sub-step in Stage 7 and is re-verified there. **If every rung fails:** the approach is dead as specified — write it up and present the NIC-present-but-unrouted fallback (weaker isolation story) as a **user decision**. Do not build the fallback unilaterally.

---

## Stage 2 — qrexec byte-path probe: one hand-driven stream, no listener (retires most of R2; ~1.5–2 rig-h; needs G2+G3)

**Build:** `guest/up-oneshot.ps1` — invoked as the qrexec localprogram: writes a hand-built `GET http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/authrootstl.cab HTTP/1.1` (absolute-URI form, as tinyproxy expects) to raw stdout via `[Console]::OpenStandardOutput()`, copies raw stdin to a file. Triggered from the rig: `qtest run "qrexec-client-vm.exe \"@default|qubes.UpdatesProxy|<user>|powershell -File C:\...\up-oneshot.ps1\""` — the ONE pipe-delimited string form (the space-separated form silently no-ops with RC=0; the gates below are designed to catch exactly that).

**Gates (each can fail):**
1. **Policy/endpoint:** response file exists, starts `HTTP/1.` status 200, body has CAB magic `MSCF`. Empty/missing file = FAIL (RC=0 alone proves nothing).
2. **8-bit cleanliness at volume:** fetch a multi-MB real CDN binary (plain HTTP :80 on `*.windowsupdate.com`), SHA256 it; fetch the same URL through the same tinyproxy from the dev qube; hashes must match.
3. **Throughput floor:** record MB/s on the big fetch, 3 runs. <2 MB/s is a yellow flag for the Stage 4 relay design (buffering), not a kill.
4. **Control:** re-run with a wrong service name → must fail visibly, not hang.

**Kills:** "the Windows qrexec stream is a viable TCP substitute" — before any forwarder code exists. If the body is CRLF-mangled through PowerShell stdio specifically, that confirms the relay must be compiled code (already the Stage 3 plan), and gate 2 is re-run with the compiled relay before proceeding.

---

## Stage 3 — Relay pair, proven clean locally (finishes R2 mechanics; ~4 h dev-qube + ~1 rig-h; can interleave with Stage 2's rig time)

**Build:** `qubes-updates-relay` — single-file C#, two modes, compiled **on-guest** with in-box `csc.exe`/`Add-Type` (no new build infra; move into CI packaging at Stage 7):
- `--listen`: binds `127.0.0.1:8082`; per accepted connection mints a token, listens once on an ephemeral loopback control port, spawns `qrexec-client-vm.exe "@default|qubes.UpdatesProxy|<user>|<path>\relay --relay <port> <token>"`, then pumps acceptedSocket↔relaySocket.
- `--relay`: connects back to the control port, presents the token, pumps its socket↔raw stdio (which qrexec-wrapper wires to the vchan). Async pumps both directions, no line buffering, half-close aware (`exit-on-service-eof` analogue). Per-connection log line: timestamp, first request line/CONNECT host, bytes in/out, duration — **this log is the instrument every later stage reads.**

**Local harness (no qrexec):** run `--relay` as a plain child with stdio wired to an echo/file-serving stub, `--listen` in front.

**Gates (each can fail):**
1. **Binary fidelity:** 64 MB random bytes each direction, SHA256 equal both ways.
2. **Duplex deadlock:** simultaneous full-duplex streaming with small socket buffers completes, no hang.
3. **Half-close:** client FIN propagates through and back; no orphaned processes.

A local FAIL is just a code bug — fix and re-run; nothing upstream is implicated.

---

## Stage 4 — Full forwarder over qrexec to real tinyproxy (retires R3; ~3–4 rig-h)

**Build:** nothing new — wire Stage 3's exe to the real qrexec invocation.

**Gates (numbers follow the 3-runs-interleaved house rule):**
1. `curl.exe -x http://127.0.0.1:8082 http://ctldl.windowsupdate.com/...authrootstl.cab` → hash-identical to Stage 2's reference.
2. **CONNECT/443:** HTTPS fetch succeeds (tinyproxy allows 443/873); TLS terminates at origin — proves 8-bit cleanliness over the actual vchan under TLS traffic.
3. **Range/206:** `curl -r 100-199` returns status 206 and exactly 100 correct bytes (WU/BITS delta downloads depend on untouched Range).
4. **Fan-out:** 20 parallel connections — per-connection setup latency (qrexec spawn cost) and one ~100 MB download's throughput recorded in FINDINGS.md. >1 s setup or <2 MB/s → design a listener-side mitigation (pre-spawned relay pool) **before** Stage 5, not after.
5. **Controls:** kill the listener mid-transfer → curl errors promptly (no silent short-write); one run with the policy line commented out (owner) → visible qrexec denial, then restore.

**Kills:** connect-back token design, per-connection spawn overhead, concurrency wedges. FAIL on (2) with (1) passing = qrexec byte-mangling → in-scope bug for our fork; escalate with data.

---

## Stage 5 — Real WU scan end-to-end (retires half of R4; ~2–3 rig-h)

**Build:** nothing — `wu-proxy-config.ps1 -Enable` (planes now point at the live forwarder) + `wu-scan.ps1` + forwarder log.

**Gate:** `IUpdateSearcher.Search` returns S_OK with **>0 updates** on the not-fully-patched image, against the Stage 0 failure signature as control. On failure, triage is mechanical: the forwarder log shows which endpoint class never arrived, isolating which plane (WinHTTP vs WinINET vs DO) leaked on this Win11 build — find the fourth plane, re-run.

**Kills:** "three proxy planes suffice on current Win11" — the second-biggest unknown after NLM.

---

## Stage 6 — Download + install, bytes accounted (finishes R4; ~4–5 rig-h, mostly WU wall-clock)

**Build:** extend to `guest/wu-cycle.ps1` with `-Phase scan|download|install` (`IUpdateDownloader`/`IUpdateInstaller` COM), `=== RESULT ===` JSON per phase.

**Targets in order:** (1) Defender definition update — small, always available, exercises the exact WU channel (`Get-MpComputerStatus` version delta as the check); (2) a real cumulative/quality update, multi-hundred MB.

**Gates:**
1. Defender signature version increases; forwarder log shows payload GETs on port-80 CDNs with byte counts ≳ payload size.
2. ≥1 real update reaches **Installed**: install HRESULT S_OK **and** it appears in update history/`Get-HotFix` delta — judge output, not logs — including any demanded reboot, with `nic-state.ps1` still showing no adapters afterwards.
3. **Bytes accounting (bypass detector):** total relay bytes consistent with download size. WU claiming success with ~zero relay bytes = FAIL and an isolation finding (a bypass path exists) — investigate immediately.
4. Watch for `*.do.dsp.mp.microsoft.com` CONNECTs — cert-pinned, must pass through untouched (no TLS inspection anywhere; they do, by construction).
5. **Control:** stop the listener mid-download → WU fails with a network error (proxy is load-bearing, not a bystander).

The big cumulative completing also retires the throughput risk for real. If BITS/DO stalls despite all planes: experiment with Win10-style `DODownloadMode=100` (classic BITS) or `bitsadmin /util /setieproxy` before escalating.

---

## Stage 7 — Productize per house pattern + cold boot (~4–6 rig-h + ~3 h packaging)

**Build:**
- **`QubesUpdatesProxy` Windows service** wrapping `--listen` (Start=Automatic, delayed after qrexec-agent). At start, reads qubesdb: `/qubes-service/updates-proxy-setup` present → obey it; absent → default **ON iff `/type == TemplateVM`** (mirrors Linux `DEFAULT_ENABLED_TEMPLATEVM`). When OFF: don't listen **and** run `wu-proxy-config.ps1 -Disable`.
- **Installer stage-2 step** in `packaging/setup/Install-QwtImproved.ps1`: new switch **`-NoUpdatesProxy`** (`/noupdatesproxy` in `install.cmd`, matching `-NoPvNetwork`/`-NoAppTweaks`); installs exe + service + planes + whatever Stage 1b rung was required; uninstall removes the service and runs `-Disable` (registry reverted byte-for-byte from the sidecar). Status into the `=== RESULT ===` JSON.
- Relay build moves from on-guest csc into CI packaging; installed binary hash-verified against the manifest (house rule).

**Gates:**
1. **Cold boot** (`qtest shutdown`/`start`, not agent restart — reboot is part of acceptance): no manual steps → WU scan succeeds within 10 min of boot. Test both pre-login (netsh winhttp plane carries the scan) and post-login (WinINET plane, DO active) states.
2. **Gating semantics, both directions:** qubesdb flag off → reboot → service idles, planes reverted, scan fails with a connectivity HRESULT (the gate fails when it should); flag on → works. On win11-fresh (`/type` = StandaloneVM, flag absent) the default must be **OFF** — the class-default logic proven in the negative; rig testing forces the flag on explicitly.
3. `-NoUpdatesProxy` install: no service, no plane keys — diff registry against baseline (can fail).
4. **Defect control:** stop the service → scan fails; start → recovers.
5. Wedge behavior: netvm paused briefly (owner) → listener errors cleanly, no socket/handle leak, recovers.

---

## Stage 8 — Side-scope matrix + soak (~2–3 rig-h)

No new build; one scripted pass, each row a can-fail check cross-checked against the relay byte log, recorded in FINDINGS.md. Only the first two are acceptance-required (update signature validation depends on them); the rest are informational.

| Client | Check | Extra config needed |
|---|---|---|
| **CryptoAPI CRL/OCSP/CTL** | `certutil -verify -urlfetch` on a real chain; `ctldl.windowsupdate.com` visible in relay log | none — WinHTTP plane (**required**) |
| **Defender** | `MpCmdRun -SignatureUpdate`; definitions version advances | none — WU channel (**required**) |
| winget | `winget source update` + one upgrade | none expected (WinINET); Store rows will fail — NLM-gated, out of scope, record as expected-broken |
| Chocolatey | `choco outdated` reaches the feed (if present on rig) | none expected (WinINET/env) |
| Office C2R | update check honors device proxy — only if the Office eval from `install-office-eval.ps1` is on the guest | none per docs — record verified vs expected-per-docs |
| git/pip/npm | `git ls-remote https://...`, `pip download` | machine env `HTTP_PROXY`/`HTTPS_PROXY=http://127.0.0.1:8082` behind a `-DevToolsEnv` switch in `wu-proxy-config.ps1` |
| NTP | n/a — UDP, not proxyable | none: Qubes already syncs guest clocks via its own qrexec service |

**Soak:** guest up 24 h with the service running; handle/socket counters before vs after — no leak.

---

## Stage 9 — Real Windows TemplateVM, stock policy (retires R5; user-gated G4; ~3–4 rig-h + user time)

**User creates** a Windows TemplateVM from the packaged installer (reused policied qube name). **No custom dom0 policy line** — the point is that the default `@type:TemplateVM → sys-net` rule matches by class. Owner also **removes** the win11-fresh line.

**Gates:**
1. qubesdb `/type` reads `TemplateVM`; service auto-activates with the flag absent (DEFAULT_ENABLED default proven live).
2. Cold boot → full WU scan+download+install with **zero** dom0 policy edits.
3. win11-fresh (line removed) is now **denied** — the class-match assumption proven, not trusted.
4. An AppVM based on the template does **not** get the proxy activated (class default OFF) — the isolation story's other half.

**Close-out:** FINDINGS.md entry with the full evidence chain. Per standing upstream policy, everything stays in the fork — no upstream PRs/issues from this track.

---

## Verdict tree

| Stage fails | Meaning | Action |
|---|---|---|
| 1 & 1b | NLM hard-gates with no NIC, unmitigable | Approach dead as specified → user decision on unrouted-NIC fallback |
| 2 | qrexec stream unusable as TCP substitute | If PS-stdio-specific: compiled relay (Stage 3) re-runs the gate. If qrexec-agent mangles: in-scope fork bug, fix with data |
| 3 | Relay code bug | Fix locally; nothing upstream implicated |
| 4 | Token/concurrency/perf design flaw | Redesign relay only (e.g. pre-spawned pool); Stages 1–2 verdicts survive |
| 5 | A proxy plane leaks on current Win11 | Find the fourth plane; forwarder log localizes it |
| 6 | Payload path breaks (Range, DO/BITS) | Targeted fix (mode 100 / setieproxy); Stage 5 scan verdict survives |
| 7–9 | Packaging/policy/gating friction | Iteration, not kill |

## Shippable-feature checklist (end state, all demonstrated by gates above)

- [ ] `qubes-updates-relay` exe (`--listen`/`--relay`, connect-back token, binary-safe, half-close aware, per-connection byte log) — Stages 3–4
- [ ] `QubesUpdatesProxy` auto-start service, gated by qubesdb `/qubes-service/updates-proxy-setup` with default ON iff `/type == TemplateVM` — Stage 7
- [ ] `guest/wu-proxy-config.ps1 -Enable/-Disable`: all three proxy planes (winhttp, device-wide WinINET, DODownloadMode=0), prior-state JSON sidecar, full revert; `UseWUServer`/`DoNotConnectToWindowsUpdateInternetLocations` left unset and asserted so — Stage 1
- [ ] Installer stage-2 step + `-NoUpdatesProxy`/`/noupdatesproxy` opt-out; uninstall reverts planes — Stage 7
- [ ] Stage 1b rung (if any) as installer sub-step, docs adjusted if a loopback adapter is required — Stages 1b/7
- [ ] Cold-boot acceptance, pre-login and post-login — Stage 7
- [ ] Side-scope matrix recorded (table above) — Stage 8
- [ ] TemplateVM stock-policy proof + AppVM/Standalone negative checks — Stage 9
- [ ] Docs: TemplateVMs need zero dom0 changes; StandaloneVMs need one documented policy line + service flag; Store out of scope (NLM-gated); no TLS inspection ever
- [ ] Explicitly NOT built: Store fix, notification forwarding, TLS MITM, QWT transport changes

## Standing rules applied throughout

One Windows guest at a time; VM-mutating stages serial. Every gate has a demonstrated-fail path (Stage 0 signature, policy-line removal, service-flag off, listener kill). Measurements read from the relay byte log — never WU's own success claims alone. Metrics follow the 3-runs-before-verdict rule. Dated findings to FINDINGS.md per stage. dom0 steps are flagged to the owner and never attempted from the dev qube.
---

## North-star compatibility (owner note 2026-08-10): don't wall off the reporter

The proxy is stage one of a full **updater agent** that also reports update AVAILABILITY
and PROGRESS to dom0's updater tool (Linux analogue: `qubes.NotifyUpdates` for the count +
the newer per-VM progress streaming the Qubes updater consumes). The architecture here must
not create obstacles:

- **Separate qrexec services, composable.** Proxy = guest→`qubes.UpdatesProxy` (OUT).
  Availability = guest→dom0 `qubes.NotifyUpdates` after a scan (guest/wu-scan.ps1 already
  produces the count — reuse it). Progress/trigger = dom0→guest `qubes.WindowsUpdate`-style
  service that runs scan/download/install and streams progress back on the same 8-bit-clean
  qrexec stdout. The connect-back relay proven here is the SAME bidirectional mechanism that
  service will reuse.
- **Keep the COM logic reusable.** wu-scan.ps1 / the Stage 6 wu-cycle.ps1 must stay callable
  by a future reporter, not welded to the proxy path.
- **Services as drop-in files** under `<InstallDir>\qubes-rpc\` (Q:\qubes-rpc\ override), so
  `qubes.WindowsUpdate` / a NotifyUpdates caller can be added with no rebuild.
- **Policy:** the reporter needs a dom0 line (guest→dom0 `qubes.NotifyUpdates`) added to
  mgmt/10-win-idd-all.policy when built — flagged, not built now.

This is recorded so Stage 7's service/installer design leaves these seams open; the reporter
itself is a later deliverable.
