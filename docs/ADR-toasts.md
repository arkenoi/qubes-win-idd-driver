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
rendered by dom0; the guest's own banner is suppressed while, and only while, the dom0 connection is
up. What dom0 then does with the text - origin marking, sanitisation, its own rate limits - is
dom0's stock `qubes.Notifications` behaviour for every qube, not something this project implements
or has measured.

**Why.** A toast drawn by the guest is a guest-controlled surface on the user's desktop — the thing
the seamless model exists to bound. Forwarding text to dom0 puts the rendering on the trusted side,
under whatever treatment dom0 already gives every other qube's notifications. The alternative,
prettier guest-drawn banners, buys nothing and widens what a compromised guest can paint.

## 2. The route is decided per toast; the allowlist is a shortcut, not the gate

**Decision.** Every toast that is not already allowlisted is classified from its own content, and
the classifier's verdict decides the route: `verdict=bridge` forwards it to dom0 and suppresses the
guest banner, `verdict=window` leaves it on the ordinary guest-window path with its buttons intact.
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
marked seen. It is never held indefinitely and never dropped.

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
