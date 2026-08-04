# SESSION HANDOFF — 2026-08-04

Continues SESSION-HANDOFF-2026-08-03.md. Read that file's §4 "Traps" as well — they still
apply, and §4.4 (acting on a stale in-memory model) bit again today in a new form.

Everything below was read off the machine or the repo, not recalled. Full detail in
`FINDINGS.md` under the two 2026-08-04 headings.

---

## 1. Headline

**T1 is now largely closed and T2 is a Track B deliverable** — and the day's real lesson is
about controls and premises, not about any individual fix.

| commit | status after today |
|---|---|
| `98eed30` | validated 2026-08-03 (unchanged) |
| `aaa8c37` | **VALIDATED** — 4/4 strips announced by the pre-fix build, 0/4 by the fix, 3 interleaved rounds, cold boot per side |
| `66fc670` | **VALIDATED** — control adopted the popup 3/3, fix refused it 3/3, on two opposed signals |
| `6b5b298` | **REVERTED** (agent `8629a9c`) — measured no effect: guard-reverted 136->83 damage/12s channel alive, guard-present 176->118 alive. Justification already retracted; logged nothing so was unfalsifiable |
| `b4301b1` | **wild-pointer loop in the post-recovery repaint sweep — VALIDATED**: control CRASHES the agent 3/3, fix survives 3/3 |
| `d3a5fbc` | mask-sort, written days ago and never merged; cherry-picked today, not separately validated |
| `a4f6961` | framebuffer-pointer invalidation on duplication release; not separately validated |

**FIVE separate instruments were discarded today as incapable of failing.** That is the
single most useful thing to carry forward: before running any A/B, ask *what makes the
control able to FAIL*, and confirm the feature under test even exists on the control side.

---

## 2. The five dead controls (each failed differently)

1. **Counting PNGs from `qtest shot`.** `local.WinScreenshot` uses `import -window <id>`,
   which silently fails on `WS_EX_LAYERED` windows. With the control announcing all four
   shadow strips, the tar still held exactly ONE png, byte-identical to the fixed build's.
   It is structurally blind to the very windows the bug creates.
2. **Office's own strips as the scene.** They are transient — four at 13:37, one at 13:41,
   none at 13:42. The metric tracked scene state, not the build.
3. **Stock QWT as the control, twice, for two different reasons.**
   - For thin strips: stock rejects an 8 px strip on the `SM_CXMIN` floor, so both sides
     read zero. The override-redirect exemption that lets Office's strips through is
     **fork-local** (`d6ab61c`).
   - For synthesis: composite synthesis does not exist upstream at all (`0a334c1`), so stock
     emits no `msg=SYNTH` under any circumstances.
4. **`PerWindowCapture=0`.** `AddWindow()` gates synthesis on `PwEnabled()`, so with capture
   off nothing is ever synthesized and both sides report zero. Two control runs were wasted
   on this before the precondition was added.
5. **The Word run that "showed the shadow is fixed".** It ran at `PerWindowCapture=0`, where
   synthesis cannot run, so the frozen shadow band could not have appeared whether or not the
   fix works. It proved nothing.

And the deeper version of the same mistake, twice: **the PREMISE of the comparison was wrong,
not the measurement.** "Stock is a valid control" (it lacked the feature under test) and "the
default is off" (it is ON — see the FINDINGS retraction). Both were one grep away. Check the
premise BEFORE running the comparison; a wrong premise yields confident, well-replicated,
meaningless numbers.

Plus two harness bugs that guards caught rather than results:
`Copy-Item -Force` over a **running** `gui-agent.exe` silently leaves the previous build
installed (Windows locks a running image — same reason a `qtest push` of `chromerepro.exe`
fails while it is running); and `grep -oE '...[^\r]*'` truncates at the first letter **r**,
because a POSIX bracket expression has no `\r` escape.

---

## 3. What is proven, and how

Method that works, and the only one that does — `scratchpad/ab-boot.sh`, `ab-orphan.sh`:
- **one cold boot per side** (see §4: an in-place agent restart kills gui-daemon);
- binary installed with the agent **stopped**, then the installed hash compared to the CI
  manifest before measuring;
- a **positive control in every run** (the main window must be announced) so a dead
  gui-daemon fails the run instead of silently reading as "the fix worked";
- 3 interleaved rounds per side.

**`aaa8c37`** (reject `MSO_BORDEREFFECT_WINDOW_CLASS`): stock announced 4/4 strips every
round, the fix 0/4 every round, total announcements differing by exactly the four strips.

**`66fc670`** (never re-home an owned popup onto an unrelated sibling) — **VALIDATED, 3/3 vs
3/3.** Control is agent **`aaa8c37`** (`6554EFED…`), test is `6b5b298` (`4DA9FE96…`),
`PerWindowCapture=1` asserted, scene `chromerepro --orphan`. Control adopted the popup into
the frame every round (`orphan_synth=1, adopted_by_main=1, orphan_mapped=0`, with `SYNTH_ALL`
naming the exact pair each time); the fix refused synthesis and announced the popup normally
(`0/0/1`) every round. Results in `scratchpad/ab-orphan-results.txt`.

Two signals moving in OPPOSITE directions is what makes it hard to fool: a confound that
merely suppressed synthesis would drive both counts to zero, and a dead gui-daemon would
suppress the announcement too. Only the intended behaviour inverts them.

### Scope limits — do not overstate these
- ~~`66fc670`'s defect is unreachable at the shipped default~~ **RETRACTED — see FINDINGS
  "there is no shipped `PerWindowCapture=0`".** The code default in `PwInit()` is **1 (ON)** and
  nothing in `guest/ mgmt/ tools/` ever writes the registry value, so a fresh install of this
  fork RUNS per-window capture. Our guest's 0 is a leftover from an earlier session's A/B. These
  fixes are **on-path**, and the daemon-killing chain was reachable out of the box.
- **The Office strip bug is a regression this fork introduced.** `d6ab61c` lowered the size
  floor for override-redirect popups to rescue Win11 keytip badges, which let Office's 8 px
  strips reach the chrome rules; `aaa8c37` closes that. Any upstream submission must say so,
  and `d6ab61c` has to travel with it or the hole reopens. **Needs user approval first.**
- Everything is measured against `chromerepro`, not real Office.

---

## 4. CORRECTED: only a FORCE-KILLED agent restart loses gui-daemon

An earlier section of this handoff claimed "one agent restart kills gui-daemon, reproducible on
demand". **Both halves were wrong** — see the FINDINGS retraction. Measured:

- `Global\QGA_SHUTDOWN` (`include/common.h:46`, `main.c:3483/3848`) is the supported way to stop
  the agent. Signalling it: agent exits in 1 s, watchdog respawns it, the new instance gets a
  vchan client, **dom0 keeps its windows**. `scratchpad/graceful-stop.ps1`.
- I had concluded "no graceful path exists" from `taskkill` without `/F` — which posts WM_CLOSE
  to a *windowless* process. Wrong mechanism, wrong generalisation.
- Every harness here used `Stop-Process -Force`, so the GUI losses blamed on "restarting the
  agent" were **self-inflicted by the stop method**.

Mechanism (daemon source, `gui-common/txrx-vchan.c`): guid has two EOF paths; the poll helper
calls `restart_guid()` and survives, while `handle_vchan_error` does a bare `exit(0)` and never
consults `vchan_at_eof`. Only the WRITE side reaches the fatal branch, and
`libxenvchan_buffer_space` ignores `is_open` — so it fires only if the daemon had something
queued at the instant the agent vanished. **A coin flip**, which explains 08-03 recovering twice
and 08-04 dying twice; my n=2 was never evidence of determinism.

Also dead: the "reconnect race" idea. `libvchan_client_init` waits with an INFINITE timeout for
the xenstore node, so a re-exec'd guid cannot fail just because the agent is briefly absent.

Practical: **cold-boot-per-side is no longer required for A/B runs** (it was a workaround for a
problem we caused); keep it for boot-path acceptance. Full options, the dom0 proposal, and the
attribution experiments are in `DESIGN-gui-daemon-restart-survival.md` — dom0 items need your
approval and nothing dom0-side has been touched.

---

## 5. T2 becomes a Track B deliverable — the mode list has to be OURS

The **stock Basic Display Adapter** exposes a fixed list of 29 modes and **1600x1000 is not in
it**. Confirmed by the agent's own `InitVideoModes()` (at `LogLevel=5`) and independently by
`ChangeDisplaySettings(CDS_TEST)`: 1600x1000 / 1234x777 / 2566x1022 → `DISP_CHANGE_BADMODE`,
1920x1080 → success.

**Do not read this as "T2 is blocked."** (An earlier draft did, and the user corrected it.)
The adapter is ours to choose — replacing it is the entire point of Track B, and declaring the
mode list, including arbitrary modes added on demand, is an IddCx driver's core capability.
The measurement establishes only that 1600x1000 cannot come from the *stock* adapter, so it
must come from **our** driver. It is the strongest concrete argument yet for building the IDD:
Phase 2B-resize needs sizes like 2566x1022 that no fixed list will ever contain.

**The trap to remember:** `SelectSupportedMode()` does not fail on an unsupported request — it
silently snaps to the nearest entry, so a naive "default to 1600x1000" would look like it
worked while quietly giving something else.

`LogLevel` note: the value gui-agent reads is in the **`…\Qubes Tools\gui-agent` subkey**, not
the parent key. Setting the parent does nothing.

---

## 6. Guest state at handoff

| thing | value |
|---|---|
| `netvm` | **detached** — measurement control only; T6 wants it networked again |
| `gui-agent.exe` | **`EBAE90FD`** — CI build of agent `8629a9c` = HEAD (wild-pointer + mask-sort + fb-invalidation, and `6b5b298` REVERTED). `.orig` (`4B4CE2B1`) intact |
| `PerWindowCapture` | **registry value REMOVED** — the guest now matches a fresh install, i.e. capture is **ON** via the code default. This is deliberate: `0` was our own test residue and reading it as "the shipped default" caused a whole day's worth of wrong conclusions |
| `LogLevel` (`gui-agent` subkey) | 3 (raise to 5 for per-window damage lines — `SendWindowDamageEvent` logs at VERBOSE, which silently zeroed a metric today) |
| services | QdbDaemon / QrexecAgent / QubesGuiWatchdog all Running |

**Consequence to expect:** with capture ON you will see the open occlusion artifact (leftovers
behind a moving window, §7 item 2). To silence it for interactive use:
`Set-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools' -Name PerWindowCapture -Value 0`
then reboot the qube — but remember that is NOT what a real user gets.

Binaries staged in `QubesIncoming\win-idd-mgmt` for reuse: `gui-agent-fixed3.exe` (`F06C0979`),
`gui-agent.exe` (`4DA9FE96`, pre-wild-pointer control), `gui-agent-ctl.exe` (`6554EFED`,
pre-`66fc670`), `gui-agent-98eed30.exe` (`3F8F2502`, pre-`aaa8c37`), `chromerepro.exe`
(`443391F9`, with `--mso` / `--mso-thin` / `--orphan` / `--popup`), `dump-windows.exe`.
Note a `qtest push` over a RUNNING exe silently fails — kill it first.

## 7. What is actually left

Nothing is half-finished. Everything started is either landed+validated, landed with its
unproven status stated, or written down as a plan with the experiment that would settle it.

**1. Stop force-killing the agent — and test the hang hypothesis at the same time.**
The guest hang is diagnosed as far as guest-side evidence allows (FINDINGS, "GUEST HANG"):
Windows never bugchecks, the hang PRECEDES the shutdown request, and the freeze is abrupt.
Leading hypothesis is leaked grants — `capture.c:428` says grants are NOT auto-revoked on handle
close, revocation lives only in user-mode teardown that `TerminateProcess` skips, per-window
buffers are ~4838 pages each, and 136,744 pages were granted today. Against it: no grant failure
is logged.
Convert `install-agent2.ps1` to signal `Global\QGA_SHUTDOWN` and wait (see
`scratchpad/graceful-stop.ps1`) instead of `Stop-Process -Force`, then rerun the ~30-cycle
install/reboot workload. Hangs stop ⇒ supports the leak; hangs persist ⇒ next suspect is the PV
transport, which needs dom0 and therefore you. **This change is justified regardless** — it is
also what stops gui-daemon being lost. Two failures, one cause: we were killing the agent
instead of asking it to stop.

**2. The occlusion artifact** — "leftovers behind a moving window" at per-window capture, which
is ON by default. The only known user-facing defect outstanding. Move a tracked window across
another and count `SendWindowDamageEvent` for the window being UNCOVERED; control = the same
motion at `PerWindowCapture=0`. Two traps already paid for: the probe must be a NATIVE tool
(P/Invoke from the qrexec shell cannot see session windows), and `SendWindowDamageEvent` logs at
VERBOSE so `LogLevel` must be 5 or the metric reads zero. Revives T3.

**3. Desktop size / T2** — `PLAN-trackb-t2-modes.md` plus the work-area addendum. Four
agent-side fixes can land before any driver work: the preference-vs-cache split, work area as a
ceiling, making `SelectSupportedMode`'s silent snapping visible, and the silent "No change"
no-op. Then the geometry-change recovery bug (`RecreateDuplication` bails on exactly the event
resize generates), then the driver.

**4. Track B proper** — Phase 1B's gating question, `DesktopImageInSystemMemory` under an IDD,
is unanswered and gates everything downstream.

**5. Needs YOU:**
   - **Non-QWT bug reports**, per your policy now in CLAUDE.md: the two gui-daemon defects in
     `DESIGN-gui-daemon-restart-survival.md` §3. Nothing from `agent/` goes anywhere until QWT
     is complete.
   - **dom0 diagnostics** if the hang survives change 1: `xl dmesg` and the domain console,
     captured BEFORE recovery. Also the guid log, which is perishable — truncated on the next
     non-`-f` start, so it survives exactly one recovery cycle.

Branches `control/aaa8c37`, `control/98eed30` and `control/revert-6b5b298` exist only to build
pre-fix control agents (`gh workflow run build --ref <branch>`). **Do not merge, do not delete**
— every A/B on this subsystem needs a control able to fail, and stock QWT cannot serve as one.

## 8. The one habit worth carrying forward

Seven instruments were discarded this session for being incapable of failing, and twice the
PREMISE was wrong rather than the measurement ("stock is a valid control"; "the default is
off"). Both were one `grep` away. The most serious defect of the day — a wild-pointer loop live
on the default path — was found by READING code, not by running it, and no test we had would
have caught it.

Before any comparison: ask what makes the control able to FAIL, and check the premise. Before
trusting a green run: check the instrument could have gone red.
