#!/bin/bash
# THE ARM THAT ACTUALLY FIRES MUST MARK THE SPECIMEN.
#
# w_session has two ways out when a guest never gives a session:
#
#   * the DEADLINE branch, reached at $dl, which calls specimen_mark; and
#   * `elif [ "$dark" -ge 3 ]`, which returns about four minutes in.
#
# Every production call site passes $dl of 420, 600 or 900 (measured: 1x420, 1x600, 8x900). All are
# above 240, so the dark arm ALWAYS wins and the only specimen_mark call in the function never ran.
# That is how the first reliably captured wedge was lost on 2026-10-20: the guest was classified,
# nothing recorded it as evidence, and the campaign recreated it two minutes later. The marker is
# what makes tools/hooks/golden-boot-gate.sh refuse a start of that name.
#
# The assertion is a FILE SIDE EFFECT, not stdout: the call sends its stdout to /dev/null, so a
# receipt scraped from stdout could never appear and would pass for ever.
#
# w_session is eval'd out of the shipped file - the same way cputime-failopen-selftest.sh takes
# w_cpu_time - so this cannot drift from the harness. The clock and sleep are virtual.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }

# The deadlines the harness really uses, read from the call sites rather than assumed.
mapfile -t DEADLINES < <(command grep -rhoE 'w_session "[^"]+" [0-9]+' --include='*.sh' "$ROOT/mgmt" "$ROOT/tools" \
                         | command grep -oE '[0-9]+$' | sort -n -u)
[ "${#DEADLINES[@]}" -gt 0 ] || { echo "FATAL: found no w_session deadline in the harness"; exit 2; }
echo "note deadlines found at the real call sites: ${DEADLINES[*]}"

run_session(){ # $1=source file $2=deadline -> prints "rc=<n> marked=<0|1>"
  local src="$1" dl="$2" T
  T="$(mktemp -d)"
  (
    export SPECIMEN_DIR="$T/specimens"
    cd "$T" || exit 2
    # ---- virtual clock: w_session reads `date +%s` and calls `sleep`. Functions beat externals.
    _NOW=1000000
    date(){ case "${1:-}" in +%s) echo "$_NOW" ;; *) command date "$@" ;; esac; }
    sleep(){ _NOW=$(( _NOW + ${1:-1} )); }
    # ---- the guest: dark, unreachable, and spinning
    w_screen(){ echo NOWINDOW; }
    w_alive_poll(){ return 2; }                  # the single probe is still outstanding
    w_alive_start(){ echo 424242; }
    w_state(){ echo Running; }
    w_appvm_shell(){ return 0; }
    wedge_classify(){ echo "SPIN 1.01"; }
    w_cpu_moving(){ return 0; }
    w_cpu_time(){ echo 1234; }
    kill(){ return 0; }                          # w_alive_poll's liveness check / cleanup
    fetch_wedge_core(){ return 1; }
    log(){ :; }
    # ---- the real functions under test
    eval "$(sed -n '/^specimen_file()/,/^}/p' "$ROOT/mgmt/harness/specimen-lib.sh")"
    eval "$(sed -n '/^_sp_say()/,/^}/p'       "$ROOT/mgmt/harness/specimen-lib.sh")"
    eval "$(sed -n '/^specimen_mark()/,/^}/p' "$ROOT/mgmt/harness/specimen-lib.sh")"
    eval "$(sed -n '/^w_session()/,/^}/p'     "$src")"
    declare -F w_session    >/dev/null || { echo "rc=X marked=X"; exit 0; }
    declare -F specimen_mark >/dev/null || { echo "rc=Y marked=Y"; exit 0; }
    w_session somevm "$dl" "lbl-$dl" "$T/out" : >/dev/null 2>&1
    rc=$?
    n=$(find "$SPECIMEN_DIR" -type f 2>/dev/null | wc -l)
    echo "rc=$rc marked=$([ "${n:-0}" -gt 0 ] && echo 1 || echo 0)"
  )
  rm -rf "$T"
}

# ---------------------------------------------------------------- the shipped file
allmarked=1; detail=""
for dl in "${DEADLINES[@]}"; do
  out=$(run_session "$ROOT/mgmt/harness/e2e-wait.sh" "$dl")
  detail="$detail $dl:[$out]"
  case "$out" in *marked=1*) ;; *) allmarked=0 ;; esac
done
[ "$allmarked" = 1 ] \
  && ok "a dark unreachable guest is marked as a specimen at every production deadline -$detail" \
  || no "a dark guest went unmarked at a production deadline -$detail"

# ---------------------------------------------------------------- NEGATIVE CONTROL
# Put the pre-fix arm back - no specimen_mark, and the "NOT burning CPU" claim it never tested -
# and the assertion above must fail. A check never seen to fail is not evidence.
CTL=$(mktemp --suffix=.sh); trap 'rm -f "$CTL"' EXIT
python3 - "$ROOT/mgmt/harness/e2e-wait.sh" "$CTL" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'\n(        elif \[ "\$dark" -ge 3 \]; then\n.*?\n          return 1\n)', t, re.S)
if not m:
    sys.stderr.write("control: could not find the dark arm\n"); sys.exit(3)
pre = ('\n        elif [ "$dark" -ge 3 ]; then\n'
       '          $log "  $lbl: TERMINAL - no usable screen for ${dark} min and NOT burning CPU '
       '(cpu=${cpu:-NA}), qvm=$(w_state "$vm")"\n'
       '          return 1\n')
open(sys.argv[2], "w", encoding="utf-8").write(t[:m.start(1)-1] + pre + t[m.end(1):])
PY
if [ -s "$CTL" ]; then
  cdetail=""; anymarked=0
  for dl in "${DEADLINES[@]}"; do
    out=$(run_session "$CTL" "$dl")
    cdetail="$cdetail $dl:[$out]"
    case "$out" in *marked=1*) anymarked=1 ;; esac
  done
  [ "$anymarked" = 0 ] \
    && ok "negative control: the pre-fix arm marks NOTHING at any production deadline -$cdetail" \
    || no "negative control did not reproduce the loss -$cdetail"
  # and the false claim is what it used to say
  command grep -qa 'NOT burning CPU' "$CTL" && ok "negative control carries the pre-fix wording" \
                                            || no "negative control was not built from the pre-fix text"
else
  no "negative control could not be generated"
fi

# ---------------------------------------------------------------- the removed false claim
# Comments are excluded on purpose: the fix's own comment explains the removed claim and quotes it.
# Grepping the whole file would fire on the explanation, which is a check keyed on wording rather
# than on behaviour - the thing this repo keeps getting wrong.
if command grep -a 'NOT burning CPU' "$ROOT/mgmt/harness/e2e-wait.sh" \
     | command grep -qav '^[[:space:]]*#'; then
  no "e2e-wait.sh still claims 'NOT burning CPU' in a live line of a branch that tests no cpu term"
else
  ok "no live line claims 'NOT burning CPU' (the explanation in the comment is allowed)"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
