#!/usr/bin/env bash
# pwsh-path.sh - the ONE place that knows where pwsh is. Prints the path, or exits non-zero.
#
# WHY THIS FILE EXISTS. Fifty-odd suites resolved pwsh for themselves, in five spellings, against
# four different dev-qube install paths (/home/user/pwsh, /home/user/pwsh74, /home/user/bin/pwsh7,
# /home/user/.local/pwsh). Nothing kept them in sync, and the cost was measured twice:
#
#   * 2026-10-25, CI run 40156224497 and again 40192417696: clock-sync-selftest.sh reported
#     "settime_behaviour: the model did not run - no verdict" and the `test` workflow was RED on
#     every push for a day. The suite ran `"${PWSH:-/home/user/pwsh/pwsh}"` - a path that exists on
#     exactly one machine - while the runner has pwsh ON PATH the whole time. The suite was not
#     measuring anything in CI and said so correctly; no one had read it.
#   * 2026-10-25, choosing which suites a runner can run: PWSH=/nonexistent/pwsh was used to mean
#     "pretend pwsh is absent", and 11 of 28 "passes" were uninterpretable because the next line was
#     `[ -x "$PWSH" ] || PWSH=/home/user/bin/pwsh7/pwsh`. The override defeated path 1 of 3.
#
# So the two rules here are not stylistic:
#
#   1. AN EXPLICIT PWSH IS OBEYED, NEVER SECOND-GUESSED. If PWSH is set and non-empty, that is the
#      answer - and if it is not executable this exits 1 rather than quietly searching elsewhere.
#      That is what makes PWSH=/nonexistent a usable absence fixture instead of a no-op.
#   2. OTHERWISE PATH COMES FIRST, then the known installs. A runner has pwsh on PATH and none of
#      the dev-qube paths; the dev qube has the reverse. Searching both, in that order, is what
#      makes a suite's result mean the same thing in both places.
#
# Usage, and it is the same line everywhere:
#
#     PWSH="$("$(dirname "$0")/pwsh-path.sh" || true)"
#
# then the caller's own `[ -x "$PWSH" ] ||` handling decides whether absence is a skip or a failure
# - this script takes no view on that, because the suites legitimately differ.
#
# tools/lint-harness.py (l33) FAILS the commit on a hardcoded pwsh path outside this file, so the
# fan-out cannot grow back.
set -u

# ---- 1. an explicit request is the answer, right or wrong -------------------------------------
if [ -n "${PWSH:-}" ]; then
    if [ -x "$PWSH" ]; then
        printf '%s\n' "$PWSH"
        exit 0
    fi
    echo "pwsh-path: PWSH=$PWSH is set but not executable - NOT searching elsewhere (an explicit" \
         "override is an instruction, and silently ignoring it is how an absence fixture becomes a" \
         "no-op)" >&2
    exit 1
fi

# ---- 2. PATH, then every install this project has ever used ------------------------------------
# PATH first: that is where a GitHub runner, a fresh container and a distro package all put it.
_p="$(command -v pwsh 2>/dev/null || true)"
if [ -n "$_p" ] && [ -x "$_p" ]; then
    printf '%s\n' "$_p"
    exit 0
fi
for _c in /home/user/pwsh/pwsh \
          /home/user/pwsh74/pwsh \
          /home/user/bin/pwsh7/pwsh \
          /home/user/.local/pwsh/pwsh; do
    if [ -x "$_c" ]; then
        printf '%s\n' "$_c"
        exit 0
    fi
done

echo "pwsh-path: no pwsh - not on PATH and none of the known installs exist" >&2
exit 1
