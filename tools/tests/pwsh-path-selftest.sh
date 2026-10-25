#!/usr/bin/env bash
# UNRELIABLE - DROPPED FROM PREFLIGHT 2026-10-25, owner's directive: never write a test for a
# test, and never fault-inject a harness fix as part of the harness. This file mutates another
# TEST or HARNESS file and runs the mutants, so a defect in it corrupts both arms. It is not in
# tools/tests/offline-suites.txt, nothing runs it, and it is NOT to be fixed or re-registered
# without the owner saying so. See TESTFORATESTRECURSION in findings/issues.md.
# pwsh-path-selftest.sh - the resolver every pwsh suite now depends on, driven both ways.
#
# It is the single point of failure for 50-odd suites, so each of its three properties is asserted
# AND broken on purpose with a mutant that must go red:
#
#   obey     an explicit PWSH is printed verbatim                       mutant: search anyway
#   enforce  an explicit PWSH that is not executable FAILS, with no     mutant: fall back to the
#            fallback - this is what makes PWSH=/nonexistent a usable             known installs
#            absence fixture rather than a no-op (the defect that made
#            11 of 28 "runs without pwsh" passes uninterpretable on
#            2026-10-25)
#   find     unset PWSH resolves PATH first, then the known installs    mutant: drop the PATH probe,
#                                                                       which is the whole CI defect
#
# Nothing here needs pwsh to actually run: every candidate is a stub this suite creates, so the
# result does not depend on which machine it is on - which is the point of the thing under test.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$ROOT/tools/tests/pwsh-path.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/pwsh-path-selftest-XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
ck()  { local want="$1" got="$2" what="$3"; [ "$want" = "$got" ] && ok "$what" || bad "$what: want [$want] got [$got]"; }

[ -x "$SUT" ] || { echo "FAIL pwsh-path.sh is missing or not executable - nothing ran"; exit 2; }

# A stub that is executable and identifiable, standing in for a real pwsh.
mk() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\necho %s\n' "$2" > "$1"; chmod +x "$1"; }
mk "$W/stub/pwsh" STUB
mk "$W/onpath/pwsh" ONPATH

# The script under test is invoked through an ABSOLUTE bash, never through PATH: these legs strip
# PATH down to a directory that holds only the stub pwsh (or nothing), and a `#!/usr/bin/env bash`
# shebang resolved under that PATH exits 127 before the resolver runs a line - which reads as a
# resolver failure and is not one.
BASH_BIN="$(command -v bash)"
# run <PWSH-or-UNSET|empty> <PATH-dir-or-none> -> "rc|stdout"
run() {
    local p="$1" pd="$2" rc out
    [ "$pd" = none ] && pd=/nonexistent-bin
    if [ "$p" = UNSET ]; then out=$(env -u PWSH PATH="$pd" "$BASH_BIN" "$SUT" 2>/dev/null); rc=$?
    else out=$(env PWSH="$p" PATH="$pd" "$BASH_BIN" "$SUT" 2>/dev/null); rc=$?; fi
    printf '%s|%s' "$rc" "$out"
}

echo "== obey: an explicit PWSH is the answer =="
ck "0|$W/stub/pwsh" "$(run "$W/stub/pwsh" none)" "an executable PWSH is printed verbatim"
# ...and it WINS over a pwsh on PATH, or the override would be advisory.
ck "0|$W/stub/pwsh" "$(run "$W/stub/pwsh" "$W/onpath")" "an explicit PWSH beats one on PATH"

echo "== enforce: an explicit PWSH that is absent is a HARD failure =="
ck "1|" "$(run /nonexistent/pwsh none)" "absent explicit PWSH: rc=1 and nothing on stdout"
# THE LEG THAT MATTERS. With a perfectly good pwsh on PATH, an explicit absent PWSH must STILL
# fail - otherwise PWSH=/nonexistent silently measures the installed pwsh, which is exactly how
# 11 "ran without pwsh" passes were manufactured on 2026-10-25.
ck "1|" "$(run /nonexistent/pwsh "$W/onpath")" "absent explicit PWSH does NOT fall back to PATH"
# An EMPTY PWSH is not an instruction - it is the shell's way of saying nothing was set.
ck "0|$W/onpath/pwsh" "$(run "" "$W/onpath")" "PWSH='' is treated as unset, not as an absent path"

echo "== find: unset PWSH searches, PATH first =="
ck "0|$W/onpath/pwsh" "$(run UNSET "$W/onpath")" "unset PWSH resolves pwsh from PATH"
_r="$(run UNSET none)"
case "$_r" in
  0\|/home/user/*) ok "unset PWSH with no PATH pwsh falls back to a known install (${_r#0|})" ;;
  1\|)             ok "unset PWSH with no PATH pwsh and no install: rc=1, nothing on stdout" ;;
  *)               bad "unset PWSH, no PATH pwsh: unexpected [$_r]" ;;
esac

echo "== the candidate list covers every install this repo has used =="
# A path named in a suite's history but missing from the resolver is a machine where the suites
# silently stop measuring - the CI defect, repeated.
for _k in /home/user/pwsh/pwsh /home/user/pwsh74/pwsh /home/user/bin/pwsh7/pwsh /home/user/.local/pwsh/pwsh; do
    command grep -qF "$_k" "$SUT" \
        && ok "candidate list names $_k" \
        || bad "candidate list is missing $_k - a machine with only that install resolves nothing"
done

echo "== the properties are BROKEN on purpose and must be seen to fail =="
# obey+enforce: strip the early-return block so an explicit PWSH is second-guessed.
m1="$W/m1.sh"; python3 - "$SUT" "$m1" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
new, n = re.subn(r'if \[ -n "\$\{PWSH:-\}" \]; then.*?\n    exit 1\nfi\n', '', t, count=1, flags=re.S)
assert n == 1, "mutant m1 anchor did not match exactly once"
open(sys.argv[2], 'w').write(new)
PY
chmod +x "$m1"
_g=$(env PWSH=/nonexistent/pwsh PATH="$W/onpath" "$BASH_BIN" "$m1" 2>/dev/null); _rc=$?
[ "$_rc" = 0 ] && ok "mutant m1 (no explicit-PWSH branch) resolves anyway - the enforce leg has teeth" \
                || bad "mutant m1 still failed (rc=$_rc) - the enforce leg would pass on a broken resolver"

# find: drop the PATH probe, the exact shape of the CI failure.
m2="$W/m2.sh"; python3 - "$SUT" "$m2" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
new, n = re.subn(r'_p="\$\(command -v pwsh 2>/dev/null \|\| true\)".*?\nfi\n', '', t, count=1, flags=re.S)
assert n == 1, "mutant m2 anchor did not match exactly once"
open(sys.argv[2], 'w').write(new)
PY
chmod +x "$m2"
_g=$(env -u PWSH PATH="$W/onpath" "$BASH_BIN" "$m2" 2>/dev/null)
[ "$_g" = "$W/onpath/pwsh" ] && bad "mutant m2 (no PATH probe) still found pwsh on PATH - the find leg is decoration" \
                             || ok "mutant m2 (no PATH probe) cannot see a pwsh on PATH - the find leg has teeth"

echo
echo "pwsh-path-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
