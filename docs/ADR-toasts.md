# ADR — guest notifications (the toast bridge)

**Status: accepted.** The bridge ships default-on since 4.3.30; per-toast routing since 4.3.31.

This file records DECISIONS about how a guest's Windows notifications reach dom0, and why the
routing is shaped the way it is. It is not a status report: what a guest did on a given day belongs
in `findings/`, and the implementation detail lives in the design notes.

| record | content |
|---|---|
| `docs/DESIGN-toast-bridge.md` | the bridge's mechanism, the options considered (A0/A1/B), phase plan |
| `docs/DESIGN-p3-classifier-impl.md` | the per-toast classifier: signals, call sites, tests |
| `docs/DESIGN-error-notify.md` | the separate error route (`service.notify-errors`) |
| `docs/QVM-FEATURES.md` | the features, their defaults and precedence — authoritative |
| `findings/issues.md` | open defects |

Rule for editing this file: add a section only when a DECISION changes. A sentence that goes stale
when a guest is fixed is an observation and belongs in `findings/`.

---

## 1. A guest notification is dom0's to render, not the guest's to draw

**Decision.** An allowed guest toast is forwarded to dom0's stock `qubes.Notifications` service and
rendered by dom0; the guest's own banner is never mapped into dom0 for a forwarded toast (how: §10 -
the agent holds each banner until that toast's verdict; the per-application `ShowBanner` switch this
sentence used to name is retired). What dom0 then does with the text - origin marking, sanitisation,
its own rate limits - is dom0's stock `qubes.Notifications` behaviour for every qube, not something
this project implements or has measured.

**Why.** A toast drawn by the guest is a guest-controlled surface on the user's desktop — the thing
the seamless model exists to bound. Forwarding text to dom0 puts the rendering on the trusted side,
under whatever treatment dom0 already gives every other qube's notifications. The alternative,
prettier guest-drawn banners, buys nothing and widens what a compromised guest can paint.

## 2. The route is decided per toast; the allowlist is a shortcut, not the gate

**Decision.** Every toast that is not already allowlisted is classified from its own content, and
the classifier's verdict decides the route: `verdict=bridge` forwards it to dom0 and its guest banner
is never mapped (§10), `verdict=window` leaves it on the ordinary guest-window path with its buttons intact.
An AUMID in `NotifyBridgeAllow` is forwarded without waiting for a verdict. An app in neither place
is no longer skipped outright - which is what shipped before 4.3.31 and is the behaviour this
decision replaces.

**Why.** An allowlist can only route apps somebody enumerated, and nobody enumerates the app that
fires the toast in front of a user. The property that decides whether a toast can be safely rendered
by dom0 is INTERACTIVITY - does acting on it require its buttons - and that is a property of the
toast, not of the app that sent it. So the classifier's verdict is the routing decision, and the
allowlist degrades to what it always really was: a per-app shortcut for senders whose toasts are
known to be informational, saving the classification round-trip.

**Bound.** A toast with no verdict after 3 poll passes (about 6 s) takes the window path and is
marked seen. It is never held indefinitely and never dropped. (The agent's own bound on holding the
banner is shorter - 3 s, §10 - so a verdict the bridge reaches between 3 and 6 s arrives after the
banner has already been shown; that is the designed fail-open, reported in the agent log.)

**Scope note.** WHICH inputs the classifier has, and what they carry on each Windows build (ETW
payload on 11, signal-only on 10 with the payload read from `wpndatabase.db`), is implementation and
lives in `docs/DESIGN-p3-classifier-impl.md`. The decision here is only that the VERDICT routes, and
that a missing or untrustworthy input fails open (§3, §8) rather than changing the route.

**Measured** (win11-nfy, package 4.3.30+agent.54347f15b43e, `mgmt/harness/classifier-route-probe.sh`,
2026-09-23): an informational toast from a non-allowlisted app was classified `verdict=bridge` and
routed to the bridge; a buttoned toast from a different non-allowlisted app was classified
`verdict=window` and stayed on the window path; deferrals stayed inside the cap.

## 3. Misrouting fails open, never closed

**Decision.** Anything the bridge is unsure of — an unknown app, an unhealthy bridge, a classifier
that cannot decide, a dom0 connection that is down — keeps the guest-window path. A notification is
never dropped to satisfy the bridge.

**Why.** The failure the user would never forgive is a notification that simply vanishes. Fail-open
means the worst case of a bridge defect is the behaviour that shipped for years, which is why the
classifier does not have to be right to be safe — it only has to be right to be *useful*.

## 4. An allowlist ships with a conservative seed, not empty and not everything

**Decision.** With `NotifyBridgeAllow` unset, a small built-in seed of reliably informational apps is
used (Snipping Tool, Camera, Photos, Security & Maintenance, the backup reminder). Operators extend
it per guest, using `notifhost --dump-aumids` to see what a guest actually emits.

**Why.** An empty allowlist would have meant the bridge forwarded nothing on a guest nobody had
configured - the feature present, running, and inert. A seed makes it demonstrably alive on first
boot. A seed makes the feature demonstrably alive on
first boot. Seeding *everything* would make every app bannerless the moment the bridge connects, ahead of any
verdict about its toasts - the seed is a shortcut for senders known to be informational (§2), so it
may only contain senders that are.

## 5. The dom0 notification is the copy; the guest Notification Center stays in sync

**Decision.** A dismissal in dom0 is echoed back to the guest, so an action taken on the dom0 copy is
reflected in the guest's own Notification Center.

**Why.** Two independent copies of the same notification is worse than one in the wrong place: the
user clears it in dom0 and the guest still believes it is pending. Sync is what makes forwarding a
move rather than a duplication.

## 6. Error reporting is a sibling route, not this one

**Decision.** `service.notify-errors` raises ACTION-severity agent faults to dom0 as notifications,
through the same helper but a different path (`--notify-file`, one-shot). It is bounded — once per
distinct error per boot, at most 8 per boot, secret-shaped text refused — and it is **in addition
to** the guest log line, never instead of it. `service.legacy-toasts` does not affect it.

**Why.** A fault the operator never sees is a fault that does not get fixed; a log line inside a
guest nobody opens is that. Bounding it is what keeps a failing guest from becoming a notification
storm, and keeping the log line means the evidence survives even when qrexec — which this route rides
— is down.

## 7. Every gate is read once, at agent start

**Decision.** `NotifyBridge`, `NotifyErrors` and `LegacyToasts` are read at agent init from the
registry and then qubesdb, with dom0 winning; changing one takes effect at the next agent start.

**Why.** The project's standing rule: a capability is settled at start and never re-read, so a
transient failure to read a gate cannot silently downgrade a running guest. It also makes the log
line at init the single authoritative statement of what this boot is doing.
## 8. When the classifier cannot trust its inputs, it stops classifying

**Decision.** The per-toast classifier reads `wpndatabase.db`, whose schema is undocumented and
owned by Windows. A missing table or column is treated as PERMANENT for the life of the process:
the shadow classifier is disabled for that run, logged once and loudly
(`WPNDB SCHEMA MISMATCH: ... (shadow classifier disabled for this run, fail-open)`), and every
unlisted toast then takes the window path. Allowlisted apps are unaffected - they never needed a
verdict.

**Why.** The alternative is worse in both directions: retrying a query the OS will never satisfy
turns every toast into a stall, and guessing at a changed schema would route notifications on a
misread. A Windows build that moves the schema must degrade to the behaviour that shipped for
years, not to a coin flip - and it must SAY so, because a silently disabled classifier looks
exactly like a classifier that decided "window" every time (the standing rule: a fallback that
fires is an anomaly and is logged).
## 9. The allowlist is a guest-side convenience; the switches that matter are dom0's

**Decision.** `NotifyBridgeAllow` lives in the guest registry and is extended by whoever
administers that guest, on the evidence of `notifhost --dump-aumids` for senders whose toasts are
informational. dom0 keeps the controls that decide whether anything is forwarded at all
(`service.notify-bridge`, and `service.legacy-toasts`, which wins), and dom0's own qrexec policy
decides whether the qube may reach `qubes.Notifications` in the first place.

**Why.** A list of application ids is a routing convenience, not a privilege boundary: a guest that
can write its own HKLM can widen it, so nothing may depend on it being honest. What that buys the
guest is bounded by design - its text reaches dom0 only over a service dom0 policy already governs,
and it is rendered by dom0 under the treatment dom0 gives every qube. Putting the list in dom0
would dress it up as a control it is not, and would make a per-guest, per-application list a
policy edit.

## 10. The guest banner is suppressed by not mapping it, never by ShowBanner — ACCEPTED, 2026-10-04 (proposed by Jev 2026-10-01)

**Decision.** The agent keeps each toast's banner window unmapped in dom0 until THAT toast's verdict is known:
`verdict=bridge` - never mapped (the guest banner times out unseen in the guest); `verdict=window` - mapped at once;
no verdict within 3 s - mapped, and the fall-back is reported (`QGATOASTHOLDLATE`): a double is better than a loss, and
neither is the target. The suppression is revisited on every pass (see the review corrections below): a record that
turns `window`, or a bridge that dies before dom0's acknowledgement, shows the banner after all. The per-application `ShowBanner=0` switch is retired: the bridge no longer writes it; the sweep
that restores markers left by versions that did stays. The bridge publishes one record per listed notification (content
identity hashes, verdict pending/bridge/window, arrival tick) into a section the agent created and signals an event the
agent's main loop waits on; nothing polls. Implementation: `agent/gui-agent/toastident.h` (the contract both binaries
compile), `toasthold-core.h` (the state machine, unit-tested), `toasthold.c`, `tools/notifhost/notifhost.cpp`.

**Measured facts the design fits** (retail Windows 11 26300.9457 and Windows 10 19045.2965, both on 4.3.34,
`scratchpad/toast-banner-probe`, 2026-10-04):
1. ONE banner window serves every toast of the session: process ShellExperienceHost, class `Windows.UI.Core.CoreWindow`,
   window text 'New notification', the same HWND for all toasts (created ~0.7 s after the session's first toast, with a
   second 1x1 ShellExperienceHost window). It lives in a higher z-band (EnumWindows cannot see it; the agent's WinEvent
   hooks do).
2. The shell SERIALIZES banners, one at a time, FIFO by arrival; a queued toast's banner appears seconds after its
   arrival (6.9 s measured). Neither the HWND nor the arrival time identifies a banner.
3. A new banner arrives EITHER as a collapse-and-grow cycle (396x152 -> 396x0 -> 396x43 -> 396x152 on 11; 396x193 ->
   396x0 -> 396x82 -> 396x193 on 10) OR IN PLACE (same rect, a burst of EVENT_OBJECT_LOCATIONCHANGE, no collapse).
   A new banner is therefore detected by its CONTENT, re-read on every location/name change of the banner window.
4. The card's UI Automation tree identifies the toast. The card is the element with AutomationId `NormalToastView` on
   both builds (its ClassName is `FlexibleToastView` on 11 only and is not keyed on; its Name is a LOCALIZED composite -
   en-GB "action centre", GWeck's guests are German - and is never parsed). Its children, by AutomationId and
   unlocalized: `SenderName` (the app display name), `Title` on 11 / `TitleText` on 10 (the first text line),
   `MessageText` (the second), `AppLogo`, `SettingsButton`, `DismissButton`, and `VerbButton`/`VerbText` for a toast
   with actions.

**The matching rule** (Jev, 2026-10-04): a banner is tied to the bridge's notification by CONTENT identity - the app
display name (when the bridge has it), the title and the message, normalized identically on both sides (whitespace
folded, bidi marks dropped, ASCII/Latin-1 case folded, FNV-1a 64 over UTF-16) - and arrival order is used ONLY to break
a tie between notifications with identical text. Never by order alone: a notification that produces no banner (per-app
banners off, do-not-disturb, Notification Center open, an update of an existing toast) would desync an order-based
matcher and misroute a window-path toast to nowhere. A record whose message differs but whose sender+title match is
taken only when it is the unique such candidate (and logged); otherwise nothing is claimed and the banner fails open.

**Pre-emption** (the price of "no flash", measured fact 3): a banner arriving IN PLACE paints into a window that may be
mapped for the window-path toast before it. So while a record NEWER than the displayed banner's own is still `bridge`
or `pending` (FIFO: it is queued behind), the displayed banner is unmapped before the swap can paint, and re-mapped if
that record resolves to `window` without a swap. A window-path banner followed within its display time by a bridged
toast loses the tail of its dom0 display (it stays in the guest's Notification Center). Bounded: a `pending` record
pre-empts for at most the 3 s hold bound, a `bridge` record for at most 15 s after its arrival - a bridged toast whose
banner never comes must not keep the user's banners hidden.

**Why.** Two defects measured on 2026-10-01 come from the per-application switch. It is set only when a toast is
forwarded, so the first classified toast of an app is already on screen and reaches dom0 twice (guest banner + dom0
notification). And it stays set until the bridge exits, so a later toast of the same app whose own verdict sends it to
the window path - an interactive one - is shown nowhere: a misroute that fails CLOSED, against §3. In seamless mode the
user sees a guest banner only because the agent maps its window into dom0, so not mapping it is the whole suppression;
nothing in Windows' settings has to change, and every uncertain case (no verdict, no record, no readable identity, a
bridge that is down or dies mid-hold) falls to mapping the window - the behaviour that shipped. Owner: an occasional
~3 s delay on a first toast is fine, a flash of the guest banner before it disappears is not. Jev (2026-10-01): agent-
side hold 1.00 against per-toast ShowBanner toggling (racy with concurrent toasts) and RemoveNotification after
forwarding (deletes the guest's Notification Center copy, §5) 0.00; fails open by construction 0.89.

**Review corrections, 2026-10-06** (an independent review of the first implementation; each is a knob in the offline
suite that makes it fail with the defect present):
- *A suppression is not final.* The bridge's record can turn `window` after the agent suppressed the banner (the forward
  failed for good, the toast was listed while dom0 was unreachable), and the bridge can die between deciding `bridge` and
  dom0 acknowledging the forward. A suppressed banner therefore re-reads its record every pass: `window` shows it after
  all (`QGATOASTHOLD state=show reason=record-turned-window`), and a bridge death shows it unless the record says
  `forwarded` - the state the bridge writes once dom0 acknowledged (a fourth verdict). The classifier's late answer is a
  compare-exchange from `pending` only; the bridge keeps the classifier's verdict until the forward succeeds or is given
  up, so a failed forward is retried instead of ending as `window` unforwarded; an allowlisted toast listed while dom0 is
  unreachable is published `window`, not `bridge`.
- *Pre-emption is evaluated on every pass, whether or not an identity read is in flight.* The in-place swap's own
  LOCATIONCHANGE queues a read before the tracking pass runs; a pass that treated the identity as unknown ended the
  pre-emption and mapped the window while the bridged toast painted. The last reading stands until the new one lands,
  and an identity-less pass never ends a pre-emption in force.
- *A completed identity re-claims its record.* A first read of a half-built card (no message yet) takes the unique
  partial match and consumes the record; when the full read changes the identity, that record stays a candidate for the
  same banner (and only for it), so the banner is decided on it instead of waiting out the bound with "no record".
- *Only the banner is held.* `IsShellToastWindow` admits every shell-host surface (no size ceiling since 2026-08-12); the
  hold applies to the ShellExperienceHost kind under 60 % of the screen in both dimensions, and a window with no
  `NormalToastView` in two reads 250 ms apart is a flyout (Quick Settings, volume, clock): shown at once, never held, no
  fail-open logged. Cost: a flyout appears up to ~250 ms + one read later than before, in the same order as the
  crop-before-show hold it already pays.
- *The identity read uses the UI Automation RAW view* (as the measurement and toastcrop's toast rule do), through a cache
  request whose tree filter is the raw-view condition; template-part text blocks the control view hides are then seen.
  Both sides log the three field hashes (sender, title, message) so a mismatch names the field.
- *No timer for a decided banner.* A banner the hold owns (held, suppressed, pre-empted) leaves the crop-before-show
  re-check sweep (`ToastHoldOwned`); it is woken only by the verdict event, its own reads and its bounded deadlines, and
  put back on the sweep's clock when the hold lets go with the crop still outstanding. The no-identity hold honours a
  bridge that is down (shown at once); a bridge-withheld banner is never mapped by a resize re-attach or a popup-state
  toggle either; an identity read carries the window's incarnation so a reading about a removed-and-re-added window is
  dropped; a deadline the sweep fires is moved, never cleared, so an early-leaving pass cannot strand a held banner.

**Second review, 2026-10-06** (each again a knob in the suite):
- *The agent bounds the forward too.* A suppressed banner whose record has not turned `forwarded` within 3 s
  (`TH_FORWARD_BOUND_MS`, the latency already accepted for a first toast; dom0's ack arrives within the forward's own
  round trip - measured from the captured bridge logs' `FWD_RTT ok=1` lines, 85 forwards: min 1 ms, p50 9 ms, p90
  17 ms, max 24 ms, so the bound is >100x the worst measured ack) is shown after all, loudly
  (`QGATOASTHOLDLATE reason=forward-unconfirmed`): the bridge's own failure paths - its 15 s ack timeout, a reconnect
  before the next listing, the rejection cap - correct the record only after a 5 s banner is gone. Armed only while a
  suppression awaits its ack.
- *A dead bridge's records are dead letters.* At the bridge's death the agent captures the ring's position; `bridge`/
  `pending` records at or below it read as `window` (a relaunched bridge baselines the center as seen and never
  forwards them), `forwarded` stands, and nothing pre-empts while the bridge is down.
- *Pre-emption lives only on the glue's every-pass evaluation.* The extra term that kept a pre-emption alive while the
  identity was unknown made it permanent for a banner whose card never read (every toast swapped into that window
  lost); dropped.
- *The size rule is relative.* A surface is not a banner only when it is >= 90 % of the screen in either dimension
  (the Notification Center and the clock flyout are full height); the earlier absolute 60 % cut never held the
  measured 573 px banners at 1366x768, 1600x900 or 125 %+ DPI. Applied once, at first sight, so a banner is never
  released by its own growth.
- *The second card-less look is paced*: it counts only when requested >= 250 ms after the first, so a banner mid-grow
  (both looks within milliseconds) is never classed a flyout; a decided banner whose last read failed re-reads on a
  deadline, at most six times in a row; a refused read request (full worker queue) backs off 250/500/1000/2000 ms
  instead of spinning.

**Non-seamless mode** (decided 2026-10-06, Jev N1 0.95 / within the mandate 0.82). The hold exists only in seamless
mode: in non-seamless (fullscreen) mode the guest draws its banner inside the one desktop window the agent maps, nothing
can withhold it, and a toast forwarded to dom0 shows twice - which 4.3.34 avoided for allowlisted apps only, through
`ShowBanner`. The agent publishes the current display mode in the records section's header (`Seamless`, updated on every
mode switch) and the bridge forwards NOTHING while it is non-seamless: every toast listed then takes the window path
(`skip ... (window path; non-seamless mode)`), its record is `window`, and a toast arriving during non-seamless is not
forwarded later either - the guest banner inside the desktop window was its one copy.

**Windows 10.** The same path: the only difference is the title block's AutomationId (`TitleText`), and the agent
accepts both. Should a build's card not be readable at all (no `NormalToastView`, no title block), every banner on it
fails open after 3 s - visible as `QGATOASTHOLDLATE reason=no-identity` on every toast - and every bridged toast there
shows twice; that state must not ship and is the first thing the guest test reads.

**Trust.** Everything the bridge writes into the section is untrusted input to the agent (hashes are opaque, the
verdict is range-checked with anything else reading as `window`, the ring is read under a seqlock). A hostile user-IL
writer can keep the user's own banners unmapped, which is the privilege it already has over its own notification
settings; it cannot make the agent map anything it would not have mapped.
