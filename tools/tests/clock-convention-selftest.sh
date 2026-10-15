#!/bin/bash
# clock-convention-selftest.sh - the RTC convention is DERIVED, from a witness that is not the
# thing under test.
#
# WHAT IS UNDER TEST: the CLOCKCONV block in guest/sync-clock-from-dom0.ps1. RealTimeIsUniversal
# declares whether Windows reads the emulated RTC as UTC (1) or as local time (0), and only one is
# true for a given qube:
#   * dom0 sets the qube's `timezone` feature to `localtime` after the guest reports
#     os=Windows+qrexec, and the RTC then holds DOM0 LOCAL time -> the correct value is 0;
#   * a qube whose feature is UNSET - which includes one the acceptance harness just created - gets
#     a true-UTC RTC -> the correct value is 1.
#
# WHY THE WITNESS MATTERS, and this is the defect this file exists for. The first version compared
# the guest's clock BEFORE the pull with its clock AFTER it and concluded "fits" whenever they
# agreed. A pull that changes nothing makes those the same number, and the script cannot see whether
# the pull did anything: qrexec hands dom0's date straight to set-time.ps1, whose exit code does not
# come back through the client. Measured on run 11, it reported "RealTimeIsUniversal=1 matches this
# qube's RTC convention" FOUR TIMES on a guest that was three hours out. A test whose reference is
# the thing under test cannot fail.
#
# So the block now reads set-time.ps1's own SETTIME line - the one component that saw dom0's value -
# which carries dom0's UTC, the pre-set skew and the guest's offset, all measured before the clock
# was touched. These cases plant that witness and assert the verdict, including the case with no
# witness at all.
#
# IT RUNS THE SHIPPED TEXT, extracted from the real file, with the registry and the log stubbed.
set -u
cd "$(dirname "$0")/../.." || exit 1
SRC=guest/sync-clock-from-dom0.ps1
PWSH=${PWSH:-$(command -v pwsh || echo /home/user/.local/pwsh/pwsh)}
pass=0; fail=0
T=$(mktemp -d "${TMPDIR:-/tmp}/clockconv.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
finish(){ echo "clock-convention-selftest: $pass passed, $fail failed"; [ "$fail" -eq 0 ]; }

[ -r "$SRC" ] || { echo "no $SRC"; exit 2; }
[ -x "$PWSH" ] || { echo "no pwsh found (tried PATH and the local tarball) - set PWSH=<path>"; exit 2; }

# ---- extract the shipped block -----------------------------------------------------------------
# From the section marker up to the `switch` that follows it, minus that line. NOT "to the first
# column-0 brace": the block contains a function whose closing brace is in column 0, and an earlier
# version of this extraction stopped there and silently tested the function alone.
awk '/^# ---- WHICH CONVENTION DOES THIS QUBE/,/^switch \(\$exit\) \{/' "$SRC" | sed '$d' > "$T/block.ps1"
blines=$(wc -l < "$T/block.ps1")
if [ "$blines" -lt 40 ]; then
  bad "could not extract the block (got $blines lines) - the markers moved"
  finish; exit $?
fi
ok "extracted the shipped CLOCKCONV block ($blines lines)"
command grep -q 'Get-ClockWitness' "$T/block.ps1" \
  && ok "the extract carries the witness reader" || bad "the extract has no witness reader - wrong region"
command grep -q "if (\$exit -eq 'set')" "$T/block.ps1" \
  && ok "and the decision itself" || bad "the extract stops before the decision - wrong region"

# ---- the harness -------------------------------------------------------------------------------
# $REAL is dom0's UTC. SkewS is (dom0 - guest_clock_before), so it is NEGATIVE when the guest ran
# ahead - the shape measured on run 11 ("was -10821.2 s out"). Offset is the guest's zone offset.
mk(){ # <cur> <body of the Get-ClockWitness stub>
  {
    printf '%s\n' \
      "\$ErrorActionPreference='Stop'" \
      "\$script:Written = 'NONE'" \
      "\$script:Log = @()" \
      "function LogInfo([string]\$m)    { \$script:Log += \"INFO  \$m\" }" \
      "function LogWarning([string]\$m) { \$script:Log += \"WARN  \$m\" }" \
      "function LogError([string]\$m)   { \$script:Log += \"ERROR \$m\" }" \
      "function Get-ItemProperty { param([string]\$LiteralPath,[string]\$Name,\$ErrorAction)" \
      "  if (\$script:Written -ne 'NONE') { return [pscustomobject]@{ RealTimeIsUniversal = \$script:Written } }" \
      "  return [pscustomobject]@{ RealTimeIsUniversal = $1 } }" \
      "function New-ItemProperty { param([string]\$LiteralPath,[string]\$Name,[string]\$PropertyType,\$Value,[switch]\$Force,\$ErrorAction)" \
      "  \$script:Written = \$Value; return \$null }" \
      "\$exit = 'set'" \
      "\$tools = '$T'" \
      "\$REAL = [datetime]::SpecifyKind([datetime]::Parse('2026-10-15T09:24:50Z').ToUniversalTime(), 'Utc')"
    # THE STUB COMES FIRST. PowerShell executes top to bottom, so a function defined after its call
    # site does not exist yet - an earlier version appended it and every case died with
    # "Get-ClockWitness is not recognized", which the catch turned into "could not decide".
    printf 'function Get-ClockWitness { %s }\n' "$2"
    # and the shipped reader is dropped, so the stub is the only definition.
    awk '/^function Get-ClockWitness \{/,/^\}$/ { next } { print }' "$T/block.ps1"
    printf '%s\n' "\"WROTE=\$script:Written\"" "\$script:Log | ForEach-Object { \"LOG=\$_\" }"
  } > "$T/run.ps1"
}
run(){ "$PWSH" -NoProfile -File "$T/run.ps1" 2>&1; }
W_AHEAD='return @{ Dom0Utc = $REAL; SkewS = -10800.0; Offset = [timespan]::FromHours(3) }'
W_BEHIND='return @{ Dom0Utc = $REAL; SkewS = 10800.0; Offset = [timespan]::FromHours(3) }'
W_JUNK='return @{ Dom0Utc = $REAL; SkewS = -21600.0; Offset = [timespan]::FromHours(3) }'
W_ZERO='return @{ Dom0Utc = $REAL; SkewS = 0.0; Offset = [timespan]::Zero }'

echo "PART A  a localtime qube (the RTC held dom0 local) must choose 0"
mk 1 "$W_AHEAD"; out=$(run)
printf '%s' "$out" | command grep -q 'WROTE=0' \
  && ok "RTIU 1 on a dom0-local RTC is corrected to 0" \
  || { bad "did not write 0 on a localtime qube"; printf '%s\n' "$out" | sed 's/^/        /' | head -8; }

echo "PART B  a feature-unset qube (the RTC held true UTC) must choose 1"
mk 0 "$W_BEHIND"; out=$(run)
printf '%s' "$out" | command grep -q 'WROTE=1' \
  && ok "RTIU 0 on a true-UTC RTC is corrected to 1" \
  || { bad "did not write 1 on a feature-unset qube"; printf '%s\n' "$out" | sed 's/^/        /' | head -8; }

echo "PART C  an RTC that fits neither convention is an anomaly, not a guess"
# Xen persists a per-VM RTC offset that the guest's own clock writes move, so a long-corrected
# subject can hold an RTC matching nothing (RTCOFFSETWRITEBACK, measured on win10-acc).
mk 1 "$W_JUNK"; out=$(run)
printf '%s' "$out" | command grep -q 'WROTE=NONE' \
  && ok "nothing is written when neither hypothesis fits" || bad "it wrote a value for an RTC that fits neither"
printf '%s' "$out" | command grep -q 'fits NEITHER convention' \
  && ok "and it says so, loudly" || bad "the anomaly is silent"
printf '%s' "$out" | command grep -q 'diagnose, do not guess' \
  && ok "and tells the reader not to guess" || bad "the anomaly message does not say what to do"

echo "PART D  a zero-offset guest has nothing to choose, and must not thrash"
mk 1 "$W_ZERO"; out=$(run)
printf '%s' "$out" | command grep -q 'WROTE=NONE' \
  && ok "no write when both conventions coincide (offset 0)" || bad "it wrote a value where there was nothing to decide"
printf '%s' "$out" | command grep -q 'same arithmetic' \
  && ok "and it says the two conventions are the same arithmetic" || bad "it does not explain the ambiguity"

echo "PART E  NO WITNESS MEANS NO DECISION - the case the old version got wrong"
mk 1 'return $null'; out=$(run)
printf '%s' "$out" | command grep -q 'WROTE=NONE' \
  && ok "no witness -> nothing is written" || bad "it decided the convention with no witness"
printf '%s' "$out" | command grep -q 'no usable SETTIME witness' \
  && ok "and it names what is missing" || bad "the missing witness is not reported"
printf '%s' "$out" | command grep -q 'exit code does not come back' \
  && ok "and says why this script cannot see dom0 time itself" || bad "it does not explain why a witness is needed"

echo "PART F  seen to fail: break the branch PART A reaches"
# An earlier version of this part mutated an arm case A never takes, so it passed while proving
# nothing. This flips the verdict case A actually reaches.
sed 's/{ \$want = 0 }/{ $want = 1 }/' "$T/block.ps1" > "$T/block.bad"
if command grep -q '{ \$want = 1 }' "$T/block.bad"; then
  cp "$T/block.ps1" "$T/block.keep"; cp "$T/block.bad" "$T/block.ps1"
  mk 1 "$W_AHEAD"; out=$(run)
  cp "$T/block.keep" "$T/block.ps1"
  printf '%s' "$out" | command grep -q 'WROTE=0' \
    && bad "the broken branch still chose 0 - PART A proves nothing" \
    || ok "breaking the chosen branch changes the verdict (PART A is real)"
else
  bad "PART F could not plant its defect - the branch text moved"
fi

finish
