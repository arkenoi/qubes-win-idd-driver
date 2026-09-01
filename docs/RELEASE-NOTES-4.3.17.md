# QWT-NG 4.3.17

A bugfix release. MSI ProductVersion **4.3.17** — a real bump over 4.3.16, so an in-place
MajorUpgrade lands on an existing guest without an uninstall.

## What changed since 4.3.16

**Dragging a window by its Windows title bar no longer wobbles.** 4.3.16 shipped a regression, and
this is the retraction of a claim made in that release's own notes: *"It also releases a drag latch
that could otherwise stick if a button release was lost."* That latch release is the defect.

The drag latch (`g_InputDragWindow`) is what selects the fixed input-translation law for a
guest-native drag — dom0 sends window-relative pointer motion and withholds the root coordinate, so
the agent must add an origin, and translating against the *live* window origin closes a gain-1
feedback loop through the announce path. Four separate shipped fixes gate on that latch: the
interpolated origin, `InputDragFreezeContent`, `DragEventPriority`, and the announce pacing.

4.3.16's `HandleCrossing` released the latch on a `LeaveNotify`. Measured on a hand drag
(2026-09-01, agent `EB25802E85D471A8`, shipped tuning asserted from the log banner):

| | motion events | translation law used | window-path direction reversals |
|---|---|---|---|
| first 569 ms | 50 | 50/50 interpolated origin | 4/50 = 8 % |
| after the crossing | 490 | **489/490 live origin** | 99/490 = **20 %** |

569 ms into a 5.0 s drag, dom0 delivered `LeaveNotify mode=0 (NotifyNormal) detail=3
(NotifyNonlinear)` and the latch went with it. Announced positions then swung 867 ↔ 2475 px at
~15 Hz. 16–19 % reversals is the wobble exactly as it was first characterised, so that single event
restores it in full and it never re-arms, because only a new button press arms the latch.

The premise was wrong: in a guest-native drag the *window* moves, not the pointer, and the button
stayed down for another 4.4 s with 490 further motion events for that same window arriving after
the "leave". The hole it claimed to close — a lost `Button1` release freezing a window — had
already been closed 17 days earlier by `INPUT_DRAG_STUCK_MS` and the settle-sweep disarm.

**Fix: the latch release is deleted, not guarded.** `HandleCrossing` now receives the message,
records it under the drag trace, and touches no state. The one real defect that handler was written
for — a `LogWarning` per crossing event on the input path, ~10 lines/s — stays fixed.

**App-menu shortcuts launch.** From core-agent `b2ccd83`: `get-appmenus.ps1` emits the two fixed
desktop-entry ids dom0's launchers are actually wired to, so *Windows Run Terminal* and *File
Explorer* start something instead of nothing; and `start-app.ps1` opens the **interactive user's**
folder rather than the service account's, and returns in 4–5 s instead of blocking. Verified on a
live guest: both entries emit, both launch, Explorer opens the right folder.

**Fault injection cannot be in a release build.** `QgaFaultInjection` was flipped to default 1 on a
diagnostics branch whose own comment reads *"NEVER merge this to a release branch"*, and those
commits reached the branch this release is cut from. The default is back to 0 and a fault-capable
agent must now be asked for explicitly (`-p:QgaFaultInjection=1`). **No published release ever
carried it** — the flip is newer than 4.3.16 — but every developer build on that branch did.

**New, opt-in, and off by default: a drag trace.** `ProtoTraceDrag=1` (DWORD under the `gui-agent`
key) emits only the input-rate protocol messages — motion, buttons, the drag latch, outgoing
position announces, inbound configures — at roughly 44 lines/s. Unlike full `ProtoTrace` it does not
carry the per-damage-rect lines that multiply the frame-walk tail, so latency and mechanism can be
judged from the same run. `msg=MOTION` now reports `br=`, which of the translation laws each event
actually took, and `msg=DRAGLATCH` names every arm and teardown. `tools/drag-analyze.py` reads the
result. Nothing is emitted unless the value is set.

## What was actually tested — and what was not

**Measured, on the artifact's own code path:**

- The defect above, on a hand drag, with the failing side recorded in full (the table). The build
  that produced it *is* the defect build, on the same guest, window and tuning as the fix, so the
  check has been seen to fail.
- The instrument was calibrated against injected ground truth before being trusted: a synthetic
  drag with a chosen dom0 apply lag of 17 / 80 / 200 ms was fitted back at 10 / 90 / 190 ms, and
  the wobble metric moved 5 % → 41 % with it.
- The drag tuning is unchanged from the 2026-08-16 user-approved baseline and is compiled in, not
  configured: `git diff 168a869..HEAD -- gui-agent/perf.c` changes no drag default, and the guest's
  registry carries no `InputDrag*` override.
- App-menu entries: emitted, launched, and returning on a live guest.

**Confirmed by hand after this release was cut** (owner, 2026-09-01: *"it drags fine now"*), on
agent `C3D2A0193F9D493A`, which differs from the released `45e788d` by the version file alone. The
trace from those drags, same guest, same window, same tuning as the defect table above:

| | defect build | fixed build |
|---|---|---|
| `NotifyNormal` crossings during the drag | 1 | **21** |
| what each did to the latch | destroyed it | **kept it, every one** |
| motion events on the fixed translation law | 50/540 = 9 % | **587/587 = 100 %** |
| window-path reversals, per drag | 20 % after the crossing | 11 % / 0 % / 8 % |

Note the crossing *rate*: 14 arrived inside the first 3.5 s drag alone. On the defect build the
first one lands within about half a second of any drag, which is why this was not intermittent.

**NOT verified, stated plainly:**
- Clicking the two app-menu entries **in dom0** after `qvm-sync-appmenus` is unverified; only the
  guest half was exercised.
- No acceptance campaign was run against this artifact. It is a targeted bugfix on top of the
  4.3.16 campaign (`20260830-062519`, 36 checks, 0 failures), not a re-qualified release.

## Known-unchanged residual

The drag law assumes dom0 applies an announce within about 25 ms. Measured on the rig it does
(median 0, p75 17), but the tail reaches 82 and 398 ms, and the synthetic calibration quantifies
what happens past the assumption: 22 % reversals at 80 ms, 35 % at 200 ms, against 1 % at 17 ms. So
a dom0 that answers slowly will still wobble, with nothing regressed in the guest. That is a design
residual of `InputDragAdoptMs` / `InputDragLagMs`, unchanged since 2026-08-16, and it now has
numbers attached for the first time.
