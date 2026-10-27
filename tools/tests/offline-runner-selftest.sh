#!/bin/bash
# An EMPTY list, a shrunken one or a gutted silent suite MUST NOT read as 'all suites passed'.
# run: tools/tests/offline-runner-selftest.sh
# pass: exit 0
set -u
cd "$(dirname "$0")/../.." || exit 1
R=tools/tests/run-offline-suites.sh
pass=0; fail=0
T=$(mktemp -d "${TMPDIR:-/tmp}/offline-runner-st.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

mk(){ printf '%s\n' "$2" > "$T/$1"; chmod +x "$T/$1"; }
# A suite that reports a tally and passes.
mk good-selftest.sh '#!/bin/bash
echo "  PASS  something real"
echo "good-selftest: 3 passed, 0 failed"'
# A suite that passes while reporting only a bare verdict line - four real suites do this, and
# counting tallies alone called them empty.
mk bare-selftest.sh '#!/bin/bash
echo "FAIL  planted defect, expected in the knob leg"
echo "PASS  clean leg passes, the defect knob fails it"'
# A suite that exits 0 and says NOTHING. This is the gutted shape.
mk silent-selftest.sh '#!/bin/bash
exit 0'
# A suite that fails.
mk red-selftest.sh '#!/bin/bash
echo "  FAIL  a real assertion failed"
echo "red-selftest: 2 passed, 1 failed"
exit 1'

run(){ # <list-contents> [extra env assignments...]
  printf '%s\n' "$1" > "$T/list.txt"; shift
  # DEPTH CLEARED DELIBERATELY: this suite is itself in the shipped list, so the runner has already
  # incremented the guard by the time it runs us. We are the one caller that is allowed to re-enter,
  # because we hand it a FIXTURE list and dir - and Part F proves the guard still fires for a caller
  # that does not clear it.
  env "$@" OFFLINE_SUITES_DEPTH=0 OFFLINE_SUITES_LIST="$T/list.txt" OFFLINE_SUITES_DIR="$T" \
      TMPDIR_OVERRIDE="$T/tmp" bash "$R" >"$T/out" 2>&1; echo $?
}

echo "PART A  a healthy list passes"
rc=$(run 'good-selftest.sh
bare-selftest.sh' OFFLINE_SUITES_FLOOR=2)
[ "$rc" = 0 ] && ok "two green suites -> rc=0" || { bad "a green list came back rc=$rc"; sed 's/^/        /' "$T/out"; }
command grep -q 'RESULT: PASS' "$T/out" && ok "and it says RESULT: PASS" || bad "no RESULT: PASS line"
# The bare-verdict suite must be COUNTED, not called empty - that was a real false red.
command grep -qE '^ok +bare-selftest\.sh' "$T/out" \
  && ok "a suite reporting only 'PASS <text>' is counted, not called empty" \
  || { bad "the bare-verdict suite was not counted as green"; command grep -a 'bare' "$T/out" | sed 's/^/        /'; }

echo "PART B  the FLOOR fires when the list shrinks"
rc=$(run 'good-selftest.sh' OFFLINE_SUITES_FLOOR=2)
[ "$rc" = 2 ] && ok "a list below the floor is rc=2, before any suite runs" || bad "the floor did not fire (rc=$rc)"
command grep -q 'the list shrank' "$T/out" && ok "and the message says the list shrank" || bad "the floor message does not explain itself"
# An EMPTY list is the extreme of the same defect and must not read as success.
rc=$(run '' OFFLINE_SUITES_FLOOR=2)
[ "$rc" = 2 ] && ok "an EMPTY list is rc=2, never 'all passed'" || bad "an empty list came back rc=$rc"

echo "PART C  the EMPTY rule fires on a gutted suite"
rc=$(run 'good-selftest.sh
silent-selftest.sh' OFFLINE_SUITES_FLOOR=2)
[ "$rc" = 1 ] && ok "a suite that exits 0 reporting nothing FAILS the run" || bad "a silent suite passed (rc=$rc)"
command grep -qE '^EMPTY +silent-selftest\.sh' "$T/out" \
  && ok "and it is named as EMPTY, not counted green" || bad "the silent suite was not reported as EMPTY"

echo "PART D  a red suite and a missing suite both fail"
rc=$(run 'good-selftest.sh
red-selftest.sh' OFFLINE_SUITES_FLOOR=2)
[ "$rc" = 1 ] && ok "a failing suite fails the run" || bad "a red suite did not fail the run (rc=$rc)"
command grep -q 'a real assertion failed' "$T/out" \
  && ok "and the failing assertion is echoed, so CI shows why" || bad "the red suite's own output is hidden"
rc=$(run 'good-selftest.sh
not-in-the-tree-selftest.sh' OFFLINE_SUITES_FLOOR=2)
[ "$rc" = 1 ] && ok "a suite named in the list but absent fails the run" || bad "a missing suite was skipped (rc=$rc)"
command grep -qE '^MISSING' "$T/out" && ok "and it is reported as MISSING" || bad "the missing suite was silent"

echo "PART E  it is wired into CI, and the real list is honoured"
ck(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
ck "the offline-suites job calls this runner" "1" \
   "$(python3 -c "
import yaml
d=yaml.safe_load(open('.github/workflows/test.yml'))
j=d['jobs'].get('offline-suites') or {}
print(sum(1 for s in j.get('steps',[]) if 'run-offline-suites.sh' in (s.get('run') or '')))" 2>/dev/null)"
ck "that job checks out submodules (the patch suites need the mirror)" "True" \
   "$(python3 -c "
import yaml
d=yaml.safe_load(open('.github/workflows/test.yml'))
j=d['jobs']['offline-suites']
print(any((s.get('with') or {}).get('submodules') for s in j['steps']))" 2>/dev/null)"
# THE PROBE JOB MUST SHARE THE GATE JOB'S PREP, or it is measuring somewhere else. The probes
# that decide whether a held-out suite may JOIN this gate live in their own job (they must: PART E
# above pins the gate job to exactly one runner call). Their comment says the prep is copied from
# offline-suites on purpose; this is that claim as a check rather than a sentence.
#
# THE ABSENT-JOB CASE IS DECIDED, NOT EXCUSED. The probe job is temporary - it goes when the probes
# have been acted on - and a first version of this leg simply reported ok when it was missing. Jev
# named that the worst defect (absent_job_branch 0.63) because it cannot tell "acted on and
# removed" from "deleted to silence this leg". So the absence is only acceptable when the probes
# are gone TOO: no job, and no step named PROBE anywhere in the workflow, is the intended end
# state; no job while PROBE steps live elsewhere is a probe outside the parity check, and fails.
probe_prep=$(python3 -c "
import yaml
d=yaml.safe_load(open('.github/workflows/test.yml'))
g=d['jobs'].get('offline-suites') or {}
p=d['jobs'].get('out-of-gate-probe')
probe_steps=sum(1 for j in d['jobs'].values()
                for s in (j.get('steps') or [])
                if (s.get('name') or '').startswith('PROBE'))
if p is None:
    print('NO-PROBE-JOB-AND-NO-PROBES' if probe_steps == 0
          else 'PROBES-OUTSIDE-THE-JOB:%d' % probe_steps)
    raise SystemExit
def prep(j):
    out=[]
    for s in j.get('steps',[]):
        if 'run-offline-suites.sh' in (s.get('run') or ''):
            break
        out.append((s.get('name') or s.get('uses'), (s.get('run') or '').strip(),
                    tuple(sorted((s.get('with') or {}).items()))))
    return out
print('SAME' if prep(g)==prep(p) else 'DIFFERENT')" 2>/dev/null)
case "$probe_prep" in
  SAME)
    ok "the probe job's prep is identical to the gate job's" ;;
  NO-PROBE-JOB-AND-NO-PROBES)
    ok "no probe job and no PROBE step anywhere - the probes were acted on and removed, which is the end state" ;;
  PROBES-OUTSIDE-THE-JOB:*)
    bad "${probe_prep#*:} PROBE step(s) live outside the parity-checked job: a probe that decides whether a suite may join the gate must run where the gate runs, so it belongs in out-of-gate-probe or nowhere" ;;
  *)
    bad "the probe job's prep has drifted from the gate job's ($probe_prep): a probe that decides whether a suite may join the gate must run where the gate runs" ;;
esac


echo "PART F  the depth guard refuses an accidental re-entry"
# A suite that runs the whole suite is how a self-test once fork-bombed this qube. The guard is
# proven by calling the runner WITHOUT clearing the depth, which is what an accident looks like.
printf 'good-selftest.sh\n' > "$T/list.txt"
OFFLINE_SUITES_DEPTH=1 OFFLINE_SUITES_LIST="$T/list.txt" OFFLINE_SUITES_DIR="$T" \
  OFFLINE_SUITES_FLOOR=1 TMPDIR_OVERRIDE="$T/tmp" bash "$R" >"$T/out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "re-entry at depth 1 is refused (rc=2)" || bad "the depth guard did not fire (rc=$rc)"
command grep -q 're-entered itself' "$T/out" && ok "and it says what happened" || bad "the depth refusal is silent"

echo "offline-runner-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
