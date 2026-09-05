# Per-GUEST mutual exclusion for acceptance harnesses.  source this, then: vm_lock "$VM"
#
# WHY. CLAUDE.md: "Run VM-mutating jobs serially. Concurrent bisects rebooted the test VM
# underneath each other and destroyed hours of results." That rule was enforced only by my
# remembering it, and on 2026-08-31 I broke it in a new way: a runner was launched with `nohup ... &`
# inside an already-backgrounded task, the WRAPPER exited, the harness reported `exit code 0` and
# tore down the process group - but the nohup'd runner SURVIVED, which is precisely what nohup is
# for. Believing it dead, I started a second run against the same guest and the same output
# directory. The two interleaved: doubled banners in one log, a probe JSON whose mode disagreed with
# the banner above it, and finally SG2 graded FAIL - "a 1600x900 window reached dom0" - against the
# OTHER run's captioned probe, which maps legitimately at 1586x893. That is a fabricated product
# defect produced entirely by the instrument.
#
# A rule I have to remember is not a control. This is the control: the second runner cannot start.
#
# HOW THE LOCK IS HELD - the 2026-09-06 redesign. The first implementation did
# `exec {FD}>>lockfile; flock -n $FD` in the harness shell itself. That fd had no close-on-exec
# (bash does NOT set FD_CLOEXEC on {var} fds - verified on this rig - and CANNOT: the external
# `flock -n $FD` call only works because the flock binary INHERITS the fd), so every child of the
# harness (prime-run.sh, its `sleep`s, qtest) inherited the open, flock-bearing description.
# Killing the harness then released NOTHING: orphaned children kept the fd open and the advisory
# lock lived until the last orphan died. Measured live 2026-09-06: killing p3a-etw-gate.sh left
# prime-run.sh + sleeps holding /tmp/qwt-vmlock-win10-p3etw for 40+ minutes, and the next run
# bounced with rc=2 naming a long-dead pid.
#
# Now the lock lives in a dedicated HOLDER process instead of the harness shell:
#
#   flock -n -o <lockfile> sh -c '<write holder info>; exec tail --pid=<job leader> -f /dev/null'
#
#   - `flock -o` keeps the locked fd ONLY in the flock waiter; the exec'd sentinel (tail) does
#     not carry it, and no harness child can ever inherit it - the harness shell never owns it.
#   - the sentinel lives exactly as long as the JOB LEADER ($$ of the script that called
#     vm_lock): when the leader exits FOR ANY REASON (normal exit, error, SIGTERM, SIGKILL),
#     `tail --pid` notices within ~1-2s, exits, the flock waiter exits, and the lock is FREE.
#     Release is guaranteed by process lifetime, not by traps (traps can be clobbered or
#     skipped on SIGKILL; a process's death cannot).
#   - vm_unlock releases explicitly and immediately (run-lib.sh's teardown calls it), and is a
#     no-op in any process that merely INHERITED the lock (children must never release the
#     parent's lock - ownership is tracked in an UNexported variable).
#
# Stale locks: if flock refuses, the recorded holder pid is checked with kill -0. A live holder
# is a real conflict and refuses as before (rc=2). A DEAD holder is reclaimed: any leftover
# holder/sentinel process of the dead job is killed by recorded pid (never pkill -f - it
# self-matches), the acquire is retried for 15s (covers the sentinel's ~2s release lag), and as
# a last resort the lock FILE is rotated (unlink + fresh inode) to break a pre-redesign orphan's
# inherited fd, with a post-win re-verify to close the rotation race. Every step logs loudly.
#
# RE-ENTRANT within one job, because harnesses legitimately call each other -
# failproof-faultinject.sh runs rnd8-resolution.sh three times, and a naive lock would make the
# child refuse its own parent. QWT_VMLOCK_HELD is exported once acquired, so descendants pass
# straight through while any UNRELATED process is still refused. NOTE the flip side since the
# redesign: the lock dies with the JOB LEADER, so if the leader is SIGKILLed while a child
# harness still runs, the lock frees ~2s later even though the child is alive. Kill jobs with
# SIGTERM to the leader (its run-lib.sh traps tear down the whole tree first), not SIGKILL.
#
# The lock is advisory and per-VM: it serialises work on one guest, and deliberately does not stop
# two harnesses running against two different guests, which is safe and useful.
# protocol/run.py takes the same per-guest lock file (fcntl.flock on an O_APPEND fd; python fds
# are close-on-exec by default, so it never had the inheritance bug) - the two interoperate, and
# run.py may APPEND its holder line, which is why parsers below take the LAST `pid=` line.

# _vmlock_try <vm> <lockfile>: one non-blocking acquire attempt. 0 = lock is ours (holder
# spawned, QWT_VMLOCK_HOLDERPID/QWT_VMLOCK_SENTINELPID set); 1 = refused.
_vmlock_try(){
  local vm="$1" lf="$2" hp n line
  flock -n -o "$lf" /bin/sh -c \
    'printf "pid=%s holder=%s sentinel=%s started=%s cmd=%s vm=%s\n" "$1" "$PPID" "$$" "$(date -u +%FT%TZ)" "$2" "$3" > "$4"; exec tail --pid="$1" -f /dev/null' \
    vmlock-holder "$$" "${0##*/}" "$vm" "$lf" &
  hp=$!
  disown "$hp" 2>/dev/null || true
  # Acquisition is confirmed by CONTENT (this job's pid+holder pid in the lock file, written by
  # the sentinel AFTER flock granted the lock), refusal by the holder's death (flock -n exits 1
  # without forking the sentinel). Content match alone is not enough: a recycled pid could match
  # a stale line, so the line must name THIS holder process too.
  n=0
  while :; do
    line=$(grep -a "^pid=$$ holder=$hp " "$lf" 2>/dev/null | tail -1)
    [ -n "$line" ] && kill -0 "$hp" 2>/dev/null && break
    kill -0 "$hp" 2>/dev/null || return 1
    n=$((n+1))
    if [ "$n" -ge 30 ]; then
      echo "FATAL vmlock: holder $hp for $vm neither acquired nor exited in 3s - instrument broken" >&2
      kill "$hp" 2>/dev/null
      return 1
    fi
    sleep 0.1
  done
  QWT_VMLOCK_HOLDERPID="$hp"
  QWT_VMLOCK_SENTINELPID=$(printf '%s\n' "$line" | sed -n 's/.*sentinel=\([0-9]\{1,\}\).*/\1/p')
  return 0
}

# _vmlock_won <vm>: bookkeeping + the VERIFY-STARTED banner. The banner line is the machine
# signal that a launched job actually acquired its guest and is running (run-lib.sh
# run_verified watches for it); it goes to stderr so harness stdout parsing is unaffected.
_vmlock_won(){
  export QWT_VMLOCK_HELD="$1"
  QWT_VMLOCK_OWNER_PID=$$   # deliberately NOT exported: children inherit HELD (pass-through),
                            # never ownership - vm_unlock in a child must be a no-op.
  echo "VMLOCK-ACQUIRED vm=$1 pid=$$ holder=${QWT_VMLOCK_HOLDERPID:-?} job=${0##*/} at=$(date -u +%FT%TZ)" >&2
}

vm_lock(){
  local vm="${1:?vm_lock <vm>}"
  # already held by an ancestor of this job - the whole point is to serialise JOBS, not calls
  if [ "${QWT_VMLOCK_HELD:-}" = "$vm" ]; then return 0; fi
  local lf="${TMPDIR:-/tmp}/qwt-vmlock-$vm"
  : >> "$lf" 2>/dev/null || { echo "FATAL: cannot open lock $lf" >&2; exit 2; }

  _vmlock_try "$vm" "$lf" && { _vmlock_won "$vm"; return 0; }

  # Refused. Read the recorded holder (LAST pid= line - run.py appends its own) and decide.
  local hline hpid hproc hsent comm i
  hline=$(grep -a '^pid=' "$lf" 2>/dev/null | tail -1)
  hpid=$(printf '%s\n' "$hline" | sed -n 's/^pid=\([0-9]\{1,\}\).*/\1/p')
  if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then
    echo "REFUSING TO START: another harness already holds $vm." >&2
    echo "  holder: ${hline:-unknown} (pid $hpid is ALIVE)" >&2
    echo "  Two jobs on one guest interleave their probes and fabricate verdicts (see the header" >&2
    echo "  of this file). Wait for it, or kill it BY PID with SIGTERM - never with pkill -f," >&2
    echo "  which matches your own command line." >&2
    exit 2
  fi

  # DEAD-HOLDER TAKEOVER. The job that took this lock is gone; with the holder-process design
  # the lock frees itself within ~2s of the leader's death, so mostly this just waits that out.
  # Leftover holder/sentinel processes of the dead job are killed by their RECORDED pids first
  # (comm-checked so a recycled pid is never an innocent kill).
  echo "vmlock: STALE lock on $vm - recorded holder job (${hline:-no record}) is DEAD; taking over" >&2
  hproc=$(printf '%s\n' "$hline" | sed -n 's/.*holder=\([0-9]\{1,\}\).*/\1/p')
  hsent=$(printf '%s\n' "$hline" | sed -n 's/.*sentinel=\([0-9]\{1,\}\).*/\1/p')
  for i in ${hproc:-} ${hsent:-}; do
    if kill -0 "$i" 2>/dev/null; then
      comm=$(cat "/proc/$i/comm" 2>/dev/null)
      case "$comm" in
        flock|tail|sh) echo "vmlock: killing leftover lock process $i ($comm) of the dead job" >&2
                       kill -TERM "$i" 2>/dev/null ;;
        *) echo "vmlock: recorded lock process $i is now '$comm' (pid recycled) - not killing it" >&2 ;;
      esac
    fi
  done
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    if _vmlock_try "$vm" "$lf"; then
      echo "vmlock: stale lock on $vm freed after ${i}s - taken over" >&2
      _vmlock_won "$vm"; return 0
    fi
  done

  # Still held by SOMETHING with a dead leader after 15s: a pre-redesign orphan is sitting on an
  # inherited raw fd (the 2026-09-06 incident shape). Rotate the lock file: new lockers contend
  # on a fresh inode; the orphan keeps its flock on the unlinked one, where it locks nothing.
  echo "vmlock: lock on $vm still held 15s after its job died - ROTATING the lock file to break" >&2
  echo "  a pre-redesign orphan's inherited fd (find it: ls -l /proc/[0-9]*/fd 2>/dev/null | grep qwt-vmlock-$vm)" >&2
  rm -f -- "$lf"
  if _vmlock_try "$vm" "$lf"; then
    # Post-win re-verify: if a SECOND taker rotated concurrently, our locked inode may no longer
    # be the file at the path - then our lock guards nothing and we must not proceed.
    sleep 1
    if grep -aq "^pid=$$ holder=$QWT_VMLOCK_HOLDERPID " "$lf" 2>/dev/null; then
      echo "vmlock: ROTATED and re-acquired $vm (verified against the live lock file)" >&2
      _vmlock_won "$vm"; return 0
    fi
    echo "REFUSING TO START: concurrent takeover detected on $vm during lock rotation - two" >&2
    echo "  takers raced. Re-run ONE of them." >&2
    for i in "${QWT_VMLOCK_HOLDERPID:-}" "${QWT_VMLOCK_SENTINELPID:-}"; do
      [ -n "$i" ] && kill -TERM "$i" 2>/dev/null   # never `kill 0` - that TERMs the whole group
    done
    exit 2
  fi
  echo "REFUSING TO START: could not take the $vm lock even after rotation. Something is alive" >&2
  echo "  and locking the fresh file, or the lock dir is broken (check flock errors above)." >&2
  exit 2
}

# vm_unlock: immediate, explicit release - safe on ANY exit path and in any process.
# Only the process that ACQUIRED the lock releases it (ownership is unexported, so a child that
# inherited QWT_VMLOCK_HELD no-ops here). Killing the holder closes the only locked fd (-o), so
# release is instant; the sentinel is killed too so nothing lingers. Even if this is never
# called (SIGKILL), the sentinel's tail --pid frees the lock ~2s after the leader dies.
vm_unlock(){
  [ "${QWT_VMLOCK_OWNER_PID:-}" = "$$" ] || return 0
  local _p
  for _p in "${QWT_VMLOCK_HOLDERPID:-}" "${QWT_VMLOCK_SENTINELPID:-}"; do
    [ -n "$_p" ] && kill -TERM "$_p" 2>/dev/null   # never `kill 0` - that TERMs the whole group
  done
  echo "VMLOCK-RELEASED vm=${QWT_VMLOCK_HELD:-?} pid=$$" >&2
  unset QWT_VMLOCK_HELD QWT_VMLOCK_OWNER_PID QWT_VMLOCK_HOLDERPID QWT_VMLOCK_SENTINELPID
  return 0
}
