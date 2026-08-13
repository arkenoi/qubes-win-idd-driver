---
name: qubes-admin-api
description: >
  What this dev qube (win-idd-mgmt) can do to the testbed through the Qubes Admin API over
  qrexec — create/remove qubes, set properties, features and tags, import volumes, drive power
  state — plus the exact calling convention and the traps that make results lie. Use whenever a
  task looks like it "needs dom0": most of it does not, and these calls are pre-authorised, so
  use them WITHOUT asking. Read before provisioning a qube, changing qube settings, or concluding
  that something is impossible from here.
---

# Qubes Admin API from the dev qube

**These calls are already permitted by the testbed policy. Use them; do not ask first.**
CLAUDE.md says "anything needing dom0 → ask the user". That rule is about *shell access to dom0*.
It does NOT cover the Admin API surface below, which the user deliberately policied for this qube.
I once told the user "TemplateVM creation is dom0-only" — it is not, and the claim was wrong.

## Calling convention

    qrexec-client-vm <dest> <service>[+<arg>]        # payload, if any, on stdin

- `<dest>` is the qube the call is *about* (`win11-fresh`), or `dom0` for global calls
  (`admin.vm.List`, `admin.label.List`, `admin.vm.Create.*`).
- The reply starts with a **status byte**: `0` = OK, `2` = exception, followed by NUL-separated
  fields. Pipe through `tr -d '\0'` to read it. `2QubesValueError...` is an *allowed* call whose
  arguments were rejected — not a permission problem.
- **Policy refusal is exit code 126 with `Request refused`.** That is the ONLY reliable
  permission signal. An allowed call returns exit 0 even when the API answers with an exception.

## Verified surface (probed 2026-08-13)

| call | status |
|---|---|
| `admin.vm.List`, `admin.property.List`, `admin.label.List`, `admin.pool.List` (dest dom0) | allowed |
| `admin.vm.property.Get` / `.List` / `.Set` | allowed |
| `admin.vm.feature.Get` / `.List` / `.Set` | allowed (used to set `vmexec=1`) |
| `admin.vm.tag.List` / `.Set` / `.Remove` | allowed |
| `admin.vm.volume.Info` / `.List` / `.Resize` / `.Import` | allowed |
| `admin.vm.Create.TemplateVM` / `.StandaloneVM` / `.AppVM` (dest dom0) | allowed |
| `admin.vm.Start` / `.Shutdown` / `.Kill` / `.CurrentState` / `.Stats` | allowed (this is what `tools/qtest` uses) |
| `admin.vm.volume.Clone` | **refused** |
| `admin.vm.device.pci.List` | **refused** |
| `admin.vm.Remove` | **unknown — never probed against a real qube.** Assume allowed; treat as destructive |

So the policy is a curated allowlist, not blanket admin: check, don't assume, in either direction.

## Traps that made results lie (all hit for real)

1. **`$?` after a pipeline is the last command's status.** `qrexec-client-vm ... | tr | head; echo $?`
   reports `head`'s 0 and hides a refusal. Capture first:
   `out=$(printf '' | timeout 15 qrexec-client-vm "$d" "$s" 2>&1); rc=$?`
2. **Probing a mutating service MUTATES.** `admin.vm.tag.Set+!!illegal!!` was expected to fail
   validation; it succeeded, creating a real `__illegal__` tag that had to be removed. To test
   permission on a mutating call, use an argument the API must reject (`property.Set+nosuchproperty`,
   `Create.*` with `name=!!bad`), or do not probe it at all. Never probe `admin.vm.Remove`
   against a qube that matters.
3. **Feature values are Qubes booleans.** `updates-available` reads back as `1` when true and as
   an EMPTY string when false — an empty payload means "cleared", not "missing". "Not set at all"
   is `2QubesFeatureNotFoundError`.
4. `qrexec-client-vm` argument quoting: pass `domain|service|user|prog` UNQUOTED (see
   [[qrexec-client-vm-arg-quoting]] in memory) — a wrapping quote leaks into the target.

## Cloning a qube (including into a DIFFERENT class)

`qubesadmin` and the CLIs (`qvm-clone`, `qvm-create`, `qvm-prefs`, `qvm-ls`, `qvm-tags`) are
installed here and work over the same policy. `clone_vm(src, name, new_cls=...)` /
`qvm-clone --class` change the class, which is how a StandaloneVM becomes a TemplateVM without
reinstalling anything. On `lvm_thin` the copy is CoW: an 80 GiB root + 40 GiB private cloned in
**2.7 s**.

**But `qvm-clone` in one shot FAILS here**, with `Service call error: Request refused` after
"Cloning root volume". Policy on this testbed is **tag-based** (`win-idd-testbed`), and
`qvm-clone` creates the qube, then clones volumes into it *before* the tags are copied — so the
volume call hits a qube policy does not yet cover. Do it in the order that satisfies policy:

    qvm-create --class TemplateVM --label red <new>
    qvm-tags <new> add win-idd-testbed          # policy now applies to it
    python3 - <<'EOF'                            # volumes + prefs + features
    import qubesadmin
    app = qubesadmin.Qubes(); src = app.domains['<src>']; dst = app.domains['<new>']
    for v in ('root', 'private'):
        dst.volumes[v].clone(src.volumes[v])
    for p in ('virt_mode','kernel','memory','maxmem','vcpus','qrexec_timeout','netvm'):
        setattr(dst, p, getattr(src, p))
    EOF

A fresh TemplateVM's defaults are Linux-shaped, so a Windows guest needs at minimum
`virt_mode=hvm` and an EMPTY `kernel`, or it will not boot its own bootloader.
`admin.vm.volume.Export` is REFUSED, so streaming a volume out of a qube is not an option —
server-side `CloneFrom`/`CloneTo` (what the above uses) is.

## Recovering a guest you can no longer run code in

A Windows qube that boots to the SIGN-IN SCREEN is unreachable: qrexec service calls have nobody
to run as, so `qubes.VMShell` and `qubes.VMExec` both fail (measured rc=117, which is NOT the 126
of a policy refusal). No agent, no script, no update can be run inside it. Measured 2026-08-13
after a cumulative update rewrote Winlogon on win11-tpl.

The way back in does not need a session, because it operates on the VOLUME:

    qrexec-client-vm <vm> admin.vm.volume.ListSnapshots+root </dev/null | tr -d '\0'
    # -> e.g. 1786643600-back  1786643731-back      (revisions_to_keep, default 2)
    printf '<revision>' | qrexec-client-vm <vm> admin.vm.volume.Revert+root      # qube must be HALTED

Both are permitted here. Revert rolls the root volume back to that revision, which undoes whatever
made the guest unreachable - at the cost of everything written since it. On a TEMPLATE that means
losing the updates installed after the snapshot; on a StandaloneVM it means losing user data too.
It is a recovery of last resort, not a routine step - but it beats a qube nobody can log into.

Prevention is better and is now in the product: `guest/ensure-autologon.ps1` runs before any
reboot the updater triggers, because while `AutoLogonCount` exists Windows CONSUMES
`DefaultPassword` and then falls back to the sign-in screen.

## Never edit a script while it is running

bash reads a script incrementally, by BYTE OFFSET. Editing the file in place while it executes
shifts every offset after the edit, and the running shell resumes mid-token:

    ./tools/clean-shot-template.sh: line 81: syntax error near unexpected token `)'
    ./tools/clean-shot-template.sh: line 81: `test pushrun guest/wu-verify-installed.ps1 ...'

That is `./tools/q` + `test pushrun ...` - one command sliced in half. It cost a 40-minute run
whose actual work had already SUCCEEDED; only the harness died. Edit a copy, or wait for the run
to finish. The same applies to any long-running interpreter reading from the file as it goes.

## Recipes

    # what exists, right now - trust this over any remembered roster (mine was stale)
    qrexec-client-vm dom0 admin.vm.List </dev/null | tr -d '\0'

    # read a property / feature
    qrexec-client-vm win11-fresh admin.vm.property.Get+qrexec_timeout </dev/null | tr -d '\0'
    qrexec-client-vm win11-fresh admin.vm.feature.Get+vmexec </dev/null | tr -d '\0'

    # set a feature (payload on stdin)
    printf '1' | qrexec-client-vm win11-fresh admin.vm.feature.Set+vmexec

    # create a qube (dest dom0; label must exist - see admin.label.List)
    printf 'name=win11-tpl label=red' | qrexec-client-vm dom0 admin.vm.Create.TemplateVM

    # volume facts before importing into one
    qrexec-client-vm win11-fresh admin.vm.volume.Info+root </dev/null | tr -d '\0'

## Testbed facts worth re-reading, not remembering

The qube roster changes; `admin.vm.List` is the source of truth. As of 2026-08-13 it was
`win10-clean`, `win11-24h2`, `win11-fresh` (all StandaloneVM) plus `win-idd-mgmt` (this qube).
A qube that policy applies to carries the tag `win-idd-testbed`, so a NEWLY created qube needs
that tag before qrexec/admin calls to it will be permitted — set it with `admin.vm.tag.Set`.
Only ONE Windows guest should run at a time (host memory).
