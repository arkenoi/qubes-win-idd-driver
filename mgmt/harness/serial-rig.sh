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
# AN UNREADABLE RIG IS NOT AN EMPTY RIG, and that was the hole: the admin.vm.List call was piped
# with 2>/dev/null and its exit status was never read, so a timeout, a policy denial or a truncated
# answer produced an empty list - which both asserts below read as "nothing else is up" and PASSED.
# A gate against two concurrent guests that fails OPEN when it cannot see the rig is worse than no
# gate, because it reports safety. Found by the descending audit, 2026-10-21.
# THE DISCRIMINATOR: admin.vm.List always returns at least dom0 and this qube, so RAW output with
# zero lines means the call failed. Lines present with none in a running state means the rig really
# is idle. Those two are now different answers.
# SERIAL-RIG-READ-A  (to the B marker: driven by tools/tests/serial-rig-selftest.sh; neither marker
# names the other)
_sr_rig_raw() { printf '' | timeout 20 qrexec-client-vm dom0 admin.vm.List 2>/dev/null | tr '\0' '\n'; }

# -> 0 and the list on stdout; 2 and nothing when the rig could not be read at all
_sr_running_guests() {
    local self="${1:-}" name state raw
    raw=$(_sr_rig_raw)
    if [ -z "${raw//[$' \t\n']/}" ]; then return 2; fi
    while read -r name state; do
        [ -n "$name" ] || continue
        [ "$name" = "$self" ] && continue
        # dom0 AND win-idd-mgmt BY NAME, BEFORE ANY TAG LOOKUP. dom0 is always Running, so it
        # reached the qvm-tags call below on EVERY assert - and there is no policy rule for
        # admin.vm.tag.List against dom0, so each one was DENIED and written to the owner's dom0
        # journal. That is the same leak he asked about on 2026-10-21, here in production code
        # rather than in a suite. These two are the only qubes on this rig that are not ours
        # (tools/hooks/admin-target-gate.sh states it, and it refuses the command outright), so
        # skipping them by name costs nothing and asks nothing.
        case "$name" in dom0|win-idd-mgmt) continue ;; esac
        # A TAG LOOKUP THAT FAILED IS NOT A GUEST THAT IS NOT OURS. `qvm-tags ... | grep -qx` fed
        # both outcomes into the same `|| continue`: a readable answer without the tag, and a
        # lookup that did not answer at all (timeout, transient qubesd error, truncated reply). The
        # second dropped a RUNNING guest out of the list these asserts are built from, so a
        # VM-mutating job could proceed while a real guest was up - the exact two-concurrent-guests
        # failure this file exists to prevent, scored 0.78 as a campaign-stopper by the tier
        # re-check, 2026-10-21.
        # Fail CLOSED, which is safe precisely because of the line above: every name that reaches
        # here is one of ours, so an unreadable tag means "a subject whose tag we could not read",
        # never "somebody else's qube". It is reported with its reason so the refusal is readable.
        # A TIMEOUT AND A POLICY DENIAL ARE DIFFERENT ANSWERS, and only one of them is missing data.
        # `timeout` reports 124 when it had to kill the call: nothing came back, so whether this
        # guest is a subject is UNKNOWN and the only safe reading is "it might be" - fail closed.
        # Any other non-zero is the admin client refusing: there is no policy rule for a qube that
        # is not tagged win-idd-testbed, so a refusal is itself the answer "not a test guest", and
        # treating it as unknown would block every job whenever any non-rig qube happens to be up.
        # THE BOUND: a refusal and some other client-side error share a status here. A tagged guest
        # is readable by policy, so a refusal on one is not a case this can produce - but a future
        # client that exits 1 for an unrelated reason would be read as "not ours". Jev scored the
        # blanket fail-closed version 0.63 on exactly that risk.
        local tags trc
        tags=$(timeout 20 qvm-tags "$name" list 2>/dev/null); trc=$?
        if [ "$trc" = 124 ]; then
            printf '%s(%s,tag-lookup-TIMED-OUT) ' "$name" "$state"
            continue
        fi
        [ "$trc" != 0 ] && continue      # refused: no policy rule, so not a testbed subject
        printf '%s\n' "$tags" | grep -qx 'win-idd-testbed' || continue
        printf '%s(%s) ' "$name" "$state"
    done < <(printf '%s\n' "$raw" \
             | awk '{ n=$1; s=""
                      for (i=2;i<=NF;i++) if ($i ~ /^state=/) s=substr($i,7)
                      if (s!="" && s!="Halted") print n, s }')
    return 0
}
# SERIAL-RIG-READ-B

# For a job that owns the WHOLE rig and is about to destroy and rebuild everything: no guest at all
# may be up, not even one. Separate from assert_sole_guest on purpose - that one REQUIRES the caller
# to name the guest it owns, and passing it an empty string to mean "none" trips its ${1:?} guard
# and kills the shell mid-preflight (measured 2026-10-13 on rebuild-rig.sh's first run). Expressing
# "none" needs its own name, not a special value.
assert_no_guest() {
    local others rc
    # NOT THROUGH A PIPE. `others=$(f | tr ...); rc=$?` reads TR's status, not f's, so the
    # unreadable-rig signal was discarded and this assert passed anyway - measured while writing
    # the fix, and the same class as the pipefail/grep -q rule this project already carries.
    others=$(_sr_running_guests ""); rc=$?
    others=$(printf '%s' "$others" | tr '\n' ' ')
    if [ "$rc" = 2 ]; then
        echo "REFUSING: the rig could not be read (admin.vm.List returned nothing) - this job owns" >&2
        echo "  the entire rig and cannot proceed without knowing what is up. Missing data is not" >&2
        echo "  an empty rig." >&2
        return 1
    fi
    [ -z "${others// /}" ] && return 0
    echo "REFUSING: a Windows guest is up - $others" >&2
    echo "  This job owns the entire rig and would destroy and rebuild every golden." >&2
    echo "  Shut it down first with qwt_shutdown from mgmt/harness/shutdown-lib.sh." >&2
    return 1
}

assert_sole_guest() {
    local vm="${1:?assert_sole_guest needs the vm this job owns}"
    local others
    # THE DEFECT KNOB IS GONE. It was `[ "${SERIAL_RIG_DEFECT:-}" = "1" ] && return 0`, described as
    # being for the self-test only - and a grep of the whole tree found it referenced NOWHERE but at
    # its own definition. So the only thing it did was offer an unconditional bypass of the one gate
    # that stops two concurrent guests: any job that inherited that variable, by export or by stray
    # shell state, passed this assert whatever was running. Scored 0.67 as a campaign-stopper by the
    # tier re-check, 2026-10-21.
    # A NEGATIVE CONTROL DOES NOT NEED A PRODUCTION KNOB. The suite proves this function is what
    # refuses by removing the assert from a COPY of the file - the same way the rig-shim, shutdown
    # and firstboot suites do it - which cannot be reached from a real job's environment at all.
    local rc
    others=$(_sr_running_guests "$vm"); rc=$?   # not through a pipe - see assert_no_guest
    others=$(printf '%s' "$others" | tr '\n' ' ')
    if [ "$rc" = 2 ]; then
        echo "REFUSING: the rig could not be read (admin.vm.List returned nothing), so whether" >&2
        echo "  another guest is up is UNKNOWN. This gate exists because two concurrent guests" >&2
        echo "  fabricate verdicts and reboot each other; it does not pass on no information." >&2
        return 1
    fi
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
