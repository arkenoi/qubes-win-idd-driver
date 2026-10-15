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
command grep -q 'function Wait-ClockWitness' "$T/block.ps1" \
  && ok "and the bounded wait" || bad "the extract has no bounded wait - wrong region"
command grep -q '\$w = Wait-ClockWitness' "$T/block.ps1" \
  && ok "and the decision reads the witness THROUGH the wait" \
  || bad "the decision calls the reader directly - the fire-and-forget race is back"
command grep -q "if (\$exit -eq 'set')" "$T/block.ps1" \
  && ok "and the decision itself" || bad "the extract stops before the decision - wrong region"

# ---- the harness -------------------------------------------------------------------------------
# $REAL is dom0's UTC. SkewS is (dom0 - guest_clock_before), so it is NEGATIVE when the guest ran
# ahead - the shape measured on run 11 ("was -10821.2 s out"). Offset is the guest's zone offset.
mk(){ # <cur> <body of the Wait-ClockWitness stub>
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
    printf 'function Wait-ClockWitness { %s }\n' "$2"
    # and BOTH shipped functions are dropped, so the stub is the only definition. The decision
    # reads its witness through Wait-ClockWitness, so THAT is what these cases stub: each one plants
    # a witness and asserts the verdict, with no log files and no waiting. The wait and the reader
    # are real code with their own cases (PART H and PART I), where their behaviour IS the subject.
    awk '/^function (Get|Wait)-ClockWitness \{/,/^\}$/ { next } { print }' "$T/block.ps1"
    printf '%s\n' "\"WROTE=\$script:Written\"" "\$script:Log | ForEach-Object { \"LOG=\$_\" }"
  } > "$T/run.ps1"
}
# TZ CHOOSES THE EFFECTIVE OFFSET, because the block derives it from [TimeZoneInfo]::Local rather
# than trusting the witness's field - the witness logs the zone's BASE offset, which for FLE is
# 02:00:00 all year while the offset in effect under DST is 03:00:00. Europe/Sofia on the test date
# (2026-10-15) is in DST, so +03:00.
run(){ TZ="${1:-Europe/Sofia}" "$PWSH" -NoProfile -File "$T/run.ps1" 2>&1; }
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
mk 1 "$W_ZERO"; out=$(run UTC)
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

echo "PART F  the EFFECTIVE offset is used, not the zone's base offset"
# THE DEFECT THIS CATCHES, measured on run 12's first cell. set-time.ps1 logs
# `(Get-TimeZone).BaseUtcOffset` - 02:00:00 for FLE Standard Time, all year - while the offset in
# effect under DST is 03:00:00. Using the base value made a real three-hour displacement match
# NEITHER hypothesis, so the convention was never flipped and the guest kept needing a correction:
# "the RTC fits NEITHER convention unambiguously: it held 13:34:15Z, dom0 said 10:34:06Z, this
# guest's offset is 02:00:00". The witness still REPORTS the base offset; the block must ignore it.
mk 1 'return @{ Dom0Utc = $REAL; SkewS = -10800.0; Offset = [timespan]::FromHours(2) }'
out=$(run Europe/Sofia)
printf '%s' "$out" | command grep -q 'WROTE=0' \
  && ok "a witness reporting the BASE offset still resolves, using the effective one" \
  || { bad "the base offset was used - a DST displacement resolves to neither convention"; printf '%s\n' "$out" | sed 's/^/        /' | head -6; }
printf '%s' "$out" | command grep -q "the zone's base is" \
  && ok "and the line reports both offsets, so the two can never be confused again" \
  || bad "the message does not distinguish the effective offset from the base"

# ---- the REAL wait, on planted log files -------------------------------------------------------
# A runner that keeps BOTH shipped functions and gives them a log directory to read.
wait_case(){ # <settime line> <extra args to Wait-ClockWitness>
  rm -rf "$T/log"; mkdir -p "$T/log"
  printf '%s\n' "$1" > "$T/log/set-time.ps1-a.log"
  {
    printf '%s\n' "\$ErrorActionPreference='Stop'" \
      "\$script:Log = @()" \
      "function LogWarning([string]\$m) { \$script:Log += \$m }" \
      "function Get-ItemProperty { param([string]\$LiteralPath,[string]\$Name,\$ErrorAction) return [pscustomobject]@{} }" \
      "\$tools = '$T'"
    awk '/^function (Get|Wait)-ClockWitness \{/,/^\}$/' "$T/block.ps1"
    printf '%s\n' "\$w = Wait-ClockWitness $2" \
      "if (\$null -eq \$w) { 'GOT=NONE' } else { \"GOT=\" + \$w.Dom0Utc.ToString('o') }" \
      "\$script:Log | ForEach-Object { \"LOG=\$_\" }"
  } > "$T/wait.ps1"
  "$PWSH" -NoProfile -File "$T/wait.ps1" 2>&1
}
NOWZ=$(date -u '+%Y-%m-%dT%H:%M:%S.0000000Z')

echo "PART H  the bounded wait: a witness from an EARLIER boot is stale and is NOT used"
# THE DEFECT IT EXISTS FOR: the pull is fire-and-forget - the qrexec client writes the request and
# exits while a SEPARATE set-time.ps1 process writes the line - so reading the log straight afterwards
# finds the PREVIOUS boot's line, or nothing. Measured on run 13 cell 1: CLOCKCONV refused at
# 14:18:14.479 while the line it needed was written at 14:18:14.305, 174 ms earlier
# (CLOCKWITNESSMISSEDONFIRSTBOOT). Taking the stale line instead would decide this boot's convention
# from the PREVIOUS boot's RTC - the one outcome worse than not deciding.
out=$(wait_case 'SETTIME clock set to 2020-01-01T00:00:00.0000000Z (was -1.0 s out, now 0 s; guest zone FLE Standard Time, offset 02:00:00)' '-TimeoutSeconds 0')
printf '%s' "$out" | command grep -q 'GOT=NONE' \
  && ok "a stale witness is refused" || { bad "the wait returned a stale witness"; printf '%s\n' "$out" | sed 's/^/        /' | head -5; }
printf '%s' "$out" | command grep -q 'from an earlier boot' \
  && ok "and it says so, with both timestamps" || bad "the stale witness is silent"
printf '%s' "$out" | command grep -q 'did not arrive' \
  && ok "and distinguishes stale from never-written" || bad "stale and absent are conflated"

echo "PART H2  a witness from THIS boot is accepted"
out=$(wait_case "SETTIME clock set to $NOWZ (was -1.0 s out, now 0 s; guest zone FLE Standard Time, offset 02:00:00)" '-TimeoutSeconds 0')
printf '%s' "$out" | command grep -q 'GOT=' && printf '%s' "$out" | command grep -qv 'GOT=NONE' \
  && ok "a fresh witness is returned" || { bad "the wait refused a witness from this boot"; printf '%s\n' "$out" | sed 's/^/        /' | head -5; }

echo "PART J  the wait's BOUND is monotonic - a clock that jumps back mid-wait must not hang it"
# THE FRAGILE MOMENT, NAMED BY THE OWNER: this wait exists to span the instant set-time.ps1 sets the
# clock, and a correction of dom0's offset is a BACKWARD jump of hours (10800 s, measured). A
# wall-clock bound - `$deadline = (Get-Date).AddSeconds(n)` compared against `Get-Date` - is then
# unreachable for that whole offset, so the boot hangs in the one place a hang is least acceptable:
# while the agents are coming up. Stopwatch is QueryPerformanceCounter and a clock set cannot move
# it. This stub hands out the real time ONCE (so any deadline is computed from it) and three hours
# EARLIER on every call after that, which is exactly the shape of the correction.
rm -rf "$T/log"; mkdir -p "$T/log"
printf 'SETTIME clock set to 2020-01-01T00:00:00.0000000Z (was -1.0 s out, now 0 s; guest zone FLE Standard Time, offset 02:00:00)\n' > "$T/log/set-time.ps1-a.log"
{
  printf '%s\n' "\$ErrorActionPreference='Stop'" \
    "function LogWarning([string]\$m) { }" \
    "function Get-ItemProperty { param([string]\$LiteralPath,[string]\$Name,\$ErrorAction) return [pscustomobject]@{} }" \
    "\$tools = '$T'" \
    "\$script:n = 0" \
    "\$script:t0 = [datetime]::Now" \
    "function Get-Date { \$script:n++; if (\$script:n -le 1) { return \$script:t0 } return \$script:t0.AddHours(-3) }"
  awk '/^function (Get|Wait)-ClockWitness \{/,/^\}$/' "$T/block.ps1"
  printf '%s\n' "\$null = Wait-ClockWitness -TimeoutSeconds 2" "'RETURNED'"
} > "$T/jump.ps1"
# 25 s is far longer than the 2 s bound and far shorter than the 3 h a wall-clock bound would wait.
if jout=$(timeout 25 "$PWSH" -NoProfile -File "$T/jump.ps1" 2>&1) && printf '%s' "$jout" | command grep -q 'RETURNED'; then
  ok "the wait returns under a backward clock jump (the bound is monotonic)"
else
  bad "the wait did NOT return under a backward clock jump - the bound is on the wall clock, so a correction hangs the boot"
  printf '%s\n' "$jout" | sed 's/^/        /' | head -5
fi

echo "PART I  the REAL reader picks the newest line BY CONTENT, not by file order"
# THE DEFECT: the reader sorted the log files by LastWriteTime DESCENDING and then took the last
# match the pipeline emitted - which is the newest line of the OLDEST file. It also anchored
# freshness on guest file mtimes, which this very script moves backwards by hours. Here the OLDER
# file is given the NEWER mtime, so file order and content disagree and only content is right.
rm -rf "$T/log"; mkdir -p "$T/log"
printf 'SETTIME clock set to 2026-10-15T06:00:00.0000000Z (was -1.0 s out, now 0 s; guest zone FLE Standard Time, offset 02:00:00)\n' > "$T/log/set-time.ps1-old.log"
printf 'SETTIME clock set to 2026-10-15T09:24:50.0000000Z (was -2.0 s out, now 0 s; guest zone FLE Standard Time, offset 02:00:00)\n' > "$T/log/set-time.ps1-new.log"
touch -d '2020-01-01' "$T/log/set-time.ps1-new.log"   # the line we WANT, in the file with the OLDEST mtime
{
  printf '%s\n' "\$ErrorActionPreference='Stop'" \
    "function LogWarning([string]\$m) { }" \
    "function Get-ItemProperty { param([string]\$LiteralPath,[string]\$Name,\$ErrorAction) return [pscustomobject]@{} }" \
    "\$tools = '$T'"
  awk "/^function Get-ClockWitness \\{/,/^\\}$/" "$T/block.ps1"
  printf '%s\n' "\$w = Get-ClockWitness" "if (\$null -eq \$w) { 'PICKED=NONE' } else { \"PICKED=\" + \$w.Dom0Utc.ToString('o') }"
} > "$T/reader.ps1"
rout=$("$PWSH" -NoProfile -File "$T/reader.ps1" 2>&1)
printf '%s' "$rout" | command grep -q 'PICKED=2026-10-15T09:24:50' \
  && ok "the newest line wins even when its file has the oldest mtime" \
  || { bad "the reader picked by file order, not content"; printf '%s\n' "$rout" | sed 's/^/        /' | head -6; }

echo "PART K  a ZONE mismatch is named as one, not reported as a convention problem"
# THE CASE THE OWNER NAMED: "guest may choose its time zone only if its rtc is utc. if it is
# localtime, tz is propagated with it." A localtime RTC carries no zone label, so
# guest_UTC - real_UTC = dom0_offset - guest_offset, for ever, and no RealTimeIsUniversal value
# fixes it. The detector already lands such a guest in the fits-NEITHER branch - `fitsLocal` tests
# |dom0_offset - guest_offset| < tol, which is exactly this mismatch - but it USED to report only
# "fits neither convention", which reads like a convention problem and sends the reader to the
# wrong fix. Here dom0's offset is 2 h while the guest sits on Europe/Sofia (+3 h in October).
W_ZONE='return @{ Dom0Utc = $REAL; SkewS = 3600.0; Offset = [timespan]::FromHours(2) }'
mk 0 "$W_ZONE"; out=$(run Europe/Sofia)
printf '%s' "$out" | command grep -q 'WROTE=NONE' \
  && ok "nothing is written for a zone mismatch" \
  || { bad "it wrote a convention value for what is a zone difference"; printf '%s\n' "$out" | sed 's/^/        /' | head -6; }
printf '%s' "$out" | command grep -q 'ZONE MISMATCH AND NOT' \
  && ok "and it is named as a zone mismatch" || bad "the zone mismatch is still reported as a convention problem"
printf '%s' "$out" | command grep -q 'propagates dom0' \
  && ok "and says the zone is propagated, not chosen" || bad "it does not explain why the guest cannot choose"
printf '%s' "$out" | command grep -q 'timezone utc' \
  && ok "and names the configuration that frees the zone" || bad "it does not name the fix"

echo "PART G  seen to fail: break the branch PART A reaches"
# An earlier version of this part mutated an arm case A never takes, so it passed while proving
# nothing. This flips the verdict case A actually reaches.
sed 's/{ \$want = 0 }/{ $want = 1 }/' "$T/block.ps1" > "$T/block.bad"
if command grep -q '{ \$want = 1 }' "$T/block.bad"; then
  cp "$T/block.ps1" "$T/block.keep"; cp "$T/block.bad" "$T/block.ps1"
  mk 1 "$W_AHEAD"; out=$(run)
  cp "$T/block.keep" "$T/block.ps1"
  printf '%s' "$out" | command grep -q 'WROTE=0' \
    && bad "the broken branch still chose 0 - PART A proves nothing (G)" \
    || ok "breaking the chosen branch changes the verdict (PART A is real)"
else
  bad "PART G could not plant its defect - the branch text moved"
fi

finish
