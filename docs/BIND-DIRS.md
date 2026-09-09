# bind-dirs — persistent directories on a Windows AppVM (the `qubes-bind-dirs` counterpart)

> **Status (2026-09-09):** source, project, offline tests and the package wiring (CI build of
> `bind-dirs.exe`, staging into the setup tree, the installer step that copies it to `System32`
> and registers BootExecute, the `bind_dirs_boot` health check) are all in the tree. **No CI
> build and no guest has run it yet.** Until a release note says otherwise, a package does NOT
> carry this feature.

A Windows AppVM's `C:` is restored from its template at every boot. Anything a program writes
under `C:\ProgramData\<vendor>` is gone next boot. Linux Qubes solves this with
[`qubes-bind-dirs`](https://www.qubes-os.org/doc/bind-dirs/): a list of paths that are copied
to the private volume once and bind-mounted over the template's copy at every boot. This is the
same feature for Windows, kept as close to the Linux one as NTFS allows.

| Linux | Windows |
|---|---|
| `/rw` — the persistent private volume | `Q:` — the Qubes private volume |
| the template root, reset each boot | `C:` — the AppVM system volume |
| `mount --bind /rw/bind-dirs/X /X` | an NTFS **directory junction** at `C:\X` → `Q:\bind-dirs\X` |
| `/rw/config/qubes-bind-dirs.d/*.conf` | `Q:\config\qubes-bind-dirs.d\*.conf` |
| `/etc/qubes-bind-dirs.d/*.conf` (template admin) | `C:\ProgramData\Qubes\qubes-bind-dirs.d\*.conf` |
| `/usr/lib/qubes-bind-dirs.d/*.conf` (shipped) | `C:\Program Files\Qubes Tools\qubes-bind-dirs.d\*.conf` |
| `/rw/bind-dirs/<path>` | `Q:\bind-dirs\<path without C:>` |
| `qubes-bind-dirs.service`, early in boot | `bind-dirs.exe` in Session Manager **BootExecute**, before any service |

## Using it

Create `Q:\config\qubes-bind-dirs.d\50_user.conf` in the AppVM (the directory is created by the
installer; the file name follows the Linux convention) with the same syntax as on Linux, with
Windows paths:

```bash
# Keep this application's state across reboots.
binds+=( 'C:\ProgramData\SomeVendor\SomeApp' )
binds+=( 'C:\Program Files\SomeVendor\Plugins' "C:\Data\Shared" )
```

Reboot. At the next boot, before any service starts, each listed directory is **seeded** — its
current content on `C:` is copied to `Q:\bind-dirs\ProgramData\SomeVendor\SomeApp` — **once**,
the first time a `Q:` copy does not yet exist. Then the `C:` directory is replaced by a junction
to the `Q:` copy. Every later boot only re-creates the junction (the copy on `Q:` is never
touched again, whatever the template now contains). That is exactly the Linux semantics:
first-use seeding from the template, then the private copy wins.

`fsutil reparsepoint query C:\ProgramData\SomeVendor\SomeApp` shows the junction; the data is
visible at both paths.

### Config syntax

The grammar is the subset of bash that Linux `.conf` files actually use, so a file written for
the Linux feature reads the same here:

| line | meaning |
|---|---|
| `# ...`, blank | ignored |
| `binds+=( 'C:\a' "C:\b" )` | append (the documented Linux form; any number of elements) |
| `binds=( 'C:\a' )` | replace the list |
| `binds=( "${binds[@]/'C:\a'}" )` | remove an earlier entry — the removal idiom from the Linux documentation |
| `binds=()` | clear |

One statement per line, a trailing `# comment` is allowed. Elements are single-quoted (literal),
double-quoted (bash's `\\` `\"` `\$` `` \` `` escapes are honoured; any other `$` or backtick is
refused, no expansion is supported) or bare. **A bare element may not contain a backslash** —
on Linux `binds+=( C:\Foo )` would have read `C:Foo`, so quote Windows paths. Forward slashes
are accepted and normalised.

Files are read in lexical order (case-insensitive, like NTFS names) from the three directories in
the order of the table above, so a later file can remove an entry an earlier file added.

**Any malformed line aborts the whole run before anything is touched** — the same as `bash -n`
plus `set -e` on Linux — and the log names the file, line and problem. Nothing is skipped
silently: a path that exists neither on `C:` nor on `Q:` is a failure (`source-missing`), not a
skip.

### Where it reports

Everything goes to the **private volume**, because a log on an AppVM's `C:` would not survive
the boot that failed:

- `Q:\Qubes Logs\bind-dirs.log` — this boot; `bind-dirs.prev.log` — the previous boot.
- `Q:\Qubes Logs\bind-dirs-result.txt` — machine-readable outcome, overwritten each boot:

```
result=ok|failed
reason=bound|no-config|entries-failed|config|private-volume|enable-privileges
status=0x00000000
entries=2
ok=2
failed=0
seeded=1
warnings=0
log=Q:\Qubes Logs\bind-dirs.log
entry=C:\ProgramData\SomeVendor\SomeApp result=ok reason=bound status=0x00000000 seeded=1 warning=0 rollback_failed=0 rw=Q:\bind-dirs\ProgramData\SomeVendor\SomeApp source=Q:\config\qubes-bind-dirs.d\50_user.conf:2
```

If `Q:` is not mounted at BootExecute time the log falls back to `C:\bind-dirs.log` and says so
on the boot screen; problems (`[!]` lines) are also printed on the boot screen, the way
`autochk` prints. `guest/bind-dirs-status.ps1` prints the record and verifies each junction.

Per-entry `reason` tokens: `bound`, `already-bound`, `duplicate` (ok); `source-missing`,
`file-unsupported`, `foreign-reparse-point`, `reparse-ancestor`, `target-missing`,
`target-not-directory`, `nested`, `protected`, `cross-volume`, `not-absolute-c`,
`unc-or-device-path`, `dot-component`, `empty-component`, `bad-character`, `root`,
`reserved-suffix`, `too-long`, `seed-copy`, `seed-commit`, `seed-parent`, `seed-stale-staging`,
`move-aside`, `mkdir`, `junction`, `verify`, `orig-stale`, `stat-*` (failed).

## Why it runs at BootExecute, and what that costs

A junction can only replace a directory that **nothing has open**. The paths people want to
persist — service state under `C:\ProgramData`, an application's install directory — are opened
by services as they start. A scheduled task or a service "at boot" runs after those services and
can only manage what happens to be idle at that moment; it would silently fail on exactly the
paths that matter. So `bind-dirs.exe` runs where `relocate-dir.exe` (the existing MoveUsers step
that moves `C:\Users` onto `Q:`) already runs: Session Manager's `BootExecute`, after `autochk`
and after `relocate-dir.exe`, before the Win32 subsystem exists. At that point no directory on
`C:` is in use by anything but the kernel itself.

The price of that position, stated plainly:

- **It is a native image.** No kernel32, no CRT — `ntdll` only, the same footing as
  `relocate-dir`. The decision logic is therefore written against a tiny file-system interface
  (`core-agent/src/bind-dirs/bind-dirs.h`) so it can be built and tested with gcc on Linux
  (`tools/tests/bind-dirs/run.sh`); only `main.c` touches NT.
- **A hang would hang the boot.** Nothing in it waits or retries; every operation is bounded by
  the size of the configured directories (the seed copy is the only potentially slow step, as it
  is for MoveUsers).
- **No qubesdb, no registry policy, no Win32.** It cannot ask "am I a template?" (see
  differences below) and cannot be invoked from a normal shell (a native image is not a Win32
  application).
- **`Q:` must already be mounted.** It is, on every guest where MoveUsers works: the PV disk
  driver is boot-start and the mount manager assigns drive letters before `smss` runs
  `BootExecute`. If it is not, the run fails with `reason=private-volume` and touches nothing.
- **`C:\Windows` and the tools' own directory can never be bound**, because that is the image
  running the boot. Refused as `protected`.

The alternatives considered and rejected: (a) extending `relocate-dir.exe` itself — it is a
one-shot migration that removes its own BootExecute entry on every exit path and whose result
record the MoveUsers health check reads; turning it into a permanent every-boot program would
change a boot-critical binary's contract for no gain, so `bind-dirs.exe` is a second program
that shares relocate-dir's I/O layer (`io.c`) by reference; (c) a service or scheduled task —
easy, Win32, testable from a shell, and unable to manage anything a service opens at start,
which is the case this feature exists for.

## How a bind is applied (and why it cannot leave a path half-converted)

For each configured path `ro` with `rw = Q:\bind-dirs\<ro without C:>`:

1. `ro` is already a reparse point: if it is **our** junction to `rw` and `rw` is a directory →
   `already-bound`, nothing done (idempotent; zero writes). Any other reparse point → refused
   `foreign-reparse-point`. Our junction with `rw` missing → refused `target-missing` (a
   dangling junction is never "repaired" by re-seeding: that would resurrect template content
   over data the user deleted).
2. Any ancestor of `ro` is a reparse point (e.g. `C:\Users\...` after MoveUsers) → refused
   `reparse-ancestor`: the junction would land on `Q:` pointing into `Q:`.
3. `ro` is a file → refused `file-unsupported`.
4. **Seed**, only if `rw` does not exist: copy `ro` → `rw.qbd-seeding` (attributes, ACLs,
   reparse points preserved; strict — any child failure fails the copy and the partial copy is
   removed), then **rename** `rw.qbd-seeding` → `rw`. The rename is the commit: a seed exists
   only if it is complete, so a later run can never mistake a half copy for data and can never
   re-seed over real data. A stale `.qbd-seeding` from an interrupted boot is discarded.
5. **Bind**: rename `ro` → `ro.qbd-orig` (atomic, same volume), create an empty `ro`, set the
   junction, **read it back** and compare the target. If any step fails the empty directory is
   removed and `ro.qbd-orig` is renamed back; the entry is reported `failed` with the step name
   and, if even the rename-back failed, `rollback_failed=1` with the data still at
   `ro.qbd-orig`. On success `ro.qbd-orig` is deleted (on an AppVM it would vanish with `C:`
   anyway; on a template it would be a stale duplicate); failure to delete it is a warning on
   an otherwise successful bind.

Before anything is applied the whole list is validated: refused paths, duplicates (second
occurrence is `ok/duplicate`, a no-op) and **nested** pairs (both refused) are decided first.

## Differences from Linux `qubes-bind-dirs`, and why

| Linux `bind-dirs.sh` | here | why |
|---|---|---|
| Binds files as well as directories | **directories only**; a file is refused `file-unsupported` | a junction is a directory-only reparse point. Files would need a file symbolic link, whose evaluation is policy-controlled (`fsutil behavior SymlinkEvaluation`) and which many applications refuse to follow. |
| `prerequisite()`: exits on a fully persistent VM (template, standalone) | **runs everywhere** | qubesdb is unreachable at BootExecute. On a template/standalone the junction is created once (the seed goes to that qube's own `Q:`) and is `already-bound` on every later boot; an AppVM created from such a template inherits the junction on `C:` and the seed on its private volume (Windows AppVM private volumes are seeded from the template's at creation). Data-wise this is consistent; it differs in that a template *also* has its `C:` copy moved to `Q:`. |
| Follows symlinks in the configured path (up to 10 levels) and binds the target | **refuses** any existing reparse point that is not our own junction, and any path under a reparse point | the target of an arbitrary link can be another volume or the private volume itself; binding "wherever this points today" from a SYSTEM-privileged boot step is a redirect trap, and `C:\Users` under MoveUsers is exactly such a link. |
| `/home` → `/rw/home`, `/usr/local` → `/rw/usrlocal` special cases | none; `C:\Users` itself is refused (`protected`), paths under it are refused by the ancestor rule when MoveUsers owns it | MoveUsers already persists the whole profile tree. |
| A path that exists neither in the template nor in `/rw` is **skipped** with a message | **fails** (`source-missing`) | a typo in the config silently persisting nothing is the failure mode this repo refuses to ship. |
| A `mount --bind` failure aborts the script (`set -e`) at that entry; earlier binds stay | every entry is independent; the run is `failed` if any entry failed, all others are still applied | each entry is atomic on its own; taking the rest down with one bad path helps nobody. A **syntax error** in any file still aborts everything before anything is touched, like `bash -n`. |
| Nested binds stack as mounts | **refused** (`nested`, both entries) | binding the inner first and then seeding the outer copies the inner junction onto `Q:` as a junction pointing back into `Q:\bind-dirs` — a loop; the outer bind already persists the inner path. |
| Removal idiom `"${binds[@]/'/x'}"` is bash substring substitution | removes entries **equal** (case-insensitively) to the path | the only use the documentation gives it, and the only one that makes sense for a path list. |
| `binds+=( ... )` may span lines, bare elements may contain backslashes | one statement per line; bare elements with a backslash are a syntax error (`quote the path`) | in bash a bare `\` is an escape and the path would have been mangled; refusing is the honest reading of what the file *would* have done on Linux. |
| Seeds with `cp --archive` (no atomicity) | seeds into `rw.qbd-seeding`, renames into place | a half-copied `/rw/bind-dirs/x` on Linux is taken as a complete seed next boot; the rename-commit makes that impossible here. |
| `umount` mode (`bind-dirs.sh umount`) | none | on an AppVM the junctions vanish with `C:` at reboot; on a template, removing a junction would leave the data on `Q:` and an empty `C:` directory. Not provided until someone needs it. |
| Config also from qubesdb `/persist/` (`custom-persist`) | not implemented | needs qubesdb at BootExecute, which does not exist. |
| Protected locations: none | `C:\`, `C:\Windows\**`, `C:\Program Files\Qubes Tools\**`, and exactly `C:\Users`, `C:\Program Files`, `C:\Program Files (x86)`, `C:\ProgramData`, `C:\Recovery`, `C:\System Volume Information`, `C:\$Recycle.Bin`; any drive but `C:`; UNC / `\\?\`; `..`/`.` components; names Win32 would rewrite (trailing space/dot, reserved characters) | the OS image, the tools running the boot, the private volume itself, and names that would bind something other than what Explorer shows. |
| Runs as root with the whole coreutils | ntdll only; ADS, EFS-encrypted and compressed files are copied as plain data streams (same as MoveUsers) | native image. |

## Known limitations

- **After QWT is uninstalled** `bind-dirs.exe` stays in `System32` and in `BootExecute`
  (nothing removes it), fails with `private-volume` once `Q:` is gone and prints one line on
  the boot screen. Remove the `bind-dirs.exe` entry from
  `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\BootExecute` to silence it.
- **A path in use by the kernel at BootExecute** (page file directory, `System Volume
  Information`, anything under `C:\Windows`) cannot be bound; `C:\Windows` is refused up front,
  the rest fails `move-aside` with `STATUS_SHARING_VIOLATION` and is left intact.
- **Not testable from a shell.** A native image cannot be launched by `CreateProcess`; the
  instrument is the result record after a reboot, plus `guest/bind-dirs-status.ps1`.
- **Limits**: 256 entries, 256 `.conf` files per directory, 1 MiB per file, 1023-character
  paths. Exceeding any is a config error.

## Files

- `core-agent/src/bind-dirs/bind-dirs.{h,c}` — portable core (config, validation, decision,
  execution) against the `BD_FS` interface.
- `core-agent/src/bind-dirs/main.c` — NT implementation: `BD_FS` over relocate-dir's `io.c`,
  logging, result record, `NtProcessStartup`.
- `core-agent/vs2022/bind-dirs/bind-dirs.vcxproj` — built like `relocate-dir` (WDK toolset,
  km headers, `ntdllp.lib`).
- `tools/tests/bind-dirs/run.sh` — offline tests (gcc + in-memory fake FS with failure
  injection); `failproof.sh` re-introduces eight defects and proves the suite catches each.
- `guest/bind-dirs-status.ps1` — reads the result record on a guest and verifies the junctions.
