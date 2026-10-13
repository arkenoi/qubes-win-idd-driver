#!/bin/bash
# serial-rig.sh - ONE Windows guest at a time, enforced IN THE HARNESS.
#
# Source this and call `assert_sole_guest <vm>` before starting or creating a guest.
#
# WHY THIS EXISTS AND WHY THE HOOK WAS NOT ENOUGH (measured 2026-10-13).
# tools/hooks/serial-rig-gate.sh is a PreToolUse hook: it inspects the TEXT of the command the model
# is about to run and refuses it when another guest is up. That works only while the harness name
# appears in the command. On 2026-10-13 a vendor-media install was launched as
# `nohup bash /tmp/.../win11r.sh`, whose text contains no harness name at all - so the hook saw
# nothing, and win11r-base was created and booted while win10-dptest was still Running from a run
# that had ended five minutes earlier. Two guests, 8 GiB each, concurrently. The same wrapper
# defeats tools/hooks/golden-boot-gate.sh for the same reason.
#
# A gate that can be stepped around by putting the command in a file is a reminder, not a gate. This
# one asks the RIG what is actually running, so it holds no matter how the harness was invoked - by
# a model, by a script, by hand, or from cron.
#
# WHY SERIAL AT ALL: concurrent jobs interleave their probes and fabricate verdicts, and they reboot
# guests underneath each other (CLAUDE.md, "Run VM-mutating jobs serially"; .claude/skills/rig-cycle).
# On 2026-09-21 two guests came up twice and a whole campaign's results were discarded.
#
# NO OVERRIDE, deliberately. If a second guest genuinely must be up, shut the other one down first -
# that is a decision someone makes explicitly, not a flag a script sets for itself.

# WHAT COUNTS AS A TEST GUEST: the TAG, never the name. Name patterns like ^win(10|11) are a guess -
# they miss a guest called dptest or churn, and they catch win-idd-mgmt, which is this dev qube. The
# rig's own policy model is tag-based (dom0/12-install-policy-tagged.sh): a qube is drivable from
# here exactly when it is tagged win-idd-testbed. So that tag is the honest definition of "a test
# guest", and it is the same one the policy uses to decide what we may touch at all.
#
# One admin.vm.List call for the states, then a tag lookup only on the ones that are actually up -
# normally none or one. qvm-ls is deliberately avoided: it fires a property fetch at EVERY qube,
# including this one, which is its own standing prohibition (owner 2026-10-09).
_sr_running_guests() {
    local self="${1:-}" name state
    while read -r name state; do
        [ -n "$name" ] || continue
        [ "$name" = "$self" ] && continue
        [ "$name" = "win-idd-mgmt" ] && continue
        qvm-tags "$name" list 2>/dev/null | grep -qx 'win-idd-testbed' || continue
        printf '%s(%s) ' "$name" "$state"
    done < <(printf '' | timeout 20 qrexec-client-vm dom0 admin.vm.List 2>/dev/null | tr '\0' '\n' \
             | awk '{ n=$1; s=""
                      for (i=2;i<=NF;i++) if ($i ~ /^state=/) s=substr($i,7)
                      if (s!="" && s!="Halted") print n, s }')
}

# For a job that owns the WHOLE rig and is about to destroy and rebuild everything: no guest at all
# may be up, not even one. Separate from assert_sole_guest on purpose - that one REQUIRES the caller
# to name the guest it owns, and passing it an empty string to mean "none" trips its ${1:?} guard
# and kills the shell mid-preflight (measured 2026-10-13 on rebuild-rig.sh's first run). Expressing
# "none" needs its own name, not a special value.
assert_no_guest() {
    local others
    others=$(_sr_running_guests "" | tr '\n' ' ')
    [ -z "${others// /}" ] && return 0
    echo "REFUSING: a Windows guest is up - $others" >&2
    echo "  This job owns the entire rig and would destroy and rebuild every golden." >&2
    echo "  Shut it down first with qwt_shutdown from mgmt/harness/shutdown-lib.sh." >&2
    return 1
}

assert_sole_guest() {
    local vm="${1:?assert_sole_guest needs the vm this job owns}"
    local others
    # Defect knob for tools/tests/serial-rig-selftest.sh ONLY: restores the pre-2026-10-13 state in
    # which nothing in the script checked, so the self-test can prove this function is what refuses.
    [ "${SERIAL_RIG_DEFECT:-}" = "1" ] && return 0   # GUARD:serial-rig
    others=$(_sr_running_guests "$vm" | tr '\n' ' ')
    others="${others%% }"
    [ -z "${others// /}" ] && return 0
    cat >&2 <<EOM
REFUSING: another Windows guest is up - $others
  This job owns '$vm'. One rig-mutating job at a time; concurrent guests interleave their probes,
  fabricate verdicts, and reboot each other (CLAUDE.md "Run VM-mutating jobs serially").
  Shut the other guest down first - qwt_shutdown from mgmt/harness/shutdown-lib.sh, which bounds the
  wait and says what it did; a bare --wait kills on expiry and reports it as a clean stop (L9).
  There is no override flag on purpose - stopping the other guest is a decision, not a default.
EOM
    return 1
}
