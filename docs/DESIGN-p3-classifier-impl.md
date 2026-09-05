# DESIGN — P3c implementation: verdict channel + deferred-map routing for the per-toast split

Status: **design only, no agent code** (written 2026-09-05). Per the Phase 3 scope ordering,
P3c agent code waits for the P3a rig gate (DESIGN-toast-bridge.md:608-609: schema stable across
win10 / win11 24H2 / 25H2, XML extractable, correlation unambiguous in practice). This document
is the concrete build plan for the day that gate passes; its companion harness skeleton is
`mgmt/harness/a0-p3-toast-split.sh` (P3d).

Grounding (everything here cites shipped code, not intentions):

- Phase 3 spec: DESIGN-toast-bridge.md **decision table :160-177**, Phase-3 write-up **:559-627**
  (AUTHORITATIVE — this doc implements §3.3/§3.4.3 and changes nothing in the table).
- Shipped A0 bridge: `tools/notifhost/notifhost.cpp` — listener/`FirstTexts` :178-192, allowlist
  :262-311, `ForwardText` :728-743, skip/window-path branch :920, lazy suppression :948-953,
  `BannerApplyOne`/`BannerRestoreAll` :394-476, build rule :42 (in-box winsqlite3, no new deps).
- Shipped P3b classifier: `tools/notifhost/toastclassify.h` — pure `ClassifyToastXml`/
  `ClassifyToastXmlBytes`, fail-open by construction, defect-reintroduction switches, unit suite
  `toastclassify_test.cpp`. P3c only *calls* it.
- Agent hold to extend: `agent/gui-agent/toastcrop.h` (`IsShellToastWindow`, `CropPending`),
  `agent/gui-agent/main.c` — defer set :2875-2883, `CROP_BEFORE_SHOW_TIMEOUT_MS` :2656 (=400),
  release logic :4901-4926, broker poke precedent :6365-6367.
- Bridge supervision (unchanged): `main.c` :2249-2423 (`NotifRunInSession`, `NotifBridgeSupervise`,
  heartbeat, stop file), gate read :8511-8545 (`g_NotifBridge`, legacy_toasts wins).

## 0. Invariants this design is not allowed to break

1. **FAIL-OPEN**: any DB-unreadable / schema-mismatch / parse-failure / correlation-ambiguity /
   WAL-contention / pipe-failure / forward-failure ⇒ the toast takes the **window path** — never
   bannerless-and-unforwarded, never silently lost. §5 enumerates every enforcement point.
2. **NO UNREQUESTED BEHAVIOUR CHANGES**: every new hold/latency applies ONLY when the mixed
   feature is armed (`NotifyBridgeMixed` non-empty AND `g_NotifBridge`). A non-mixed config keeps
   today's release condition **byte-for-byte** (the ~400 ms crop hold, main.c:4905-4919). No new
   qubesdb services, no extra knobs: `service.notify-bridge` stays the single master gate,
   `service.legacy-toasts` still forces everything off (it clears `g_NotifBridge`, main.c:8539-8541,
   which disarms mixed too).
3. **ShowBanner is NEVER written for a mixed app.** Per-toast suppression is the agent's
   deferred-map drop (DESIGN-toast-bridge.md:591-602): you cannot pre-suppress a toast whose
   content you have not seen, and A0's `ShowBanner=0` + a withheld forward would be a lost
   notification. `BannerApplyOne` remains reachable only from the A0 allowlist arm.
4. **Build rules**: notifhost stays v143 /MT C++/WinRT, no nuget/WDK (notifhost.cpp:42);
   SQLite via the in-box `C:\Windows\System32\winsqlite3.dll`, loaded with
   `LoadLibraryExW(L"winsqlite3.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32)` + `GetProcAddress`
   for the ~10 entry points used (open_v2/prepare_v2/step/column_*/finalize/close/busy_timeout/
   errmsg). No import library, no header dependency beyond a local minimal prototype block —
   zero new deployable dependencies.

## 1. Config: the three-tier routing

One new value, beside the existing one, same key notifhost already reads (notifhost.cpp:291):

```
HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent
  NotifyBridgeAllow  REG_MULTI_SZ   (exists, A0)  — per-APP bridge, ShowBanner suppression
  NotifyBridgeMixed  REG_MULTI_SZ   (NEW, P3c)    — per-TOAST split via the classifier
```

- **Empty/absent `NotifyBridgeMixed` ⇒ Phase 3 fully dormant** — notifhost never opens
  wpndatabase, never serves the verdict pipe; the agent never arms the verdict hold. There is
  deliberately **no compiled default seed** (unlike `DEFAULT_ALLOW`, notifhost.cpp:274-280):
  per-toast routing carries undocumented-DB risk and must be explicitly opted into per app.
- Routing per new toast, evaluated in this order (extends the poll-loop branch at
  notifhost.cpp:914-927):

  | tier | membership test (case-insensitive exact AUMID, as :919) | behaviour |
  |---|---|---|
  | 1 | AUMID ∈ `NotifyBridgeAllow` | **A0 unchanged**: forward, lazy `ShowBanner=0` after first success |
  | 2 | AUMID ∈ `NotifyBridgeMixed` | **per-toast**: classify via P3b, forward-then-confirm, verdict to the agent; ShowBanner untouched |
  | 3 | neither | today's `skip id=… (window path)` line :920, byte-for-byte |

  An AUMID listed in BOTH is a config error resolved in favour of **Allow** (tier 1 checked
  first): A0 semantics are the proven ones, and this keeps tier-1 behaviour independent of
  whether Phase 3 is deployed. Logged once at startup:
  `MIXED config warning: <aumid> in both Allow and Mixed - Allow wins`.
- Both lists are read once at `BridgeMain` startup (as today); the startup line :786 grows a
  `mixed=[…]` segment. Changing lists ⇒ bridge restart (`--bridge-stop`, supervisor relaunch
  ≤75 s) as for the allowlist today; the **agent** additionally reads only the *presence* of a
  non-empty `NotifyBridgeMixed` at its own init (§3.1), so arming/disarming mixed needs an agent
  restart / cold boot — same lifecycle as the `NotifyBridge` gate itself (main.c:8511 "read once
  at init").

## 2. notifhost: DB reader, classifier call, verdict-pipe server

### 2.1 wpndatabase reader (the P3a-gated part)

Path: `%LocalAppData%\Microsoft\Windows\Notifications\wpndatabase.db`, same user, read-only
(DESIGN-toast-bridge.md:577-589).

- **Open per classification attempt, not held**: `sqlite3_open_v2(path, &db,
  SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX, NULL)` + `sqlite3_busy_timeout(db, 200)`. Human-rate
  cadence makes per-attempt open cheap; not holding a handle (a) lets P3d's ACL-deny fault
  injection actually bite (§6 Q3a) and (b) avoids pinning a WAL snapshot that goes stale while
  ShellExperienceHost writes.
- **Schema gate at open** (fail-open on drift, DESIGN-toast-bridge.md:583-585): before the first
  real query of a bridge lifetime, prepare two probe statements —
  `SELECT Id, HandlerId, Payload, ArrivalTime FROM Notification LIMIT 0` and
  `SELECT RecordId, PrimaryId FROM NotificationHandler LIMIT 0`. Either failing to prepare ⇒ log
  `WPNDB schema mismatch - per-toast classification DISABLED (fail-open)` once, set a
  session-sticky `g_mixedDbBroken` flag: every subsequent mixed verdict is `window` without
  touching the DB again (re-probed only on bridge restart). Exact expected column names/types are
  whatever **P3a's `--dump-wpndb` probe measured on the rig** — the gate constant is filled in
  from the P3a evidence, not from forensics blog posts.
- **Per-toast query** (candidates for one listener event `{AUMID, Id, CreationTime, texts}`):

  ```sql
  SELECT n.Id, n.Payload, n.ArrivalTime
  FROM Notification n JOIN NotificationHandler h ON n.HandlerId = h.RecordId
  WHERE h.PrimaryId = ?1
  ORDER BY n.ArrivalTime DESC LIMIT 8
  ```

  then filter client-side to an arrival window (|row time − listener CreationTime| ≤ 30 s; the
  time-column epoch/unit is a P3a-measured fact) and a text match (the listener title from
  `FirstTexts()` must appear in the payload XML — both strings originate from the same
  `<text>` element, so substring match after entity-decoding is sound; P3a validates it).
- **WAL freshness**: a just-fired toast's row may not be visible yet. Bounded retry: up to 3
  attempts, 150 ms apart, all inside the verdict deadline (§2.3). Still absent ⇒ `window`
  (`corr=none`).
- **Correlation rule** (fail-open, DESIGN-toast-bridge.md:586-589): after filtering,
  - exactly one candidate ⇒ use it (`corr=ok`);
  - several candidates that all classify to the **same** route ⇒ use that route (`corr=multi`,
    still safe: the verdict is invariant across the ambiguity);
  - several candidates with **differing** routes, or zero ⇒ `window` (`corr=ambiguous|none`).

### 2.2 Classification + forward-then-confirm

For a tier-2 toast (from the poll loop or a verdict request, §2.4 — one shared function,
idempotent per listener `Id` via a verdict cache `Id → {route, tick}`):

1. Read + correlate (§2.1). Any failure ⇒ verdict `window`.
2. `ClassifyToastXmlBytes(payload)` (toastclassify.h:416) — pure, fail-open by construction.
3. **route = window** ⇒ done: verdict `window`, mark the id seen (the banner window delivers it).
4. **route = bridge** ⇒ **forward FIRST, confirm AFTER**: call `ForwardText(title, body, Id)`
   (notifhost.cpp:728 — ack-waited on the held A0 connection). Only a `true` return (server
   `Id` ack, :583) yields verdict `bridge`; so the agent drops a held window **only when dom0
   provably has the copy**. `ForwardText == false` (conn dead, write/ack failure, server
   reject) ⇒ verdict `window`.
5. Every outcome logs ONE `CLASSIFY` line (§4) and lands in the verdict cache.

**Mixed-list retry semantics — deliberately NOT A0's.** A0 leaves a failed-forward toast
*unseen* for unlimited retry (notifhost.cpp:920-923 comment, :954-958) because `ShowBanner=0`
means retry is the only route to delivery. A mixed toast whose forward failed got verdict
`window` — the banner window maps and **delivers it** — so it is marked **seen immediately, no
retry**: a later reconnect re-forwarding it would double-deliver (dom0 bubble for a toast the
user already saw as a window). Deterministic server rejects need no `fwdFails` cap for mixed —
one failure is final. The A0 `fwdFails`/`capFailed` machinery (:820-947) remains tier-1-only.

Burst behaviour: >3 fresh **bridge-verdict** mixed toasts in one pass join the existing
coalesce path (:960-973) with `guestId 0` (documented A0 limit); verdicts for held windows are
still delivered per-toast (§2.4). Window-verdict toasts never coalesce (nothing is sent).

### 2.3 Deadline discipline

Every verdict request carries the agent's absolute deadline (§2.4 wire). notifhost budgets:
DB retries and the forward must complete before `deadline − 250 ms` (margin for the reply +
agent pass). If the budget is exhausted **before** the forward was attempted ⇒ reply `window`
(no forward, no double-show; the toast is seen, delivered by the window). If the forward is
already in flight when the budget expires, it is allowed to finish — this is the residual
**double-show-on-timeout** case (§7), bounded to one dom0 round-trip's tail.

### 2.4 The verdict pipe (agent ⇄ notifhost)

A **second** named pipe, alongside the relay pipe (:645-654), served by the bridge only while
mixed is armed:

- Name: fixed, `\\.\pipe\qubes-toast-verdict` (the SYSTEM agent must find it without a
  discovery channel; single instance, `FILE_FLAG_FIRST_PIPE_INSTANCE` so a squatter loses to
  whoever is first — and if a squatter wins, the agent's requests fail their deadline and every
  toast maps: fail-open even under local-user mischief, and a malicious reply can only choose
  between the two safe-by-construction routes for a toast the attacker's session could fire
  anyway).
- Security: explicit SD `D:(A;;GRGW;;;SY)(A;;GRGW;;;OW)` — SYSTEM (the agent) + the creating
  user; message mode, one request per message, serving loop on its own thread (blocking
  `ConnectNamedPipe` → read → process → write → disconnect; the agent connects per request).
- Wire (UTF-8 text, one message each way, ≤512 bytes):

  ```
  agent → notifhost:  VREQ1 token=<hex64> hwnd=<hex> deadline=<tick64>
  notifhost → agent:  VRSP1 token=<hex64> verdict=window|bridge reason=<short-ascii>
  ```

  `token` is an opaque agent-side correlation cookie (echoed verbatim); `hwnd` is diagnostic
  only — notifhost cannot resolve HWNDs to toasts and does not try. `deadline` is
  `GetTickCount64`-domain (same guest, same clock).
- **Request semantics**: "one shell toast banner window just appeared; classify the
  newest-unseen mixed toast(s) and answer for THIS hold." Handler: run §2.2 for every fresh
  tier-2 listener toast not yet in the verdict cache (usually exactly one), then reply:
  - exactly one fresh verdict ⇒ that verdict;
  - multiple fresh verdicts, all equal ⇒ that verdict (matches the correlation rule:
    hwnd↔toast pairing is unknowable, but an invariant verdict is safe either way);
  - multiple differing, or zero fresh mixed toasts (the window belongs to a tier-1/3 app, or
    the listener has not seen it yet and the DB retry budget is gone) ⇒ `window`.
  This is the same ambiguity bias as §2.1, now at the hwnd level: **never guess which window
  is which; equal-or-window.** (P3d Q4 asserts exactly this: two same-AUMID informational
  back-to-back ⇒ both bridge or both window, never one lost.)
- Pipe absent (bridge down, gate off, mixed unarmed) ⇒ the agent's connect fails instantly ⇒
  the hold expires at its ceiling ⇒ window path. No handshake, no versioning beyond the `VREQ1`
  literal (unknown prefix ⇒ reply `VRSP1 … verdict=window reason=badreq`).

## 3. Agent: the bounded verdict-wait and the drop edge

### 3.1 Arming

At init, next to the `NotifyBridge` gate read (main.c:8511-8545): read `NotifyBridgeMixed`
via `RegQueryValueExW` (REG_MULTI_SZ, presence of ≥1 non-empty string is all that matters) and
set

```c
g_ToastVerdictArmed = g_NotifBridge && mixedNonEmpty;   // legacy_toasts already cleared g_NotifBridge
```

plus the ceiling: `ToastVerdictCeilingMs` DWORD under the same gui-agent key (read with
`CfgReadDword` like :8515), **default 1500**, clamped to
`[CROP_BEFORE_SHOW_TIMEOUT_MS, 10000]`. Logged:
`TOASTVERDICT armed ceiling=%lu ms` / nothing when dormant.

### 3.2 Hold entry (extends main.c:2875-2883)

Today a toast/menu defers only when `!CropReadyForMap(entry)`. Add, in `AddWindow`:

```c
BOOL verdictHold = g_ToastVerdictArmed && IsShellToastWindow(entry);   // toasts ONLY, never menus
if (entry->IsVisible && !entry->IsIconic &&
    ((IsMenuPopupWindow(entry) || IsShellToastWindow(entry) ||
      (g_DeSlice && entry->PwSliceFed)) && !CropReadyForMap(entry)
     || verdictHold))                                                  // NEW arm
{
    entry->MapDeferred = TRUE;
    entry->MapDeferSince = GetTickCount64();
    if (verdictHold) { entry->VerdictState = VERDICT_PENDING; VerdictEnqueue(entry->Handle); }
}
```

New `WINDOW_DATA` fields (main.h, beside `MapDeferred`/`MapDeferSince` :114-115):
`UCHAR VerdictState` (`NONE=0 / PENDING / WINDOW / BRIDGE`) and `BOOL VerdictDropped`.
`VerdictState` stays `NONE` forever when disarmed — that is what makes §3.3 reduce to today's
code. Note the CREATE/buffer-attach path above the map (:2820-2868) is untouched: a held
window is announced and attached exactly as the crop hold does today, so a `window` verdict
maps instantly with everything in place.

### 3.3 Release logic (extends main.c:4901-4926)

```c
if (windowData->MapDeferred && windowData->IsVisible && !windowData->IsIconic &&
    !windowData->Synthesized)
{
    ULONGLONG held = GetTickCount64() - windowData->MapDeferSince;
    BOOL cropDone = CropReadyForMap(windowData) || held > CROP_BEFORE_SHOW_TIMEOUT_MS;

    if (windowData->VerdictState == VERDICT_BRIDGE)            // NEW: the drop edge
    {
        windowData->MapDeferred = FALSE;
        windowData->VerdictDropped = TRUE;                     // never map this window
        LogInfo("TOASTDROP hwnd=0x%x held=%llums (bridged to dom0)", ...);
    }
    else if (cropDone &&
             (windowData->VerdictState != VERDICT_PENDING || held > g_ToastVerdictCeilingMs))
    {
        if (windowData->VerdictState == VERDICT_PENDING)       // ceiling hit: fail-open map
            LogWarning("TOASTVERDICT TIMEOUT hwnd=0x%x mapped after %llums (double-show possible)", ...);
        windowData->MapDeferred = FALSE;
        ... existing SendWindowMap + damage block :4911-4917 unchanged ...
    }
}
else if (windowData->MapDeferred) { ... existing :4920-4925 unchanged ... }
```

Disarmed configs: `VerdictState == NONE` always ⇒ the drop edge is dead code and the map
condition is literally `cropDone` — **today's behaviour exactly** (constraint 0.2).

The drop edge's aftermath: the window stays in the tracked list, `CreateSent`, unmapped.
`VerdictDropped` is consulted at every other site that could map or paint it — `ToggleMap`,
the damage send path, and `SendWindowMap` itself gets a guard (`if (VerdictDropped) return
ERROR_SUCCESS`) so no later code path resurrects it. It is NOT marked `DeletePending`:
removal would let the next tracking pass re-add → re-hold → re-request → (cache hit) re-drop,
a pointless 1-per-pass churn loop; keeping the tombstoned entry until the banner's own
destroy (~5 s later, normal `RemoveWindow`, which also runs `ToastCropEvict`) is loop-free.
Dom0 never sees a MAP for it, so there is nothing to unmap.

### 3.4 The verdict client thread

One agent thread owns the pipe-client side (the frame/tracking loop must never block on IPC):

- queue in: `VerdictEnqueue(hwnd)` from `AddWindow` (token = hwnd value + a monotonic counter);
- per request: `CreateFileW` the pipe (no wait — `WaitNamedPipe` 0; absent ⇒ resolve `window`
  immediately... **no**: resolve *nothing* — leave `PENDING` and let the ceiling expire. A
  fast-fail resolve would map the toast ~1.2 s earlier when the bridge is down, but it would
  also make the latency behaviour differ between "bridge down" and "bridge slow", and the
  simple rule "PENDING resolves only by VRSP or ceiling" is easier to prove fail-open; revisit
  only if P3d measures the full-ceiling wait as user-visible annoyance in the bridge-down
  case);
- on reply: under the watched-windows critical section, find the entry by token, set
  `VerdictState = WINDOW|BRIDGE` (discard if the window died meanwhile), then
  `PokeWindowTracking()` (precedent: the broker's crop poke, main.c:6365-6367) so the release
  runs promptly instead of at the next 2 s resync;
- a reply arriving after the ceiling already mapped the window: `VERDICT_BRIDGE` must NOT
  un-map (a visible flash, and dom0 already has the window) — the release logic above only
  drops from `MapDeferred`, so a late bridge verdict on a mapped window just logs
  `TOASTVERDICT LATE hwnd=0x%x verdict=bridge (double-show)`. That is the accepted §7 cost.

## 4. Log-line contract (shared with P3a, asserted by P3d)

P3a's measure-only probe and P3c's live path emit the SAME `CLASSIFY` format — one line per
classified toast, in `bridge.log` (BLog, rotation :227-229):

```
CLASSIFY id=<listenerId> aumid=<AUMID> row=<0..6> verdict=<window|bridge> corr=<ok|multi|ambiguous|none|nodb> src=<probe|live> reason=<toastclassify reason string>
```

(`row`/`reason` come from `ToastClass` :68-74; `corr` from §2.1; `src=probe` is P3a's shadow
pass whose routing stays byte-for-byte A0, `src=live` is P3c.) Additional P3c lines:

| line | where | meaning |
|---|---|---|
| `VREQ token=<t> hwnd=<h> -> verdict=<v> (<reason>) in <ms>ms` | bridge.log | one verdict served |
| `MIXED forward-failed id=<id> - verdict=window, seen (no retry)` | bridge.log | §2.2 step 4 failure |
| `WPNDB schema mismatch - per-toast classification DISABLED (fail-open)` | bridge.log | §2.1 gate |
| `TOASTDROP hwnd=0x%x held=%llums (bridged to dom0)` | gui-agent log | the drop edge fired |
| `TOASTVERDICT TIMEOUT hwnd=0x%x mapped after %llums (double-show possible)` | gui-agent log | ceiling hit |
| `TOASTVERDICT LATE hwnd=0x%x verdict=bridge (double-show)` | gui-agent log | reply after map |
| `TOASTVERDICT armed ceiling=%lums` | gui-agent log | init, mixed armed |

Forwards keep A0's exact `SENT id=… OK` line (:979) so every existing `a0-lib.sh` detector and
offset idiom (`blog_len`/`blog_since`) keeps working unmodified.

## 5. Fail-open enforcement points (complete list)

| # | fault | enforcement | net effect |
|---|---|---|---|
| 1 | mixed list empty/absent | notifhost never opens DB/pipe; agent `g_ToastVerdictArmed=FALSE` | Phase 3 dormant, A0 byte-for-byte |
| 2 | gate off / legacy-toasts | `g_NotifBridge=FALSE` (main.c:8539) disarms mixed AND the bridge | all toasts window path |
| 3 | DB missing/unreadable/ACL-denied | open fails per attempt ⇒ verdict `window` | window path |
| 4 | schema drift | prepare-probe gate ⇒ sticky disable, all verdicts `window` | window path |
| 5 | WAL lag / SQLITE_BUSY | busy_timeout 200 ms + 3×150 ms bounded retry ⇒ `corr=none` ⇒ `window` | window path |
| 6 | payload malformed/undecodable | `ClassifyToastXml*` rows 0 fail-open (toastclassify.h:300-310,416-419) | window path |
| 7 | correlation zero/ambiguous | §2.1 rule ⇒ `window` | window path |
| 8 | multiple held windows, differing verdicts | §2.4 equal-or-window rule | all window |
| 9 | forward fails (conn dead/reject) | forward-then-confirm ⇒ verdict `window`, seen, no retry | window path, no double |
| 10 | bridge process down / pipe absent | agent hold expires at ceiling ⇒ map | window path (+ceiling latency) |
| 11 | verdict thread/pipe wedged | same ceiling; PENDING can only resolve via VRSP or ceiling | window path |
| 12 | agent dies mid-hold | window was never suppressed anywhere (no ShowBanner write); guest banner + Notification Center intact | nothing lost |
| 13 | consent revoked | existing bridge FATAL-exit (:883-885) ⇒ pipe gone ⇒ #10 | window path |
| 14 | notifhost crash post-forward pre-reply | agent ceiling ⇒ map ⇒ double-show (§7), never loss | double, not loss |

The one *structural* loss-shape Phase 3 could have introduced — suppressed-but-unforwarded —
is impossible by constraint 0.3: no code path writes `ShowBanner` for a tier-2 AUMID.

## 6. What P3d asserts (see mgmt/harness/a0-p3-toast-split.sh)

Q1 mixed-empty regression guard (A0 byte-for-byte, zero CLASSIFY lines); Q2 headline
same-AUMID split (informational ⇒ `SENT…OK` + `CLASSIFY verdict=bridge` + `TOASTDROP`, no new
o-r window; real-choice ⇒ o-r window, zero SENT, `CLASSIFY verdict=window`); Q3 fault
injections each seen-to-fail (DB ACL-deny ⇒ #3, bridge stopped ⇒ #10, consent revoke ⇒ #13,
ShowBanner spot-check ⇒ constraint 0.3); Q4 ambiguity bias (#8) + burst; Q5 cold-boot
persistence + legacy-toasts (#2).

## 7. Named architectural costs (owner-visible, not bugs)

1. **Map latency on every toast of a mixed-armed guest.** While armed, EVERY
   `IsShellToastWindow` banner (tier-1 and tier-3 apps included — the agent cannot know the
   AUMID tier, only notifhost can) waits for its verdict: typically one VREQ round-trip
   (~DB read + classify + forward ≈ 100-600 ms), worst case the full ceiling (default
   1500 ms) when the bridge is down/slow. Non-armed configs: zero change. (Tier-1/3 windows
   resolve as `window` in one round-trip — no forward — so their typical added latency is the
   DB-read path only, but it is not zero.)
2. **Double-show-on-timeout.** Ceiling expiry maps the window; a forward already in flight may
   still land in dom0 ⇒ the same toast appears as both an o-r window and a dom0 bubble.
   Bounded by §2.3's deadline margin to the in-flight tail; logged (`TOASTVERDICT
   TIMEOUT`/`LATE`); the deliberate trade — the alternatives are un-mapping a shown window
   (visible flash) or dropping without confirmation (possible loss).
3. **Non-seamless double render for mixed apps.** A0 suppresses the guest banner
   (`ShowBanner=0`) so non-seamless shows only the dom0 bubble; mixed cannot pre-suppress, so
   a bridged mixed toast in non-seamless shows the banner *inside* the desktop window AND the
   dom0 bubble. (In seamless the deferred-map drop removes the dom0 window; the in-guest
   pixels exist but are never presented.)
4. **Win10/legacy-slice bleed.** On slice-fed configs (no de-slice/broker) a dropped banner's
   pixels still sit in the composited desktop and can bleed into overlapping windows' slices.
   Mixed is therefore best gated in practice to de-slice-capable guests; P3d runs on win10
   must eyeball Q2 shots for bleed before the feature is recommended there.
5. **Undocumented DB on the hot path** — the P3a gate exists precisely to price this; schema
   drift after shipping degrades to all-window (enforcement #4), i.e. A0 behaviour, silently
   minus the split.

## 8. Fixture spec: `guest/fire-demo-toast.ps1 -Long` (P3d prerequisite)

fire-demo-toast.ps1:17-19 already predicts the trap: `-Persistent` uses `scenario="reminder"`
(+an OK action), which the P3b classifier routes **window** (row 3 — and the action alone
would hit row 4), so under Phase 3 it can no longer serve as the *bridged*-and-visible
fixture. The positive persistent-informational fixture is a new switch:

- **Switch**: `[switch]$Long`, mutually exclusive with `-RealChoice`/`-Persistent` (error out
  if combined — a silently-merged XML would corrupt the class).
- **XML** (text-only, row-6 informational; `duration` is not classification-relevant —
  toastclassify.h ignores unknown attributes/elements — so this classifies
  `verdict=bridge row=6 reason=no banner actions`):

  ```xml
  <toast duration="long"><visual><binding template="ToastGeneric"><text>$t</text><text>$b</text></binding></visual></toast>
  ```

  `duration="long"` keeps the banner on screen ~25 s (vs ~5 s default) with **no actions and
  no scenario** — long enough for one immediate `geom` pass to catch its o-r window in the
  fail-open arms (Q3), while remaining a true buttonless informational toast for the bridge
  arms (Q2). Detection caveat the harness carries: 25 s < the rig's ~59 s/geom call, so
  `new_or_window … 1` must be issued IMMEDIATELY after the fire and the result treated as
  best-effort (the deterministic detector for window-path mixed toasts is `CLASSIFY
  verdict=window` + zero `SENT`, with geom as corroboration).
- **FIRED line**: extend the existing trailer to
  `FIRED class=long aumid=… title=… tag=…` (class values: realchoice | informational |
  long; `-Persistent` keeps printing `informational` for A0-harness compatibility).
- Tag/Group uniquing unchanged (:44-47).
- NOT implemented in this pass: the file is a live A0-harness fixture
  (`a0-lib.sh` fire_raw/fire_info/fire_info_p) and changes to it ride with the P3c/P3d
  landing, not before.

## 9. Build/test plumbing

- `toastclassify.h` gets included by notifhost.cpp under mixed (it is header-only; no project
  change beyond the include). The winsqlite3 loader is a new small TU or a section of
  notifhost.cpp; no .vcxproj dependency changes (LoadLibrary, not linking).
- CI: `toastclassify_test.cpp` already carries the defect-reintroduction proof builds
  (toastclassify.h:47-53). P3c adds two more seen-to-fail hooks, compile-time, notifhost test
  builds only: `P3C_DEFECT_NOFORWARDCONFIRM` (reply `bridge` before/without the ack — Q2/Q3
  must then catch a dropped-and-unconfirmed toast) and `P3C_DEFECT_SUPPRESS_MIXED` (route the
  mixed arm through `BannerApplyOne` — Q3d's ShowBanner spot-check must catch `=0`).
- Effort (refines DESIGN-toast-bridge.md:620-621): notifhost DB+pipe ~1 session, agent hold
  ~0.5-1, P3d execution ~1 (Opus, per the acceptance division), on top of the P3a probe gate.

## 10. Acquisition layer — the ETW-first ladder (appended 2026-09-05, design only)

This section refactors ONE thing: **where the payload XML comes from**. Everything downstream
of "payload bytes in hand" — `ClassifyToastXmlBytes` (toastclassify.h:416), the verdict
channel (§2.4), the deferred map (§3), the fail-open table (§5) — is unchanged and is NOT
rewritten here. §2.1's DB reader stops being *the* acquisition step and becomes **tier D of a
three-tier ladder**. The shipped P3a probe (notifhost.cpp: `WpnSqlGet` :572-591,
`WpnCorrelate` :712-767, `ShadowClassify` :799-841, `DumpWpnDbMain` :846-906) is kept intact
as that tier; nothing in this section deletes or weakens it.

### 10.1 Why: what the DB tier costs, in the shipped code's own numbers

1. **The correlation heuristic.** The DB shares no key with the listener
   (DESIGN-toast-bridge.md:151-153, :587-589), so `WpnCorrelate` guesses by AUMID +
   ±60 s ArrivalTime window + first-`<text>` match (notifhost.cpp:712-767), and every
   ambiguity — >1 text match, >1 candidate with no match — is forced to `window`
   (:761-764). Two same-AUMID same-title toasts inside a minute are *structurally*
   unclassifiable on this tier. ETW hands us `{AUMID, payload}` **in the same event, at the
   source** — there is nothing to correlate, so the heuristic and its ambiguity class die.
2. **The WAL-retry latency, on the poll thread.** `WpnCorrelate` runs up to 3 attempts,
   150 ms sleeps between, each open capped by a 250 ms `busy_timeout` (:714-716, :618):
   arithmetic ceiling 3×250 + 2×150 ≈ **~1050 ms per fresh toast** (the in-code comment's
   "~650 ms" :715 under-counts its own arithmetic — 3 opens at 250 ms is already 750).
   `ShadowClassify` is called from the poll loop (:1337, comment :1331-1336 admits the cost),
   the same thread that writes the supervisor heartbeat (:1254-1264). A 3-toast burst can
   stall a pass ~3 s. That is *inside* the 15 s deadline — but it is exactly the
   **variable per-toast hot-loop latency class** that already got the bridge TERMINATED once
   (the CreateToolhelp32Snapshot bisect, :94-101). ETW-first exists to REMOVE this class,
   not to shave it.
3. **Undocumented-schema risk stays either way** — an ETW provider's event shape is exactly
   as undocumented as the DB schema. That is why ETW is a *tier*, not a replacement (§10.6).

### 10.2 The ladder

Three tiers, tried strictly in order, per toast. A tier never blocks the next; the floor is
today's shipped behaviour.

| tier | source | yields | degrade to next tier when |
|---|---|---|---|
| **E — ETW** (primary) | real-time trace session on the candidate notification providers | `{AUMID, payload XML}` pushed at source | per-toast: no matching record (no event, event carried no payload property, TDH decode failed, first-`<text>` mismatch vs the listener title, >1 differing candidate). Tier-wide (sticky for the process, one `ETW DOWN` line): session create/enable `ERROR_ACCESS_DENIED` (unprivileged token), `StartTraceW` fails after one stop-stale-and-retry, zero providers enable, `ProcessTrace` returns unexpectedly, consumer thread threw. Re-armed only on bridge restart — no in-process retry loop. |
| **D — DB correlate** (fallback) | shipped `WpnCorrelate` :712-767, byte-for-byte | correlated Payload bytes, `corr` class | every failure class it already has: no-winsqlite3, db-fail, schema-mismatch (sticky, :740-744), notfound, ambiguous, text-mismatch |
| **W — window** (floor) | none | verdict `window` | never — this IS the fail-open floor (§0.1, §5) |

**Fail-open across tiers**: `bridge` can only ever be EARNED — a clean payload (tier E match
or tier D `corr=ok`) that `ClassifyToastXmlBytes` routes `bridge`, and (live mode, §2.2 step
4) a confirmed forward. Every fault at every tier degrades toward `window`, which is today's
exact behaviour; the ladder adds acquisition paths, never removes the floor. The §5 table
gains one row:

| # | fault | enforcement | net effect |
|---|---|---|---|
| 15 | ETW tier dead/denied/payload-less | per-toast and tier-wide degrade rules above | tier D (shipped), then window |

**Measure-only preserved (shadow mode, --bridge today)**: the ladder feeds ONLY
`ShadowClassify`'s logging. The A0 skip/forward routing (:1338-1401) reads nothing the ETW
tier produces; the consumer thread and the acquisition worker (§10.3) call `BLog` and touch a
private record buffer, nothing else; all their exceptions are self-swallowed (the
`ShadowClassify` pattern :798, :837-840), so they can never feed `failStreak`/FATAL
(:1416-1420). It remains *impossible by construction* for the probe to change which toasts
banner or forward. Two seen-to-fail hooks (autonomy rule 5), compile-time, test builds only:
- `P3AQ_DEFECT_HOTWAIT` — perform the ETW wait on the poll thread; the harness's
  heartbeat-cadence detector (max mtime gap of `%ProgramData%\qubes-toast-bridge\heartbeat`
  during a 3-toast burst ≤ 4 s) must then FAIL.
- `P3AQ_DEFECT_ROUTE` — let the ETW verdict gate the forward; the routing-invariance detector
  (identical `SENT`/`skip` line sequence for the same fixture sequence with ETW armed vs
  disabled) must then FAIL.

### 10.3 Threading — the AgentGone rule, generalized

Two new threads inside `--bridge`; the poll loop's per-toast cost becomes a fixed-cost
enqueue. **The poll thread never waits for acquisition — not for ETW, and no longer for the
DB either.**

1. **ETW consumer thread** (blocking by design): owns the whole session lifecycle —
   `ControlTraceW(EVENT_TRACE_CONTROL_STOP)` on the fixed name first (a crashed bridge leaks
   its session: ETW sessions outlive processes, and the system caps at 64), then
   `StartTraceW` (EVENT_TRACE_PROPERTIES: `EVENT_TRACE_REAL_TIME_MODE`, small buffers,
   `FlushTimer=1` — the documented minimum, see the latency caveat below, and
   `Wnode.ClientContext=2` system-time stamps so event timestamps compare directly to the
   fixture's FIRED clock and wpndb ArrivalTime), `EnableTraceEx2` per candidate provider,
   `OpenTraceW` (`PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD`), then
   `ProcessTrace` — which blocks this thread until stop; that is why it gets its own thread
   (evntrace.h contract). Session name fixed: `QubesToastEtw` (singleton bridge per session
   already, mutex :1163-1164; a same-name squatter ⇒ stop+retry once ⇒ tier-wide degrade,
   fail-open). Per event: `TdhGetEventInformation` (tdh.h; handles both manifest and
   self-describing TraceLogging events on Win10+), scan properties for an AUMID-like and a
   toast-XML-like value; on a hit, append `{aumid, payload, eventTs, deliverTick}` to a
   fixed-cap (32) ring under a small critical section and `SetEvent` the worker. Shutdown on
   bridge exit: `ControlTraceW` STOP + `CloseTrace`, bounded 3 s join (the `ConnDown`
   pattern :1029).
   Provider name→GUID: manifest names (`Microsoft-Windows-PushNotifications-Platform`,
   `Microsoft-Windows-Notifications`) via `TdhEnumerateProviders`; dotted TraceLogging names
   (`Microsoft.Windows.Shell.NotificationController`) via the standard EventSource
   name-hash GUID derivation (they are not in the registered-provider list) — correctness of
   the derivation is proven on the rig by whether events flow at all (§10.7).
2. **Shadow acquisition worker**: consumes a queue of `{listenerId, aumid, creationFt,
   title}` captured by `ShadowClassify` on the poll thread (all cheap — those WinRT reads
   already happen there today :821-824). Per entry: consult the ETW ring; on miss while tier
   E is healthy, wait on the consumer's event up to **2000 ms** (flush-timer staleness cover
   — legal here, this thread owns no heartbeat); still no match ⇒ tier D
   (`WpnCorrelate`, unchanged, now OFF the poll thread); then classify + emit the one
   `CLASSIFY` line (the `logged`-set exactly-once contract :803-805 moves with it). Net
   effect on the poll loop: today's ~650-1050 ms-per-toast `WpnCorrelate` stall (:1335-1336)
   is REMOVED even when ETW yields nothing — the refactor pays for itself before any ETW
   provider is proven.
3. **Live mode (P3c, later)**: the verdict-pipe handler (§2.4, already its own thread) uses
   the same ladder under §2.3's deadline discipline — the ETW wait is capped at
   `deadline − 250 ms` like every other budget item. No change to §2.3's rules.

**ETW latency caveat (honest, rig-measured, not assumed)**: real-time sessions deliver
events when a buffer fills or the flush timer fires; the timer's floor is 1 s. A sparse
single toast can therefore arrive up to ~1 s after emission. So ETW's *guaranteed* win is
killing the correlation heuristic and taking acquisition off the hot loop; whether it also
beats tier D's end-to-end latency is precisely what §10.7 measures (`deliver_lat`), not
something this design asserts.

**Build**: everything above is evntrace.h/evntcons.h/tdh.h, linked from in-box SDK libs
only — `advapi32.lib` (StartTraceW/ControlTraceW/EnableTraceEx2/OpenTraceW/ProcessTrace/
CloseTrace) is ALREADY linked (notifhost.vcxproj:84,106); **`tdh.lib`
(TdhGetEventInformation, TdhEnumerateProviders) is the one addition** — added to both
configs' AdditionalDependencies in this change. No nuget, no WDK, /MT v143 unchanged
(vcxproj:3-9). No new processes, no new qubesdb services, `service.notify-bridge` remains
the single master gate; the ETW tier arms only inside `--bridge` and `--dump-etw`.

### 10.4 Log-line formats

bridge.log (BLog :230-251; appends are per-call `FILE_APPEND_DATA`, safe from both threads):

```
ETW ENABLE provider=<name> guid=<guid> hr=0x<hr8>            one per candidate at arm time
ETW ARMED session=QubesToastEtw providers_ok=<n>/<m>          consumer up, n providers live
ETW DOWN reason=<denied|start-failed|enable-none|processtrace-exit|consumer-threw> hr=0x<hr8>
                                                              tier-wide degrade, logged once
ETW REC aumid=<aumid> bytes=<n> deliver_lat=<ms> provider=<slug>
                                                              one payload-bearing event captured
                                                              (deliver_lat = consumer tick − event
                                                              timestamp; throttled: first 50 per
                                                              run, then 1-in-20 + a count)
```

The shipped `CLASSIFY` line (:834) grows one APPENDED field (existing `a0-lib.sh` grep/offset
detectors keep working — nothing before it moves):

```
CLASSIFY id=%u verdict=%s row_latency=%lums signals=%s corr=%hs acq=%hs
```

`acq` ∈ `etw|db|none`. For `acq=etw`, `corr` ∈ `ok|text-mismatch` (the listener-title match
against the ETW payload's first `<text>`, same check as tier D's, same rule: only `ok` may
say `bridge`). For `acq=db` the `corr` domain is exactly the shipped one (:699-700).
`row_latency` becomes the whole-acquisition latency: enqueue → payload-in-hand (ETW ring hit
≈ 0-2000 ms wait; DB fallback adds `WpnCorrelate`'s own measured cost). `SUPPAPI`, `FWD_RTT`
(:1128-1142), `SENT`, `skip` lines: unchanged.

### 10.5 `--dump-etw` — new opt-in CLI diag mode (launched by nothing)

`notifhost --dump-etw [seconds] [provider ...]` — default 30 s, default provider set = the
three candidates above. Runs the consumer inline (it IS the diag), prints to stdout in
`DumpWpnDbMain`'s narrow-stream style (:846-906):

```
ETWDUMP session=QubesToastEtw dur=<s> providers=<m>
ENABLE provider=<name> guid=<guid> hr=0x<hr8>
EVENT ts=<iso8601Z> provider=<name> event_id=<n> pid=<n> deliver_lat=<ms> nprops=<n>
PROP <name> intype=<tdh-intype> len=<n> value="<preview, first 256 chars, quotes escaped>"
PAYLOAD aumid=<aumid|-> bytes=<n> verdict=<window|bridge> row=<n> reason="<r>" xml=<full XML, one line>
ETWDUMP OK events=<n> payload_events=<n>
```

`PAYLOAD` fires when an event property parses as a full `<toast>` document
(`ClassifyToastXmlBytes` accepts it — the shadow verdict doubles as the "is it really the
XML" check). Exit codes, harness-gateable like `--dump-wpndb`'s (:844-845): **0** clean run
(judge counts from the OK line), **2** session create/enable `ERROR_ACCESS_DENIED` — THE
unprivileged-block signal, **3** session started but zero providers enabled / other start
failure. Never launched by the agent, the installer, or any task — a rig hand tool only.

### 10.6 Retiring tier D — criteria, and why not yet

Tier D is retired ONLY after the rig proves, for at least one provider, **on every build in
the OS matrix** (win10-base 22H2, win11-base 24H2, win11 25H2 once provisioned):

1. **Full payload**: 100% of the standard fired sequence yields a `PAYLOAD` line whose XML
   classifies to the SAME verdict as the wpndb Payload for the same toast (row-level
   agreement, not just presence) — across ≥2 runs per build **with a reboot between** (the
   boot path is part of acceptance, CLAUDE.md).
2. **Unprivileged**: exit 0 (never 2) under the plain interactive user token — no group
   membership changes, no elevation. (Real-time session control/consumption is documented as
   requiring admin / Performance Log Users / LocalSystem; the testbed user's UAC-filtered
   token is expected to be denied — this criterion is where that expectation is tested, not
   assumed.)
3. **Shape stability**: identical provider + event_id + property names across all builds in
   the matrix (an ETW rename is the same failure mode as a DB schema drift).
4. **Latency**: `deliver_lat` p95 measured, and p95(deliver_lat) + p95(FWD_RTT) ≤
   verdict ceiling − 250 ms margin (§2.3) — i.e. ETW is usable LIVE, not only in shadow.

Until all four hold everywhere, **tier D stays**, because: it is the only *proven*
full-payload source (shipped, schema-gated at :740-744, probed by `--dump-wpndb`); ETW swaps
one undocumented internal for another and only pays if strictly better on the measured axes;
and the ladder makes keeping it free — tier D is already written, exception-tight, and after
§10.3 it no longer costs the hot loop anything. Retirement is a separate, later owner-visible
decision; this design never conditions correctness on it.

### 10.7 Updated Opus rig-run spec (extends the DESIGN-toast-bridge.md:605-609 gate)

Runs on Opus per the acceptance division (Fable hands off ready-to-run; no VM contact from
the design/impl side). Per guest — win10-base (22H2), win11-base (24H2), +25H2 when
provisioned:

1. Provision from the release package carrying the `--dump-etw` build (prime-run path, no
   binary swaps).
2. In the interactive user session: start `notifhost --dump-etw 90` capturing stdout; while
   it runs, fire the standard sequence via `guest/fire-demo-toast.ps1` — informational,
   `-RealChoice`, `-Persistent`, and a 4-toast burst — recording each `FIRED` line with a
   guest timestamp. Then run `notifhost --dump-wpndb 20` (existing probe, same session).
   Separately run `--bridge` (gate ON, shadow) through the same fixture sequence for
   `CLASSIFY`/`row_latency`/`FWD_RTT` lines, 3 interleaved repetitions per the instrument
   rules (metric stability before any verdict).
3. Grade, per provider per build:
   - **payload availability**: `payload_events` vs fired count; XML verdict agreement vs the
     wpndb row for the same toast (§10.6.1);
   - **privilege**: exit code 2 vs 0 under the user token; if 2, ONE diagnostic re-run via
     the SYSTEM qrexec path — solely to distinguish "denied" from "provider carries
     nothing", never as a deployment plan;
   - **latency**: per fired toast, (FIRED → EVENT ts), `deliver_lat`, and (FIRED → wpndb
     row available) via the shadow `row_latency acq=db` distribution — the direct
     confirmation (or refutation) that ETW removes the ~1050 ms WAL-retry ceiling from
     acquisition;
   - **defect proofs**: one run each with `P3AQ_DEFECT_HOTWAIT` and `P3AQ_DEFECT_ROUTE`
     builds — both detectors must FAIL, or they count as decoration.
4. **Verdicts** (write to FINDINGS.md, report deltas):
   - **PICK ETW PRIMARY** when §10.6 criteria 1-3 hold on all tested builds and 4 at least
     on shadow numbers ⇒ tier E is primary, tier D confirmed fallback; DB retirement stays a
     separate later decision.
   - **FALL TO DB** when any build shows exit-2 unprivileged, or missing/truncated payload,
     or shape drift ⇒ tier E remains compiled-in shadow-only opportunism (it degrades
     per-toast anyway), tier D remains the primary acquisition, and the P3c gate reverts to
     the original DESIGN-toast-bridge.md:608-609 DB-schema criteria unchanged.
   - **KILL** when on any build NEITHER source yields the payload — every candidate
     provider payload-less even in the elevated diagnostic AND `--dump-wpndb` exits 4
     (schema mismatch) ⇒ per-toast classification is unbuildable on that build: STOP, report
     to the owner; A0 per-app stays the shipped ceiling there (the fail-open floor is
     already the shipped behaviour, so nothing regresses).

### 10.8 Open risks (named, not resolved here)

1. **Same-user event spoofing**: user-mode provider GUIDs are not authenticated — a
   same-session process can emit forged "toast" events. Same trust class as the
   user-writable wpndatabase and the verdict-pipe squatter (§2.4): the attacker already owns
   the session and can only choose between two safe-by-construction routes; the
   listener-title match limits casual injection. Worst live-mode effect: a real-choice toast
   mis-bridged ⇒ lost buttons, never a lost notification.
2. **Flush-timer floor (~1 s)** may make ETW slower than a first-attempt DB hit for sparse
   toasts — measured, not assumed (§10.7.3), and mitigated by the ladder either way.
3. **Privilege**: if unprivileged consumption is denied everywhere, the only cures (group
   membership change by the SYSTEM agent, or an agent-side ETW proxy) are behaviour changes
   requiring an explicit owner decision — NOT taken unilaterally (no-unrequested-changes
   rule); the ladder simply keeps tier D primary. **RESOLVED 2026-09-05: the owner directed
   the proxy route — §10.10-§10.16 below are that design.** The consumer moves OUT of
   `--bridge` into a separate `--etw-proxy` process under a Performance-Log-Users-only
   token, launched by the agent; the bridge's tier E becomes a locked one-way pipe reader.
4. **TraceLogging GUID derivation** for the dotted provider name is computed, not looked up;
   a wrong derivation reads as "provider silent" — indistinguishable from payload-less until
   cross-checked (the rig run should also try the manifest providers first for exactly this
   reason).
5. **Session leakage** on hard kill (no exit path runs): one stale `QubesToastEtw` session
   holding small buffers until the next bridge start stops it — bounded, self-healing, but
   visible to `logman query -ets` and worth a line in the run report if seen.

## 10.9 As-shipped status (2026-09-05) — what §10.1-10.8 designed vs what the code now carries

The P3-ETW shadow tier from §10.2-10.5 has since been **implemented inside `--bridge`**
(notifhost.cpp, the "P3-ETW: push acquisition tier" section :807-1379). Where the shipped
code and the earlier prose differ, THE CODE is the baseline the proxy refactor starts from:

| §10.x said | shipped code does | ref |
|---|---|---|
| session `QubesToastEtw`, 3 providers | `QubesToastBridgeEtw` (+ `QubesToastEtwDump` for the diag), **5-entry candidate table** (1 manifest GUID + 4 name-hashed TraceLogging names via `EtwNameToGuid`) | :861-862, :871-879, :886-915 |
| ring cap 32, worker wakes on event | ring capped at **64 entries, count only — no byte cap** (§10.12.2) | :1156-1157 |
| shadow acquisition **worker thread**, DB fallback off the poll thread | **NOT built**: `ShadowClassify` runs on the poll thread (:1972) and calls `WpnCorrelate` there on every ETW gap — the ~650-1050 ms WAL-retry stall §10.1.2 promised to remove is still on the hot loop (comment :1970-1971 admits it) | :1441-1461, :733-788 |
| `ClientContext=2`, `FlushTimer=1` | `ClientContext=1` (QPC), no FlushTimer set | :958 |
| `CLASSIFY … acq=` field | `CLASSIFY id=%u src=%hs etw=%hs verdict=%s row_latency=%lums signals=%s corr=%hs` (src∈etw\|db\|none; etw∈hit\|miss\|text-mismatch\|down\|off) | :1462-1463, :1383-1394 |
| `--dump-etw` exit 2/3 | exit **5** access-denied, **6** other start failure, **7** consumer open failure | :43-52, :1336-1379 |

Also shipped: `EtwSessionStart` (:951-966, stale-session reap first :938-949),
`EtwEnableProviders` (:972-994, `EnableTraceEx2` VERBOSE + MatchAnyKeyword ~0 :984-985),
`EtwTierThread` (:1167-1221 — `ProcessTrace` blocks its own thread :1203;
`ERROR_ACCESS_DENIED` parks the tier permanently :1175-1183; 5 retries 120 s apart
:1211-1219), defensive TDH decode `EtwDecode` (:1025-1099, bounds: 1 MB TEI :1033, 64
props :1047, 64 KB/property :1065, 4 MB format buffer :1075, 48-byte hex fallback
:1085-1091), harvest heuristics `EtwHarvest` (:1113-1138), the ring callback
`EtwBridgeEventCb` (:1145-1165), the poll-thread lookup `EtwTierLookup` (:1265-1291), and
`DumpEtwMain` (:1336-1379). `tdh.lib` is already linked in both configs
(notifhost.vcxproj:87,109; v143 /MT SDK-only unchanged :44-52,:100).

**Why the refactor is mandatory, in the shipped code's own words**: the in-bridge consumer
runs under the interactive user token, and `EtwTierThread` documents the consequence —
"Expected for a plain user token (real-time session control wants Performance Log Users
membership or elevation)" (:1177-1179). As shipped, tier E is EXPECTED to be born dead on
every guest, and the ladder lives on the DB rung. The two cures §10.8.3 named are now
owner-decided: the consumer moves OUT of `--bridge` into `notifhost --etw-proxy`, a separate
process under a Performance-Log-Users-only token. §10.10-§10.16 are that design. Everything
stays inside the one `notifhost.exe` binary (a mode, not a new exe — the packaging lesson
from 4.3.18 stands: helper binaries ship only if explicitly staged, so reusing the
already-packaged exe adds zero packaging surface).

## 10.10 The process split: `--etw-proxy` (privileged, untrusted-parsing) vs `--bridge` (plain user)

### 10.10.1 The security property this split exists to enforce

ETW event payloads are **attacker-influenceable data**: any process in the guest session can
emit events under a user-mode provider GUID (GUIDs are not authenticated — §10.8.1), and
TDH decoding (`TdhGetEventInformation`/`TdhGetPropertySize`/`TdhGetProperty`) parses
complex, self-describing, adversary-shapeable metadata — a classic parser attack surface.
The naive fix for the access-denied gate ("run the consumer as SYSTEM / run the bridge
elevated") would put that parse at high privilege. **This design's invariant: the
untrusted ETW/TDH parse never runs as SYSTEM or admin.** Concretely:

- **`notifhost --etw-proxy`** hosts EVERYTHING that touches raw event records: session
  start/stop (`EtwSessionStart`/`EtwSessionStop` :938-966), provider enable
  (`EtwEnableProviders` :972-994, `EtwNameToGuid` :886-915), `OpenTrace`/`ProcessTrace`
  (:996-1003, :1203), the TDH decode (`EtwDecode` :1025-1099) and the harvest heuristics
  (`EtwHarvest` :1113-1138). It runs under a token whose only grant beyond a bare local
  user is **BUILTIN\Performance Log Users membership (S-1-5-32-559)** — the documented
  sufficient group for real-time session control/consumption — optionally narrowed further
  per §10.14.3. It is additionally: non-interactive (batch logon, no desktop), job-limited
  (memory cap, 1 process, UI-restricted, kill-on-job-close), network-blocked (per-account
  outbound firewall block + deny-network-logon right, §10.14.4), and holds ONE writable
  IPC object — the outbound-only pipe it serves.
- **`notifhost --bridge`** (plain interactive user, unchanged token) loses the in-process
  consumer entirely (`EtwTierThread`/`EtwBridgeEventCb`/`EtwTierStart/Stop` :1145-1251 move
  to the proxy mode) and gains a pipe **reader** thread that fills the same ring the
  shipped `EtwTierLookup` (:1265-1291) scans. The bridge parses pipe frames as bounded,
  length-checked, UNTRUSTED input (§10.11.4): payload bytes go only through the DB tier's
  existing defensive decoders (`WpnPayloadToW` :655-667, `WpnFirstTextW` :698-716) and the
  pure fail-open classifier (`toastclassify.h` — no Windows headers, adversarial bounds
  kMaxChars/kMaxElems/kMaxDepth/kMaxAttrs :85-88, every doubt routes `window` :27-38).
- **The SYSTEM gui-agent** never touches event data at all. Its entire involvement is
  process lifecycle: create/launch/supervise the proxy (§10.14, design only). It never
  connects to the ETW pipe, never reads a frame. (The P3c verdict pipe §2.4 remains the one
  SYSTEM-parses-derived-data spot; it is a ≤512-byte fixed-prefix text reply whose only
  semantic content is a choice between two safe-by-construction routes — unchanged here.)

**Blast radius of a subverted proxy** (a TDH/decode exploit granting the attacker the
proxy's execution context): a Performance-Log-Users, no-network, non-interactive,
job-capped account whose only reachable IPC is a pipe it can WRITE toasts into — and the
reader of that pipe treats every byte as hostile and can, at absolute worst, be steered
into mis-classifying a toast between two routes that are both safe by construction (window
= today's behaviour; bridge = a forward whose content the classifier + title match still
gate). No SYSTEM handle, no agent handle, no dom0 reach beyond what any guest process
already has. The genuine residual — PLU membership lets the proxy enable/consume OTHER
machine-wide ETW providers, an intra-guest information-disclosure surface — is named in
§10.17.2, and is strictly less than what the rejected SYSTEM-consumer alternative concedes.

### 10.10.2 What moves, what stays (function-level manifest)

| unit (shipped ref) | destination | change in the move |
|---|---|---|
| `g_etwProviders` table + `EtwNameToGuid` (:871-915) | proxy | none (extend only from `--dump-etw` evidence, per :866-870) |
| `EtwSessionStart/Stop`, `EtwEnableProviders`, `EtwOpen` (:938-1003) | proxy | session name stays `QubesToastBridgeEtw` (:861); stale-reap semantics unchanged |
| `EtwDecode` + `EtwHarvest` (:1025-1138) | proxy | payload property is LOCATED but its bytes forwarded RAW (§10.11.3); `TdhFormatProperty` rendering becomes `--dump-etw`-only |
| `EtwBridgeEventCb` (:1145-1165) | proxy (as the pipe-push callback) | RAII lock guard + per-entry byte cap (§10.12.1-2); pushes a frame instead of a ring entry |
| `EtwTierThread` retry ladder (:1167-1221) | proxy main loop | `ERROR_ACCESS_DENIED` stays a permanent park (:1175-1183) — now it means "provisioning wrong", a loud finding, not an expected state |
| ring + `EtwTierLookup` (:855-859, :1265-1291) | bridge (fed by the pipe reader) | ambiguity degrade (§10.12.3); state values gain `ipc-down` |
| `EtwTierStart/Stop` (:1224-1251) | bridge (start/stop the pipe READER thread instead) | same shape: spawn-and-return, bounded 3 s join on exit (:1246) |
| `DumpEtwMain` (:1336-1379) | unchanged, any token | stays the rig's payload-availability instrument; exit codes 5/6/7 (:49-52) unchanged |
| `WpnCorrelate` tier D (:733-788) | bridge, **moved off the poll thread** (§10.13.2) | logic byte-for-byte; only the calling thread changes |
| `ShadowClassify` ladder (:1404-1469) | bridge worker thread | CLASSIFY contract unchanged except the new `etw=` values (§10.16.4) |

MEASURE-ONLY is preserved verbatim: in `--bridge` the ladder still feeds ONLY
`ShadowClassify`'s logging; the A0 skip/forward routing (:1973-2036) reads nothing from it,
and no acquisition failure can feed `failStreak`/FATAL (:2051-2055) — the worker and reader
threads swallow their own exceptions exactly as `ShadowClassify` does today (:1465-1468).

## 10.11 IPC: the one-way, locked, proxy-served pipe

### 10.11.1 Contract (direction, roles, trust)

- **Server = the proxy.** It creates the pipe with `PIPE_ACCESS_OUTBOUND` — the server end
  can only write, a client handle can only read. One-way-ness is enforced by HANDLE RIGHTS
  at the object layer, not by protocol politeness: a fully compromised bridge cannot write
  one byte toward the proxy, and a fully compromised proxy cannot read one byte from the
  bridge over this channel.
- **No control channel, no handshake, no requests.** The proxy accepts NOTHING from the
  pipe after `ConnectNamedPipe`: it pushes records as events arrive and otherwise ignores
  the client. Its only inputs, ever, are its command line (from the SYSTEM agent at
  launch, §10.14.5) and process termination (agent job teardown). A compromised
  user-session bridge therefore cannot drive, reconfigure, or query the privileged proxy —
  the worst it can do is read what the proxy was already pushing, which is data the same
  session's listener/DB already expose to it.
- **Locked**: explicit security descriptor at `CreateNamedPipe`,
  `D:P(A;;GR;;;<interactive-user-SID>)` — connect/read for the bridge's user ONLY (the
  agent passes that SID on the proxy's command line; the agent already resolves the
  interactive user to launch the bridge via Task Scheduler `/ru user /it`, notifhost.cpp:16).
  No SYSTEM ACE (the agent never connects), no Everyone, protected DACL (no inheritance).
  Contrast: the shipped relay pipe uses the default token DACL (:1677-1679) — acceptable
  there (both ends same user); NOT acceptable here (ends are different principals).
- **Squat-resistant enough, fail-open regardless**: `FILE_FLAG_FIRST_PIPE_INSTANCE` +
  `nMaxInstances=1`, and the name carries a per-boot random 128-bit suffix generated by the
  agent (§10.14.5) — `\\.\pipe\qubes-etw-toast-<32hex>`. The proxy creates the instance
  BEFORE the agent publishes the name to the bridge, so a name-guessing squatter loses the
  race window; if a squat nonetheless wins, the proxy fails `CreateNamedPipe` loudly
  (`PROXY SQUAT` line, §10.16.4), parks, and the bridge's tier degrades to the DB rung —
  fail-open, and the squatter has gained only the ability to feed the bridge bytes it
  already treats as hostile (same trust class as §10.8.1).
- Reconnect: one client at a time; on client disconnect the proxy loops back to
  `ConnectNamedPipe` (bridge restarts are routine — the supervisor relaunches it). Records
  captured while no client is connected are buffered in the proxy's own small ring (64
  entries / capped bytes, same policy as §10.12.2) and flushed on connect, so a bridge
  relaunch does not lose the toast that raced it.

### 10.11.2 Frame format (message-mode, one record per message)

```
offset size  field
0      4     magic      'E','T','P','1' (0x31505445 LE)
4      4     flags      0 (reserved; receiver drops nonzero)
8      8     eventFt    EVENT_RECORD.TimeStamp (FILETIME domain, as :1030)
16     8     proxyTick  GetTickCount64 at capture (proxy clock; diagnostic only)
24     2     aumidBytes    UTF-16LE bytes, <= 1024   (cap mirrors EtwHarvest's 512-wchar test :1126)
26     2     notifIdBytes  UTF-16LE bytes, <= 128
28     4     payloadBytes  RAW bytes,     <= 65536   (§10.12.2)
32     ...   aumid || notifId || payload   (no padding, no terminators)
```

Max message 32+1024+128+65536 < 68 KiB; pipe buffers sized 128 KiB. Exactly the fields the
constraint names — {AUMID, raw payload bytes, notif-id, timestamp} — and nothing else: no
strings the bridge must parse for structure, no versioned sub-records. A future format
change is a new magic, not a negotiation (there is no channel to negotiate on).

### 10.11.3 Minimal in-proxy parsing: TDH locates, never interprets

The proxy uses TDH only to find PROPERTY BOUNDARIES and names: `TdhGetEventInformation`
for the property table, `TdhGetPropertySize`/`TdhGetProperty` for each candidate's raw
extent (the shipped plumbing :1058-1068). Identification is the shipped name heuristic
(:1113-1138) plus a bounded raw sniff for the payload (BOM-tolerant `memcmp` for `<toast`
in UTF-16LE/UTF-8 over the first 16 bytes — the raw-bytes equivalent of :1121). The
payload property's bytes are then forwarded RAW — `TdhFormatProperty`'s rendering pass
(:1072-1083), the heaviest interpretation step, is dropped from the proxy hot path and
survives only inside `--dump-etw` where a human reads the output. **The XML parse happens
exactly once, in the bridge, in the defensive classifier** — never in the privileged
process. (Yes, `TdhGetEventInformation` itself parses untrusted metadata; that is
precisely WHY it is in the proxy and not in the bridge or agent.)

### 10.11.4 Bridge side: the reader thread and the untrusted-input rules

A dedicated bridge thread (started where `EtwTierStart` is called today, :1835): open the
pipe name read from the HKLM plumbing value (§10.14.5) with `GENERIC_READ`, overlapped
reads with the `PipeXfer` shape (:1559-1582), retry-with-backoff while absent (absent pipe
= tier `down`, DB rung serves — the shipped degrade). Per message, BEFORE anything else:
magic/flags check, all three lengths within caps, sum equals message length; any violation
drops the record, bumps a counter, and after 16 violations in a row abandons the
connection (`ipc-poison` log, tier down — a proxy speaking garbage is treated as dead).
Validated records are converted (aumid/notifId via bounded UTF-16 copy; payload KEPT as
bytes) and pushed into the ring under the RAII guard (§10.12.1). `EtwTierLookup` then
works unchanged except: it decodes ring payload bytes through `WpnPayloadToW` (:655-667)
at match time (the same decoder tier D trusts for correlation), and applies the ambiguity
degrade (§10.12.3). The `state` value seen by CLASSIFY gains `ipc-down` (pipe absent /
poisoned / disconnected) alongside the shipped `down/dead` (:1259-1261) so the rig can
tell "proxy not running" from "proxy running, provider silent".

## 10.12 Review must-fixes carried by the move (each with a seen-to-fail hook)

These are DEFECTS in the shipped in-bridge tier; the refactor does not copy them.

1. **RAII lock guard — the lock leak at :1155-1164.** `EtwBridgeEventCb` does
   `EnterCriticalSection` (:1155) then `ring.push_back` (:1156) — three `std::wstring`
   copies + deque growth, any of which can throw `bad_alloc` — and the `catch (...)`
   (:1164) does NOT leave the critical section. The consumer thread keeps running (it
   recursively re-enters fine), but the poll thread's next `EtwTierLookup` blocks forever
   at `EnterCriticalSection` (:1275) → the heartbeat (:1889-1899) stops → the 15 s
   supervisor kills a live bridge — **exactly the AgentGone termination shape** (:107-126).
   Fix: a scoped guard (`struct CsGuard { CRITICAL_SECTION* c; CsGuard(CRITICAL_SECTION*);
   ~CsGuard(); }`) used at EVERY Enter/Leave pair the acquisition code owns (ring push,
   `EtwTierLookup`, the proxy's own ring). Hook: `P3AQ_DEFECT_LOCKLEAK` (test builds only)
   reinstates the bare Enter + a forced throw between Enter and Leave; the harness's
   heartbeat-cadence detector (§10.2) must then FAIL.
2. **Per-entry ring byte cap — missing at :1156-1157.** The ring is capped at 64 ENTRIES
   (:1157) but an entry's payload wstring is unbounded up to `EtwDecode`'s 4 MB per-property
   format ceiling (:1075): 64 × 4 MB = 256 MB of hostile-controlled heap in the bridge.
   Fix, both ends: the proxy enforces `payloadBytes <= 65536` at frame build (a bigger
   "toast" is not a shell toast — real payloads are a few KB; toastclassify's own
   adversarial cap is 256 K wchars :85) and DISCARDS the record (never truncates: a
   truncated doc would only classify row-0 window anyway, and a discard degrades cleanly to
   tier D); the bridge re-enforces the same caps on receive (§10.11.4 — pipe input is
   untrusted). Hook: `P3AQ_DEFECT_NOBYTECAP` removes both checks; the harness's
   working-set assertion on the bridge process during an oversized-event fixture must FAIL.
3. **Ambiguity degrade in `EtwTierLookup` — missing at :1278-1287.** The shipped scan
   walks newest-first and takes the FIRST title match (`break` :1286). Two same-AUMID
   candidates in the ±60 s window whose payloads differ but share a first `<text>` (burst
   of same-title toasts with different actions) silently classify the WRONG toast's XML —
   the exact ambiguity class tier D refuses (`match.size() > 1` ⇒ `"ambiguous"` :783).
   Fix: collect ALL matches; >1 match with byte-identical payloads = a duplicate event,
   safe hit; **>1 match with DIFFERING payloads ⇒ no hit** — return `"ambiguous"`, which
   the ladder treats as a non-hit (degrade to tier D, whose own ambiguity rule then almost
   always lands `window`). Hook: `P3AQ_DEFECT_AMBIG` reinstates first-match; the P3d
   two-same-AUMID-back-to-back fixture (§6 Q4) must then FAIL its equal-or-window assert.
4. **IPC one-way/DACL proofs.** Two proxy-side hooks, same seen-to-fail rule:
   `P3AQ_DEFECT_DUPLEXPIPE` creates the pipe `PIPE_ACCESS_DUPLEX` — the rig's one-way
   assert (a write attempt from the bridge account must fail `ERROR_ACCESS_DENIED`) must
   then FAIL; `P3AQ_DEFECT_OPENDACL` creates it with a NULL DACL — the rig's
   foreign-account connect probe (§10.16.3e) must then FAIL.
5. The two shipped hooks stand: `P3AQ_DEFECT_HOTWAIT` and `P3AQ_DEFECT_ROUTE` (§10.2) —
   HOTWAIT now means "perform the acquisition wait on the poll thread", which after
   §10.13.2 covers the DB rung too.

## 10.13 Push over poll (owner directive), with bounded backstops

Retire polling where a RELIABLE push source exists; keep a low-frequency floor wherever
the push source is unproven; introduce no new poll.

1. **Toast detection: `UserNotificationListener.NotificationChanged` replaces the 2 s
   cadence.** Today the loop unconditionally sleeps 2 s (:2071) and re-lists. Change: at
   startup, subscribe `listener.NotificationChanged` (WinRT event; the handler does ONE
   thing — `SetEvent(g_wakeEvt)`; no listener calls, no locks, nothing that can throw past
   it); the loop tail becomes `WaitForSingleObject(g_wakeEvt, 30000)`. The loop BODY is
   unchanged — it is already a reconcile (list, diff against `seen`, act), so a missed,
   dropped, or never-firing event costs at most the 30 s floor of latency and can never
   lose a toast. The floor poll is the mandated backstop: `NotificationChanged` has a
   known reliability question mark for unpackaged Win32 listeners on some builds — the rig
   measures it (§10.16.3f: wake-to-FIRED latency; all-floor-paced = event dead on that
   build, a finding, not a failure). Dismiss-echo, stop-file, consent, and reconnect
   checks ride the same wakes/floor as today's pass structure. NOTE the coupling: a 30 s
   floor is only legal AFTER the supervisor deadline moves off 15 s (§10.15) — landing
   this before §10.15 would have the supervisor killing a healthy bridge every wait.
2. **DB fallback off the poll thread + WAL watch instead of blind sleeps.** New
   **acquisition worker thread** (the §10.3.2 design, now mandatory): `ShadowClassify`'s
   poll-thread part shrinks to capturing `{id, aumid, creationFt, title}` (WinRT reads
   already done there today :1961-1981) and enqueueing; the worker runs the ladder — ring
   lookup, then `WpnCorrelate` — and emits the CLASSIFY line (the `logged`-set
   exactly-once contract :1408-1410 moves with it). This removes the last acquisition
   latency from the hot loop: the shipped worst case (~650-1050 ms per fresh toast, on the
   poll thread, admitted at :1970-1971 and :733-737) becomes worker-thread time, so a
   burst can no longer sum toward the supervisor deadline — the AgentGone shape is closed
   by construction, not by budget arithmetic. Inside the worker, `WpnCorrelate`'s blind
   `Sleep(150)` between attempts (:753) is replaced by `ReadDirectoryChangesW` on
   `%LocalAppData%\Microsoft\Windows\Notifications` filtered to `wpndatabase.db-wal`
   writes (the row it is waiting for arrives via a WAL append): wait up to the same total
   budget on the change event, re-query on signal. One final timed re-query stays as the
   in-budget backstop (directory-watch buffers can overflow and drop notifications). Total
   tier-D budget unchanged (~1 s ceiling), so §2.3's deadline math is untouched; typical
   case gets FASTER (query fires when the row lands, not on a fixed grid).
3. **No acquisition failure feeds `failStreak`/FATAL** — restated as a hard rule for the
   new threads: reader, worker, and their queues swallow and log their own failures
   (`ShadowClassify`'s pattern :1465-1468); `failStreak` (:2051-2055) remains reserved for
   listener-poll failures exactly as shipped.

## 10.14 Provisioning the proxy (agent-side + installer — DESIGN ONLY, no agent code in this change)

The gui-agent work described here is a LATER, separate change (the agent tree currently
carries unrelated uncommitted work); this section is its specification. Supervision
precedent: the agent already launches and supervises `--bridge` per user session
(DESIGN-p3-classifier-impl.md:22 → main.c:2249-2423) via Task Scheduler `/ru user /it`
(notifhost.cpp:16). The proxy is DELIBERATELY NOT launched that way — a scheduled task in
the interactive session would hand it the wrong (interactive, unrestricted) context.

1. **Account**: dedicated local account `qubes-etwproxy`, created by the installer
   (firstboot script, the `guest/firstboot-setup.ps1` family) or lazily by the agent on
   first arm. `NetUserAdd` level 1 (so it joins NO groups implicitly), flags
   `UF_DONT_EXPIRE_PASSWD`; `NetLocalGroupAddMembers` into **BUILTIN\Performance Log Users
   only** — which also carries the "Log on as a batch job" right the launch needs. Hidden
   from the logon UI (`SpecialAccounts\UserList` = 0, cosmetic). Password: 32 random bytes
   from `BCryptGenRandom`, set via `NetUserSetInfo(1003)` by the SYSTEM agent AT EVERY
   BOOT and held only in agent memory for the `LogonUserW` call — never persisted anywhere
   (no LSA secret, no file; if the agent restarts it just resets the password again).
2. **Logon-right lockdown** (LsaAddAccountRights on the account SID): grant
   `SeBatchLogonRight` (redundant with PLU but explicit); deny
   `SeDenyInteractiveLogonRight`, `SeDenyRemoteInteractiveLogonRight`,
   `SeDenyNetworkLogonRight`.
3. **Token**: `LogonUserW(LOGON32_LOGON_BATCH)` → primary token. Ship posture A (default):
   use that token as-is — PLU membership is the documented sufficient grant, and the rig
   measures whether it actually suffices (§10.16.3b). Posture B (tighten after A is proven,
   or fall back if A carries more than expected): `CreateRestrictedToken` from it, deleting
   every privilege except `SeSystemProfilePrivilege` and disabling all groups except the
   PLU SID + the account SID + Everyone/AuthenticatedUsers (needed for object opens) —
   whether the trace APIs still succeed under B is itself a §10.16 measurement, never an
   assumption. Either way the token never gains a privilege the interactive user session
   or the bridge could reach: the split GRANTS nothing to the user session.
4. **Sandbox at launch** (SYSTEM agent, which holds SeAssignPrimaryToken/SeIncreaseQuota):
   `CreateProcessAsUser(token, "notifhost.exe --etw-proxy --pipe <name> --client-sid <S>",
   CREATE_SUSPENDED | CREATE_NO_WINDOW)`, assign to a job object BEFORE resume:
   `JOB_OBJECT_LIMIT_ACTIVE_PROCESS=1`, `KILL_ON_JOB_CLOSE`, `ProcessMemoryLimit` 64 MB
   (a decode bomb dies, the guest does not), `JOB_OBJECT_UILIMIT_*` all set (no desktop,
   clipboard, atoms, displaysettings, exitwindows). No `LoadUserProfile` (the proxy needs
   no HKCU); it runs in session 0 — real-time ETW sessions and the pipe namespace are
   machine-global, so session placement is irrelevant to function and favorable to
   isolation. Network: the installer adds ONE Windows Firewall rule — outbound, action
   Block, `-LocalUser` scoped to the `qubes-etwproxy` SID (PowerShell
   `New-NetFirewallRule`; netsh cannot express per-user) — which together with 2's
   deny-network-logon yields the "no-network" property §10.10.1 claims. The proxy's log
   is `%ProgramData%\qubes-etw-proxy\proxy.log` (BLog pattern :248-269 with its own path),
   directory pre-created by the installer with a DACL granting the proxy account write and
   Users read — NOT the bridge's world-writable-ish `qubes-toast-bridge` dir.
5. **Pipe discovery** (how the bridge finds the proxy without a control channel): per boot
   the agent generates a 128-bit random hex suffix; pipe name
   `\\.\pipe\qubes-etw-toast-<32hex>`. Order: launch proxy (name on its command line) →
   proxy creates the pipe instance (`FIRST_PIPE_INSTANCE`) → agent writes the full name to
   `HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent\NotifyEtwPipe` (REG_SZ) — the
   same key the bridge already reads read-only (:324), admin-writable only, so the
   user session can READ the name but never FORGE it. The bridge treats an absent value or
   unconnectable pipe as tier-down (DB rung). This value is agent-written plumbing, not a
   user knob — no new user-facing configuration, `service.notify-bridge` remains the single
   gate, and the agent launches the proxy only when that gate is on (same condition that
   launches the bridge, main.c:8511-8545 read).
6. **Supervision — event-driven, no heartbeat for the proxy**: the agent keeps the job +
   process handles and `RegisterWaitForSingleObject`s the process handle; the callback
   relaunches with exponential backoff (5 s → 5 min, the bridge reconnect table's shape
   :1918). No proxy heartbeat file AT ALL: a hung-but-alive proxy is indistinguishable
   from a silent provider and costs nothing — the bridge's tier degrades to the DB rung
   (fail-open), which is not an urgent condition. Agent shutdown: `TerminateJobObject`
   (also covers agent crash via KILL_ON_JOB_CLOSE), then the standard stale-session reap
   at next start (`EtwSessionStop` first, :938-949) clears the kernel-side trace session
   the killed proxy leaked.
7. **Installer implications**: notifhost.exe is ALREADY explicitly packaged (the 4.3.18
   helpers-must-be-explicitly-packaged rule — a mode adds no packaging work); NEW
   installer items: account creation + group membership + logon-right denies + firewall
   rule + log-dir DACL, and their UNINSTALL mirrors (delete account, rule, dir). All are
   idempotent one-shot PowerShell in the firstboot family; no MSI custom-action work
   beyond invoking it.

## 10.15 Supervision of the BRIDGE: from heartbeat staleness to exit-wait (agent-side — DESIGN ONLY)

Shipped shape (main.c:2249-2423 per :22, described from the notifhost side at :107-126):
the agent POLLS a heartbeat file's mtime; >15 s stale ⇒ kill + relaunch via schtasks. That
15 s deadline is what turned a slow loop pass into a termination (the Toolhelp bisect
:112-119), and it caps every legal in-pass latency. Worse, it is ALREADY latently violated
by shipped bounded waits: one `ConnUp` attempt can legitimately block a pass ~55 s
(qrexec-client-vm wait 10 s :1716 + relay-connect wait 15 s :1726 + handshake read 30 s
:1736), and `ForwardText` holds it 15+15 s (:1779-1781) — today's bridge survives these
only when they don't happen. The redesign, coupled to §10.13's 30 s floor:

1. **DEAD detection goes event-driven.** The bridge writes `pid=<n>` into its heartbeat
   file once at startup (file exists :1889-1899; content today is a tick, gains the pid).
   The agent reads the pid after task launch, `OpenProcess(SYNCHRONIZE |
   PROCESS_QUERY_LIMITED_INFORMATION)` (SYSTEM opening a user process — allowed; the
   DENIED direction was user→SYSTEM, :108-110), verifies image identity
   (`QueryFullProcessImageName` — a recycled pid must not be supervised), and
   `RegisterWaitForSingleObject` on the handle: the relaunch callback fires the moment the
   process exits, replacing staleness-poll-as-death-detector entirely. Zero polling for
   the DEAD case, and relaunch latency drops from ≤75 s (today's task cadence) to
   milliseconds-plus-backoff.
2. **HUNG detection: keep the heartbeat, demote it to a wide backstop.** The hang class
   does not vanish: `GetNotificationsAsync(...).get()` (:1939) is an unbounded external
   call, and future lock bugs are exactly what §10.12.1's hook guards. So the heartbeat
   file WRITE stays (cheap, every pass), but the agent's staleness check becomes the
   minimal backstop the constraint demands: checked every 60 s (a REDUCTION of the
   existing supervision poll — today's is tighter — not a new poll), kill+relaunch
   threshold **180 s**. Why 180: it must exceed the worst LEGAL pass = 30 s wake floor
   (§10.13.1) + ~55 s ConnUp + 30 s ForwardText + margin. With acquisition off the poll
   thread (§10.13.2) nothing else in a pass is unbounded-by-design.
3. **What is NOT done**: the AgentGone net is not removed (owner constraint) — the bridge
   keeps its own agent-liveness probe (:127-144) and stop-file poll (:1887) untouched;
   the supervisor keeps the ability to kill a wedged bridge — only its trigger gets slow
   enough to never fire on a healthy one. Landing order is fixed: §10.15 (agent) FIRST,
   then §10.13.1's 30 s floor — the reverse order kills healthy bridges every 30 s wait.

## 10.16 Rig-run spec v2 — the proxy gate (supersedes §10.7 where they conflict; Opus executes)

Per the acceptance division, Fable hands this off ready-to-run; execution is Opus on the
live rig. Matrix: win10-base (22H2), win11-base (24H2), +25H2 when provisioned. Build
under test: the release package carrying `--etw-proxy` + the §10.12 fixes; provision via
the prime-run path, no binary swaps.

1. **Provisioning under test is the SHIP path**: create the account/group/rights/firewall
   per §10.14.1-4 with the same script the installer will invoke, then have the agent (or,
   until agent code exists, a SYSTEM-qrexec stand-in performing the exact §10.14.4 launch
   sequence) start `--etw-proxy`. The stand-in must replicate token+job+session-0 —
   results from a proxy launched any other way are void.
2. **Fixture sequence** (per §10.7.2): `guest/fire-demo-toast.ps1` informational,
   `-RealChoice`, `-Persistent`, 4-toast burst, plus the §10.12.3 ambiguity fixture (two
   same-AUMID same-title toasts, differing actions, <10 s apart); 3 interleaved
   repetitions; one cold reboot between run 2 and 3 (boot path is acceptance).
3. **Measurements** (each a named number in FINDINGS.md):
   a. **Payload availability**: proxy `PROXY PUSH` count and bridge `ETW REC`/`CLASSIFY
      etw=hit` per FIRED line; verdict agreement with the same toast's wpndb row
      (`--dump-wpndb`, §10.6.1 row-level rule).
   b. **Perf-Log-Users sufficiency — THE privilege datum**: the proxy logs every
      `StartTraceW` and `EnableTraceEx2` return code verbatim (§10.16.4).
      `ERROR_SUCCESS` across all ⇒ PLU suffices (posture A confirmed; then repeat once
      under posture B's restricted token). Any `ERROR_ACCESS_DENIED` ⇒ a FINDING: PLU is
      not sufficient on that build — record which call denied, and STOP there; the cures
      (more groups, more privileges) are owner decisions, not rig improvisation.
   c. **IPC delivery + end-to-end latency**: per FIRED toast, FIRED→ring-insert (bridge
      tick at push) and FIRED→`CLASSIFY` emission, vs the DB rung's `row_latency`
      distribution from `CLASSIFY src=db` lines in the same runs — the direct test of
      "ETW removes the WAL-retry ceiling" (§10.1.2) now measured across the pipe, not
      in-process.
   d. **Defect proofs**: one run per `P3AQ_DEFECT_*` build (§10.12 + §10.2) — every
      corresponding detector must FAIL or it is recorded as unproven decoration.
   e. **Lockdown asserts**: from the interactive user, a `CreateFileW(pipe,
      GENERIC_WRITE)` must fail (one-way); from a second test account, `GENERIC_READ`
      must fail (DACL); `whoami /groups /priv` of the proxy (via its own startup log)
      shows PLU-only; an outbound TCP attempt from the proxy account must be blocked.
   f. **Push-source reliability** (§10.13.1): fraction of toasts detected via
      `NotificationChanged` wake vs the 30 s floor; all-floor ⇒ the event is dead on that
      build (finding: the floor IS the detector there).
4. **Verdicts** (unchanged shape from §10.7.4, proxy-adjusted):
   - **PICK ETW PRIMARY**: 3a agrees at row level on every build, 3b clean under posture
     A, 3c beats the DB distribution ⇒ tier E primary through the proxy; tier D confirmed
     fallback (retirement still a separate later decision, §10.6).
   - **FALL TO DB**: 3b denied, or payloads missing/truncated/shape-drifting on any build
     ⇒ the proxy ships dormant-or-absent, tier D stays primary, the bridge behaves as
     today (`etw=down/ipc-down`, all served by the DB rung) — nothing regresses.
   - **KILL**: no provider yields the payload even in the controlled elevated diagnostic
     AND `--dump-wpndb` exits 4 on some build ⇒ per-toast classification unbuildable
     there; STOP and report (A0 per-app remains that build's ceiling).
   **SYSTEM `--dump-etw` is permitted ONLY as the step-0 controlled-rig shortcut** — run
   it (SYSTEM qrexec path) BEFORE building the account plumbing to answer "does any
   provider carry {AUMID, payload} at all" cheaply (:1336-1379 is already that
   instrument; exit 5 semantics :49-52). It is never the ship posture, never left
   scheduled, and a payload seen ONLY under SYSTEM must be re-proven under the proxy
   token before counting toward 3a.

### 10.16.4 New log/dump line formats (proxy.log unless marked)

```
PROXY ARMED session=QubesToastBridgeEtw pipe=qubes-etw-toast-<32hex> client_sid=<S-1-5-21-...>
PROXY RC api=StartTrace|EnableTraceEx2 provider=<name|-> rc=<win32>          every control call, verbatim
PROXY SQUAT rc=<win32>                                                       pipe name taken - parked, tier down
PROXY PUSH aumid_chars=<n> payload_bytes=<n> notif_id=<s|-> lat_ms=<n>       one frame written (event->write)
PROXY DROP reason=oversize|no-payload|decode-fail bytes=<n>                  record discarded (§10.12.2)
PROXY CLIENT connect|disconnect                                              bridge attach/detach
ETW IPC state=up|down|poison pipe=<name> (bridge.log)                        reader-thread transitions
CLASSIFY ... etw=hit|miss|text-mismatch|ambiguous|down|ipc-down|off ...      (bridge.log) two NEW values in the
                                                                             shipped :1462 format; field order,
                                                                             prefix, and all other fields unchanged
                                                                             so a0-lib.sh detectors keep working
```

## 10.17 Open risks (v2 — supersedes §10.8 items 1 and 3)

1. **Same-user event spoofing is unchanged in kind, relocated in path**: forged provider
   events now traverse proxy→pipe→bridge instead of being read in-process; every mitigation
   (title match, classifier fail-open, two-safe-routes) applies at the bridge exactly as in
   §10.8.1. The pipe adds no new forgery power — the bridge's DACL'd read end accepts
   frames only from the proxy, and squatting is covered in §10.11.1.
2. **PLU is a real grant** (replaces §10.8.3): the proxy account can start/consume
   real-time sessions for ARBITRARY providers — an intra-guest information-disclosure
   surface if the proxy is subverted (it could observe other processes' ETW traffic).
   Bounded by: no network egress, no interactive access, job caps, and the qube's own
   shared-fate model; strictly narrower than the rejected SYSTEM-consumer alternative.
   Named for the owner, accepted by this design.
3. **Batch logon of a hidden local account** may trip guest hardening baselines (logon
   auditing, account-lockout tooling) on managed images — same deferral class as
   autologon on managed images (task #31); the testbed images are not managed.
4. **`NotificationChanged` reliability** is unproven for an unpackaged listener on the
   matrix builds — measured at §10.16.3f; the 30 s floor bounds the damage to latency.
5. **Password-reset-per-boot** races a concurrently-running stale proxy (agent restarts,
   resets the password, old proxy's token stays valid — tokens survive password changes).
   Harmless (the old proxy is killed via job teardown first in the §10.14.6 order), noted
   so the order is kept.
6. Flush-timer floor and TraceLogging GUID-derivation risks carry over unchanged
   (§10.8.2, §10.8.4); session leakage (§10.8.5) is now reaped by the AGENT's next proxy
   launch rather than the bridge's (§10.14.6).

## 10.18 As-implemented record (2026-09-05) — what notifhost.cpp now carries, and its deltas vs §10.10-10.16

The proxy split is **implemented** in `tools/notifhost/notifhost.cpp` (working tree, this
change): mode `--etw-proxy [--client-sid <SID>]` hosts the entire ETW/TDH **consume**
surface as a PURE CONSUMER under the two-context split (`OpenTraceW` on the agent-started
session + `ProcessTrace` on its own thread, and a new minimal harvest `PxHarvest` —
TdhGetEventInformation + TdhGetPropertySize/
TdhGetProperty raw-extent only, no `TdhFormatProperty`, payload forwarded RAW after a
bounded `"<toast"` byte sniff `PxLooksLikeToastXml`). Session CONTROL — `StartTraceW` of
the fixed-name/fixed-GUID session, `EnableTraceEx2` of the provider list, the
`EventAccessControl` per-session DACL grant, and every stop/reap — lives in the SYSTEM
agent (`agent/gui-agent/etwproxy.c`, §10.19); the proxy never calls
StartTrace/EnableTrace/ControlTrace and never stops the session. `--bridge` runs **no ETW
code** —
`EtwIpcThread` is a read-only pipe client filling the ring `EtwTierLookup` scans, the
shadow worker (`ShadowWorkerThread` + `ShadowClassifyWork`) runs the ladder off the poll
thread, `WalWatchThread` (ReadDirectoryChangesW on the Notifications directory) paces
`WpnCorrelate`'s retries, and `UserNotificationListener.NotificationChanged` gates the
center listing with a 30 s floor (2 s wake retained for the supervisor heartbeat). All
§10.12 must-fixes are in: `CsGuard` RAII on every new lock, 64 KB per-entry payload cap
enforced at BOTH ends, `EtwTierLookup` ambiguity degrade (>1 differing same-AUMID
text-matches ⇒ `etw=ambiguous` ⇒ verdict `window` with NO DB consult; byte-identical
duplicates don't count), and `P3AQ_DEFECT_HOTWAIT` / `P3AQ_DEFECT_ROUTE` compile-time
hooks (mutually exclusive via `#error`). Proxy exit codes: 0 clean, 5 consume denied
(`OpenTrace`/`ProcessTrace` ERROR_ACCESS_DENIED — the per-session DACL grant insufficient
on this build; `ProcessTrace`'s return is read back via the consumer thread's exit code so
a denial can never masquerade as a clean exit 0; the agent parks on this TRUE finding),
7 open/thread/event failure, 8 pipe creation failure, 9 refused (never-SYSTEM/admin guard,
OR a DRIFTED token carrying Performance Log Users / SeSystemProfilePrivilege — the census
is refuse-on-drift, never warn-and-proceed, since group SIDs cannot be shed in-process);
per-provider `EnableTraceEx2` RCs now log agent-side (`PROXY RC` lines, §10.19).

**Deliberate implementation deltas vs the §10.11 design prose** (code is what ships; each
delta is either tighter or pending agent-side plumbing that this change must not touch):

| §10.10-10.16 says | code does | why |
|---|---|---|
| §10.11.2 message-mode pipe, magic `ETP1`, u16 length fields, flags/proxyTick | **byte-mode** stream, magic `QTE1`, 24-byte header `{u32 magic, u32 aumidBytes, u32 payloadBytes, u32 notifBytes, u64 eventFt}`, length-prefixed | message-READMODE on the client requires `SetNamedPipeHandleState`, which needs `FILE_WRITE_ATTRIBUTES` in the DACL — a wider grant than read-only. Byte-mode keeps the client at pure `GENERIC_READ`; a desynced stream is handled by drop-connection-and-reconnect (stricter than the 16-violation counter: ANY malformed frame kills the connection) |
| §10.11.1 per-boot random pipe name `qubes-etw-toast-<32hex>`, published via HKLM by the agent | **fixed name** `\\.\pipe\qubes-toast-etw` | the random-suffix scheme needs the agent-side HKLM plumbing (§10.14.5), which is design-only; a fixed name lets proxy+bridge pair with zero configuration today. Squat outcome identical either way: proxy exits 8 loudly, bridge tier stays down, DB rung serves (fail-open). Adopt the random name in the same change that lands §10.14 |
| §10.11.4 ring stores payload BYTES, decode at match time | ring stores the decoded wstring (`EtwRawPayloadToW`: BOM'd UTF-16/UTF-8 + BOM-less UTF-16LE heuristic, doubt ⇒ UTF-8 ⇒ fail-open miss) | decode-once vs decode-per-lookup; same defensive decoders, same fail-open outcome |
| §10.11.1 no-SYSTEM DACL | matches: `D:P(A;;FR;;;<client-sid>)`; **without `--client-sid` the DACL is `D:P` (empty = deny everyone)** — locked shut, tier down, loud WARN | agent never connects; nothing else should |
| §10.11.4 `ipc-down` state value | reuses the shipped `down` state (CLASSIFY `etw=down`); "proxy absent" vs "provider silent" is distinguished by the `ETW IPC` bridge.log lines + the proxy's own log instead | avoids widening the CLASSIFY value domain twice in one day; revisit with §10.16 |
| §10.11.2 notifIdBytes ≤ 128 | ≤ 256 | matches the shipped `EtwHarvest` notif-id bound (64 wchars) with slack; still trivially small |

Unchanged from the design: outbound-only server pipe (`PIPE_ACCESS_OUTBOUND`,
`FILE_FLAG_FIRST_PIPE_INSTANCE`, nMaxInstances=1), no control channel/no stop file on the
proxy, proxy-side 64-entry buffered queue flushed on connect (a bridge relaunch does not
lose the toast that raced it; overflow drops oldest), MEASURE-ONLY routing invariance, and
every fail-open rule in §0/§5/§10.2. The bridge treats pipe frames as hostile input
despite the privileged sender: caps checked before allocation, undecodable payloads
dropped, connection abandoned on any framing violation.

§10.14 (account provisioning, launch, supervision) and §10.15 remain DESIGN ONLY *in the
notifhost change* — see §10.19 for the separate agent-side change that has since
implemented §10.14. The §10.16 rig-run spec applies to this code as written; §10.16's grading should
read the proxy log names as implemented here: `etw-proxy.log` with `ETWPROXY start|LIVE|
CLIENT connected|TOAST|FAIL|WARN|stop` and `ETW provider <name> guid=<guid> enable=<rc>`
lines, and bridge.log's `ETW IPC connected server_pid=|disconnected|proxy pipe absent`,
`ETW REC #<n>`, `WALWATCH armed|unavailable`, `PUSH NotificationChanged armed|unavailable`,
`SHADOWQ overflow`, plus the unchanged `CLASSIFY` line whose `etw=` field gains
`ambiguous` and `enqueue-threw`.

## 10.19 As-implemented record (2026-09-05, separate change) — §10.14 agent-side launch/supervision

The §10.14 agent work is now IMPLEMENTED, in a change deliberately segregable from both
the notifhost proxy change (§10.18) and main.c's uncommitted slice-map-hold edit
(CropReadyForMap/AddWindow are untouched):

- **`agent/gui-agent/etwproxy.c` + `etwproxy.h`** (new translation unit, added to
  `agent/vs2022/gui-agent/gui-agent.vcxproj`): the SYSTEM agent's entire involvement.
  main.c gains exactly three one-line hooks + one include: `EtwProxyInit(g_NotifBridge)`
  after the NotifyBridge gate read in `Init()` (same gate, §10.14.5 — no new services,
  no new knobs), `EtwProxyPoke()` at the existing supervise call site in the main loop,
  `EtwProxyShutdown()` next to `NotifBridgeShutdown()`.
- **Two-context split — the agent is the session CONTROLLER, the proxy a PURE CONSUMER**
  (2026-09-05 architecture decision, supersedes the §10.14 prose where they differ): per
  launch the agent, as SYSTEM, reaps any stale session by name, `StartTraceW`s the
  real-time session `QubesToastBridgeEtw` with its FIXED private GUID (`Wnode.Guid` — the
  deterministic grant target), `EnableTraceEx2`s the constant provider list (RCs logged as
  `PROXY RC` lines), and grants the consumer account `TRACELOG_ACCESS_REALTIME` on the
  session GUID via `EventAccessControl` — SET (a SYSTEM full-control ACE, replacing the
  persisted SD so grants never accrete) then ADD (the consumer ACE). None of these control
  calls parses attacker-influenceable bytes. The proxy then only `OpenTraceW`s that
  session by name and `ProcessTrace`s it; it holds no session-control capability at any
  instant. This closes §10.17.2: PLU membership is gone outright, and the only token that
  cannot use PLU is one that never held it.
- **Launch — credentials IN-MEMORY, NO SECRET AT REST** (replaces the LSA-secret design):
  the agent is the single credential actor. Per launch it generates a fresh CSPRNG
  password, resets the account to it (`NetUserSetInfo(1003)`), and immediately proves it
  with `LogonUserW(LOGON32_LOGON_BATCH)` — the set-autologon.ps1 validate discipline with
  the storage step deleted. The former LSA secret `L$QubesEtwProxyCred`, the
  `QubesEtwProxyGuard` rotation task, and the rotation-vs-retrieve TOCTOU are all GONE
  (§10.17.5 closed by removal); the password lives in one stack frame and is zeroed before
  return. Then `CreateProcessAsUserW` of
  `notifhost.exe --etw-proxy --client-sid <console-user SID>` with
  `CREATE_SUSPENDED|CREATE_NO_WINDOW` → `AssignProcessToJobObject` → `ResumeThread`.
  Job: 64 MB ProcessMemoryLimit, ActiveProcessLimit=1, KILL_ON_JOB_CLOSE, all
  JOB_OBJECT_UILIMIT_* set. Session 0 (token born in the service's session), no
  LoadUserProfile, `lpDesktop=""` (the batch logon session's own window station). The
  client SID comes from `WTSQueryUserToken(WTSGetActiveConsoleSessionId())` → TokenUser.
  If the job cannot be built or assigned, the launch is REFUSED (never unsandboxed).
- **Refuse-on-drift (secure default, both sides)**: before any session control, the agent
  censuses the freshly-logged-on consumer token; if it carries the Performance Log Users
  SID, SeSystemProfilePrivilege, or Administrators, the launch is REFUSED and the ETW tier
  parks for the boot (fail-open — bridge degrades to listener/DB), never WARN-and-proceed:
  a drifted token has machine-wide trace capability and group SIDs cannot be shed
  in-process. The proxy's own census independently refuses the same condition (exit 9),
  belt-and-braces with its never-SYSTEM guard.
- **Supervision — exit-wait, no heartbeat** (§10.14.6 / owner directive):
  `RegisterWaitForSingleObject` on the process handle; the callback relaunches via a
  one-shot timer-queue timer, backoff 5 s→5 min doubling, reset after 10 min healthy
  uptime. Proxy exit 5 (`OpenTrace`/`ProcessTrace` consume denied despite the per-session
  DACL grant — §10.16.3b's datum as redefined by the split) and exit 9 (the proxy refused
  its own token: never-SYSTEM guard or drift census) PARK instead of relaunching; parking
  and every backoff also stop the agent-owned session (nothing would consume it), and the
  next launch restarts it fresh. `EtwProxyPoke` (5 s self-throttle on the existing loop
  pass) is NOT a health poll: it covers only "no console session yet" (first launch) and
  "console user changed" (TerminateJobObject → exit-wait relaunches with the new
  --client-sid), conditions an exit-wait cannot observe.
- **Graceful degrade**: account absent / batch logon refused / token drift / sandbox
  unavailable ⇒ ONE
  `ETWPROXYSUP parked` log line, then nothing for the rest of the boot — the bridge's
  ETW tier stays down and the listener/DB rungs serve (fail-open). The agent's frame
  path and main loop are never blocked or failed by any of this.
- **Provisioning ships** (§10.14.7, the helpers-must-be-explicitly-packaged rule):
  `guest/provision-etwproxy-account.ps1` — revised for the capability-grant split:
  account with ZERO group memberships (PLU actively stripped on upgrade — §10.17.2's
  residual closes only in a token that never held the group SID), explicit
  SeBatchLogonRight (load-bearing now that PLU no longer carries it), interactive/
  remote/network logon denied, throwaway random password batch-validated then
  DISCARDED (no LSA secret, no QubesEtwProxyGuard boot task — both deleted on upgrade;
  the SYSTEM agent is the sole credential actor, fresh in-memory password per launch),
  per-SID outbound firewall block, a log ACE scoped to the proxy's OWN
  `etw-proxy.log`/`.old` in the STANDARD QWT log dir (file-level Modify + folder-only
  FILE_ADD_FILE for the rotation re-create + CREATOR OWNER inherit-only Modify), and an
  inheritable DENY-write for the proxy SID on the bridge state dir (stop file/
  heartbeat/markers untouchable; the PLU-era Modify grant there is removed). Staged by
  `packaging/make-setup.ps1`, CI-guarded by `packaging/ours-wins.psd1`, and invoked by
  `packaging/setup/Install-QwtImproved.ps1` stage 2 after the bin overlay; always
  exits 0 (trailer `provisioned=`/`reason=` shape unchanged for the installer's parse).

Still design-only: §10.15 (BRIDGE supervision exit-wait + 180 s backstop — the shipped
heartbeat-poll `NotifBridgeSupervise` is unchanged) and the §10.14.5 per-boot random
pipe name (proxy and bridge still pair on the fixed name, §10.18 delta table).
