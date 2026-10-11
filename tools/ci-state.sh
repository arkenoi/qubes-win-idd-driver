#!/usr/bin/env bash
# ci-state.sh [sha] - the conclusion of EVERY workflow for a commit, not just the one you asked about.
#
# WHY IT EXISTS. On 2026-10-11 I took a guest receipt against build "38119590694 green" and reported
# the fix as building clean. That run was release-package. build.yml - which runs the offline test
# batteries - had been RED for 14 consecutive runs since 2026-10-10T16:00Z, because a message-rewording
# pass had moved the text three notifyerr checks match. Nothing lied to me: I read one workflow's
# conclusion and called it "the build". Same shape as the owner's rule about dom0 toasts - if it is
# red, I am supposed to see it, with no guesswork and without being told.
#
# REQUIRED workflows must have a SUCCESSFUL latest run for the sha. The rest are reported for context;
# they are manually dispatched and an absent run is not a failure. in_progress is rc 2, never a pass.
#
#   rc 0  every required workflow is green for this sha
#   rc 1  at least one required workflow is RED (or has no run at all - missing data fails)
#   rc 2  at least one is still running, or gh could not answer: the instrument has no verdict yet
#
# GH_BIN is overridable so both arms are provable offline; tools/tests/ci-state-selftest.sh drives it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
SHA="${1:-$(git rev-parse HEAD)}"
GH="${GH_BIN:-gh}"
REQUIRED="${CI_STATE_REQUIRED:-build.yml test.yml}"
rc=0; running=0
printf 'ci-state %s\n' "${SHA:0:8}"
for wf in .github/workflows/*.yml; do
  name=$(basename "$wf")
  req=no; case " $REQUIRED " in *" $name "*) req=yes ;; esac
  row=$($GH run list --workflow "$name" --limit 40 \
        --json headSha,status,conclusion,databaseId,createdAt 2>/dev/null \
        | python3 -c '
import json,sys
sha=sys.argv[1]
try: rows=json.load(sys.stdin)
except Exception: print("UNREAD - -"); raise SystemExit
for r in rows:                      # newest first, so the first match is the latest run
    if r.get("headSha","").startswith(sha[:8]) or sha.startswith(r.get("headSha","")[:8]):
        print("%s %s %s" % (r.get("status"), r.get("conclusion") or "-", r.get("databaseId")))
        break
else:
    print("NORUN - -")
' "$SHA")
  set -- $row; status="${1:-UNREAD}"; concl="${2:--}"; runid="${3:--}"
  mark="    "
  case "$status:$concl" in
    completed:success) mark="ok  " ;;
    completed:*)       mark="RED "; [ "$req" = yes ] && rc=1 ;;
    NORUN:*)           mark="none"; [ "$req" = yes ] && { rc=1; mark="MISS"; } ;;
    UNREAD:*)          mark="????"; [ "$req" = yes ] && running=1 ;;
    *)                 mark="run "; [ "$req" = yes ] && running=1 ;;
  esac
  printf '  %s %-22s %-11s %-9s %s%s\n' "$mark" "$name" "$status" "$concl" "$runid" \
         "$([ "$req" = yes ] && echo '  (required)')"
done
[ "$rc" = 0 ] && [ "$running" = 1 ] && rc=2
case $rc in
  0) echo "CI 0 every required workflow is green for ${SHA:0:8}" ;;
  1) echo "CI 1 a required workflow is RED or absent for ${SHA:0:8} - do not receipt against this sha" ;;
  2) echo "CI 2 a required workflow has not finished for ${SHA:0:8} - no verdict yet" ;;
esac
exit $rc
