# Architecture decision records

An ADR records a DECISION: what we do, why, what it costs, and what evidence shows that it works. It is not a
status report. What a guest measured on a given day belongs in `findings/*.md`; how a mechanism works belongs
in `docs/DESIGN-*.md` and in the code headers. An ADR section goes stale only when the decision changes.

## The records

| file | scope | sections |
|---|---|---|
| `ADR-windows.md` | which guest surfaces become dom0 windows: the screens never shown, the fullscreen window that needs dom0's consent, the secure desktop, the non-seamless desktop window, chrome fragments, popups, autologon | 10 |
| `ADR-capture.md` | where a guest window's pixels come from: the PrintWindow engine, the WGC broker, liveness at rest | 32 |
| `ADR-gui.md` | window geometry between the guest and dom0's gui-daemon: placement after a restart, resizes | 2 |
| `ADR-toasts.md` | how a guest's Windows notifications reach dom0 (the toast bridge), how each toast is routed, and how a toast's buttons round-trip as dom0 actions | 11 |
| `ADR-display.md` | the IddCx driver (Track B): ships on, sole active output, the mode list, the identity, the grant-path gate | 6 |
| `ADR-network.md` | PV networking: the unplug latch, re-arming, the L3 service, DHCP off, the acceptance, our xenvif | 8 |
| `ADR-boot.md` | what may touch the device model (QEMU, Xen) in a fresh domain's first minutes: install stages and first boots | 2 |
| `ADR-supervision.md` | how our processes and services are kept alive, and how their deaths are made loud | 4 |
| `ADR-updater.md` | the dom0-owned Windows update path (Track C): invariants, verification, install routes, process ownership, the installer's deploy | 13 |
| `ADR-uac.md` | elevation prompts a user in dom0 can answer: the prompt moved off the secure desktop, the stand-in window, a prompt Windows did not raise, what may elevate at all | 10 |

### Cross-cutting rules, and where they are decided

- **Capabilities are decided at START and never re-read.** A component that was working and stops is a
  FAILURE of an eligible system, reported loudly, never a capability change: `ADR-capture` §1, `ADR-toasts`
  §7, `ADR-windows` §2 and §8, `ADR-supervision` §1.
- **No silent fallback, no silent recovery.** `ADR-windows` §8 (no composite fallback on a direct-capable
  guest), `ADR-supervision` §1 (every death is an ERROR and a dom0 notification), `ADR-capture` §32 (a deaf
  window is declared to the user), `ADR-toasts` §8 (a disabled classifier says so).
- **Never a timeout as a fix; every wait is an observed condition.** `ADR-boot` §1 and §2, `ADR-updater` §4
  and §12.3, `ADR-capture` §14.
- **Verify by effect, by pixels, with the defect seen first.** `ADR-updater` §3 and §9; every section's
  "Evidence" part.
- **Nothing of ours is killed or adopted by name.** `ADR-updater` §12.4, `ADR-supervision` §4.
- **Defects in components that are not ours go upstream only with the owner's approval of the exact text.**
  `ADR-network` §8, `ADR-gui` §1, `ADR-boot` §1, `ADR-display` §6, `ADR-uac` §10.
- **A window nobody can reach is not a window.** `ADR-uac` §6 and §7 (a contentless stand-in is hidden, the
  prompt itself is announced), `ADR-capture` §32, `ADR-windows` §10.

## How a section is written

Every section has the same parts, in this order. A part that has nothing to say is left out, except
**Status** and **Decision**, which are always present.

```
## N. Title - a sentence that states the decision

**Status:** ACCEPTED (owner, Jev), 2026-10-04.

**Context.** The problem, the measurement that showed it, the mechanism where it is known.
**Decision.** What we do, written as rules. Numbered when the order matters. Code references
(commit, function, log tag) come after the rules, not inside them.
**Why.** The reasoning from context to decision, with the Jev verdicts. Left out when the context
already says it.
**Cost.** Every tradeoff, with a bound. A cost that cannot be written down with a bound is not
understood yet.
**Evidence.** "Seen to fail": the defect observed with the fix absent. "Seen to pass": the defect
gone with the fix present. Or "owed", naming the measurement that would settle it.
**Open.** What the decision does not cover or does not fix.
```

Each file has two parts. **In plain English** comes first: a few paragraphs anyone can read, with no code
identifiers and no verdict numbers, followed by the flowcharts and a table of the sections with their status.
**The decisions in detail** follows: the records each decision rests on, then the sections in the format
above, where the code references, measurements and Jev verdicts live. A flowchart (Mermaid, rendered by
GitHub) is drawn where a decision describes an order of steps or a routing choice; it shows the decision, not
the code.

### Status vocabulary

| status | meaning |
|---|---|
| ACCEPTED | decided and in force: built, or being built against this text |
| PROPOSED | written down to be judged; not built before its verdict |
| OPEN | a tradeoff that is the owner's to decide |
| REJECTED | not done; kept so that it is not tried again |
| SUPERSEDED by §N | was accepted; a later section replaced the rule or removed the code |
| WITHDRAWN | a part of an accepted decision that the owner took back |
| RETIRED | was accepted; removed on the builds a later section names, still in force elsewhere |

The parenthesis after the status names who decided: the owner, Jev (`tools/jev.py`), or both. A number such
as "Jev 0.84" is the probability Jev assigned to the stated option when asked; where alternatives were
offered, they are listed with their own numbers. Low confidence is recorded as a finding, not hidden.

## Rules for editing

- **Section numbers are stable.** Other documents cite them as `ADR-capture §20` or `ADR-updater.md 12.4`.
  Never renumber and never delete: a decision that no longer holds becomes REJECTED, SUPERSEDED or RETIRED,
  with the section that replaced it named.
- **Add or change a section only when a decision changes.** A sentence that would go stale once a guest is
  fixed is an observation and belongs in `findings/`.
- **Every section is classified by Jev** and the verdict is recorded in it. A PROPOSED section is not built
  before its verdict.
- **Retractions are loud.** A claim that turned out wrong stays in the text, marked RETRACTED or CORRECTED
  with the date, so that it is not re-derived.
- **Retired lines stay retired.** `docs/` is guarded by `tools/hooks/retired-names-gate.sh`: an edit that names
  a line in `tools/hooks/retired-names.txt` is refused unless it records the retirement.
- **Nothing from a guest capture goes here.** The repo is public; per-run evidence stays in `scratchpad/`.
