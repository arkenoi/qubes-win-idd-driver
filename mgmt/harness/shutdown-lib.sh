# shutdown-lib.sh - source this. ONE way to power a guest down, and it never kills.
#
# WHY THIS FILE EXISTS. `qvm-shutdown --wait` is not a wait, it is a KILL ON A TIMER. From
# qubesadmin/tools/qvm_shutdown.py (4.3.33, read 2026-09-20):
#
#     parser.add_argument('--timeout', action='store', type=float, default=60,
#         help='timeout after which domains are killed when using --wait')
#     ...  vm.kill()
#
# So a bare `qvm-shutdown --wait $VM` hard-kills the guest 60 seconds in, and wrapping it in
# `timeout 300 qvm-shutdown --wait` does NOT buy 300 seconds - the kill happens at 60, inside the
# wrapper, silently and with rc=0. A Windows guest that is installing updates ("Do not turn off
# your computer") routinely needs far longer than that.
#
# What a kill costs here is not one guest: CLAUDE.md forbids reusing a killed subject, and these
# call sites go on to SEAL GOLDENS and to grade cold boots. A golden sealed from a hard-killed
# guest carries that contamination into every clone made from it afterwards.
#
# qwt_shutdown <vm> [deadline_s]   ask politely, then POLL. Returns:
#   0  the guest reached Halted on its own
#   1  still up at the deadline, and it is THE SAME SESSION - the request genuinely had no effect
#   2  still up at the deadline, but THE GUEST REBOOTED while we waited - it is not ignoring
#      anything, it went down and came back (and is now waiting for something)
#   3  still up at the deadline and we COULD NOT TELL - reported as unknown, never as either
#
# WHY 1, 2 AND 3 ARE DIFFERENT RETURN CODES, and why this is not a comment asking anyone to be
# careful. Returning a bare "still not Halted" hands the caller a fact whose MEANING is a guess,
# and that guess has been got wrong on this project almost daily for two months, in both
# directions: "it is ignoring ACPI" (fabricated - nothing measured says a QWT-less Windows
# ignores the power button) and "it is a wedged specimen" (also wrong). The real answer on
# 2026-09-21 was that the guest had RESTARTED WITHOUT QWT and was waiting for an answer stick
# that was not attached, so every poll read Running because it kept coming back.
#
# `Running` at two reads cannot distinguish those. THE GUEST'S OWN BOOT TIME CAN, and it is one
# qrexec call. So this samples it BEFORE the request and again at the deadline: if it moved, the
# guest rebooted - that is a measurement, not an opinion. Where it cannot be sampled (no QWT, no
# qrexec) the answer is UNKNOWN and the classification is delegated to Jev via
# tools/guest-state-judge.py, because naming a case is a classifier and classifiers belong to Jev
# (owner, 2026-09-21: "when you need to GUESS, ask fucking Jev").
_qwt_boottime() {
    # Anchored to the repo root on purpose: a caller with a different cwd would find no qtest,
    # get an empty answer, and land in the UNKNOWN branch for a reason that has nothing to do
    # with the guest - a missing instrument reading as a guest state is the trap this file exists
    # to close.
    local root; root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
    QTEST_VM="$1" timeout 60 "$root/tools/qtest" run 'cmd /c wmic os get lastbootuptime /value' 2>/dev/null \
        | tr -d '\r' | sed -n 's/^LastBootUpTime=//p' | head -1
}
qwt_shutdown() {
    local vm="$1" deadline="${2:-1800}" end st b0 b1
    b0=$(_qwt_boottime "$vm")            # before the request; empty = no qrexec, a fact in itself
    # A bare qvm-shutdown is the REQUEST (ACPI). It returns immediately and kills nothing.
    timeout 120 qvm-shutdown "$vm" >/dev/null 2>&1
    end=$(( $(date +%s) + deadline ))
    while [ "$(date +%s)" -lt "$end" ]; do
        st=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$vm" '$1==v{print $2}')
        [ "$st" = Halted ] && return 0
        sleep 10
    done
    b1=$(_qwt_boottime "$vm")
    if [ -n "$b0" ] && [ -n "$b1" ] && [ "$b0" != "$b1" ]; then
        echo "qwt_shutdown: $vm REBOOTED while we waited (boot time $b0 -> $b1). It is NOT ignoring" >&2
        echo "  the request - it went down and came back, and is now waiting for something. Find out" >&2
        echo "  WHAT this boot expects (a medium? a stage?) before calling anything a defect." >&2
        return 2
    fi
    if [ -n "$b0" ] && [ "$b0" = "$b1" ]; then
        echo "qwt_shutdown: $vm is still up at the deadline and it is THE SAME SESSION" >&2
        echo "  (boot time unchanged at $b0), so the request had no effect on it." >&2
        return 1
    fi
    echo "qwt_shutdown: $vm is still up at the deadline and the guest's boot time is NOT READABLE" >&2
    echo "  (qrexec did not answer - normal on a guest with no QWT, and it says nothing about" >&2
    echo "  health). This is UNKNOWN, not 'ignoring'. Delegating the classification:" >&2
    if [ -x tools/guest-state-judge.py ]; then
        timeout 600 python3 tools/guest-state-judge.py "$vm" \
            --request "qvm-shutdown, then polled to a ${deadline}s deadline" >&2 \
            || echo "  (guest-state-judge did not run - the state stays UNKNOWN, do not name it)" >&2
    else
        echo "  tools/guest-state-judge.py is missing - the state stays UNKNOWN, do not name it." >&2
    fi
    return 3
}
