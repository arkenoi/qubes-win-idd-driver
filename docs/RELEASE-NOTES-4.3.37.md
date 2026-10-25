# QWT-NG 4.3.37 — the Start menu is a window you can move

**The change you will actually notice: the Start menu is an ordinary framed window.** You can move
it, it has a title bar you can drag, and it behaves like Settings or any other guest window rather
than something that appears in a fixed place and vanishes if you look at it wrong. Its expanding
cards — the lists that slide out when you click into a section — are drawn as their own windows and
dismiss when they should, neither early nor late.

Underneath that, a thing that had never worked was found and fixed: the broker's per-window crop was
**dead code**. Nothing in the agent ever wrote the field the broker reads to decide where a shell
surface's pixels begin, so the broker had been falling back to a whole-surface crop the entire time.
That is why the menu used to render partly black or show the desktop through itself.

## Guest windows could stay shadowless for a whole session

Leaving seamless mode is supposed to restore the window shadows that dom0 draws for you. If that
restore failed, nothing retried it and nothing said so: the agent discarded the result, latched
"done", and the only line it wrote claimed it *would* retry. The retry that exists is gated on the
seamless direction, so it never ran, and the bounded give-up message could not fire either.

The failure is now reported as an error naming what you would see — windows staying shadowless
outside seamless — and the line no longer promises a retry it cannot perform. Three spawn paths that
could fail silently (token duplication, reading our own image path, and starting the helper) now say
which one failed and why; before, they returned without logging anything while the caller blamed
"no usable interactive session yet" for a session that was demonstrably usable.

## A resolution change on the sign-in screen no longer waits 12 seconds

Applying an exact resolution starts with a pre-flight query asking the driver whether the mode is
available. On the secure desktop — the sign-in screen, a lock, a UAC prompt — that query cannot see
the mode, so it was polled 74 times over a full 12-second deadline and then the mode was applied
anyway. The pre-flight is now skipped while the input desktop is the secure one, and the apply
happens immediately; a mode that genuinely is not offered on an ordinary desktop keeps its warning.

## "The keyed mutex was abandoned" is gone from the logs

`DXGI_ERROR_ACCESS_LOST` is the routine signal that a desktop-duplication handle expired — it fires
on every mode change and every trip to the secure desktop. Windows renders that error code as *"The
keyed mutex was abandoned"*, a message about a synchronisation object that is not involved at all,
so anyone reading the logs was chasing a phantom. All seven calls on the duplication object now
route that one signal through a single reporter, and every other failure still reports with its own
status.

## Upgrading no longer restarts the GUI agent into a pending reboot

When an upgrade needs a reboot, restarting the GUI agent first mapped windows that were about to
disappear. The installer now skips that restart, says so, and records it in the result the caller
reads.

## Smaller, user-visible

* The menu key and the menu's presentation are one decision, so the key and the mouse agree about
  what the menu is.
* A window that holds its last content while waiting for a frame is no longer logged as a warning on
  every frame; a window that holds it *past a bound* is now reported as an error naming the stale
  pixels, which is the case that can actually be seen.

## What was verified, and what was not

**This release was published on a FAILED acceptance record, deliberately, and the gate was not met.**
That is stated first because everything below is read in its light. It was cut with
`--acceptance-override` on the maintainer's explicit instruction, as an interim publication to be
superseded by the campaign that was running at the time.

What ran, against this exact ISO (`32b950df…a0a9f`), on the build the capture itself declares —
`4.3.37+agent.93a1b271d1bb`, modules `gui-agent@4.3.37.1096`, `gui-watchdog@4.3.37.1096`,
`qrexec-agent@4.3.37.1096`, `qrexec-wrapper@4.3.37.1096`:

* **Eight matrix cells** — clean install, same-version reinstall, in-place upgrade and
  template→AppVM derivation, on **both Windows 10 and Windows 11**. Seven swept CLEAN. One,
  `win10-reinstall`, came back FINDINGS.
* **Five feature cell-groups, all passed**: crop-before-map, notify-errors-guest-test,
  supervision-gate, template-update, updater-component.

**The one failure, named exactly.** `win10-reinstall` reported a single breach with **zero P1**:
`signatures_unclassified = 1 (max 0)`. The line is a WARNING of our own,
`agent|W|PwLedgerAccount: QGALEDGERGAP hwnd=0x1021c class=1 copies=4 attributed=3 unattributed=1,
a pixel copy site is not instrumented`. It is the agent's own copy-accounting ledger reporting that
it could not attribute one of four pixel copies to a known site — a gap in *our* instrumentation,
not a statement that a window rendered wrongly, and the gate counts it because an error or warning
matching no declared class is a debt we owe. Nothing user-facing went with it: the same cell
measured `dom0_loud_failures=0`, `bugchecks=0`, `wer_crashes=0`, `agent_unrequested_deaths=0`,
`notifications_lost=0`, `error_lines_undeclared=0`, `fallbacks_fired=0`, `broker_hangs=0`.

**What was NOT met, said plainly.** The change-scoped gate
([`docs/ADR-acceptance.md`](docs/ADR-acceptance.md)) requires the **full 19 suites** for the range
this release spans, for two independent reasons: four paths in the diff are unmapped, and no past
record covers the full scope — the best on file is 4.3.35 with 13 of 19. So this release is **not**
cut on a met gate, and it is not cut on 4.3.36's campaign either. The missing suites are
`failproof-faultinject`, `failproof-gates`, `gate-preflight`, `log-sweep`, `p3a-etw-gate` and
`updater-component` relative to that best record.

**Therefore**: treat this build as what its own record says it is. The user-visible changes above are
in it, and seven of eight matrix cells and all five feature groups were clean on these exact bytes;
the ledger-accounting gap is open, and the full gate has not been demonstrated on this package.

## Known issues

* A per-window hold that outlasts its bound is now reported, but the underlying starvation — a
  window the broker stops feeding — is detected by that bound rather than prevented. See
  `docs/ADR-capture.md`.
* Desktop duplication is still created at startup and held for the life of the agent even on guests
  where no window takes pixels from it. `docs/ADR-capture.md` §33 records removing it as the target
  state, with the three things that must be settled first.
