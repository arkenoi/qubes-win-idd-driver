#!/bin/bash
# golden-guard-selftest.sh - drive both golden safeguards, and require each to FIRE.
#
# A check that has never been seen to fail is not evidence. So every blocking case is run TWICE:
# once with the guard in place (must block) and once with the guard's defect knob set, which
# restores the behaviour that lost win10-base on 2026-10-11 (must NOT block). If a case blocks in
# both runs, something OTHER than the guard is refusing it and the test says so rather than
# counting a free pass.
#
#   PART A  tools/hooks/golden-boot-gate.sh   - starting a sealed golden        (knob: GOLDEN_BOOT_GATE_DEFECT=1)
#   PART B  mgmt/golden.sh seal               - re-sealing over a lost record   (knob: GOLDEN_RESEAL_DEFECT=1)
#
# Usage: tools/tests/golden-guard-selftest.sh      (read-only except for a backed-up seal file)
set -u
cd "$(dirname "$0")/../.." || exit 1
GATE=tools/hooks/golden-boot-gate.sh
pass=0; fail=0

hookjson() { python3 -c '
import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }

# $1 = expectation (BLOCK|ALLOW), $2 = label, $3 = command
case_is() {
    local want=$1 label=$2 cmd=$3 rc rc_defect
    printf '%s' "$(hookjson "$cmd")" | bash "$GATE" >/dev/null 2>&1; rc=$?
    if [ "$want" = BLOCK ]; then
        printf '%s' "$(hookjson "$cmd")" | GOLDEN_BOOT_GATE_DEFECT=1 bash "$GATE" >/dev/null 2>&1; rc_defect=$?
        if [ "$rc" -eq 2 ] && [ "$rc_defect" -eq 0 ]; then
            pass=$((pass+1)); printf '  PASS  %-46s blocked (and the knob proves the gate did it)\n' "$label"
        elif [ "$rc" -eq 2 ]; then
            fail=$((fail+1)); printf '  FAIL  %-46s blocked WITH the defect knob too - not this gate\n' "$label"
        else
            fail=$((fail+1)); printf '  FAIL  %-46s NOT blocked (rc=%s)\n' "$label" "$rc"
        fi
    else
        if [ "$rc" -eq 0 ]; then
            pass=$((pass+1)); printf '  PASS  %-46s allowed\n' "$label"
        else
            fail=$((fail+1)); printf '  FAIL  %-46s REFUSED a legitimate command (rc=%s)\n' "$label" "$rc"
        fi
    fi
}

echo "PART A - starting a sealed golden"
echo "  sealed goldens seen: $(ls mgmt/goldens/*.json 2>/dev/null | wc -l)"

# --- must BLOCK: these start or overwrite the golden itself
case_is BLOCK "qvm-start"                  'qvm-start win11-base'
case_is BLOCK "qvm-run (it auto-starts)"   'qvm-run win11-base "cmd /c ver"'
case_is BLOCK "qtest run via QTEST_VM"     'QTEST_VM=win11-base ./tools/qtest run whoami'
case_is BLOCK "qtest start positional"     './tools/qtest start win11de-base'
case_is BLOCK "reprovision overwrites"     'PRISTINE=1 mgmt/reprovision-usb.sh win10-base loop3 loop4'
case_is BLOCK "second line of a script"    'echo preparing
qvm-start win11r-base'
case_is BLOCK "inside an if"               'if true; then qvm-start win11-base; fi'
case_is BLOCK "after a pipeline"           'cat /dev/null | qvm-start win11-base'

# --- must ALLOW: reads, clones, prose, unsealed guests, and an explicit authorisation
case_is ALLOW "golden.sh verify"           'mgmt/golden.sh verify win11-base'
case_is ALLOW "golden.sh seal"             'mgmt/golden.sh seal win11-base "note"'
case_is ALLOW "quick-upgrade CLONES"       'mgmt/harness/quick-upgrade.sh win11de-qwt subj'
case_is ALLOW "prime-selftest CLONES"      'mgmt/prime-selftest.sh win11r-base'
case_is ALLOW "qvm-volume info"            'qvm-volume info win11-base:root'
case_is ALLOW "qvm-ls"                     'qvm-ls --raw-data --fields STATE win11-base'
case_is ALLOW "grep names a golden"        'grep -n win11-base mgmt/golden.sh'
case_is ALLOW "commit message is prose"    'git commit -m "qvm-start win11-base is now refused"'
case_is ALLOW "unsealed qube"              'qvm-start win11-acc'
case_is ALLOW "usage request"              'qvm-start --help win11-base'
case_is ALLOW "explicit authorisation"     'GOLDEN_UNSEAL=win10-base mgmt/reprovision-usb.sh win10-base loop3 loop4'
case_is ALLOW "authorisation is per-guest" 'GOLDEN_UNSEAL=win10-base mgmt/golden.sh verify win11-base'

# A heredoc body that TALKS about the forbidden command must not trip the gate.
case_is ALLOW "heredoc body is prose"      'cat > /tmp/x <<EOF
qvm-start win11-base
EOF'

echo
echo "PART B - re-sealing over a record you can no longer reach"
# win10-base is the genuine case: its committed seal records two revisions that have both aged out.
VICTIM=win10-base; SEAL=mgmt/goldens/$VICTIM.json
if [ ! -f "$SEAL" ]; then
    echo "  SKIP  no $SEAL - cannot drive the real case"
else
    BK=$(mktemp); cp "$SEAL" "$BK"
    restore() { cp "$BK" "$SEAL"; rm -f "$BK"; }
    trap restore EXIT
    before=$(sha256sum "$SEAL" | cut -c1-16)

    out=$(mgmt/golden.sh seal "$VICTIM" "selftest - must be refused" 2>&1); rc=$?
    after=$(sha256sum "$SEAL" | cut -c1-16)
    if [ "$rc" -eq 4 ] && [ "$before" = "$after" ]; then
        pass=$((pass+1)); printf '  PASS  %-46s refused (rc=4) and wrote nothing\n' "re-seal over a lost record"
    else
        fail=$((fail+1)); printf '  FAIL  %-46s rc=%s, seal changed=%s\n' "re-seal over a lost record" "$rc" \
            "$([ "$before" = "$after" ] && echo no || echo YES)"
        echo "$out" | sed 's/^/        /' | head -4
    fi

    # The knob must restore the old behaviour, or the refusal above proves nothing about this guard.
    cp "$BK" "$SEAL"
    out=$(GOLDEN_RESEAL_DEFECT=1 mgmt/golden.sh seal "$VICTIM" "selftest - defect knob" 2>&1); rc=$?
    after=$(sha256sum "$SEAL" | cut -c1-16)
    if [ "$rc" -eq 0 ] && [ "$before" != "$after" ]; then
        pass=$((pass+1)); printf '  PASS  %-46s knob re-seals freely - the guard is what refuses\n' "defect knob restores the loss"
    else
        fail=$((fail+1)); printf '  FAIL  %-46s rc=%s, seal changed=%s (knob did not restore it)\n' "defect knob restores the loss" "$rc" \
            "$([ "$before" = "$after" ] && echo no || echo YES)"
    fi

    # With a reason, the deliberate re-seal proceeds AND records why.
    cp "$BK" "$SEAL"
    out=$(GOLDEN_RESEAL_REASON="selftest deliberate abandon" mgmt/golden.sh seal "$VICTIM" "selftest" 2>&1); rc=$?
    got=$(python3 -c "import json;print(json.load(open('$SEAL')).get('reseal_reason',''))" 2>/dev/null)
    if [ "$rc" -eq 0 ] && [ "$got" = "selftest deliberate abandon" ]; then
        pass=$((pass+1)); printf '  PASS  %-46s proceeds and records the reason\n' "authorised re-seal"
    else
        fail=$((fail+1)); printf '  FAIL  %-46s rc=%s reseal_reason=%q\n' "authorised re-seal" "$rc" "$got"
    fi
    restore; trap - EXIT
    printf '  seal restored: %s\n' "$(sha256sum "$SEAL" | cut -c1-16)"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
