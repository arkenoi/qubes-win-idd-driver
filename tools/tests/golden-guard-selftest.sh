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

# Rewrite a seal so every volume it records names a revision that cannot be reached - the exact
# state the re-seal guard exists for, built rather than borrowed.
doctor_seal() { python3 - "$1" <<'EOPY'
import json, sys
d = json.load(open(sys.argv[1]))
for v in d.get("volumes", {}).values():
    v["revisions"] = ["selftest-revision-that-cannot-exist"]
json.dump(d, open(sys.argv[1], "w"), indent=1)
EOPY
}

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

# THE NAMES COME FROM THE SEAL DIRECTORY, NEVER FROM THIS FILE. Until 2026-10-14 every blocking
# case here named win11-base and win11de-base by hand. Both lost their seals when the rig was
# re-sealed that day, the gate correctly ignored two unsealed names, and SIX of the eight blocking
# cases silently stopped testing anything - the test still reported them as its own failures rather
# than as a stale fixture. A test that names rig state is a test that expires; derive it.
mapfile -t SEALED < <(ls mgmt/goldens/*.json 2>/dev/null | xargs -r -n1 basename | sed 's/\.json$//')
if [ "${#SEALED[@]}" -lt 2 ]; then
    echo "  FATAL: fewer than two sealed goldens exist - this gate cannot be exercised"; exit 2
fi
G=${SEALED[0]}; G2=${SEALED[1]}
echo "  exercising with: $G and $G2"
# And the names must BE sealed, or an ALLOW case could pass for the wrong reason.
for n in "$G" "$G2"; do
    [ -f "mgmt/goldens/$n.json" ] || { echo "  FATAL: $n is not sealed"; exit 2; }
done
# An unsealed, unmarked name for the negative case, likewise not hardcoded to a guest that may
# since have been sealed or marked as a specimen.
UNSEALED=__selftest_no_such_qube__

# --- must BLOCK: these start or overwrite the golden itself
case_is BLOCK "qvm-start"                  "qvm-start $G"
case_is BLOCK "qvm-run (it auto-starts)"   "qvm-run $G \"cmd /c ver\""
case_is BLOCK "qtest run via QTEST_VM"     "QTEST_VM=$G ./tools/qtest run whoami"
case_is BLOCK "qtest start positional"     "./tools/qtest start $G2"
case_is BLOCK "reprovision overwrites"     "PRISTINE=1 mgmt/reprovision-usb.sh $G loop3 loop4"
case_is BLOCK "second line of a script"    "echo preparing
qvm-start $G2"
case_is BLOCK "inside an if"               "if true; then qvm-start $G; fi"
case_is BLOCK "after a pipeline"           "cat /dev/null | qvm-start $G"

# --- must ALLOW: reads, clones, prose, unsealed guests, and an explicit authorisation
case_is ALLOW "golden.sh verify"           "mgmt/golden.sh verify $G"
case_is ALLOW "golden.sh seal"             "mgmt/golden.sh seal $G \"note\""
case_is ALLOW "quick-upgrade CLONES"       "mgmt/harness/quick-upgrade.sh $G2 subj"
case_is ALLOW "prime-selftest CLONES"      "mgmt/prime-selftest.sh $G"
case_is ALLOW "qvm-volume info"            "qvm-volume info $G:root"
case_is ALLOW "qvm-ls"                     "qvm-ls --raw-data --fields STATE $G"
case_is ALLOW "grep names a golden"        "grep -n $G mgmt/golden.sh"
case_is ALLOW "commit message is prose"    "git commit -m \"qvm-start $G is now refused\""
case_is ALLOW "unsealed qube"              "qvm-start $UNSEALED"
case_is ALLOW "usage request"              "qvm-start --help $G"
case_is ALLOW "explicit authorisation"     "GOLDEN_UNSEAL=$G mgmt/reprovision-usb.sh $G loop3 loop4"
# Per-guest scoping, tested where it can actually fail: authorising one golden must not start
# ANOTHER. As an ALLOW case on `golden.sh verify` (a read, which no authorisation is needed for)
# this asserted nothing.
case_is BLOCK "authorisation is per-guest" "GOLDEN_UNSEAL=$G qvm-start $G2"

# A heredoc body that TALKS about the forbidden command must not trip the gate.
case_is ALLOW "heredoc body is prose"      "cat > /tmp/x <<EOF
qvm-start $G
EOF"

echo
echo "PART B - re-sealing over a record you can no longer reach"
# THE LOST STATE IS CONSTRUCTED HERE, NOT BORROWED FROM THE RIG. This case used to rely on
# win10-base's committed seal happening to name two revisions that had aged out. That is a moving
# target: win10-base was rebuilt on 2026-10-14, its seal named reachable revisions again, the guard
# correctly allowed the re-seal - and the check reported FAIL while nothing was wrong. A check whose
# premise is "some real file is currently in the broken state" inverts silently the moment the rig
# is repaired, which is the opposite of what a regression test is for. So the seal is doctored to
# name a revision that cannot exist, and the guard is asked about THAT.
VICTIM=win10-base; SEAL=mgmt/goldens/$VICTIM.json
VSTATE=$(qvm-ls --raw-data --fields STATE "$VICTIM" 2>/dev/null | tail -1)
if [ ! -f "$SEAL" ]; then
    echo "  SKIP  no $SEAL - cannot drive the real case"
elif [ "$VSTATE" != Halted ]; then
    echo "  SKIP  $VICTIM is ${VSTATE:-absent}, not Halted - seal refuses before reaching this guard"
else
    BK=$(mktemp); cp "$SEAL" "$BK"
    restore() { cp "$BK" "$SEAL"; rm -f "$BK"; }
    trap restore EXIT
    doctor_seal "$SEAL"
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

    # A re-seal over a lost record IS permitted as a deliberate, recorded act - that is the guard's
    # whole premise, and a gate that refused a legitimate rebuild would just get worked around.
    cp "$BK" "$SEAL"; doctor_seal "$SEAL"
    out=$(GOLDEN_RESEAL_REASON="selftest - a deliberate rebuild" mgmt/golden.sh seal "$VICTIM" "selftest - reason given" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        pass=$((pass+1)); printf '  PASS  %-46s allowed when a reason is RECORDED\n' "re-seal over a lost record"
    else
        fail=$((fail+1)); printf '  FAIL  %-46s REFUSED even with GOLDEN_RESEAL_REASON (rc=%s)\n' "re-seal over a lost record" "$rc"
        echo "$out" | sed 's/^/        /' | head -4
    fi

    # The knob must restore the old behaviour, or the refusal above proves nothing about this guard.
    cp "$BK" "$SEAL"; doctor_seal "$SEAL"
    before=$(sha256sum "$SEAL" | cut -c1-16)
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
