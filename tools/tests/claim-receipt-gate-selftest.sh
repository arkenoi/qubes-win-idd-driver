#!/bin/bash
# SELF-TEST for tools/hooks/claim-receipt-gate.sh - every case is staged with a fabricated
# transcript and a fabricated wire log; nothing real is read. A PASS here is a check that has
# been SEEN TO FAIL: T9 re-introduces the original state (CLAIM_GATE_DEFECT=1) and T1 must then
# stop being blocked.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
H=tools/hooks/claim-receipt-gate.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/claimgate.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
pass=0; failn=0

mk(){ # $1=assistant text  [$2=wire ts]  -> writes $T/tr.jsonl and $T/wire.jsonl
  python3 - "$1" "${2:-}" "$T" <<'PY'
import json, sys
txt, wts, d = sys.argv[1], sys.argv[2], sys.argv[3]
with open(d + '/tr.jsonl', 'w') as f:
    f.write(json.dumps({"type": "user", "timestamp": "2026-09-21T12:00:00.000Z",
                        "message": {"content": "what is going on with that guest?"}}) + "\n")
    f.write(json.dumps({"type": "assistant", "timestamp": "2026-09-21T12:05:00.000Z",
                        "message": {"content": [{"type": "text", "text": txt}]}}) + "\n")
with open(d + '/wire.jsonl', 'w') as f:
    if wts:
        f.write(json.dumps({"ts": wts, "caller": "jev.py", "request": {}, "response": {}}) + "\n")
PY
}
run(){ # $1=label $2=want-rc  [$3..=extra env]
  local rc
  rc=$(python3 -c 'import json,sys;print(json.dumps({"session_id":"s","transcript_path":sys.argv[1],"stop_hook_active":False}))' "$T/tr.jsonl" \
       | env JEV_WIRE_LOG="$T/wire.jsonl" "${@:3}" bash "$H" >/dev/null 2>&1; echo $?)
  if [ "$rc" = "$2" ]; then echo "PASS  $1 (rc=$rc)"; pass=$((pass+1));
  else echo "FAIL  $1 (rc=$rc, want $2)"; failn=$((failn+1)); fi
}

# T1: the sudo fabrication, verbatim in shape - the sixth instance cost an afternoon.
mk "prime-run had no loop device and creating one needs sudo, so a human must have set those up."
run "T1 fabricated capability limit, no receipt -> BLOCKED"            2
# T2: the same sentence with the probe actually run and quoted.
mk "Loop attach is root-free here: measured just now, \`udisksctl loop-setup -f\` printed /dev/loop37."
run "T2 same claim WITH a measurement -> allowed"                      0
# T3: a guest state named rather than measured.
mk "The subject is wedged - it has been Running for twelve minutes since the shutdown request."
run "T3 guest state named, no receipt -> BLOCKED"                      2
# T4: the same state, carrying Jev's numbers.
mk "Jev: same_as_known_stall 0.36, insufficient-evidence 0.58 - so it is not called a stall."
run "T4 state WITH a judgment quoted -> allowed"                       0
# T5: a Jev call made THIS TURN answers for the claims in it.
mk "The guest is stuck at the login prompt and nothing has moved." "2026-09-21T12:04:00+0300"
run "T5 claim with a Jev call taken this turn -> allowed"              0
# T6: tool OUTPUT that contains the vocabulary is data, not a diagnosis.
mk "State right now: \`win-idd-test|Transient\`, and the pool is at 744 GiB."
run "T6 the word inside backticks (qvm-ls output) -> allowed"          0
# T7: quoting the owner back must never be blocked.
mk "> you were expected to run one test guest at a time, no?

Right - and that is what the gate now enforces."
run "T7 a quoted line -> allowed"                                      0
# T8: ordinary prose with none of the vocabulary.
mk "Both selftests pass, 44/44, and the lint is at baseline. Committing now."
run "T8 ordinary report -> allowed"                                    0
# T9: DEFECT RE-INTRODUCED - T1 must stop being blocked, or T1 proves nothing.
mk "prime-run had no loop device and creating one needs sudo, so a human must have set those up."
run "T9 DEFECT RE-INTRODUCED: T1 must NOT be blocked"                  0 CLAIM_GATE_DEFECT=1
# T10: a blocker asserted at the platform level - what was handed to the owner yesterday.
mk "The acceptance campaign is blocked at the platform level, not by tonight's build."
run "T10 an invented blocker -> BLOCKED"                               2
# T11: the hook must never loop - once it has blocked, the next stop is let through.
mk "The guest is wedged."
rc=$(python3 -c 'import json,sys;print(json.dumps({"session_id":"s","transcript_path":sys.argv[1],"stop_hook_active":True}))' "$T/tr.jsonl" \
     | env JEV_WIRE_LOG="$T/wire.jsonl" bash "$H" >/dev/null 2>&1; echo $?)
if [ "$rc" = 0 ]; then echo "PASS  T11 stop_hook_active -> never blocks twice (rc=0)"; pass=$((pass+1));
else echo "FAIL  T11 stop_hook_active (rc=$rc, want 0)"; failn=$((failn+1)); fi
# T12: an unreadable transcript must SAY it did not run, and allow.
out=$(printf '{"transcript_path":"/nonexistent/x.jsonl"}' | bash "$H" 2>&1; echo "rc=$?")
case "$out" in *"DID NOT RUN"*rc=0) echo "PASS  T12 unreadable transcript: says so, allows"; pass=$((pass+1)) ;;
  *) echo "FAIL  T12 unreadable transcript: $out"; failn=$((failn+1)) ;; esac

echo "checks: $pass passed, $failn failed"
[ "$failn" = 0 ] && exit 0 || exit 1
