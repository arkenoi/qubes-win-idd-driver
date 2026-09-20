#!/bin/bash
# serial-rig-gate-selftest.sh - proves tools/hooks/serial-rig-gate.sh blocks a second mutating
# launch while a LIVE lock is held, allows passive monitoring and stale locks, and that with the
# defect re-introduced (SERIAL_GATE_DEFECT=1) the blocking case is NOT blocked - a PASS here is a
# check that has been seen to fail. Uses a private LOCKDIR so it never touches real rig locks.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
H=tools/hooks/serial-rig-gate.sh
LD=$(mktemp -d "${TMPDIR:-/tmp}/serialgate.XXXXXX") || exit 2
trap 'kill "$SLEEPER" 2>/dev/null; rm -rf "$LD"' EXIT

# A LIVE holder: a real sleeping process whose pid we write into a lock file.
sleep 300 & SLEEPER=$!
printf 'pid=%s holder=%s sentinel=%s started=x cmd=prime-run.sh vm=win11-acc\n' "$SLEEPER" "$SLEEPER" "$SLEEPER" > "$LD/qwt-vmlock-win11-acc"
# A STALE holder: a pid that is not alive (the sleeper's pid + a large offset, reaped).
DEAD=$(( SLEEPER + 100000 ))
printf 'pid=%s holder=%s sentinel=%s started=x cmd=dead.sh vm=win10-acc\n' "$DEAD" "$DEAD" "$DEAD" > "$LD/qwt-vmlock-win10-acc"

pass=0; failn=0
check(){ # $1=label $2=want-rc $3=json  [$4..=extra env KEY=VAL]
  local rc; rc=$(printf '%s' "$3" | env TMPDIR="$LD" "${@:4}" bash "$H" >/dev/null 2>&1; echo $?)
  if [ "$rc" = "$2" ]; then echo "PASS  $1 (rc=$rc)"; pass=$((pass+1)); else echo "FAIL  $1 (rc=$rc, want $2)"; failn=$((failn+1)); fi
}
jb(){ python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }
jw(){ python3 -c 'import json,sys;print(json.dumps({"tool_name":"Workflow","tool_input":{"script":sys.argv[1]}}))' "$1"; }

check "C1 mutating Bash while a LIVE lock is held -> BLOCKED"           2 "$(jb 'prime-run.sh win10-base')"
check "C2 mutating Workflow while a LIVE lock is held -> BLOCKED"       2 "$(jw 'agent(\"matrix.sh --cells x\")')"
check "C3 passive monitor (qvm-ls) while a LIVE lock is held -> allowed" 0 "$(jb 'qvm-ls --raw-data --fields NAME,STATE')"
check "C4 passive admin.vm.Stats while a LIVE lock is held -> allowed"  0 "$(jb 'qrexec-client-vm win11-acc admin.vm.Stats')"
check "C5 qtest state/shot (read) while a LIVE lock is held -> allowed" 0 "$(jb 'qtest state win11-acc; qtest shot out.tar')"
check "C6 this launch already holds the lock -> allowed"                0 "$(jb 'prime-run.sh win11-acc')" QWT_VMLOCK_HELD=win11-acc
check "C7 non-rig command -> allowed"                                   0 "$(jb 'git status && grep foo bar')"
check "C8 DEFECT RE-INTRODUCED: C1 must NOT be blocked (proves load-bearing)" 0 "$(jb 'prime-run.sh win10-base')" SERIAL_GATE_DEFECT=1

# C9: only a STALE lock present (dead holder) -> a mutating launch is allowed.
rm -f "$LD/qwt-vmlock-win11-acc"
check "C9 mutating launch with only a STALE lock present -> allowed"    0 "$(jb 'prime-run.sh win10-base')"

echo "checks: $pass passed, $failn failed"
[ "$failn" = 0 ] && exit 0 || exit 1
