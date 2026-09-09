# QWT-NG 4.3.22

Every binary in this package can now be asked which build produced it, and the release that carries
them cannot be cut by hand. Both exist because of a near-miss: two 4.3.21 asset directories built
from different commits were **indistinguishable by their labels**, and the wrong one nearly shipped.

## Every shipped binary carries the release version

`FILEVERSION = <release>.<build_rev>` on all 19 binaries we build — inside the MSI and in the setup
tree — stamped from one generator driven by `agent/version` and the release-package run number.

Before this, the core-agent executables were stamped `4.2.2.0` — *identical to stock*, so nothing in
a shipped `qrexec-agent.exe` distinguished our build from Invisible Things Lab's. The five
user-session helpers (`wgcbroker`, `notifhost`, `etwproxy`, `qwt-bootstrap`, `qubesdb-read`) had no
version resource at all. The IddCx driver used a wall-clock minute counter that mapped back to
nothing; its INF `DriverVer` is now pinned to the release version too.

**What this is not.** It does not fix MSI upgrades — `REINSTALLMODE=amus` already neutralises the
Windows Installer per-file versioning rule. The value is per-component *assertability*: the release
verifier asserts each shipped file's version, and a guest can be asked what it is running component
by component.

## The release process is mechanized, and takes a build rather than a directory

`tools/cut-release.sh` no longer accepts a directory of assets. It is given a **release-package run
id** and fetches, verifies, publishes and re-verifies the bytes itself.

The argument *was* the defect. Every release failure this project has had came from choosing which
bytes to act on and being wrong about them: a stale asset directory that nearly shipped as 4.3.21; a
chain script verifying one package while acceptance ran another; a tag landing on `HEAD` instead of
the commit the package was built from; a release published on a partial check. More checks on a
named directory cannot help, because a check that runs on the named directory is as wrong as the
name.

Each link fails closed:

- the run must be `release-package`, completed, successful
- **three provenance bindings** must agree: manifest `ci.run_id` == the run, build commit == run
  head, `build_rev` == run number
- the tag targets the **build commit** (and must be an ancestor of `HEAD`), so a published release
  can be checked against the source that produced it — `v4.3.21`'s tag pointed at `37383a58` while
  its package came from `3245867d`
- the package is verified as fetched, not as named
- **full acceptance must have run on these exact bytes**: the record is keyed by the ISO's own
  SHA-256, derives its verdict and cell list from the campaign logs rather than accepting them as
  arguments, and there is deliberately no flag to skip it
- after publishing, the assets are downloaded back and byte-compared against what was verified

## PowerShell is checked against the version that runs it

CI parsed `.ps1` files with PowerShell 7 while every guest invocation is Windows PowerShell 5.1, so
a ternary, `??`, `??=` or a `&&`/`||` pipeline chain parsed green in CI and was a **syntax error on
the guest**. `PSUseCompatibleSyntax` against 5.1 now gates both CI and pre-commit, alongside a parse
check that covers the whole repo rather than two directories.

## Watchdog service lifetime

Token handles leaked on every agent launch, and the `GetCurrentProcess()` pseudo-handle was closed
instead of the real one. `ServiceMain` joined its worker thread with no bound. `PRESHUTDOWN` reported
`SERVICE_STOPPED` from the handler while the respawn loop was still running, so the SCM believed the
service gone while it was still live.

That last one reverses `b51a09f`, which fixed a **three-minute stall on every clean shutdown**. Its
premise — a worker thread that never exits — is obsolete: the thread now waits on the stop event and
exits in milliseconds. The join is bounded at 10 s so the stall cannot return even if that changes.

## A shutdown fault nothing could see

`health-check` filtered the System log from `LastBootUpTime`, but Event 7043 is written *during
shutdown* — always before that boundary — and was separately exempted from failing. Acceptance could
not detect it on any guest, ever, which is why the three-minute stall above was found by reading a
log by hand. The new `prev_shutdown_clean` check looks in the window ending at this boot; an
unreadable window fails, because a shutdown that could not be read is not a shutdown that was clean.

## Known open

- **The install's stage-1 reboot is not deterministic, and ~1 clean install in 14 strands the guest.**
  Measured across 14 recorded clean installs: the guest-initiated reboot leaves the Xen domain
  **halted** in 8 runs (the next start is a fresh domain, the PV bus binds, all fine) and
  **warm-resets it in place** in 6. A warm reset usually still rebinds the PV bus — but in one of
  those six it did not, and that guest was left booting to a desktop with **no qrexec and no window**:
  from outside, indistinguishable from a hang. Stage 2's activation of the IddCx driver disables the
  emulated VGA adapter, so the last means of seeing the guest goes away exactly when it is needed.
  This is **not new in 4.3.22** — 4.3.21 shipped with the same behaviour and the same odds; it is
  newly *measured*. If you hit it: the resume task is still armed, so shutting the qube down and
  starting it again resumes the install. Root-causing the halt-vs-warm-reset split, and deferring IDD
  activation to a boot where qrexec is already up, are both under active investigation.
- **Only 5 of 16 core-agent binaries ship from our build.** The rest still come from the stock image
  and always have, so stamping reaches five of them. Pre-existing, not a regression; closing it means
  deciding to ship eleven more binaries, which is a scope change rather than a packaging detail.
- **Boot-to-qrexec varies 15–38 s, cause unknown.** An earlier reading of this ("~10 s slower on
  non-clean guests, disjoint") was retracted: it rested on two samples against four, and the fuller
  set (n=22) overlaps completely. The noise floor has to be established before any comparison means
  anything.
- Two audit findings live in `upstream/ro/**`, a read-only reference checkout, and cannot be fixed
  here.
