#!/usr/bin/env bash
# ci-state-selftest.sh - drive tools/ci-state.py offline, each arm SEEN TO FAIL.
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

# a gh stub. Each workflow's answer comes from $T/<workflow>.state, one line:
#   MINE <status> <conclusion>    a run whose headSha IS the sha under test
#   OTHER <status> <conclusion>   a run for a DIFFERENT sha (the only kind an inherit can use)
#   EMPTY                         the workflow has no runs at all
#   BROKEN                        gh answers something that is not JSON
mk_gh(){ cat > "$T/gh" <<STUB
#!/bin/bash
wf=""; prev=""
for a in "\$@"; do [ "\$prev" = --workflow ] && wf="\$a"; prev="\$a"; done
f="$T/\$wf.state"
[ -f "\$f" ] || { echo "[]"; exit 0; }
read -r who st cn < "\$f"
case "\$who" in
  EMPTY)  echo "[]"; exit 0 ;;
  BROKEN) echo "not json at all"; exit 0 ;;
  OTHER)  sha="0000000000000000000000000000000000000000" ;;
  MINE)   sha="$SHA" ;;
  *)      echo "STUB: '\$f' must start with MINE|OTHER|EMPTY|BROKEN, got '\$who'" >&2; exit 3 ;;
esac
printf '[{"headSha":"%s","status":"%s","conclusion":"%s","databaseId":99,"createdAt":"x"}]' "\$sha" "\$st" "\$cn"
STUB
chmod +x "$T/gh"; }
set_all(){ for w in "$ROOT"/.github/workflows/*.yml; do echo "MINE $1 $2" > "$T/$(basename "$w").state"; done; }
# CI_STATE_BRANCH is set UNCONDITIONALLY: an assignment prefix built by expansion
# (${BRANCH:+CI_STATE_BRANCH=...}) is a WORD, which bash then tries to execute - rc 127. Empty is
# fine, because ci-state falls back to the working tree's branch on an empty value.
run(){ GH_BIN="$T/gh" CI_STATE_CHANGED="${CHANGED:-tools/x.py}" CI_STATE_BRANCH="${BRANCH:-}" \
         python3 tools/ci-state.py "$SHA" >"$T/out" 2>&1; echo $?; }

mk_gh
# ---- 1. THE INCIDENT: one green workflow does not make the sha green --------------------------
set_all completed success; echo "MINE completed failure" > "$T/build.yml.state"
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
set_all completed success; echo "MINE completed failure" > "$T/winenum.yml.state"
rc=$(run)
[ "$rc" = 0 ] && ok "optional_red_ok: a manually-dispatched workflow's failure is reported, not fatal" \
  || bad "optional_red_ok: rc=$rc"
# ---- 4. MISSING DATA FAILS: a required workflow with no run for the sha -----------------------
set_all completed success; echo "EMPTY" > "$T/build.yml.state"
rc=$(run)
if [ "$rc" = 1 ] && grep -q "MISS build.yml" "$T/out"; then
  ok "required_absent_fails: no run for the sha is not a pass"
else
  bad "required_absent_fails: rc=$rc - $(tail -1 "$T/out")"
fi
# a run that exists but for a DIFFERENT sha must not be credited to this one
set_all completed success; echo "OTHER completed success" > "$T/build.yml.state"
rc=$(run)
[ "$rc" = 1 ] && ok "other_sha_not_credited: another commit's green run is not this commit's" \
  || bad "other_sha_not_credited: rc=$rc - $(tail -1 "$T/out")"
# ---- 5. still running is rc 2, never a pass --------------------------------------------------
set_all completed success; echo "MINE in_progress -" > "$T/build.yml.state"
rc=$(run); [ "$rc" = 2 ] && ok "running_is_rc2: an unfinished required workflow has no verdict" \
  || bad "running_is_rc2: rc=$rc - $(tail -1 "$T/out")"
# a red one wins over a running one: the red is actionable now
set_all completed success; echo "MINE in_progress -" > "$T/test.yml.state"; echo "MINE completed failure" > "$T/build.yml.state"
rc=$(run); [ "$rc" = 1 ] && ok "red_beats_running: a red required workflow is reported as red" \
  || bad "red_beats_running: rc=$rc"
# ---- 6. PATH-FILTERED: skipped for this sha is not a failure, but a red ancestor still is ----
# test.yml is filtered to guest/**, tools/**, ... so a commit touching only findings/ never starts it.
set_all completed success; echo "OTHER completed success" > "$T/test.yml.state"
rc=$(CHANGED="findings/issues.md" run)
if [ "$rc" = 0 ] && grep -q "inh  test.yml" "$T/out" && grep -q "path-filtered" "$T/out"; then
  ok "pathfiltered_inherits_green: a workflow this sha cannot trigger inherits its latest green"
else
  bad "pathfiltered_inherits_green: rc=$rc - $(tail -1 "$T/out")"
fi
set_all completed success; echo "OTHER completed failure" > "$T/test.yml.state"
rc=$(CHANGED="findings/issues.md" run)
if [ "$rc" = 1 ] && grep -q "RED  test.yml" "$T/out" && grep -q "inherited from" "$T/out"; then
  ok "pathfiltered_red_ancestor_fails: a red latest run is NOT hidden by the sha not triggering it"
else
  bad "pathfiltered_red_ancestor_fails: rc=$rc - a live red would be invisible"
fi
set_all completed success; echo "EMPTY" > "$T/test.yml.state"
rc=$(CHANGED="findings/issues.md" run)
if [ "$rc" = 1 ] && grep -q "MISS test.yml" "$T/out"; then
  ok "pathfiltered_no_run_at_all_fails: nothing to inherit is not a pass"
else
  bad "pathfiltered_no_run_at_all_fails: rc=$rc - $(tail -1 "$T/out")"
fi
# and when the sha DOES touch its paths, an absent run is due and loud
set_all completed success; echo "EMPTY" > "$T/test.yml.state"
rc=$(CHANGED="tools/qtest" run)
if [ "$rc" = 1 ] && grep -q "DUE for this sha" "$T/out"; then
  ok "due_and_absent_fails: a sha that touches its paths must have a run"
else
  bad "due_and_absent_fails: rc=$rc - $(tail -1 "$T/out")"
fi

# ---- 7. an unreadable answer is not green ----------------------------------------------------
set_all completed success; echo "BROKEN" > "$T/build.yml.state"
rc=$(run); [ "$rc" = 2 ] && ok "unreadable_is_rc2: gh answering nonsense is 'no verdict', not 'green'" \
  || bad "unreadable_is_rc2: rc=$rc - $(tail -1 "$T/out")"

# ---- 8. A FLAG IS NOT A SHA -------------------------------------------------------------------
# MEASURED 2026-10-25, twice, both ways: the sha is POSITIONAL, so `ci-state.py --sha <value>`
# graded the literal string "--sha". Every workflow came back "no run for this sha" and the
# verdict was rc=1 while all four runs at the real sha had SUCCEEDED; earlier the same mistake
# read rc=0 and a campaign started on a sha whose test suite was broken. The guard must REFUSE
# (rc=2, the instrument could not answer) and must NOT fire on a sha it can use - a short sha is
# the arm that would break every committed caller if the pattern were too strict.
set_all completed success
rc=$(GH_BIN="$T/gh" CI_STATE_CHANGED="tools/x.py" \
     python3 tools/ci-state.py --sha "$SHA" >"$T/out" 2>&1; echo $?)
if [ "$rc" = 2 ] && grep -q "is not a commit sha" "$T/out" && grep -q "POSITIONAL" "$T/out"; then
  ok "flag_is_not_a_sha_rc2: --sha refuses instead of grading the literal flag"
else
  bad "flag_is_not_a_sha_rc2: rc=$rc - $(tail -1 "$T/out")"
fi
# THE PREDICATE IS THE PROPERTY, NOT A PROXY. My first version of this arm asserted rc=0 and
# failed BOTH with and without the guard: the stub gh is keyed to the FULL $SHA, so a 7-char sha
# has no state to grade and comes back rc=1 on the stub's data, which says nothing about the
# guard. What must hold is that the guard does not REJECT a short sha - i.e. it reaches the
# grader at all and never prints its refusal.
rc=$(GH_BIN="$T/gh" CI_STATE_CHANGED="tools/x.py" \
     python3 tools/ci-state.py "${SHA:0:7}" >"$T/out" 2>&1; echo $?)
if ! grep -q "is not a commit sha" "$T/out"; then
  ok "short_sha_not_rejected: the guard lets a 7-char sha through to the grader"
else
  bad "short_sha_not_rejected: the guard rejected a valid short sha - $(tail -1 "$T/out")"
fi

# ---- A BLOCKED REQUIRED GATE IS NOT GREEN ------------------------------------------------------
# MEASURED 2026-10-16 on sweep-gate-severity: test.yml and build.yml are `branches: [main]`, the
# diff touched guest/ and tools/ - exactly the paths test.yml guards - and both REQUIRED gates were
# reported green from 7fbf7c18's runs. The gate had something to say and could not run; an
# ancestor's green is not a receipt for this sha. A path-filtered workflow is the opposite case and
# must still inherit, which the three cases above pin.
# An ANCESTOR green and NO run for this sha - the shape the incident had.
set_all completed success; echo "OTHER completed success" > "$T/test.yml.state"
rc=$(CHANGED="tools/qtest" BRANCH="some-topic-branch" run)
if [ "$rc" = 1 ] && grep -q "MISS test.yml" "$T/out" && grep -q "cannot run on this branch" "$T/out"; then
  ok "branchblocked_required_not_green: paths matched, branch cannot run it -> not this sha's green"
else
  bad "branchblocked_required_not_green: rc=$rc - $(tail -1 "$T/out")"
fi
# and on the branch it DOES run on, the same sha is green - or the check above would pass by
# refusing everything.
set_all completed success
rc=$(CHANGED="tools/qtest" BRANCH="main" run)
if [ "$rc" = 0 ]; then
  ok "branchblocked_onmain_is_green: on main the required gates are satisfied by their own runs"
else
  bad "branchblocked_onmain_is_green: rc=$rc - $(tail -1 "$T/out")"
fi
# SEEN TO FAIL: the shipped reason-string blamed the PATHS for a branch exclusion, so the output
# said "path-filtered" about a diff whose paths matched. Assert the real filter is named.
set_all completed success; echo "OTHER completed success" > "$T/test.yml.state"
rc2=$(CHANGED="tools/qtest" BRANCH="some-topic-branch" run)
if grep -q "branch-filtered" "$T/out" && ! grep -q "path-filtered for" "$T/out"; then
  ok "branchblocked_names_the_real_filter: the note says branch-filtered, not path-filtered"
else
  bad "branchblocked_names_the_real_filter: $(grep -a 'test.yml' "$T/out" | head -1)"
fi

echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
