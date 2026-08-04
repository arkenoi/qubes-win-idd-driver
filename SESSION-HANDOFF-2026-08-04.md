# SESSION HANDOFF — 2026-08-04

Continues SESSION-HANDOFF-2026-08-03.md. Read that file's §4 "Traps" as well — they still
apply, and §4.4 (acting on a stale in-memory model) bit again today in a new form.

Everything below was read off the machine or the repo, not recalled. Full detail in
`FINDINGS.md` under the two 2026-08-04 headings.

---

## 1. Headline

**T1 is now partly closed and T2 is now blocked** — and the day's real lesson is about
controls, not about either fix.

| commit | status after today |
|---|---|
| `98eed30` | validated 2026-08-03 (unchanged) |
| `aaa8c37` | **VALIDATED** — 4/4 strips announced by the pre-fix build, 0/4 by the fix, 3 interleaved rounds, cold boot per side |
| `66fc670` | **VALIDATED** — control adopted the popup 3/3, fix refused it 3/3, on two opposed signals |
| `6b5b298` | **still unvalidated**; instrument designed and committed but never run |

**Four separate instruments were discarded today as incapable of failing.** That is the
single most useful thing to carry forward: before running any A/B, ask *what makes the
control able to FAIL*, and confirm the feature under test even exists on the control side.

---

## 2. The four dead controls (each failed differently)

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
- `66fc670`'s defect is **unreachable at the shipped default** (`PerWindowCapture=0`). It is
  a real fix for a real path, but latent unless per-window capture is on. Same for `6b5b298`,
  which lives entirely in `wincapture.cpp`.
- **The Office strip bug is a regression this fork introduced.** `d6ab61c` lowered the size
  floor for override-redirect popups to rescue Win11 keytip badges, which let Office's 8 px
  strips reach the chrome rules; `aaa8c37` closes that. Any upstream submission must say so,
  and `d6ab61c` has to travel with it or the hole reopens. **Needs user approval first.**
- Everything is measured against `chromerepro`, not real Office.

---

## 4. NEW, and the biggest robustness finding: one agent restart kills gui-daemon

Reproducible on demand from a known-good cold boot, on an offline guest: stop the watchdog,
kill the agent, copy the **same** binary back, start the watchdog → the new agent parks at
`Awaiting for a vchan client` forever, `qtest shot` returns **zero** windows, and only a full
qube restart recovers it. Two for two.

Consequences: in-place binary swapping is not a usable test method for this component, and
any "restart the agent to apply a fix" instruction is, on this build, an instruction to take
the qube's GUI down until reboot. This is dom0-side → Phase 3 discipline (design writeup and
user review before code), and worth an upstream issue on its own.

---

## 5. T2 is blocked on the IddCx driver — settled, stop re-deriving it

The adapter offers a **fixed list of 29 modes** and **1600x1000 is not in it**. Confirmed by
the agent's own `InitVideoModes()` (at `LogLevel=5`) and independently by
`ChangeDisplaySettings(CDS_TEST)`: 1600x1000 / 1234x777 / 2566x1022 → `DISP_CHANGE_BADMODE`,
1920x1080 → success.

**The trap:** `SelectSupportedMode()` does not fail on an unsupported request — it silently
snaps to the nearest entry. Implementing T2 as written would have *looked* like it worked
while quietly giving a different resolution. T2 is therefore a Track B deliverable.

`LogLevel` note: the value gui-agent reads is in the **`…\Qubes Tools\gui-agent` subkey**, not
the parent key. Setting the parent does nothing.

---

## 6. Guest state at handoff

| thing | value |
|---|---|
| `netvm` | **detached** — a measurement control only; T6 wants it networked again |
| `gui-agent.exe` | `4DA9FE96…` — the validated CI build of agent `6b5b298`; `.orig` (`4B4CE2B1…`) intact. Verified live after a cold boot: gui-daemon connected, `SendWindowMap` x2, all services Running |
| `PerWindowCapture` | **0** — restored to the shipped default. Set it to **1** for any synthesis or `6b5b298` work, or the code under test is inert |
| `LogLevel` (`gui-agent` subkey) | **3** — restored. Verbose (5) sits on the hot path and would pollute timing runs |

Also in `QubesIncoming\win-idd-mgmt` on the guest, ready to reuse: `gui-agent-ctl.exe`
(`6554EFED…`, the pre-fix control), `chromerepro.exe` (`443391F9…`, with `--mso`/`--orphan`),
`dump-windows.exe`, `install-agent2.ps1`, `boot-measure-orphan.ps1`, `secure-desktop-probe.ps1`.
Note a `qtest push` of `chromerepro.exe` FAILS while it is running — kill it first.
| lockout threshold | `Never` (so trap 4.3 cannot bite) |
| autologon | `AutoAdminLogon=1`, **no** `DefaultPassword` — yet autologon works at boot every time (~12 boots today), so the credential lives in LSA, not the registry |

One reboot in roughly nine wedged in `Transient` for >5 min; `qtest kill` + `qtest start`
recovered it cleanly. Low rate, no cause claimed, but T6 wants reboot survival — watch it.

---

## 7. Next steps, in order

1. **`6b5b298`** — the last unproven commit. `scratchpad/secure-desktop-probe.ps1` is written
   but **never run**. Two pitfalls already baked into it: (a) do **not** count `MSG_SHMIMAGE`
   — the DDA frame loop keeps emitting it on both sides and only the per-window thread is
   affected, so it cannot discriminate; count `SendWindowDamageEvent` restricted to HWNDs
   that hold a per-window buffer instead; (b) the fix's idle path logs **nothing**, so the
   signal is an absence — which means the control MUST be shown to produce the activity
   first. Needs `PerWindowCapture=1`. Locking the guest is recoverable by reboot only.
   Consider instead an instrumented pair of builds (log the input-desktop name each pass) and
   validate the logic, then ship the uninstrumented binary — stating that plainly.
2. **T2 → Track B.** The IddCx driver is now the blocking dependency for dynamic resolution.
   Phase 1B's question (does an IDD-backed desktop keep `DesktopImageInSystemMemory` TRUE)
   is unanswered and gates everything.
3. **gui-daemon fragility (§4)** — design writeup, then user review, before any code.
4. **Upstream framing for `aaa8c37` + `d6ab61c`** — needs explicit user approval of the exact
   text per CLAUDE.md.

Branch `control/aaa8c37` exists solely to build the pre-fix control agent (superproject pins
the submodule there; build it with `gh workflow run build --ref control/aaa8c37`). **Do not
merge it**, and keep it — any future synthesis A/B needs that binary.
