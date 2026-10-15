#!/bin/bash
# rtc-utc-selftest.sh - THE HARNESS REPORTS THE CLOCK CONVENTION; IT DOES NOT DECIDE IT.
#
# WHAT THIS FILE USED TO ASSERT, AND WHY THAT WAS THE DEFECT. It required `w_rtc_utc` to exist and
# to be CALLED from prime-run.sh and e2e-wait.sh - a harness function that wrote
# RealTimeIsUniversal=1 into the subject after every install. That is the harness deciding a product
# setting, and it made the gate unable to measure the product: whatever the installer and the
# per-boot task derived was overwritten on every primed subject. MEASURED on run 11 - the installer
# logged `RealTimeIsUniversal set to 0 for the next boot`, and the boots that followed ran with 1
# and a three-hour error, which the sweep then reported as clock_boot_correction_s = 10800.
#
# ONLY ONE VALUE IS CORRECT FOR A GIVEN QUBE and the harness cannot know which: what the RTC holds
# is decided by the qube's `timezone` feature, which qubes-core-admin sets once the GUEST reports
# os=Windows+qrexec - a runtime event. So the PRODUCT derives it from a witness that is not the
# thing under test (set-time.ps1's SETTIME line), and the harness only reports what it finds.
#
# This suite now asserts that posture: a reporter exists, nothing in the harness writes the value,
# and the per-boot derivation is the only thing that does.
set -u
cd "$(dirname "$0")/../.." || exit 1
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1: expected '$2', got '$3'"; fi; }

# ---- THE HARNESS MUST NOT WRITE IT ------------------------------------------------------------
# Comments stripped first: this file and rtc-lib.sh both NAME the old call and the reg add that
# implemented it, so grepping raw text finds the explanation and calls it a write.
hcode(){ sed 's/#.*//' mgmt/harness/*.sh; }
ck "no harness file writes RealTimeIsUniversal" "0" \
   "$(hcode | command grep -cE 'RealTimeIsUniversal[^|]*(/d 1|/d 0)|reg add[^|]*RealTimeIsUniversal')"
ck "the old setter is gone"                     "0" \
   "$(hcode | command grep -c 'w_rtc_utc')"
ck "a reporter exists in rtc-lib.sh"            "1" \
   "$(command grep -c '^w_rtc_report()' mgmt/harness/rtc-lib.sh)"
ck "and it only QUERIES the registry"           "1" \
   "$(sed 's/#.*//' mgmt/harness/rtc-lib.sh | command grep -c 'reg query')"
ck "prime-run reports after priming"            "1" \
   "$(sed 's/#.*//' mgmt/harness/prime-run.sh | command grep -c 'w_rtc_report')"
# The name has to RESOLVE where it is called - the original defect in this area was a call that
# resolved to nothing because prime-run deliberately does not source e2e-wait.sh.
ck "the name resolves in prime-run's context"   "yes" \
   "$(bash -c 'eval "$(command grep -E "^source mgmt/harness/" mgmt/harness/prime-run.sh)" 2>/dev/null; declare -f w_rtc_report >/dev/null && echo yes || echo no')"
ck "e2e-wait.sh still provides it to ITS callers" "yes" \
   "$(bash -c 'source mgmt/harness/e2e-wait.sh 2>/dev/null; declare -f w_rtc_report >/dev/null && echo yes || echo no')"
# The golden-baking script must refuse rather than exist as a loaded gun.
ck "set-rtc-utc-golden.sh is retired"           "1" \
   "$(command grep -c 'RETIRED: this script forced RealTimeIsUniversal' mgmt/harness/set-rtc-utc-golden.sh)"

# ---- THE PRODUCT IS THE ONLY THING THAT DECIDES -----------------------------------------------
C=guest/sync-clock-from-dom0.ps1
ck "the per-boot task derives the convention"   "yes" "$(command grep -q 'CLOCKCONV' "$C" && echo yes || echo no)"
ck "it writes a DERIVED value, not a constant"  "1" "$(command grep -cE 'Value \$want' "$C")"
ck "from a witness, not its own clock"          "1" "$(command grep -c '^function Get-ClockWitness' "$C")"
ck "and decides nothing without one"            "1" "$(command grep -c 'no usable SETTIME witness' "$C")"

# ---- THE QUBE FEATURE IS REPORTED, NEVER CHANGED ----------------------------------------------
mcode(){ sed 's/#.*//' mgmt/harness/matrix.sh; }
ck "the harness reports the timezone feature"   "1" "$(command grep -c '^clock_feature_report()' mgmt/harness/matrix.sh)"
ck "the post-prime sweep never unsets it"       "0" \
   "$(awk '/^clear_prime_leftovers\(\)/,/^\}/' mgmt/harness/matrix.sh | sed 's/#.*//' | command grep -cE 'qvm-features +--unset +[^ ]+ +timezone')"
ck "the per-cell hook never unsets it"          "0" \
   "$(awk '/^logvol_bind_now\(\)/,/^\}/' mgmt/harness/matrix.sh | sed 's/#.*//' | command grep -cE 'qvm-features +--unset +[^ ]+ +timezone')"
ck "exactly two create-time unsets remain"      "2" \
   "$(mcode | command grep -cE 'qvm-features +--unset +[^ ]+ +timezone')"

echo "rtc-utc-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
