#!/bin/bash
# guest text cannot forge or mask a declared severity.
# run: tools/tests/logvol-guesttext-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

# shellcheck disable=SC1091
_lv_guest(){ printf '%s' "$1" | tr -d '\r\n' | tr '[]' '()' | cut -c1-160; }
# Take the shipped definition, not this copy, if it can be sourced in isolation.
eval "$(sed -n '/^_lv_guest()/p' mgmt/harness/logvol-lib.sh)"

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: expected '$2', got '$3'"; fi; }

ck "a forged level loses its brackets"     "LOGVOL-BIND failed (ERROR) denied" "$(_lv_guest 'LOGVOL-BIND failed [ERROR] denied')"
ck "a forged WARN loses its brackets"      "(WARN) nothing to see"             "$(_lv_guest '[WARN] nothing to see')"
ck "a newline cannot split the record"     "firstsecond"                       "$(_lv_guest "$(printf 'first\nsecond')")"
ck "a CRLF cannot split the record"        "firstsecond"                       "$(_lv_guest "$(printf 'first\r\nsecond')")"
ck "ordinary guest text survives"          "access is denied"                  "$(_lv_guest 'access is denied')"
ck "length is bounded to 160"              "160"                               "$(s=$(_lv_guest "$(printf 'x%.0s' $(seq 1 400))"); echo ${#s})"

# And the shipped file must route every guest-derived quote through it.
n_guest=$(grep -c '_lv_guest "' mgmt/harness/logvol-lib.sh)
ck "the helper is defined once"            "1"   "$(grep -c '^_lv_guest()' mgmt/harness/logvol-lib.sh)"
ck "every guest-derived quote is wrapped"  "yes" "$([ "$n_guest" -ge 5 ] && echo yes || echo "no ($n_guest)")"
# No remaining bare interpolation of the guest's bind reply into a severity line.
ck "no bare \$line in a declared line"     "0"   "$(grep -c '_lv_say "\[ERROR\][^"]*: \$line"' mgmt/harness/logvol-lib.sh)"

echo "logvol-guesttext-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
