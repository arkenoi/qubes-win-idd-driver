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
#   1  still not Halted at the deadline - the CALLER decides what that means. Nothing is killed
#      here, ever; a guest that will not stop is a finding, not a thing to shoot.
qwt_shutdown() {
    local vm="$1" deadline="${2:-1800}" end st
    # A bare qvm-shutdown is the REQUEST (ACPI). It returns immediately and kills nothing.
    timeout 120 qvm-shutdown "$vm" >/dev/null 2>&1
    end=$(( $(date +%s) + deadline ))
    while [ "$(date +%s)" -lt "$end" ]; do
        st=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$vm" '$1==v{print $2}')
        [ "$st" = Halted ] && return 0
        sleep 10
    done
    return 1
}
