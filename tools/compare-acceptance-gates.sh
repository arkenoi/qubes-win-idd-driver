#!/usr/bin/env bash
# compare-acceptance-gates.sh - what each updater gate actually asserts, extracted from the code.
#
# WHY IT EXTRACTS INSTEAD OF DESCRIBING: a hand-written comparison of two harnesses is prose about
# code, and prose drifts from the code the day either one changes. It drifted within the hour the
# first time: the gates moved into mgmt/harness/updater-gates-lib.sh and a version of this script
# that grepped only the test files reported "NO" for every gate that had just been wired in.
# Owner, 2026-10-22: "make functional comparison table of new modular acceptance gate vs the old one".
#
# THREE COLUMNS, because a two-column table cannot show a merge:
#   BEFORE  mgmt/harness/template-update-test.sh as it stood at git HEAD~ for this change - the
#           release gate that let the relay defect through. Read from git, not from memory.
#   RELEASE the same gate NOW: it runs the component gates as a PREFLIGHT before its dom0 rounds.
#   QUICK   mgmt/harness/updater-component-test.sh standalone - the per-component split.
# RELEASE and QUICK share ONE implementation of the gates, so they cannot disagree; that is the
# point of the library and this table proves it row by row rather than asserting it.
set -u
cd "$(dirname "$0")/.." || exit 2
OLD=mgmt/harness/template-update-test.sh
NEW=mgmt/harness/updater-component-test.sh
LIB=mgmt/harness/updater-gates-lib.sh
PROBE=mgmt/harness/updater-component-probe.ps1
DRV=mgmt/harness/wu-e2e.sh
for f in "$OLD" "$NEW" "$LIB"; do [ -f "$f" ] || { echo "FATAL: $f missing"; exit 2; }; done

# The pre-merge copy of the release gate, from git. If the preflight is already committed, HEAD is
# post-merge, so walk back to the last revision that did NOT source the library.
BEFORE=$(mktemp); trap 'rm -f "$BEFORE"' EXIT
found=no
for rev in HEAD HEAD~1 HEAD~2 HEAD~3 HEAD~4; do
  if git show "$rev:$OLD" > "$BEFORE" 2>/dev/null; then
    if ! grep -q 'updater-gates-lib' "$BEFORE"; then found="$rev"; break; fi
  fi
done
[ "$found" = no ] && { : > "$BEFORE"; }

# does a gate's evidence appear in a given set of files?
inany(){ local pat="$1"; shift; local f; for f in "$@"; do [ -f "$f" ] && grep -qaiE -- "$pat" "$f" && return 0; done; return 1; }
# the RELEASE column: directly in the gate, or through the library it sources
rel(){ local pat="$1"
  if inany "$pat" "$OLD"; then echo yes
  elif grep -q 'updater-gates-lib' "$OLD" && inany "$pat" "$LIB"; then echo "yes (preflight)"
  else echo NO; fi; }
qck(){ local pat="$1"
  if inany "$pat" "$NEW" "$LIB" "$PROBE"; then echo yes; else echo NO; fi; }
bfr(){ local pat="$1"
  [ -s "$BEFORE" ] || { echo "?"; return; }
  if inany "$pat" "$BEFORE"; then echo yes; else echo NO; fi; }

row(){ printf '%-34s | %-8s | %-16s | %s\n' "$1" "$2" "$3" "$4"; }
rule(){ printf '%s\n' "-----------------------------------+----------+------------------+-----------------"; }

echo "UPDATER GATES - FUNCTIONAL COMPARISON, extracted from the code $(date -u +%Y-%m-%dT%H:%MZ)"
echo "  BEFORE  = $OLD at ${found:-<unavailable>} (pre-merge)"
echo "  RELEASE = $OLD now ($(wc -l < "$OLD") lines; preflight: $(grep -q 'updater-gates-lib' "$OLD" && echo yes || echo no))"
echo "  QUICK   = $NEW ($(wc -l < "$NEW") lines) + $LIB ($(wc -l < "$LIB") lines)"
echo
row "PROPERTY" "BEFORE" "RELEASE (now)" "QUICK (standalone)"
rule
row "base golden win11de-qwt (German)" "$(bfr 'FAMILY:-win11de')" "$(rel 'FAMILY:-win11de')" "$(qck 'FAMILY:-win11de')"
row "env built to reporter" "$(bfr 'reporter-env-build')" "$(rel 'reporter-env-build')" "$(qck 'reporter-env-build')"
row "env asserted (locale)" "$(bfr 'env-assert')" "$(rel 'env-assert')" "$(qck 'env-assert')"
rule
row "ASSERTIONS" "" "" ""
rule
row "relay SOURCE vouched" "$(bfr 'relay source vouched')" "$(rel 'relay source vouched')" "$(qck 'relay source vouched')"
row "relay COMPILED this install" "$(bfr 'compiled relay')" "$(rel 'compiled relay')" "$(qck 'compiled relay')"
row "placed exe vouched (UTF-16)" "$(bfr 'marker=True')" "$(rel 'marker=True')" "$(qck 'marker=True')"
row "guest relay listens on 8082" "$(bfr 'listen 127')" "$(rel 'listen 127')" "$(qck 'listen 127')"
row "listen declares parent=<pid>" "$(bfr 'parent=\[0-9\]')" "$(rel 'parent=\[0-9\]')" "$(qck 'parent=\[0-9\]')"
row "served it, adopted nothing" "$(bfr 'started by this pass')" "$(rel 'started by this pass')" "$(qck 'started by this pass')"
row "a COUNT reached dom0" "$(bfr 'reported to dom0')" "$(rel 'reported to dom0')" "$(qck 'reported to dom0')"
row "no pass died on the relay" "$(bfr 'not accepting connections')" "$(rel 'not accepting connections')" "$(qck 'not accepting connections')"
rule
row "update actually INSTALLED" "$(bfr 'last round')" "$(rel 'last round')" "$(qck 'last round')"
row "reboot accounting/oscillation" "$(bfr 'oscillat')" "$(rel 'oscillat')" "$(qck 'oscillat')"
row "excluded updates audited" "$(bfr 'wu-exclusion-audit')" "$(rel 'wu-exclusion-audit')" "$(qck 'wu-exclusion-audit')"
row "dom0-driven rounds (progress+rc)" "$(bfr 'wu-e2e.sh')" "$(rel 'wu-e2e.sh')" "$(qck 'wu-e2e.sh')"
row "rounds per run" "$(grep -oE 'ROUNDS:-[0-9]+' "$BEFORE" 2>/dev/null | head -1 | cut -d- -f2)" \
                      "$(grep -oE 'ROUNDS:-[0-9]+' "$OLD" | head -1 | cut -d- -f2)" "1 scan"
rule
row "DIAGNOSIS + TESTABILITY" "" "" ""
rule
row "per-cause discriminators" "$(bfr 'CONFIRMED')" "$(rel 'CONFIRMED')" "$(qck 'CONFIRMED')"
row "Jev as secondary evaluator" "$(bfr 'updater_gates_jev')" "$(rel 'updater_gates_jev')" "$(qck 'updater_gates_jev')"
row "offline verdict mode" "$(bfr 'EVAL_ONLY')" "$(rel 'EVAL_ONLY')" "$(qck 'EVAL_ONLY')"
nslf=tools/tests/updater-component-selftest.sh
# counted by RUNNING it: a ck call split across continuation lines is invisible to a line grep,
# which read 20 for a suite that executes 33.
nass=$([ -f "$nslf" ] && bash "$nslf" 2>/dev/null | sed -n 's/^RESULT: \([0-9]*\) passed.*/\1/p' | tail -1)
row "registered offline suite" "none" "$(basename "$nslf") (shared)" "$(basename "$nslf")"
row "assertions executed by it" "0" "${nass:-0}" "${nass:-0}"
row "graded on a REAL failing capture" "no" "$(grep -q 'PRE-FIX capture is a FAIL' "$nslf" 2>/dev/null && echo yes || echo no)" \
                                            "$(grep -q 'PRE-FIX capture is a FAIL' "$nslf" 2>/dev/null && echo yes || echo no)"
row "each gate fails independently" "no" "$(grep -q 'only_fails' "$nslf" 2>/dev/null && echo yes || echo no)" \
                                         "$(grep -q 'only_fails' "$nslf" 2>/dev/null && echo yes || echo no)"
echo
echo "READ IT THIS WAY: every NO in the BEFORE column is a property the release gate did not check"
echo "when fa5b416a made the relay compile dead code, which is why that silence was attributed to"
echo "four different causes in turn. RELEASE now covers them through the preflight, and QUICK covers"
echo "the same ones standalone in minutes - one implementation, so the two columns cannot disagree."
echo "What stays only in RELEASE is deliberate: installing an update, reboot accounting, oscillation"
echo "and the exclusion audit (Jev: scan_only_is_a_real_gap 0.19)."
