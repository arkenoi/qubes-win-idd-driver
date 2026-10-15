#!/bin/bash
# goal-meter.sh - meter the release goal's two clauses against a campaign, with the evidence.
#
#   tools/goal-meter.sh [<campaign matrix dir>]
#
# THE GOAL, verbatim: "next release passed acceptance test. qrexec behavior is aligned with dom0
# callers: updaters and start menu, from cold qube as well."
#
# WHY A TOOL AND NOT A READING. Both clauses have been reported closed from a glance at a log more
# than once in this project, and both times the glance was reading one line out of a run that had
# failed elsewhere - "one green run is not a green sha" is the same mistake in CI form. This reads
# the campaign's own artefacts and names every cell that does not meet the clause, so the verdict
# cannot be produced by looking at the part that passed.
#
# MISSING DATA FAILS. A cell with no sweep output has not passed its sweep; a cell whose guest never
# answered has not had its callers measured. Both are reported as NOT MET, never skipped - a check
# that cannot see its subject must not report on it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

M="${1:-}"
if [ -z "$M" ]; then
  M=$(ls -1dt /home/user/qwt-accept/rel-*/campaign/matrix 2>/dev/null | head -1)
fi
[ -n "$M" ] && [ -d "$M" ] || { echo "goal-meter: no campaign matrix dir (pass one, or run a campaign first)"; exit 2; }
LOG="$M/matrix.log"
[ -r "$LOG" ] || { echo "goal-meter: $LOG is not readable"; exit 2; }

echo "goal-meter: $M"
echo

# ---- the cells the campaign was asked to run ---------------------------------------------------
# THE LABEL IS MIXED CASE AND BOTH FORMS ARE NEEDED. The log writes `CELL WIN10-clean` - OS part
# upper, rest lower - and uses that verbatim on its PASS/FAIL lines, while the sweep artefacts are
# named all-lower (win10-clean-logsweep.out). An earlier version upper-cased the whole label to
# match the log and reported every battery as ABSENT on a campaign where all of them had passed.
labels=$(command grep -aoE '######## CELL [A-Za-z0-9-]+' "$LOG" | cut -d' ' -f3 | sort -u)
cells=$(printf '%s\n' "$labels" | tr 'A-Z' 'a-z' | sort -u)
nc=$(printf '%s\n' "$cells" | command grep -c . || true)
echo "CELLS STARTED: $nc"
printf '%s\n' "$cells" | sed 's/^/  /'
echo

footer=$(command grep -a '=== MATRIX:' "$LOG" | tail -1)
echo "FOOTER: ${footer:-<none - the campaign did not finish>}"
echo

# ---- CLAUSE 1: acceptance passed ---------------------------------------------------------------
echo "---- CLAUSE 1: the release passed acceptance ----"
c1=0
for c in $cells; do
  # the log's own label for this cell, verbatim
  u=$(printf '%s\n' $labels | command grep -ix "$c" | head -1)
  [ -n "$u" ] || u="$c"
  bat=$(command grep -a "$u: accept-.* battery" "$LOG" | tail -1)
  case "$bat" in
    *"battery PASS"*) bverd="PASS" ;;
    *"battery FAILED"*) bverd="FAIL" ;;
    *) bverd="ABSENT" ;;
  esac
  sw="$M/$c-logsweep.out"
  if [ -s "$sw" ]; then
    br=$(sed -n '/^BREACHES/,/^NEW SIG/p' "$sw" | command grep -aoE '\[P[12]\] [a-z_]+ = [0-9]+ \(max [0-9]+\)' | tr '\n' ' ')
    [ -n "$br" ] && sverd="BREACH" || sverd="clean"
  else
    br="(no sweep output)"; sverd="ABSENT"
  fi
  # AND THE MATRIX'S OWN FAIL LINES ARE AUTHORITATIVE. A sweep can fail without a BREACHES section
  # at all - INVALID-SWEEP-DATA, where the guest logs could not be read - and an earlier version of
  # this meter called that "clean" because it only looked for breaches. Anything the campaign itself
  # recorded as a FAIL for this cell counts, whatever produced it.
  nf=$(command grep -ac "FAIL  *$u:\|FAIL  *$c:" "$LOG" || true)
  [ "$nf" -eq 0 ] && fverd="none" || fverd="$nf"
  [ "$bverd" = PASS ] && [ "$sverd" = clean ] && [ "$nf" -eq 0 ] || c1=1
  printf '  %-16s battery=%-6s sweep=%-6s matrix-FAILs=%-4s %s\n' "$c" "$bverd" "$sverd" "$fverd" "$br"
done
echo
if [ "$c1" -eq 0 ] && [ "$nc" -ge 1 ] && printf '%s' "$footer" | command grep -qa '0 failed'; then
  echo "  CLAUSE 1: MET - every cell passed its battery and its sweep is clean, and the footer agrees"
else
  echo "  CLAUSE 1: NOT MET - see the cells above; a clean sweep AND a passing battery are both required"
fi
echo

# ---- CLAUSE 2: the dom0 callers ----------------------------------------------------------------
# Three distinct channels, each with its own line. The cold one is measured once per campaign, by
# design: it costs a boot and the path does not vary by cell.
echo "---- CLAUSE 2: qrexec aligned with dom0 callers ----"
upd_ok=$(command grep -ac 'dom0 caller channel aligned' "$LOG" || true)
upd_no=$(command grep -ac 'dom0 caller channel is NOT aligned' "$LOG" || true)
men_ok=$(command grep -ac 'start-menu caller aligned (dom0' "$LOG" || true)
men_no=$(command grep -ac 'start-menu caller is NOT aligned - ' "$LOG" || true)
cold_ok=$(command grep -ac 'start-menu caller aligned FROM A COLD QUBE' "$LOG" || true)
cold_no=$(command grep -ac 'start-menu caller is NOT aligned from a cold qube' "$LOG" || true)
unmeasured=$(command grep -ac 'caller channel went unmeasured\|cold caller path went unmeasured' "$LOG" || true)
printf '  updater channel (qubes.VMExec)   aligned on %s cell(s), NOT aligned on %s\n' "$upd_ok" "$upd_no"
printf '  start menu  (qubes.GetAppmenus)  aligned on %s cell(s), NOT aligned on %s\n' "$men_ok" "$men_no"
printf '  from a COLD qube                 aligned %s time(s), NOT aligned %s\n' "$cold_ok" "$cold_no"
printf '  unmeasured cells                 %s\n' "$unmeasured"
echo
if [ "$upd_ok" -ge 1 ] && [ "$upd_no" -eq 0 ] && [ "$men_ok" -ge 1 ] && [ "$men_no" -eq 0 ] \
   && [ "$cold_ok" -ge 1 ] && [ "$cold_no" -eq 0 ] && [ "$unmeasured" -eq 0 ]; then
  echo "  CLAUSE 2: MET - all three channels aligned, none unmeasured"
else
  echo "  CLAUSE 2: NOT MET - a channel failed, or a cell went unmeasured (unmeasured is not a pass)"
fi
echo

# ---- the clock, which is the metric this release turned on -------------------------------------
echo "---- clock_boot_correction_s per cell (the P1 that gated this release) ----"
any=0
for c in $cells; do
  sw="$M/$c-logsweep.out"
  [ -s "$sw" ] || { printf '  %-16s (no sweep output)\n' "$c"; any=1; continue; }
  v=$(command grep -aoE 'clock_boot_correction_s=[0-9]+' "$sw" | head -1 | cut -d= -f2)
  printf '  %-16s %s\n' "$c" "${v:-<not reported>}"
  [ "${v:-0}" -gt 60 ] 2>/dev/null && any=1
done
[ "$any" -eq 0 ] && echo "  no cell needed a correction over the 60 s threshold" \
                 || echo "  at least one cell still applies a correction - the convention is still being forced somewhere"
