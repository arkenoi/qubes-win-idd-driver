#!/bin/bash
# env-assert-selftest.sh - prove mgmt/harness/env-assert.sh, offline, against the GWeck spec with
# synthetic measurements: the matching environment passes, each single deviation that bit this
# project on 2026-09-16 FAILS (24H2 build, English install language, a 'user' account, a
# StandaloneVM, default_user still 'user'), and an unmeasurable fact FAILS rather than passing.
#
# Per this project's rule a check counts only once it has been seen to FAIL on the defect:
#   ENVASSERT_DEFECT=1  - the comparison cannot fail (the original bug: a "matched" verdict on a
#                         24H2 English guest) -> the mismatch cases pass -> THIS TEST MUST FAIL (exit 1)
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
S=mgmt/harness/env-assert.sh
grep -q 'GUARD:envassert-compare' "$S" || { echo "FATAL: defect-knob guard line missing from $S"; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/envassert.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
good(){ cat <<'EOF'
display_version=25H2
current_build=26200
ubr=6725
ui_language=de-DE
install_language=0407
system_locale=de-DE
accounts=Administrator;DefaultAccount;Guest;gerd-test;legacyuser;WDAGUtilityAccount
account_user_absent=true
qwt_version=4.3.29.0
ENVASSERT-END=1
qube_class=TemplateVM
netvm=
default_user=gerd-test
EOF
}
run(){ # $1=label $2=expected-exit $3=sed-expression applied to the good facts
  local f="$T/f.txt" rc out
  good | sed -E "$3" > "$f"
  out=$(ENVASSERT_FAKE_FACTS="$f" bash "$S" fake-vm gweck 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then pass=$((pass+1)); echo "ok    $1 (exit $rc)"
  else fail=$((fail+1)); echo "FAIL  $1: expected exit $2, got $rc"; echo "$out" | sed 's/^/      /' | head -14; fi
}
run "GWeck's environment as measured -> OK"                         0 ''
run "24H2 (build 26100, DisplayVersion 24H2) -> MISMATCH"           3 's/^current_build=.*/current_build=26100/; s/^display_version=.*/display_version=24H2/'
run "English install language with a de-DE locale switch -> MISMATCH" 3 's/^ui_language=.*/ui_language=en-US/; s/^install_language=.*/install_language=0409/'
run "an account named user exists -> MISMATCH"                      3 's/^account_user_absent=.*/account_user_absent=false/'
run "StandaloneVM instead of TemplateVM -> MISMATCH"                3 's/^qube_class=.*/qube_class=StandaloneVM/'
run "template with a netvm -> MISMATCH"                             3 's/^netvm=.*/netvm=fw-net/'
run "default_user still user -> MISMATCH"                           3 's/^default_user=.*/default_user=user/'
run "Windows 10 build -> MISMATCH"                                  3 's/^current_build=.*/current_build=19045/; s/^display_version=.*/display_version=22H2/'
run "ui_language not measured at all -> MISSING (exit 2)"           2 '/^ui_language=/d'
run "class not measured -> MISSING (exit 2)"                        2 '/^qube_class=/d'

echo "summary: $pass passed, $fail failed"
if [ "${ENVASSERT_DEFECT:-}" = "1" ]; then
  [ "$fail" -gt 0 ] && { echo "DEFECT KNOB: the comparison could not fail and this test FAILED on it - the check is proven able to fail"; exit 1; }
  echo "DEFECT KNOB: the test did NOT fail with the comparison disabled - the check is worthless"; exit 1
fi
[ "$fail" -eq 0 ]
