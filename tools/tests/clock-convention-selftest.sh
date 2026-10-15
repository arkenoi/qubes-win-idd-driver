#!/bin/bash
# clock-convention-selftest.sh - the RTC convention is DERIVED, and the derivation must be right.
#
# WHAT IS UNDER TEST: the CLOCKCONV block in guest/sync-clock-from-dom0.ps1. RealTimeIsUniversal
# declares whether Windows reads the emulated RTC as UTC (1) or as local time (0), and only one of
# the two is true for a given qube:
#   * qubes-core-admin sets `timezone=localtime` for every os=Windows qube with qrexec, so Xen
#     presents a DOM0-LOCAL RTC -> the correct value is 0;
#   * a qube whose `timezone` feature is UNSET gets a true-UTC RTC -> the correct value is 1.
# Shipping either blind is wrong for the other case. Measured 2026-10-15: shipping 1 on a localtime
# qube put it 10800 s ahead on every boot; Jev scored the opposite default as breaking the
# feature-unset qube at 0.88. So the value is derived from dom0's real UTC, which the script has just
# pulled, and this proves the derivation on the four cases that exist.
#
# IT RUNS THE SHIPPED TEXT, not a copy of the arithmetic. The block is extracted from the real file
# and executed with stubs for the registry and the log, so a change to the shipped logic changes
# what this measures. Copying the formula into the test would have proved only that I can repeat
# myself - the trap this project has hit with offline renderers before.
#
# The guest's own UTC offset comes from [TimeZoneInfo]::Local, so each case sets TZ to choose it.
set -u
cd "$(dirname "$0")/../.." || exit 1
SRC=guest/sync-clock-from-dom0.ps1
# FIND pwsh, DO NOT HARDCODE THE DEV QUBE'S PATH. The first version pinned
# /home/user/.local/pwsh/pwsh, which is where the tarball lives on this qube and nowhere else - so
# this suite went red on its first CI run while passing locally. A GitHub runner has pwsh on PATH.
PWSH=${PWSH:-$(command -v pwsh || echo /home/user/.local/pwsh/pwsh)}
pass=0; fail=0
T=$(mktemp -d "${TMPDIR:-/tmp}/clockconv.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

[ -r "$SRC" ] || { echo "no $SRC"; exit 2; }
[ -x "$PWSH" ] || { echo "no pwsh found (tried PATH and the local tarball) - set PWSH=<path>"; exit 2; }

# ---- extract the shipped block -----------------------------------------------------------------
awk '/^if \(\$exit -eq .set.\) \{$/,/^\}$/' "$SRC" > "$T/block.ps1"
blines=$(wc -l < "$T/block.ps1")
[ "$blines" -gt 20 ] && ok "extracted the shipped CLOCKCONV block ($blines lines)" \
  || { bad "could not extract the block (got $blines lines) - the markers moved"; echo "  (cannot continue)"; echo "clock-convention-selftest: $pass passed, $fail failed"; exit 1; }
command grep -q 'CLOCKCONV' "$T/block.ps1" || bad "the extracted block carries no CLOCKCONV line - wrong region"

# ---- the harness: stubs + the shipped block ----------------------------------------------------
# $REAL is "real UTC"; each case says what the guest BELIEVED UTC was before the pull ($before) and
# what RealTimeIsUniversal currently is. The stubs record what the block writes and logs.
mk(){ # <cur> <before-expr>
  cat > "$T/run.ps1" <<EOS
\$ErrorActionPreference='Stop'
\$script:Written = 'NONE'
\$script:Log = @()
function LogInfo([string]\$m)    { \$script:Log += "INFO  \$m" }
function LogWarning([string]\$m) { \$script:Log += "WARN  \$m" }
function LogError([string]\$m)   { \$script:Log += "ERROR \$m" }
function Get-ItemProperty { param([string]\$LiteralPath,[string]\$Name,\$ErrorAction)
  if (\$script:Written -ne 'NONE') { return [pscustomobject]@{ RealTimeIsUniversal = \$script:Written } }
  return [pscustomobject]@{ RealTimeIsUniversal = $1 } }
function New-ItemProperty { param([string]\$LiteralPath,[string]\$Name,[string]\$PropertyType,\$Value,[switch]\$Force,\$ErrorAction)
  \$script:Written = \$Value; return \$null }
\$exit   = 'set'
\$REAL   = [datetime]::SpecifyKind([datetime]::Parse('2026-10-15T07:48:08Z').ToUniversalTime(), 'Utc')
\$before = $2
\$after  = \$REAL
$(cat "$T/block.ps1")
"WROTE=\$script:Written"
\$script:Log | ForEach-Object { "LOG=\$_" }
EOS
}
run(){ TZ="$1" "$PWSH" -NoProfile -File "$T/run.ps1" 2>&1; }

echo "PART A  a localtime qube (RTC holds dom0 local) must choose 0"
# Shipping 1 on such a qube is the measured defect: the guest believed UTC was real+3h.
mk 1 '$REAL.AddHours(3)'
out=$(run Europe/Sofia)
printf '%s' "$out" | command grep -q 'WROTE=0' \
  && ok "RTIU 1 on a dom0-local RTC is corrected to 0" \
  || { bad "did not write 0 on a localtime qube"; printf '%s\n' "$out" | sed 's/^/        /' | head -6; }

echo "PART B  a feature-unset qube (RTC holds true UTC) must choose 1"
# This is the case Jev scored at 0.88 as being made worse by a blind 0.
mk 0 '$REAL.AddHours(-3)'
out=$(run Europe/Sofia)
printf '%s' "$out" | command grep -q 'WROTE=1' \
  && ok "RTIU 0 on a true-UTC RTC is corrected to 1" \
  || { bad "did not write 1 on a feature-unset qube"; printf '%s\n' "$out" | sed 's/^/        /' | head -6; }

echo "PART C  an RTC that matches NEITHER convention is an anomaly, not a guess"
# Measured on win10-acc: after a correction cycle its RTC read dom0-local PLUS three hours, because
# on Xen a guest's own clock writes move a per-VM offset the toolstack persists.
mk 0 '$REAL.AddHours(3)'
out=$(run Europe/Sofia)
if printf '%s' "$out" | command grep -q 'WROTE=NONE'; then
  ok "nothing is written when neither hypothesis fits"
else
  bad "it wrote a value for an RTC that fits neither convention"
fi
printf '%s' "$out" | command grep -q 'matches NEITHER convention' \
  && ok "and it says so, loudly" || bad "the anomaly is silent"
printf '%s' "$out" | command grep -q 'diagnose, do not guess' \
  && ok "and tells the reader not to guess" || bad "the anomaly message does not say what to do"

echo "PART D  a zero-offset guest has nothing to choose, and must not thrash"
# With the guest's offset at 0 both hypotheses are the same arithmetic; writing either way on every
# boot would be a change for its own sake.
mk 0 '$REAL'
out=$(run UTC)
printf '%s' "$out" | command grep -q 'WROTE=NONE' \
  && ok "no write when both conventions coincide (offset 0)" \
  || bad "it wrote a value where there was nothing to decide"
printf '%s' "$out" | command grep -q 'matches this qube' \
  && ok "and reports the setting as already matching" || bad "no 'already matching' report"

echo "PART E  seen to fail: break the inversion and PART A must stop passing"
# IT MUST BREAK SOMETHING PART A ACTUALLY DEPENDS ON. The first version of this mutated the
# `else { $before + $off }` arm of the RTC reconstruction - which case A never takes, because for
# cur=1 the correct expression IS $before. The mutation was a no-op and this part passed while
# proving nothing, which is the exact failure mode it exists to catch. It now flips the verdict that
# case A reaches: the localtime branch choosing 0.
sed 's/{ \$want = 0 }/{ $want = 1 }/' "$T/block.ps1" > "$T/block.bad"
command grep -q '$want = 1 }' "$T/block.bad" || bad "PART E could not plant its defect - the branch text moved"
cp "$T/block.ps1" "$T/block.keep"; cp "$T/block.bad" "$T/block.ps1"
mk 1 '$REAL.AddHours(3)'
out=$(run Europe/Sofia)
cp "$T/block.keep" "$T/block.ps1"
# With the inversion broken the localtime case can no longer be identified as such.
printf '%s' "$out" | command grep -q 'WROTE=0' \
  && bad "the broken inversion still chose 0 - PART A proves nothing" \
  || ok "a broken inversion changes the verdict (PART A is real)"

echo "clock-convention-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
