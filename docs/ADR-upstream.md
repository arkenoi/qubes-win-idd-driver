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
patches were aimed at it when this was decided. So there is no upstream there to send a patch to,
and the library was assimilated into this project on 2026-11-07. By then the patches aimed at it had
grown from nine to thirteen; they are now one commit in a third repository of ours, carried beside
the two forks.

| § | decision | status |
|---|---|---|
| 1 | two repositories are forked, as submodules | ACCEPTED |
| 2 | four dependencies are cloned at a pinned version and patched | ACCEPTED |
| 3 | the vendored read-only checkout is local working material, never a build input | ACCEPTED |
| 4 | windows-utils is to be assimilated - it has no consumer outside QWT | ACCEPTED, DONE 2026-11-07 |

## The decisions in detail

## 1. The two repositories we rewrite are forks, carried as submodules

**Status:** ACCEPTED, in force since the project began.

**Decision.** `agent` → `arkenoi/qubes-gui-agent-windows` and `core-agent` →
`arkenoi/qubes-core-agent-windows` are our forks, added as submodules of this repository and pinned
by commit. Work happens in them directly. Submodules are pushed before the superproject, because CI
checks out the superproject's recorded commit and a parent pushed first races its own submodule.

**ENFORCED, since 2026-11-06, by `.githooks/pre-push`** - not by this paragraph. The ordering was
written here, and again in agent memory in capitals naming both submodules, and was still got wrong
three times (2026-10-07 core-agent, 2026-10-28 agent, 2026-11-06 core-agent at 7760000, the last
killing release-package run 42241372883 at checkout). The hook refuses a parent push while any
submodule SHA the pushed tip pins is unreachable on that submodule's own remote, and names the
submodule and the command that fixes it. Its limits are stated in its own header; read those before
trusting it rather than assuming the rule is now total.

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
| `qubes-windows-utils` | `v4.2.2` | 9 at the decision, 13 by 2026-11-07, none since: no longer cloned, see §4 |
| `qubes-gui-common` | `v4.3.1` | none |
| `qubes-core-vchan-xen` | `v4.2.7` | none |
| `qubes-core-qubesdb` | `v4.3.1` | none |
| `qubes-vmm-xen-windows-pvdrivers` | `v4.2.0-1` | 1, as a build-time edit script |
| `xeniface` | commit `9cd9a604` | none |
| `qubes-installer-qubes-os-windows-tools` | commit `14c189e4` | 2, as build-time edit scripts |

A ref is pinned, never a branch: a moving upstream would change what we build and what our suites
measure with no commit here saying so.

**THE TABLE READ "none" FOR TWO SOURCES WE DO MODIFY. Corrected 2026-11-08** from `qwt-full.yml`
rather than from the table: three of our changes to cloned upstream sources are PowerShell edit
scripts under `packaging/`, not `.patch` files under `patches/`, which is why a census of `patches/`
counted two and missed three.

| script | target | applied at |
|---|---|---|
| `patch-installer-drop-prepareprivateimg.ps1` | `installer-src/vs2022/installer/Package.wxs` | `qwt-full.yml:208` |
| `patch-installer-serialize-services.ps1` | the same `Package.wxs` | `qwt-full.yml:228` |
| `patch-xenbus-inf.ps1` | pvdrivers' `xenbus.inf`, then catalog regenerate + re-sign | `qwt-full.yml:792` |

All three FAIL THE BUILD if the edit does not apply (7, 12 and 14 `throw`s), the two installer ones
are re-counted in the patched source afterwards (`:211`, `:231`), and the serialized start is
verified in the BUILT MSI database (`:894`) - so the form is a script, but the proof is not weaker.
Cost 3 reaches all three: the shipped installer and INF exist in no checkout on disk. What keeps
them clear of §4's windows-utils failure is that nothing in the tree ASSERTS anything about them -
no suite reads a mirrored copy - so there is no instrument to mislead.

**Open (2026-11-08).** `qubes-installer-qubes-os-windows-tools` has no consumer outside QWT, which
is the measurement §4 assimilated windows-utils on. Two build-time edits are not thirteen patches,
so the cost side differs; nothing is decided here and no fork is proposed.

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
from a missing file. `test.yml` then materialised the mirror at the dev qube's commit, so the
reads happened for real in CI.

**RETIRED as an input, measured 2026-11-08.** Five counts, each read rather than argued:

1. **CI: zero.** No workflow names `upstream/ro`. `test.yml` fetches the `winutils` submodule and
   "nothing else is fetched for them" (`:204`, `:251`); the three suites of the Cost above read
   `winutils/` now, and nothing in the tree reads a mirrored `log.c`/`log.h`. The old Open - whether
   the CI mirror's pin and the dev qube's checkout agree - is MOOT: there is no CI pin any more.
2. **The forks are out of the mirror.** It holds twelve checkouts and not one of them is
   `qubes-gui-agent-windows`, `qubes-core-agent-windows` or `qubes-windows-utils`, so the set
   difference in `tools/upstream-emitters.py` now reports 6 of 6 vendored emitters with 0 also
   emitting in our tree, against the "6 of 34, the other 28" its committed output still recorded.
3. **One tracked consumer is left:** `tools/upstream-emitters.py` (`VENDORED` at `:28`, scanned at
   `:67`), an operator tool run by hand with `--write`. Its OUTPUT is tracked, CI reads only that,
   and `tools/sweep-gate.sh` takes the path field as a label it never opens (`up[fn] = src`,
   `:412`). The harm this section records - a fresh clone getting suites whose input lives on one
   qube - does not reach it.
4. **The other 17 mentions are citations, not inputs:** 13 `.md`, two `.txt` ledgers, one comment in
   `tools/log-sweep.py:266` and one in `packaging/patch-installer-drop-prepareprivateimg.ps1:23`.
   `.gitignore:27` stays - it is what keeps the corpus out of the public repo.
5. **Moving the corpus out of the repo tree is BLOCKED, not declined.** It is the one step that
   would retire the path NAME rather than the dependency, and it would stale the off-repo search
   index rooted at `upstream/ro` (30705 records), whose reindex waits on the owner's judgment on
   the 20 files its secret scan refuses.

So the search-corpus role this section ACCEPTED stands, and what the owner named is gone: no build,
no CI job and no suite reads the mirror.

## 4. windows-utils is to be ASSIMILATED - it has no consumer outside QWT

**Status:** ACCEPTED (maintainer), 2026-10-21. Sequenced AFTER the work in flight lands.
**DONE 2026-11-07** - see "Done" below.

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

**Done, 2026-11-07.** Point 2 held this behind the work in flight, and the stack grew from the nine
patches counted above to thirteen while it waited. It landed on 2026-11-07.

The fork is `arkenoi/qubes-windows-utils`, branch `qwt-4.3`: v4.2.2 plus all thirteen patches as ONE
commit, `e25cbc1` (6 files, +719/-116: `src/log.c`, `pipe-server.c`, `service.c`, `error.c`, `exec.c`,
`vchan-common.c`), pushed. Its message names the thirteen patches in the order the build applied them
and the file each touched, so the delta against v4.2.2 is `git diff v4.2.2 e25cbc1` inside `winutils/`.
It is carried in this repository as the submodule `winutils/` (`.gitmodules`, branch `qwt-4.3`), the way
§1's two forks are. `patches/windows-utils-*.patch` (13 files) and the steps in `build.yml` and
`qwt-full.yml` that cloned the pinned ref and applied them are deleted, and both workflows build
`winutils/` in place; `patches/` keeps the two xenvif patches (§2).

The gitignored mirror `upstream/ro/qubes-windows-utils` was never the shipped source: it sits at
`22e03f5` on branch `main`, while the build pinned `v4.2.2` and then applied the patches, so the
shipped source existed in no checkout on disk. §2's third cost and §3's mirror are about that gap, and
`winutils/` closes it for this library.

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
