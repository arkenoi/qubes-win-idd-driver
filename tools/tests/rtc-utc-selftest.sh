#!/bin/bash
# NOTHING SETS A HARDWARE-CLOCK CONVENTION, AND THE QUBE FEATURE IS SET AT CREATE TIME
# run: tools/tests/rtc-utc-selftest.sh
# pass: exit 0
set -u
cd "$(dirname "$0")/../.." || exit 1
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1: expected '$2', got '$3'"; fi; }

I=packaging/setup/Install-QwtImproved.ps1
C=guest/sync-clock-from-dom0.ps1
# Comments stripped before counting: these files NAME the writes that were removed, so matching raw
# text finds the explanation and calls it a write - a mistake made twice in one day here.
nocomment(){ tr -d '\r' < "$1" | sed 's/^ *#.*//'; }
xmlbody(){ python3 -c "import re,sys;print(re.sub(r'<!--.*?-->','',open(sys.argv[1],encoding='utf-8').read(),flags=re.S))" "$1"; }
W='New-ItemProperty[^|]*RealTimeIsUniversal|Set-ItemProperty[^|]*RealTimeIsUniversal|reg(\.exe)? +add[^|]*RealTimeIsUniversal'

echo "---- A. nothing anywhere sets a hardware-clock convention ----"
ck "the installer writes none"                  "0" "$(nocomment "$I" | command grep -cE "$W")"
ck "the per-boot clock task writes none"        "0" "$(nocomment "$C" | command grep -cE "$W")"
ck "no harness file writes one"                 "0" "$(sed 's/#.*//' mgmt/harness/*.sh | command grep -cE "$W")"
for x in mgmt/autounattend*.xml; do
  ck "no convention in $(basename "$x")"        "0" "$(xmlbody "$x" | command grep -c 'RealTimeIsUniversal')"
done
ck "the golden-baking script is gone"           "absent" \
   "$([ -e mgmt/harness/set-rtc-utc-golden.sh ] && echo present || echo absent)"

echo "---- B. every creator of a Windows guest sets timezone=localtime ----"
# DERIVED, NOT ENUMERATED. The first version of this listed the five files I had edited, and missed
# mgmt/prime-selftest.sh - which creates its own churn and was therefore booting guests on a true-UTC
# clock. Measured 2026-10-15: that churn read 16:46 where dom0 said 19:46. So the check now starts
# from the thing that defines a Windows guest - `qvm-features <vm> os Windows` - and requires the
# same file to give that guest its clock, with the SAME number of sites. A new creator cannot be
# added without tripping this, which is what the enumerated version could not do.
for f in $(command grep -rla 'qvm-features .* os Windows' --include='*.sh' mgmt/ tools/ 2>/dev/null | sort); do
  o=$(sed 's/#.*//' "$f" | command grep -cE 'qvm-features +"?\$[A-Za-z_]+"? +os +Windows')
  t=$(sed 's/#.*//' "$f" | command grep -cE 'qvm-features +"?\$[A-Za-z_]+"? +timezone +localtime')
  ck "$(basename "$f"): $o os-Windows site(s) each get a clock" "$o" "$t"
done
ck "and nothing ever CLEARS it"                 "0" \
   "$(sed 's/#.*//' mgmt/harness/*.sh mgmt/*.sh 2>/dev/null | command grep -cE 'qvm-features +--unset +[^ ]+ +timezone')"

echo "---- C. the guest's zone comes from dom0, and that is all the product sets ----"
ck "the installer reads /qubes-timezone"        "yes" \
   "$(nocomment "$I" | command grep -q '/qubes-timezone' && echo yes || echo no)"
ck "it sets the zone with tzutil"               "1" "$(nocomment "$I" | command grep -c 'tzutil /s')"
ck "no answer file pins UTC"                    "0" \
   "$(command grep -ao '<TimeZone>UTC</TimeZone>' mgmt/autounattend*.xml | command grep -c . || true)"
ck "the per-boot task only pulls the clock"     "0" "$(nocomment "$C" | command grep -cE 'tzutil|TimeZoneInformation')"

echo "---- D. seen to fail: put a writer back ----"
# NEVER A PASS THE CHECK HAS NOT BEEN SEEN TO FAIL. Five versions of this file asserted five
# different shapes and each went green on the belief of the morning.
T=$(mktemp -d "${TMPDIR:-/tmp}/rtcnone.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
{ nocomment "$I"; echo 'New-ItemProperty -LiteralPath $key -Name RealTimeIsUniversal -PropertyType DWord -Value 1 -Force'; } > "$T/bad.ps1"
ck "a planted writer is caught"                 "1" "$(command grep -cE "$W" "$T/bad.ps1")"
{ sed 's/#.*//' mgmt/harness/prime-run.sh; echo 'qvm-features --unset "$CHURN" timezone'; } > "$T/bad.sh"
ck "a planted feature-clear is caught"          "1" \
   "$(command grep -cE 'qvm-features +--unset +[^ ]+ +timezone' "$T/bad.sh")"

echo "rtc-utc-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
