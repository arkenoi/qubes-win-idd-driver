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

## The decisions at a glance

| § | decision | status | date |
|---|---|---|---|
| 1 | A release's gate is scoped to what its diff touches, over an always-run core | ACCEPTED (owner) | 2026-10-07 |
| 2 | An unmapped path requires the full gate | ACCEPTED (owner; Jev 0.97) | 2026-10-07 |
| 3 | A floor forces the full gate on whichever of four conditions comes first | ACCEPTED (owner; Jev 0.96) | 2026-10-07 |
| 4 | The scheme is computed and refusing, not written down | ACCEPTED (owner; Jev 1.00) | 2026-10-07 |
| 5 | A changed file expands through its reverse-dependency closure before it is mapped | ACCEPTED (Jev 0.62 named the hazard) | 2026-10-07 |

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

## What this scheme does NOT protect against

- **A pattern that maps too narrowly.** The closure catches a shared *file*; it cannot catch a change whose effect
  travels through data, a registry value or dom0's behaviour rather than through a reference. The mapping is a
  judgement, and a wrong one is only visible when something ships.
- **A suite that does not assert the thing.** Scoping decides which suites run, not what they check. The defect that
  prompted all of this was invisible to every cell; the log sweep in the core is the answer to that, not the map.
- **The ledger being wrong.** It is written by the tool, but its first three records were reconstructed from release
  notes, and they are marked as such. None of them is a full run under this scheme, so the first gate after this lands
  is a full one.

## Implementation notes (2026-10-07) - what was built; not decisions

`mgmt/gate-scope.json` (the map, with a reason per pattern), `tools/gate-scope.py`, `mgmt/gate-ledger.json` (seeded
from the records of 4.3.33, 4.3.34 and 4.3.35, each marked `reconstructed`), and
`tools/tests/gate-scope-selftest.sh`. The suite names are the ones the harnesses already use:
`tools/release-acceptance.sh`'s eight cells and three feature tests, plus `failproof-gates`,
`failproof-faultinject`, `gate-preflight`, `p3a-etw-gate`, `toast-hold-test` and `log-sweep`.
