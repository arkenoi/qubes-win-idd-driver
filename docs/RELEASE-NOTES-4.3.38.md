# QWT-NG 4.3.38 — "updates available" means something again, and a shutdown crash is gone

## Defender definitions no longer raise dom0's update flag

On a freshly updated Windows qube, dom0's `updates-available` could go back to *available* within a
minute of clearing, indefinitely. That was not a defect in the flag: Microsoft republishes Defender
Security Intelligence definitions several times a day, the guest scanned with no category filter, and
so it reported a definition offer to dom0 exactly like a cumulative update.

Definitions are now excluded from the count dom0 reads, so the flag means *servicing work is
pending* — something an operator can act on. Three properties of that change, because each is a way
it could have been done wrong:

* **Definitions are identified structurally, never by title.** WU classifies every offer, and
  "Definition Updates" is a fixed classification GUID carried in `Categories`. A title match would
  have been locale-dependent — the field reporter runs a German edition, where the same offer reads
  *"Definitionsupdate für Microsoft Defender Antivirus"* — and would have broken the day a product
  name changed.
* **The Defender platform update still counts.** The antimalware engine/platform updates are
  classified as ordinary servicing, not definitions, and they remain real work you should see.
  Neither a KB number nor a title separates those two; the classification does.
* **An offer we cannot classify still counts.** If the categories are unreadable, the update is
  reported. An exclusion that swallowed what it failed to classify would hide real servicing.

Definitions are still *installed* — only the count dom0 reads is narrowed, and excluded offers are
counted and named in the guest log rather than silently vanishing. A changed signature classification
now also reddens a run instead of passing quietly.

## A crash in our own pipe server at service stop

`QpsDestroy` deleted the critical section, zeroed and freed the server object while a never-joined
per-client thread was still travelling from a broken-pipe read into `QpsDisconnectClient`, whose
first act takes that same lock. An 18 ms window — measured in the source, not inferred — producing an
`0xc0000005` in `qubesdb-daemon` as it stopped.

The server object is now deliberately retained with its lock valid, and every entry point that takes
a client id goes through one accessor that answers "no such client" for a call arriving after the
destroy. The unhandled-exception filter was also emitting its `Parameter N:` detail on lines that
never reached the log, so the one line it does write now carries the faulting address — which is the
only reason this was diagnosable.

**Measured on these bytes:** the `win10-reinstall` cell, where this crash was originally caught,
swept CLEAN — `crash_lines=0`, `wer_crashes=0`, `error_lines_undeclared=0`.

## The de-slice supervisor stopped measuring from a stale clock

When a window stops needing the sliced capture path, a supervisor gives the broker a grace period to
come up and then stands the slicing down. That grace was counted from a tick taken **before** the
launch — in two places, and in the second the earlier "fix" had been placed above `WgcLaunch()`, so
it was inert as well. A slow broker launch could therefore eat its own grace. Both anchors are now
read after the launch returns, and a teardown no longer leaves the supervisor armed with no window to
supervise.

`E_ACCESSDENIED` from capture initialisation was treated as fatal. It is also what an ordinary
desktop switch gives you — a UAC prompt, a lock, the sign-in screen — at the moment capture starts.
It now joins the switch-transient set the other such errors were already in.

## Smaller

* The pixel-copy ledger counted copy *attempts* against source counters that count *successes*, so
  every refused copy read as an uninstrumented site. 4.3.37's single acceptance breach was this.
* `dom0-sends-capture.ps1` read a gitignored helper, so it worked on exactly one machine.

## Nothing else changed

No driver change, and no change to what the agent is permitted to do. The security model is
identical to 4.3.37.

## What was verified, and what was not

The **full eight-cell matrix** ran against this exact package — clean install, same-version
reinstall, in-place upgrade and template→AppVM derivation, on both Windows 10 and Windows 11:
**89 checks passed, 1 failed.** The captures declare `4.3.38+agent.3cb91be41179`, so these
measurements are of these bytes.

Of the five feature tests, only `updater-component` ran (**pass**). The campaign was then stopped
deliberately, so **`notify-errors-guest-test`, `crop-before-map`, `template-update` and
`supervision-gate` are uncovered for this build** — not passed, not failed. The change-scoped gate
for this range has not been demonstrated. This release was published with an explicit
`--acceptance-override`; the reason and the checker's refusal lead the release body.

**The one failure:** `win11-upgrade`'s guest log sweep, one breach, **zero P1** —
`signatures_unclassified = 1` on the stock `qubesdb` line `QpsWrite: [N] client is disconnected`.
That is the daemon cancelling a write to a client that had already closed the pipe: the write-side
twin of five sibling teardown lines our sweep dictionary already settles as normal, whose own wording
is not in it. The cell measured zero dom0-visible failures, zero crashes, zero bugchecks, zero
unrequested agent deaths and zero lost notifications. The connection churn behind those teardowns is
ours and remains open as `QUBESDBCONNECTPERREAD` (P2): we open a fresh qubesdb connection per read
instead of one per process.

## Known issues shipped knowingly

- **A toast pre-emption can leave a banner un-mapped** (`TOASTPREEMPTLOSESBANNER`, P1): while a
  newer notification is queued, a displayed window-path banner is taken off screen before the swap
  can paint, and for a `forwarded` resolution it is not put back. Rule 5 of the toast-hold design is
  to be replaced by swap-edge gating; the replacement is specified, not built.
- **The ETW/p3a gate reports four product failures** (T5, T7a, T7b, T8c) and two cells it could not
  grade (T6hb, T7w). Those cells had never reached their precondition before, so these are newly
  *visible* rather than new.
- **The toast-hold suite fails S3i-1, S3ii-1 and S4.**
