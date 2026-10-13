#!/bin/bash
# serial-rig-selftest.sh - prove assert_sole_guest refuses a second guest, and that IT is what refuses.
#
# Offline: the rig is never touched. `qrexec-client-vm` and `qvm-tags` are stubbed on PATH so the
# guest list is whatever the case says it is. Every refusing case runs TWICE - once guarded, once
# with SERIAL_RIG_DEFECT=1, which restores the pre-2026-10-13 behaviour where nothing checked. A case
# that refuses in BOTH runs is reported as a free pass, not counted: a check never seen to fail is
# not evidence.
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
        PATH="$STUB:$PATH" SERIAL_RIG_DEFECT=1 bash -c '. mgmt/harness/serial-rig.sh; assert_sole_guest "$1"' _ "$self" >/dev/null 2>&1; rcd=$?
        if [ "$rc" -ne 0 ] && [ "$rcd" -eq 0 ]; then
            pass=$((pass+1)); printf '  PASS  %-44s refused (knob proves this function did it)\n' "$label"
        elif [ "$rc" -ne 0 ]; then
            fail=$((fail+1)); printf '  FAIL  %-44s refused WITH the knob too - something else refused\n' "$label"
        else
            fail=$((fail+1)); printf '  FAIL  %-44s NOT refused\n' "$label"
        fi
    else
        if [ "$rc" -eq 0 ]; then pass=$((pass+1)); printf '  PASS  %-44s allowed\n' "$label"
        else fail=$((fail+1)); printf '  FAIL  %-44s refused a legitimate case\n' "$label"; fi
    fi
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

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
