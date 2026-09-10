#!/usr/bin/env bash
# FAIL if the acceptance runner's default campaign does not cover every cell cut-release.sh requires.
#
# THE CLASS OF BUG THIS EXISTS FOR. The required cell set lives in tools/cut-release.sh (the publish
# gate) and the campaign that produces it lives in tools/release-acceptance.sh. They are two lists in
# two files with no relationship, so they drifted: the runner's default omitted win11-reinstall and
# win11-upgrade while running two cells the gate does not require. A full run then reported
# "51 passed, 0 failed", record-acceptance wrote verdict CLEAN, and only cut-release caught it -
# "PARTIAL MATRIX - these cells did not run: win11-reinstall, win11-upgrade" (2026-09-10).
#
# Fixing that instance fixed nothing structural: either list can drift again, and the symptom is a
# GREEN verdict over an incomplete matrix - the shape of the 4.3.19 mistake the gate was built for.
# So the relationship is now checked, in the pre-commit hook, instead of remembered.
#
# It reads both files rather than hard-coding a third copy of the list, because a third copy would
# be the same bug with an extra step.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

CUT=tools/cut-release.sh
RUN=tools/release-acceptance.sh
[ -f "$CUT" ] && [ -f "$RUN" ] || { echo "FAIL  missing $CUT or $RUN"; exit 1; }

# cut-release.sh:  required={"win11-clean","win10-clean",...}
required=$(grep -aoE 'required=\{[^}]*\}' "$CUT" | head -1 | grep -oE '"[a-z0-9-]+"' | tr -d '"' | sort -u)
# release-acceptance.sh:  CELLS_DEFAULT="win10-clean win10-reinstall ..."
defaults=$(grep -aoE '^CELLS_DEFAULT="[^"]*"' "$RUN" | head -1 | sed -E 's/^CELLS_DEFAULT="//; s/"$//' | tr ' ' '\n' | sed '/^$/d' | sort -u)

if [ -z "$required" ]; then echo "FAIL  could not read the required cell set from $CUT"; exit 1; fi
if [ -z "$defaults" ]; then echo "FAIL  could not read CELLS_DEFAULT from $RUN"; exit 1; fi

missing=$(comm -23 <(printf '%s\n' "$required") <(printf '%s\n' "$defaults"))
if [ -n "$missing" ]; then
  echo "FAIL  $RUN's default campaign does not run every cell $CUT requires."
  echo "      missing: $(printf '%s' "$missing" | tr '\n' ' ')"
  echo "      A campaign can then pass, record CLEAN, and still be refused at publish - or worse,"
  echo "      be believed. Add them to CELLS_DEFAULT (or justify removing them from the gate)."
  exit 1
fi
echo "--- cell coverage: $(printf '%s' "$required" | wc -w) required, all present in CELLS_DEFAULT ($(printf '%s' "$defaults" | wc -w) cells)"
exit 0
