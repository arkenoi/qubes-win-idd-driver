#!/bin/bash
# A CLEAN VERDICT OVER A CAPTURE WITH NO AGENT-FAMILY LOG IS NOT EVIDENCE.
#
# matrix.sh already refused a CLEAN sweep that read ZERO QWT-format lines (INVALID-SWEEP-BLIND,
# predicate q==0). On run 39476792836 both appvm cells walked through that guard with q=73 and
# still contained no agent-family log content: 13 files, an `agent.log` with zero QWT-format lines,
# and none of gui-agent-*, gui-watchdog-*, qrexec-agent-*, qubesdb-daemon-*. The 73 lines were the
# installer and the wrapper. Both cells were reported "swept CLEAN", and the owner's error-line
# gate was graded over a capture that could not hold a single agent error.
#
# "Some lines arrived" was a proxy. "The agent's own log is here" is the property.
#
# The fixtures below hold the MEASURED shape of both cases - file names taken from that run's real
# captures, contents synthesized, because a capture never goes on a tracked path. When the archive
# is present this suite also replays the eight real captures, where the discriminator is exact:
# the two appvm cells 0, the six others 4-8.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

QWT='^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+'
LINE='[20261020.132705.123-4812:3344-I] LogInit: Log started, module name: %s'

# The predicate as matrix.sh computes it. Taken from the file so the suite cannot drift from it:
# a hand-retyped copy here would pass while the harness did something else, which is how a check
# becomes decoration.
agent_count(){ # $1 = a <cell>-guestlogs dir
  local src
  src=$(sed -n '/^  a=\$(find "\$m\/\$c-guestlogs\/logs" -type f/,/| wc -l)$/p' "$ROOT/mgmt/harness/matrix.sh")
  [ -n "$src" ] || { echo "NOPREDICATE"; return; }
  m="$(dirname "$1")" c="$(basename "$1" -guestlogs)" bash -c "
      m=\"$(dirname "$1")\"; c=\"$(basename "$1" | sed 's/-guestlogs$//')\"
      ${src}
      echo \$a"
}

mkcap(){ # $1=dir $2=mode(blind|good)
  mkdir -p "$1/logs"
  # present in BOTH, and carrying the lines that made q=73 on the blind cells
  for f in qwt-install.log qwt-improved-install.log QubesIDD-diag.log QubesNetSetup.log \
           QubesPvNic.log file-receiver-20261020.log qrexec-wrapper-20261020.log; do
    printf "$LINE\n" "${f%%.log}" > "$1/logs/$f"
  done
  : > "$1/logs/agent.log"        # the agent-family NAME with no agent content - the whole trap
  printf '{"logdir":{"exists":0}}' > "$1/logs/meta.json"
  if [ "$2" = good ]; then
    for f in gui-agent-20261020.log gui-watchdog-20261020.log qrexec-agent-20261020.log \
             qubesdb-daemon-20261020.log; do
      printf "$LINE\n" "${f%%-*}" > "$1/logs/$f"
    done
  fi
}

mkcap "$T/m/win10-appvm-guestlogs" blind
mkcap "$T/m/win10-clean-guestlogs" good

a=$(agent_count "$T/m/win10-appvm-guestlogs")
[ "$a" = 0 ] && ok "the blind shape yields 0 agent-family logs with lines (so CLEAN is refused)" \
             || no "the blind shape yielded a=$a, so the gate would let it read CLEAN"
a=$(agent_count "$T/m/win10-clean-guestlogs")
[ "$a" -ge 1 ] 2>/dev/null && ok "a healthy capture yields $a (positive control: not refused)" \
                           || no "a healthy capture yielded a=$a - the gate would fail every cell"

# AN EMPTY agent.log MUST NOT COUNT. It is the one file both shapes share, and counting the NAME
# rather than its content is exactly the proxy this gate replaces.
printf 'some harness bash line, not QWT format\n' > "$T/m/win10-appvm-guestlogs/logs/agent.log"
a=$(agent_count "$T/m/win10-appvm-guestlogs")
[ "$a" = 0 ] && ok "an agent.log holding non-QWT text still counts 0" \
             || no "non-QWT text in agent.log counted as agent evidence (a=$a)"

# ...and one real QWT line in it IS evidence, so the gate is not keyed on file names.
printf "$LINE\n" agent > "$T/m/win10-appvm-guestlogs/logs/agent.log"
a=$(agent_count "$T/m/win10-appvm-guestlogs")
[ "$a" = 1 ] && ok "one QWT line in agent.log counts 1 (the gate reads content, not names)" \
             || no "a QWT line in agent.log counted a=$a"

# THE GATE MUST BE WIRED, not merely computable. A predicate nobody calls is decoration.
if command grep -qa 'INVALID-SWEEP-NOAGENT' "$ROOT/mgmt/harness/matrix.sh"; then
    ok "matrix.sh raises INVALID-SWEEP-NOAGENT"
else
    no "matrix.sh computes the count but never raises on it"
fi
# and it must raise through `no`, which is what the tally counts
if sed -n '/INVALID-SWEEP-NOAGENT/p' "$ROOT/mgmt/harness/matrix.sh" | command grep -qa '^\s*no '; then
    ok "it raises via no(), so the cell is counted as failed"
else
    no "INVALID-SWEEP-NOAGENT does not go through no() - it would print and pass"
fi

# ---------------------------------------------------------------- replay the real captures
A=/home/user/qwt-accept/rel-39476792836/campaign/matrix
if [ -d "$A" ]; then
    blind=0 good=0 wrong=""
    for d in "$A"/*-guestlogs; do
        [ -d "$d/logs" ] || continue
        c=$(basename "$d" | sed 's/-guestlogs$//')
        a=$(agent_count "$d")
        case "$c" in
            *appvm) [ "$a" = 0 ] && blind=$((blind+1)) || wrong="$wrong $c=$a(expected 0)" ;;
            *)      [ "${a:-0}" -ge 1 ] 2>/dev/null && good=$((good+1)) || wrong="$wrong $c=$a(expected >=1)" ;;
        esac
    done
    if [ -z "$wrong" ] && [ "$blind" = 2 ] && [ "$good" = 6 ]; then
        ok "replay of run 39476792836: both appvm captures refused, all six others pass"
    else
        no "replay of run 39476792836 disagreed:$wrong (appvm refused=$blind, others passed=$good)"
    fi
else
    echo "note the archived captures are not on this host - the replay assertion did not run"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
