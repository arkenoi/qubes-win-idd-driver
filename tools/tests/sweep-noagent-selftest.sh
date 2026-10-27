#!/bin/bash
# A CLEAN VERDICT OVER A CAPTURE WITH NO AGENT-FAMILY LOG IS NOT EVIDENCE
# run: tools/tests/sweep-noagent-selftest.sh
# pass: exit 0
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

  # The BIRTH predicate, extracted the same way and for the same reason as agent_count above: a
  # capture can hold an agent-family log FULL of lines and still say nothing about which build wrote
  # them. MEASURED on run 39868919766 - all four CLEAN cells had gui-agent-20261023.log with 148
  # lines and reported boots=0 agent_instances=0, because ea61ba28 demoted the LogInit banner and
  # nothing emitted the QWTBIRTH replacement. agent_count() returns >0 on exactly those captures, so
  # the rung below cannot see this.
  birth_count(){ # $1 = a <cell>-guestlogs dir
    local src
    src=$(sed -n '/^  b=\$(find "\$m\/\$c-guestlogs\/logs" -type f/,/| wc -l)$/p' "$ROOT/mgmt/harness/matrix.sh")
    [ -n "$src" ] || { echo "NOPREDICATE"; return; }
    bash -c "
        m=\"$(dirname "$1")\"; c=\"$(basename "$1" | sed 's/-guestlogs$//')\"
        ${src}
        echo \$b"
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

# ---- A CLEAN SWEEP OVER AN UNPROVEN LOG PATH IS NOT A CLEAN CELL --------------------------------
# matrix.sh re-proves the log path immediately before grading, with --require-agent-logs, and that
# failure is FATAL. But the proof is SKIPPED when the subject is no longer running, and that branch
# covers two different things: a wedge, which is the case the volume exists for, and a guest that
# simply halted. In the second case nothing establishes that the product was still writing where
# the sweep later read, and a log truncated at the break reads exactly like a clean one. The cell is
# now marked and the grading refuses to call it clean. The predicate is taken from the shipped file.
pred=$(sed -n '/if \[ "\$rc" = 0 \] && \[ -f "\$m\/\$c-logvol-unproven.marker" \]; then/,/^  fi$/p' "$ROOT/mgmt/harness/matrix.sh")
if [ -n "$pred" ] && printf '%s' "$pred" | command grep -qa 'INVALID-SWEEP-UNPROVEN'; then
  ok "the unproven-path predicate was extracted from matrix.sh"
else
  no "could not extract the unproven-path predicate" "the two legs below would test nothing"
fi

judge_unproven(){ # $1=rc $2=marker present(1/0) -> prints what the grading says
  rm -f "$T/m/win10-clean-logvol-unproven.marker"
  [ "$2" = 1 ] && : > "$T/m/win10-clean-logvol-unproven.marker"
  bash -c '
    no(){ printf "NO %s\n" "$*"; }
    rc="$1"; m="$2"; c=win10-clean
    eval "$3"
    echo DONE
  ' _ "$1" "$T/m" "$pred"
}

got=$(judge_unproven 0 1)
case "$got" in
  *"NO win10-clean: INVALID-SWEEP-UNPROVEN"*) ok "a CLEAN sweep over an unproven path is graded INVALID-SWEEP-UNPROVEN" ;;
  *) no "an unproven path was allowed to read clean" "$got" ;;
esac

got=$(judge_unproven 0 0)
case "$got" in
  *NO*) no "a cell whose path WAS proven was graded invalid anyway" "$got - the guard would fail every cell" ;;
  *)    ok "a cell with no marker (path re-proven) is untouched - the guard is not blanket" ;;
esac

got=$(judge_unproven 1 1)
case "$got" in
  *NO*) no "an already-failing cell got a second, confusing verdict" "$got" ;;
  *)    ok "a cell that already failed the sweep is not re-graded by this predicate" ;;
esac

# and the marker must actually be WRITTEN in the branch that skips the proof
if command grep -qa ': > "$M/$c-logvol-unproven.marker"' "$ROOT/mgmt/harness/matrix.sh"; then
  ok "the skip branch writes the marker, so the predicate has an input"
else
  no "nothing writes the unproven marker" "the predicate above would never fire - decoration"
fi

echo

# ---- THE RUNG ABOVE: a log full of lines that names no build -------------------------------------
B="$T/birth"; mkdir -p "$B"

# 1. the legacy banner counts as a birth record - an entry fixture built before ea61ba28 writes it
mkdir -p "$B/legacy-guestlogs/logs/files"
printf "$LINE\n" gui-agent > "$B/legacy-guestlogs/logs/files/gui-agent-20261023-023932-804.log"
printf '[20261023.023940.459-4652-E] ReleaseFrame: failed\n' >> "$B/legacy-guestlogs/logs/files/gui-agent-20261023-023932-804.log"
g=$(birth_count "$B/legacy-guestlogs")
[ "$g" != NOPREDICATE ] || no "the birth predicate could not be extracted from matrix.sh"
[ "${g:-0}" -gt 0 ] && ok "a legacy 'Log started, module name:' banner is a birth record ($g)" \
                    || no "the legacy banner was not counted as a birth record (got '$g')"

# 2. the new marker counts too - this is what a post-fix guest writes
mkdir -p "$B/qwtbirth-guestlogs/logs/files"
printf '[20261023.021749.400-3820:3824-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1100 pid=3820 session=1 uptime=31.500\n[20261023.021750.000-3820:3824-I] TrackWindows: up\n' \
  > "$B/qwtbirth-guestlogs/logs/files/gui-agent-20261023.log"
g=$(birth_count "$B/qwtbirth-guestlogs")
[ "${g:-0}" -gt 0 ] && ok "a QWTBIRTH line is a birth record ($g)" \
                    || no "QWTBIRTH was not counted as a birth record (got '$g')"

# 3. THE MEASURED SHAPE OF RUN 39868919766, and the whole reason this rung exists: an agent-family
#    log carrying real content and declaring no build. agent_count() is >0 here, so INVALID-SWEEP-
#    NOAGENT passes it - and four cells were reported CLEAN over captures of exactly this shape.
mkdir -p "$B/nobirth-guestlogs/logs/files"
{
  printf '[20261023.021749.488-3820:3824-I] LifecycleStart: QGALIFECYCLE channel open\n'
  printf '[20261023.021749.647-3820:3824-I] PerfInit: QGADRAGQUANT on\n'
  printf '[20261023.021800.000-3820:3824-I] TrackWindows: 3 windows\n'
} > "$B/nobirth-guestlogs/logs/files/gui-agent-20261023.log"
a=$(agent_count "$B/nobirth-guestlogs")
g=$(birth_count "$B/nobirth-guestlogs")
[ "${a:-0}" -gt 0 ] && ok "the rung below PASSES this capture ($a agent-family file(s) with lines)" \
                    || no "fixture wrong: the agent-family predicate should see this capture (got '$a')"
[ "${g:-0}" = 0 ] && ok "a capture whose agent log names no build has ZERO birth records" \
                  || no "a birth record was found in a capture that declares none (got '$g')"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
