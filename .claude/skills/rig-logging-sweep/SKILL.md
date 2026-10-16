# rig-logging-sweep — get the guest's logs out, and judge them

Read before collecting, grading or reporting on a run's logs. Every number below was measured on
this rig; none is a shape anyone invented.

## The one rule

**A run has no log verdict until a structured artifact says so.** Not a tail, not a grep, not
silence. `report.json` per cell, `campaign-state.py` per campaign. Silence is the failure mode this
whole chain exists to remove: on 2026-10-15 a campaign with four failed cells and three P1 breaches
was reported as "0 FAIL, campaign healthy" four times, because a hand-written watcher pattern
(`^\[[0-9:]+\] (FAIL|no) `) did not match the line it was looking at
(`[20:00:38] [ERROR] FAIL  win10-clean: ...`). The sweep had returned `rc=1 FINDINGS` every time.

## The pipeline

| Stage | Command | Verdict |
|---|---|---|
| 1. collect | `mgmt/harness/log-sweep.sh <vm> <since-utc> <outdir>` | writes `pull.txt`, `logs/`, `report.json`, `summary.txt` |
| 2. decode | `tools/log-sweep.py decode <pull.txt> --out <logsdir>` | rc 1 on a count/hash mismatch, truncated block or missing END |
| 3. analyze | `tools/log-sweep.py analyze <logsdir> --baseline mgmt/harness/log-sweep-baseline.json --out <report.json>` | 0 CLEAN · 1 FINDINGS · 3 DATA · 4 INCOMPLETE |
| 4. gate | `tools/sweep-gate.sh <log> [...]` | 0 accounted for · 1 something is not · 2 nothing readable |
| 5. verdict | `tools/campaign-state.py [<campaign-dir>]` | 0 clean · 1 a cell failed or a P1 breached · 2 NO-VERDICT |

`<since-utc>` is the instant the harness started the run, as `2026-10-07T08:00:00Z`.

**Stage 4 moves the verdict, it does not just print.** `sweep_gate_rc`
(`mgmt/harness/run-lib.sh`) reads the gate's **structured** `SWEEP-GATE-RESULT` line — never the
shape of its messages — raises the caller's rc on an unaccounted or risen error, treats the **blind**
case (`undeclared_ours>0`: a gate that judged only part of the run, whose silence means nothing) as a
finding too, and discounts the caller's own graded verdicts so one failure is not counted twice.
`matrix.sh` does the same through `no "INVALID-SWEEP…"`. Until 2026-10-16 `quick-upgrade.sh` printed
the findings and left rc alone, so the short cycle — the sanctioned path for every fix here — could
carry an unexplained declared error and still exit 0.

**3 and 4 are never a pass.** rc 3 means a log was missing, empty, partial or unparseable; rc 4
means the judge did not run. Missing data is not a clean run. `campaign-state.py` exit 2 means no
cell graded anything — also not a pass, and it says so in words rather than printing a zero.

## Two stores, and why both

- **LogDir** — normally `Q:\Qubes Logs`, on the guest's **PRIVATE** volume. What ships. Read by the
  collector over `qubes.VMShell` as SYSTEM.
- **The DIAG stick** — a FAT image on `xvdj`, label `DIAG`, its own loop device in this qube. The
  **host** reads it with `mdir`/`mcopy` *without the guest's cooperation* — so it is the only store
  that survives a wedged guest, which is exactly when the pull path cannot help.

`logvol_bind_guest <vm> <id>` (`mgmt/harness/logvol-lib.sh`) binds LogDir onto the stick. It is
**OFF by default** (`LOGVOL_BIND=1` to enable) and that default has been wrong in both directions;
`LOGVOL_BIND=1` is for hunting a wedge, which is what the volume was built for. The receipt is the
`LOGVOL-BIND` line — **a bind that moved 0 bytes is a failed bind**, not a bind.

mtools is lost on every mgmt reboot: `rpm2cpio` → `~/bin` (memory `mtools-mcopy-recovery`).

## Severity comes from the WRITER, never from vocabulary

Every QWT line is `[YYYYMMDD.HHMMSS.mmm-PID[:TID]-L]` with `L` ∈ `D I W E`; PowerShell and installer
logs use `[ERROR]`/`[WARN]`. `blog_level` is **the writer's declared level, or nothing** — no
vocabulary, no guessing. An undeclared line returns `None`: neither error nor non-error, and
therefore **invisible to every gate**. So undeclared lines are **counted and named**, never ignored;
that count is the honest size of what the tool cannot judge, and the lever for making the emitter
declare.

Two earlier versions tried to recognise an error by its words and missed

```
gui-agent.exe died within 10000 ms of starting, 2 time(s) in a row ... The guest has NO GUI
while this lasts ... (grant-table exhaustion, 0x5aa, needs a reboot)
```

because no word in it was on the list. Jev scored that approach **0.07**. Owner: *"NO FUCKING
SHAPES. ALL error messages should be handled."* The emitter **should** declare; fix the emitter.

## The ledger is a disposition, not a silencer

`mgmt/harness/error-ledger.txt`. Every declared `E`/`W` line is reduced to its message (prefix, hex
and numbers are not part of a message) and must have an entry. An entry means *someone read this and
recorded what it means* — for **one message**, not for a class. **A real defect does not belong in
the ledger**: it gets fixed, stays out, and surfaces again every run until it is gone.

## Deterministic is code; semantic is Jev

Parsing, signatures, per-signature/family/boot counts, joins, thresholds → **code**. "Is this new
signature a defect, expected behaviour or noise?" → **Jev**, batched one call per run, one question
per item. `jev.py` exit 2 = the judge did not run = **INCOMPLETE, never a pass**. Score the
ARTIFACT, not prose (`tools/jev-artifact.sh`).

## Traps, each one measured

- **Boot attribution manufactures defects.** Three times now. `boot_for()` admitted a boot up to
  150 s in the **future** and kept the last one; win10-clean's boots were **55 and 62 s apart**, so
  three of four agent instances landed in boot 4 and `agent_instances_per_boot` read 3 against a max
  of 1. The forward allowance must be **derived** — never past `BOOT_TOL_S`, never past the midpoint
  to the next boot. Before trusting any per-boot metric, check the boot list in `report.json`.
- **A per-day log is many processes.** `gui-agent-<yyyymmdd>.log` is appended by every instance of
  the day, and concurrent appenders **interleave**. Split by the **pid in the prefix**, grouped, not
  by consecutive runs; one file ≠ one instance. windows-utils writes `Log started` → `System uptime`
  → `process ID`, so **open the instance record on `Log started`** — opening it on the pid line put
  each instance's boot estimate on the previous instance's record and threw the first one away.
- **A clock correction looks like six boots.** The guest's clock moves mid-boot; estimates either
  side of the jump land one offset apart and the same boot counts twice. Sequence per **writer**,
  never across writers, and never re-detect on already-shifted data.
- **`events.txt` concatenates channels**, each in its own time order — a channel boundary is **not**
  a backward clock jump. Two P1s (960 s, 1260 s) were this.
- **A completed task is not a failure.** Task Scheduler 201 reads "successfully completed ... with
  return code N". Our tasks run and complete every boot, so counting every 201 made a `max 0` metric
  unpassable. Require the return code.
- **A reaped task is not a death — and the previous boot's backlog is not read at all.** Task
  Scheduler **refuses to launch anything during shutdown**, so the death reporter is not alive when
  the kills land. It used to read them in the next boot's catch-up and infer, from a record's mere
  presence there, that a shutdown had reaped it — which is what put "The PV NIC setup task failed"
  in front of the user. Owner 2026-10-16: reading that backlog "is misleading and overreaching".
  The catch-up now stops at the boot boundary (the watermark carries the volatile per-boot token it
  was written under), so a record from another boot re-seeds and reports nothing, and the only
  shutdown evidence left needs no inference: the live kernel state plus a result code that NAMES the
  reap. Event 111 is also raised at `ExecutionTimeLimit`, which is why the code was never optional.
- **The gate must not grade its own output.** `_is_own_report` excludes `SWEEP-GATE-*` and
  `LOGSWEEP-RESULT` from the census; without it the gate blocked on its own report.
- **Coverage is over our own logger shapes only.** A gate that judged 9% of its input and passed is
  worse than no gate.
- **A pushed file must ARRIVE before anything runs it.** `qtest pushrun` asserts the delivered byte
  count and exits 4 if nothing arrived — measured twice as `sent 0/11 KB` followed by "the argument
  ... does not exist", and both times the logs stayed on C:.
- **Every gate suite needs a producer.** 14 of 33 had none. `tools/tests/gate-producer-selftest.sh`.
- **Never sample.** `head` on an enumeration is how three P1s were missed. Enumerate completely.
- **Tool-shell grep is `ugrep -I`** and silently skips non-UTF-8 files — guest captures contain
  `NT-AUTORITÄT`. Use `grep -a` / `command grep`.

## Self-tests — a check never seen to FAIL is not evidence

```
tools/tests/log-sweep-selftest.sh          the analyzer, incl. the GUARD knobs
tools/tests/sweep-gate-selftest.sh         severity, coverage, the ledger
tools/tests/campaign-state-selftest.sh     plants a failing report and requires it to be reported
tools/tests/gate-producer-selftest.sh      every suite the gate requires has a producer
tools/tests/qtest-push-selftest.sh         a copy that delivers nothing must not run the script
tools/tests/logvol-lib-selftest.sh         the stick, the tag, the bind receipt
tools/tests/matrix-logsweep-grade-selftest.sh   the harness's own grading
```

A `# GUARD:<knob> DEFECT: <old line>` marker means the suite re-runs the tool with that **one line**
replaced by its defect and requires the assertion to **fail**. Add the knob with the fix, in the
same commit, or the fix is untested by construction.
