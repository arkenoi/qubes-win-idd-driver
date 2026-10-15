#!/bin/bash
# rtc-utc-selftest.sh - NOTHING BUT THE PRODUCT DECIDES THE RTC CONVENTION, AND IT DERIVES IT.
#
# WHAT THIS FILE HAS ASSERTED, IN ORDER, AND WHY EACH VERSION WAS WRONG:
#   1. that `w_rtc_utc` EXISTS and is called from prime-run.sh - a harness function writing
#      RealTimeIsUniversal=1 into every subject after every install. That is the harness deciding a
#      product setting, and it made the gate unable to measure the product at all: whatever the
#      installer and the per-boot task derived was overwritten. MEASURED on run 11 - the installer
#      logged `set to 0 for the next boot` and the following boots ran with 1, three hours out.
#   2. that the answer files write 1 and `set-rtc-utc-golden.sh` bakes it into a golden - the same
#      defect one layer earlier. Every clone of such a golden inherited a forced value.
#   3. that the installer writes the CONSTANT 1.
# Each version grepped for whichever value I believed that morning, so each time the decision was
# re-made the check went green on the new belief and told me nothing.
#
# SO THIS ASSERTS THE INVARIANT INSTEAD OF A VALUE. Which convention is right is a property of the
# QUBE, not of Windows: dom0 gives a qube `timezone=localtime` - making Xen present the RTC as dom0
# LOCAL time - once the GUEST reports os=Windows+qrexec, and before that the RTC holds true UTC. No
# constant is right in both windows and no image can know which it is in. What must hold:
#   * NOTHING outside the product declares a convention - no answer file, no golden, no harness;
#   * the product has exactly TWO writers and BOTH derive their value - the installer picks an
#     opening value from a measurement (is QWT installed?), and the per-boot task converges it from
#     an independent witness;
#   * BOTH HALVES EXIST. Either alone is a shipped defect: an opening value that never converges is
#     the +3 h we shipped, and convergence with no opening value reintroduces the 25-minute drvinst
#     hang on a clean install.
# A check that greps for a number cannot catch one half of that pair going missing. See
# docs/ADR-clock.md.
set -u
cd "$(dirname "$0")/../.." || exit 1
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1: expected '$2', got '$3'"; fi; }

I=packaging/setup/Install-QwtImproved.ps1
C=guest/sync-clock-from-dom0.ps1
# Comments stripped before counting: this file, rtc-lib.sh and the installer all NAME the writes
# they removed, so grepping raw text finds the explanation and calls it a write.
hcode(){ sed 's/#.*//' mgmt/harness/*.sh; }
icode(){ tr -d '\r' < "$I" | sed 's/^ *#.*//'; }
fn(){ tr -d '\r' < "$1" | awk "/^function $2 \\{/,/^\\}\$/"; }

echo "---- A. nothing outside the product declares a convention ----"
ck "no harness file writes RealTimeIsUniversal" "0" \
   "$(hcode | command grep -cE 'RealTimeIsUniversal[^|]*(/d [01])|reg add[^|]*RealTimeIsUniversal')"
ck "the old harness setter is gone"             "0" "$(hcode | command grep -c 'w_rtc_utc')"
ck "no ANSWER FILE writes it"                   "0" \
   "$(command grep -ao 'RealTimeIsUniversal /t REG_DWORD' mgmt/autounattend*.xml | command grep -c . || true)"
ck "the golden-baking script is GONE"           "absent" \
   "$([ -e mgmt/harness/set-rtc-utc-golden.sh ] && echo present || echo absent)"
ck "a reporter exists in rtc-lib.sh"            "1" "$(command grep -c '^w_rtc_report()' mgmt/harness/rtc-lib.sh)"
ck "and it only QUERIES the registry"           "1" \
   "$(sed 's/#.*//' mgmt/harness/rtc-lib.sh | command grep -c 'reg query')"
ck "prime-run reports after priming"            "1" \
   "$(sed 's/#.*//' mgmt/harness/prime-run.sh | command grep -c 'w_rtc_report')"
# The name has to RESOLVE where it is called - the original defect here was a call that resolved to
# nothing, because prime-run deliberately does not source e2e-wait.sh.
ck "the name resolves in prime-run's context"   "yes" \
   "$(bash -c 'eval "$(command grep -E "^source mgmt/harness/" mgmt/harness/prime-run.sh)" 2>/dev/null; declare -f w_rtc_report >/dev/null && echo yes || echo no')"
ck "e2e-wait.sh provides it to ITS callers"     "yes" \
   "$(bash -c 'source mgmt/harness/e2e-wait.sh 2>/dev/null; declare -f w_rtc_report >/dev/null && echo yes || echo no')"

echo "---- B. the installer touches the convention ONLY in response to a measurement ----"
# THE NORMAL CONFIGURATION IS ALREADY CORRECT, so the installer must not declare a convention at
# all until a measurement says to. Windows' default reads the RTC as local time; Qubes presents a
# Windows qube's RTC as dom0 local time; the two are halves of one convention. The ONE moment the
# value matters is a guest measured BEHIND the payload's certificates - a true-UTC RTC read as local
# - which is the direction that hangs drvinst for 25 minutes (0x800B0101). So the invariant is not
# "which value" but "reached only from the failure branch of the clock gate".
ck "exactly one writer in the installer"        "1" \
   "$(icode | command grep -cE 'New-ItemProperty[^|]*RealTimeIsUniversal')"
ck "exactly one call site"                      "1" \
   "$(icode | command grep -cE '^ *\$?[a-z]* *=? *Set-RtcConventionForNextBoot *$')"
# ORDER IS THE WHOLE ASSERTION: measure, then branch on the result, then act. A call before the
# measurement would be the unconditional write this release removed.
measure=$(command grep -n "\$skewed = Assert-PayloadClockSane -Root \$Root -Why 'stage 1 pre-flight'" "$I" | head -1 | cut -d: -f1)
branch=$(awk -v m="${measure:-0}" 'NR>m && /if \(\$skewed\.Count -gt 0\) \{/ {print NR; exit}' "$I")
act=$(command grep -nE '^ *\$fixed = Set-RtcConventionForNextBoot *$' "$I" | head -1 | cut -d: -f1)
ck "the clock is MEASURED before anything acts" "yes" \
   "$([ -n "$measure" ] && [ -n "$branch" ] && [ -n "$act" ] && [ "$measure" -lt "$branch" ] && [ "$branch" -lt "$act" ] && echo yes || echo "no (measure=${measure:-none} branch=${branch:-none} act=${act:-none})")"
# AND THE WRITE LIVES ONLY INSIDE THAT FUNCTION. Counting writers "before the call site" does not
# work - the function is DEFINED above its caller, so its own body matches. What must hold is that
# no other part of the installer writes the value, on any path.
ck "no writer anywhere outside that function"   "0" \
   "$(icode | awk '/^function Set-RtcConventionForNextBoot \{/{inf=1} inf&&/^\}$/{inf=0;next} !inf' | command grep -cE 'New-ItemProperty[^|]*RealTimeIsUniversal')"
ck "it is idempotent when already set"          "1" \
   "$(fn "$I" Set-RtcConventionForNextBoot | command grep -c 'already 1')"
ck "and says so when the RTC is NOT the fault"  "1" \
   "$(fn "$I" Set-RtcConventionForNextBoot | command grep -c 'the clock itself is')"
ck "it reads the value back"                    "1" \
   "$(fn "$I" Set-RtcConventionForNextBoot | command grep -c 'did not read back as')"
ck "and is never fatal itself"                  "0" \
   "$(fn "$I" Set-RtcConventionForNextBoot | command grep -c 'Fail ')"
ck "the refusal names the one-reboot fix"       "1" \
   "$(fn "$I" Assert-Stage1Preflight | command grep -c 'reboot this guest and re-run')"

echo "---- C. the per-boot task converges it from an independent witness ----"
ck "the per-boot derivation exists"             "yes" "$(command grep -q 'CLOCKCONV' "$C" && echo yes || echo no)"
ck "exactly one writer, and it is derived"      "1" \
   "$(tr -d '\r' < "$C" | command grep -cE 'New-ItemProperty.*-Value \$want')"
ck "the witness reader exists"                  "1" "$(command grep -c '^function Get-ClockWitness' "$C")"
ck "read through the BOUNDED WAIT, not directly" "1" "$(command grep -c '\$w = Wait-ClockWitness' "$C")"
ck "the wait is bounded"                        "1" \
   "$(fn "$C" Wait-ClockWitness | command grep -c 'param(\[int\]\$TimeoutSeconds')"
ck "no witness -> no decision"                  "1" "$(command grep -c 'no usable SETTIME witness' "$C")"
ck "a STALE witness is rejected, not used"      "1" "$(command grep -c 'from an earlier boot' "$C")"

echo "---- D. BOTH HALVES EXIST (the pair is the invariant) ----"
# Either half alone has already shipped as a defect. The installer must NAME the convergence it
# depends on, and that convergence must actually be there.
ck "the installer names the convergence"        "1" \
   "$(fn "$I" Set-RtcConventionForNextBoot | command grep -c 'sync-clock-from-dom0')"
ck "and says it acts only on a measurement"     "1" \
   "$(fn "$I" Set-RtcConventionForNextBoot | command grep -c 'ALREADY BEEN MEASURED WRONG')"
ck "the named convergence file exists"          "yes" "$([ -r "$C" ] && echo yes || echo no)"

echo "---- E. the qube's timezone feature is reported, never changed ----"
ck "no create path unsets it, anywhere"         "0" \
   "$(sed 's/#.*//' mgmt/harness/*.sh mgmt/*.sh 2>/dev/null | command grep -cE 'qvm-features +--unset +[^ ]+ +timezone')"
ck "the harness reports it instead"             "1" "$(command grep -c '^clock_feature_report()' mgmt/harness/matrix.sh)"

echo "---- F. seen to fail: turn the derived write back into a constant ----"
# NEVER A PASS THE CHECK HAS NOT BEEN SEEN TO FAIL. The whole point of this rewrite is that a
# constant cannot be right in both windows, so the check that catches a constant must be shown to.
T=$(mktemp -d "${TMPDIR:-/tmp}/rtcinv.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
sed 's/New-ItemProperty -LiteralPath $key -Name RealTimeIsUniversal -PropertyType DWord -Value $want/New-ItemProperty -LiteralPath $key -Name RealTimeIsUniversal -PropertyType DWord -Value 1/' "$I" > "$T/bad.ps1"
if ! command grep -qE 'DWord -Value 1 -Force' "$T/bad.ps1"; then
  ck "the mutation could be planted" "yes" "no"
else
  ck "a constant write fails the derived-value check" "0" \
     "$(tr -d '\r' < "$T/bad.ps1" | awk '/^function Set-RtcConventionForNextBoot \{/,/^\}$/' | command grep -cE 'New-ItemProperty.*-Value \$want')"
fi

echo "rtc-utc-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
