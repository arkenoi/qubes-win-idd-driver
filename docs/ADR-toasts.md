# ADR - guest notifications: the toast bridge

## In plain English

A Windows notification (a "toast") in a seamless qube used to appear as a small window drawn by the guest on
your desktop. Now, by default, it is forwarded to dom0's own notification service and shown the way a
notification from any other qube is shown, and the banner inside the guest is suppressed while the forwarding
connection is up. The guest is not trusted to paint on your desktop; dom0 renders the text under its usual
treatment.

Not every toast can be forwarded. One that carries buttons needs them to work, so it stays a guest window.
Since 4.3.31 that choice is made per notification, by a classifier that looks at the toast's own content, not
per application. A short list of applications whose notifications are always informational (Snipping Tool,
Camera, Photos, Security and Maintenance, the backup reminder) is forwarded without waiting for the verdict,
and operators can extend the list per guest.

Whenever the bridge is unsure, the toast keeps the old guest-window path: an unknown application, no verdict
within about six seconds, the connection down, a Windows build whose notification database looks different. A
notification may lose its dom0 rendering, never its delivery. Dismissing the dom0 copy clears it in the guest
too. Agent faults travel to dom0 on a separate, bounded route that these switches do not affect. All switches
are read once when the agent starts, and dom0's settings win over the guest's.

The first toast of an application routed by the classifier used to appear twice, because the guest banner was
already on screen when the verdict arrived. Now the agent does not show the banner window at all until that
toast's own verdict is in (§10): forwarded, it is never shown; kept on the window path, it is shown at once; no
verdict within about three seconds, it is shown and the fall-back is logged. Windows' per-application banner
setting is no longer touched. In non-seamless mode, where the guest's banner is visible inside the desktop window,
the bridge forwards nothing, so no toast is shown twice there either.

How one toast is routed (§2, §3, §7, §8). §10 changes how the banner is suppressed, not the route:

```mermaid
flowchart TD
    A["An application raises a toast in the guest"] --> G{"Gates, read once at agent start (§7)"}
    G -->|"legacy-toasts set, or notify-bridge off"| W["Window path: the banner is an ordinary override-redirect<br/>guest window in dom0, its buttons intact"]
    G -->|"bridge on"| H{"Bridge healthy, dom0 connection up?"}
    H -->|no| W
    H -->|yes| L{"Sender's AUMID in NotifyBridgeAllow,<br/>or in the built-in seed (§4)?"}
    L -->|yes| F["Forward to dom0's qubes.Notifications;<br/>the guest banner stays unmapped (§10)"]
    L -->|no| S{"Classifier usable? (§8: the wpndatabase<br/>schema matched for this process)"}
    S -->|no| W
    S -->|yes| V{"Verdict within 3 poll passes (about 6 s)?"}
    V -->|"verdict = bridge"| F
    V -->|"verdict = window"| W
    V -->|"no verdict"| W2["Window path, marked seen - never held, never dropped (§3)"]
    F --> D["dom0 renders it; a dom0 dismissal is echoed back to the guest (§5)"]
```

## The decisions at a glance

| § | decision | status | since |
|---|---|---|---|
| 1 | A guest notification is dom0's to render, not the guest's to draw | ACCEPTED | 4.3.30 |
| 2 | The route is decided per toast; the allowlist is a shortcut, not the gate | ACCEPTED | 4.3.31 |
| 3 | Misrouting fails open, never closed | ACCEPTED | 4.3.30 |
| 4 | The allowlist ships with a conservative seed, not empty and not everything | ACCEPTED | 4.3.30 |
| 5 | The dom0 notification is the copy; the guest Notification Center stays in sync | ACCEPTED | 4.3.30 |
| 6 | Error reporting is a sibling route, not this one | ACCEPTED | 4.3.30 |
| 7 | Every gate is read once, at agent start | ACCEPTED | 4.3.30 |
| 8 | When the classifier cannot trust its inputs, it stops classifying | ACCEPTED | 4.3.31 |
| 9 | The allowlist is a guest-side convenience; the switches that matter are dom0's | ACCEPTED | 4.3.30 |
| 10 | The guest banner is suppressed by not mapping it, never by ShowBanner | ACCEPTED (owner, Jev); built for 4.3.35, guest acceptance owed | 2026-10-04 |

Status words and the section format are defined in `docs/ADR-README.md`.

---

## The decisions in detail

Where the details live:

| record | content |
|---|---|
| `docs/DESIGN-toast-bridge.md` | the bridge's mechanism, the options considered (A0/A1/B), phase plan |
| `docs/DESIGN-p3-classifier-impl.md` | the per-toast classifier: signals, call sites, tests |
| `docs/DESIGN-error-notify.md` | the separate error route (`service.notify-errors`) |
| `docs/QVM-FEATURES.md` | the features, their defaults and precedence - authoritative |
| `findings/issues.md` | open defects, among them the first-toast double (P1) that §10 addresses |

## 1. A guest notification is dom0's to render, not the guest's to draw

**Status:** ACCEPTED.

**Decision.** An allowed guest toast is forwarded to dom0's stock `qubes.Notifications` service and rendered
by dom0. The guest's own banner is suppressed while, and only while, the dom0 connection is up. What dom0 then
does with the text - origin marking, sanitisation, its own rate limits - is dom0's stock behaviour for every
qube, not something this project implements or has measured.

**Why.** A toast drawn by the guest is a guest-controlled surface on the user's desktop, the thing the
seamless model exists to bound. Forwarding text to dom0 puts the rendering on the trusted side, under whatever
treatment dom0 already gives every other qube's notifications. The alternative, prettier guest-drawn banners,
buys nothing and widens what a compromised guest can paint.

## 2. The route is decided per toast; the allowlist is a shortcut, not the gate

**Status:** ACCEPTED, shipped in 4.3.31. Before it, an app in neither the allowlist nor the classifier's
reach was skipped outright; this decision replaces that.

**Context.** An allowlist can only route apps somebody enumerated, and nobody enumerates the app that fires
the toast in front of a user. The property that decides whether dom0 can safely render a toast is
INTERACTIVITY - does acting on it require its buttons - and that is a property of the toast, not of the app
that sent it.

**Decision.**

1. Every toast that is not already allowlisted is classified from its own content. `verdict=bridge` forwards
   it to dom0 and suppresses the guest banner; `verdict=window` leaves it on the ordinary guest-window path
   with its buttons intact.
2. An AUMID in `NotifyBridgeAllow` is forwarded without waiting for a verdict. The allowlist is a per-app
   shortcut for senders whose toasts are known to be informational, saving the classification round trip.
3. **Bound.** A toast with no verdict after 3 poll passes (about 6 s) takes the window path and is marked seen.
   It is never held indefinitely and never dropped.

**Scope.** WHICH inputs the classifier has, and what they carry on each Windows build (the ETW payload on 11;
signal-only on 10 with the payload read from `wpndatabase.db`), is implementation and lives in
`docs/DESIGN-p3-classifier-impl.md`. The decision here is only that the VERDICT routes, and that a missing or
untrustworthy input fails open (§3, §8) rather than changing the route.

**Evidence.** Measured on win11-nfy (package 4.3.30+agent.54347f15b43e, `mgmt/harness/classifier-route-probe.sh`,
2026-09-23): an informational toast from a non-allowlisted app was classified `verdict=bridge` and routed to the
bridge; a buttoned toast from a different non-allowlisted app was classified `verdict=window` and stayed on the
window path; deferrals stayed inside the cap. That measurement covered the ROUTE, not the absence of the guest
banner; the banner defect it missed is §10's subject.

## 3. Misrouting fails open, never closed

**Status:** ACCEPTED.

**Decision.** Anything the bridge is unsure of - an unknown app, an unhealthy bridge, a classifier that cannot
decide, a dom0 connection that is down - keeps the guest-window path. A notification is never dropped to
satisfy the bridge.

**Why.** The failure the user would never forgive is a notification that simply vanishes. Fail-open means the
worst case of a bridge defect is the behaviour that shipped for years. That is why the classifier does not have
to be right to be safe; it only has to be right to be *useful*.

## 4. The allowlist ships with a conservative seed, not empty and not everything

**Status:** ACCEPTED.

**Decision.** With `NotifyBridgeAllow` unset, a small built-in seed of reliably informational apps is used:
Snipping Tool, Camera, Photos, Security & Maintenance, the backup reminder. Operators extend it per guest,
using `notifhost --dump-aumids` to see what a guest actually emits.

**Why.** An empty allowlist would have meant the bridge forwarded nothing on a guest nobody had configured:
the feature present, running, and inert. A seed makes it demonstrably alive on first boot. Seeding
*everything* would make every app bannerless the moment the bridge connects, ahead of any verdict about its
toasts; the seed is a shortcut for senders known to be informational (§2), so it may only contain senders that
are.

## 5. The dom0 notification is the copy; the guest Notification Center stays in sync

**Status:** ACCEPTED.

**Decision.** A dismissal in dom0 is echoed back to the guest, so an action taken on the dom0 copy is reflected
in the guest's own Notification Center.

**Why.** Two independent copies of the same notification is worse than one in the wrong place: the user clears
it in dom0 and the guest still believes it is pending. Sync is what makes forwarding a move rather than a
duplication.

## 6. Error reporting is a sibling route, not this one

**Status:** ACCEPTED.

**Decision.** `service.notify-errors` raises ACTION-severity agent faults to dom0 as notifications, through the
same helper but a different path (`--notify-file`, one-shot). It is bounded - once per distinct error per boot,
at most 8 per boot, secret-shaped text refused - and it is **in addition to** the guest log line, never instead
of it. `service.legacy-toasts` does not affect it.

**Why.** A fault the operator never sees is a fault that does not get fixed, and a log line inside a guest
nobody opens is that. Bounding it keeps a failing guest from becoming a notification storm. Keeping the log
line means the evidence survives even when qrexec, which this route rides, is down.

## 7. Every gate is read once, at agent start

**Status:** ACCEPTED.

**Decision.** `NotifyBridge`, `NotifyErrors` and `LegacyToasts` are read at agent init from the registry and
then qubesdb, with dom0 winning. Changing one takes effect at the next agent start.

**Why.** The project's standing rule: a capability is settled at start and never re-read, so a transient
failure to read a gate cannot silently downgrade a running guest. It also makes the log line at init the
single authoritative statement of what this boot is doing.

## 8. When the classifier cannot trust its inputs, it stops classifying

**Status:** ACCEPTED.

**Context.** The per-toast classifier reads `wpndatabase.db`, whose schema is undocumented and owned by
Windows.

**Decision.** A missing table or column is treated as PERMANENT for the life of the process: the shadow
classifier is disabled for that run, logged once and loudly
(`WPNDB SCHEMA MISMATCH: ... (shadow classifier disabled for this run, fail-open)`), and every unlisted toast
then takes the window path. Allowlisted apps are unaffected; they never needed a verdict.

**Why.** The alternative is worse in both directions: retrying a query the OS will never satisfy turns every
toast into a stall, and guessing at a changed schema would route notifications on a misread. A Windows build
that moves the schema must degrade to the behaviour that shipped for years, not to a coin flip. And it must SAY
so, because a silently disabled classifier looks exactly like a classifier that decided "window" every time
(the standing rule: a fallback that fires is an anomaly and is logged).

## 9. The allowlist is a guest-side convenience; the switches that matter are dom0's

**Status:** ACCEPTED.

**Decision.** `NotifyBridgeAllow` lives in the guest registry and is extended by whoever administers that
guest, on the evidence of `notifhost --dump-aumids`, for senders whose toasts are informational. dom0 keeps the
controls that decide whether anything is forwarded at all (`service.notify-bridge`, and `service.legacy-toasts`,
which wins), and dom0's own qrexec policy decides whether the qube may reach `qubes.Notifications` in the first
place.

**Why.** A list of application ids is a routing convenience, not a privilege boundary: a guest that can write
its own HKLM can widen it, so nothing may depend on it being honest. What that buys the guest is bounded by
design: its text reaches dom0 only over a service dom0 policy already governs, and it is rendered by dom0 under
the treatment dom0 gives every qube. Putting the list in dom0 would dress it up as a control it is not, and
would make a per-guest, per-application list a policy edit.

## 10. The guest banner is suppressed by not mapping it, never by ShowBanner

**Status:** ACCEPTED (owner: "i thought we agreed on design, delay and everything"; Jev), 2026-10-04; proposed by Jev
2026-10-01. In 4.3.35 (owner 2026-10-06: "switch to toast-fix"), with rule 5's case as a known failure (see Cost); the guest
acceptance (`mgmt/harness/toast-hold-test.sh`, control first) passed every other case.
The defect it fixes is the first-toast double, P1 in `findings/issues.md` (owner 2026-10-04: "first toast shown twice is
fucking ugly P1").

**Context.** Two defects measured on 2026-10-01 come from the per-application `ShowBanner=0` switch the bridge wrote:

- It was set only when a toast was forwarded, so the first classified toast of an app was already on screen and reached
  dom0 twice: the guest banner (captured as a window) and the dom0 notification. Seen by the owner 2026-10-01 ~11:59 on
  w11-ds (Windows Security, "Microsoft Defender summary"). After every bridge restart it happened again.
- It stayed set until the bridge exited, so a later toast of the same app whose own verdict sent it to the window path
  was shown nowhere: a misroute that fails CLOSED, against §3.

Measured 2026-10-04 on retail Windows 11 26300 and Windows 10 19045: ONE ShellExperienceHost banner window
(`Windows.UI.Core.CoreWindow`, "New notification") serves every toast of the session; the shell shows banners one at a
time, first in first out, a queued one seconds after its arrival; a new banner arrives either by a collapse-and-grow
cycle or in place (same rectangle, a burst of location changes). The card's UI Automation tree names it by
non-localized ids: `NormalToastView` (the card), `SenderName`, `Title` (11) or `TitleText` (10), `MessageText`. So a
banner is identified by its content, never by its window or by arrival order alone.

**Decision.**

1. The agent keeps each toast's banner window unmapped in dom0 until THAT toast's verdict is known: `bridge` (or
   `forwarded`) - never mapped; `window` - mapped at once; none within 3 s - mapped, and the fall-back is logged loudly
   (`QGATOASTHOLDLATE`). A double is better than a loss; neither is the target.
2. The bridge no longer writes `ShowBanner` (a sweep still restores markers older versions left). It publishes one
   record per listed notification - content identity hashes (sender, title, message; normalized the same way on both
   sides), verdict pending/bridge/window/forwarded, arrival tick - into a section the agent created, and signals an event
   the agent's main loop waits on. Nothing polls.
3. Matching is by content; arrival order only breaks ties between identical texts - by arrival tick, then by the
   record's publish sequence, never by its position in the ring (which reorders across a wrap). A record with the same
   sender and title but another message is taken only when it is the unique such candidate. A banner re-claims the
   record it already consumed only when a later reading COMPLETES the earlier one (same sender and title, the message
   empty before or a prefix of the new one); other content in the same window is a new toast and must match its own
   record or fail open. The identity is read in the UI Automation raw view, on the toastcrop worker, bounded.
4. A suppression is not final: a record that turns `window`, a bridge that dies before dom0's acknowledgement (unless
   the record says `forwarded`), and a suppression not acknowledged within 3 s each show the banner after all, loudly.
   A dead bridge's unacknowledged records read as `window`.
5. While a newer record is still `bridge` or `pending`, a displayed window-path banner is unmapped before an in-place
   swap can paint (pre-emption), bounded (3 s for `pending`, 15 s for `bridge`, never while the bridge is down).
6. Only the banner is held: the ShellExperienceHost banner surface (a surface >= 90 % of the screen is not one); a window
   with no toast card in two reads at least 250 ms apart is a flyout and is shown at once.
7. Nothing runs at rest: deadlines are armed only while something is held, suppressed or pre-empted.
8. In non-seamless mode the agent publishes the mode in the section header and the bridge forwards nothing: every toast
   takes the window path there, its banner visible inside the desktop window (Jev 0.95).

Implementation: `agent/gui-agent/toastident.h` (the contract both binaries compile), `toasthold-core.h` (the state
machine), `toasthold.c`, every UI Automation call in `toastcrop.c`, `tools/notifhost/notifhost.cpp`.

**Why.** In seamless mode the user sees a guest banner only because the agent maps its window into dom0, so not mapping
it is the whole suppression; nothing in Windows' settings has to change, and every uncertain case falls to mapping the
window - the behaviour that shipped before. Owner: an occasional ~3 s delay on a first toast is fine, a flash is not.
Jev 2026-10-01: agent-side hold 1.00 against per-toast ShowBanner toggling and RemoveNotification after forwarding
(0.00); fails open by construction 0.89. Two independent reviews of the implementation (2026-10-06) found a flash path
(pre-emption released during an identity read), a loss path (a suppression that ignored a later `window`), a permanent
pre-emption for an unreadable card, an unpaced not-a-banner verdict and a pixel-based size cut; all fixed, each with a
defect knob in the offline suite. Jev on the result: no doubles 0.79, the bounds are failure states 0.94, nothing at
rest 0.71, nothing lost 0.54, top residual an identity mismatch on real banners (measured by the guest test).

**Cost.** A first toast waits for its verdict: the identity read plus the verdict latency, at most 3 s, then shown. A
window-path banner followed within its display time by a bridged toast loses its dom0 display (it stays in the guest's
Notification Center) - measured 2026-10-06: withdrawn 20 ms after it was mapped, or, when the newer record was already there,
never mapped at all. That is against the owner's rule (no flash, nothing lost); 4.3.35 ships it as a known issue by the owner's
decision, and rule 5 is to be replaced (Open). A flyout (Quick Settings, volume, clock) appears up to ~250 ms plus one read later.

**Evidence.** Offline: `agent/gui-agent/toasthold_test.c` (176 checks, as C99 and as C++17) and
`tools/notifhost/toasthold_bridge_test.cpp` (25 checks), every defect knob (15 + 2) seen to fail; CI builds and runs
both suites. On a guest (`mgmt/harness/toast-hold-test.sh`, win11r, 2026-10-06): the build without the hold doubled the
first classified toasts and lost a window-path one (the detectors seen to fail); the hold build (37499041570) passed 17 of 18
rows - forwarded toasts never mapped (held 78-375 ms), window-path toasts shown, a shared-window pair bridged-then-window clean,
non-seamless forwarding nothing - and failed only rule 5's case.

**Open.** Not fixed by this section: a toast whose banner timed out before a correction is only in the guest's
Notification Center; the identity of system toasts whose display name differs between the notification database and
the card is unmeasured (a mismatch fails open: the double returns, logged).
Rule 5 is to be replaced: keep the displayed window-path banner mapped, and while a newer `bridge` or `pending` record is
queued behind it forward none of that window's new frames until a fresh identity read shows which toast it carries (swap-edge
gating; Jev 2026-10-06 0.44, against 0.36 for a bridge re-route with it as the fallback and 0.08 for keeping rule 5). First
measurement: whether the capture path can hold back one mapped window's frames (Jev 0.75).
