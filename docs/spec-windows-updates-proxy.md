# Spec: Windows Update through the Qubes update proxy (netvm-less Windows templates)

**Status: SPECIFICATION ONLY — not scheduled, not part of the display work.**
An agent working from `../CLAUDE.md` should NOT start this. It exists so the design is
recorded; implement only if the user explicitly asks.

## Problem

A Windows TemplateVM (or any Windows qube kept offline by policy) cannot run Windows Update
without a netvm. Linux templates solve this with the Qubes update proxy; Windows has no
equivalent, so Windows qubes either get a netvm (against the template convention, and a
much larger exposure) or never update.

## How the Linux path works (the model to copy)

1. Template has `netvm = none`.
2. `qubes-updates-proxy-forwarder` — a systemd **socket-activated** unit in the template —
   listens on `127.0.0.1:8082`.
3. Each accepted connection is piped over qrexec to the `qubes.UpdatesProxy` service in a
   proxy qube (sys-net / sys-firewall).
4. There, tinyproxy performs the actual HTTP(S) fetch and streams bytes back.
5. dnf/apt are configured with `proxy=http://127.0.0.1:8082` and are none the wiser.

The transport is plain qrexec: no IP connectivity is granted to the template at any point.

## What has to be built for Windows

### 1. Forwarder service (the only real work)

A Windows service — `qubes-updates-proxy-forwarder.exe`, C or C# — that:

- listens on `127.0.0.1:8082` (loopback ONLY; never bind 0.0.0.0);
- per accepted TCP connection, spawns
  `qrexec-client-vm.exe @default qubes.UpdatesProxy`
  (client ships with QWT; confirm exact path/name in the installed tools);
- pumps socket↔stdio bidirectionally until either side closes; one child process per
  connection, concurrency required (Windows Update opens many parallel connections);
- logs failures somewhere greppable; never retries indefinitely.

Reference behaviour: `qubes-core-agent-linux`'s
`qubes-updates-proxy-forwarder.socket`/`.service`. Semantics are identical; only the
plumbing differs.

### 2. Point Windows at it

```cmd
netsh winhttp set proxy 127.0.0.1:8082
```
Windows Update uses **WinHTTP**, not the per-user WinINET settings, so this is the correct
knob (the IE/Settings proxy UI is not).

Also disable Delivery Optimization's peer paths, which bypass the proxy:
```
HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization
    DODownloadMode (REG_DWORD) = 0        ; HTTP only, no peering
```

### 3. Policy

`qubes.UpdatesProxy` default policy keys on `@type:TemplateVM`. A Windows **TemplateVM**
should already match. A **StandaloneVM** needs an explicit rule, e.g.:
```
qubes.UpdatesProxy  *  <windows-qube>  @default  allow target=sys-net
```
Confirm against the shipped `/etc/qubes/policy.d/90-default.policy` before adding anything;
prefer matching the existing convention over inventing a rule.

## Known risks / open questions

- **Proxy destination filtering.** tinyproxy in the updates proxy may be configured to allow
  only distro domains. Windows Update needs a broad set (`*.windowsupdate.com`,
  `*.update.microsoft.com`, `*.delivery.mp.microsoft.com`, and more, which drift over time).
  VERIFY the deployed filter before building anything — if it is restrictive, this design
  needs a filter change in the proxy qube, which is a separate (and more contentious)
  discussion than a guest-side forwarder.
  Empirical hint: `npm install` through `https_proxy` from a Fedora template succeeded on
  this system (2026-07-30), suggesting the local filter is permissive. Not proof.
- **Volume/behaviour**: Windows Update is far chattier than dnf — many parallel CONNECTs,
  large payloads, long-lived connections. Expect it to be slower and less robust than the
  Linux path, and expect the forwarder's concurrency handling to be the weak point.
- **WSUS/ESU/Store**: only Windows Update proper is in scope here. The Store, Defender
  definition updates, and Delivery Optimization metadata may use different transports.
- **Trust boundary unchanged**: the guest still cannot reach the network directly; the proxy
  qube performs all fetches. This does NOT make an untrusted Windows guest safer to update —
  it makes updating possible without granting it a netvm.

## Relationship to Track C (update status reporting)

Track C (in `../CLAUDE.md`) reports *whether* updates are available, via WUA COM search →
`qubes.NotifyUpdates` → the Qubes updater widget. This spec covers *fetching* them without a
netvm. They are complementary and share qrexec plumbing, but neither depends on the other:
Track C works fine on a Windows qube that has a netvm, and this forwarder is useful even if
nothing ever reports status. Implement independently.

## Simpler alternative (for the record)

Give the Windows template a netvm with a firewall restricted to Microsoft update endpoints.
Zero code; breaks the "templates have no netvm" convention; the endpoint list is broad and
drifts, so the firewall rules rot. Mentioned because it is what most people actually do.
