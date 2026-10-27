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
declare -F toolstack_accept >/dev/null 2>&1 \
  || . "$(dirname "${BASH_SOURCE[0]}")/primitives.sh" 2>/dev/null || true   # toolstack_accept: the one recorded shutdown request
_qwt_boottime() {
    # NEVER PROBE A GUEST THAT IS NOT ALREADY RUNNING. A qrexec call to a halted or Transient qube
    # makes the toolstack START it, so this probe - added to a function whose entire job is to
    # STOP a guest - restarted win-idd-test while qwt_shutdown was trying to shut it down
    # (measured 2026-09-21, and the owner caught it, not me). A shutdown helper that can start a
    # guest is worse than no helper. Refuse unless the state read says Running.
    local _s; _s=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$1" '$1==v{print $2}')
    [ "$_s" = Running ] || return 0
    # Anchored to the repo root on purpose: a caller with a different cwd would find no qtest,
    # get an empty answer, and land in the UNKNOWN branch for a reason that has nothing to do
    # with the guest - a missing instrument reading as a guest state is the trap this file exists
    # to close.
    local root; root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
    # NOT wmic: it is REMOVED from Windows 11 24H2+ and this rig's reporter image is 25H2, where it
    # answers "konnte nicht gefunden werden". Measured 2026-09-21 - the first version of this
    # function used wmic, so it returned empty on every modern guest and the classification below
    # would have fallen into UNKNOWN every single time. A guard that can never succeed is
    # decoration, and this one was committed without being driven against a real guest.
    QTEST_VM="$1" timeout 60 "$root/tools/qtest" run \
        "powershell -NoProfile -Command (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')" 2>/dev/null \
        | tr -d '\r' | grep -aoE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+' | head -1
}
qwt_shutdown() {
    local vm="$1" deadline="${2:-1800}" end st b0 b1
    # A QUBE THAT DOES NOT EXIST IS NOT "NOT HALTED". The poll below reads STATE out of qvm-ls and
    # compares it to Halted; for an absent qube that read is EMPTY, which is never Halted, so every
    # caller that pre-cleaned a subject it had not created yet sat here for its whole deadline and
    # then returned 1 - "the request had no effect" - about a qube there was nothing to request of.
    # Measured 2026-10-07: appmenu-guest-ab.sh spent 240 s in its pre-clean and another 300 s in
    # its teardown doing exactly this, before it had cloned anything.
    # AN UNREADABLE RIG IS NOT AN ABSENT QUBE, and this check read them as the same thing: the
    # output was piped with 2>/dev/null and its status never read, so a denial, a timeout or a
    # truncated answer gave an empty list, the grep failed, and this returned 0 - "nothing to shut
    # down" - WITHOUT EVEN ASKING. Callers that rely on the exit code then take a clean shutdown as
    # done. Same shape as serial-rig.sh's rig read, found the same day by the component re-grade
    # (2026-10-21) one layer below the fix that went in that morning.
    # THE DISCRIMINATOR is the same one: the list always carries at least dom0 and this qube, so
    # RAW output with nothing in it means the call failed, while a readable list without $vm in it
    # means the qube really is absent.
    # SHUTDOWN-RIGREAD-A  (to the B marker: driven by tools/tests/shutdown-reask-selftest.sh;
    # neither marker names the other)
    local _rig
    _rig=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null)
    if [ -z "${_rig//[$' \t\n']/}" ]; then
        echo "qwt_shutdown: the rig could not be read (qvm-ls returned nothing), so whether $vm" >&2
        echo "  exists or is Halted is UNKNOWN. Missing data is not an absent qube and not a clean" >&2
        echo "  shutdown - refusing to report either." >&2
        return 4
    fi
    if ! printf '%s\n' "$_rig" | awk -F'|' '{print $1}' | grep -qxF "$vm"; then
        echo "qwt_shutdown: $vm does not exist - nothing to shut down" >&2
        return 0
    fi
    # SHUTDOWN-RIGREAD-B
    b0=$(_qwt_boottime "$vm")            # before the request; empty = no qrexec, a fact in itself
    # A bare qvm-shutdown is the REQUEST (ACPI). It returns immediately and kills nothing.
    toolstack_accept "$vm" >/dev/null 2>&1
    end=$(( $(date +%s) + deadline ))
    # ASK AGAIN. A single ACPI request that is lost, or that lands while the guest is still busy
    # with first-boot work, used to mean the poll ran to its whole deadline and reported failure on
    # a guest that would have stopped at once. MEASURED TWICE on win11de-qwt 2026-10-15, both right
    # after a deliberate GOLDEN_UNSEAL boot that wrote to the registry: the request went at 14:39:06
    # and the guest was still Running at 14:54:15 - 909 s - and a SECOND ask was answered in seconds.
    # It cost two golden seals that day.
    # A re-ask is the same idempotent ACPI request, not an escalation: nothing here ever kills a
    # guest, because a kill contaminates a subject (findings: never reuse a killed subject). The
    # interval is a constant, deliberately not a knob - a knob on a shared predicate drives every
    # consumer whether they meant it or not.
    local reask=120 nextask asks=1 _unreadable=0 _readable=0
    nextask=$(( $(date +%s) + reask ))
    while [ "$(date +%s)" -lt "$end" ]; do
        # SAME DISCRIMINATOR MID-POLL. Reading the state straight out of the pipe made an
        # unreadable rig indistinguishable from a vanished qube, and the branch below then reported
        # "it is gone, not unresponsive" and returned 0 on no information at all.
        _rig=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null)
        if [ -z "${_rig//[$' \t\n']/}" ]; then
            echo "qwt_shutdown: the rig could not be read mid-wait - that is not 'gone'; still waiting" >&2
            _unreadable=$(( _unreadable + 1 ))
            sleep 10
            continue
        fi
        _readable=1
        st=$(printf '%s\n' "$_rig" | awk -F'|' -v v="$vm" '$1==v{print $2}')
        [ "$st" = Halted ] && return 0
        if [ "$(date +%s)" -ge "$nextask" ]; then
            asks=$(( asks + 1 ))
            echo "qwt_shutdown: $vm still $st after $(( reask * (asks - 1) ))s - asking again (ask #$asks)" >&2
            toolstack_accept "$vm" >/dev/null 2>&1
            nextask=$(( $(date +%s) + reask ))
        fi
        # and if it has gone from the list entirely while we waited, it is down, not unresponsive -
        # the same mistake as above, just arriving mid-poll.
        if [ -z "$st" ]; then
            echo "qwt_shutdown: $vm is no longer listed - it is gone, not unresponsive" >&2
            return 0
        fi
        sleep 10
    done
    # NEVER ONCE READABLE: the whole wait happened without a single usable answer from the rig, so
    # nothing below - which reasons about boot times to tell "ignoring" from "wedged" - is about
    # this guest. Its own code, so no caller can mistake it for a measured outcome.
    if [ "$_readable" = 0 ]; then
        echo "qwt_shutdown: the rig was NOT READABLE once in ${deadline}s ($_unreadable attempts)." >&2
        echo "  Nothing was measured about $vm. This is not 'ignoring the request' and not a" >&2
        echo "  clean shutdown - fix the rig read before classifying the guest." >&2
        return 4
    fi
    b1=$(_qwt_boottime "$vm")   # same guard: returns empty unless it is still Running
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
