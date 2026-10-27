#!/bin/bash
# assert_sole_guest REFUSES a second guest, and IT is what refuses - dom0 is never asked.
# run: tools/tests/serial-rig-selftest.sh
# pass: exit 0
set -u
cd "$(dirname "$0")/../.." || exit 1
pass=0; fail=0
STUB=$(mktemp -d); trap 'rm -rf "$STUB"' EXIT

# $1 = the admin.vm.List body the stub returns, $2 = space-separated names that carry the testbed tag
mkstubs() {
    cat > "$STUB/qrexec-client-vm" <<EOF
#!/bin/bash
printf '%s' '$1'
EOF
    cat > "$STUB/qvm-tags" <<EOF
#!/bin/bash
for t in $2; do [ "\$1" = "\$t" ] && { echo win-idd-testbed; exit 0; }; done
exit 0
EOF
    chmod +x "$STUB/qrexec-client-vm" "$STUB/qvm-tags"
}

# $1 expectation REFUSE|ALLOW, $2 label, $3 self vm, $4 list body, $5 tagged names
case_is() {
    local want=$1 label=$2 self=$3 rc rcd
    mkstubs "$4" "$5"
    PATH="$STUB:$PATH" bash -c '. mgmt/harness/serial-rig.sh; assert_sole_guest "$1"' _ "$self" >/dev/null 2>&1; rc=$?
    if [ "$want" = REFUSE ]; then
        # THE CONTROL IS A COPY, NOT A PRODUCTION KNOB. This used to set SERIAL_RIG_DEFECT=1, which
        # existed in assert_sole_guest purely to serve this leg - an unconditional
        # `[ "$SERIAL_RIG_DEFECT" = 1 ] && return 0` that ANY job inheriting the variable would hit,
        # bypassing the one gate against two concurrent guests (0.67 campaign-stopper, tier
        # re-check 2026-10-21). The knob is deleted; the control now strips the two asserts' bodies
        # from a COPY of the shipped file, which no real environment can reach.
        # Asserted, not assumed: the copy must still define the function and must no longer carry
        # the refusal, or this leg would prove nothing.
        sed 's/^\( *\)others=$(_sr_running_guests "$vm"); rc=$?/\1others=""; rc=0/' \
            mgmt/harness/serial-rig.sh > "$STUB/serial-rig-noassert.sh"
        if grep -qa 'others=""; rc=0' "$STUB/serial-rig-noassert.sh" \
           && grep -qa '^assert_sole_guest()' "$STUB/serial-rig-noassert.sh"; then :
        else
            fail=$((fail+1)); printf '  FAIL  %-44s the control copy was not built - leg proves nothing\n' "$label"; return
        fi
        PATH="$STUB:$PATH" bash -c '. "$2"; assert_sole_guest "$1"' _ "$self" "$STUB/serial-rig-noassert.sh" >/dev/null 2>&1; rcd=$?
        if [ "$rc" -ne 0 ] && [ "$rcd" -eq 0 ]; then
            pass=$((pass+1)); printf '  PASS  %-44s refused (the copy without the check allows it)\n' "$label"
        elif [ "$rc" -ne 0 ]; then
            fail=$((fail+1)); printf '  FAIL  %-44s refused WITH the check removed too - something else refused\n' "$label"
        else
            fail=$((fail+1)); printf '  FAIL  %-44s NOT refused\n' "$label"
        fi
    else
        if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf '  PASS  %-44s allowed\n' "$label"
        else fail=$((fail+1)); printf '  FAIL  %-44s refused a legitimate case\n' "$label"; fi
    fi
}

# EXTRA STUBS for the two behaviours added on 2026-10-21. $1 = list body, $2 = tagged names,
# $3 = names whose TAG LOOKUP FAILS (rc 1, no output - a timeout or a transient qubesd error).
# Every qvm-tags invocation is recorded, so a leg can assert a name was never asked about at all.
mkstubs_tagfail() {   # $1 list $2 tagged $3 refused(rc1) $4 timed-out(rc124)
    mkstubs "$1" "$2"
    cat > "$STUB/qvm-tags" <<EOF
#!/bin/bash
echo "\$1" >> "$STUB/tagcalls"
for t in $3; do [ "\$1" = "\$t" ] && exit 1; done
for t in ${4:-}; do [ "\$1" = "\$t" ] && exit 124; done
for t in $2; do [ "\$1" = "\$t" ] && { echo win-idd-testbed; exit 0; }; done
exit 0
EOF
    chmod +x "$STUB/qvm-tags"
    : > "$STUB/tagcalls"
}

R='win10-base class=StandaloneVM state=Running uuid=x
win11r-base class=StandaloneVM state=Halted uuid=y'
H='win10-base class=StandaloneVM state=Halted uuid=x
win11r-base class=StandaloneVM state=Halted uuid=y'
SELF='win11r-base class=StandaloneVM state=Running uuid=y'
MGMT='win-idd-mgmt class=AppVM state=Running uuid=z'
UNTAGGED='some-linux-vm class=AppVM state=Running uuid=w'

echo "serial-rig: one guest at a time"
case_is REFUSE "another tagged guest is Running"       win11r-base "$R"        "win10-base win11r-base"
case_is ALLOW  "nothing running"                       win11r-base "$H"        "win10-base win11r-base"
case_is ALLOW  "only the guest this job owns"          win11r-base "$SELF"     "win10-base win11r-base"
case_is ALLOW  "this dev qube is not a test guest"     win11r-base "$MGMT"     "win-idd-mgmt"
case_is ALLOW  "an UNTAGGED running vm is not ours"    win11r-base "$UNTAGGED" "win10-base win11r-base"
case_is REFUSE "a guest whose NAME does not start win" win11r-base \
        'dptest-churn class=StandaloneVM state=Running uuid=q' 'dptest-churn'

# ---- AN UNREADABLE RIG IS NOT AN EMPTY RIG -----------------------------------------------------
# The admin.vm.List call was piped with 2>/dev/null and its status never read, so a timeout, a
# policy denial or a truncated answer produced an empty list - which both asserts read as "nothing
# else is up" and PASSED. A gate against two concurrent guests that fails OPEN when it cannot see
# the rig is worse than no gate, because it reports safety. The discriminator: admin.vm.List always
# returns at least dom0 and this qube, so zero RAW lines means the call failed.
mkstubs "" ""          # the rig answers with nothing at all
PATH="$STUB:$PATH" bash -c '. mgmt/harness/serial-rig.sh; assert_sole_guest win11-acc' >/dev/null 2>&1
rc=$?
PATH="$STUB:$PATH" bash -c '. mgmt/harness/serial-rig.sh; assert_no_guest' >/dev/null 2>&1
rcn=$?
if [ "$rc" -ne 0 ] && [ "$rcn" -ne 0 ]; then
  pass=$((pass+1)); printf '  PASS  %-44s both asserts REFUSE (missing data is not an idle rig)
' "an unreadable rig"
else
  fail=$((fail+1)); printf '  FAIL  %-44s sole=%s no_guest=%s - a gate that passes on no information
' "an unreadable rig" "$rc" "$rcn"
fi
# and the refusal must SAY it could not read, not claim the rig is busy
out=$(PATH="$STUB:$PATH" bash -c '. mgmt/harness/serial-rig.sh; assert_sole_guest win11-acc' 2>&1 >/dev/null)
case "$out" in
  *"could not be read"*) pass=$((pass+1)); printf '  PASS  %-44s the message names the real reason
' "its message" ;;
  *) fail=$((fail+1)); printf '  FAIL  %-44s said: %s
' "its message" "$(printf '%s' "$out" | head -1)" ;;
esac
# THE POSITIVE CONTROL: a rig that answers with NOTHING RUNNING must still be allowed, or this
# predicate would refuse every job on an idle rig.
mkstubs "dom0 state=Running
win-idd-mgmt state=Running
win11-acc state=Halted" "win11-acc"
PATH="$STUB:$PATH" bash -c '. mgmt/harness/serial-rig.sh; assert_sole_guest win11-acc' >/dev/null 2>&1
rc=$?
PATH="$STUB:$PATH" bash -c '. mgmt/harness/serial-rig.sh; assert_no_guest' >/dev/null 2>&1
rcn=$?
if [ "$rc" -eq 0 ] && [ "$rcn" -eq 0 ]; then
  pass=$((pass+1)); printf '  PASS  %-44s allowed (an idle rig that ANSWERED is not refused)
' "an idle rig"
else
  fail=$((fail+1)); printf '  FAIL  %-44s sole=%s no_guest=%s - the predicate refuses an idle rig
' "an idle rig" "$rc" "$rcn"
fi
# SEEN TO FAIL: the pre-fix read, which had no raw-emptiness test at all
pre=$(mktemp); sed '/SERIAL-RIG-READ-A/,/SERIAL-RIG-READ-B/d' mgmt/harness/serial-rig.sh > "$pre"
cat >> "$pre" <<'PREFIX'
_sr_running_guests() {
    local self="${1:-}" name state
    while read -r name state; do
        [ -n "$name" ] || continue
        [ "$name" = "$self" ] && continue
        [ "$name" = "win-idd-mgmt" ] && continue
        qvm-tags "$name" list 2>/dev/null | grep -qx 'win-idd-testbed' || continue
        printf '%s(%s) ' "$name" "$state"
    done < <(printf '' | timeout 20 qrexec-client-vm dom0 admin.vm.List 2>/dev/null | tr '\0' '\n'              | awk '{ n=$1; s=""
                      for (i=2;i<=NF;i++) if ($i ~ /^state=/) s=substr($i,7)
                      if (s!="" && s!="Halted") print n, s }')
}
PREFIX
mkstubs "" ""
PATH="$STUB:$PATH" bash -c '. "$1"; assert_sole_guest win11-acc' _ "$pre" >/dev/null 2>&1
rc=$?
rm -f "$pre"
if [ "$rc" -eq 0 ]; then
  pass=$((pass+1)); printf '  PASS  %-44s SEEN TO FAIL: the pre-fix read ALLOWS an unreadable rig
' "the old read"
else
  fail=$((fail+1)); printf '  FAIL  %-44s the pre-fix read refused too (rc=%s) - not driven
' "the old read" "$rc"
fi

# ---- AN UNREADABLE TAG IS NOT "NOT OURS" (0.78 campaign-stopper, tier re-check 2026-10-21) ------
# `qvm-tags ... | grep -qx` sent two different outcomes into the same `|| continue`: a readable
# answer without the tag, and a lookup that never answered. The second dropped a RUNNING guest out
# of the list both asserts are built from, so a VM-mutating job proceeded while a guest was up.
LIST='win10-base class=StandaloneVM state=Running uuid=x
win-idd-mgmt class=AppVM state=Running uuid=y
dom0 class=AdminVM state=Running uuid=z'
mkstubs_tagfail "$LIST" "" "" "win10-base"
PATH="$STUB:$PATH" bash -c '. mgmt/harness/serial-rig.sh; assert_sole_guest win11-acc' >"$STUB/o" 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then
  pass=$((pass+1)); printf '  PASS  %-44s refused - a lookup that TIMED OUT is not a guest we may ignore\n' "a tag lookup that FAILED"
else
  fail=$((fail+1)); printf '  FAIL  %-44s allowed (rc=0) - the guest was dropped from the list\n' "a tag lookup that FAILED"
fi
if grep -qa 'tag-lookup-TIMED-OUT' "$STUB/o"; then
  pass=$((pass+1)); printf '  PASS  %-44s and it says WHY, naming the guest and the rc\n' "its message"
else
  fail=$((fail+1)); printf '  FAIL  %-44s the refusal does not name the timed-out tag: %s\n' "its message" "$(tr '\n' ' ' < "$STUB/o" | cut -c1-90)"
fi

# A REFUSED lookup is the OTHER answer: no policy rule means not a testbed subject, and treating
# that as unknown would block every job whenever any non-rig qube is up (Jev 0.63 on the blanket
# fail-closed version). This leg is what keeps the refinement honest in both directions.
mkstubs_tagfail "$LIST" "" "win10-base" ""
PATH="$STUB:$PATH" bash -c '. mgmt/harness/serial-rig.sh; assert_sole_guest win11-acc' >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then
  pass=$((pass+1)); printf '  PASS  %-44s allowed - a refusal IS the answer "not a test guest"\n' "a tag lookup REFUSED by policy"
else
  fail=$((fail+1)); printf '  FAIL  %-44s refused (rc=%s) - any non-rig qube being up would block every job\n' "a tag lookup REFUSED by policy" "$rc"
fi

# ---- AND dom0 IS NEVER ASKED AT ALL ------------------------------------------------------------
# dom0 is always Running, so it reached the tag lookup on EVERY assert, and there is no policy rule
# for admin.vm.tag.List against dom0: each call was DENIED and written to the owner's dom0 journal.
# Same leak he asked about on 2026-10-21, here in production code.
mkstubs_tagfail "$LIST" "win10-base" ""
PATH="$STUB:$PATH" bash -c '. mgmt/harness/serial-rig.sh; assert_sole_guest win11-acc' >/dev/null 2>&1 || true
if grep -qax 'dom0' "$STUB/tagcalls"; then
  fail=$((fail+1)); printf '  FAIL  %-44s dom0 WAS asked - that call is denied and logged in his journal\n' "no tag lookup at dom0"
else
  pass=$((pass+1)); printf '  PASS  %-44s dom0 is skipped by name, before any lookup\n' "no tag lookup at dom0"
fi
if grep -qax 'win-idd-mgmt' "$STUB/tagcalls"; then
  fail=$((fail+1)); printf '  FAIL  %-44s this dev qube was asked too\n' "no tag lookup at win-idd-mgmt"
else
  pass=$((pass+1)); printf '  PASS  %-44s and neither is this dev qube\n' "no tag lookup at win-idd-mgmt"
fi
# AND THE TAGGED GUEST IS STILL ASKED ABOUT, or the two legs above would pass on a loop that asks
# about nothing at all.
if grep -qax 'win10-base' "$STUB/tagcalls"; then
  pass=$((pass+1)); printf '  PASS  %-44s the real guest IS still asked about\n' "the loop still works"
else
  fail=$((fail+1)); printf '  FAIL  %-44s nothing was asked - the skips are vacuous\n' "the loop still works"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
