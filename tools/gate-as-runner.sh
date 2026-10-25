#!/bin/bash
# gate-as-runner.sh - run the offline gate (or named suites) in the CONFIGURATION CI HAS.
#
#   tools/gate-as-runner.sh                      the whole gate, as the runner sees it
#   tools/gate-as-runner.sh <suite> [<suite>...]  just those, same shape
#
# WHY IT EXISTS. On 2026-10-25 `test` was RED for a day while the same gate was green on this qube,
# because clock-sync-selftest.sh shelled out to a pwsh path that exists on one machine. A gate whose
# result differs between here and the runner is not a gate, and the difference was invisible because
# nothing could reproduce the runner's shape: no pwsh at any of this qube's four tarball paths, and a
# pwsh ON PATH. This is that shape, and it had been written from scratch in a scratchpad three times
# before it was finally committed - owner, same day: "you orchestrate everything by hand, despite i
# asked you to mechanize everything multiple times."
#
# WHY A MOUNT NAMESPACE AND NOT PWSH=<something>. Setting the variable that NAMES a resource proves
# nothing about its absence: production code is full of fallback chains and a single-variable
# override hands control to exactly those. Measured, same day: PWSH=/nonexistent defeated path 1 of
# 3 and 11 of 28 "ran without pwsh" passes were uninterpretable. So the installs are MASKED and the
# mask is ASSERTED before a suite runs - if the namespace did not take, this refuses rather than
# printing a clean result from the wrong machine.
#
# --no-pwsh: mask the installs and provide NO pwsh at all, asserting that `command -v pwsh` is
# empty. That is the shape in which a suite's handling of ABSENCE is visible, and it is the only
# honest way to prove a refactor of the lookup did not silently turn a skip into a failure (or the
# reverse). Run the same suites in a worktree at the old sha and diff the exit codes.
#
# RUN IT ALONE. The per-suite cap is 300 s and death-reporter-selftest.sh needs ~210 s of that, so a
# second heavy job on this qube turns it into an rc=124 that reads exactly like a defect. That cost a
# re-measurement on 2026-10-25.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

# Every location this repo has ever looked in; tools/tests/pwsh-path.sh holds the same list and
# tools/tests/pwsh-path-selftest.sh asserts it names each one.
INSTALLS=(/home/user/pwsh /home/user/pwsh74 /home/user/bin/pwsh7 /home/user/.local/pwsh)
REAL=""
for d in "${INSTALLS[@]}"; do [ -x "$d/pwsh" ] && { REAL="$d"; break; }; done
[ -n "$REAL" ] || { echo "REFUSED: no pwsh install on this qube to stand in for the runner's" >&2; exit 2; }
command -v unshare >/dev/null 2>&1 || { echo "REFUSED: no unshare - the mask cannot be made real" >&2; exit 2; }

NOPWSH=0
[ "${1:-}" = "--no-pwsh" ] && { NOPWSH=1; shift; }

unshare -r -m /bin/bash -s "$REAL" "$NOPWSH" "$@" <<'NS'
set -uo pipefail
REAL="$1"; shift
NOPWSH="$1"; shift
mount --make-rprivate / 2>/dev/null

# 1. the real install, under a name the mask will not cover
mkdir -p /tmp/gar-pwsh /tmp/gar-bin /tmp/gar-empty
mount --bind "$REAL" /tmp/gar-pwsh || { echo "REFUSED: bind of $REAL failed" >&2; exit 2; }

# 2. mask every install
for d in /home/user/pwsh /home/user/pwsh74 /home/user/bin/pwsh7 /home/user/.local/pwsh; do
  [ -d "$d" ] && { mount --bind /tmp/gar-empty "$d" || { echo "REFUSED: mask of $d failed" >&2; exit 2; }; }
done

# 3. a private /home/user/tmp. At least one suite ignores TMPDIR and mktemps there, so without this
#    a concurrent run outside the namespace can collide and manufacture a red.
mkdir -p /tmp/gar-home-tmp
[ -d /home/user/tmp ] && { mount --bind /tmp/gar-home-tmp /home/user/tmp || { echo "REFUSED: private /home/user/tmp failed" >&2; exit 2; }; }

# 4. a pwsh on PATH, as every runner, container and distro package has - unless --no-pwsh, where
#    the point is that there is none anywhere.
if [ "$NOPWSH" = 0 ]; then
  ln -sf /tmp/gar-pwsh/pwsh /tmp/gar-bin/pwsh
fi
export PATH="/tmp/gar-bin:$PATH"

# 5. ASSERT THE SHAPE, or the result is from the wrong machine
bad=0
for d in /home/user/pwsh /home/user/pwsh74 /home/user/bin/pwsh7 /home/user/.local/pwsh; do
  [ -x "$d/pwsh" ] && { echo "REFUSED: $d/pwsh is STILL executable - the mask did not take" >&2; bad=1; }
done
p="$(command -v pwsh || true)"
if [ "$NOPWSH" = 1 ]; then
  # THE ABSENCE IS ASSERTED, not requested. A namespace that silently did not take would otherwise
  # print a clean result measured against an installed pwsh - 11 of 28 such passes were
  # uninterpretable on 2026-10-25 for exactly that reason.
  [ -z "$p" ] || { echo "REFUSED: --no-pwsh but command -v pwsh says $p" >&2; bad=1; }
  [ "$bad" = 0 ] || exit 2
  echo "NO-PWSH SHAPE: four installs masked, nothing on PATH"
  echo "               tools/tests/pwsh-path.sh answers: $(env -u PWSH tools/tests/pwsh-path.sh 2>/dev/null || echo '<none, as required>')"
else
  [ -n "$p" ] && [ -x "$p" ] || { echo "REFUSED: no pwsh on PATH - this is not the runner's shape" >&2; bad=1; }
  [ -n "$p" ] && { "$p" -NoProfile -Command 'exit 0' >/dev/null 2>&1 || { echo "REFUSED: the PATH pwsh does not run" >&2; bad=1; }; }
  [ "$bad" = 0 ] || exit 2
  echo "RUNNER SHAPE: four installs masked, pwsh on PATH at $p"
  echo "              tools/tests/pwsh-path.sh answers: $(env -u PWSH tools/tests/pwsh-path.sh || echo '<none>')"
fi
echo

unset PWSH
export TMPDIR="${TMPDIR:-/home/user/tmp}"
mkdir -p "$TMPDIR"
if [ "$#" -eq 0 ]; then
  tools/tests/run-offline-suites.sh
else
  rc=0
  for s in "$@"; do
    out=$(timeout 300 bash "tools/tests/$s" 2>&1); r=$?
    if [ "$r" = 0 ]; then
      printf 'ok    %-45s %s\n' "$s" "$(printf '%s' "$out" | tail -1 | cut -c1-70)"
    else
      rc=1
      printf 'FAIL  %-45s rc=%s\n' "$s" "$r"
      printf '%s\n' "$out" | tail -20
    fi
  done
  exit $rc
fi
NS
rc=$?
echo "gate-as-runner rc=$rc"
exit $rc
