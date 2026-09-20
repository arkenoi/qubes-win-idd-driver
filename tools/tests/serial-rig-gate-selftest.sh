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
# C7b/C7c: PROSE is not a launch. Measured 2026-09-20 - the gate blocked a real `git commit`
# because its MESSAGE described harness work, so it read its own subject line as an invocation.
check "C7b git commit whose MESSAGE names a rig verb -> allowed"        0 "$(jb "git commit -m 'quick-upgrade: stop refusing the German golden, prime-run untouched'")"
check "C7c heredoc BODY naming a rig verb -> allowed"                   0 "$(jb "$(printf 'cat <<EOF\nwe ran matrix.sh and prime-run.sh yesterday\nEOF\n')")"
# C7e: a message that QUOTES a command inside itself. The naive "[^"]* arm ends at the first
# inner quote and leaves the rest of the message exposed - this blocked its own fix commit.
check "C7e message containing an ESCAPED-quoted verb -> allowed"        0 "$(jb 'git commit -m "gate: bash -c \"qvm-kill x\" must still be caught, and prime-run too"')"
# C7f: watching the running job is what the refusal text TELLS you to do; it must not be blocked.
check "C7f ps|grep for the running harness -> allowed"                  0 "$(jb "ps -eo pid,args --no-headers | grep -E 'quick-upgrade\\.sh' | grep -v grep")"
check "C7g tail of a harness log -> allowed"                            0 "$(jb 'tail -5 scratchpad/prime-run.log')"
# ...and the counterparts that must still be CAUGHT, or the strip went too far.
check "C7d a real command inside quotes -> BLOCKED"                     2 "$(jb 'bash -c "qvm-kill win11-acc"')"
check "C7h a real launch AFTER a passive segment -> BLOCKED"            2 "$(jb 'grep foo bar | cat; qvm-start win11-acc')"
# C7i-C7k: three more over-match shapes, all measured 2026-09-20 while a real run held a lock.
# The segment splitter was QUOTE-BLIND: a `\|` inside a grep PATTERN split the line, so the tail of
# the pattern became a fresh "segment" in command position and the passive `grep` in front of it
# stopped counting. And a verb invoked to print its own USAGE is not a launch.
check "C7i grep whose SINGLE-QUOTED pattern contains \\| -> allowed"     0 "$(jb "grep -n 'add_argument\\|ArgumentParser' \"\$(command -v qvm-shutdown)\" | head -20")"
check "C7j qvm-shutdown --help (usage, not a launch) -> allowed"        0 "$(jb 'qvm-shutdown --help')"
check "C7k command -v lookup of a rig verb -> allowed"                  0 "$(jb 'head -5 "$(command -v qvm-shutdown)"')"
# ...and their counterparts, or the strip went too far.
check "C7l --help INSIDE a quoted guest argument -> BLOCKED"            2 "$(jb "qvm-run win11-acc 'installer.exe --help'")"
check "C7m a launch in a COMMAND SUBSTITUTION -> BLOCKED"               2 "$(jb 'echo $(qvm-kill win11-acc)')"
check "C7n help flag on a NON-qvm command word -> BLOCKED"              2 "$(jb 'bash -c "qvm-kill win11-acc" --help')"
# C7m2: the substitution that the QUOTE-AWARE splitter cannot see - inside double quotes it is one
# token, so only lifting $(...) bodies out of the line catches it. This is the check that makes
# pull_subs load-bearing; the unquoted C7m is already caught by the splitter alone.
check "C7m2 a launch in a DOUBLE-QUOTED substitution -> BLOCKED"       2 "$(jb 'echo "$(qvm-kill win11-acc)"')"
# C7o/C7p: a `for` LIST is data. Measured 2026-09-20 - the gate refused a read-only loop over
# harness FILENAMES because one of them is called reprovision-usb.sh. `for` is a keyword, not a
# command word, so the passive-inspector rule never applied to it.
check "C7o for-loop over rig-named FILES -> allowed"                   0 "$(jb 'for f in mgmt/reprovision-usb.sh mgmt/harness/matrix.sh; do grep -n wait "$f"; done')"
check "C7p a launch behind an if/time keyword -> BLOCKED"              2 "$(jb 'if qvm-kill win11-acc; then echo dead; fi')"
# C7q/C7r: a NEWLINE ends a command. shlex throws newlines away as whitespace, so without an
# explicit boundary line 2 inherits line 1's command word - measured 2026-09-20 on a two-line
# edit script whose second line was a read-only `for` loop over harness filenames.
check "C7q second LINE is a for-list over rig-named files -> allowed"  0 "$(jb "$(printf 'python3 - </dev/null\nfor f in mgmt/reprovision-usb.sh; do bash -n "$f"; done')"
)"
check "C7r second LINE is a real launch -> BLOCKED"                    2 "$(jb "$(printf 'python3 - </dev/null\nqvm-start win11-acc')")"
# C7s/C7t: `bash -n <file>` is a syntax check - it parses and exits. Measured 2026-09-20: refused
# because the file being checked is named tools/release-acceptance.sh.
check "C7s bash -n on a rig-named script -> allowed"                   0 "$(jb 'bash -n tools/release-acceptance.sh')"
check "C7t bash -c (the EXECUTING form) with -n too -> BLOCKED"        2 "$(jb 'bash -n -c "qvm-kill win11-acc"')"
# C7u/C7v: arguments to git are PATHS. Measured 2026-09-20 - staging the fix for this whole
# class was refused because one of the staged files is called mgmt/harness/matrix.sh.
check "C7u git add of rig-named FILES -> allowed"                      0 "$(jb 'git add mgmt/harness/matrix.sh tools/release-acceptance.sh')"
check "C7v git bisect run (which DOES run a command) -> BLOCKED"       2 "$(jb 'git bisect run mgmt/harness/prime-run.sh')"
# C7w: mgmt/harness/shutdown-lib.sh wraps the power-off in a FUNCTION, so the verb list stopped
# seeing it - a blind spot created by the very fix that removed the kills.
check "C7w qwt_shutdown (the wrapper) -> BLOCKED"                      2 "$(jb 'qwt_shutdown win11-acc 600')"
check "C8 DEFECT RE-INTRODUCED: C1 must NOT be blocked (proves load-bearing)" 0 "$(jb 'prime-run.sh win10-base')" SERIAL_GATE_DEFECT=1
# C8b: knob 2 re-introduces the OVER-strip (help flag matched anywhere, substitutions not read).
# Each counterpart must then stop being blocked - that is what makes C7l/C7m evidence.
check "C8b OVER-STRIP: C7l must NOT be blocked"                        0 "$(jb "qvm-run win11-acc 'installer.exe --help'")" SERIAL_GATE_DEFECT=2
check "C8c OVER-STRIP: C7m2 must NOT be blocked"                       0 "$(jb 'echo "$(qvm-kill win11-acc)"')" SERIAL_GATE_DEFECT=2

# C9: only a STALE lock present (dead holder) -> a mutating launch is allowed.
rm -f "$LD/qwt-vmlock-win11-acc"
check "C9 mutating launch with only a STALE lock present -> allowed"    0 "$(jb 'prime-run.sh win10-base')"

echo "checks: $pass passed, $failn failed"
[ "$failn" = 0 ] && exit 0 || exit 1
