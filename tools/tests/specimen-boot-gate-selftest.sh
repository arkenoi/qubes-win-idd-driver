#!/bin/bash
# specimen-boot-gate-selftest.sh - a spent specimen cannot be started by hand, and the block says
# where its logs actually are.
#
# WHY THIS EXISTS. 2026-10-14: a campaign cell failed, deliberately left win10-acc as it stands as
# the only interrogable form of the failure, and minutes later I ran `qvm-start win10-acc` by hand
# to read its logs. The owner, watching: "starting WHAT THE FUCK to read the logs, we agreed to
# move the logs off to stick". The logs never needed the guest - logvol_pull reads the secondary log
# volume as an image file in THIS qube - and the start could not have worked anyway, because the ISO
# cell had left a `--required` claim on a loop device that was later released.
#
# Every blocking case runs TWICE: once with the gate in place (must block) and once with
# GOLDEN_BOOT_GATE_DEFECT=1, which restores the state where nothing enforced (must NOT block). A
# case that blocks in both runs is being refused by something else, and this says so instead of
# counting a free pass.
set -u
cd "$(dirname "$0")/../.." || exit 1
GATE=tools/hooks/golden-boot-gate.sh
pass=0; fail=0

T=$(mktemp -d "${TMPDIR:-/tmp}/specimen-gate.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

# A marker built HERE, through the library that the harness uses - not a hand-written file, so the
# field names the gate reads are the ones specimen_mark actually writes.
export SPECIMEN_DIR="$T/specimens"
# shellcheck disable=SC1091
source mgmt/harness/specimen-lib.sh
specimen_mark win10-acc "clean cell left it as it stands (selftest)" "matrix.log:72" >/dev/null \
  || { echo "FATAL: specimen_mark failed"; exit 2; }

# The hook's stdin comes from a FILE, never a pipe. sourcing specimen-lib.sh sets `pipefail` in
# this shell, and the gate with its defect knob set exits WITHOUT READING stdin - so `printf | gate`
# hands printf a SIGPIPE and the pipeline reports 141 instead of the gate's 0. That read as "blocked
# with the knob too" on every case here, i.e. the test accused the gate of a fault that was the
# test's own. Same trap as the 2026-10-14 `reader | grep -q` graded a live guest dead.
hookjson(){ python3 -c '
import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" > "$T/hook.json"; }

# $1 = BLOCK|ALLOW, $2 = label, $3 = command
case_is(){
    local want=$1 label=$2 cmd=$3 rc rc_defect
    hookjson "$cmd"
    bash "$GATE" <"$T/hook.json" >"$T/err" 2>&1; rc=$?
    if [ "$want" = BLOCK ]; then
        GOLDEN_BOOT_GATE_DEFECT=1 bash "$GATE" <"$T/hook.json" >/dev/null 2>&1; rc_defect=$?
        if [ "$rc" -eq 2 ] && [ "$rc_defect" -eq 0 ]; then
            pass=$((pass+1)); printf '  PASS  %-52s blocked (knob proves the gate did it)\n' "$label"
        elif [ "$rc" -eq 2 ]; then
            fail=$((fail+1)); printf '  FAIL  %-52s blocked WITH the defect knob too - not this gate\n' "$label"
        else
            fail=$((fail+1)); printf '  FAIL  %-52s NOT blocked (rc=%s)\n' "$label" "$rc"
        fi
    else
        if [ "$rc" -eq 0 ]; then
            pass=$((pass+1)); printf '  PASS  %-52s allowed\n' "$label"
        else
            fail=$((fail+1)); printf '  FAIL  %-52s blocked, and it must not be (rc=%s)\n' "$label" "$rc"
        fi
    fi
}

ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  PASS  $1"; else fail=$((fail+1)); echo "  FAIL  $1: expected '$2', got '$3'"; fi; }

echo "PART A  the start verbs"
case_is BLOCK "qvm-start of a marked specimen"            'qvm-start win10-acc'
case_is BLOCK "qvm-run auto-starts it"                    'qvm-run -p win10-acc whoami'
case_is BLOCK "a start buried after a harmless command"   'echo hi; qvm-start win10-acc >/dev/null 2>&1 && echo started'
case_is BLOCK "qtest run via QTEST_VM"                    'QTEST_VM=win10-acc ./tools/qtest run whoami'
case_is BLOCK "qtest pushrun naming it positionally"      './tools/qtest pushrun win10-acc script.ps1'

echo "PART B  what must still pass"
case_is ALLOW "reading its state"                         'qvm-ls --raw-data --fields NAME,STATE win10-acc'
case_is ALLOW "pulling its logs off the stick"            '. mgmt/harness/logvol-lib.sh; logvol_pull ~/win-iso/logvol/logs-win10-acc.img out/'
case_is ALLOW "collect-failure on it"                     'mgmt/harness/collect-failure.sh win10-acc out/'
case_is ALLOW "an UNMARKED subject"                       'qvm-start win11-acc'
case_is ALLOW "prose that merely quotes the command"      'git commit -m "specimen: refuse qvm-start win10-acc by hand"'
case_is ALLOW "authorised deliberately, on the segment"   'SPECIMEN_BOOT=win10-acc qvm-start win10-acc'
case_is ALLOW "asking the verb for its usage"             'qvm-start --help win10-acc'

echo "PART C  the block has to be USEFUL"
hookjson 'qvm-start win10-acc'; bash "$GATE" <"$T/hook.json" >"$T/msg" 2>&1
ck "names logvol_pull as the route"      "1" "$(grep -c 'logvol_pull' "$T/msg")"
ck "names collect-failure.sh"            "1" "$(grep -c 'collect-failure.sh' "$T/msg")"
ck "quotes the recorded reason"          "1" "$(grep -c 'left it as it stands' "$T/msg")"
ck "names the override"                  "1" "$(grep -c 'SPECIMEN_BOOT=win10-acc' "$T/msg")"
ck "warns about the stale loop claim"    "1" "$(grep -c 'required. claim on a loop device' "$T/msg")"

echo "PART D  the marker's own lifecycle"
ck "the reason round-trips"              "clean cell left it as it stands (selftest)" "$(specimen_why win10-acc)"
specimen_clear win10-acc >/dev/null
hookjson 'qvm-start win10-acc'
ck "a cleared specimen is startable"     "0" "$(bash "$GATE" <"$T/hook.json" >/dev/null 2>&1; echo $?)"
ck "clearing twice is not an error"      "0" "$(specimen_clear win10-acc >/dev/null 2>&1; echo $?)"
ck "an unmarked guest has no reason"     "1" "$(specimen_why win10-acc >/dev/null 2>&1; echo $?)"

# The harness must actually CALL the mark, or this gate protects nothing real - the failure mode
# logvol-lib.sh carries in its own header: "the library landed and NO harness called it".
# The mark belongs at the LEFT-AS-IT-STANDS decision itself, which lives in the shared wait
# primitive, so every harness that reaches it marks - not only matrix.sh.
# EVERY path that leaves a guest standing must record WHY - asserted as a property, not as a count
# and not as a spelling. Two things broke the previous form of this leg, which read
#   grep -c 'specimen_mark "$vm"'   expecting exactly 1:
# the direct call became the _wm_mark wrapper (it sources specimen-lib.sh if the caller did not, and
# reports a mark that FAILED rather than swallowing it under `|| true` - the hole that lost the first
# reliably captured wedge on 2026-10-20), and a SECOND preserve path landed, the dark-screen TERMINAL
# arm, which is the one that actually fires. Both are correct; the leg was red on correct code.
# Comment lines are excluded because this very block quotes the old spelling in prose.
_pres=$(awk '/LEFT AS IT STANDS/,/return 1/' mgmt/harness/e2e-wait.sh | command grep -vE '^[[:space:]]*#')
_pres_blocks=$(printf '%s\n' "$_pres" | command grep -c 'LEFT AS IT STANDS')
_pres_marks=$(printf '%s\n' "$_pres" | command grep -cE '(_wm_mark|specimen_mark) "\$vm"')
ck "every LEFT-AS-IT-STANDS path records evidence" "yes" \
   "$([ "$_pres_blocks" -gt 0 ] && [ "$_pres_blocks" = "$_pres_marks" ] \
      && echo yes || echo "no: $_pres_blocks preserve path(s), $_pres_marks mark call(s)")"
ck "matrix.sh clears when it recreates"  "2" "$(grep -c 'specimen_clear "\$' mgmt/harness/matrix.sh)"
ck "and it sources the library"          "1" "$(grep -c '^source mgmt/harness/specimen-lib.sh' mgmt/harness/matrix.sh)"

echo "specimen-boot-gate-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
