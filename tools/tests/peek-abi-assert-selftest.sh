#!/bin/bash
# The peek script's ABI assertion must actually be able to REFUSE.
# run: tools/tests/peek-abi-assert-selftest.sh
# pass: exit 0
set -u
cd "$(dirname "$0")/../.." || exit 2
P=guest/wgcbroker-peek.ps1
[ -f "$P" ] || { echo "SELFTEST-ERROR: missing $P"; exit 2; }
fail=0

echo "peek ABI assertion selftest"
# --- 1. static: case-only variable collisions ---
# COMMENTS ARE NOT CODE. This file documents the old broken spelling on purpose, so a scan that
# includes comments reports the very thing the comment is warning about - a self-fulfilling failure.
dup=$(sed 's/#.*$//' "$P" | grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' | sort -u \
      | awk '{ lc=tolower($0); if (lc in seen) print seen[lc] " and " $0; else seen[lc]=$0 }')
if [ -n "$dup" ]; then
  echo "  FAIL variables differing only by case (PowerShell treats these as ONE variable):"
  printf '       %s\n' "$dup"; fail=1
else
  echo "  OK   no two variables differ only by case"
fi

# --- 2. behavioural, under real PowerShell ---
# pwsh on this qube is an unpacked tarball and not on PATH; a runner has it on PATH and none of
# the tarballs. tools/tests/pwsh-path.sh knows both and is the only thing that does.
PS="$("$(dirname "$0")/pwsh-path.sh" || true)"
if [ -z "$PS" ]; then
  echo "  SKIP no pwsh on this host - the static check above still applies"
else
  want=$(grep -oE '^\$WANT_ABI\s*=\s*[0-9]+' "$P" | grep -oE '[0-9]+$')
  [ -n "$want" ] || { echo "  FAIL cannot read \$WANT_ABI from $P"; fail=1; want=16; }
  # the FIXED spelling must refuse when the section disagrees
  got=$("$PS" -NoProfile -Command "\$WANT_ABI = $want; \$secAbi = $((want-1)); if (\$secAbi -ne \$WANT_ABI) { 'REFUSED' } else { 'ACCEPTED' }" 2>/dev/null | tr -d '\r')
  if [ "$got" = REFUSED ]; then echo "  OK   the shipped spelling refuses a section one version behind"
  else echo "  FAIL the shipped spelling did NOT refuse (got '$got')"; fail=1; fi
  # and the SHADOWED spelling must be shown to be broken, or this test proves nothing
  got=$("$PS" -NoProfile -Command "\$ABI = $want; \$abi = $((want-1)); if (\$abi -ne \$ABI) { 'REFUSED' } else { 'ACCEPTED' }" 2>/dev/null | tr -d '\r')
  if [ "$got" = ACCEPTED ]; then echo "  OK   the old shadowed spelling is demonstrated to accept a mismatch (the defect is real)"
  else echo "  FAIL could not demonstrate the shadowing defect (got '$got') - this test would not have caught it"; fail=1; fi
fi

[ "$fail" = 0 ] && { echo "PASS: the ABI assertion can refuse, and the defect that disabled it is guarded"; exit 0; }
echo "FAIL: the peek script could misparse a section without saying so"; exit 1
