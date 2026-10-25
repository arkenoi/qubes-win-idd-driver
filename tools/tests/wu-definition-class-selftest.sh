#!/usr/bin/env bash
# wu-definition-class-selftest.sh - the scan's definition classifier and the exclusion that keeps
# Defender signatures out of dom0's updates-available (both regions of guest/qubes-windows-update.ps1),
# against fake offers. The clean leg must pass; -Defect titlematch (the structural test replaced by an
# English title substring match - the defect most likely to have been shipped instead) must fail the
# German-title case among others, and -Defect swallowunknown (an unclassifiable offer excluded instead
# of counted) must fail every must-still-count case. Exit 0 only if all three hold.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="$("$(dirname "$0")/pwsh-path.sh" || true)"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
T="$ROOT/tools/tests/wu-definition-class-test.ps1"
out=$("$PWSH" -NoProfile -File "$T" 2>&1); rc=$?
printf '%s\n' "$out" | tail -1
fails_of() { printf '%s\n' "$1" | grep -oE '^  FAIL [a-z-]+:' | sed 's/^  FAIL //; s/:$//' | LC_ALL=C sort | tr '\n' ','; }
bad=0
expect() { local kout krc kf; kout=$("$PWSH" -NoProfile -File "$T" -Defect "$1" 2>&1); krc=$?; kf=$(fails_of "$kout")
  if [ "$krc" = 1 ] && [ "$kf" = "$2" ]; then echo "OK    $1 fails exactly {$kf}"; else echo "FAIL  $1 rc=$krc fails={$kf} (want $2)"; bad=1; fi; }
[ "$rc" = 0 ] || { echo "FAIL  clean rc=$rc"; printf '%s\n' "$out" | grep FAIL; bad=1; }
# titlematch leaves signature-en passing on purpose: an English title DOES match, which is exactly
# why the German case is the one that decides whether the classifier is structural.
expect titlematch      "braced-uppercase,multiple-categories,signature-de,"
expect swallowunknown  "cumulative,defender-platform,driver,no-categories,throwing-categories,wrong-category-type,"
[ $bad = 0 ] && { echo "PASS  clean passes; every knob fails exactly its cases"; exit 0; }
exit 1
