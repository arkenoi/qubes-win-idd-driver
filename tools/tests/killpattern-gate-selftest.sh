#!/bin/bash
# killpattern-gate-selftest.sh - a process is never signalled because it MATCHED something.
#
# THE INCIDENT THIS IS BUILT FROM, 2026-10-15. Stopping an acceptance campaign I ran, in one command:
#   for p in /proc/[0-9]*; do ... case "$c" in *release-accept*|*harness/matri*) echo "$pid|..." ;;
#   esac; done | while IFS='|' read -r pid c; do kill -TERM "$pid"; done
# The two campaign pids died as intended AND SO DID TWO OF MY OWN TOOL SHELLS, because a tool
# shell's /proc/<pid>/cmdline contains the whole command being run - pattern included - so the
# matcher matched itself. Third occurrence in this project; the owner's rule on the first two was
# capitalised: "PKILL IS HARD PROHIBITED FOREVER". Minutes earlier, on the same task, I had done it
# correctly: print the candidates, read them, signal two literal pids.
#
# Every blocking case runs TWICE: once with the gate in place (must block) and once with
# KILL_BY_PATTERN_GATE_DEFECT=1, which restores the state where nothing enforced (must NOT block).
# A case that blocks in both runs is being refused by something else, and this says so.
set -u
cd "$(dirname "$0")/../.." || exit 1
GATE=tools/hooks/kill-by-pattern-gate.sh
pass=0; fail=0
T=$(mktemp -d "${TMPDIR:-/tmp}/killpattern.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

hookjson(){ python3 -c '
import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" > "$T/hook.json"; }

case_is(){ # <BLOCK|ALLOW> <label> <command>
    local want=$1 label=$2 cmd=$3 rc rc_defect
    hookjson "$cmd"
    bash "$GATE" <"$T/hook.json" >"$T/err" 2>&1; rc=$?
    if [ "$want" = BLOCK ]; then
        KILL_BY_PATTERN_GATE_DEFECT=1 bash "$GATE" <"$T/hook.json" >/dev/null 2>&1; rc_defect=$?
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

echo "PART A  the exact command that killed my shells, and its relatives"
# VERBATIM from the incident (shortened only where it does not change the shape).
case_is BLOCK "the 2026-10-15 /proc scan piped into kill" \
  'for p in /proc/[0-9]*; do pid=${p#/proc/}; c=$(tr "\0" " " < "$p/cmdline"); case "$c" in *release-accept*|*harness/matri*) echo "$pid|$c";; esac; done | while IFS="|" read -r pid c; do kill -TERM "$pid"; done'
case_is BLOCK "pkill -f, prohibited outright"                'pkill -f matrix.sh'
case_is BLOCK "kill fed by pgrep"                            'kill $(pgrep -f release-acceptance)'
case_is BLOCK "pgrep piped into xargs kill"                  'pgrep -f qrexec | xargs kill -TERM'
case_is BLOCK "ps | grep | awk | xargs kill"                 'ps aux | grep matrix | awk "{print \$2}" | xargs kill -9'
case_is BLOCK "killall by name"                              'killall gui-agent.exe'
case_is BLOCK "pidof feeding a kill"                         'kill -9 $(pidof relay)'
case_is BLOCK "a /proc/*/ scan with kill in the loop body"   'for p in /proc/*/cmdline; do grep -q matrix "$p" && kill -TERM "$(dirname "$p" | xargs basename)"; done'
case_is BLOCK "Stop-Process by name"                         'pwsh -c "Get-Process qrexec | Stop-Process"'

echo "PART B  what must still work"
case_is ALLOW "literal pids, the shape that worked"          'kill -TERM 1524132 1524590'
case_is ALLOW "a pid the process wrote down"                 'kill -TERM "$(cat /home/user/tmp/run.pid)"'
case_is ALLOW "a liveness PROBE signals nothing"             'kill -0 "$pid" 2>/dev/null && echo alive'
case_is ALLOW "reading /proc without signalling"             'for p in /proc/[0-9]*; do c=$(tr "\0" " " < "$p/cmdline"); case "$c" in *matri*) echo "${p#/proc/} $c";; esac; done'
case_is ALLOW "pgrep that only COUNTS"                       'pgrep -cf qrexec'
case_is ALLOW "a commit message about the incident"          'git commit -m "kill: a /proc scan piped into kill killed my own shell; use literal pids"'
case_is ALLOW "a heredoc body describing it"                 'cat > /tmp/x <<EOF
pkill -f matrix.sh is what not to do
EOF'
case_is ALLOW "qvm-kill, which names a QUBE not a process"   'qvm-kill win10-acc'
case_is ALLOW "grep for the word kill in a log"              'grep -n kill scratchpad/acceptance.log'

echo "PART C  the block has to teach the right shape"
hookjson 'pkill -f matrix.sh'; bash "$GATE" <"$T/hook.json" >"$T/msg" 2>&1
ck "says the matcher carries the text"  "1" "$(command grep -c 'MATCHER CARRIES THE TEXT' "$T/msg")"
ck "shows the two-command shape"        "1" "$(command grep -c 'TWO commands' "$T/msg")"
ck "names the literal-pid form"         "1" "$(command grep -c 'kill -TERM 12345' "$T/msg")"
ck "allows a recorded pidfile"          "1" "$(command grep -c 'cat run.pid' "$T/msg")"

echo "PART D  it is actually wired in"
ck "registered as a PreToolUse hook"    "1" \
   "$(python3 -c "
import json
d=json.load(open('.claude/settings.json'))
print(sum(1 for m in d.get('hooks',{}).get('PreToolUse',[]) for h in m.get('hooks',[]) if 'kill-by-pattern-gate' in h.get('command','')))")"

echo "killpattern-gate-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
