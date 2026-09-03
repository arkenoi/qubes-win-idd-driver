# notify-proxy — Windows client for the existing `qubes.Notifications` dom0 service

A minimal Windows-guest client that sends arbitrary text to the **existing** Qubes
dom0-rendered notification service. **No dom0 service, script, or policy of ours is involved
anywhere** — upstream Qubes R4.3 already ships both the service and the allow policy; we only
wrote the VM-side caller (the piece the Linux `qubes-notification-agent` package provides for
Linux qubes, minus the D-Bus bridge).

## Target service

`qubes.Notifications`, implemented by
[QubesOS/qubes-notification-proxy](https://github.com/QubesOS/qubes-notification-proxy)
(the resolution of qubes-issues #889 "Centralized Tray Notifications", in the R4.3 release
notes). Present on every stock R4.3 GUI dom0: the `qubes-gui-daemon` RPM `Requires:
qubes-notification-daemon`, which installs `/etc/qubes-rpc/qubes.Notifications`
(symlink to `/usr/bin/qubes-notification-proxy-server`) plus an rpc-config with
`wait-for-session=1`.

**Stock policy — already enabled, the owner changes NOTHING** (qubes-core-admin,
`qubes-rpc-policy/90-default.policy` line 68, present on release4.3):

```
qubes.Notifications     *           @anyvm          @default    allow target=dom0
```

The client requests target `@default` (never an explicit `dom0`): that is the form the stock
rule matches, and it is also what lets the GuiVM salt rule redirect notifications to sys-gui
on GuiVM systems.

## What the SERVICE handles vs what the CLIENT handles

Server-side (dom0, enforced there — the client cannot influence any of it):

- **Origin marking, unforgeable**: the qube name comes from `QREXEC_REMOTE_DOMAIN` set by
  qrexec itself. Summary is rendered as `<qube>: <text>`, app name `Qube: <qube>`, icon =
  the qube's label icon. The wire protocol has **no app-name or icon fields at all**, so a
  malicious guest cannot spoof identity — this is what makes "dom0 renders guest text" safe.
- **Sanitization**: code points filtered through libqubes-pure's display-safe allowlist
  (same list as window titles; rejects become U+FFFD), CR normalized, lines capped at 1000
  chars, text at 500 lines, markup entity-escaped, action names/categories/hints strictly
  validated, images validated and currently discarded, frames capped at 16 MiB.
- **NOT rate-limited**: a guest can flood. Upstream accepted that with the default-allow
  policy (attribution makes the offender obvious). Polite coalescing is the client's job —
  do not put this client in a hot loop.

Client-side (all this tool does): correct handshake and framing, valid UTF-8, plain text
only (markup renders literally), one qrexec connection per notification. **No client-side
sanitization by design** — it would duplicate the trust boundary the server already enforces
on its own side of the vchan.

## Files

- `NotifyClient.cs` — the whole client, C# 5, compiles with the in-box
  `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`. One exe, two roles:
  launcher (`--send` / `--send-file`) and qrexec local handler (`--handler`).
- `send-notification.ps1` — convenience wrapper: compiles if needed, sends.

## Exact invocation

The launcher runs (all four fields UNQUOTED as one pipe-string — qrexec-client-vm's
`GetArgument()` splits the raw command line on `|` and does not strip quotes; an outer quote
leaks into the target field and dom0 refuses; quotes *inside* field 4 are fine):

```
"C:\Program Files\Qubes Tools\bin\qrexec-client-vm.exe" @default|qubes.Notifications|<user>|"<path>\NotifyClient.exe" --handler "<spool-file>"
```

qrexec-client-vm hands this to qrexec-agent and exits (its exit 0 means "handed to the
agent", **not** allowed or delivered). The agent spawns the handler **in the interactive
session** with stdin/stdout wired to the data vchan; the handler speaks the proxy protocol:

1. **Handshake** (server speaks first): read u32 LE version `0x00010000` (major 1, minor 0);
   abort unless major == 1; reply u32 LE `(1<<16) | min(server_minor, 0)`.
2. **Send one frame**: u32 LE length, then bincode-1.x fixint LE `Message` — id u64 = 1;
   `Notification::V1` tag u32 = 0; suppress_sound/transient/resident u8 = 0; urgency
   Option = None; replaces_id u32 = 0; summary and body as u64-length-prefixed UTF-8;
   actions count u64 = 0; category Option = None; expire_timeout i32 = −1; image
   Option = None.
3. **Wait for the ack**: framed `ReplyMessage` — tag 0 `Id{id, sequence}` for sequence 1 =
   success (`OK id=N`), tag 1/2 = error, tags 3/4 (Dismissed/ActionInvoked) ignored, tag 5
   ServerRestart = error. Result goes to `<spool-file>.result`, which the launcher polls
   and prints.

Spool files live in `%ProgramData%\qubes-notify-proxy` (not `%TEMP%`) because the launcher
may run as SYSTEM (e.g. via `qubes.VMShell`) while the handler runs as the desktop user.

Usage inside the guest:

```powershell
powershell -ExecutionPolicy Bypass -File send-notification.ps1 -Summary "hello" -Body "arbitrary text"
# or, once compiled:
NotifyClient.exe --send "hello" arbitrary text words
NotifyClient.exe --send-file msg.txt        # UTF-8; first line = summary, rest = body (multi-line OK)
```

Exit codes: 0 = acked by dom0 (`OK id=N` printed), 1 = server-reported error, 2 = local
failure, 3 = NOACK timeout (policy refusal — invisible to callers by design — or no dom0
GUI session yet (`wait-for-session=1` blocks), or no logged-on guest session).

## Known limits (v1, deliberate)

- Fire-and-forget: no `replaces_id` reuse, no action buttons consumed, no images (the
  server discards images anyway). All are protocol-supported if ever wanted.
- One qrexec connection per notification (the Linux agent holds one long-lived connection;
  fine at human notification rates, and bridge-process churn is the proven wedge provocation,
  so keep rates low anyway).
- Requires a logged-on interactive session in the guest (qrexec local handlers are spawned
  there). Autologon is enforced on this project's testbeds.

## TEST PLAN — run only when the rig is free (owner-gated; nothing here touches a qube)

Setup: any `win-idd-testbed`-tagged AppVM with QWT and a logged-on session (autologon),
e.g. `win10-app`. dom0 needs its GUI session up.

1. **One-time dom0 sanity (owner, optional, read-only)**: confirm
   `/etc/qubes-rpc/qubes.Notifications` exists and the stock 90-default.policy line above is
   present unmodified. Expected yes on R4.3; no edits either way.
2. **Push**: `tools/qtest push` this directory's `NotifyClient.cs` and
   `send-notification.ps1` to the guest.
3. **Send** (inline `qtest run`, not pushrun): run `send-notification.ps1 -Summary "notify-proxy test"
   -Body "arbitrary text from the Windows guest"` via powershell. Expect stdout `OK id=<n>`
   and exit 0.
4. **Verify pixels, not logs**: an origin-marked notification appears in dom0 —
   summary **`<qube>: notify-proxy test`**, app name `Qube: <qube>`, qube-colored icon.
   The dom0 screen is the criterion.
5. **Sanitization is server-side (spot-check it)**:
   - `-Body '<b>bold</b> & <a href="x">link</a>'` → must render literally/escaped, not as markup.
   - `--send-file` with a UTF-8 file containing multi-line text + non-ASCII (e.g. Cyrillic,
     an emoji, a control char) → renders with the control char replaced (U+FFFD), the rest intact.
   - Confirm the `<qube>: ` prefix cannot be omitted (there is no field to omit it with).
6. **Instrument fail-proof** (per the evidence rules: a check counts only once seen to
   FAIL): temporarily change `OurMajor` to 2 in `NotifyClient.cs`, recompile, send → must
   print `FAIL handshake: ...` / exit nonzero; revert, resend → `OK`. This proves the
   OK/FAIL verdict can actually fail.
7. **NOACK path**: send with `-User nonexistentaccount` → expect NOACK/failure, proving the
   timeout branch reports rather than false-OKs.
8. **Politeness note**: send 3 notifications back-to-back; all should appear and be
   attributed. There is no server rate limit — record that the client's callers must
   coalesce.

## Open items

- The rig's QWT-era `qrexec-client-vm.exe` + wrapper handling a long-lived bidirectional
  stream is already proven by `guest/qubes-updates-relay.cs` (same channel shape, same
  `@default` target, ~13 MB/s duplex); step 3 is still the first live use for THIS service.
- bincode is formally "native endian"; both ends are x86-64 here and the client hard-codes
  LE against the version handshake.
- CLAUDE.md's 2A-chrome note that dom0-rendered guest notifications "would be rejected
  upstream" predates R4.3, where upstream shipped exactly this (origin-marked, dom0-
  sanitized, allow-by-default). The toast-predicate test case there is unaffected; the scope
  note deserves an update pointing at `qubes.Notifications` (owner's call).
