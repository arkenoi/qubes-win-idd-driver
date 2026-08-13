# Windows updates: one click in the Qubes Update GUI, no dom0-side command

Status 2026-08-13: implemented and deployed on `win11-fresh`; a real install pass was driven
through the whole path (see Evidence). Targets **TemplateVMs and StandaloneVMs** alike.

The goal, stated by the user: *"it should just update from gui with regular click"*. That rules
out our own dom0 command as the primary path, because the Qubes Update GUI does not call it —
it shells out to `qubes-vm-update`. So the guest has to answer `qubes-vm-update` itself.

## Why a Windows guest cannot be updated the way a Linux one is

dom0's updater does **not** call an agent that lives in the guest. It injects one on every run
and deletes it afterwards (`qubes-core-admin-linux`, `vmupdate/qube_connection.py`):

| step | command | transport |
|---|---|---|
| 1 | `mkdir -p /run/qubes-update/` | `qubes.VMExec` |
| 2 | `cat > /run/qubes-update/agent.tar.gz` (tarball on stdin) | `qubes.VMShell` |
| 3 | `tar -xzf … -C /run/qubes-update/` | `qubes.VMExec` |
| 4 | `/usr/bin/python3 /run/qubes-update/agent/entrypoint.py <flags>` | `qubes.VMExec`, progress mode |
| 5 | `rm -r /run/qubes-update/` | `qubes.VMExec` |
| 6 | `cat /var/log/qubes/qubes-update/update-agent.log` | `qubes.VMExec` |

That is *why* any Linux qube is updatable with nothing preinstalled — and exactly why Windows
never can be: no `/usr/bin/python3`, no dnf/apt, and no Windows branch in `get_os_data()` /
`AgentType`. Our `qubes.WindowsUpdate` service is the Windows equivalent of that injected agent,
and it must be preinstalled precisely because dom0 cannot inject a runnable one.

So the guest answers the same command shapes and, at step 4, runs **our** updater. The injected
Python is accepted and discarded — nothing downstream ever reads the extracted tree.

## What ships

- **`guest/vmupdate-shim.ps1`** — handles `mkdir`/`rm`/`tar`/`cat`, and routes step 4 to
  `wu-update.ps1`, which already speaks the agent contract: bare float progress 0..100 on
  stderr, stdout = logs, exit 0 = ok / 100 = no updates / else error (re-verified against
  `vmupdate/agent/source/common/exit_codes.py`). `--download-only` gets its own scheduled task
  so it can never install — that decision stays with dom0.
- **`guest/VMExec.ps1`** — our replacement for QWT's handler. Two changes: it propagates the
  child's exit code, and it dispatches updater-scoped commands to the shim. Anything not naming
  the updater workdir or `entrypoint.py` goes to `cmd.exe` exactly as before.
- **`guest/qubes-posix-cat.cs`** → `cat.exe` on the machine PATH. Step 2 arrives over
  `qubes.VMShell`, which is cmd.exe with no interception point, so this one is a real binary.
  (`mkdir` cannot be handled this way — it is a cmd builtin and always wins over PATH.)
- **`vmexec` feature advertisement** — `qubesadmin.run_with_args()` uses `qubes.VMExec` only for
  qubes that advertise it, and otherwise falls back to `qubes.VMShell` with a shell-quoted line,
  which lands in cmd.exe and fails on `mkdir -p`. QWT has implemented `qubes.VMExec` all along,
  so this advertises a capability we genuinely have. dom0 accepts it from any VM via
  `qubes.FeaturesRequest` (`qubes/ext/core_features.py` allows exactly `qrexec`, `gui`,
  `gui-emulated`, `qubes-firewall`, `vmexec`).
- **`NoAutoUpdate=1`** — dom0 owns installs. Not cosmetic: the updates proxy is raised only for
  the duration of a dom0-driven pass, which is exactly the window in which a live Windows AU
  would find connectivity and install behind dom0's back. `wuauserv`/USO stay enabled — the
  on-demand path uses them.
- Deployed by **default** from installer stage 2 (`/noupdates` opts out). `qvm-windows-update`
  ships in the dom0 RPM as a fallback and diagnostic, not as the required path.

## A real QWT defect found on the way

Stock `VMExec.ps1` ends on `& cmd.exe /c $cmd` and never exits with the child's status, so
**every** `qubes.VMExec` call returns 0 to dom0. Measured: a command exiting 100 arrived as 0,
while the identical command over `qubes.VMShell` correctly returned 100 (and a refused service
returns 126, so the check can fail). dom0 tooling decides success from that status —
`qubesadmin` raises `CalledProcessError` on it — so on Windows every failure has been reading as
success. Fixed here; worth reporting upstream once QWT-NG work is submitted.

## TemplateVMs

Templates are a first-class target, not an afterthought:

- `vmupdate`'s `get_targets` selects by class (TemplateVM/StandaloneVM/running AppVM) plus the
  `updates-available`, `skip-update` and `prohibit-start` features. **There is no OS filter.**
- The Qubes Update GUI lists any qube with `updateable` true — TemplateVMs and StandaloneVMs.
- `qubes.FeaturesRequest` is *ignored for template-BASED VMs* and honoured for templates, so the
  `vmexec` advertisement must happen in the template (it does — the installer runs there), and
  AppVMs inherit it through `features.check_with_template`.
- `qubes.NotifyUpdates` walks the template chain: a template reports for itself; an AppVM hints
  its template only when the template is not running. Standard Qubes behaviour, unchanged by us.

**Autologon / cold start.** A QWT guest does not really boot to "no session": autologon fires
(our images set it in `unattend.xml`; QWT also has an Autologon feature, which we deliberately
omit because it randomises the local account password). This matters because dom0 sends no
`nogui:` prefix, so QWT's agent runs service children in the interactive session; and because
dom0 *starts a stopped template* to update it. The residual risk is therefore a timing race on a
cold start, not a missing session — which is why the cold-boot path is part of acceptance below
rather than assumed.

## Transport: it works with or without the `vmexec` feature (and we cannot set it)

dom0 picks the transport per qube. `qubesadmin.run_with_args()` uses `qubes.VMExec` only for
qubes advertising the **`vmexec`** feature, and otherwise falls back to `qubes.VMShell` with a
shell-quoted line. The obvious move — have the guest advertise it via `qubes.FeaturesRequest`,
which dom0 accepts from any VM — **does not work, and cannot**:

> The Windows build of `qubesdb-cmd` cannot write to QubesDB at all. `client/qubesdb-cmd.c`
> does `optind -= 2` under `_WIN32` after an option loop that also tests `getopt(...) != 0`
> instead of `!= -1`; the net effect is that exactly ONE trailing argument reaches the command
> handler. `read`/`list` take one argument and work; `write` needs a path/value pair and dies
> with "Invalid number of parameters" for every documented form (measured: `-c write p v`,
> `-c write -- p v`, `write p v`, `-c write p`, and two pairs at once).

This is an upstream defect in `qubes-core-qubesdb` — not ours — and qualifies for reporting
under the upstream policy in CLAUDE.md. **Do not re-add an advertisement step to the installer.**

So the design has to survive without the feature, and it does:

| step | with `vmexec` | without it (today's reality) |
|---|---|---|
| 1 `mkdir -p` | shim creates the dir | fails in cmd — but harmless, see below |
| 2 `cat > …tar.gz` | VMShell → `cat.exe` | identical (always VMShell) |
| 3 `tar -xzf` | shim accepts + discards | bsdtar extracts, or fails; either is fine |
| 4 **entrypoint** | shim runs the updater | **identical** — the progress path calls `qubes.VMExec` directly, with no feature check and no fallback |
| 5 `rm -r` | shim empties the workdir | `rm` not found; workdir persists |
| 6 `cat <log>` | shim emits our status | `cat.exe` emits nothing, exit 0 |

The reason the failures are harmless: over VMShell dom0's line ends in `& exit`, and **`exit`
with no argument returns 0 regardless of what preceded it** (measured: a bogus command still
yields exit 0, while an explicit `exit 100` correctly returns 100). dom0 therefore sees success
for the preparation steps and proceeds to the only one that matters.

**One thing must not fail**, and it is why the installer pre-creates `C:\run\qubes-update\` and
why the shim's `rm` empties that directory instead of removing it: if the workdir is missing,
cmd's redirection in step 2 fails, cmd exits immediately, and dom0 is left writing a megabyte
into a closed pipe — a broken-pipe error rather than a silent no-op.

Also relied on, and already true: **`os=Windows`**. `qubesadmin.prepare_input_for_vmshell()`
terminates the VMShell command with `& exit` rather than `; exit` only when the qube's `os`
feature reads `Windows` — upstream already special-cases Windows here — and QWT advertises it at
every boot from `advertise-tools.c` (`/qubes-tools/os` → `qubes.NotifyTools`).

## Evidence

| check | result |
|---|---|
| `qubes.VMExec` present in shipped QWT 4.2.2 | yes (`qubes-rpc/qubes.VMExec` → `VMExec.ps1`) |
| exit code through `qubes.VMExec` (stock) | `exit 100` → **0** (defect); via `qubes.VMShell` → 100 |
| `mkdir -p /run/qubes-update/` through cmd | **fails**, "syntax of the command is incorrect" |
| `tar` on the guest | present, bsdtar 3.8.4 |
| `/usr/bin/python3` resolution | resolves to `C:\usr\bin\python3.*`, args + exit code survive |
| dom0 step sequence 1,3,5,6 after the shim | rc=0 each, shim log lines confirm the handler ran |
| `vmexec` feature actually set in dom0 | **no** — `admin.vm.feature.Get+vmexec` → "Feature not set" |
| `qubesdb-cmd` write from the guest | fails in all five documented forms (read/list work) |
| VMShell `exit` after a failing command | 0 — while an explicit `exit 100` returns 100 and a refused service returns 126 |
| step 2, agent tarball | 1 MB payload **byte-exact** (size + SHA256 read back from the guest) |
| step 4, real update pass | count=2, KB5121003 installed (DISM rc=3010) |
| the guest actually changed | **UBR 8875 → 9168** after reboot, matching KB5121003 "(26200.9168)"; `Get-HotFix` lists it; CBS reboot flag cleared |
| cold boot (dom0 starts a stopped qube) | `qubes.VMShell` answers at t+259 s, `qubes.VMExec` at t+265 s — with a cumulative update being applied at boot |
| workdir survives a reboot and a dom0 `rm` | present after both |
| PowerShell parse check | all guest scripts ok, and proven able to FAIL on a deliberately broken file |

Re-run any of it with `tools/replay-dom0-update.py <vm> [--with-entrypoint]`, which replays
dom0's sequence using the same services and the same `encode_for_vmexec` encoding, and
`tools/verify-vmupdate-copy.py <vm>` for the byte-exactness check.

## Reporting the outcome, not the phase

The first real pass also exposed two defects in *our* updater, both the same family as the QWT
`VMExec` bug — success reported regardless of outcome:

- `qubes-windows-update.ps1` **assigned** the install rows inside the per-KB loop, so each KB
  erased the previous one and only the last survived. Now appended and grouped per KB.
- A single catalog KB legitimately yields several `.msu` (build/architecture variants,
  prerequisites) and the inapplicable ones fail by design — a 24H2 cumulative returns `rc=552`
  on a 25H2 guest. So a KB counts as installed when **at least one** of its files returns DISM
  0, 3010 or 0x240006 (already installed).
- `wu-update.ps1` exited 0 whenever the phase reached `done`, so a KB whose every file failed
  still reported success to dom0. It now names failed KBs on stderr and exits 1.

## Acceptance still open

1. **The user's click** — the Qubes Update GUI against a Windows qube. Cannot be run from this
   dev qube (it is a dom0 tool); the one step that needs the user.
2. **TemplateVM proper** — everything above was exercised on a StandaloneVM. dom0-side selection
   has no OS filter and the guest side is identical, so templates are in scope by construction —
   but that is an argument, not a demonstration.
## Known limitation: not every offered update can be fetched yet

`Resolve-Catalog` in `guest/qubes-windows-update.ps1` scrapes the Microsoft Update Catalog and
is written around the **x64 / 24H2 / 26100** client build. On the 25H2 (26200) rig it returned
nothing installable for **KB5120708** (.NET Framework Security Update), so that update is offered
by the scan and then not installed. Until the resolver handles more package shapes and builds:

- the pass now **reports this as a failure** (`ok=false` with a reason, `wu-update.ps1` exits 1
  naming the KB) rather than the silent "count=1, exit 0" it produced before — measured;
- so a user sees "failed to install KB…" in the updater instead of a false success.

Making it actually install is the next piece of work on the updater, and is independent of the
shim: the transport, protocol and dom0 integration all work, this is package resolution.

The cold-boot path (item 2 in earlier drafts) is now **closed**: after a cold start with a
cumulative update applying at boot, `qubes.VMExec` answered 6 s after qrexec came up.

## Do not repeat

- Do not judge the copy step by its exit code. cmd's `exit` returns 0 whether or not the payload
  landed; only reading the file's size and hash back out of the guest proves it.
- `$ErrorActionPreference='Stop'` turns any native stderr line into a terminating error. It
  silently truncated `install-updater-agent.ps1` mid-deploy twice — once on a `schtasks` warning,
  once on `qubesdb-cmd`. Wrap native calls.
