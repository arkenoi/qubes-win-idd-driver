# packaging/version-stamp — one version, stamped into every binary

## What this is for: per-component assertability

Every binary this project ships should carry `FILEVERSION == <release>.<build_rev>`, so that a
file — not just a package — can be asked *which build produced you*. That is the whole
justification, and it comes from a real incident: two 4.3.21 asset directories built from
different driver-repo commits both read `package_version = 4.3.21+agent.a1956929c319` (the fix was
driver-repo-only, so the agent sha did not move) and nothing but `MANIFEST.json`'s
`source.driver_repo_commit` and a grep for the fix itself told the stale one from the right one.
With the fourth field stamped from the release-package run number, every OURS binary in those two
directories differs in version (e.g. `4.3.21.415` vs `4.3.21.416`), the release verifier's
`OURS_VERSION` gate can assert the build per file, and a guest can be asked what is installed
component by component.

Before this directory existed: the core-agent exes were stamped `4.2.2.0` (== stock), the five
helpers (wgcbroker, notifhost, etwproxy, qwt-bootstrap, qubesdb-read) had no version resource at
all, and the driver used a wall-clock minute counter nobody could map back to a release.

## What this is NOT (read before repeating an old claim)

- **It does not fix MSI upgrades.** The Windows Installer per-file versioning rule ("keep an
  installed file whose version is >= the incoming one") is already neutralised by the installer:
  `packaging/setup/Install-QwtImproved.ps1` passes `REINSTALLMODE=amus`. An equal or lower
  FILEVERSION would be overwritten regardless of anything here.
- **Same-version rebuilds are not an install path.** The MSI ProductVersion uses only the first
  three fields, and `tools/cut-release.sh` invariant 2 refuses a release whose version already has
  a tag (the v4.3.0/v4.3.1 same-ProductVersion case). "Package B of version X installs over
  package A of version X" never happens through the installer, so nothing here is designed for it.

## The mapping

```
agent/version           MAJOR.MINOR.PATCH            e.g. 4.3.22     (3 fields, each 0..65535, enforced)
QWTNG_BUILD_REV         see "the fourth field"       e.g. 517        (0..65535, enforced)

FILEVERSION          =  MAJOR , MINOR , PATCH , BUILD_REV               4,3,22,517
FileVersion string   =  "MAJOR.MINOR.PATCH.BUILD_REV"                  "4.3.22.517"
INF DriverVer        =  mm/dd/yyyy , MAJOR.MINOR.PATCH.BUILD_REV       09/09/2026,4.3.22.517
MSI ProductVersion   =  MAJOR.MINOR.PATCH.0  (unchanged: qwt-full.yml's installer-src\version step)
```

A VERSIONINFO field is a 16-bit integer, so every input is checked against 65535 — `rc.exe` would
silently truncate a larger value into a *wrong but valid-looking* version.

**The fourth field** has three producers whose values never overlap:

| producer | `QWTNG_BUILD_REV` | reads as |
|---|---|---|
| `release-package.yml` | that run's `github.run_number` (always >= 1), exported to every job and passed as `build_rev` to the reusable workflows | a release build |
| `build.yml` (dev overlay) | `0`, set **explicitly** | not a release — the exact shape the release gates reject |
| a local build, variable unset | `0` with a warning | same as the overlay |

Two independent run counters in one field would let a dev overlay out-number a later release; `0`
is the one value a run number never takes, so the overlay namespace is `<ver>.0` and nothing else.
In CI (`GITHUB_ACTIONS` set) an *unset* variable is an error (`MISSING_BUILD_REV`), never a
default: a release build that quietly stamped `.0` would look like a local build and tell nobody
which run produced it. An explicit `0` in CI is accepted (that is the overlay contract).

## Files

| File | Role |
|---|---|
| `../../tools/stamp-version.ps1` | **The one generator.** CLI-identical to qubes-builderv2's `set-version.ps1 <versionfile> <header>`, so CI copies it over builderv2's and every existing `$(QB_SCRIPTS)\set-version.ps1` call (gui-agent, watchdog, windows-utils, core-agent) stamps `<ver>.<rev>` with no source change in those repos. Emits the `QWT_*` (builderv2), `QIDD_VER_*` (driver) and `QWTNG_*` macro families. `-Print` resolves the 4-field string for workflows and the INF stamper. Self-contained by design — it is copied alone. Resolves all paths once against `$PWD` (System.IO follows the *process* cwd; a `Set-Location` caller would otherwise test one file and write another). |
| `qwtng_version.rc` | Shared VERSIONINFO for repo projects that have no .rc of their own (the five shipped helpers). Clone of `agent/include/version_common.rc` with this fork's ProductName/CompanyName. `#error`s without a FileDescription — a compile break, not a PASS line. |
| `qwtng-version.props` | MSBuild import for repo vcxprojs: target `QwtNgStampVersion` (BeforeTargets=ResourceCompile) runs the generator into **`$(IntDir)qwtng_version.h` — per project** — and compiles `qwtng_version.rc` with `$(IntDir)` on its include path. Requires `<QwtNgFileDescription>`. |
| `stamp-inf-driverver.ps1` | The ONE INF `DriverVer` stamper (replaces two copy-pasted epoch-minute blocks in build.yml and release-package.yml). Version via `stamp-version.ps1 -Print`; refuses 0 or 2+ DriverVer lines; detects UTF-16LE-BOM / UTF-8-BOM / BOM-less UTF-8 and writes the same encoding back with a **strict** decoder — a BOM-less INF with a byte that is not valid UTF-8 fails `INF_ENCODING` and is left untouched (the lenient decoder used to rewrite a Latin-1 `0xA9` as `EF BF BD` elsewhere in the file while the DriverVer line looked perfect). |
| `selftest.sh` | Fail-proofs, runnable in the dev qube with pwsh. Every code in the table below has a case; each INF encoding is byte-compared against an independently built expectation; two mutation proofs (a stamper defaulting the CI rev to 0; a lenient INF decoder) show the selftest itself can fail. Exit 3 = no pwsh = NOT CHECKED. Re-run whenever either stamper changes. |
| `../../core-agent/vs2022/qwt-version.props` + 17 vcxproj imports | core-agent wiring (fork submodule): each project regenerates **its own `$(IntDir)qwt_version.h`** before its ResourceCompile via `$(QB_SCRIPTS)\set-version.ps1` (or `-p:QwtSetVersionScript=`); `src/version_common.rc` includes `"qwt_version.h"` and finds it through `$(IntDir)` on the RC include path. Build ORDER can no longer decide what version an exe carries, and 17 projects no longer write one shared file (a race under a parallel/IDE build; Windows PowerShell's `Move-Item -Force` is delete+move, so no write strategy makes a shared file safe). qrexec-agent's duplicate PreBuildEvent call was removed. |

## Failure codes — only codes with a fixture in `selftest.sh` are listed

Each is one `<tool>: FAIL code=<CODE> k=v` line on stderr, then a throw (non-zero exit for
msbuild `<Exec>`, a workflow step, or an in-process call alike).

| Code | Emitted by | Fixture(s) in selftest.sh |
|---|---|---|
| `BAD_VERSION_FILE` | stamp-version | version file `4.3.21.0`, `4.3`, `4.3.70000`, empty, nonexistent; no header written |
| `MISSING_BUILD_REV` | stamp-version | in CI: unset, empty, `70000`, `abc`, `-1`; outside CI: `abc`; no header written. Mutation proof: a stamper defaulting the CI rev to 0 is caught |
| `USAGE` | stamp-version | no arguments; version file but no header |
| `BAD_FILEDESCRIPTION` | stamp-version | a quote; a backslash; 121 chars (120 accepted) |
| `INF_MISSING` | stamp-inf-driverver | nonexistent INF |
| `INF_DRIVERVER_COUNT` | stamp-inf-driverver | INF with 0 and with 2 DriverVer lines |
| `BAD_DATE` | stamp-inf-driverver | `-Date 2026-09-09` |
| `INF_ENCODING` | stamp-inf-driverver | BOM-less INF containing `0xA9`; file byte-identical afterwards. Mutation proof: a non-throwing decoder is caught |
| `STAMPER_MISSING` | stamp-inf-driverver | script copied to a directory with no `../../tools/stamp-version.ps1` |

Positive properties asserted alongside: every header macro line; CRLF + ASCII; a header is a pure
function of its inputs (same rev from `-BuildRev` vs env leaves it byte-identical and untouched);
relative paths resolve against the caller's `$PWD`; explicit `0` in CI stamps `.0` without a
warning; for each INF encoding (UTF-16LE BOM, UTF-8 BOM, ASCII, BOM-less multibyte UTF-8) the
stamped file is `cmp`-identical to an expectation built without the stamper.

**Deliberately absent** (they could never fail, so they were removed rather than kept as
decoration): a re-read of the INF after writing (re-decoding with the identical encoder cannot
disagree); a regex check on `-Print`'s output (already validated inside the generator); an
`IntDir == ''` Error task (Microsoft.Cpp.props always assigns it); "generator exited 0 but wrote no
header" Error tasks (every exit-0 path writes or finds it; a missing header surfaces as RC1015).

## Build breaks in the .props files — UNPROVEN until a Windows build has failed on each

These are MSBuild `<Error>` tasks, not gates that print a verdict. They can only be exercised in a
Windows build, and per the repo rule they count as evidence only once seen to fail:

| File | Break | Fixture (to run once, in CI or a Windows checkout) |
|---|---|---|
| `qwtng-version.props` | no `<QwtNgFileDescription>` | import the props without the property |
| `qwtng-version.props` | generator missing | `-p:QwtNgStampScript=C:\nonexistent.ps1` |
| `qwtng-version.props` | version file missing | build with the `agent` submodule not checked out |
| `core-agent qwt-version.props` | no generator resolves | `QB_SCRIPTS` unset and no `-p:QwtSetVersionScript` |
| `core-agent qwt-version.props` | generator missing | `-p:QwtSetVersionScript=C:\nonexistent.ps1` |
| `core-agent qwt-version.props` | version file missing | delete `core-agent/version` |
| target is load-bearing | RC1015 on `qwt_version.h` | remove the import from one core-agent project **after** the CI up-front header generation (`qwt-full.yml`, `build.yml`) has been deleted |

That last row is why the up-front generation in the workflows must go in the same change as the
imports: with a pre-generated header the build stays green even if the per-project target never
runs, which masks exactly the failure the target exists to make visible.

## What still has to be wired outside this directory

Other owners / other repos: the CI shadow copy of `stamp-version.ps1` over builderv2's; the
"unify version files" step driven from the *shipped* binary set (every shipped binary needs a known
version file **and** a generator call, else the step throws — `libxenvchan.dll` from
`deps-src\pvdrivers` is the known case with neither); `QWTNG_BUILD_REV` / `build_rev` plumbing in
`release-package.yml` and the reusable workflows, and `QWTNG_BUILD_REV: '0'` in `build.yml`; the
five `tools/*` vcxproj imports; the driver vcxproj PreBuildEvent + un-tracking
`driver/IddSampleDriver/qidd_version.h`; replacing the two epoch-minute stamp blocks with
`stamp-inf-driverver.ps1`; deleting the up-front `qwt_version.h` generation in both workflows;
the agent submodule's watchdog PreBuildEvent hardening. The exact patch text is in the (untracked)
hand-off document the previous round produced; the contract every patch relies on is the one at the
top of `tools/stamp-version.ps1`.
