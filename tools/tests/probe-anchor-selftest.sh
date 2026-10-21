#!/bin/bash
# A LIVENESS MARKER MUST BE MATCHED ANCHORED, OR THE REQUEST ANSWERS FOR THE GUEST.
#
# qubes.VMShell returns cmd's banner AND THE ECHOED COMMAND LINE. So the stream for
# `cmd /c echo QREADY` against a guest that answered NOTHING still contains the characters
# QREADY - inside the echo of the request we just sent:
#
#     C:\Windows\System32>cmd /c echo QREADY
#
# An unanchored `grep -qa QREADY` matches that line. Every such predicate therefore reported a
# dead guest as alive. tools/qtest hit this exact defect with its QTINCOK probe on 2026-10-09 and
# anchored it; nine readiness/liveness consumers in the harness were still unanchored on
# 2026-10-21, including the QREXECDEAD discriminator in collect-failure.sh, which decides whether a
# run is graded "qrexec dead on a running guest" or "the subject would not halt".
#
# Lint L23 does not cover this: it is about a pipe into `grep -q` returning 141 under pipefail, and
# its own "correct shape stays silent" fixture is `grep -qa PONG <<< "$(...)"` - the unanchored form.
#
# This suite EXECUTES the real predicates out of the real files against a stub that emits the
# banner-and-echo stream, and it is checked against the pre-fix text in git so that it is known to
# fail when the anchor is absent.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A stub qtest. MODE=deaf emits only the banner and the echoed request - what a guest that answered
# nothing looks like. MODE=answered also emits the marker on its own line.
mkstub(){ # $1=dir $2=mode
  mkdir -p "$1/tools"
  cat > "$1/tools/qtest" <<'STUB'
#!/bin/bash
# $1=verb, $2=command line
printf 'Microsoft Windows [Version 10.0.26100.1]\r\n'
printf '(c) Microsoft Corporation. All rights reserved.\r\n\r\n'
printf 'C:\\Windows\\System32>%s\r\n' "${2:-}"
[ "${STUB_MODE:-deaf}" = answered ] && printf 'QREADY\r\n'
exit 0
STUB
  chmod +x "$1/tools/qtest"
}

# ---------------------------------------------------------------- w_alive, out of the real file
w_alive_case(){ # $1=source-text-file $2=mode -> echoes the rc
  local d="$T/wa.$RANDOM"; mkdir -p "$d/mgmt/harness"; mkstub "$d"
  cp "$1" "$d/mgmt/harness/e2e-wait.sh"
  ( cd "$d" && STUB_MODE="$2" bash -c '
      # take ONLY the w_alive definition: sourcing the whole library runs its own preamble
      eval "$(sed -n "/^w_alive()/,/^}/p;/^w_alive(){/p" mgmt/harness/e2e-wait.sh)"
      w_alive somevm 2 >/dev/null 2>&1; echo $?' )
}
cp "$ROOT/mgmt/harness/e2e-wait.sh" "$T/now.sh"
git -C "$ROOT" show HEAD:mgmt/harness/e2e-wait.sh > "$T/head.sh" 2>/dev/null || cp "$T/now.sh" "$T/head.sh"

rc=$(w_alive_case "$T/now.sh" deaf)
[ "$rc" != 0 ] && ok "w_alive: a banner-and-echo stream is NOT alive (rc=$rc)" \
               || no "w_alive: the echoed request declared the guest alive (rc=$rc)"
rc=$(w_alive_case "$T/now.sh" answered)
[ "$rc" = 0 ] && ok "w_alive: a real marker line IS alive (positive control)" \
              || no "w_alive: a real marker line was not accepted (rc=$rc) - the anchor is too strict"

# THE NEGATIVE CONTROL. Against the pre-fix text this suite must FAIL, or it proves nothing.
rc=$(w_alive_case "$T/head.sh" deaf)
if command grep -qa "grep -qa QREADY <<<" "$T/head.sh"; then
    [ "$rc" = 0 ] && ok "negative control: the unanchored HEAD text DOES call a deaf guest alive" \
                  || no "negative control did not reproduce: unanchored HEAD gave rc=$rc, expected 0"
else
    ok "negative control: HEAD already carries the anchor (nothing to reproduce)"
fi

# ---------------------------------------------------------------- w_alive_poll, which reads a FILE
poll_case(){ # $1=source-text-file $2=file-contents -> rc
  local d="$T/wp.$RANDOM"; mkdir -p "$d/mgmt/harness"
  cp "$1" "$d/mgmt/harness/e2e-wait.sh"; printf '%b' "$2" > "$d/out.txt"
  ( cd "$d" && bash -c '
      eval "$(sed -n "/^w_alive_poll()/,/^}/p" mgmt/harness/e2e-wait.sh)"
      w_alive_poll 1 out.txt >/dev/null 2>&1; echo $?' )
}
BANNER='C:\\Windows\\System32>cmd /c echo QREADY\r\n'
rc=$(poll_case "$T/now.sh" "$BANNER")
[ "$rc" != 0 ] && ok "w_alive_poll: the echoed request alone is not the marker (rc=$rc)" \
               || no "w_alive_poll: matched the echoed request (rc=$rc)"
rc=$(poll_case "$T/now.sh" "${BANNER}QREADY\r\n")
[ "$rc" = 0 ] && ok "w_alive_poll: a real marker line is seen (positive control)" \
              || no "w_alive_poll: missed a real marker (rc=$rc)"

# ---------------------------------------------------------------- the QREXECDEAD discriminator
# collect-failure.sh decides LIVENESS from $PROBE. Run the real line against both streams.
disc(){ # $1=source-text $2=probe-text -> alive|unresponsive
  local line; line=$(command grep -a "GUARD:unresponsive" "$1" | command grep -av '^\s*#' | head -1)
  [ -n "$line" ] || { echo "NOLINE"; return; }
  PROBE="$(printf '%b' "$2")" bash -c "LIVENESS=; ${line%%   # GUARD*}; echo \$LIVENESS"
}
cp "$ROOT/mgmt/harness/collect-failure.sh" "$T/cf-now.sh"
git -C "$ROOT" show HEAD:mgmt/harness/collect-failure.sh > "$T/cf-head.sh" 2>/dev/null || cp "$T/cf-now.sh" "$T/cf-head.sh"
v=$(disc "$T/cf-now.sh" "$BANNER")
[ "$v" = unresponsive ] && ok "collect-failure: banner-and-echo is unresponsive, not alive" \
                        || no "collect-failure: graded '$v' on a stream with no answer"
v=$(disc "$T/cf-now.sh" "${BANNER}QREADY\r\n")
[ "$v" = alive ] && ok "collect-failure: a real marker is alive (positive control)" \
                 || no "collect-failure: a real marker graded '$v'"
if command grep -qa '\*QREADY\*) LIVENESS="alive"' "$T/cf-head.sh"; then
    v=$(disc "$T/cf-head.sh" "$BANNER")
    [ "$v" = alive ] && ok "negative control: the pre-fix case DID grade a deaf guest alive" \
                     || no "negative control did not reproduce: pre-fix gave '$v'"
else
    ok "negative control: HEAD's discriminator is already anchored"
fi

# ---------------------------------------------------------------- THE SWEEP, not one emitter
# Every consumer of the marker, in every harness file, must be anchored. A rule that checks the one
# site someone remembered is how four wrong-tag false negatives happened in one morning.
unanchored=$(cd "$ROOT" && command grep -rn "QREADY" --include='*.sh' mgmt tools \
    | command grep -v '/tests/' \
    | command grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | command grep -E "grep -qa QREADY|grep -q QREADY|\*QREADY\*" || true)
if [ -z "$unanchored" ]; then
    ok "sweep: no unanchored marker consumer in mgmt/ or tools/"
else
    no "sweep: unanchored marker consumer(s) still present:"
    printf '%s\n' "$unanchored" | sed 's/^/       /'
fi

# ---- A PROBE THAT DID NOT ANSWER IS NOT A LOG OF ZERO LINES ------------------------------------
# w_install polls the guest for its log's line count and had `n=${n:-0}`: an unparseable or empty
# answer - a transient qrexec hiccup, a busy guest, a timeout - produced the SAME value as a
# genuinely empty or not-yet-created log, so "t+Ns 0 log lines" could not be told apart from a real
# zero and a stalled install looked like a guest that had not started writing yet. The stall clock
# is driven by whether the count CHANGES, and an unanswered probe is not a change.
blk=$(sed -n '/A PROBE THAT DID NOT ANSWER IS NOT A LOG OF ZERO LINES/,/^      fi$/p' "$ROOT/mgmt/harness/e2e-wait.sh")
if [ -n "$blk" ] && printf '%s' "$blk" | command grep -qa 'n=$last'; then
  ok "the probe-failure branch was extracted from e2e-wait.sh"
else
  no "could not extract the probe-failure branch" "the legs below would test nothing"
fi

judge(){ # $1=probe answer ("" = no answer) $2=last known -> "n=<kept> said=<yes|no>"
  bash -c '
    lbl=cell; log=echo
    n="$1"; last="$2"
    eval "$3"
    printf "n=%s said=%s\n" "$n" "$SAID"
  ' _ "$1" "$2" "$(printf '%s' "$blk" | sed 's/\$log /SAID=yes; : /')" 2>&1
}

got=$(judge "" 17)
case "$got" in
  *"n=17"*) ok "an UNANSWERED probe keeps the last known count (17), it does not read as 0" ;;
  *)        no "an unanswered probe did not hold the last count" "$got" ;;
esac
got=$(judge "" 0)
case "$got" in
  *"n=0"*) ok "with nothing known yet it stays 0 - no invented progress" ;;
  *)       no "an unanswered probe at the start invented a count" "$got" ;;
esac
got=$(judge 42 17)
case "$got" in
  *"n=42"*) ok "a real answer is taken as the count" ;;
  *)        no "a real answer was discarded" "$got" ;;
esac
# SEEN TO FAIL: the pre-fix default makes an unanswered probe indistinguishable from an empty log
got=$(bash -c 'n="$1"; last="$2"; n=${n:-0}; printf "n=%s\n" "$n"' _ "" 17)
case "$got" in
  *"n=0"*) ok "SEEN TO FAIL: with n=\${n:-0} an unanswered probe reads as 0 lines, like an empty log" ;;
  *)       no "the pre-fix shape did not reproduce" "$got" ;;
esac

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
