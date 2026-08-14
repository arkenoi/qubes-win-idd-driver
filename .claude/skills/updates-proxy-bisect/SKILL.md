---
name: updates-proxy-bisect
description: Own BOTH ends of the updates-proxy path by running tinyproxy in this dev qube, instead of guessing about infrastructure you cannot see or asking the user to restart it. Use whenever guest traffic through qubes.UpdatesProxy misbehaves - truncated bodies, dropped requests, TLS failures, throughput mysteries - or whenever you are tempted to name a qube you have not verified exists.
---

# Do not guess the infrastructure. Become it.

Two failures this exists to prevent, both committed repeatedly in this project:

1. **Inventing qube names.** There is no `sys-net` and no `sys-firewall` here. Naming them wastes
   the user's time and produces conclusions about a topology that does not exist.
2. **Escalating instead of bisecting.** "The proxy qube may be degraded, please restart it" is not
   a finding. This qube can BE the updates proxy in about a minute, after which both ends are
   instrumented and the question is answered with evidence.

## The actual roster (verify, never recall)

    qvm-ls --fields NAME,STATE,CLASS,NETVM

As of 2026-08-14 the whole world is: `dom0`, `win-idd-mgmt` (this dev qube), `win10-clean`,
`win11-24h2`, `win11-fresh`, `win11-tpl`. The network-providing qube is **`core-net`**.
Anything else you were about to type is a hallucination. See also the `reuse-policied-qube-names`
memory: the testbed policy is tag-based (`win-idd-testbed`), so only qubes already on the roster
have policy.

## Why this qube can serve the proxy

It already ships the service, as a symlink straight to a local port:

    /etc/qubes-rpc/qubes.UpdatesProxy -> /dev/tcp/127.0.0.1/8082

So anything listening on 127.0.0.1:8082 here IS what `qubes.UpdatesProxy` connects callers to. No
root, no dom0, no policy change is needed to stand it up - `tinyproxy` is installed at
`/usr/bin/tinyproxy` and runs fine as an ordinary user with its own config file.

## Recipe

1. **Write a config in your scratchpad** (unprivileged, verbose, and logging every request):

   ```
   Port 8082
   Listen 127.0.0.1
   Timeout 600
   LogFile "<scratch>/tinyproxy.log"
   LogLevel Connect          # Info/Connect logs each request; Critical hides what you need
   PidFile "<scratch>/tinyproxy.pid"
   MaxClients 64
   Allow 127.0.0.1
   ```

   `LogLevel Connect` is the point of the exercise - it names every host and method, so a
   truncation or a refusal is attributable rather than inferred.

2. **Run it in the foreground of a background task** so you can read and kill it:
   `tinyproxy -d -c <scratch>/tinyproxy.conf`

3. **Point the guest at THIS qube by name** rather than `@default`, so routing is not a variable:
   the relay takes `--target`, e.g.
   `qubes-updates-relay.exe --listen 8082 --target win-idd-mgmt --log C:\ProgramData\Qubes\wu`
   (`@default` sends it wherever dom0 policy decides, which is exactly the thing you cannot see.)

4. **Re-run the failing fetch** and compare the two logs you now own:
   * tinyproxy's log - did the request arrive, what did the upstream return, how many bytes?
   * the relay's `CONN`/`HANDLER` lines - what did the guest receive and why did each pump stop?

## Reading the result

| tinyproxy log | guest sees | conclusion |
|---|---|---|
| full response logged | short body | loss is between here and the guest: qrexec transport or the relay |
| short/failed upstream | short body | the fault is upstream of this qube - the network path, not Qubes plumbing |
| request never arrives | error | routing/policy: check `--target`, and that the service call is permitted |

That table is the whole value: it converts "the proxy qube might be unhealthy" into a fact, without
touching a qube you do not own.

## Rules

- **Never ask the user to restart infrastructure before doing this.** It is faster than the ask.
- **Never name a qube you have not seen in `qvm-ls`.**
- Keep the config, logs and pidfile in the scratchpad, never in `/etc` - no sudo is required and
  needing it means you have taken a wrong turn.
- Kill tinyproxy when finished; a stray listener on 8082 silently changes what every later test
  measures.
- The guest's own relay also listens on 8082 INSIDE the guest. Same number, different qube - do not
  confuse the two when reading logs.

## Related

- `.claude/skills/guest-introspection/SKILL.md` - ask the guest what it is doing
- `guest/wu-proxy-direct.ps1` - fetch through qubes.UpdatesProxy with our relay removed
- `guest/wu-plainhttp-repeat.ps1` - same-URL repeat, to separate "this URL" from "the tunnel"
- `guest/wu-relay-ends.ps1` - per-direction termination reasons from the relay
