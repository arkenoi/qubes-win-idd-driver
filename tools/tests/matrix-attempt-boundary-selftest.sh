#!/bin/bash
# A FILE CANNOT SCOPE A RUN: every line in a shared work dir belongs to a nameable attempt.
# run: tools/tests/matrix-attempt-boundary-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
SRC=mgmt/harness/matrix.sh
[ -r "$SRC" ] || { echo "FATAL: $SRC missing"; exit 2; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

code=$(awk '/MATTEMPT-A/,/MATTEMPT-B/' "$SRC" | command grep -v 'MATTEMPT-[AB]')
if [ -z "$code" ] || ! printf '%s' "$code" | command grep -qa '_matrix_stamp_inherited_artefacts()'; then
  echo "FATAL: could not extract the stamping code from $SRC between its markers"; exit 2
fi

# attribute: given a stamped file, which attempt does each payload line belong to?
# This is what a READER does, and it is the property - not "a header string exists".
attribute() { # <file> -> "<attempt>|<line>" per payload line, "UNATTRIBUTABLE|<line>" before any boundary
  python3 - "$1" <<'PY'
import re, sys
cur = None
for ln in open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines():
    m = re.match(r'^=== ATTEMPT BOUNDARY: every line below belongs to attempt (\S+) ===$', ln)
    if m:
        cur = m.group(1); continue
    if ln.strip():
        print(f"{cur or 'UNATTRIBUTABLE'}|{ln}")
PY
}

run_two_attempts() { # <extracted code> -> populates $T/art/cell.out as two attempts would
  local body="$1"
  T=$(mktemp -d "${TMPDIR:-/tmp}/matattempt-XXXXXX")
  mkdir -p "$T/art" "$T/empty"
  # attempt ONE leaves a failure behind, exactly as the aborted attempt did
  printf 'LOGVOL-BIND fail reason=no_volume_labelled_DIAG_with_LOGVOL.TAG\n' >> "$T/art/cell.out"
  printf 'logvol: [ERROR] the binder refused\n' >> "$T/art/cell.out"
  # attempt TWO starts: it inherits that file, stamps it, then writes its own success.
  # The extracted region carries matrix.sh's OWN invocation as well as the definition, so M points
  # at an empty dir to make that call a no-op; the call under test is the explicit one below.
  # THE EXTRACTED REGION DEFAULTS MATRIX_ATTEMPT TO THE SEALED attempt_id, so the subshell sources
  # primitives.sh. Without it that default expanded to nothing, the stamper's `id="${2:?}"` refused,
  # and the stamp this suite exists to check was never written - silently, since the call's stderr
  # is discarded. Not a stub: it is the real primitive, which is the point of one id.
  ( set +u; . "$(dirname "$SRC")/primitives.sh"; M="$T/empty"; eval "$body"
    _matrix_stamp_inherited_artefacts "$T/art" "ATTEMPT2" >/dev/null 2>&1 )
  printf 'LOGVOL-BIND ok mode=registry drive=Z: found=D: letter=pinned\n' >> "$T/art/cell.out"
}

# ---- THE PROPERTY -------------------------------------------------------------------------------
run_two_attempts "$code"
att=$(attribute "$T/art/cell.out")
pre=$(printf '%s\n' "$att" | command grep -c '^UNATTRIBUTABLE|' || true)
post=$(printf '%s\n' "$att" | command grep -c '^ATTEMPT2|' || true)
if [ "$pre" = 2 ] && [ "$post" = 1 ]; then
  ok "two attempts in one file are separable: 2 line(s) precede the boundary, 1 belongs to attempt 2"
else
  no "the two attempts are not separable" "before=$pre (want 2) after=$post (want 1)"
fi
if printf '%s\n' "$att" | command grep -q '^ATTEMPT2|LOGVOL-BIND ok'; then
  ok "the SUCCESS line is attributed to the attempt that wrote it"
else
  no "the success line is not attributed to attempt 2" "$(printf '%s' "$att" | tr '\n' ';')"
fi
if printf '%s\n' "$att" | command grep -q '^UNATTRIBUTABLE|LOGVOL-BIND fail'; then
  ok "the inherited FAILURE is NOT attributed to this attempt - which is the whole defect"
else
  no "the inherited failure leaked into this attempt" "$(printf '%s' "$att" | tr '\n' ';')"
fi
# nothing may be destroyed: an aborted attempt's output is its only record
if [ "$(command grep -ca 'LOGVOL-BIND fail' "$T/art/cell.out")" = 1 ]; then
  ok "the previous attempt's evidence is KEPT, not truncated away"
else
  no "the previous attempt's evidence was lost" "stamping must never delete"
fi
rm -rf "$T"

# ---- SEEN TO FAIL: without the stamp, the two attempts are one undifferentiated file ------------
nostamp=$(printf '%s' "$code" | sed "s/^\( *\)printf '=== ATTEMPT BOUNDARY.*$/\1:/")
if [ "$nostamp" = "$code" ]; then
  no "SEEN TO FAIL: could not build the control" "the stamp line was not found to remove"
else
  run_two_attempts "$nostamp"
  att=$(attribute "$T/art/cell.out")
  bad=$(printf '%s\n' "$att" | command grep -c '^UNATTRIBUTABLE|' || true)
  if [ "$bad" = 3 ]; then
    ok "SEEN TO FAIL: with the stamp removed all 3 lines are UNATTRIBUTABLE - the shipped defect, reproduced"
  else
    no "the control did not reproduce the defect" "unattributable=$bad (want 3)"
  fi
  rm -rf "$T"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
