# Handover: Windows update throughput through the Qubes updates proxy

Written 2026-08-14 for whoever picks this up next. Everything here is measured, with the command
that produced it. Where I concluded something wrong, the retraction is kept — the wrong turns are
part of the evidence.

## Where it stands in one paragraph

Updating a Windows qube from dom0 **works end to end and is correct**: dom0's own
`qubes-vm-update` (and therefore the Qubes Update GUI) drives the guest, the protocol is honest,
and the guest reports what it did. What is **not** solved is **download throughput**: the
Windows-Update-native path runs at ~120–150 KB/s through the proxy, so a 4.8 GB cumulative would
take many hours. One real defect on our side was found and fixed along the way (a 6-second tail
per connection, ~10x). Everything after that has resisted every transport-level lever I tried,
and my last hypothesis (guest CPU) is **disproven by its own numbers** — see The arithmetic.

## Two paths, and why we are on the slow one

| | catalog + DISM (old) | WU-native (`-Action wuinstall`) |
|---|---|---|
| picks the right packages | **no** — scrapes the Update Catalog and guesses; a checkpoint prerequisite came back "not applicable" (DISM rc=552) and the cumulative was then rolled back at boot with `0x80070490` / `CBS_E_INVALID_PACKAGE` | **yes** — the WU agent decides |
| installs on a 24H2 image | **no** — verified on a VIRGIN template (isolated per-KB dir, verified downloads, no stale packages): build stayed 26100.8875 | pending the throughput fix |
| throughput | ~13 MB/s (one long-lived connection) | ~120–150 KB/s |

The old path is fast and wrong; deciding which packages an image needs is exactly what the WU
agent exists to do, and reimplementing it from outside is not a bounded task. **The WU-native path
is the right design; the open problem is purely transport speed.**

## The one defect that WAS ours, and is fixed

`guest/qubes-updates-relay.cs` had `Task.Delay(3000)` in `HandleInbound` **and another in**
`RunRelay` — in series on every connection. Instrumenting the relay (request line + time to first
byte) showed it immediately:

    ms=6090 for down=14524     ms=6076 for down=524800     ms=6138 for down=0

A constant ~6 s independent of payload is a timeout, not bandwidth. Invisible on one huge
transfer (our own downloader pays it once for 4.8 GB and still measures 13 MB/s); crippling for
WU, which issues hundreds of small ranged GETs. Drain cut to 250 ms
(`QUBES_UPDATES_DRAINMS`), after which: **524 KB in 623 ms, and a zero-byte connection in 74 ms.**

Also added: a warm pool of pre-spawned qrexec channels (`QUBES_UPDATES_POOL`, default 8). It
removes spawn/policy/handshake latency from the critical path — real, but NOT the dominant cost.

## The hypothesis ledger (all measured, none argued)

| hypothesis | verdict | evidence that decided it |
|---|---|---|
| TLS/CONNECT handshake per connection | **dead** | request line is plain `GET http://tlu.dl.delivery.mp.microsoft.com/...` |
| server/CDN slow to respond | **dead** | `ttfb=70..304 ms` |
| our byte pump too slow | **dead** | same pump does 13 MB/s on one connection |
| tinyproxy in the proxy qube | **dead** | same 13 MB/s goes through it |
| **our two 3 s drains** | **CONFIRMED, FIXED** | 6090 ms → 623 ms per connection |
| DO/BITS background throttling + `IUpdateDownloader.Priority=3` | **dead** | 118 KB/s with, 126 KB/s without |
| DO scheduler (bypass to BITS, `DODownloadMode=100`) | **dead** | 144 KB/s vs 126 KB/s |
| warm-pool starvation | **dead** | `warm=1: 126, warm=0: 0` — every connection served warm |
| guest-side chunk processing (CPU) | **RETRACTED — see below** | 28 % CPU, nothing pegged |

## The arithmetic that matters (and my retraction)

The CPU probe over 8 s on a 4-core guest, during an active download:

    svchost   cpu_sec=5.0        MsMpEng cpu_sec=2.7      System cpu_sec=0.6
    powershell cpu_sec=0.6       qubes-updates-relay cpu_sec=0.2

I called that "the guest is busy between requests". **It is not.** 4 cores x 8 s = 32 CPU-seconds
available; ~9.1 were used = **28 %**, and no process is pegged (`svchost` averages 0.63 cores,
`MsMpEng` 0.34). A guest that is 70 % idle with no saturated thread is **waiting, not computing**.
Excluding Defender would free capacity that is not scarce. I mistook "largest number in the list"
for "the bottleneck"; do not repeat that.

## The shape of the demand (this is the clue)

Gaps between connection starts, from the relay log:

    gaps_ms  min=0  median=43  p90=3713  max=4256
    gaps over 2000 ms: 40 of 134

So: a burst of ~3 connections within tens of milliseconds, then a **fixed ~3.7–4.2 s pause**,
repeating. Per connection inside a burst: ~524 KB in ~623 ms ≈ **840 KB/s**. The transport is
fast; the client asks for more data only every ~4 s.

**Next measurement, already scripted:** `guest/wu-iowait-probe.ps1` samples
`Avg. Disk sec/Write`, `Current Disk Queue Length`, `Disk Bytes/sec` and CPU idle over 12 s.
It separates the two survivors:
- high write latency or a standing queue → **storage** is the limiter (thin LVM under host load)
- disk idle AND CPU idle during the pause → a **timer/scheduler inside BITS/DO**, which no
  transport tuning of ours will move, and the product decision below applies.

It has not been run yet: the template went `Transient` (mid-servicing) before I could.

## If it turns out to be unfixable

Two honest options, in preference order:

1. **Accept it.** Updates are dom0-driven and unattended. A template updating overnight at
   150 KB/s is ugly but correct, and correctness is what the catalog path could not deliver.
   Requires the pass to be resumable across sessions (WU already keeps its own state in
   `SoftwareDistribution`, and our pass can be re-driven).
2. **Hybrid.** Let WU decide and install, but fetch payloads ourselves — blocked today because WU
   chooses express/differential payloads we cannot address from the catalog. Only worth it if
   someone finds a supported way to enumerate the exact URLs WU intends to fetch.

## How to reproduce anything here

    tools/replay-dom0-update.py <vm> [--with-entrypoint]   # dom0's exact command sequence
    tools/clean-shot-template.sh <src> <tpl>               # rebuild a template, full flow, verdict
    guest/wu-dism-forensics.ps1                            # per-package DISM/CBS verdicts
    guest/wu-peek-download.ps1                             # first bytes of every downloaded .msu
    guest/wu-busy-probe.ps1                                # who burns CPU during a download
    guest/wu-iowait-probe.ps1                              # disk latency/queue vs CPU idle  <-- NEXT
    -Action wuinstall                                      # the WU-native path
    C:\ProgramData\Qubes\wu\agent.log                      # the agent's own log (tee'd; survives)
    C:\ProgramData\Qubes\wu\qubes-updates-relay.log        # CONN warm= up= down= ttfb= ms= req=

Rigs: `win11-tpl` (TemplateVM, 24H2 26100.8875, the subject), `win11-24h2` (pristine source, never
booted by me), `win11-fresh` (StandaloneVM, 25H2 26200.9168, fully patched — the control that
proves the flow works when the packages install).

## Traps that produced false results today (all cost real time)

1. `$?` after a pipeline is the **last** command's status — a qrexec refusal reads as success.
2. `cmd /c "A & echo %errorlevel%"` expands `%errorlevel%` at PARSE time: it reports the previous
   command's code. Use PowerShell's `$LASTEXITCODE`, or the replay harness.
3. Nested quoting through `qtest run` silently mangles PowerShell one-liners — push a `.ps1` and
   `pushrun` it instead. Several "empty" results here were this, not the guest.
4. **Never edit a shell script while bash is executing it** — bash reads by byte offset and
   resumes mid-token. It killed a 40-minute run whose work had already succeeded.
5. A region-replacing edit can delete something it never mentions: mine removed the `$OK_RC`
   definition, so every install reported failure. Grep for what an edit REMOVES.
6. `.msu` is not always a cabinet: recent Win11 cumulatives are WIM (`MSWIM`), not `MSCF`. A
   CAB-only check rejected a valid 4.8 GB download and looped forever.
7. DISM `rc=3010` means **staged**, not installed. Only the build number (`CurrentBuild.UBR`)
   proves an update landed.

## RECOVERED FROM THE FABLE ANALYSIS (2026-08-14) - read this before designing anything

Four independent lenses were run over the data above. Two converged on the same mechanism, and
one produced the arithmetic that makes it the leading candidate:

### The number that matters
The modal connection carries **down=524800 = 524288 body + ~512 B of headers** - one 512 KiB
Delivery Optimization piece. One piece per ~4.1 s tick is

    524288 B / 4.1 s = 125 KB/s

which IS the measured 120-150 KB/s, independently of link speed. A bandwidth ceiling stretches
transfers; it does not create fixed idle gaps. The limiter is therefore the client's REQUEST
CADENCE, not the pipe.

### Leading hypothesis: our tunnel destroys HTTP keep-alive
DoSvc/BITS issue HTTP/1.1 ranged GETs through WinHTTP expecting a persistent connection: against a
real CDN, one connection streams many pieces back to back with ~0 ms between requests. Here:
tinyproxy (the qubes.UpdatesProxy backend) serves ONE request per connection and closes, and our
relay maps ONE qrexec channel to ONE TCP connection and tears it down after the response. So the
completion-driven refill path dies with every piece, and the only surviving refill is DO's
periodic job-scheduler callback (~4 s). Hence: burst of ~3 connections, one piece each, then
silence until the next tick.

This also explains why EVERY transport lever moved nothing: they all sit ABOVE the stall.

### Correction to the dead list
`DODownloadMode=100` (bypass to BITS) is **deprecated/ignored on Windows 11 24H2**. Both sides of
that A/B ran DoSvc, so "DO bypass: dead (144 vs 126 KB/s)" tested nothing. Do not cite it.

### The storage hypothesis is NOT refuted by path A
Our 4.8 GB download wrote with large BUFFERED writes absorbed by the page cache. DO commits pieces
with write-through/flush semantics (integrity requirement for resumable downloads), which defeats
the cache and serialises on blkfront -> blkback -> thin-LVM -> physical flush. ~380 small
synchronous IOs at 10-15 ms = 3.8-4.2 s, which fits the gap exactly as well. The two hypotheses
are distinguishable only by measurement, not by argument.

### Cheapest experiments, in order
1. **Ceiling calibration THROUGH THE RELAY** (not from the dev qube - that leg is already known
   healthy at 13.4 MB/s and does not exercise the vchan or tinyproxy). One ~32 MB ranged GET to
   127.0.0.1:8082 using a URL copied verbatim from a recent `req=[GET ...]` line. If it sustains
   multi-MB/s, the path is fine and the client cadence is the cause. If it is <= ~300 KB/s, every
   WU comparison from today is invalid and the investigation moves to the path.
2. **Keep-alive evidence** - the relay already buffers the request head, so log (a) the client's
   `Connection:` header and (b) WHICH SIDE hits EOF first. Dead if the client says
   `Connection: close` (it never wanted reuse) or if the client closes first.
3. **I/O probe with the witness** during an active download - separates the write-through stall
   from the timer. Already scripted and still unrun.

### If keep-alive is confirmed, the fix is ours and is not exotic
Terminate keep-alive LOCALLY in the relay: hold the client socket open, read the next request on
it, and pair each request with a fresh pooled qrexec channel. The warm pool already makes a
channel available in ~0 ms (warm=1 on 126 of 126 connections), so DO's completion-driven refill
would work even though tinyproxy still closes upstream per request. That is a normal proxy-chain
behaviour, entirely guest-side, and touches nothing in dom0 or the proxy qube.
