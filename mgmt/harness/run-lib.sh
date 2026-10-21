# mgmt/harness/run-lib.sh — shared JOB LIFECYCLE for VM harnesses: signal/EXIT teardown of the
# descendant process tree, guaranteed vm-lock release, and verify-started. Source this from the
# ENTRY script (after vm_lock if it takes one) and call `job_init <label>`.
#
# WHY (2026-09-06, observed live). Killing the top harness script (p3a-etw-gate.sh) killed ONE
# process: its children (prime-run.sh, qtest, `sleep`s) reparented to init and kept running -
# churning the guest for 40+ minutes and, under the old fd-inheriting vmlock, holding the guest
# lock of a dead job. Separately, ad-hoc runners auto-chained "next job on previous job's exit",
# so the killed run FIRED THE NEXT VM JOB while the harness files were mid-edit. And a run that
# bounced instantly on the lock (rc=2) produced no further log lines, which a log-tailing watcher
# read as "still priming". This library is the fix for all three:
#
#   job_init [label]     install ONE set of traps (EXIT TERM INT HUP). On any exit: run the
#                        optional job_on_abort hook (signals only), TERM the live descendant
#                        tree BY EXPLICIT PIDS (never pkill -f - it matches your own command
#                        line), grace-wait, KILL survivors, release the vm lock LAST
#                        (vm_unlock), and log one machine-readable "TORE DOWN" line. A SIGTERM
#                        of the top script therefore leaves ZERO orphans. (SIGKILL skips traps
#                        by definition - even then the vmlock holder self-frees ~2s after the
#                        leader dies; only stray children can survive, so prefer SIGTERM.)
#   job_on_abort()       optional, defined by the CALLER before the signal can fire: extra
#                        abort-time work (e.g. prime-run marks its half-primed subject
#                        CONTAMINATED). Called with one arg, "signal-TERM" etc. NOT called on
#                        normal exits - error exits deliberately preserve guest state as
#                        evidence (H3.5).
#   kill_tree [-x skip] <pid>...   TERM then KILL the live descendant tree of each pid (the
#                        pids themselves are NOT signalled). Usable standalone.
#   run_verified <log> <timeout_s> <cmd...>   launcher-side VERIFY-STARTED: background cmd
#                        into <log> (stdout+stderr), then within <timeout_s> demand either the
#                        start banner (default 'VMLOCK-ACQUIRED', override with RL_START_RE) or
#                        the process's exit. Distinguishes, LOUDLY: STARTED (rc 0, job runs on;
#                        pid in RL_STARTED_PID) / BOUNCED (job exited first - rc propagated,
#                        never 0, log tail dumped) / NOT CONFIRMED (rc 4, alive but silent -
#                        investigate, do not assume it is priming). It returns at START and
#                        never waits for completion: whether and when to run ANOTHER VM job is
#                        always a fresh human/agent decision. NO auto-chaining - a killed run
#                        must never fire the next job as a side effect (live corruption,
#                        2026-09-06). This library deliberately has no "then run X" helper.
#
# Assumes bash 5 + procps `ps`. Traps: job_init OWNS the EXIT/TERM/INT/HUP traps - a caller
# that sets its own `trap ... EXIT` afterwards would silently REPLACE the teardown (bash keeps
# one trap per signal), so callers add exit work via job_on_abort or before job_init, never
# with a competing trap.

RL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# vm_unlock/vm_lock come from vmlock.sh; sourcing twice is harmless (function definitions).
. "$RL_LIB_DIR/vmlock.sh"

# All live descendants of $1, deepest first, one per word. The `ps` child that enumerates them
# is itself transient; already-dead pids are handled by suppressed kill errors.
_rl_descendants(){
  local kid
  for kid in $(ps -o pid= --ppid "$1" 2>/dev/null); do
    _rl_descendants "$kid"
    printf '%s ' "$kid"
  done
}

# kill_tree [-x skip_pid] <root>...: TERM the live descendant tree of each root (excluding
# skip_pid, e.g. the vmlock holder so the lock is released LAST, by vm_unlock, not as a kill
# side effect), wait up to 8s, KILL survivors. Sets RL_KILLED to the pid list for the log line.
kill_tree(){
  local skip="" p pids="" list="" alive="" i
  if [ "${1:-}" = "-x" ]; then skip="${2:-}"; shift 2; fi
  for p in "$@"; do pids+="$(_rl_descendants "$p")"; done
  for p in $pids; do
    [ "$p" = "$skip" ] && continue
    [ "$p" = "$BASHPID" ] && continue
    list+="$p "
  done
  RL_KILLED="${list% }"
  [ -n "${list// /}" ] || return 0

  # LET AN IN-FLIGHT qrexec CALL FINISH CONNECTING FIRST.
  #
  # MEASURED 2026-10-09, and it is the gate's own breach: killing this tree while a
  # qrexec-client-vm is still mid-connect makes the client vanish BEFORE the guest-side
  # qrexec-wrapper reads the vchan's xenstore node, so the wrapper correctly reports a departed
  # peer - "QGAVCHANFAIL ... xenstore node unreadable". Three of those fired within 0.3 s at uptime
  # 261 s on win11-acc as five gate suites failed fast and their trees were reaped, and log-sweep
  # counted them as error_lines_undeclared=1, breaching "a clean error log is THE gate condition".
  # The product line is right and stays; the CAUSE is here. Jev refused the alternative of having
  # the run declare the lines it caused (declaring_is_hiding 0.63), and named this the biggest gap
  # at 0.80.
  #
  # WHY THIS IS SHORT AND BOUNDED: the exposed window is only the first moments of a call, while the
  # client publishes the node and the guest spawns its wrapper. A client that has already connected
  # is past that point and its death is reported by a different path. So this waits only for
  # qrexec-client-vm descendants, only up to RL_QREXEC_GRACE seconds (default 12), and then proceeds
  # exactly as before - a teardown can never be delayed indefinitely by a long-running call.
  local qr grace="${RL_QREXEC_GRACE:-12}" waited=0
  while [ "$waited" -lt "$grace" ]; do
    qr=""
    for p in $list; do
      kill -0 "$p" 2>/dev/null || continue
      case "$(cat /proc/$p/comm 2>/dev/null)" in qrexec-client-v*) qr+="$p " ;; esac
    done
    [ -z "${qr// /}" ] && break
    sleep 1
    waited=$((waited + 1))
  done
  [ "$waited" -gt 0 ] && echo "run-lib: waited ${waited}s for in-flight qrexec client(s) before teardown" >&2

  kill -TERM $list 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    alive=""
    for p in $list; do kill -0 "$p" 2>/dev/null && alive+="$p "; done
    [ -z "${alive// /}" ] && return 0
    sleep 0.5
  done
  echo "run-lib: descendants [$alive] survived TERM+8s grace - KILLing" >&2
  kill -KILL $alive 2>/dev/null
  return 0
}

_rl_teardown(){
  local via="$1" rc="$2" lockmsg
  # Abort hook first, ONLY for signals: a signal means "operator/parent stopped this job", and
  # e.g. prime-run must mark its half-primed subject contaminated before anything else dies.
  # Normal (even failing) exits skip it: TERMINAL exits leave guest state as evidence (H3.5).
  case "$via" in
    signal-*) declare -F job_on_abort >/dev/null && job_on_abort "$via" ;;
  esac
  if [ "${QWT_VMLOCK_OWNER_PID:-}" = "$$" ]; then
    lockmsg="vmlock=${QWT_VMLOCK_HELD:-?}:released"
  elif [ -n "${QWT_VMLOCK_HELD:-}" ]; then
    lockmsg="vmlock=${QWT_VMLOCK_HELD}:held-by-ancestor-untouched"
  else
    lockmsg="vmlock=none"
  fi
  # Kill the tree by explicit pids, sparing the vmlock holder so the guest stays locked until
  # everything that could touch it is dead; vm_unlock below is the authoritative release.
  kill_tree -x "${QWT_VMLOCK_HOLDERPID:-}" "${RL_LEADER:-$$}"
  vm_unlock
  echo "TORE DOWN (${RL_LABEL:-job} via=$via rc=$rc): descendants=[${RL_KILLED:-none}] $lockmsg" >&2
  # NO process-group sweep here, deliberately (tried and removed 2026-09-06): when the job
  # leads a pipeline group ('harness | tee log' under an interactive shell), `kill -- -$$`
  # TERMs the operator's tee/grep as well and the pipeline's exit status becomes tee's 143
  # instead of the harness's rc. Its only coverage beyond the explicit pid walk above is
  # grandchildren whose intermediate parent was SIGKILLed before this trap ran - a narrow
  # residual whose members here are bounded anyway (sleeps <=90s, qtest under timeout -k),
  # and the vm lock self-frees ~2s after the leader dies regardless. Kill jobs with SIGTERM
  # to the leader and the walk gets everything.
}

_rl_on_sig(){
  local sig="$1"
  trap '' TERM INT HUP EXIT   # no recursion, and no second teardown via the EXIT trap
  _rl_teardown "signal-$sig" "$2"
  exit "$2"
}

_rl_on_exit(){
  local rc=$?
  trap '' TERM INT HUP EXIT
  _rl_teardown exit "$rc"
  exit "$rc"
}

job_init(){
  RL_LABEL="${1:-${0##*/}}"
  RL_LEADER=$$
  RL_KILLED=""
  trap '_rl_on_sig TERM 143' TERM
  trap '_rl_on_sig INT 130'  INT
  trap '_rl_on_sig HUP 129'  HUP
  trap '_rl_on_exit' EXIT
  return 0
}

# rl_fg <cmd...>: run a LONG foreground command INTERRUPTIBLY, propagating its exit status.
# Bash defers a trapped signal until the current foreground command exits - so a TERM to the
# harness during a foreground `prime-run.sh` (3600s deadline) would defer the whole teardown
# by up to an hour (measured on the local lifecycle test: a TERM during a foreground sleep
# simply hung). `wait` on a background child IS interruptible: the trap runs immediately and
# never returns. Wrap any single command expected to run longer than ~2 minutes; short
# commands and loops of short commands don't need it (deferral is per simple command).
rl_fg(){
  "$@" &
  wait $!
}

# run_verified <logfile> <timeout_s> <cmd...>  - see header. Watches the log region written
# AFTER launch (an old banner in a reused log can never satisfy it).
run_verified(){
  local logf="${1:?run_verified <logfile> <timeout_s> <cmd...>}" tmo="${2:?timeout}"; shift 2
  local re="${RL_START_RE:-VMLOCK-ACQUIRED}"
  : >>"$logf" 2>/dev/null || { echo "[ERROR] run_verified: cannot write log $logf" >&2; return 3; }
  local mark; mark=$(wc -c <"$logf")
  "$@" >>"$logf" 2>&1 &
  local pid=$! t0=$SECONDS rc
  echo "run_verified: launched pid=$pid: $* (log=$logf; stop it with: kill -TERM $pid - its traps tear down the tree)"
  while :; do
    # COUNT, never `grep -q`: the log is still being written, so an early match closes the pipe,
    # tail dies of SIGPIPE, pipefail returns 141 - and a job that DID start is reported as never
    # having started. grep -c reads to EOF.
    if [ "$(tail -c "+$((mark+1))" "$logf" 2>/dev/null | grep -ac "$re")" -gt 0 ]; then
      echo "run_verified: STARTED pid=$pid - '$re' confirmed in $logf"
      RL_STARTED_PID=$pid
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null; rc=$?
      echo "run_verified: BOUNCED rc=$rc - the job exited before confirming start (lock refusal?). It is NOT running. Log tail:" >&2
      tail -n 20 "$logf" >&2
      [ "$rc" -eq 0 ] && rc=1   # exit 0 without the banner is still NOT STARTED - never report success
      return "$rc"
    fi
    if [ $(( SECONDS - t0 )) -ge "$tmo" ]; then
      echo "run_verified: NOT CONFIRMED within ${tmo}s - pid $pid is alive but never printed '$re'. Investigate NOW; do not assume it is priming. Log tail:" >&2
      tail -n 20 "$logf" >&2
      return 4
    fi
    sleep 1
  done
}

# ---------------------------------------------------------------------------------------------
# sweep_gate_rc - DOES THE ERROR SWEEP OF A RUN'S OWN LOG MOVE THE VERDICT?
#
#   sweep_gate_rc <gate-output-file>
#       0  nothing in that output must move a counter
#       1  it must: unaccounted or risen declared errors remain after the caller's own graded
#          verdicts are discounted
#
# WHY IT IS A FUNCTION AND NOT A LINE IN THE HARNESS. `quick-upgrade.sh` ran the gate, printed its
# findings and then said, in a comment, "REPORTS, DOES NOT GATE - yet". So the short cycle - the
# sanctioned path for every fix on this project - could carry an unexplained declared error in its
# own log and still exit 0. Owner, 2026-10-16: "the sweep gate SHOULD be fixed."
#
# IT READS THE GATE'S STRUCTURED LINE, NOT ITS PROSE. tools/sweep-gate.sh prints
# `SWEEP-GATE-RESULT unaccounted=<n> risen=<n> accounted=<n>`, and the blind case prints
# `SWEEP-GATE-RESULT undeclared_ours=<n>` instead - a gate that judged only part of the run, whose
# silence means nothing. Both must move the verdict. Counting the printed UNACCOUNTED lines with
# grep is what this replaces: a watcher built on the shape of a message is how four cells' worth of
# findings were read as "0 FAIL" on 2026-10-15.
#
# AND IT DOES NOT COUNT THE CALLER'S OWN VERDICTS TWICE. A harness writes its own failures into the
# same log at `[ERROR] ...`/`[WARN] ...`, and a failing run therefore hands the gate its own words.
# Those are already in the caller's tally, so UNACCOUNTED lines that are a graded verdict of ours
# (`FAIL `, `summary: `, `no `) are discounted here - shown by the gate, never counted again.
sweep_gate_rc(){
    local out=${1:?sweep_gate_rc needs the gate output file}
    [ -s "$out" ] || return 0
    local res blind un ro own
    res=$(grep -a '^SWEEP-GATE-RESULT' "$out" | tail -1)
    # A GATE THAT PRODUCED OUTPUT BUT NO VERDICT DID NOT JUDGE THE RUN, AND THAT IS NOT A CLEAN
    # SWEEP. This returned 0 - the same value as "ran clean, found nothing" - with the comment "the
    # gate did not get far enough to have a verdict", and the only production caller
    # (quick-upgrade.sh:198) reaches this function exclusively from the ELSE branch of
    # `if bash tools/sweep-gate.sh; then ... else ...`, i.e. ALREADY KNOWING the gate exited
    # non-zero. So a crash in the gate's python normalisation step, or a kill mid-run, logged "the
    # only error-shaped lines are this run's own graded verdicts" and left rc untouched: a sweep
    # that never ran, reported as equivalent to a clean one. Scored 0.75 as a campaign-stopper by
    # the tier re-check, 2026-10-21, from a tier the audit had put below blocks-acceptance.
    # Its own code (2), because "the gate did not judge" is a different fact from "the gate judged
    # and found something" (1) and no caller should have to tell them apart by guessing.
    # An EMPTY/ABSENT file keeps returning 0 above: that is the gate not having run at all, which
    # the caller controls and the suite asserts separately (T20d).
    if [ -z "$res" ]; then
        echo "sweep_gate_rc: the gate wrote output but never printed SWEEP-GATE-RESULT - it did not" >&2
        echo "  judge this run. That is missing data, not a clean sweep ($out)." >&2
        return 2
    fi
    blind=$(printf '%s\n' "$res" | sed -n 's/.*undeclared_ours=\([0-9][0-9]*\).*/\1/p')
    if [ -n "$blind" ] && [ "$blind" -gt 0 ]; then return 1; fi
    un=$(printf '%s\n' "$res" | sed -n 's/.*unaccounted=\([0-9][0-9]*\).*/\1/p'); un=${un:-0}
    ro=$(printf '%s\n' "$res" | sed -n 's/.*risen=\([0-9][0-9]*\).*/\1/p');       ro=${ro:-0}
    own=$(grep -acE '^  UNACCOUNTED .*\[(ERROR|WARN)\] +(FAIL |summary: |no )' "$out" 2>/dev/null || true)
    own=${own:-0}
    un=$((un - own)); [ "$un" -lt 0 ] && un=0
    [ $((un + ro)) -gt 0 ] && return 1
    return 0
}
