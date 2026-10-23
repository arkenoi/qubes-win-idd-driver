# ADR — the guest log sweep is a classifier with three classes and a default of ALERT

Status: ACCEPTED (owner, restated 2026-10-23 after the design was not implemented)

## The decision

Every line in a guest capture belongs to exactly one of **three declared classes**, and anything
that falls in none of them is an **ALERT**:

| class | declaration means | the finding is |
|---|---|---|
| **SHOULD BE PRESENT** | this line must appear (here, on this cell/boot) | its **absence** |
| **SHOULD NOT BE PRESENT** | this line must never appear | its **presence** |
| **NORMAL OPERATION** | this line may appear and is not a finding | nothing |
| *(no match)* | — | **ALERT — acted on, never absorbed** |

Owner, 2026-10-23, verbatim:

> THERE ARE 3 CLASSES OF LEGIT MESSAGES AND WE DEALT WITH IT FROM THE VERY BEGINNING: SHOULD BE
> PRESENT, SHOULD NOT BE PRESENT AND NORMAL OPERATION, AND EVERYTHING ELSE IS ALERT

> REGEXES ARE FINE, BUT IF NONE MATCHES IT SHOULD BE ACTED ON, AND YOU SPENT WEEKS ON THIS MATCHING

**Regexes are not the problem.** They are how a class is declared. The problem is the DEFAULT. A
classifier whose default is "report it and carry on" is not a classifier; it is a pattern hunt whose
coverage nobody can state. The default is what makes the three classes load-bearing: you cannot grow
the dictionary to make a cell pass, because everything not yet declared already fails.

## Severity

An ALERT that is **loud to the client** — a dom0 toast, a notification, a dialog — and that should
not occur in normal operation is **P1**. Owner, stated several times and confirmed:

> ANYTHING LOUD TO THE CLIENT THAT SHOULD NOT BE IN NORMAL OPERATION IS P1

Whether the log sentence behind such an alert is arithmetically true is irrelevant. On 2026-10-23 a
de-slice broker-down toast reached the client 1.4 s before that broker validated ready; the 30 s it
reported was correct arithmetic and the toast was still wrong. It was filed P2 with a justification
for why that was acceptable. That was the error this section exists to prevent.

## What this replaced, and why it had to be written down

The sweep carried 89 curated regexes and a 336-entry hand-maintained dictionary
(`mgmt/harness/log-sweep-baseline.json`: 202 `expected`, 80 `benign`, 39 `unsettled`,
15 `known-defect`). An unmatched line went into `new` or `unsettled`, was printed, was given a Jev
opinion, and **failed nothing** — there was no gated metric for it. MEASURED, acceptance run
39868919766 cell win10-upgrade:

    NEW SIGNATURES (240; Jev: expected 40, insufficient-evidence 142, noise 87)

240 unmatched lines, 142 of which the classifier of record could not settle, and the cell was graded
**CLEAN**. The response for weeks was to add entries to the dictionary. This ADR exists because the
architecture above had been given and was not recorded in any ADR, findings head or memory, so it
was repeatedly re-derived as "add another pattern".

## As implemented

- `signatures_unclassified` (max 0, **P1**) — `new` + `unsettled`. This is the default. `unsettled`
  is included deliberately: its own baseline note reads "a human decision is owed", and a decision
  that is owed is not one of the three classes. Verified on a real capture: a report that graded
  `BREACHES (0; P1 0)` with 258 unmatched lines now grades `BREACHES (1; P1 1)`.
- `fallbacks_fired` is **P1**, not P2 — a fallback firing is client-visible by this project's own
  rule that it be logged loudly and diagnosed.

## Not yet implemented — the SHOULD-BE-PRESENT gate

There is no absence gate, and the baseline's `expected` status cannot serve as one: it means
"allowed if seen", 202 signatures carry it, and no single cell produces all of them, so gating their
absence at max 0 would fail every cell for lines that were never required. That class needs a
`required` declaration stating WHERE each line must appear (which cell kinds, which boot kinds).
Tracked as `REQUIREDLINESHAVENOABSENCEGATE`. Until it exists, class 1 is declared but not enforced,
and this ADR says so rather than letting the gap read as coverage.
