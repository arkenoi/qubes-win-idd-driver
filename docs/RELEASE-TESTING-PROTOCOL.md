# Release testing protocol

Binding for anything a user can download or run. Written 2026-08-16 after the fourth consecutive
release broke a reporter's working configuration. This is not general QA advice: every rule below
exists because a specific failure got past us, and each rule names it.

## The incidents this protocol is built from

| # | What we shipped | What the user got | What we had actually tested |
|---|---|---|---|
| 1 | `/idd` | `Start-Process -FilePath 'D:\idd'` — "file not found" | the flag existed in the tree; the launch form was never run |
| 2 | `/iddonly`, announced on the forum | his medium rejected it — committed ~3.7 h AFTER the 4.3.1 assets were built | the tree, not the asset |
| 3 | `/noidd`, announced as available | `package_version 4.3.1+agent.c7ccb459aec9` — 4.3.2 was never published | the tree, not a release |
| 4 | mode selection | pointer ~1 cm low on his 1920x1200 screen | our rig, which is not 1920x1200 |
| 5 | `/iddoff`, recorded "SHIPPED + VERIFIED" | `-FilePath 'C:\iddoff'`, install aborts | Win10 22H2, **elevated**, **our** medium, English |
| 6 | Windows-key handling | Start AND Open-Shell both dead — the workaround we had recommended to him | that the stock Start menu stopped appearing |

Five distinct classes, and none of them is "the code was wrong in a way a unit test would catch":

- **A. Matrix collapse.** One cell passes; we report the feature green. (#5)
- **B. Tree/artifact divergence.** We test what we built, then publish something else — or nothing. (#2, #3)
- **C. Rig monoculture.** Our single guest's geometry/locale/OS build hides whole defect classes. (#4)
- **D. Blast radius unexamined.** A feature that DISABLES something is tested for the thing it was
  meant to disable, never for what else it took down. (#6)
- **E. No provenance.** Neither we nor the user can tell which build produced a transcript, so
  every report starts with an argument about what he was running. (#5)

## Gate 0 — Provenance (blocks everything else)

Nothing is diagnosable without knowing what ran.

1. Every user-facing entry point prints, as its first line, `QWT-NG <version> (<commit>) <medium path>`
   — `install.cmd`, `activate-idd.ps1`, `deactivate-idd.ps1`, and any script we ask a user to run.
2. The same string goes into the `=== RESULT ===` JSON and into the guest log.
3. A bug report without a version line is answered by asking for one, before any theorising.

Cost of not having this: incident #5 cannot be attributed even now — we cannot prove whether he ran
a stale `install.cmd` or the shipped one, because the shipped one does not say who it is.

## Gate 1 — The artifact under test is the published asset

1. Tests run against the **downloaded release asset**, verified against `SHA256SUMS.txt`. Never a
   local build, never the working tree, never a CI artifact that is not the one being published.
2. The test harness records the SHA of every file it installed, and the run is void if any recorded
   SHA differs from the asset manifest.
3. A release is published **before** it is described to anyone. The forum post quotes the tag and
   the SHA256 of the file the user will download.

Kills class B outright. Incidents #2 and #3 were both "the tree had it, the asset did not".

## Gate 2 — The invocation matrix

A switch is not "verified" until every reachable cell is executed and its result parsed. For each
user-facing switch (`/auto /idd /noidd /iddonly /iddoff /updatesonly /noupdates /nonet /nodisk
/acceptpvdiskupgrade /noapptweaks`):

| axis | values that MUST be run |
|---|---|
| medium | ISO (`D:\`), copied directory (`C:\QWT-NG\`), directory path containing a space |
| elevation | already-elevated console, **non-elevated** (exercises the UAC relaunch) |
| guest state | fresh guest, guest with the previous QWT, guest with a **stale copy of the previous installer present** |

Rules:

1. The matrix is generated and executed by a script; cells are not chosen by judgement.
2. Any cell that cannot be run states *why*, in the release notes, as an explicit gap. "Not run" is
   never rendered as "verified".
3. Status vocabulary is per-cell. `docs/GWECK-STATUS.md` may say "VERIFIED" only with the cell list
   attached: *"verified: copied-dir + elevated + Win10 22H2"*, never a bare "VERIFIED".
4. The **non-elevated** row is mandatory, not optional. Incident #5 lived entirely in that row, and
   it is the row a normal user is in by default.

## Gate 3 — Defect pairs, and checks that have failed

Restates the CLAUDE.md autonomy rules as release gates:

1. A fix ships only with a recorded defect-present / defect-absent pair on ONE binary, config-toggled
   (the `*FaultInject` convention under `HKLM\SOFTWARE\QubesIDD`).
2. A check counts as evidence only once it has been **seen to fail** with the defect deliberately
   re-introduced. Otherwise its PASS is recorded as *unproven* and says so in the release notes.
3. Missing data fails the gate. A harness that reports clean zeros because a precondition was absent
   is a failed run, not a pass — assert every precondition per iteration and abort loudly.
4. Absence of a regression is not evidence of the intended effect.

## Gate 4 — Blast radius: what did this feature BREAK?

For any change that disables, hides, filters, suppresses or blocks anything, the acceptance list must
name what MUST STILL WORK, and each item is tested. Minimum standing list:

- **Everything we have ever recommended as a workaround is a permanent test case.** Open-Shell menu
  opens via the Windows key. `/noidd` boots on the emulated adapter. The `Enable-PnpDevice` recovery
  command works with no display.
- Windows notifications still appear (the CLAUDE.md 2A-chrome toast case: same predicate, opposite
  desired outcome — Office shadows DROPPED, toasts KEPT).
- Both Start paths: stock Start, and Open-Shell.
- Keyboard: Windows key, Ctrl-Alt-Del/SAS path, Alt-Tab.

Incident #6 is exactly this gate missing: we verified the stock Start menu stopped appearing, which
was the intent, and never checked the alternative *we ourselves had told him to install*.

## Gate 5 — Environment diversity (kills the monoculture)

The rig must not be the only environment. Per release, the matrix runs on at least:

- **OS builds**: Windows 10 22H2 **and** Windows 11 25H2. (The reporter is on 25H2; several of our
  defects are 25H2-shaped, and the Start surface is not even the same object between UBRs.)
- **Geometry**: at least one non-1920x1080 monitor size, including a non-16:9 one. Incident #4 was
  invisible on our rig purely because of its resolution. `1920x1200` is now a permanent case.
- **Locale**: at least one installer run on a non-English Windows. His transcripts are German; error
  text we pattern-match on is locale-dependent, and any parsing we do on English strings is a latent
  failure we have not yet been bitten by only because nobody tried.

Where a dimension cannot be covered, it is declared in the release notes as untested, by name.

## Gate 6 — Upgrade and staleness

1. Install N-1, then N **over it, in the same directory**, and verify no stale file wins: compare
   every installed file's SHA against the new manifest.
2. The installer refuses to run, with a clear message, if it finds files from a different version
   beside it — or overwrites them and says so. Silent coexistence is what makes incident #5
   unattributable.
3. Cold boot is part of acceptance: a restart in a live session *clears* faults a user meets on a
   fresh boot. Every acceptance run ends with a reboot and a re-check.

## Release checklist

Copy into the release PR/issue; a release does not go out with an unticked line or an unexplained gap.

```
[ ] Gate 0  every entry point prints version+commit; sample transcript attached
[ ] Gate 1  assets published and checksummed; tests ran against the DOWNLOADED asset
[ ] Gate 1  installed-file SHAs match the manifest, recorded in the run log
[ ] Gate 2  switch x medium x elevation x guest-state matrix executed; results table attached
[ ] Gate 2  non-elevated row green (or gap declared by name)
[ ] Gate 3  every fix has a defect-present/absent pair; each check seen to FAIL once
[ ] Gate 4  blast-radius list written for every disabling change; standing list re-run
[ ] Gate 4  Open-Shell + Windows key + notifications verified
[ ] Gate 5  Win10 22H2 and Win11 25H2 both run; non-1920x1080 geometry; non-English locale
[ ] Gate 6  N-1 -> N upgrade in place, no stale files; cold boot after
[ ] Notes   every gap stated explicitly; nothing described that is not in a published asset
```

## When a gate cannot be met

State it, by name, in the release notes and to the user — do not quietly downgrade the claim.
"`/iddoff` is verified elevated only; the non-elevated path is untested" is a usable sentence and
costs nothing. "SHIPPED + VERIFIED" for a matrix with one cell run is what produced incident #5, and
it is the sentence that made the reporter waste an evening.
