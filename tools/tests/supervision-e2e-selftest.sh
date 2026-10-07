#!/usr/bin/env bash
# supervision-e2e-selftest.sh - offline checks on mgmt/harness/supervision-e2e.sh. No guest, no rig.
#
# A ROUTINE THAT GRADES THE PRODUCT IS ITSELF AN INSTRUMENT. This one was written after three ad-hoc runs measured a
# broken harness instead of the product, so the shapes that made those runs worthless are the shapes checked here -
# and every check is driven to FAIL with its line removed, because a check never seen to fail is decoration.
#
#   usage      it refuses to run without --iso, and refuses an --iso that does not exist (missing data fails)
#   cells      every documented cell has an `if has <cell>` block, and every block is documented
#   shutdown   it uses qwt_shutdown, never `qvm-shutdown --wait` (which KILLS at its timeout - lint L9)
#   waits      its session wait has THREE exits and says which one it took
#   byname     nothing is killed or adopted by process name
#   verdicts   every cell records a verdict, and a missing measurement is INVALID or FAIL - never PASS
#   control    L7C compares against a clone of the GOLDEN and never boots the golden itself
#   exit       the script exits non-zero when any cell failed or was invalid
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/mgmt/harness/supervision-e2e.sh"
OUT="${SUP_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/sup-selftest-XXXXXX")}"
mkdir -p "$OUT"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$S" ] || { echo "FAIL  $S is missing - nothing ran (missing data fails)"; exit 2; }

# a check and its knob: $1 label, $2 predicate over a file, $3 a literal line whose removal must break it
shape(){ local label="$1" fn="$2" guard="$3" tmp="$OUT/knob.sh"
  if ! "$fn" "$S"; then bad "$label"; return; fi
  grep -vF "$guard" "$S" > "$tmp"
  if [ "$(wc -l < "$tmp")" -eq "$(wc -l < "$S")" ]; then bad "$label (the guard line is not in the file: '$guard')"; return; fi
  if "$fn" "$tmp"; then bad "$label - still passes with the guard removed (decoration)"; else ok "$label (and FAILS with its line removed)"; fi
}

# ---- usage: no --iso, or an --iso that does not exist, must refuse ------------------------------------------------
rc=0; bash "$S" >"$OUT/noiso.out" 2>&1 || rc=$?
if [ "$rc" = 2 ] && grep -q -- "--iso" "$OUT/noiso.out"; then ok "usage: it refuses to run without --iso (rc=2)"
else bad "usage: no --iso gave rc=$rc: $(head -1 "$OUT/noiso.out")"; fi
rc=0; bash "$S" --iso /nonexistent/nope.iso >"$OUT/badiso.out" 2>&1 || rc=$?
if [ "$rc" = 2 ]; then ok "usage: it refuses an --iso that does not exist (rc=2) - missing data fails"
else bad "usage: a nonexistent --iso gave rc=$rc"; fi

# ---- every documented cell exists, and every cell is documented ---------------------------------------------------
doc=$(grep -oE '^#   (L[0-9]+C?|SW) ' "$S" | awk '{print $2}' | sort -u)
impl=$(grep -oE 'if has (L[0-9]+C?)' "$S" | awk '{print $3}' | sort -u)
missing=""; for c in $doc; do case "$c" in SW) continue ;; esac; printf '%s\n' "$impl" | grep -qx "$c" || missing="$missing $c"; done
extra=""; for c in $impl; do printf '%s\n' "$doc" | grep -qx "$c" || extra="$extra $c"; done
if [ -z "$missing" ] && [ -z "$extra" ]; then ok "cells: every documented cell is implemented and every implemented cell documented ($(printf '%s' "$impl" | tr '\n' ' '))"
else bad "cells: documented-but-absent:'$missing' implemented-but-undocumented:'$extra'"; fi

# ---- the shapes that made the ad-hoc runs worthless ---------------------------------------------------------------
uses_qwt_shutdown(){ grep -q 'source mgmt/harness/shutdown-lib.sh' "$1" && grep -q 'qwt_shutdown "' "$1" &&
                     # a comment that NAMES the forbidden form is not a use of it (lint L9 skips comment lines too;
                     # the first version of this check failed on the very comment explaining why the form is banned)
                     ! grep -vE '^\s*#' "$1" | grep -qE 'qvm-shutdown[^|;&#]*--wait'; }
shape "shutdown: it asks through qwt_shutdown and never 'qvm-shutdown --wait' (which kills at its timeout)" \
      uses_qwt_shutdown 'source mgmt/harness/shutdown-lib.sh'

three_exits(){ awk '/^wait_session\(\)/{f=1} f&&/echo "halted"/{a=1} f&&/echo "deadline"/{b=1} f&&/echo "up"/{c=1} f&&/^guest_ps/{exit} END{exit !(a&&b&&c)}' "$1"; }
shape "waits: the session wait has three exits and says which it took (up / halted / deadline)" \
      three_exits 'done; echo "deadline"; return 1; }'

# The predicate must depend on the GUARD LINE, or the knob proves nothing. What matters here is that the broker is
# resolved by the pid the AGENT logged - never by image name - so that is what is checked: the pid parsed out of the
# agent's line, and the process opened by -Id with it.
no_by_name(){ ! grep -qE '(Stop-Process|taskkill|pkill|killall)' "$1" &&
              grep -qF 'pid (\d+)' "$1" &&
              # the UNIQUE by-handle action: the suspend takes $p.Handle, never a name. (Get-Process -Id appears
              # twice in the routine, so keying on it made the knob removable without breaking the check.)
              grep -qF 'NtSuspendProcess($p.Handle)' "$1"; }
shape "byname: the broker is resolved by the pid the agent logged, never by image name" \
      no_by_name '[void][W.T]::NtSuspendProcess($p.Handle)'

missing_is_not_pass(){ # every INVALID branch must exist for the cells that read guest output
  for c in L3 L4 L6 L7 L7C; do grep -q "verdict $c INVALID" "$1" || return 1; done; return 0; }
shape "verdicts: every cell that reads guest output has an INVALID branch - missing data is never a PASS" \
      missing_is_not_pass 'verdict L3 INVALID "a 4 s suspension does not get the broker reaped"'

# ONE GUEST AT A TIME. The first version of L7C booted the control while the subject was still up -
# two Windows guests interleaving their probes, which is the rule the rig-cycle skill puts second and
# the serial-rig hook refuses outright. The check is ORDER, not presence: the subject's shutdown must
# come before the control's start.
one_guest(){ awk '/^if has L7C/{f=1} f&&/qwt_shutdown "\$SUBJ"/{d=NR} f&&/qvm-start "\$CTL"/{s=NR; exit} END{exit !(d && s && d < s)}' "$1"; }
shape "custody: L7C takes the subject DOWN before the control comes up - never two guests at once" \
      one_guest 'qwt_shutdown "$SUBJ" 600 > "$OUT/L7C-subject-down.out" 2>&1'

control_clones(){ grep -q 'clone-guest.sh "$GOLDEN" "$CTL"' "$1" && ! grep -qE 'qvm-start "\$GOLDEN"' "$1"; }
shape "control: L7C clones the golden and never boots the golden itself (it is a pristine base)" \
      control_clones 'if bash mgmt/clone-guest.sh "$GOLDEN" "$CTL" > "$OUT/L7C-clone.out" 2>&1; then'

# SELF-CONTAINMENT. Three runs measured a broken instrument because this routine reached into a scratch
# directory and a second worktree for its firing helpers. Everything is on this branch now, so a path
# that leaves the repo is a defect - and this check INJECTS one rather than removing a line, because a
# negative claim cannot be driven to fail by deletion.
self_contained(){ ! grep -qE '/home/user/(wt-|qwt-retest)' "$1"; }
inject(){ # $1 label, $2 predicate, $3 line to append as the defect
  if ! "$2" "$S"; then bad "$1"; return; fi
  { cat "$S"; printf '%s\n' "$3"; } > "$OUT/inject.sh"
  if "$2" "$OUT/inject.sh"; then bad "$1 - still passes with the defect injected (decoration)"
  else ok "$1 (and FAILS with the defect injected)"; fi
}
inject "self-contained: no cell reaches into a scratch dir or a sibling worktree for its helpers" \
       self_contained 'source /home/user/wt-toasthold/mgmt/harness/a0-lib.sh'

# THE LIBRARIES REFUSE WITHOUT WHAT THEY DEMAND, and they say so. e2e-lib.sh wants QTEST_VM ("there is
# deliberately no default target"); a0-lib.sh wants $R and a log() BEFORE it is sourced. Sourcing either
# without them ends the run on the spot - which is how L6 died on 2026-10-07 after L1-L5 had already passed,
# the third time in this project that a library was sourced without its prerequisite. The check is ORDER.
lib_prereqs(){ awk '
  /^ *export QTEST_VM=|^ *QTEST_VM=.*export|^ *VM="\$SUBJ"; export QTEST_VM=/ {qv=NR}
  /^ *R="\$OUT\/L6-a0.log"/ {r=NR}
  /source .claude\/skills\/win-guest-e2e\/e2e-lib.sh/ {e=NR}
  /source mgmt\/harness\/a0-lib.sh/ {a=NR}
  END{exit !(qv && r && e && a && qv < e && r < a)}' "$1"; }
shape "prereqs: QTEST_VM is exported before e2e-lib.sh and \$R is set before a0-lib.sh (both refuse without them)" \
      lib_prereqs 'VM="$SUBJ"; export QTEST_VM="$SUBJ"'

# PUSHRUN NEEDS A LOGGED-ON SESSION and returns nothing but cmd's banner without one, so waiting for qrexec
# to answer is not waiting for the guest to be usable: the control arm did exactly that on 2026-10-07 and then
# reported "the probe produced nothing" about a guest that was simply not logged on yet. Again an ORDER check.
pushrun_after_session(){ awk '
  /imagename eq explorer.exe/ {sess=NR}
  /qtest pushrun "\$OUT\/L7-probe.ps1"/ {pr=NR}
  END{exit !(sess && pr && sess < pr)}' "$1"; }
shape "session: the control waits for a LOGGED-ON session before pushrun, not just for qrexec" \
      pushrun_after_session 'imagename eq explorer.exe'

exits_nonzero(){ grep -qE '\[ "\$nf" = 0 \] && \[ "\$ni" = 0 \] && exit 0 \|\| exit 1' "$1"; }
shape "exit: the routine exits non-zero when any cell failed or was invalid" \
      exits_nonzero '[ "$nf" = 0 ] && [ "$ni" = 0 ] && exit 0 || exit 1'

# ---- the guest-side probes must parse as PowerShell ---------------------------------------------------------------
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
if [ -x "$PWSH" ]; then
  # extract each heredoc'd probe and parse-check it the way the repo checks every shipped script
  n=0; bad_ps=0
  for tag in L3-probe L4-probe L5-arm L7-probe; do
    awk -v t="$tag" '$0 ~ ("cat > \"\\$OUT/" t "\\.ps1\" <<.PS.") {f=1; next} f && /^PS$/ {exit} f {print}' "$S" > "$OUT/$tag.ps1"
    [ -s "$OUT/$tag.ps1" ] || { bad "probes: $tag could not be extracted"; bad_ps=1; continue; }
    n=$((n+1))
    "$PWSH" -NoProfile -File "$ROOT/tools/ps-parse-check.ps1" "$OUT/$tag.ps1" > "$OUT/$tag.parse" 2>&1
    grep -q '0 with syntax errors' "$OUT/$tag.parse" || { bad "probes: $tag does not parse: $(tail -2 "$OUT/$tag.parse" | tr '\n' ' ' | cut -c1-160)"; bad_ps=1; }
  done
  [ "$bad_ps" = 0 ] && [ "$n" = 4 ] && ok "probes: all $n guest-side probes parse as PowerShell"
else
  echo "skip  probes: no pwsh at $PWSH"
fi

echo "--- $pass passed, $fail failed; outputs in $OUT"
[ "$fail" = 0 ] && exit 0 || exit 1
