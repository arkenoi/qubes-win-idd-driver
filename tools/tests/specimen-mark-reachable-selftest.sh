#!/bin/bash
# THE ARM THAT ACTUALLY FIRES MUST MARK THE SPECIMEN.
# run: tools/tests/specimen-mark-reachable-selftest.sh
# pass: exit 0
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
    # AN OFFLINE SUITE MAKES NO RIG CALL. w_session samples the guest's cpu with
    # `timeout 20 qrexec-client-vm "$vm" admin.vm.Stats` (e2e-wait.sh), so every run fired 24
    # denied admin calls at a qube named `somevm`, and a denied Admin API call lands in the
    # OWNER'S dom0 journal (measured 2026-10-21; he asked what the calls were).
    # IT HAS TO BE A STUB ON PATH, NOT A FUNCTION. My first fix here was
    # `qrexec-client-vm(){ return 1; }` and the call count stayed at 24: `timeout` is an external
    # that EXECs its argument, so no shell function is in the path to be found. Same for env,
    # xargs, nohup and find -exec.
    # Empty output with rc 1 is exactly what the denial already returned, so nothing else moves.
    mkdir -p "$T/bin"
    printf '#!/bin/sh\nexit 1\n' > "$T/bin/qrexec-client-vm"
    chmod +x "$T/bin/qrexec-client-vm"
    export PATH="$T/bin:$PATH"
    fetch_wedge_core(){ return 1; }
    log(){ :; }
    # ---- the real functions under test
    eval "$(sed -n '/^specimen_file()/,/^}/p' "$ROOT/mgmt/harness/specimen-lib.sh")"
    eval "$(sed -n '/^_sp_say()/,/^}/p'       "$ROOT/mgmt/harness/specimen-lib.sh")"
    eval "$(sed -n '/^specimen_mark()/,/^}/p' "$ROOT/mgmt/harness/specimen-lib.sh")"
    # w_session's COLLABORATOR, or the call to it is "command not found" and the marker never
    # appears - which is indistinguishable from the pre-fix behaviour this suite exists to catch.
    # The marking was inlined at both TERMINAL sites until 2026-10-21; it is a helper now because
    # it has to report a failure to load or write instead of swallowing it.
    eval "$(awk '/# WM-MARK-A/,/# WM-MARK-B/' "$src")"
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

# ---- A TERMINAL VERDICT THAT CANNOT RECORD ITS EVIDENCE MUST SAY SO ----------------------------
# e2e-wait.sh marked a kept guest with
#     if type specimen_mark >/dev/null 2>&1; then specimen_mark ... || true; fi
# so a caller that never sourced specimen-lib.sh got NO marker on the one path where the guest is
# deliberately left standing, and a marker that FAILED to write was swallowed by `|| true`. Either
# way the next run sees an unmarked guest and tools/hooks/golden-boot-gate.sh does not refuse a
# hand-typed start of it - the mistake made on 2026-10-14, minutes after that line fired.
H=$(awk '/# WM-MARK-A/,/# WM-MARK-B/' "$ROOT/mgmt/harness/e2e-wait.sh")
if [ -n "$H" ] && printf '%s' "$H" | command grep -qa '_wm_mark'; then
  ok "the evidence helper was extracted from e2e-wait.sh"
else
  no "could not extract _wm_mark from e2e-wait.sh" "the legs below would test nothing"
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/wmmark-XXXXXX")

# (a) the library loadable and the write succeeding: a marker appears and the helper returns 0
# specimen-lib is sourced first, which is the normal condition in every e2e-wait caller; the
# helper's BASH_SOURCE-relative fallback cannot resolve a path from inside a `bash -c` string, so
# relying on it here would test the harness rather than the helper.
got=$(cd "$ROOT" && bash -c '
  log=echo; SPECIMEN_DIR="$2/spec"
  source mgmt/harness/specimen-lib.sh
  eval "$1"
  _wm_mark probe-vm "kept by the probe" "$2" && echo RC0 || echo RCFAIL
' _ "$H" "$W" 2>&1)
if printf '%s' "$got" | command grep -qa RC0 && [ -f "$W/spec/probe-vm.spent" ]; then
  ok "it records the marker and returns 0 when the library loads"
else no "no marker was written on the happy path" "$got"; fi

# (b) the library NOT loadable: it must say so loudly and fail, not pass quietly
got=$(cd "$W" && bash -c '
  log=echo; SPECIMEN_DIR="$1/spec2"
  eval "$2"
  _wm_mark probe-vm2 "kept by the probe" "$1" && echo RC0 || echo RCFAIL
' _ "$W" "$(printf '%s' "$H" | sed 's|/specimen-lib.sh|/NOPE-specimen-lib.sh|')" 2>&1)
if printf '%s' "$got" | command grep -qa RCFAIL && printf '%s' "$got" | command grep -qa '\[ERROR\]'; then
  ok "with the library unloadable it emits [ERROR] and fails, instead of skipping silently"
else no "an unloadable library was silent (that is the pre-fix behaviour)" "$got"; fi

# (c) the write FAILING: also [ERROR], not swallowed
got=$(cd "$ROOT" && bash -c '
  log=echo
  specimen_mark(){ return 1; }
  eval "$1"
  _wm_mark probe-vm3 "kept by the probe" "/x" && echo RC0 || echo RCFAIL
' _ "$H" 2>&1)
if printf '%s' "$got" | command grep -qa RCFAIL && printf '%s' "$got" | command grep -qa 'specimen_mark FAILED'; then
  ok "a FAILING specimen_mark is reported, not swallowed by || true"
else no "a failing specimen_mark was swallowed" "$got"; fi

# (d) the call sites must use the helper, or it is decoration
n=$(command grep -ac '_wm_mark "$vm"' "$ROOT/mgmt/harness/e2e-wait.sh")
[ "${n:-0}" -ge 2 ] && ok "both TERMINAL paths in e2e-wait.sh call the helper ($n sites)" \
                    || no "only $n call site(s) use the helper" "a path still marks evidence the old way"
# LIVE LINES ONLY. The first version of this check matched the COMMENT that quotes the old shape
# ("if type specimen_mark; then specimen_mark ... || true; fi") and reported a swallowed call that
# does not exist - the third comment-matching false positive of the day.
if sed -E 's/(^|[[:space:]])#.*$//' "$ROOT/mgmt/harness/e2e-wait.sh" | command grep -qa 'specimen_mark .* || true'; then
  no "a swallowed specimen_mark call survives in e2e-wait.sh" "$(sed -E 's/(^|[[:space:]])#.*$//' "$ROOT/mgmt/harness/e2e-wait.sh" | command grep -an 'specimen_mark .* || true' | head -1)"
else
  ok "no swallowed specimen_mark call is left in e2e-wait.sh (live lines, not comments)"
fi
rm -rf "$W"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
