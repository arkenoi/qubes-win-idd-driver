# ADR - acceptance: what the gate runs for a release, and what forces it to run everything

## In plain English

Before this, every release ran the whole acceptance: eight installs across Windows 10 and 11 (clean, same-version
reinstall, upgrade, and an AppVM made from the installed template), plus the feature tests. Hours of the rig, and it
locks the owner out of their own screen for the parts that photograph windows.

From now on a release runs what its own changes can break, plus a small core that every release runs whatever was
edited, and the gate still runs **everything** whenever any of four things is true. A script works out which suites
are required from the diff and refuses to let a release be cut if the gate did not cover them. What each release
actually covered is written down in a file anyone can read, and that file is where the counting comes from - nobody
asserts "it has been fewer than ten releases", the script reads it.

The core, every time: the package's own identity check, one clean install and one upgrade on Windows 11, the test
that dom0 is told about errors, and the log sweep that reads the guest's logs after the run.

The gate runs everything when: a path the map does not mention was touched (so adding a new directory can never
quietly shrink the gate); ten releases have passed since the last full run; three weeks have passed; the previous
full run failed; or the map itself changed.

The danger in any scheme like this is a shared helper - a library half the repo uses - mapping to its own small
corner while affecting everything. So before anything is mapped, a changed file expands to every file that uses it,
and those are mapped too.

What is accepted is a build, not the state of the repository. Each package the CI produces gets a tag naming it,
and every verdict the gate records is written against that tag, one verdict per test module, kept across runs. A
fix to a test instrument lets that module be measured again; a documentation or harness commit in between changes
nothing about what was already measured, and nothing has to be re-run for it.

## The decisions at a glance

| § | decision | status | date |
|---|---|---|---|
| 1 | A release's gate is scoped to what its diff touches, over an always-run core | ACCEPTED (owner) | 2026-10-07 |
| 2 | An unmapped path requires the full gate | ACCEPTED (owner; Jev 0.97) | 2026-10-07 |
| 3 | A floor forces the full gate on whichever of four conditions comes first | ACCEPTED (owner; Jev 0.96) | 2026-10-07 |
| 4 | The scheme is computed and refusing, not written down | ACCEPTED (owner; Jev 1.00) | 2026-10-07 |
| 5 | A changed file expands through its reverse-dependency closure before it is mapped | ACCEPTED (Jev 0.62 named the hazard) | 2026-10-07 |
| 6 | 4.3.36 was cut on `core` by owner override, recorded as an override | RECORDED (owner) | 2026-10-16 |
| 7 | The identity of what is accepted is the build tag; verdicts are per module and accumulate | ACCEPTED (owner) | 2026-11-11 |

Status words and the section format are defined in `docs/ADR-README.md`.

**This REPLACES** the standing rule "full acceptance before a release is a GATE - never downgrade to a partial check
and ship", which was written after 4.3.19 was cut on a partial check and shipped broken. That rule is not weakened by
accident here; it is replaced deliberately, by the owner, and the floor plus the unmapped-path default are what keep
its intent.

---

## 1. The gate is scoped to the diff, over an always-run core

**Status:** ACCEPTED (owner), 2026-10-07.

**Context.** The owner: *"i doubt we need fault injection on this path for every acceptance run. we may optimize our
acceptance a bit depending on what we touch and run full fault injection path and all install variants only when we
touch certain things or once in 10 updates or so."*

What the evidence says about the cost and the value:

- The 4.3.35 gate was clean - 14/14 package checks, 96/0 across eight install cells, three feature tests green - and
  it found nothing.
- The two defects that actually reached users in that period were found by the field reporter on his own environment,
  and by a dom0 dialog nobody could explain. The second was a shutdown-ordering defect that had been logged at ERROR
  on every boot for weeks, and **no cell asserts anything about it**.
- Each install variant does cover a distinct path: a reinstall is the only cell that ever showed `svc_msi_started`,
  because it is the only one where the previous install's service objects survive with their recovery armed.
- The fault-injection suites are narrow and demonstrated: M8 proves the broker's hang detection fires within 2 s, and
  it exercises the capture path only.

So the cost is real, the value is uneven, and a cheaper instrument now exists for the class of defect the cells miss:
the log sweep reads every guest log after any cell and fails the run on a new signature or a metric breach.

**Decision.** `mgmt/gate-scope.json` maps path patterns to the suites they require, each with a reason. A release's
requirement is the union of what its changed files require, plus the core: the package identity check, one clean
install and one upgrade on Windows 11 (the primary target), the error-notification test, and the log sweep over every
guest the run touched. Jev chose that core at 0.60, over "package and sweep only" (0.08) and "all eight cells always"
(0.14).

## 2. An unmapped path requires the full gate

**Status:** ACCEPTED (owner; Jev 0.97), 2026-10-07.

**Decision.** A changed file that matches no pattern is unknown risk: the full set is required and the file is named,
so the fix is either to map it or to accept the full gate. Adding a directory, a helper or a new component therefore
fails safe. This is the single property that keeps the scheme honest as the code grows, which is why Jev put it at
0.97 against "require only the core and let the maintainer add a mapping" (0.01).

## 3. The floor: whichever comes first

**Status:** ACCEPTED (owner; Jev 0.96), 2026-10-07.

**Decision.** The full gate runs when any of these is true:

| condition | why |
|---|---|
| **10 releases** since the last passing full gate | the owner's "once in 10 updates" |
| **21 days** since it | releases come in bursts - 4.3.33, 4.3.34 and 4.3.35 were cut in five days; counting releases alone would let a quiet month drift |
| the previous full gate **failed** | a failure is not a full run |
| `mgmt/gate-scope.json` itself **changed** | the map decided the last scoping; a new map has never been measured |

The floor is **computed from the ledger** by the same script that refuses the cut. Jev put "the floor is recorded but
never enforced" at 0.33 of what could go wrong, so no part of it is left to a human to assert.

## 4. Computed and refusing, not written down

**Status:** ACCEPTED (owner; Jev 1.00), 2026-10-07.

**Context.** Every rule in this project that mattered and was prose has been walked past - which is why the
serial-rig PreToolUse hook, the lint rules and the claim-receipt gate exist at all.

**Decision.** `tools/gate-scope.py`:

- `required <base>..<head>` prints the suites and, for each, the file and the reason that asked for it;
- `floor` says whether the floor trips and on which condition;
- `check <coverage.json>` compares what the gate covered against what is required and **exits non-zero naming each
  missing suite** - the refusal;
- `ledger-add` appends a release's record to `mgmt/gate-ledger.json`.

The coverage file `check` reads is `scratchpad/gate-coverage-<build tag>.json` - one per build, written and merged
only by `tools/coverage-receipt.py` (§7) - and the range it is checked over is the PACKAGE's: the newest release tag
before the build commit, to the build commit. Both the hook (`tools/hooks/release-cut-gate.sh`) and the cut
(`tools/cut-release.sh --run <id>`) resolve the run's build tag and compute that range themselves; neither reads HEAD.

Missing or unreadable data exits 2 - never "nothing was required". `tools/tests/gate-scope-selftest.sh` drives the
whole thing against a fixture repository with its own history, map and ledger: 17 checks, including each floor
condition on its own, a negative control where the floor must NOT trip, the refusal, and two defect knobs - a
catch-all pattern (so an unmapped path requires nothing) and the closure switched off - each seen to make the suite
fail.

## 5. A changed file expands through its reverse-dependency closure

**Status:** ACCEPTED (Jev named the hazard at 0.62), 2026-10-07.

**Decision.** Before mapping, a changed file expands to every file that uses it - bash `source`, PowerShell
dot-sourcing, python imports, C includes, and a harness naming another script - transitively. The closure is what
gets mapped. Without it, a library the installer dot-sources would map to "a shipped guest script" and the install
variants would never run.

---

## 6. 4.3.36 is cut on `core`, by owner override, and that is recorded as an override

Owner, 2026-10-16 ("go 3"): cut on the `core` set - `package-verify win11-clean win11-upgrade
notify-errors-guest-test log-sweep` - rather than the 18 this scheme computed as required.

THE FACTS THE DECISION WAS TAKEN ON, all measured that day:

* `gate-scope required` asks for the FULL 18 because 6 paths are UNMAPPED (`agent`, `core-agent`,
  `protocol/run.py`, `protocol/selftest.sh`, `protocol/failproofs.json`,
  `contrib/auto-qwt/qwt-ng-fix-qwcq`). The time floor is NOT what forced it: `0 release(s) and
  9 day(s) since the last full gate (4.3.35)`.
* **18 has never been reached.** Across the 23 `scratchpad/gate-coverage-*.json` receipts the
  maximum ever recorded is 12. `gate-remainder` exists to close that 12 -> 18 gap and, on its first
  live run, closed 1 of 6 - and not one of the five failures was a product defect (a missing build
  artifact, a slice boundary, a gate counting the test's own notifications, and two baselines that
  refused to attribute a later red).
* The receipt was keyed per-HEAD and not accumulated, so committing between runs discarded
  coverage, and assembling 18 required one frozen sha for ~7 h of serial rig time. (True on
  2026-10-16; SUPERSEDED by §7 on 2026-11-11 - the receipt is keyed by the build tag and
  accumulates per module.)

WHY IT IS AN OVERRIDE AND NOT A NEW RULE. This repository's standing rule is "full acceptance
before release is a GATE - never downgrade to a partial check and ship". Section 3's floor is
deliberately unchanged, so the next release still owes a full gate, and the floor also trips on any
edit to `mgmt/gate-scope.json` - which is why narrowing the map (the obvious "fix") cannot take
effect until a full 18-suite run has validated it. Nothing here makes `core` the bar; it records
that one release was cut below the computed bar, with the reasons above on the record.

Both routes to a genuine 18/18 are planned and DEFERRED under GATE18NEVERREACHED in
findings/issues.md, with per-suite estimates.

## 7. The identity of what is accepted is the build tag; verdicts are per module and accumulate

**Status:** ACCEPTED (owner), 2026-11-11.

**Context.** Owner, 2026-11-11, verbatim: *«we are not accepting "head", we accept a precise build»*; *«take separate
verdicts by modules, make instrument fixes never invalidating those verdicts»*; *«i asked you to use fucking tags, you
made tags and now you do not use it!»*; *«it costs us a new full acceptance run on every minor documentation change or
harness fix»*.

What the code did, measured at 4f342c72: `tools/release-acceptance.sh` named the receipt `git rev-parse HEAD` read at
the END of a multi-hour run and checked it over `<last release>..HEAD`; `tools/gate-remainder.sh` keyed its receipt and
its output directory on HEAD and its own inline merge wrote the harness sha as `built_from`; `mgmt/harness/campaign-full.sh`
"resolved everything from HEAD" - it listed the successful `release-package` runs whose head was HEAD, refused when
there were none, and read the newest `gate-coverage-*.json` by mtime at the end; `tools/hooks/release-cut-gate.sh`
read the receipt, CI and the scope range for HEAD; `tools/cut-release.sh` fell back to the newest receipt by mtime
whose sha descended from the build; `tools/acceptance-plan.py` fell back to HEAD when the run's sha could not be read
and defaulted its range to HEAD. 126 annotated tags `build-<version>.<run number>` existed (written retrospectively on
2026-11-10, e.g. `build-4.3.40.1257` -> 01e6d48a47b3) and nothing read them. A harness or documentation commit between
two runs therefore split one build's coverage across two files and the cut found neither, which is why §6 recorded
"assembling 18 requires one frozen sha for ~7 h".

**Decision.**

1. The identity of what is accepted is the build tag `build-<version>.<run number>`: an annotated tag on the head sha
   of ONE successful CLEAN `release-package` run, where version is the `version` file of the agent gitlink at that
   head. The acceptance never names HEAD; the harness commit appears only as the provenance of each verdict.
2. `tools/build-tag.sh create <run>` creates the tag LOCALLY, before any suite runs, idempotently, after verifying:
   workflow `release-package`, conclusion success, the run's own build log reads `QGA_FAULT_INJECTION=0`, the head sha
   is an ancestor of `origin/main`, and the agent's version at that head is readable. An existing tag must point at
   that head and name that run, else it refuses. The tool never pushes a tag (a single-tag push fires
   pv-xencons.yml / pv-xenvif.yml / winenum; publishing stays a deliberate act). Its `fi-flag` is the one
   implementation of the injection proof; the chain reads the FI run through it.
3. The receipt is `scratchpad/gate-coverage-<build tag>.json`, one per build. It holds a MODULE map - a module is what
   the receipt used to call a suite: package-verify, each matrix cell, each feature test, each remainder suite - and
   each entry records class, harness (full sha of the checkout that ran it), run (the evidence dir), attempt, at (UTC),
   package run, and the FI run where it applies. `suites` (pass + product-fail = covered), `product_fail`,
   `instrument_fail`, `not_run`, `result` and `classes` are RECOMPUTED from the map on every write.
4. The merge rule, per module: an instrument-fail or not-run NEVER replaces a measured verdict (pass or product-fail);
   a measured verdict replaces an instrument-fail or not-run; a measured verdict replaces an earlier MEASURED verdict
   ONLY when the run that produced it records a different harness commit - so an instrument fix takes effect, and a
   re-run with no change cannot turn a product-fail green. The rule lives in ONE place,
   `tools/coverage-receipt.py` (`merge_module`), and every writer goes through it: the acceptance from the campaign's
   own JSON, the remainder as `--module <suite>=<class>` words.
5. The chain takes the build explicitly - `BUILD=<tag>` or `PKG=<run>`, which it turns into the tag - plus `FI=<run>`,
   a fault-injection dispatch run at the SAME head sha proven `=1` from its log. Discovery by HEAD is gone. The
   preflight's product-drift check (build commit vs checkout over the derived PRODUCT_PATHS) stays: it compares, it
   does not identify; the chain's hand-typed product path list gives way to it.
6. The hook and the cut name the run (`tools/cut-release.sh --run <id>`), resolve its build tag offline from the local
   tags' annotations, read the receipt for that tag, check it over `<previous release before the build commit>..<build
   commit>`, and ask CI about the build commit. A hand-typed cut names no build and is refused. The cut's descendant
   fallback (newest receipt by mtime) is removed.

**Why.** A build is bytes from one commit by one run; HEAD is wherever the harness checkout happens to be. Owner's
words above. The merge rule's two decisions were taken by the implementer and are NOT Jev verdicts: on the rule Jev
leaned to it at 0.72 with confidence 0.63, under the 0.70 floor; on tag creation Jev answered insufficient_evidence
0.31. Both are recorded here so the next reader knows they were decided, not measured.

**Cost.** A measured verdict from harness H1 stands until a run from a DIFFERENT harness commit measures the module
again - so a pass recorded by mistake, or a product-fail that a later run from the same checkout would have cleared,
needs a harness commit (any commit) before the receipt can change. Bounded: one commit. The hook now also trips on
`tools/cut-release.sh --run`, and a dry remainder run refuses when no tag exists for its run instead of printing a
chain about a build it cannot name. A receipt written before this date (schema 1, keyed by a sha) is not merged into:
it is at another path, and a schema-1 file found at a tag's path has its lists replaced, with a note.

**Evidence.** Seen to fail: the 4f342c72 state above - two consecutive full runs needing one frozen sha. Seen to pass:
owed - the first full acceptance of `build-4.3.41.1266` (run 43008254292, FI run 43008346628) through the chain, and
a harness-only commit between two of its runs leaving the receipt intact. Offline, 2026-11-11: the four merge branches
exercised on a scratch receipt (kept measured against unmeasured; replaced unmeasured with measured; kept measured
against the same harness; replaced measured from a different harness), and the hook refusing a hand-typed v-tag,
a run with no tag, and a tag with no receipt, while passing a read of the cut script.

**Open.** Pushing a build tag (publishing) is out of scope. A branch-filtered CI workflow can only be dispatched at a
branch tip, so CI for a build commit that is no longer the tip of its feature branch cannot be produced by the chain;
on main the push ran it. `tools/tests/release-cut-gate-selftest.sh` was deleted with this change rather than rewritten
(owner rule on selftests); the hook itself is the enforcement and nothing else drives it offline.

## What this scheme does NOT protect against

- **A pattern that maps too narrowly.** The closure catches a shared *file*; it cannot catch a change whose effect
  travels through data, a registry value or dom0's behaviour rather than through a reference. The mapping is a
  judgement, and a wrong one is only visible when something ships.
- **A suite that does not assert the thing.** Scoping decides which suites run, not what they check. The defect that
  prompted all of this was invisible to every cell; the log sweep in the core is the answer to that, not the map.
- **The sweep judging the wrong build.** Added 2026-10-16 after it happened. The sweep's window is a time range, but
  what a gate judges is a BUILD - and the short cycle is `quick-upgrade`, where the old build is running when the
  upgrade starts and the new one starts minutes later, both inside one window. Ten error lines from gui-agent
  4.3.35.795 were billed to 4.3.36.981, three committed fixes were reported as not working, and the cut release was
  suspected of shipping stale binaries (it was not; the installed hash matched the package's own reference). The
  sweep now scopes every line metric by the version each module declared, reporting what it set aside
  (`error_lines_prior_build`, `prior_build_mix`) and naming the one case where the filter could manufacture a zero
  (`modules_superseded_silent`). A gate instrument that cannot say which build wrote a line cannot grade a release.
- **The ledger being wrong.** It is written by the tool, but its first three records were reconstructed from release
  notes, and they are marked as such. None of them is a full run under this scheme, so the first gate after this lands
  is a full one.

## Implementation notes (2026-10-07) - what was built; not decisions

`mgmt/gate-scope.json` (the map, with a reason per pattern), `tools/gate-scope.py`, `mgmt/gate-ledger.json` (seeded
from the records of 4.3.33, 4.3.34 and 4.3.35, each marked `reconstructed`), and
`tools/tests/gate-scope-selftest.sh`. The suite names are the ones the harnesses already use:
`tools/release-acceptance.sh`'s eight cells and three feature tests, plus `failproof-gates`,
`failproof-faultinject`, `gate-preflight`, `p3a-etw-gate`, `toast-hold-test` and `log-sweep`.

2026-11-11 (§7): `tools/build-tag.sh` (create / resolve / run / fi-flag), `tools/coverage-receipt.py` schema 2 with
the module map and `merge_module`, and the identity change in `tools/release-acceptance.sh`, `tools/gate-remainder.sh`,
`mgmt/harness/campaign-full.sh`, `tools/hooks/release-cut-gate.sh`, `tools/cut-release.sh` and `tools/acceptance-plan.py`.
