# Architecture decision record — upstream dependencies: what we fork and what we patch

## In plain English

The Windows guest side of this project is built out of six upstream Qubes repositories. Two of them
we rewrite heavily, and those two we fork: our own copies, carried as git submodules, developed like
any other code here. The other four we barely touch, and those we do not fork: the build clones each
one fresh at a pinned version and applies our changes as patch files kept in this repository.

The reason for the split is how much we change. A fork is the right home for work that keeps going —
a few hundred commits, its own tests, its own history. A patch file is the right home for a single
defect fix that we would like upstream to take: the patch *is* the thing you send them, and it stays
readable as a diff instead of disappearing into a branch nobody else can see. Four forks of
dependencies we hardly modify would mean rebasing four repositories at every upstream release to
carry a handful of fixes.

That reasoning has held for five of the six. It no longer holds for one: the Windows utility library,
where our patch set has grown to nine patches and over five hundred changed lines, one of them a
wholesale rewrite of how logging works. That is a fork's worth of change being carried as patches,
and it has started to cost in ways a fork would not. This record states the decision as it stands and
names that exception as open.

| § | decision | status |
|---|---|---|
| 1 | two repositories are forked, as submodules | ACCEPTED |
| 2 | four dependencies are cloned at a pinned version and patched | ACCEPTED |
| 3 | the vendored read-only checkout is local working material, never a build input | ACCEPTED |
| 4 | the windows-utils patch set has outgrown §2 | OPEN |

## The decisions in detail

## 1. The two repositories we rewrite are forks, carried as submodules

**Status:** ACCEPTED, in force since the project began.

**Decision.** `agent` → `arkenoi/qubes-gui-agent-windows` and `core-agent` →
`arkenoi/qubes-core-agent-windows` are our forks, added as submodules of this repository and pinned
by commit. Work happens in them directly. Submodules are pushed before the superproject, because CI
checks out the superproject's recorded commit and a parent pushed first races its own submodule.

**Why.** These two carry the work: the window tracker, the capture engines, the broker, the
lifecycle, the RPC agent and its services. The change is continuous and the history matters.

**Cost.** Two extra pushes per change, in order. Rebasing onto upstream is a deliberate, occasional
act rather than something the build does.

## 2. Dependencies we barely change are cloned at a pinned version and patched

**Status:** ACCEPTED.

**Decision.** `build.yml` clones each dependency fresh at a pinned ref and applies our patches from
`patches/` as named steps:

| dependency | pinned ref | our patches |
|---|---|---|
| `qubes-windows-utils` | `v4.2.2` | 9, see §4 |
| `qubes-gui-common` | `v4.3.1` | none |
| `qubes-core-vchan-xen` | `v4.2.7` | none |
| `qubes-core-qubesdb` | `v4.3.1` | none |
| `qubes-vmm-xen-windows-pvdrivers` | `v4.2.0-1` | none |
| `xeniface` | commit `9cd9a604` | none |

A ref is pinned, never a branch: a moving upstream would change what we build and what our suites
measure with no commit here saying so. `gui-common` requires `>= v4.3.1` — earlier tags do not
compile under MSVC.

**Why.** Each patch is one named defect of the kind that goes upstream as a pull request — pipe EOF
classification, the service exit code, the blocking-read level, the interactive token. A patch file
is the upstream deliverable. Four forks would mean four rebases per upstream release to carry fixes
measured in tens of lines.

**Cost.** Three, each real:
1. A patch that stops applying reads as a product regression rather than as drift.
2. The patches are applied in the build only, so any environment that does not run those steps
   compiles unpatched sources.
3. The patched source exists in no checkout, so nothing in the tree shows what the shipped library
   contains. Suites that need to assert something about it must read a copy from somewhere.

## 3. The vendored read-only checkout is local working material, never a build input

**Status:** ACCEPTED.

**Decision.** `upstream/ro/` holds read-only checkouts of upstream repositories for reading and for
developing patches against. It is gitignored (`.gitignore:27`) and is not a build input: nothing in
`build.yml` reads it. A suite that needs it must report INCONCLUSIVE and exit non-zero when it is
absent, never pass.

**Cost, measured 2026-10-21.** Two suites read `upstream/ro/qubes-windows-utils/src/log.c` and were
listed in the CI estate. A clean checkout has no `upstream/ro`, so both reported INCONCLUSIVE, which
the offline runner counts red — so the estate was green on the dev qube and red in CI on every run,
and `campaign-preflight` refuses a release campaign on "CI is not green". A third suite read `log.h`
and reported "LOG_DEFAULT_DIR changed" from the file's absence, which is a claim about upstream made
from a missing file. `test.yml` now materialises the mirror pinned to the same commit the dev qube
holds, so the reads happen for real in CI; the third suite now reports INCONCLUSIVE and exits 2.

**Open.** The CI mirror's pin and the dev qube's checkout are the same commit today by hand. Nothing
asserts they agree.

## 4. The windows-utils patch set has outgrown §2

**Status:** OPEN — stated, not decided. Needs the owner's call.

**Context, measured 2026-10-21.** `patches/windows-utils-*.patch` is nine patches, **+531 / −103**:

```
one-log-per-module      +260  -36      service-exit-code        +52   -3
pipe-connect-rewrite     +96  -47      pipe-eof                 +35   -5
pipe-client-null         +41   -1      loginit-banner-debug     +15   -7
interactive-token        +12   -1      vchan-blocking-read      +12   -2
percall-mechanics-debug   +8   -1
```

`one-log-per-module` alone rewrites how the library logs. The costs in §2 are no longer hypothetical:
the patched source is in no checkout (§2 cost 3), which is exactly why three suites reach into a
gitignored mirror and why the CI estate was red for weeks (§3). A rename inside that patch set has
already broken five consumers in this repository.

**The case for forking it.** The shipped source would be in-tree, readable and testable without a
mirror; the three suites would read the real thing; the patch-application steps and their failure
mode would go away. Upstreaming becomes `git format-patch` against the fork, which is what we send
anyway.

**The case against.** A sixth rebase target, and a fork hides the delta that nine named patches make
obvious at a glance.

**Owed.** Nothing here is measured against a fork, because no fork exists. The measurement that would
settle it is the cost of one rebase of `v4.2.2` → current upstream with our 531 lines on top.
