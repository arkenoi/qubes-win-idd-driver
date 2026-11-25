#!/bin/bash
# THE PREACCOUNT CENSUS: has the log sweep been told about every log line the tree emits?
# Exit 0 yes; 2 no (the lines are named on stdout) or it could not be checked. Run from the repo root.
#
# ONE PLACE, CALLED BEFORE ANY GUEST IS TOUCHED. It lived inline in supervision-e2e.sh, and the
# comment there said "the campaign and acceptance entry points have run this check" - but
# release acceptance never did: its only census was the supervision-gate FEATURE TEST, run after
# the whole matrix. rel-45608968441-c ran 2.5 h (88/88 PASS, then template-update) before that test
# refused on 9 advertise-tools lines from core-agent 8e13e42 that a minute-0 census would have named.
#
# Three legs - the parent tree and both submodules - each derived from the STAMPED PARENT COMMIT, so
# the ranges cannot disagree about which product version is meant; a submodule sha that will not
# resolve is itself a refusal, because an unchecked tree is not a clean one.
SWBASE=mgmt/harness/log-sweep-baseline.json
_pa=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("preaccounted_at") or "")' "$SWBASE" 2>/dev/null)
[ -n "$_pa" ] || { echo "FAIL  $SWBASE carries no preaccounted_at, so nothing says which product version it accounts for" >&2; exit 2; }
_pa_fail=0
python3 tools/sweep-preaccount.py check --baseline "$SWBASE" --since "$_pa" --head HEAD || _pa_fail=1
for _sub in agent core-agent; do
  _b=$(git rev-parse --verify --quiet "$_pa:$_sub"); _h=$(git rev-parse --verify --quiet "HEAD:$_sub")
  { [ -n "$_b" ] && [ -n "$_h" ]; } \
    || { echo "FAIL  could not resolve $_sub at ${_pa:0:8} or at HEAD - an unchecked tree is not a clean one" >&2; exit 2; }
  python3 tools/sweep-preaccount.py check --baseline "$SWBASE" --since "$_b" --head "$_h" \
          --repo "$_sub" --path-prefix "$_sub/" || _pa_fail=1
done
[ "$_pa_fail" = 0 ] \
  || { echo "FAIL  the sweep has not been told about every log line this tree emits - the lines are named above. Classify each with Jev, write them into $SWBASE, then stamp: tools/sweep-preaccount.py record --baseline $SWBASE --at \$(git rev-parse HEAD)" >&2; exit 2; }
echo "the sweep accounts for every log line in the parent tree and both submodules (stamp ${_pa:0:12})"
