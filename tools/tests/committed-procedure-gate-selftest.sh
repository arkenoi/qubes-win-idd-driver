#!/bin/bash
# the heavy-path hook BLOCKS every campaign entry point without a permit, and never the short cycle
# run: tools/tests/committed-procedure-gate-selftest.sh
# pass: exit 0
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T="$(mktemp -d "${TMPDIR:-/tmp}/procgate-XXXXXX")"
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT
pass=0; fail=0
ok(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

HOOK="tools/hooks/committed-procedure-gate.sh"
[ -x "$HOOK" ] || { echo "FATAL: $HOOK is not executable"; exit 2; }

ask(){ # $1=command text, $2=wire log path -> rc
  python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1" \
    | JEV_WIRE_LOG="$2" bash "$HOOK" >"$T/err" 2>&1
  echo $?
}

: > "$T/empty-wire.jsonl"
# THE FIXTURES CARRY A ts, because jev.py stamps every line it writes and the gate now reads it.
# NOW is computed per run: a fixture with a hardcoded date would pass today and start failing
# tomorrow, which is the stale-permit bug wearing the test's clothes.
NOW="$(date -Iseconds)"
OLD="$(date -Iseconds -d '24 hours ago')"
# a wire log that DOES quote the committed procedure for a campaign command
printf '%s\n' '{"ts":"'"$NOW"'","state":"committed_procedure: PKG=38872220406 mgmt/harness/campaign-run.sh; rejected short-cycle alternative: quick-upgrade.sh over the golden, which cannot exercise the clean-install cells"}' > "$T/good-wire.jsonl"
# a wire log with a Jev call that says nothing about the procedure
printf '%s\n' '{"ts":"'"$NOW"'","state":"is this line an error? some unrelated question"}' > "$T/unrelated-wire.jsonl"

# ---- 1. THE MEASURED HOLE: the campaign entry points must be gated ----------------------------
for c in "PKG=38872220406 mgmt/harness/campaign-run.sh" \
         "tools/release-acceptance.sh --run 38872220406" \
         "bash -c 'tools/release-acceptance.sh --run 1'"; do
  rc=$(ask "$c" "$T/empty-wire.jsonl")
  if [ "$rc" = 2 ]; then ok "BLOCKED with no wire log: ${c:0:46}"
  else no "BLOCKED with no wire log: ${c:0:46}" "rc=$rc $(head -1 "$T/err")"; fi
done

# ---- 2. the inner step was always gated, and still is -----------------------------------------
rc=$(ask "./mgmt/harness/matrix.sh" "$T/empty-wire.jsonl")
if [ "$rc" = 2 ]; then ok "matrix.sh is still gated (the case that always worked)"
else no "matrix.sh is still gated" "rc=$rc"; fi
rc=$(ask "mgmt/harness/prime-run.sh win10-base win10-acc ours" "$T/empty-wire.jsonl")
if [ "$rc" = 2 ]; then ok "prime-run.sh is still gated"
else no "prime-run.sh is still gated" "rc=$rc"; fi

# ---- 3. THE SHORT CYCLE MUST NOT BE GATED, or the gate just stops all work ---------------------
# quick-upgrade over a golden is the sanctioned short cycle; gating it would make the rule unusable
# and push work onto heavier paths, which is the opposite of the intent.
for c in "mgmt/harness/quick-upgrade.sh win11r-lt" \
         "tools/qtest shot win11r-lt" \
         "git status --porcelain"; do
  rc=$(ask "$c" "$T/empty-wire.jsonl")
  if [ "$rc" = 0 ]; then ok "NOT gated (short cycle / read-only): ${c:0:42}"
  else no "NOT gated: ${c:0:42}" "rc=$rc $(head -1 "$T/err")"; fi
done

# ---- 4. a wire log only lets it through when it quotes BOTH ------------------------------------
rc=$(ask "PKG=38872220406 mgmt/harness/campaign-run.sh" "$T/good-wire.jsonl")
if [ "$rc" = 0 ]; then ok "a Jev call quoting the command AND the rejected alternative ALLOWS it"
else no "a Jev call quoting the command AND the rejected alternative ALLOWS it" "rc=$rc $(head -2 "$T/err" | tr '\n' ' ')"; fi

rc=$(ask "PKG=38872220406 mgmt/harness/campaign-run.sh" "$T/unrelated-wire.jsonl")
if [ "$rc" = 2 ]; then ok "an unrelated Jev call does NOT open the gate - a wire log is not a permit"
else no "an unrelated Jev call does NOT open the gate" "rc=$rc"; fi

# a wire log quoting a DIFFERENT heavy command must not authorise this one
printf '%s\n' '{"ts":"'"$NOW"'","state":"committed_procedure: mgmt/harness/prime-run.sh win10-base win10-acc ours; rejected: quick-upgrade"}' > "$T/other-wire.jsonl"
rc=$(ask "PKG=38872220406 mgmt/harness/campaign-run.sh" "$T/other-wire.jsonl")
if [ "$rc" = 2 ]; then ok "a permit for ANOTHER heavy command does not authorise this one"
else no "a permit for ANOTHER heavy command does not authorise this one" "rc=$rc"; fi

# ---- 4b. A PERMIT EXPIRES. MEASURED 2026-10-29: a campaign ran on a permit from the previous
# day because WINDOW_MIN was declared and never read, while that run's own fresh permit went unused.
printf '%s\n' '{"ts":"'"$OLD"'","state":"committed_procedure: PKG=38872220406 mgmt/harness/campaign-run.sh; rejected short-cycle alternative: quick-upgrade.sh over the golden"}' > "$T/stale-wire.jsonl"
rc=$(ask "PKG=38872220406 mgmt/harness/campaign-run.sh" "$T/stale-wire.jsonl")
if [ "$rc" = 2 ]; then ok "a permit naming this command EXACTLY but 24 h old does NOT open the gate"
else no "a 24 h old permit does NOT open the gate" "rc=$rc $(head -1 "$T/err")"; fi

# a line with no ts at all is not a permit either: failing open on one restores the whole hole
printf '%s\n' '{"state":"committed_procedure: PKG=38872220406 mgmt/harness/campaign-run.sh; rejected: quick-upgrade"}' > "$T/nots-wire.jsonl"
rc=$(ask "PKG=38872220406 mgmt/harness/campaign-run.sh" "$T/nots-wire.jsonl")
if [ "$rc" = 2 ]; then ok "an UNSTAMPED line is not a permit - the freshness check cannot fail open"
else no "an unstamped line is not a permit" "rc=$rc"; fi

# ---- 5. the recreate-goldens exception still works --------------------------------------------
printf '%s\n' '{"ts":"'"$NOW"'","state":"recreate_goldens per docs/PROCEDURE-recreate-goldens.md - no golden exists, so no short-cycle alternative does either"}' > "$T/recreate-wire.jsonl"
rc=$(ask "mgmt/harness/prime-run.sh win10-base win10-acc ours" "$T/recreate-wire.jsonl")
if [ "$rc" = 0 ]; then ok "the recreate-goldens exception still opens the gate"
else no "the recreate-goldens exception still opens the gate" "rc=$rc"; fi

# ---- 6. SEEN TO FAIL: the shipped pattern, with the wrappers removed --------------------------
# The exact regex this commit replaced. If it still gated the campaign entry points, the hole this
# suite exists for would not have existed - so it must come back UNGATED here.
OLD='prime-run\.sh|reprovision-usb\.sh|matrix\.sh|seal-qwt-golden|build-media\.sh|clone-to-template'
if echo "tools/release-acceptance.sh --run 1" | grep -qE "$OLD"; then
  no "SEEN TO FAIL: the old pattern missed the campaign entry points" "the old pattern matched it"
else ok "SEEN TO FAIL: the old pattern let a full campaign through ungated"; fi

printf 'committed-procedure-gate-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
