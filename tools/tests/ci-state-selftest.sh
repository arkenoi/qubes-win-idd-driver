#!/usr/bin/env bash
# ci-state-selftest.sh - drive tools/ci-state.sh offline, each arm SEEN TO FAIL.
#
# THE INCIDENT, 2026-10-11: a receipt was taken against "build 38119590694 green". That run was
# release-package; build.yml had been red for 14 runs. The failure arm here is therefore the FIRST
# one driven: a sha whose release-package is green and whose build.yml is red must exit 1, because
# that is the exact state that was walked past.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/ci-state-selftest.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
SHA=$(git rev-parse HEAD)

# a gh stub whose answer per workflow comes from $T/<workflow>.state as "status conclusion"
mk_gh(){ cat > "$T/gh" <<STUB
#!/bin/bash
wf=""; prev=""
for a in "\$@"; do [ "\$prev" = --workflow ] && wf="\$a"; prev="\$a"; done
f="$T/\$wf.state"
[ -f "\$f" ] || { echo "[]"; exit 0; }
read -r st cn < "\$f"
[ "\$st" = EMPTY ] && { echo "[]"; exit 0; }
[ "\$st" = BROKEN ] && { echo "not json at all"; exit 0; }
[ "\$st" = OTHERSHA ] && { printf '[{"headSha":"%s","status":"completed","conclusion":"success","databaseId":1,"createdAt":"x"}]' "0000000000000000000000000000000000000000"; exit 0; }
printf '[{"headSha":"$SHA","status":"%s","conclusion":"%s","databaseId":99,"createdAt":"x"}]' "\$st" "\$cn"
STUB
chmod +x "$T/gh"; }
set_all(){ for w in "$ROOT"/.github/workflows/*.yml; do echo "$1 $2" > "$T/$(basename "$w").state"; done; }
run(){ GH_BIN="$T/gh" bash tools/ci-state.sh "$SHA" >"$T/out" 2>&1; echo $?; }

mk_gh
# ---- 1. THE INCIDENT: one green workflow does not make the sha green --------------------------
set_all completed success; echo "completed failure" > "$T/build.yml.state"
rc=$(run)
if [ "$rc" = 1 ] && grep -q "RED  build.yml" "$T/out" && grep -q "ok   release-package.yml" "$T/out"; then
  ok "incident_arm: release-package green + build.yml red -> rc 1, and both are shown"
else
  bad "incident_arm: rc=$rc - $(tail -1 "$T/out")"
fi
# ---- 2. all green ----------------------------------------------------------------------------
set_all completed success
rc=$(run); [ "$rc" = 0 ] && ok "all_green: rc 0" || bad "all_green: rc=$rc - $(tail -1 "$T/out")"
# ---- 3. a NON-required workflow being red does not block -------------------------------------
set_all completed success; echo "completed failure" > "$T/winenum.yml.state"
rc=$(run)
[ "$rc" = 0 ] && ok "optional_red_ok: a manually-dispatched workflow's failure is reported, not fatal" \
  || bad "optional_red_ok: rc=$rc"
# ---- 4. MISSING DATA FAILS: a required workflow with no run for the sha -----------------------
set_all completed success; echo "EMPTY -" > "$T/build.yml.state"
rc=$(run)
if [ "$rc" = 1 ] && grep -q "MISS build.yml" "$T/out"; then
  ok "required_absent_fails: no run for the sha is not a pass"
else
  bad "required_absent_fails: rc=$rc - $(tail -1 "$T/out")"
fi
# a run that exists but for a DIFFERENT sha must not be credited to this one
set_all completed success; echo "OTHERSHA -" > "$T/build.yml.state"
rc=$(run)
[ "$rc" = 1 ] && ok "other_sha_not_credited: another commit's green run is not this commit's" \
  || bad "other_sha_not_credited: rc=$rc - $(tail -1 "$T/out")"
# ---- 5. still running is rc 2, never a pass --------------------------------------------------
set_all completed success; echo "in_progress -" > "$T/build.yml.state"
rc=$(run); [ "$rc" = 2 ] && ok "running_is_rc2: an unfinished required workflow has no verdict" \
  || bad "running_is_rc2: rc=$rc - $(tail -1 "$T/out")"
# a red one wins over a running one: the red is actionable now
set_all completed success; echo "in_progress -" > "$T/test.yml.state"; echo "completed failure" > "$T/build.yml.state"
rc=$(run); [ "$rc" = 1 ] && ok "red_beats_running: a red required workflow is reported as red" \
  || bad "red_beats_running: rc=$rc"
# ---- 6. an unreadable answer is not green ----------------------------------------------------
set_all completed success; echo "BROKEN -" > "$T/build.yml.state"
rc=$(run); [ "$rc" = 2 ] && ok "unreadable_is_rc2: gh answering nonsense is 'no verdict', not 'green'" \
  || bad "unreadable_is_rc2: rc=$rc - $(tail -1 "$T/out")"

echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
