# Upstream diff for the chrome fix — blocked on a rebase, not written yet

Criterion (c) asks for a reviewed diff ready for the upstream PR. For the one criterion that is
verified - the Office chrome fix - that diff does not currently exist, and the reason is
structural rather than a matter of writing it up.

The commit chain in this fork is:

```
363bd6a  Phase 1A: per-frame timing instrumentation (QGAPERF)
6d46132  Phase 2A: event-driven window tracking (SetWinEventHook)
580328e  2A-chrome: reject owned click-through layered chrome
```

* `580328e` alone conflicts on upstream: the chrome predicate lives in the `ExamineWindow`
  path that `6d46132` rewrote, and depends on the rejected-window cache it introduced.
* `6d46132` alone also conflicts: it was written on top of the QGAPERF instrumentation.

So an upstream-ready diff needs `6d46132` + `580328e` rebased off `363bd6a`, with the QGAPERF
instrumentation either dropped or split into its own reviewable commit. QGAPERF is diagnostic
scaffolding for this project and is not obviously something upstream wants, so dropping it from
the PR is the likely shape - but that is a real rebase, not a formatting exercise, and it has
not been done.

The ACCESS_LOST patch (`upstream/access-lost-recovery.patch`, 6 commits, verified to build
standalone in CI) does exist and is clean, but the revised goal no longer lists ACCESS_LOST.
