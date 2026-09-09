#!/bin/bash
# prime-rescue-lib.sh - the decision logic for prime-run's one-shot RESCUE reboot, factored out
# so it is (a) exercisable by a fail-proof without a live VM and (b) impossible to get subtly
# wrong inline again.
#
# WHY THIS EXISTS (root cause, 2026-09-09 win11-clean DEADLINE failure).
# A clean install drives a PRISTINE base through stage 1 (testsigning + reboot) and stage 2 (the
# MSI + IDD activation). The stage-1 reboot is a guest-initiated reboot whose Xen outcome is
# NONDETERMINISTIC on these HVMs: sometimes the domain HALTS (prime-run's restart-on-Halt then
# gives stage 2 a fresh domain start, the PV bus binds, qrexec answers), and sometimes it is an
# in-place WARM reset (the domain stays Running). A warm reset USUALLY still rebinds the PV bus
# and reaches qrexec (history: several `halts=0 qrexec=1` clean passes). But when it does NOT, the
# guest is left Running with stage 2's IDD activation having DISABLED the emulated VGA - so dom0
# sees no window at all - and the PV bus never rebound, so qrexec never comes. That stuck state
# is package-INDEPENDENT: the stage-1 reboot happens before any QWT/PV driver is installed, and
# the SAME package that hit this passed the identical cell minutes later.
#
# prime-run already has the cure for it: a one-shot RESCUE that qvm-shutdown's the guest so the
# restart-on-Halt path gives it the fresh domain start it needs. The BUG was that the rescue could
# not fire in exactly this state. Its gate required RESCUE_QUIET consecutive CPU-quiet reads, and
# the CPU reader printed the "very busy" sentinel 9999 whenever libxl stats were UNREADABLE. In
# the failure the guest's stats became unreadable at the very moment it stuck (t+414s), so every
# subsequent poll scored as "busy", reset the quiet streak to 0, and the rescue never fired - the
# run polled to the 3600s DEADLINE. "No stats data" was being conflated with "guest is busy".
#
# The fix, encoded here:
#   1. An UNREADABLE cpu reading ("NA") is NOT evidence of a busy guest. Past the RESCUE_AFTER
#      floor it counts TOWARD quiescence, exactly like a low reading, instead of resetting it.
#   2. A second, independent trigger: a persistently no-window screen (SHOTFAIL/NOWINDOW) is the
#      distinctive observable of this stuck state (every clean PASS in history has shotfail=0; the
#      one failure had it for the whole 54-minute stall). N consecutive no-window probes past the
#      floor also fire the rescue, with no dependence on cpu stats at all.
# Both are still gated by RESCUE_AFTER from the LAST start, so a normal install (which reaches
# qrexec or halts well inside that window) is never interrupted.

RESCUE_CPU_BUSY=${RESCUE_CPU_BUSY:-15}     # cpu_usage_raw >= this = the guest is doing real work
RESCUE_NOSHOW=${RESCUE_NOSHOW:-4}          # consecutive no-window screen probes (~60s each) = stuck

# rescue_quiet_step <quiet> <cpu>  ->  echoes the new quiet-streak count.
#   <cpu> is the max cpu_usage_raw observed this poll, or the literal "NA" when libxl stats were
#   unreadable. A low reading OR "NA" both increment the streak; only a clearly-busy reading
#   resets it. (The defect was: "NA" arrived as 9999 and reset the streak.)
rescue_quiet_step() {
    local q="$1" cpu="$2"
    if [ "$cpu" = NA ]; then echo $((q + 1)); return; fi
    if [ "$cpu" -lt "$RESCUE_CPU_BUSY" ] 2>/dev/null; then echo $((q + 1)); else echo 0; fi
}

# rescue_noshow_step <noshow> <screen_verdict>  ->  echoes the new no-window-streak count.
#   SHOTFAIL/NOWINDOW increment it; an empty verdict (not probed this poll) leaves it unchanged;
#   any real verdict (DESKTOP/BLACK/booting/...) resets it.
rescue_noshow_step() {
    local n="$1" v="$2"
    case "$v" in
        SHOTFAIL|NOWINDOW) echo $((n + 1)) ;;
        "")                echo "$n" ;;
        *)                 echo 0 ;;
    esac
}

# rescue_should_fire <rescued> <since_start> <after> <quiet> <quiet_need> <noshow> <noshow_need>
#   returns 0 (fire) when: not already rescued, at least <after> seconds since the last start,
#   and EITHER the cpu-quiescence streak OR the no-window streak has crossed its threshold.
rescue_should_fire() {
    local rescued="$1" since="$2" after="$3" q="$4" qn="$5" ns="$6" nsn="$7"
    [ "$rescued" = 0 ] || return 1
    [ "$since" -ge "$after" ] 2>/dev/null || return 1
    [ "$q"  -ge "$qn"  ] 2>/dev/null && return 0
    [ "$ns" -ge "$nsn" ] 2>/dev/null && return 0
    return 1
}

# rescue_trigger_label <quiet> <quiet_need> <noshow> <noshow_need>  ->  human-readable cause.
rescue_trigger_label() {
    local q="$1" qn="$2" ns="$3" nsn="$4" why=
    [ "$q"  -ge "$qn"  ] 2>/dev/null && why="cpu-quiescent x$q"
    [ "$ns" -ge "$nsn" ] 2>/dev/null && why="${why:+$why + }no-window x$ns"
    echo "${why:-unknown}"
}
