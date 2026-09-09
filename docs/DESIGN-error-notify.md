# DESIGN — dom0 notifications as a SECONDARY error-delivery route

Status: **implemented in the working tree, offline-tested, NOT rig-tested** (written 2026-09-09
while the rig was under an acceptance campaign). Section 11 lists exactly what still needs a
guest to prove. Owner's ask: *"use dom0 notification as secondary standard error delivery route
(supplementary to the logs)."*

## 1. What it is, in one paragraph

When a guest component hits an error a human should act on, it is reported to dom0 as a native
notification **in addition to** the log line that already records it — never instead of it, and
nothing may come to depend on it. The transport is the one the toast bridge already proved:
`notifhost.exe --notify-file <file>` opens one `qubes.Notifications` connection (dom0's stock
service, origin-marked and sanitised there), sends one message, and exits. There are exactly
two tiers:

| tier | channel | needs | written |
|---|---|---|---|
| 1 | dom0 notification via `qubes.Notifications` | **qrexec-agent up**, `notifhost.exe` packaged, dom0 policy (stock allow) | best effort, gated, once per error per boot |
| 2 | the log on disk | nothing | always, first, unchanged |

No new transport, no dom0-side component, no qubesdb write, no fallback ladder.

## 2. The honest limit — read this before relying on it

**Tier 1 rides qrexec.** `notifhost` runs `qrexec-client-vm.exe @default|qubes.Notifications|…`,
and qrexec-client-vm is a local courier: it hands the relay command line to the **local
qrexec-agent service**, which owns the vchan and spawns the relay end. So this route delivers
only while qrexec-agent is up — the same dependency set as any qrexec traffic (xeniface, qubesdb,
qrexec-agent).

**In the failure that prompted this work it would have delivered nothing.** That guest's PV bus
never bound, which takes out xeniface and therefore qubesdb and qrexec together; no qrexec, no PV
console, no window, for an hour, with the answer sitting in a log nobody could reach. The only
channel still alive was the emulated VGA framebuffer, and stage 2's IDD activation switched it
off (whether that activation should be deferred is a separate investigation, not this feature).

So the accurate description is: **a channel for "qrexec is up and nobody is reading the logs"**
— a guest with zero windows and a live qrexec is exactly where it helps (a sign-in-screen-stuck
guest, a broker that never came up, an activation script that could not reboot). It is **not** a
channel that works when everything else fails. When qrexec is down it delivers nothing, and the
log is the only record, reachable only once some channel to the guest comes back.

**Independent fallback?** None within this feature's scope. The PV console (`xencons`, shipped
since 4.3.16) is an independent *pull* channel for a live guest whose qrexec is dead — an
operator can log in over it and read the log — but it is not a delivery route and it also dies
with the PV bus. Nothing here pretends otherwise.

## 3. What existed and is reused (nothing invented twice)

- `tools/notifhost/notifhost.cpp` `--notify-file <path>` / `NotifyOnceMain`: the one-shot send
  (spawn relay, handshake, one frame, wait for ack, exit). Unchanged.
- `main.c` `DirectSuppressNotifyUser` (QGADIRECTSUPPRESS, owner 2026-09-06): the agent already
  used that one-shot to put "a window could not be shown" in front of the user, by a plain
  `CreateProcess` from the SYSTEM agent (no Task Scheduler, no shell dependency — the fewest
  links, because it is needed when things are broken). Its comment already states the limit:
  "a good SECONDARY channel … NOT a last-resort one: it cannot survive a dead qrexec." That
  message is a *user-facing* one and is deliberately ungated; it is left exactly as it was.
- The service-gate pattern (`ReadServiceGate`, registry base + qubesdb override, failed-vs-absent
  discipline, read once at Init).
- The offline-test pattern (`slicepaint_test`, `toastclassify_test`: pure core + defect switches
  that the suite must be seen to fail under).

## 4. Components

| file | role |
|---|---|
| `agent/gui-agent/notifyerr.h` | **policy core**, pure C header (compiles as C and C++): severity threshold, name validation, redaction, marker/count file contract, the decision, the message text. No I/O. |
| `agent/gui-agent/notifyerr.c` | **agent glue**: `QerrInit` / `QerrReport`; marker + count files, notify file, `CreateProcess(notifhost --notify-file)`, fire-and-forget. Has a Win32 layer (the agent) and a plain-C test layer (the suite). |
| `guest/qwt-notify-error.ps1` | **PowerShell twin**: `Send-QwtError`; same rules, same marker files, same transport; Windows PowerShell 5.1. Dot-sourced by shipped scripts, no-op when absent. |
| `tools/notifhost/notifhost.cpp` | includes the core; `--notify-errors N` (gate handed down by the agent); `ReportErrorSelf` for the bridge's own two recurring FATAL exits. |
| `agent/gui-agent/notifyerr_test.c`, `agent/vs2022/notifyerr-test/` | C offline suite (gcc here, msbuild in CI). |
| `tools/tests/notifyerr-test.ps1`, `tools/tests/notifyerr-selftest.sh` | PowerShell offline suite and the runner for the whole defect matrix. |

Flow (both languages): caller logs as before → `QerrReport`/`Send-QwtError` → gate → severity →
names → compose text → redaction → marker (this boot?) → cap → write marker + count → write
notify file (UTF-16LE + BOM, line 1 summary, rest body) → start `notifhost --notify-file`, do not
wait → return. notifhost logs the delivery outcome itself (`NOTIFY one-shot: sent ok=…` in
`bridge.log`).

## 5. Gate — `service.notify-errors`, a sibling, default OFF

Registry `HKLM\…\Qubes Tools\gui-agent : NotifyErrors` (DWORD) is the base; qubesdb
`/qubes-service/notify-errors` (i.e. `qvm-features <vm> service.notify-errors 1`) wins. Read once
at agent Init like every other gate (capabilities are decided at start); the agent passes the
resolved value to the bridge helper as `--notify-errors N` so there is one reader. The PowerShell
twin reads the same registry value and the same qubesdb key.

**Why a sibling and not `service.notify-bridge`:** that gate means "forward the guest's *app*
toasts to dom0 and suppress their Windows banners" — an allowlist-shaped, lossy feature about app
content, and `service.legacy-toasts` forces it off. Neither of those may decide whether the
agent's *own faults* reach dom0: an operator who wants error reports must not have to accept
banner suppression, and a legacy-toasts qube must not be silenced. Same shape, separate switch.
No further knobs: severity, cap and dedupe are policy constants, not configuration.

**Default OFF** satisfies "a guest must not start notifying dom0 because it was upgraded": after
an upgrade nothing changes in dom0 until someone sets the feature.

## 6. Severity threshold — ACTION only

Three levels exist in the API; only one crosses:

| level | meaning | route |
|---|---|---|
| `ACTION` | the product is not delivering and will not recover by itself; a human must do something | **sent** |
| `DEGRADED` | a fault with bounded self-recovery in flight (relaunch, retry) | log only |
| `INFO` | everything else | log only |

Justification: the channel spends human attention in dom0, and a notification the reader cannot
act on trains them to ignore the channel. A DEGRADED event either resolves itself or escalates
into the ACTION event that follows it (broker died → relaunch within ~8 s; if that does not take,
QGADESLICEDOWN fires 30 s later as ACTION), so notifying DEGRADED would only duplicate the ACTION.
The agent's *log levels* are not the discriminator — QGADESLICEDOWN is deliberately `LogWarning`
for log-visibility reasons — so severity is stated explicitly at each call site.

## 7. De-duplication and rate limit

- **One notification per distinct `(component, id)` per boot.** Marker file
  `%ProgramData%\Qubes\notify-errors\<component>.<id>` containing `boot=<boot epoch seconds>`;
  the stamp is derived from uptime (`now − GetTickCount64()` in C, `now − Stopwatch` in PS), so a
  respawned agent, a relaunched helper, or a second script in the same boot all see the first
  attempt. Stamps within 120 s are the same boot; a marker from an earlier boot does not suppress.
- **Cap: at most 8 per boot across all ids** (`.count`, `boot=…\ncount=…`): the storm guard for a
  bug that mints distinct ids. Suppressions are logged, never retried.
- The files are the **cross-language contract**: C and PowerShell read and write the same
  format, so `gui-agent.deslicedown` written by the agent suppresses a PowerShell report of the
  same id, and vice versa (pinned by both suites).
- "Sent" means **attempted once per boot**, not delivered: the send is fire-and-forget by design
  (the caller must never wait on qrexec). If qrexec is down at that moment, notifhost exits 3,
  logs it, and the error is not re-attempted this boot. That is the accepted trade for a route
  that can never block its caller; the log is still the record.
- **An unwritable marker store means no send** (missing data fails): without persistence the
  dedupe would be per-process, and a helper relaunched every minute would turn one fault into a
  notification per minute.

## 8. Message content and redaction

The notification is: summary `Qubes Windows Tools, <component>: <one sentence>`; body
`Error id: <id>. Reported once per boot; the detail is in the guest log: <log pointer>`. dom0
prefixes the qube name and colour itself (origin marking is the proxy's and unforgeable), so the
guest does not name itself; the **component** is named because dom0 cannot know it. Callers pass
templated text — never an exception message, never a file's contents, never a value read from
the system.

Redaction **refuses** (does not mask) a payload that is longer than 600 bytes, has more than 6
lines or a control character, contains a credential keyword (`password`, `passwd`, `pwd=`,
`secret`, `token`, `apikey`/`api_key`/`api-key`, `authorization`, `bearer `, `-----begin`,
`private key`, `credential`), or a long opaque run (≥ 40 base64-class characters, or ≥ 32 hex
digits — keys, hashes, JWTs, bare GUIDs). Refusal is logged; nothing is sent. dom0's own
sanitisation is untouched and remains the trust boundary.

## 9. Fail-open contract

`QerrReport` / `Send-QwtError` never block (no waits, no round trips), never raise, and return
to the caller with its state untouched whatever happened. Their own failures — no marker store,
`notifhost.exe` missing (a packaging gap in the reporting path itself, named as such), spawn
failure — are logged **once per process per kind**. Policy rejections are the policy working and
are logged at most once per event. A missing PowerShell helper next to a shipped script is a
no-op stub. Both suites run every one of these paths and check the caller reaches the next line.

## 10. Call sites — chosen, not blanket

Wired (all `ACTION` unless stated):

| site | id | why it is ACTION |
|---|---|---|
| `main.c` QGABROKERMISSING | `gui-agent.broker-missing` | `wgcbroker.exe` not shipped: surfaces withheld, only a reinstall fixes it |
| `main.c` QGADESLICEDOWN | `gui-agent.deslice-down` | broker expected, absent > 30 s: surfaces withheld, nothing recovers it; text names present-vs-missing like the log line |
| `main.c` QGADESKSTUCK | `gui-agent.desktop-stuck` | secure desktop > 30 s in seamless: dom0 sees nothing — the case this route is best at (zero windows, live qrexec) |
| `main.c` QGABROKERDIED | `gui-agent.broker-died` | **DEGRADED, deliberately below threshold** — a relaunch follows; wired so the threshold is exercised by a real site |
| `notifhost.cpp` bridge FATAL access denied | `notifhost.listener-denied` | the bridge the operator turned on does nothing, forever, one relaunch per minute; needs Settings or the gate |
| `notifhost.cpp` bridge FATAL listener init threw | `notifhost.listener-init` | same shape |
| `activate-idd.ps1` reboot refused | `activate-idd.reboot-refused` | IDD not primary until a hand reboot |
| `activate-idd.ps1` activation failed | `activate-idd.activation-failed` | templated text; the exception stays in the log |
| `deactivate-idd.ps1` reboot refused | `deactivate-idd.reboot-refused` | topology not rebuilt until a hand reboot |

Considered and **not** wired, with the reason:

- QGABROKERLAUNCHFAIL, QGANOTIFBRIDGEEXIT/HUNG, QGABROKERREAP: DEGRADED by nature (a supervisor
  relaunches); their persistent form is already covered by QGADESLICEDOWN / listener-denied.
- QGAQDBGATE: fires when qubesdb is unreadable at Init, which is also when the gate cannot be read
  and qrexec is most likely down; Init aborts for a watchdog respawn. Nothing to send from there.
- QGAFAULT: fault injection, never in a shipped build.
- QGADIRECTSUPPRESS: already has its own ungated user-facing message through the same transport
  (owner decision 2026-09-06); double-reporting it as an error would be noise.
- `health-check.ps1`: an acceptance instrument driven from dom0 over qtest; its verdict already
  reaches the caller as JSON and it has no FATAL path of its own. Wiring it would spend the
  per-boot budget on the harness.
- `pvnic-selfprime.ps1` `FATAL` (inline C#), `ensure-autologon.ps1` exit 2/3, the updater: real
  candidates for a second pass once the route is rig-proven; deliberately not in the first cut.

## 11. Testing — offline now, rig later

Offline (this dev qube, `tools/tests/notifyerr-selftest.sh`; outputs kept in scratchpad):
C suite 63 checks clean; five defect builds (`NOTIFYERR_DEFECT_SEVERITY`, `_RATELIMIT`, `_CAP`,
`_REDACT`, `_FAILOPEN`) each make the suite fail. PowerShell suite 53 checks clean under pwsh;
five guard deletions (`# GUARD:severity|ratelimit|cap|redact|failopen` lines) each make it fail.
Both `tools/ps-parse-check.ps1` and `tools/ps-compat-check.ps1` (5.1) pass on the new scripts.

**Still owed on a guest** (each is an assumption until seen):
1. `notifhost --notify-file` started by a SYSTEM/administrator PowerShell (activate-idd runs
   elevated) reaches dom0 — the agent path is SYSTEM and proven for QGADIRECTSUPPRESS, the script
   path is not.
2. `notifhost` running as the *user* (the bridge) can create `%ProgramData%\Qubes\notify-errors`
   markers under the directory the SYSTEM agent creates (default ProgramData ACLs should allow
   create-file; if not, the bridge's own reports fail closed to the log, by design, and this
   needs a one-line ACL grant).
3. `--notify-errors 1` survives the Task Scheduler `/tr` string on the bridge launch.
4. The once-per-boot rule across a real reboot (marker from boot N does not suppress in boot N+1).
5. What the dom0 rendering actually looks like for the three-line body (xfce4-notifyd wraps it).
6. The whole thing switched ON on a guest where nothing is broken produces **zero**
   notifications across a reboot (the negative control).

## 12. Wiring not applied here

Packaging and CI files are being edited by other agents; the exact patches (stage
`guest/qwt-notify-error.ps1` next to `activate-idd.ps1` in the setup tree; add the
`notifyerr_test` build + defect-inversion step to `build.yml`) are in
`scratchpad/notify-errors/WIRING.md`, not in the tree. Until the staging line lands, the shipped
scripts find no helper and stay a no-op — fail-open, but also *inert*, so the staging line is
part of the feature, not a nicety.
