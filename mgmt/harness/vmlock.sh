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
# RE-ENTRANT within one job, because harnesses legitimately call each other -
# failproof-faultinject.sh runs rnd8-resolution.sh three times, and a naive lock would make the
# child refuse its own parent. QWT_VMLOCK_HELD is exported once acquired, so descendants pass
# straight through while any UNRELATED process is still refused.
#
# The lock is advisory and per-VM: it serialises work on one guest, and deliberately does not stop
# two harnesses running against two different guests, which is safe and useful.

vm_lock(){
  local vm="${1:?vm_lock <vm>}"
  # already held by an ancestor of this job - the whole point is to serialise JOBS, not calls
  if [ "${QWT_VMLOCK_HELD:-}" = "$vm" ]; then return 0; fi
  local lf="${TMPDIR:-/tmp}/qwt-vmlock-$vm"
  exec {QWT_VMLOCK_FD}>>"$lf" || { echo "FATAL: cannot open lock $lf" >&2; exit 2; }
  if ! flock -n "$QWT_VMLOCK_FD"; then
    echo "REFUSING TO START: another harness already holds $vm." >&2
    echo "  holder: $(cat "$lf" 2>/dev/null)" >&2
    echo "  Two jobs on one guest interleave their probes and fabricate verdicts (see the header" >&2
    echo "  of this file). Wait for it, or kill it BY PID - never with pkill -f, which matches" >&2
    echo "  your own command line." >&2
    exit 2
  fi
  : > "$lf"
  printf 'pid=%s cmd=%s started=%s\n' "$$" "${0##*/}" "$(date -u +%FT%TZ)" >> "$lf"
  export QWT_VMLOCK_HELD="$vm"
}
