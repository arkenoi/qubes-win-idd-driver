# DESIGN — routing Windows toast notifications through the dom0 notification bridge

Status: **research + proposal, no code**. Written 2026-09-04. Nothing here is implemented or
tested on the rig; every claim marked *(verify on rig)* is a design assumption that needs a
measurement before any build.

## 0. Context — the two delivery paths that exist today

1. **Seamless window path (exists, verified).** In seamless mode a Windows toast reaches dom0
   as its own clickable override-redirect window (acceptance check RND-4 proves delivery by
   this path). It is guest-rendered, so *everything* on it works untranslated — buttons,
   quick-reply text boxes, selection dropdowns — because the user's click goes straight into
   the guest window. Cost: it looks like a Windows toast, not a native dom0 notification; it
   exists only while the popup is on screen; in non-seamless mode there is no separate window
   at all (the toast is just pixels inside the one desktop window).
2. **Notification bridge (exists, forward-only, text-only).** `tools/notify-proxy/` sends
   summary+body to the stock R4.3 `qubes.Notifications` service
   ([qubes-notification-proxy](https://github.com/QubesOS/qubes-notification-proxy)). dom0
   renders it origin-marked (`<qube>: …`, qube-colored icon), sanitized server-side. The wire
   protocol *already* carries more than we use: an `actions` field (freedesktop-style
   key/label pairs, strictly validated) and reply tags `Dismissed` and
   `ActionInvoked{id, action}` back to the VM — the proxy's task list marks "handle actions
   being invoked" implemented. Today our client sends `actions count = 0` and ignores tags 3/4.

The owner's question: which toasts should move onto path 2, and can the split be decided
mechanically?

Two wire-level facts from the proxy source that constrain any design
([src/lib.rs](https://github.com/QubesOS/qubes-notification-proxy/blob/main/src/lib.rs)):

- Action **keys** must satisfy `is_valid_action_name`: first byte alphabetic, then only
  alphanumerics, `-`, `.`, `_`, `:`, max 255 bytes. A raw toast `arguments` string
  (`action=reply&convId=42`) does **not** pass (`=`, `&`, spaces). A bridge must therefore
  send *synthetic* keys (`a0`, `a1`, `default`) and keep a guest-side correlation table
  key → (toast id, button index / arguments / activation type).
- `ActionInvoked` returns only `{id, action-key}` — no free text. The freedesktop protocol
  (and hence the dom0 daemon) has **no input-field concept**: a quick-reply box is
  untranslatable to dom0, full stop. (The freedesktop convention for "the user clicked the
  notification body" is the reserved action key `default` —
  [Desktop Notifications Specification](https://specifications.freedesktop.org/notification-spec/latest/).)
  Whether dom0 renders action buttons at all depends on the dom0 daemon's `actions`
  capability (xfce4-notifyd and KDE's daemon both have it); if absent, actions silently don't
  render — the design must not *depend* on a button being visible.

## 1. Q1 — do real toast buttons go beyond "OK / dismiss"? Yes, in a well-defined minority

### 1.1 What a toast can carry (anatomy)

The toast XML is `<toast launch="…" activationType="…"><visual>…</visual><actions>` with **up
to five `<input>` elements and up to five `<action>` buttons**
([action element schema](https://learn.microsoft.com/en-us/uwp/schemas/tiles/toastschema/element-action)).
Each `<action>` has:

- `content` — the button label;
- `arguments` — "app-defined string of arguments that the app will later receive if the user
  clicks this button";
- `activationType` — what a click does:
  - `foreground` (default): launch/activate the app, deliver `arguments`;
  - `background`: invoke the app's background handler, no window ("such as quick reply, your
    app should not launch" — [UX guidance](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-ux-guidance));
  - `protocol`: launch a URI (any registered protocol handler);
  - `system`: handled entirely by the shell — `arguments="snooze"` / `"dismiss"`, including
    an automatic snooze-interval selection box
    ([toast content docs](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/adaptive-interactive-toasts));
- `hint-inputId` (attach button to a text box), `afterActivationBehavior="pendingUpdate"`,
  `placement="contextMenu"`, `hint-buttonStyle` Success/Critical.

`<input>` is `type="text"` (quick reply) or `type="selection"` (dropdown, e.g. snooze
intervals). For classic Win32 senders the click is delivered by COM: the shell CoCreates the
app's registered `ToastActivatorCLSID`
([System.AppUserModel.ToastActivatorCLSID](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-toastactivatorclsid))
and calls
[`INotificationActivationCallback::Activate(appUserModelId, invokedArgs, data[], count)`](https://learn.microsoft.com/en-us/windows/win32/api/notificationactivationcallback/nf-notificationactivationcallback-inotificationactivationcallback-activate),
where `data` is the array of input-element values (the typed reply text). The default banner
lives ~5 s on screen (user-configurable up to 5 min) before moving to the Notification
Center; `scenario="reminder"`/`"incomingCall"`/`"alarm"` toasts stay up until acted on
([Windows Central](https://www.windowscentral.com/how-change-time-notifications-appear-screen-windows-10),
[Windows 11 Forum](https://www.elevenforum.com/t/change-how-long-notifications-stay-open-in-windows-11.819/)).

### 1.2 What real apps actually put on toasts

| App / source | Buttons on the toast | Activation type |
|---|---|---|
| **Windows Update** pending-restart | **Restart now / Pick a time / Restart tonight** — a real, consequential choice ([Microsoft Learn, compliance deadlines](https://learn.microsoft.com/en-us/windows/deployment/update/wufb-compliancedeadlines)) | system component (foreground/background) |
| **Phone Link** (SMS/app notifications) | **inline text reply** — type and send without opening the app ([How-To Geek](https://www.howtogeek.com/434424/windows-10-now-lets-you-reply-to-your-android-notifications/), [Thurrott](https://www.thurrott.com/windows/windows-10/210903/your-phones-android-notification-syncing-now-supports-inline-replies)) | `background` + `input type=text` |
| **Calendar / reminders** (Outlook, Mail, alarms) | **Snooze** (with interval dropdown) + **Dismiss**; RSVP-style selection in Microsoft's own design example ([UX guidance](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-ux-guidance) — its lead image is an event reminder with a "Going" selection + RSVP + Dismiss) | `system` (snooze/dismiss), `foreground` (RSVP) |
| **Chrome/Edge web push** | up to **2 site-defined action buttons** rendered as native toast buttons since Chrome 68 ([BleepingComputer](https://www.bleepingcomputer.com/news/microsoft/google-chrome-now-uses-native-windows-10-notifications/), [PushAlert](https://pushalert.co/blog/google-chrome-68-windows-10-native-notifications/)); most sites send none, so most web toasts are click-to-open | `foreground` (into the browser) |
| **Teams (new)** | optional "Windows" notification style delivers @mentions/messages via native toasts ([Microsoft Tech Community](https://techcommunity.microsoft.com/t5/microsoft-teams-public-preview/now-in-public-preview-windows-10-native-notifications/td-p/1973102)); calls/meeting-join still surface through Teams' own windows; native-style toasts are essentially click-to-open | `foreground` |
| **Slack / Discord** (Electron) | Electron's [NotificationAction](https://www.electronjs.org/docs/latest/api/notification-action) documents buttons on macOS (signed, alert-style) and Windows (via toast XML), but the mainstream chat apps ship plain click-to-open toasts on Windows — no buttons in practice | `foreground` |
| **Security/AV, backup, OEM utilities** | mostly informational; occasional "Run scan"/"Fix now" single button = open-the-app deep link | `foreground` |

### 1.3 Breakdown

No public telemetry exists for "fraction of toasts with buttons"; the honest qualitative
answer, backed by the table:

- **By volume**, the large majority of toasts a desktop user receives (chat messages, mail
  arrivals, web push without actions, status/info toasts) are **informational**: zero
  buttons, or dismiss-only. Their one interaction is the **default body click**, which is
  itself a *foreground deep-link activation* (open this chat / this mail) — informational
  toasts still carry one implicit action.
- **By importance**, the buttoned minority is disproportionately high-value and clearly
  clustered: restart/update choices, snooze/dismiss reminders, RSVP, quick-reply, incoming
  call accept/decline. These are exactly the "meaningful choice" class the owner
  hypothesized, and two of them (quick reply, snooze) are **structurally untranslatable** to
  a dom0 notification (input box; shell-internal rescheduling).

So the owner's premise holds: buttons that matter exist, they are a minority, and they
concentrate in recognizable scenario classes.

## 2. Is the split mechanically decidable?

**Decidable in content, not via the supported reading API.** The toast XML separates the two
classes perfectly (§2.2). The problem is what a listener is allowed to *see*:

### 2.1 The three ways to read another app's toast

1. **`UserNotificationListener`** (the documented cross-app API,
   [notification listener docs](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/notification-listener)):
   gives `AppInfo` (AUMID, display name, logo), `CreationTime`, `Id`, and the **visual
   binding's text elements only** (`GetBinding(KnownNotificationBindings.ToastGeneric)
   .GetTextElements()`). Microsoft confirms the gap explicitly: *"there is no such api could
   access toast button actions etc. and only access part is text element such as title and
   body"* ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/836756/how-to-access-actions-buttons-from-windows-ui-noti)).
   It **cannot see buttons, inputs, activation types, or the launch args.** Requirements:
   the `userNotificationListener` capability in an app manifest → the reader needs **package
   identity** (for our Win32 agent: packaging-with-external-location / sparse package,
   [MS docs](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps);
   unpackaged callers get *element not found*,
   [field report](https://www.answeroverflow.com/m/1260371813678977145)); one-time user
   consent via `RequestAccessAsync` (revocable in Settings; APIs then *silently* return
   empty — a vacuity trap our harness rules already know to fear). It is a **per-user,
   interactive-session** surface: the consent store and the notification platform are per
   user, so the reader runs in the logged-on session — same placement as the user-session
   broker the WGC work already requires, not in the SYSTEM service. On this project's
   autologon testbeds the consent can be pre-seeded
   (`HKCU\...\CapabilityAccessManager\ConsentStore\userNotificationListener`,
   `Value=Allow` — well-known but undocumented; *(verify on rig)*).
   Write-side, the listener DOES have two verbs: **`RemoveNotification(id)`** and
   `ClearNotifications()` — i.e. cross-app *dismiss* is a supported operation.
2. **The WNS platform database** `%LocalAppData%\Microsoft\Windows\Notifications\
   wpndatabase.db` (SQLite): the `Notification` table's **`Payload` column holds the full
   toast XML — including `<actions>`, `arguments`, `activationType`, `<input>`** — joined to
   `NotificationHandler` for the owning AUMID. Extensively documented by the forensics
   community ([artefacts.help](https://artefacts.help/windows_wpndatabase_db.html),
   [swiftforensics](http://www.swiftforensics.com/2016/06/prasing-windows-10-notification-database.html),
   [kacos2000](https://github.com/kacos2000/Win10/blob/master/Notifications/readme.md),
   [MDPI journal article](https://www.mdpi.com/2673-6756/2/1/7)). Undocumented internal
   state: schema has changed across Windows versions (it *did* survive 1607→11 with the same
   core tables), WAL mode while ShellExperienceHost holds it (read-only open works; a
   fresh row may still sit in the `-wal`), and correlation to a listener event is by
   AUMID + arrival time + text match, not by a shared key. Read-only, same-user access — no
   privilege issue. This is the **only** cross-app source of the action set + arguments.
3. **UI Automation on the shell's toast popup** (`ShellExperienceHost` hosts the banner; a
   click lands there — [microsoft-ui-xaml #5499](https://github.com/microsoft/microsoft-ui-xaml/issues/5499)):
   can enumerate the rendered buttons (labels only, no arguments) and `Invoke` them. But it
   requires the banner to be *on screen* — useless for classifying **before** deciding
   whether the banner should have been suppressed, and racy within the ~5 s display window.

### 2.2 The classifier (given the XML)

With the payload XML in hand the split is a short, total decision table — evaluated
top-down, first match wins:

| Toast content | Verdict | Why |
|---|---|---|
| any `<input type="text">` | **window path** | reply text cannot cross the bridge (no input field in the freedesktop model) |
| any `<input type="selection">`, or any `activationType="system"` action with `arguments="snooze"` | **window path** | snooze rescheduling is shell-internal; not reproducible externally |
| `scenario="incomingCall"`/`"alarm"`/`"reminder"`, or `afterActivationBehavior="pendingUpdate"`, or a `<progress>` element | **window path** | time-critical / self-updating surfaces; a static dom0 copy misleads |
| any `<action>` with `activationType="foreground"` or `"background"` (non-system) | **window path** under the owner's split (it is a real choice); *bridgeable-with-risk* under Proposal B/C via activator re-invocation | the return path is the hard half, §3 |
| only `activationType="protocol"` actions | **bridgeable** even with buttons | return path is just launching a URI in the guest — documented and robust |
| only a system `dismiss` action, or no `<actions>` at all | **bridge** — informational | the implicit default click can be approximated (§3); dom0 dismissal maps to `RemoveNotification` |

Edge cases: `placement="contextMenu"` actions are auxiliary — presence alone should not
force the window path (they are invisible on the banner anyway); a toast with buttons *and*
a text box is window-path by row 1; an empty-`<actions>` toast with a `launch=` deep link is
still informational (the deep link only enriches the default click).

### 2.3 Decidability verdict

- **Per-toast, from content: YES** — the table above is total and unambiguous; nothing in it
  requires judgment. But the *supported* reading API cannot feed it (no actions exposed), so
  a per-toast classifier must read `wpndatabase.db` (undocumented, version-coupled) or
  UIA-peek (racy). Additionally, per-toast routing has a **suppression race** on the window
  path side: by the time the listener event + XML read + verdict complete, the o-r banner
  window has already mapped in dom0 for tens–hundreds of ms; un-showing it after the fact is
  a visible flash. The agent's existing map-defer machinery (built for menu crops) could hold
  toast-class windows ~250 ms pending a verdict *(verify on rig)*, at the price of coupling
  the agent to the classifier's latency.
- **Per-app: YES, cleanly, with supported mechanisms only.** Route by AUMID: apps whose
  toasts are known informational get `ShowBanner=0` under
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\<AUMID>`
  (notification goes straight to the Notification Center, **no banner renders, so no o-r
  window ever maps — no race, no flash**; the listener still fires;
  [Windows 11 Forum tutorial](https://www.elevenforum.com/t/turn-on-or-off-show-notification-banners-from-apps-in-windows-11.6214/))
  and are bridged from the listener event. Every other app keeps today's window path
  untouched. Misclassification is **fail-open**: an unknown or doubtful app stays on the
  window path, i.e. exactly today's behavior — the split can never *lose* functionality,
  only decline to prettify.
- The fail-open property is what makes the owner's split sound: the classifier does not need
  to be perfect, only *conservative*.

## 3. The return path, honestly, per activation type

`ActionInvoked`/`Dismissed` arrive from dom0 over the (kept-open) qrexec connection. What can
a guest agent then actually do?

| Click semantics | Feasible mechanism | Assessment |
|---|---|---|
| **Dismiss** (dom0 user dismissed the notification) | `UserNotificationListener.RemoveNotification(id)` — documented | **easy, safe**; keeps guest Notification Center in sync |
| **Default body click** ("open it") | (a) best-effort: activate/foreground the sender's window (AUMID → window); (b) faithful: re-invoke the activator with the toast's `launch` args | (a) is supported-API-only and right ~90 % of the time; (b) needs the XML (wpndatabase) |
| **`protocol` button** | read the URI from `arguments`, `ShellExecute` it | **feasible and faithful** — this is all the shell does |
| **`foreground`/`background` button** (Win32 sender) | CoCreate the sender's `ToastActivatorCLSID` (from the AUMID registration) and call `INotificationActivationCallback::Activate(aumid, arguments, data, count)` — exactly the shell's own call | **technically faithful, practically fragile**: needs the `arguments` string (only via wpndatabase), and some apps validate their activation context; per-app breakage is silent |
| **`foreground` button** (UWP sender) | `IApplicationActivationManager::ActivateApplication` can launch by AUMID with args, but that is a *launch* activation, not a toast activation — apps that check `ToastNotificationActivatedEventArgs` will mishandle it | **not reliable** |
| **`system` snooze** | none (shell-internal timer state); UIA-clicking the Notification Center entry is the only emulation | **not feasible** — window path |
| **Text reply** | none over the bridge (no dom0 input field). UIA `ValuePattern` + Invoke on a still-visible banner is a demo, not a product | **not feasible** — window path |
| **UIA on the banner / Notification Center** (any type) | Invoke the real button — activation-type-agnostic | banner: ~5 s lifetime, gone before a human round-trips through dom0; Notification Center: buttons persist, but driving it opens the center — in seamless mode that itself maps o-r windows in dom0 (visible artifact). A last-resort mechanism, not an architecture |

Lifecycle note: the mechanisms that matter (RemoveNotification, protocol launch, COM
re-invocation) do **not** need the banner to still exist — the correlation table plus the
persisted XML outlive it — so the "toast expires before the dom0 click arrives" objection
kills only the UIA variants. What does expire is *relevance* (an "incoming call" answered
late), which is one more reason time-critical scenarios stay on the window path (§2.2).

Return-path plumbing (all proposals except A0 share it): a **resident user-session agent**
holding one long-lived qrexec connection (the Linux `qubes-notification-agent` holds exactly
one; our `qubes-updates-relay.cs` proves the QWT channel shape at ~13 MB/s duplex), a
correlation table `bridge-id ↔ {guest notification Id, AUMID, per-button synthetic key →
arguments/activationType}`, and reconnect-with-`ServerRestart` handling. Politeness is the
client's job (the dom0 side is deliberately unlimited; coalesce, never loop).

## 4. Proposals

### A0 — status quo plus (forward-only, per-app allowlist; the owner's split, minimal form)

Informational **apps** (allowlisted AUMIDs, default OFF for unknown apps) get
`ShowBanner=0` + listener→bridge forwarding of summary/body; a dom0 dismissal is echoed back
as `RemoveNotification` (this one reply tag is worth consuming even in the minimal build).
Everything else — every app with buttons, every unknown app — stays on the window path
untouched.

- Components: user-session listener host (sparse-package identity + pre-seeded consent),
  resident bridge process (evolve NotifyClient from per-message to resident), allowlist in
  the agent config; **no XML reading, no wpndatabase, no per-toast classifier**.
- Feasible entirely on documented APIs (the consent-seeding registry key is the one
  undocumented convenience, and it has a settings-UI fallback).
- Fragile at: consent silently revoked (listener returns empty — needs a self-test, the
  detector-proof rule applies), duplicate delivery in non-seamless mode is *solved* by
  `ShowBanner=0`; the allowlist is maintenance.
- Effort: small. Risk: low. Loses: dom0 click does nothing (no default action sent).

### A1 — the owner's split, per-toast (forward-only + real-choice-stays-on-window)

As A0, but classification is per-toast via the §2.2 table, fed by `wpndatabase.db`; buttoned
toasts keep their banner (window path), buttonless ones are bridged and their banner
suppressed. Requires either accepting a brief o-r banner flash in dom0 or teaching the agent
a toast-class map-defer (~250 ms) while the verdict races *(verify on rig)*.

- Adds: XML reader + schema-drift risk, the flash/defer complication.
- Buys over A0: informational toasts from *buttoned apps* (e.g. a mail app whose reminders
  have buttons but whose mail arrivals do not) also get native rendering.
- Assessment: the owner's split is **sound** as a policy, but per-toast enforcement buys
  little over per-app enforcement and pays the two worst costs (undocumented DB on the hot
  path, map-defer coupling). If A1 is wanted, do it as an A0 refinement later, not first.

### B — full bidirectional bridge

Bridge (nearly) everything; translate buttons to dom0 actions (synthetic keys, §0); on
`ActionInvoked` re-invoke per §3 (protocol → ShellExecute; foreground/background → COM
activator re-invocation with wpndatabase-sourced arguments; default → activator/foreground
fallback). Only §2.2 rows 1–3 (text input, snooze/selection, time-critical) remain on the
window path — they are untranslatable regardless of effort.

- Components: everything in A0 + XML reader + re-invocation engine + per-app compatibility
  knowledge; dom0-daemon `actions` capability dependence for the buttons to even render.
- Assessment: **not recommended.** The re-invocation half rests on undocumented state
  (wpndatabase payload) and on third-party activators tolerating an out-of-shell caller;
  failures are silent and per-app ("clicked Archive in dom0, nothing happened in the
  guest"), which is worse than a button that was never offered. The window path already
  delivers 100 % fidelity for exactly the toasts B struggles with — B spends its entire risk
  budget re-implementing something that works.

### C — recommended hybrid: A0 now, "default click" next, per-toast never (unless data demands it)

1. **Phase 1 = A0** (per-app, forward-only, dismiss-sync). Ship, measure how much of the
   real toast stream it covers on the testbeds.
2. **Phase 2**: add one synthetic dom0 action, `default` ("Open"), mapped on return to
   best-effort app activation (foreground the sender's window; no wpndatabase). This makes
   the dom0 rendering *useful*, not just informative, still on supported APIs only. The
   long-lived connection and correlation table from §3 arrive here.
3. **Phase 3 (optional, data-driven)**: per-toast refinement (A1) and/or protocol-button
   translation (the one faithful button type) for specific high-value apps, if Phase-1
   telemetry shows allowlisted apps emitting buttoned toasts worth more than the DB-reader
   risk.

Real-choice toasts stay on the seamless window path **permanently** — not because they are
"too hard" in the vague sense, but for the specific reasons in §3: text input and snooze are
structurally untranslatable, and foreground/background re-invocation is the only bridge for
the rest and is not trustworthy cross-app.

## 5. Recommendation

Adopt **Proposal C**. The owner's split is directionally correct and, made *per-app* with
fail-open defaults, it is mechanically decidable with supported APIs alone; made *per-toast*
it is decidable only by leaning on an undocumented database plus a suppression race, for
marginal gain. The one refinement to the owner's framing: the boundary is not
"informational vs has-a-real-choice" as a translation-difficulty judgment — it is a hard
API boundary (inputs and snooze cannot cross; protocol buttons could; the listener cannot
even *see* the difference), and the per-app fail-open classifier respects that boundary
without ever having to look at it on the hot path.

Non-seamless mode note: the bridge is at its most valuable there (toasts are otherwise
pixels inside one desktop window, missable when minimized), and `ShowBanner=0` prevents the
double rendering; the window-path half of the split, however, only exists in seamless mode —
in non-seamless, real-choice toasts simply remain in-desktop as today.

Security framing stays as the notify-proxy README established: dom0 renders sanitized,
origin-marked text; bridged action *labels* are guest strings sanitized server-side; a dom0
button click only echoes a validated key string back to the origin VM — no dom0-side
execution, no new surface. Nothing here weakens the "never render guest content as dom0
authority" rule.

## 6. Sources

- [Notification listener (UserNotificationListener) — Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/notification-listener)
- [Microsoft Q&A: How to access actions/buttons from UserNotification — "no such api"](https://learn.microsoft.com/en-us/answers/questions/836756/how-to-access-actions-buttons-from-windows-ui-noti)
- [toast `action` element schema — Microsoft Learn](https://learn.microsoft.com/en-us/uwp/schemas/tiles/toastschema/element-action)
- [App notification content (interactive toasts, system snooze/dismiss) — Microsoft Learn](https://learn.microsoft.com/en-gb/windows/apps/develop/notifications/app-notifications/adaptive-interactive-toasts)
- [Notifications design basics (UX guidance: buttons, quick reply, progress) — Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/app-notifications-ux-guidance)
- [INotificationActivationCallback::Activate — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/notificationactivationcallback/nf-notificationactivationcallback-inotificationactivationcallback-activate)
- [System.AppUserModel.ToastActivatorCLSID — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-toastactivatorclsid)
- [Grant package identity by packaging with external location — Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps)
- [UserNotificationListener from unpackaged app: "element not found" — field report](https://www.answeroverflow.com/m/1260371813678977145)
- [wpndatabase.db — artefacts.help](https://artefacts.help/windows_wpndatabase_db.html) · [swiftforensics](http://www.swiftforensics.com/2016/06/prasing-windows-10-notification-database.html) · [kacos2000/Win10](https://github.com/kacos2000/Win10/blob/master/Notifications/readme.md) · [MDPI: A Digital Forensic View of Windows 10 Notifications](https://www.mdpi.com/2673-6756/2/1/7)
- [Windows Update restart toast (Restart now / Pick a time / Restart tonight) — Microsoft Learn](https://learn.microsoft.com/en-us/windows/deployment/update/wufb-compliancedeadlines)
- [Phone Link inline reply — How-To Geek](https://www.howtogeek.com/434424/windows-10-now-lets-you-reply-to-your-android-notifications/) · [Thurrott](https://www.thurrott.com/windows/windows-10/210903/your-phones-android-notification-syncing-now-supports-inline-replies)
- [Chrome 68 native Windows toasts — BleepingComputer](https://www.bleepingcomputer.com/news/microsoft/google-chrome-now-uses-native-windows-10-notifications/) · [PushAlert (2 action buttons)](https://pushalert.co/blog/google-chrome-68-windows-10-native-notifications/)
- [Teams native Windows notification style — Microsoft Tech Community](https://techcommunity.microsoft.com/t5/microsoft-teams-public-preview/now-in-public-preview-windows-10-native-notifications/td-p/1973102)
- [Electron NotificationAction platform support](https://www.electronjs.org/docs/latest/api/notification-action)
- [Toast banner display time (5 s default, up to 5 min) — Windows Central](https://www.windowscentral.com/how-change-time-notifications-appear-screen-windows-10) · [Windows 11 Forum](https://www.elevenforum.com/t/change-how-long-notifications-stay-open-in-windows-11.819/)
- [Per-app ShowBanner registry (banner off, Notification Center kept) — Windows 11 Forum](https://www.elevenforum.com/t/turn-on-or-off-show-notification-banners-from-apps-in-windows-11.6214/)
- [Toast click lands in ShellExperienceHost — microsoft-ui-xaml #5499](https://github.com/microsoft/microsoft-ui-xaml/issues/5499)
- [qubes-notification-proxy (protocol, action validation, ActionInvoked) — QubesOS GitHub](https://github.com/QubesOS/qubes-notification-proxy)
- [Desktop Notifications Specification (freedesktop; `default` action, actions capability)](https://specifications.freedesktop.org/notification-spec/latest/)

## Implementation plan (Proposal C)

Status: **plan only, no code.** Written 2026-09-04. This turns §4-C into concrete, phased work.
It is deliberately grounded in code that already exists in this repo rather than in greenfield
components — most of Proposal C's hard parts are already built for other reasons:

- **`tools/notifhost/notifhost.cpp`** is *already* a resident, user-session
  `UserNotificationListener` host: it calls `UserNotificationListener::Current()` +
  `RequestAccessAsync()` (comment records the result **proven `Allowed`** on the guest), polls
  `GetNotificationsAsync(NotificationKinds::Toast)` at 800 ms, primes its `seen` set on the first
  pass so it never replays the backlog, extracts title/body via
  `GetBinding(ToastGeneric).GetTextElements()` (`FirstTexts()`), and exits when the agent process
  dies (`--agent-pid` → `OpenProcess(SYNCHRONIZE)`) or the console session changes. Today it
  *renders each new toast as an in-guest bordered GDI window* (the de-slice window path). Proposal
  C **extends this same process** with a second output route (forward to dom0) instead of adding a
  new listener host. This is the single most important grounding fact: the "resident user-session
  agent" §3 calls for is not new — it is a mode switch inside notifhost.
- **`tools/notify-proxy/NotifyClient.cs`** is the proven `qubes.Notifications` wire client:
  handshake, bincode-1.x fixint LE framing, `qrexec-client-vm @default|qubes.Notifications|<user>|…`,
  spool/result files, reply-tag demux. It already *reads* reply tags 3/4 (`Dismissed`,
  `ActionInvoked`) and currently discards them; the encoder already has the `actions` slot
  (hard-wired count 0). The return path is a small extension of code that exists, not a rewrite.
- **The wgcbroker launch/supervise pattern** (`agent/gui-agent/main.c` `WgcLaunch` ~L2081,
  `BrokerSupervise` ~L2132) is the proven way the SYSTEM agent gets a helper into the interactive
  session: **Task Scheduler `/ru <user> /it`** (CreateProcessAsUser is documented there as
  insufficient for WGC), with liveness inferred from a heartbeat, and a **feature gate** read at
  init from registry + qubesdb `/qubes-service/<name>` (dom0 wins), default OFF. notifhost is
  already spawned by the agent this way for the de-slice window path.
- **`guest/fire-toast.ps1`** (fires a `scenario="reminder"` toast with OK/Later buttons — a
  *window-path* fixture) and **`guest/dismiss-toast.ps1`** (clears toast history from the **user**
  session — proving history mutation is per-user, session-bound) are ready-made rig fixtures.

The design decision that makes the phasing clean: **route by output, not by a new process.**
notifhost stays the one resident listener; for an allowlisted AUMID it *forwards to dom0 and
suppresses the banner*; for everything else it keeps doing exactly what it does today. "Fail-open"
is therefore literal — the default branch is the current code path, byte for byte.

### P.1 — Components and where they live

| Component | Home | Session / privilege | Status |
|---|---|---|---|
| **Notification router** (listener + allowlist + route decision + correlation table + reply demux) | extend `tools/notifhost/notifhost.cpp` | interactive **user** session | listener + loop + session/agent-liveness EXIST; add routing + forward + return |
| **Listener feed** (`UserNotificationListener`) | notifhost, as today | user session (per-user consent store) | EXISTS, access proven `Allowed` |
| **Allowlist + master gate** | qubesdb `/qubes-service/notify-bridge` = master on/off (dom0 wins, default OFF, mirrors `wgc-broker`); AUMID list in a guest-side config (registry multi-string under the gui-agent config key, or a file pushed via qrexec — the Phase-2B "config pushed via qrexec" precedent) | read by notifhost at startup + on change | NEW (small) |
| **Banner suppression** (`ShowBanner=0`) | `HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\<AUMID>\ShowBanner=DWORD 0`, written by notifhost (user session = correct hive) for each allowlisted AUMID **while it is alive**, removed on clean exit | user session | NEW (small); lifecycle is a named risk, see P.6 |
| **Long-lived qrexec connection** to `qubes.Notifications` | a thin `--relay` endpoint spawned by notifhost via `qrexec-client-vm` whose stdio (the vchan) is spliced to a local named pipe back to the resident notifhost (the `guest/qubes-updates-relay.cs` splice shape, proven ~13 MB/s duplex); the **wire protocol lives in notifhost** (ported from `NotifyClient.cs`) so all protocol + correlation state sits in one process | user session | NEW; splice + wire-encode both have working precedents |
| **Correlation table** `proxy-id (u64 seq) ↔ { guest notification Id (u32), AUMID, synthetic-key → activation }` | in-memory in notifhost, with expiry | user session | NEW (small) |
| **Agent side** | nothing new in `agent/gui-agent` beyond the existing notifhost spawn/supervise; the agent already launches notifhost and never sees bridged toasts (they map no window) | SYSTEM | EXISTS |

Consent/packaging reality, stated honestly: `UserNotificationListener` requires the
`userNotificationListener` capability, which requires **package identity** — an unpackaged Win32
exe gets *element not found*. notifhost's own comment says access is **proven `Allowed`** on this
guest, which means one of: (a) it is already running with a sparse/external-location package
identity, or (b) the testbed's autologon image has the consent pre-seeded and identity is being
granted some other way. **This must be pinned down before A0 ships** (P.5 selftest), because the
whole bridge is silent if the listener returns empty. The documented path to guarantee it is a
*packaging-with-external-location sparse package* granting identity + a pre-seeded
`HKCU\…\CapabilityAccessManager\ConsentStore\userNotificationListener = Allow`. Running a
package-identity process is the real cost here; it is the same cost the WGC broker work already
weighed, and notifhost apparently already pays it — verify, do not assume.

### P.2 — The fail-open boundary, in code

The decision lives at exactly one point: notifhost's poll loop, where a *new* toast is seen
(today the `seen.insert(id).second && primed` branch that calls `ShowToast`). It becomes:

```
on new toast un (AUMID = un.AppInfo().AppUserModelId, Id = un.Id()):
    if bridge_master_gate_off:            -> ShowToast(...)          // today's in-guest window
    else if AUMID not in allowlist:       -> ShowToast(...)          // fail-open: unchanged
    else if listener/consent unhealthy:   -> ShowToast(...)          // fail-open on any doubt
    else:                                 -> Forward(un)             // bridge; banner already off
```

Properties that make this sound:
- **The default arm is literally today's code.** No allowlisted+healthy match ⇒ nothing changes.
- **Structurally-untranslatable toasts never reach the bridge**, and not because notifhost
  inspects them (the listener cannot see inputs/actions anyway, §2.1): quick-reply and snooze
  toasts come from apps that are simply not put on the informational allowlist. Per-app routing
  sidesteps the "listener can't classify" problem entirely — the classification is the allowlist.
- **No suppression race** (§2.3): `ShowBanner=0` means the o-r banner never maps in dom0, so there
  is nothing to un-map; the listener still fires. This is why C is per-app, not per-toast.
- Any exception in the forward path falls through to `ShowToast` — a bridge fault degrades to the
  window path, never to a dropped notification (subject to the ShowBanner lifecycle risk, P.6).

### P.3 — The two directions

**Forward (listener → dom0).** On a bridged toast: allocate a proxy sequence id, record
`{seq ↔ guest Id, AUMID}` in the correlation table, and send one `Notification::V1` frame over
the held connection with `summary`/`body` from `FirstTexts()`. Phase 1 sends `actions count 0`
(exactly NotifyClient today). Phase 2 sends `actions = ["default", "Open"]` (one synthetic
freedesktop `default` key + a label; `default` trivially passes `is_valid_action_name`). Server
sanitizes and origin-marks; nothing changes on the security boundary (§5).

**Return (dom0 → guest), minimal and honest.** Replies arrive async on the held connection,
tagged by the proxy `id`, demuxed through the correlation table:

| Reply | Action in guest | Limit |
|---|---|---|
| `Dismissed{id}` (tag 3) | `UserNotificationListener.RemoveNotification(guest Id)` — documented | keeps the guest Notification Center in sync; safe |
| `ActionInvoked{id,"default"}` (tag 4, **Phase 2 only**) | best-effort **foreground the sender**: AUMID → running window (or `IApplicationActivationManager::ActivateApplication` to launch) and `SetForegroundWindow` | ~90% right; **not** a faithful toast activation — no `launch` args, no COM re-invocation (that needs wpndatabase, deferred to Phase 3); apps that key off `ToastNotificationActivatedEventArgs` won't get it |
| any other tag | ignore/log | — |

The honest ceilings, restated so the plan cannot quietly overreach: **text reply and snooze never
cross** (no dom0 input field; shell-internal timer) — those apps stay off the allowlist, on the
window path, permanently. **Foreground/background button re-invocation is Phase-3-optional and
fragile** (§3). The bridge's contract to the user is: informational text in a native dom0
notification, dom0-dismiss stays in sync, and (Phase 2) one "Open" that raises the app.

### P.4 — Phasing (each phase independently shippable and testable)

- **Phase A0 — first shippable slice** *(allowlist + banner-off + forward text + dismiss-sync;
  documented APIs only)*. Extend notifhost with: master gate + AUMID allowlist read; `ShowBanner=0`
  apply/restore; the long-lived connection (relay splice + ported wire encode); forward
  summary/body with `actions=0`; consume `Dismissed` → `RemoveNotification`; correlation table
  (`seq ↔ guest Id`) with expiry; a consent/health selftest that forces fail-open when the
  listener is unhealthy. **Note:** dismiss-sync is what forces the *long-lived, single* connection
  into A0 (you must read an async reply tag that arrives after the ack) — this refines §3's "return
  plumbing is Phase-2-onward" line: the *plumbing* (one held connection + reply demux) lands in A0;
  only *actions* are deferred.
- **Phase 2 — the synthetic default action** *("Open")*. Send `actions=["default","Open"]`; on
  `ActionInvoked{"default"}` do best-effort app foreground. Extends the correlation table with
  `synthetic-key → activation`. Still supported-APIs-only (no wpndatabase). Makes the dom0
  rendering *actionable*, not just informative. Independently shippable: if dom0's daemon lacks the
  `actions` capability the button silently doesn't render and A0 behavior is unchanged.
- **Phase 3 — optional, data-driven** *(only if Phase-1 telemetry shows allowlisted apps emitting
  buttoned toasts worth the risk)*. Either (a) `protocol`-button translation — the one *faithful*
  button type: read the URI, `ShellExecute` it in the guest; or (b) per-toast refinement (A1) via
  `wpndatabase.db`. Both carry the undocumented-DB / cross-app-activator risk §2-3 warned about;
  neither is committed to by adopting C.

Real-choice toasts (text reply, snooze, incoming-call/alarm/reminder, and any app not on the
allowlist) **remain on the seamless window path permanently** — by omission from the allowlist,
which needs no code.

### P.5 — Testing / acceptance (fits the qtest / protocol style)

Every check needs a **real logged-on session** (the listener and the qrexec handler are both
session-bound) — the autologon testbeds (`win10-app`, a Win11 app qube) provide it. Verify pixels
on the dom0 screen, not logs, per CLAUDE.md.

Fixtures:
- **Buttonless informational toast** (the bridge's happy path) — extend `guest/fire-toast.ps1`
  into a `-Informational` variant that emits a `<toast>` with `<text>` only, **no `<actions>`**,
  under a *distinct AUMID* we then put on the allowlist. (The existing OK/Later fixture becomes the
  *window-path control* — it must stay a bordered window and must **not** bridge.)
- Real informational senders that make good fixtures: any app whose status toasts carry no
  buttons — e.g. a browser download-complete toast, or PowerShell's own `New-BurntToast`-style
  informational toast. Chat/mail arrivals are the archetype but need the app installed.

Per-phase acceptance:
1. **Consent/health selftest (gates everything, must be seen to FAIL).** With the listener healthy:
   selftest reports OK and an allowlisted toast bridges. Revoke consent (or corrupt the identity):
   selftest must report unhealthy **and routing must fall back to the window path** (toast still
   appears as a guest window) — not vanish. Per the evidence rules, prove this branch by
   deliberately breaking consent, not by assuming.
2. **A0 forward.** Fire the informational fixture (allowlisted AUMID) → a dom0 notification appears,
   origin-marked `<qube>: <summary>`, qube-colored icon (reuse `notify-proxy` TEST PLAN step 4);
   **and** `qtest shot` shows **no** in-guest toast window for it (banner suppressed, not
   duplicated). Fire the OK/Later control (not allowlisted) → `qtest shot` shows it as a bordered
   guest window and **no** dom0 notification. Both in the same run.
3. **A0 dismiss-sync.** Dismiss the dom0 notification → the guest Notification Center entry is gone
   (query `UserNotificationListener.GetNotificationsAsync` from the user session, à la
   `dismiss-toast.ps1`); prove the reverse (no dismiss ⇒ entry persists) so the check can fail.
4. **A0 fail-open regressions.** Master gate OFF ⇒ *every* toast is a guest window (identical to
   pre-bridge baseline `qtest shot`). Unknown AUMID ⇒ window path. Kill the relay/connection
   mid-run ⇒ subsequent toasts fall back to the window path (this is the ShowBanner-lifecycle
   test, P.6 — confirm banners actually return).
5. **A0 boot path.** Cold-boot the guest (not just an agent restart), fire the fixture → still
   bridges. notifhost must come up under Task Scheduler and re-apply `ShowBanner=0` on boot.
6. **Phase 2 default action.** Bridged toast shows an "Open" button in dom0 (if the daemon renders
   actions); click → the sender app comes to the foreground in the guest (`qtest shot`). If the
   daemon has no `actions` capability, confirm A0 behavior is unchanged (graceful absence).
7. **Politeness.** Fire N informational toasts back-to-back over the *single* held connection; all
   are attributed; the connection is reused (not one per toast). No hot loop (the churn wedge).

### P.6 — Risks and open questions, with effort

Top risks (ranked):
1. **`ShowBanner=0` + dead bridge = silent notification loss (fail-CLOSED for allowlisted apps).**
   If notifhost writes `ShowBanner=0` and then dies, an allowlisted app neither banners nor
   forwards — the one place the "fail-open" promise can break. Mitigations to build into A0:
   notifhost restores `ShowBanner` on clean exit; the agent's existing supervisor treats a stale
   notifhost heartbeat as a trigger to *not* leave suppression in place; and/or suppress a given
   AUMID's banner **only after** its first successful forward (lazy suppression), so a bridge that
   never comes up never suppresses. This must be tested (P.5 step 4), not assumed.
2. **Listener consent / package identity in an unpackaged guest.** The whole bridge is vacuous if
   `GetNotificationsAsync` silently returns empty (revoked consent, lost identity). notifhost claims
   `Allowed` today — but *why* it is allowed must be pinned (sparse package? pre-seeded consent?),
   and a health selftest that forces fail-open is mandatory (P.5 step 1). This is the single biggest
   unknown.
3. **Allowlist maintenance + AUMID stability.** Per-app routing is only as good as the list;
   AUMIDs vary (packaged apps vs Win32 `{GUID}\…\app.exe` forms), and a mistargeted entry either
   over-suppresses (risk 1) or does nothing. Needs a documented way to discover an app's AUMID
   (the listener already exposes `AppInfo.AppUserModelId` — a `--dump-aumids` mode in notifhost is
   cheap) and a dom0-controlled master gate so the whole feature is one flag off.

Open questions: correlation-table lifecycle — evict on `Dismissed`, on `RemoveNotification`, and on
a TTL (toasts expire from the Notification Center; a stale `seq` must not resurrect a wrong Id);
banner-off scope — per-AUMID is documented, but confirm it does not also suppress the Notification
Center entry we rely on for dismiss-sync (it should not — `ShowBanner` is banner-only); relay
splice under many rapid notifications (proven at MB/s for updates, but notification cadence is
human-rate, so cadence is not the worry — connection *reconnect* on `ServerRestart` is).

Rough effort (single engineer, excluding rig-time):
- **A0:** ~1.5-2.5 sessions. Bulk is the long-lived connection (relay splice + porting the ~150-line
  wire encoder from `NotifyClient.cs` into notifhost) and the ShowBanner lifecycle + selftest; the
  route decision and correlation table are small.
- **Phase 2:** ~0.5-1 session. `actions=["default","Open"]` + `ActionInvoked` demux exist in
  skeleton; best-effort foreground (AUMID → window / `ActivateApplication`) is the only new muscle.
- **Phase 3:** deferred, ~2+ sessions if ever (wpndatabase reader *or* protocol-launch + per-app
  compatibility), gated on Phase-1 telemetry justifying it.
