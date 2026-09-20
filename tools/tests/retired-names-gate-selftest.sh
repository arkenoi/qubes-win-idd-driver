#!/bin/bash
# retired-names-gate-selftest.sh - proves tools/hooks/retired-names-gate.sh blocks what it must,
# allows what it must, and that with the defect re-introduced (RETIRED_GATE_DEFECT=1) the blocking
# case is NOT blocked - so a PASS here is a check that has been seen to fail.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
H=tools/hooks/retired-names-gate.sh
pass=0; failn=0
check(){ # $1=label $2=want-rc $3=json  [$4=env]
  local rc; rc=$(printf '%s' "$3" | env ${4:-X=1} bash "$H" >/dev/null 2>&1; echo $?)
  if [ "$rc" = "$2" ]; then echo "PASS  $1 (rc=$rc)"; pass=$((pass+1)); else echo "FAIL  $1 (rc=$rc, want $2)"; failn=$((failn+1)); fi
}
j(){ python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"file_path":sys.argv[2],"new_string":sys.argv[3]}}))' "$@"; }
check "C1 finding re-derives the bucket lock -> BLOCKED"            2 "$(j Edit findings/issues.md 'the xenbus bucket-lock spin is the cause of the stall')"
check "C2 memory ships a patched xenbus -> BLOCKED"                   2 "$(j Write /home/u/.claude/projects/x/memory/a.md 'stage pv-drivers/xenbus and pnputil it')"
check "C3 same text, says RETIRED -> allowed"                        0 "$(j Edit findings/issues.md 'xenbus bucket-lock: RETIRED 8376f69, not the cause')"
check "C4 same text, REOPENED-BY-OWNER -> allowed"                    0 "$(j Edit CLAUDE.md 'REOPENED-BY-OWNER 2026-10-01: revisit the bucket-lock patch')"
check "C5 xenbus_monitor prompt suppressor (stays per f7c16ce) -> allowed" 0 "$(j Edit findings/install.md 'the xenbus_monitor prompt suppressor ran 28 s')"
check "C6 retired name in source code, not the record -> allowed"    0 "$(j Edit guest/relay.cs 'bucket-lock comment in code')"
check "C7 Win10 phantom KB in a finding -> BLOCKED"                   2 "$(j Edit findings/updates.md 'KB5071959 is missing, chase it')"
check "C8 non-record path -> allowed"                                 0 "$(j Write README.md 'ship the xenbus patch')"
check "C9 DEFECT RE-INTRODUCED: C1 must NOT be blocked (proves the gate is load-bearing)" 0 "$(j Edit findings/issues.md 'the xenbus bucket-lock spin is the cause')" RETIRED_GATE_DEFECT=1
echo "checks: $pass passed, $failn failed"
[ "$failn" = 0 ] && exit 0 || exit 1
