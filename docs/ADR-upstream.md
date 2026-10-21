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

That reasoning holds for four of the five dependencies, and for the two patches we aim at the Xen
Project's network driver - code with thousands of users who are not us. It does not hold for the
Windows utility library. Nothing outside the Windows tools consumes it: no Linux component, no dom0
component, no package. Its only consumers are this project's own two forks, the installer, and the
Windows halves of two other libraries - all of them parts of the same product. Nine of our eleven
patches are aimed at it. So there is no upstream there to send a patch to, and the library is being
assimilated into this project once the current work lands.

| § | decision | status |
|---|---|---|
| 1 | two repositories are forked, as submodules | ACCEPTED |
| 2 | four dependencies are cloned at a pinned version and patched | ACCEPTED |
| 3 | the vendored read-only checkout is local working material, never a build input | ACCEPTED |
| 4 | windows-utils is to be assimilated - it has no consumer outside QWT | ACCEPTED |

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
measure with no commit here saying so.

**THE TWO XENVIF PATCHES ARE THE ONLY ONES AIMED AT A REAL UPSTREAM.** `xenvif/frontend.c` belongs
to the Xen Project, outside Qubes altogether (maintainer 2026-10-21: "xenvif is xen, it is even
outside the qubes"), and every Windows guest on Xen uses it whether or not QWT is installed. A
patch file is exactly the right form there: it is the deliverable, and the delta stays legible
as a diff against code we do not own.

`gui-common` requires `>= v4.3.1` — earlier tags do not compile under MSVC.

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

## 4. windows-utils is to be ASSIMILATED - it has no consumer outside QWT

**Status:** ACCEPTED (maintainer), 2026-10-21. Sequenced AFTER the work in flight lands.

**Context, measured 2026-10-21.** §4 was first written as "the patch set has outgrown the rule",
with the cost given as +531/-103 across nine patches, one of them a 260-line rewrite of the logging
core. That framing was understated, and the measurement that corrects it is this: **nothing outside
QWT consumes `qubes-windows-utils`.** Every reference to it in the thirteen mirrored upstream repos:

```
qubes-core-vchan-xen/windows/README.md          the Windows half of vchan
qubes-vmm-xen-windows-pvdrivers/README.md       the Windows PV drivers
qubes-installer-qubes-os-windows-tools/*        the QWT installer itself
qubes-builderv2/.../build-qwt.ps1 + 3 configs   the build recipe for QWT
```

No Linux or dom0 component consumes it; no package declares a dependency on it. Its Windows-side
consumers are `gui-agent-windows` and `core-agent-windows` - **both already our forks** - plus the
installer and the Windows halves of vchan and qubesdb, all of which are QWT. For contrast,
`gui-common` is a genuine shared upstream: `qubes-gui-daemon` (dom0: `xside.c`, `shmoverride.c`) and
`qubes-gui-agent-linux` (`vmside.c`) both consume it, so a change there reaches someone else.

And the alignment is total: **nine of our eleven patches target the one dependency with no other
consumer.** The maintainer's reading, which the measurement supports: it is "single source in
disguise".

**Decision.**
1. `qubes-windows-utils` is **assimilated** into this project: its source becomes ours, carried in
   tree, and the nine patches become ordinary history rather than a stack applied at build time.
2. This happens **after the work in flight lands** - it is not a reason to hold anything up now.
3. `xenvif` stays as patches (§2): it is Xen's, outside Qubes, with consumers who are not us.
4. The four dependencies we do not modify stay pinned clones (§2). Assimilation is for what we
   change, not for what we merely use.

**Why.** The one honest argument for the patch form is that a patch file is the upstream
deliverable. That argument does not survive the measurement: there is no upstream consumer to
deliver to. What the form does cost is not hypothetical - all of it was measured on 2026-10-21:
the +531/-103 delta exists in NO checkout, so three suites read a gitignored mirror to assert
anything about the shipped source; CI was therefore red on every run for weeks, which is what
`campaign-preflight` refuses a release campaign on; and it is a rebase target nobody rebases.

**Cost.** A sixth tree to carry, and the nine named patches stop advertising the delta at a glance -
that legibility has to be replaced by history and by the suites. Assimilation also removes the
ability to say "this is upstream's code" about a defect in it, which is a cost worth naming: after
this, `src/log.c` is ours and its defects are ours.

**Open.** What the assimilated tree's relationship to upstream's own future commits should be -
periodic merge, cherry-pick, or nothing - is not decided here.
