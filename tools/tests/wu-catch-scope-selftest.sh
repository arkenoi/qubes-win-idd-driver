#!/usr/bin/env bash
# wu-catch-scope-selftest.sh - offline proof that qubes-windows-update.ps1's main catch runs the 0x8024402C remedy at SCRIPT scope and
# publishes the terminal phase only once the reason is final (tools/tests/wu-catch-scope-test.ps1). The clean leg must pass, and each
# defect leg must FAIL on its own check:
#   WUCATCH_DEFECT=1          the `$st =` that silenced the remedy from e6037f5d (2026-09-21) to 2026-10-02;
#   WUCATCH_DEFECT=race       phase=error published before the diagnosis - dom0 printed the bare HRESULT (rz31, 2026-10-02);
#   WUCATCH_DEFECT=nofinally  a throwing diagnosis leaves the pass in 'diagnosing' with nothing terminal published.
# Exit 0 only if all hold.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
S="$ROOT/guest/qubes-windows-update.ps1"
T="$ROOT/tools/tests/wu-catch-scope-test.ps1"
echo "== clean"
out=$("$PWSH" -NoProfile -File "$T" -Script "$S" 2>&1); rc=$?
printf '%s\n' "$out"
bad=0
[ "$rc" = 0 ] || { echo "FAIL  the clean leg failed (rc=$rc)"; bad=1; }
leg(){ # $1 knob, $2 the check that must be among the failures
  local o r; o=$(WUCATCH_DEFECT="$1" "$PWSH" -NoProfile -File "$T" -Script "$S" 2>&1); r=$?
  echo "== WUCATCH_DEFECT=$1 (must FAIL)"; printf '%s\n' "$o" | grep -E 'FAIL|PASS|INSTRUMENT'
  if [ "$r" = 1 ] && printf '%s\n' "$o" | grep -qF "FAIL $2"; then echo "  caught"; else echo "  NOT CAUGHT (rc=$r)"; bad=1; fi
}
leg 1 'the status object is still a dictionary'
leg race 'no save published phase=error before the reason was final'
leg nofinally 'a throwing diagnosis still ends with phase=error published'
if [ "$bad" = 0 ]; then echo "PASS  clean leg passes; the \$st collision, the early terminal phase and the missing finally are each caught"; exit 0; fi
echo "FAIL  see above"; exit 1
