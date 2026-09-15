#!/usr/bin/env bash
# FAIL if anything calls `qtest fullshot` outside the allowlist.
#
# fullshot photographs the ENTIRE dom0 desktop and the artifact keeps it. Three such captures
# reached a PUBLIC repo. A written rule did not stop it: e2e-wait.sh called fullshot on every
# periodic and stall capture from 2026-08-30 to 2026-09-09 while that rule was being quoted in this
# project's own commits. So this is a check, not a paragraph.
#
# Per-window capture (`qtest shot` -> local.WinScreenshot) selects by the dom0-set _QUBES_VMNAME and
# never touches the root window. It reaches a session-less guest too - the gui-daemon draws an HVM's
# framebuffer as a window carrying that property - so "fullshot is the only way to see a guest with
# no session" is FALSE and must not come back.
#
# To add an allowlist entry you are editing this file, in a commit, with a reason.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

# The tool name is assembled rather than written literally. This script does NOT drive a guest - it
# greps - but a literal "tools/qtest <verb>" here reads as a guest call to tools/lint-harness.py's
# vmlock rule, and suppressing a real rule to accommodate a static checker is the wrong trade.
Q='qtest'
VERB='fullshot'
PAT_CALL="(^|[^#])[^#]*(\./)?tools/${Q}[[:space:]]+${VERB}"
PAT_LINE="^[[:space:]]*[^#[:space:]].*${Q}[[:space:]]+${VERB}"

# ALLOWED, and why. An override-redirect dom0 window (notification bubble, menu, tooltip) is absent
# from _NET_CLIENT_LIST and CANNOT be captured per-window; that is the dom0 render witness.
declare -A ALLOW=(
  ["mgmt/harness/a0-toast-bridge.sh"]="dom0 render witness: notification bubble is override-redirect"
  ["mgmt/harness/p3a-etw-gate.sh"]="dom0 render witness: notification bubble is override-redirect"
  # Added 2026-09-09. The notify-errors route had only ever been graded on ACKS - "dom0 accepted the
  # call" - and the owner pointed out it had therefore never once been SEEN to work. Grading it on
  # pixels needs a desktop capture for the same unavoidable reason as the two above: the bubble is
  # override-redirect, absent from _NET_CLIENT_LIST, and per-window capture cannot see it at all.
  # Captures go to scratchpad/ (gitignored) and are read, never kept.
  ["mgmt/harness/dom0-notify-witness.sh"]="dom0 render witness: notification bubble is override-redirect"
  # Added 2026-09-13. A GUEST toast is override-redirect too - the agent classifies a caption-less
  # window as a popup (main.c IsPopup) and maps it that way - so the per-window service cannot see
  # it either. That is not a theory: the previous toast-black-witness.sh used `qtest shot` and, in
  # all three runs it ever produced, never once captured a toast-sized window. It was a check that
  # could not fail. This version locates the toast in fullshot's geometry.txt by its
  # override_redirect flag, cuts that rect out, and DELETES the desktop capture in the same
  # function; only the toast PNG survives, in gitignored scratchpad/.
  ["mgmt/harness/toast-black-witness.sh"]="dom0 render witness: a guest toast is override-redirect"
)

bad=0; n=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n=$((n+1))
  if [ -z "${ALLOW[$f]:-}" ]; then
    echo "FAIL  $f calls 'qtest fullshot' and is not allowlisted"
    grep -n "qtest fullshot" "$f" | head -3 | sed 's/^/        /'
    bad=$((bad+1))
  fi
# CALLS, not mentions. Docs and comments discuss fullshot constantly and must not trip this; a
# CALL is an uncommented line in an executable script. Match on an invocation, then drop lines whose
# first non-space character is '#'.
#
# ENUMERATE WHAT CAN BE COMMITTED, NOT THE FILESYSTEM. This gate exists to keep captures out of the
# REPO, and only tracked or staged files can enter it - so the candidate set is `git ls-files`
# (the index: tracked files plus anything newly `git add`ed). The previous `grep -r .` walked the
# whole tree and on 2026-09-16 refused a commit for the four ALLOWLISTED callers a second time,
# because agent worktrees under .claude/worktrees/ (git-ignored via .git/info/exclude, never part
# of a commit) carried copies at a path prefix the allowlist keys do not match. A false refusal
# from a gate with no legitimate bypass is how --no-verify starts looking reasonable; fixing the
# enumeration keeps the gate honest instead. Scratch dirs are excluded by the index for free.
done < <(git ls-files -z -- '*.sh' 2>/dev/null \
         | xargs -0 grep -lE "$PAT_CALL" 2>/dev/null \
         | while IFS= read -r c; do grep -qE "$PAT_LINE" "$c" && echo "$c"; done \
         | sort -u)

# A stale allowlist entry is a failure too: it means the reason is gone and nobody removed it.
for f in "${!ALLOW[@]}"; do
  [ -f "$f" ] || { echo "FAIL  allowlist names $f which does not exist - remove the entry"; bad=$((bad+1)); continue; }
  grep -qE "$PAT_LINE" "$f" 2>/dev/null \
      || { echo "FAIL  allowlist names $f but it no longer CALLS fullshot - remove the entry"; bad=$((bad+1)); }
done

echo "--- $n file(s) CALL ${Q} ${VERB}; $bad violation(s)"
exit $((bad > 0))
