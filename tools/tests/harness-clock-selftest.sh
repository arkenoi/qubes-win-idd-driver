#!/bin/bash
# harness-clock-selftest.sh - ONE CLOCK ON THE HOST SIDE, AND EVERY CAMPAIGN LOG SAYS WHICH.
#
# WHY. Run 8 (2026-10-15, ~/qwt-accept/rel-38629737763-campaign-STOPPED-logvolbind-run8) carried
# three clocks in ONE matrix.log: matrix.sh's own `date` (dom0 local, until ecf4d904 on 10-16),
# accept-clean's `date -u` quoted INSIDE the same line -
#   [02:04:41]   WIN10-clean: accept-clean says: 23:04:41 accept[win10-acc]: ACCEPT=FAIL ...
# - and arm-module-bases' UTC "[23:02:30] ARMED AND PROVEN" under the "[01:50:22] pool:" header.
# The guest stamps GUEST-LOCAL (the sweep's BEGIN line: `tz=+00:00` on win10-acc, `tz=+03:00` on
# win11de-tup). On 2026-10-19 that pair turned a stick file created 42 s BEFORE a bind (guest name
# 050014 at +03:00 = 02:00:14Z; the bind logged `02:00:56 ... QWT logs bound` in UTC) into "three
# hours later" and a false claim of a live write (findings/issues.md AUTOPLAYTOASTTIMESTHESHELL,
# corrected). A number whose unit is not written down is not evidence (CAMPAIGNLOGTZSPLIT).
#
# THE FIX HOLDS TWO THINGS AND MOVES NO ANCHORED FIELD. Every host-side `date` stamp in the harness
# dirs is `date -u` - a VALUE change: the `[HH:MM:SS] ` and `HH:MM:SS name[x]: ` shapes that
# tools/sweep-gate.sh:143 and :364 anchor on are byte-for-byte the same. And the four loggers whose
# files the sweep reads (matrix.sh say, quick-upgrade.sh log, accept-clean.sh log,
# release-acceptance.sh say) write a `clock:` line FIRST, through their own logger, so it carries a
# level and names the zone in words, with the full UTC date-time and the host's local offset so a
# reader can convert any other stamp against it.
#
# CONSUMERS OF THE TOUCHED LINES, each re-matched here or shown unaffected:
#   tools/sweep-gate.sh:143   strips `^\[?HH:MM:SS\]?` before normalising      -> T3 (real tool)
#   tools/sweep-gate.sh:364   coverage census on the two logger shapes         -> T3 (real tool)
#   tools/sweep-gate.sh       level regex: the header is [INFO], never E/W     -> T3 (real tool)
#   tools/tests/sweep-gate-selftest.sh:485,:591  sed ranges `say(){` .. `tee -a` -> T4 (must end
#                             before the header, or T22a/T24 would eval it)
#   tools/stall-reference.py:34-35, tools/stall-matrix.py:60  `^(\d\d:\d\d:\d\d) ` on
#                             quick-upgrade lines anchored on `run marker` / `install.cmd` text
#                             the header does not contain; shape unchanged            -> T3c
#   tools/record-acceptance.sh:61 / acceptance-record-check.py  read only the `=== MATRIX:`
#                             footer of feature-*.out; the `cells:` stamp beside it is unparsed
#                             (the record selftest's fixture carries no stamp at all)
#
# EVERY CHECK HAS BEEN SEEN TO FAIL: T1 against the thirteen pre-fix lines quoted verbatim, T2
# against a logger with no header and one whose stamp is local while its words say UTC, T3 against a
# header carrying no level. And on 2026-10-19 this whole file was run against the UNFIXED tree first
# (T1 x13 local stamps, T2 four loggers without a header).
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/harness-clock-selftest.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

# ---- T1: ONE CONVENTION - every host-side stamp is `date -u` ---------------------------------------
# A LOCAL STAMP is a `$(date ...)` (or backtick) whose format names a clock or calendar field and
# carries no -u. `%s` is an epoch and `%z`/`%:z` IS the zone, so neither is a stamp. tools/tests is
# excluded because its fixtures (this file included) quote the defect on purpose.
SCOPE=( mgmt/harness/*.sh tools/*.sh .claude/skills/win-guest-e2e/*.sh )
_rx=$'(\\$\\(|`)date( -u)? (\'\\+|"\\+|\\+)[^\'")`]*'
local_stamps(){ # $@ files -> one "file:line:call" per local-clock stamp
  local f
  for f in "$@"; do
    grep -naoE "$_rx" "$f" 2>/dev/null \
      | grep -avE 'date -u ' \
      | grep -avE $'date [\'"]?\\+%(s(%[0-9]*N)?|:?z)[\'"]?$' \
      | sed "s|^|$f:|"
  done; return 0; }

hits=$(local_stamps "${SCOPE[@]}")
if [ -z "$hits" ]; then ok "T1a no host-side stamp in ${#SCOPE[@]} harness files reads the local clock"
else no "T1a $(printf '%s\n' "$hits" | grep -c .) host-side stamp(s) still read the LOCAL clock" "$(printf '%s\n' "$hits" | head -14)"; fi

# (b) SEEN TO FAIL: the thirteen lines exactly as they stood before the fix (2026-10-19), one file.
cat > "$T/prefix.sh" <<'EOF'
say(){ echo "[$(date +%H:%M:%S)] chain[$VM]: $*"; }
OUT="${3:-evidence/accept-$VM-$(date +%Y%m%d-%H%M%S)}"
  echo "[$(date +%H:%M:%S)] [shot] $lbl: $SNAP_STATE $SNAP_N png ${d}  (READ e2e-$lbl-ex/*.png)" >> "$R"; }
OUT=${OUT:-$HOME/qwt-burst-quiet/$VM-$VARIANT-$(date +%Y%m%d-%H%M%S)}
log(){ echo "$(date +%H:%M:%S) bq[$VM]: $*" | tee -a "$LOG"; }
  start=$(date +%H:%M:%S)
log(){ echo "[$(date +%H:%M:%S)] seal-qwt-golden: $*"; }
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$R"; }
    { echo "[$(date +%T)]   cells: feature-$t"
      [ $rc -eq 2 ] && echo "[$(date +%T)]   INSTRUMENT: feature-$t could not measure the product (rc=2); the run fails, the product is not implicated"
OUT="${WEDGE_OUT:-$REPO/evidence/wedge-hunt-$(date +%Y%m%d-%H%M%S)}"
log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/hunt.log"; }
          { echo "# captured $(date '+%Y-%m-%d %H:%M:%S') at t+${now}s"; cat "$dir/$lbl-shutdown-events.txt.new"; } \
EOF
n=$(local_stamps "$T/prefix.sh" | grep -c .)
if [ "$n" = 13 ]; then ok "T1b the scanner flags all 13 pre-fix lines (seen to fail)"
else no "T1b the scanner found $n of the 13 pre-fix local stamps" "$(local_stamps "$T/prefix.sh" | head -3)"; fi

# (c) PRECISION: UTC stamps, epochs and the zone itself are not findings.
cat > "$T/clean.sh" <<'EOF'
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$R"; }
log(){ printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
t0=$(date +%s); el=$(( $(date +%s) - t0 ))
_clk_loc=$(date +%:z); _z=$(date +%z); ms=$(date +%s%3N)
OUT="$HOME/x/$(date -u +%Y%m%dT%H%M%SZ)"; M="$(date -u +%Y%m%d-%H%M%S)"
EOF
n=$(local_stamps "$T/clean.sh" | grep -c .)
if [ "$n" = 0 ]; then ok "T1c UTC stamps, epochs and %z are not flagged"
else no "T1c $n false finding(s) on UTC/epoch/zone forms" "$(local_stamps "$T/clean.sh" | head -3)"; fi

# ---- T2: THE ZONE IS DECLARED FIRST, BY THE REAL LOGGER ----------------------------------------------
# The logger definition is extracted THROUGH its header line and run with the log path pointed at a
# temp file; the property is read off that file, never off the prose. A source with no header line
# is REFUSED before any eval: sed's range would otherwise run to end-of-file, i.e. the campaign.
emit_header(){ # $1 src $2 start-rx $3 header-rx $4 outfile, then VAR=val... for the logger
  local src=$1 start=$2 hdr=$3 out=$4 blk; shift 4
  grep -qE "$hdr" "$src" || return 2
  blk=$(sed -n "/${start}/,/${hdr}/p" "$src")     # sliced HERE, before the cd: the path is relative
  ( cd "$T" && env "$@" bash -c "$blk" ) >/dev/null 2>&1
  [ -s "$out" ]; }
# THE PROPERTY: the FIRST line is the declaration - in the logger's own stamp shape (so every reader
# anchored on it still matches), with a declared level (so the sweep counts it), the word UTC, a
# full UTC date-time, a stamp that AGREES with that date-time to the second (UTC in fact, not only in
# words), and the guest side named as guest-local.
assert_header(){ # $1 file $2 stamp-shape-rx -> 0 holds, 1 does not
  local l iso st a b d; l=$(head -1 "$1")
  grep -qE "^${2}\[INFO\] clock: " <<<"$l" || return 1
  grep -qE 'are UTC \(' <<<"$l" || return 1
  iso=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' <<<"$l" | head -1); [ -n "$iso" ] || return 1
  st=$(grep -oE '^\[?[0-9]{2}:[0-9]{2}:[0-9]{2}' <<<"$l" | tr -d '['); [ -n "$st" ] || return 1
  a=$(date -u -d "1970-01-01T${st}Z" +%s) || return 1
  b=$(( $(date -u -d "$iso" +%s) % 86400 ))
  d=$(( a - b )); d=${d#-}; { [ "$d" -le 2 ] || [ "$d" -ge 86398 ]; } || return 1
  grep -qE 'guest-local' <<<"$l"; }

MX='\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] '                              # matrix.sh / release-acceptance.sh
QU='[0-9]{2}:[0-9]{2}:[0-9]{2} quick-upgrade\[[^]]*\]: '          # quick-upgrade.sh
AC='[0-9]{2}:[0-9]{2}:[0-9]{2} accept\[[^]]*\]: '                 # accept-clean.sh
t2(){ # $1 label $2 src $3 start $4 hdr $5 out $6 shape, then env
  local lbl=$1 src=$2 start=$3 hdr=$4 out=$5 shape=$6; shift 6
  : > "$out"
  emit_header "$src" "$start" "$hdr" "$out" "$@"; local r=$?
  if [ "$r" -ne 0 ]; then
    case $r in 2) no "T2 $lbl declares no zone (no \`$hdr\` line after its logger)" "$src";;
               *) no "T2 $lbl header block ran but wrote nothing" "$src";; esac; return; fi
  if assert_header "$out" "$shape"; then ok "T2 $lbl: first line declares UTC, in its own shape, stamp agreeing: $(head -1 "$out" | cut -c1-96)"
  else no "T2 $lbl first line is not a sound zone declaration" "$(head -1 "$out" | cut -c1-140)"; fi; }
t2 "matrix.sh say"              mgmt/harness/matrix.sh        '^say(){ case' '^say "clock:' "$T/hdr-matrix.log" "$MX" R="$T/hdr-matrix.log"
t2 "quick-upgrade.sh log"       mgmt/harness/quick-upgrade.sh '^log(){ _lv=' '^log "clock:' "$T/hdr-qu.log"     "$QU" R="$T/hdr-qu.log" SUBJECT=win11-x
t2 "accept-clean.sh log"        tools/accept-clean.sh         '^log() { case' '^log "clock:' "$T/accept.log"    "$AC" OUT="$T" VM=win10-x
t2 "release-acceptance.sh say"  tools/release-acceptance.sh   '^say(){ case' '^say "clock:' "$T/hdr-ra.log"     "$MX" LOG="$T/hdr-ra.log"

# (neg 1) SEEN TO FAIL: a logger with no header is refused, not eval'd.
printf 'say(){ echo "[$(date -u +%%H:%%M:%%S)] [INFO] $*" | tee -a "$R"; }\nPASS=0\n' > "$T/nohdr.sh"
emit_header "$T/nohdr.sh" '^say(){' '^say "clock:' "$T/nohdr.log" R="$T/nohdr.log"; r=$?
if [ "$r" = 2 ]; then ok "T2n1 a logger without a header is refused before any eval (seen to fail)"
else no "T2n1 a header-less logger was not refused (rc=$r)" "$(cat "$T/nohdr.log" 2>/dev/null | head -2)"; fi
# (neg 2) SEEN TO FAIL: the words say UTC while the stamp is local. TZ is forced to a fixed +03:00
# zone so this fails on a UTC-configured runner too, not only on this +0300 qube.
cat > "$T/wrongzone.sh" <<'EOF'
say(){ echo "[$(date +%H:%M:%S)] [INFO] $*" | tee -a "$R"; }
_clk_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ); _clk_loc=$(date +%:z)
say "clock: stamps here are UTC ($_clk_utc; host local is UTC$_clk_loc); guest log stamps and file names are guest-local - convert before comparing"
EOF
: > "$T/wrongzone.log"
if emit_header "$T/wrongzone.sh" '^say(){' '^say "clock:' "$T/wrongzone.log" R="$T/wrongzone.log" TZ=Asia/Baghdad \
   && ! assert_header "$T/wrongzone.log" "$MX"; then ok "T2n2 a header whose stamp disagrees with its own UTC date-time is rejected (seen to fail)"
else no "T2n2 a local stamp under UTC words passed" "$(head -1 "$T/wrongzone.log")"; fi
# (neg 3) SEEN TO FAIL: the right stamp, the wrong words.
sed 's/are UTC (/are local (/' "$T/wrongzone.sh" | sed 's/date +%H:%M:%S/date -u +%H:%M:%S/' > "$T/wrongwords.sh"
: > "$T/wrongwords.log"
if emit_header "$T/wrongwords.sh" '^say(){' '^say "clock:' "$T/wrongwords.log" R="$T/wrongwords.log" \
   && ! assert_header "$T/wrongwords.log" "$MX"; then ok "T2n3 a header that does not say UTC is rejected (seen to fail)"
else no "T2n3 a header without the zone in words passed" "$(head -1 "$T/wrongwords.log")"; fi

# ---- T3: THE READERS STILL MATCH - the real sweep-gate over logs that start with the headers ------
if [ -s "$T/hdr-matrix.log" ] && [ -s "$T/hdr-qu.log" ]; then
  printf '# empty ledger for harness-clock-selftest\n' > "$T/ledger.txt"
  { cat "$T/hdr-matrix.log"
    printf '[12:00:01] [INFO]   WIN10-clean: QWT logs bound to the log volume\n'
    printf '[12:00:02]   WIN11-upgrade: [WARN] log-volume bind failed (see /tmp/x/WIN11-upgrade-logvol-bind.out) - logs stay on C: and a wedge loses them\n'
    printf '[12:00:03] [ERROR] FAIL  WIN10-clean: a graded product check\n'
  } > "$T/matrix.log"
  { cat "$T/hdr-qu.log"
    printf '12:00:04 quick-upgrade[win11-x]: [ERROR] FAIL  the installer exited 1\n'
    printf '12:00:05 quick-upgrade[win11-x]: [INFO] run marker E2EMARK-20261019120005-1\n'
  } > "$T/quick-upgrade.log"
  out=$(SWEEP_GATE_LEDGER="$T/ledger.txt" bash tools/sweep-gate.sh "$T/matrix.log" "$T/quick-upgrade.log" 2>&1); rc=$?
  if [ "$rc" = 1 ] && grep -qaE 'SWEEP-GATE-RESULT unaccounted=3 ' <<<"$out"; then
    ok "T3a the gate still surfaces the WARN and both FAIL lines under the headers (unaccounted=3, rc=1)"
  else no "T3a the gate's reading changed (rc=$rc)" "$(grep -a 'SWEEP-GATE-RESULT' <<<"$out" | head -2)"; fi
  if ! grep -qa 'undeclared_ours' <<<"$out" && grep -qaE 'SWEEP-GATE-COVERAGE .* without=0( |$)' <<<"$out"; then
    ok "T3b both headers count as DECLARED lines in the coverage census ($(grep -ao 'SWEEP-GATE-COVERAGE[^\n]*' <<<"$out" | head -1 | cut -c1-80))"
  else no "T3b a header was read as an undeclared line of ours" "$(grep -a 'undeclared_ours\|SWEEP-GATE-COVERAGE' <<<"$out" | head -2)"; fi
  if ! grep -a '^  UNACCOUNTED' <<<"$out" | grep -qa 'clock:'; then ok "T3c no header surfaces as a finding"
  else no "T3c a clock header surfaced as an unaccounted error" "$(grep -a 'clock:' <<<"$out" | head -2)"; fi
  ng=$(grep -acE '^  UNACCOUNTED .*\[(ERROR|WARN)\] FAIL +' <<<"$out" || true)
  if [ "${ng:-0}" = 2 ]; then ok "T3d matrix.sh's graded-verdict discount still finds both FAIL rows under a header"
  else no "T3d the graded-verdict rows changed (got $ng, want 2)" "$(grep -a 'UNACCOUNTED' <<<"$out" | head -4)"; fi
  # a ledger seeded from these very logs, each row given a REASON (the seeder writes `# TODO`, which
  # the gate rightly refuses as an account), dispositions the three E/W lines - and the headers add
  # no row of their own, so the run is clean
  bash tools/sweep-gate.sh --write-ledger "$T/seeded.txt" "$T/matrix.log" "$T/quick-upgrade.log" >/dev/null 2>&1
  sed -i 's/   # TODO:.*$/   # harness-clock-selftest fixture line, dispositioned for T3e/' "$T/seeded.txt"
  out2=$(SWEEP_GATE_LEDGER="$T/seeded.txt" bash tools/sweep-gate.sh "$T/matrix.log" "$T/quick-upgrade.log" 2>&1); rc2=$?
  if [ "$rc2" = 0 ]; then ok "T3e with the E/W lines ledgered the run is clean - the headers introduce no row (rc=0)"
  else no "T3e a clean run with headers is not clean (rc=$rc2)" "$(grep -a 'UNACCOUNTED\|undeclared\|SWEEP-GATE-RESULT' <<<"$out2" | head -3)"; fi
  # (neg) SEEN TO FAIL: the same header with NO level is exactly an undeclared line of ours.
  { printf '[12:00:00] clock: stamps here are UTC (2026-10-19T12:00:00Z; host local is UTC+03:00); guest log stamps and file names are guest-local\n'
    tail -n +2 "$T/matrix.log"; } > "$T/matrix-nolevel.log"
  out3=$(SWEEP_GATE_LEDGER="$T/ledger.txt" bash tools/sweep-gate.sh "$T/matrix-nolevel.log" 2>&1)
  if grep -qa 'undeclared_ours=1' <<<"$out3"; then ok "T3n a level-less header is counted undeclared by the gate (seen to fail)"
  else no "T3n the coverage census did not see a level-less header" "$(grep -a 'SWEEP-GATE-RESULT\|COVERAGE' <<<"$out3" | head -2)"; fi
else
  no "T3 skipped: no real header to feed the gate (T2 failed first)" "fix T2"
fi

# ---- T4: the test-suite consumers that slice the SOURCE end before the header ----------------------
for f in tools/release-acceptance.sh mgmt/harness/matrix.sh; do
  blk=$(sed -n '/^say(){/,/tee -a/p' "$f")
  if [ -n "$blk" ] && grep -qa 'tee -a' <<<"$(tail -1 <<<"$blk")" && ! grep -qa 'clock:' <<<"$blk"; then
    ok "T4 sweep-gate-selftest's say() slice of $(basename "$f") ends at tee -a, before the header"
  else no "T4 the say() slice of $(basename "$f") would carry the header into T22a/T24's eval" "$(tail -2 <<<"$blk")"; fi
done

echo
echo "harness-clock-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
