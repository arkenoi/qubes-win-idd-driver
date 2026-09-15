#!/bin/bash
# cputime-failopen-selftest.sh - prove the stall discriminator FAILS OPEN.
#
# WHY THIS EXISTS. `cpu_time` (admin.vm.Stats) is cumulative: flat across a sample means the domain
# is not executing. That is the only validated way this rig can tell a stalled guest from a slow
# one, and on 2026-09-14 it settled three cases correctly (twice busy where a stall verdict would
# have been FALSE, once frozen where it was TRUE). It is now gated in front of every timeout->death
# site: e2e-wait.sh's two w_wait_install branches, prime-run.sh's DEADLINE, quick-upgrade.sh's
# marker write.
#
# That makes ONE failure mode catastrophic: if an UNREADABLE stats read counted as "flat", every
# qrexec hiccup would manufacture a stall, and the harness would kill healthy guests for it - the
# exact false-wedge report this project has written up repeatedly. The contract is therefore:
#
#     UNREADABLE COUNTS AS MOVING. A failed stats read must never manufacture a stall.
#
# The two helpers spell that contract with OPPOSITE polarity (w_cpu_moving returns 0=moving,
# _pr_cpu_flat returns 1=not-flat), which is precisely the kind of pair that gets one side inverted
# in an edit. So this asserts both, and - per this project's rule that a check is unproven until it
# has been seen to fail - it re-introduces the inversion as a DEFECT build and requires the test to
# catch it. A green run with no defect-catch is reported as UNPROVEN, not as a pass.
#
# Offline: cpu_time reads are stubbed, so this touches no guest and runs in seconds.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
no(){ fail=$((fail+1)); echo "FAIL  $*"; }

# ---- the two helpers, verbatim from the harnesses they guard -----------------------------------
# Extracted by sourcing the real files with the qrexec call stubbed out, so this cannot drift from
# what actually ships: if someone edits the helper, this test sees the edit.
STUB=$(mktemp -d "${TMPDIR:-/tmp}/cputimetest.XXXXXX")
trap 'rm -rf "$STUB"' EXIT

# Stub qrexec-client-vm: emits a NUL-separated admin.vm.Stats reply for the requested vm, or
# nothing at all when the vm name starts with "unreadable" (the failure we are testing).
cat >"$STUB/qrexec-client-vm" <<'EOF'
#!/bin/bash
vm="$1"
case "$vm" in
  unreadable*) exit 1 ;;                       # no output, non-zero: the failure mode under test
  frozen*)     v=127804 ;;                     # same value every call -> genuinely not executing
  busy*)       v=$(( 100000 + RANDOM )) ;;     # different every call -> executing
  *)           v=1 ;;
esac
printf 'cpu_time\0%s\0cpu_usage\0 0\0' "$v"
EOF
chmod +x "$STUB/qrexec-client-vm"
export PATH="$STUB:$PATH"

# Pull the helper definitions out of the shipped files WITHOUT running the scripts (they have
# side effects). awk from the function header to its closing brace at column 0 / end of the block.
extract(){ # $1=file $2=funcname
  awk -v f="$2" '
    $0 ~ "^"f"\\(\\)" {inf=1}
    inf {print}
    inf && /^}/ {exit}
    inf && /^[a-zA-Z_]+\(\)/ && NR>start {}
  ' "$1"
}
# w_cpu_time / w_cpu_moving are one-liner + block forms; take the whole 35-44 region by name.
eval "$(sed -n '/^w_cpu_time()/,/^}/p'   mgmt/harness/e2e-wait.sh)"
eval "$(sed -n '/^w_cpu_moving()/,/^}/p' mgmt/harness/e2e-wait.sh)"
eval "$(sed -n '/^_pr_cpu_time()/,/^}/p' mgmt/harness/prime-run.sh)"
eval "$(sed -n '/^_pr_cpu_flat()/,/^}/p' mgmt/harness/prime-run.sh)"

for fn in w_cpu_time w_cpu_moving _pr_cpu_time _pr_cpu_flat; do
  declare -F "$fn" >/dev/null || { echo "FATAL: could not extract $fn from the shipped harness"; exit 2; }
done

# Defect knob: re-introduce the inversion this test exists to catch.
if [ "${CPUTIME_DEFECT_UNREADABLE_IS_FLAT:-0}" = 1 ]; then
  w_cpu_moving(){ local a b
    a=$(w_cpu_time "$1"); [ -n "$a" ] || return 1        # DEFECT: unreadable -> "not moving"
    sleep "${2:-20}"; b=$(w_cpu_time "$1"); [ -n "$b" ] || return 1
    [ "$a" = "$b" ] && return 1; return 0; }
  _pr_cpu_flat(){ local a b
    a=$(_pr_cpu_time "$1"); [ -n "$a" ] || return 0      # DEFECT: unreadable -> "flat" = stall
    sleep "${2:-20}"; b=$(_pr_cpu_time "$1"); [ -n "$b" ] || return 0
    [ "$a" = "$b" ]; }
fi

S=1   # sample seconds; the stub is instant so this only bounds the sleeps

# ---- 1. THE CONTRACT: unreadable never manufactures a stall ------------------------------------
w_cpu_moving unreadable-vm "$S" \
  && ok "w_cpu_moving: unreadable -> MOVING (no stall manufactured)" \
  || no "w_cpu_moving: unreadable -> not-moving - a stats failure would be reported as a wedge"

_pr_cpu_flat unreadable-vm "$S" \
  && no "_pr_cpu_flat: unreadable -> FLAT - a stats failure would be reported as a wedge" \
  || ok "_pr_cpu_flat: unreadable -> not-flat (no stall manufactured)"

# ---- 2. a genuinely frozen domain IS detected (the check must still be able to fire) -----------
w_cpu_moving frozen-vm "$S" \
  && no "w_cpu_moving: frozen domain reported as moving - the discriminator cannot fire at all" \
  || ok "w_cpu_moving: frozen domain -> not moving"

_pr_cpu_flat frozen-vm "$S" \
  && ok "_pr_cpu_flat: frozen domain -> FLAT" \
  || no "_pr_cpu_flat: frozen domain reported as not-flat - the discriminator cannot fire at all"

# ---- 3. a busy domain is never called stalled --------------------------------------------------
w_cpu_moving busy-vm "$S" \
  && ok "w_cpu_moving: busy domain -> moving" \
  || no "w_cpu_moving: busy domain -> not moving - healthy guests would be killed"

_pr_cpu_flat busy-vm "$S" \
  && no "_pr_cpu_flat: busy domain -> FLAT - healthy guests would be reported as wedged" \
  || ok "_pr_cpu_flat: busy domain -> not flat"

# ---- 4. the two helpers agree (opposite polarity, same verdict) --------------------------------
for vm in unreadable-vm frozen-vm busy-vm; do
  w_cpu_moving "$vm" "$S"; moving=$?
  _pr_cpu_flat "$vm" "$S"; flat=$?
  # moving==0 means executing; flat==0 means NOT executing. They must disagree numerically.
  if [ "$moving" -ne "$flat" ]; then
    ok "agreement on $vm (w_cpu_moving=$moving _pr_cpu_flat=$flat)"
  else
    no "DISAGREEMENT on $vm - one of the two has been inverted (w_cpu_moving=$moving _pr_cpu_flat=$flat)"
  fi
done

# ---- 5. EVERY CALL SITE PASSES A VARIABLE THAT EXISTS IN ITS OWN FILE --------------------------
# THE GAP THIS CLOSES, found in review 2026-09-14: everything above proves the HELPERS, and a
# helper can be perfect while a call site is broken. quick-upgrade.sh:334 passed "$VM" in a file
# whose subject variable is $SUBJECT and which runs under `set -u`, so the moment that branch was
# reached the harness died with "VM: unbound variable" instead of reaching its verdict - in exactly
# the path the commit was written to fix. The checks above all passed while that shipped.
#
# Every harness here runs under `set -u`, so an undefined variable is not a typo, it is a crash.
SCAN=mgmt/harness
if [ "${CPUTIME_DEFECT_UNDEFINED_CALLSITE:-0}" = 1 ]; then
  # Re-introduce the real 2026-09-14 bug in a COPY: quick-upgrade.sh:334 passed "$VM" in a file
  # whose variable is $SUBJECT. The scan must catch it.
  SCAN="$STUB/scan"; mkdir -p "$SCAN"; cp mgmt/harness/*.sh "$SCAN/"
  sed -i '0,/w_cpu_moving "\$SUBJECT" 15/s//w_cpu_moving "$VM" 15/' "$SCAN/quick-upgrade.sh"
fi
for f in "$SCAN"/*.sh; do
  grep -oE 'w_cpu_(moving|state)[[:space:]]+"\$\{?[A-Za-z_][A-Za-z0-9_]*' "$f" 2>/dev/null \
  | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*$' | tr -d '${' | sort -u \
  | while read -r v; do
      [ -n "$v" ] || continue
      # Assigned in this file, or a loop variable, or a function parameter it was given.
      if grep -qE "(^|[^A-Za-z0-9_])${v}=|local .*\b${v}\b|for ${v} |read .*\b${v}\b" "$f"; then
        echo "OKVAR $f \$$v"
      else
        echo "BADVAR $f \$$v"
      fi
    done
done > "$STUB/vars.txt"
# NOTE: `grep -c` exits 1 when the count is zero, so `|| echo 0` would append a SECOND zero and
# the integer test below would then fail on "0\n0" - which is exactly how this check first
# reported a bogus FAIL. Take the count without the fallback; this script runs -uo, not -e.
bad=$(grep -c '^BADVAR' "$STUB/vars.txt" 2>/dev/null); bad=${bad:-0}
good=$(grep -c '^OKVAR' "$STUB/vars.txt" 2>/dev/null); good=${good:-0}
if [ "$bad" -eq 0 ] && [ "$good" -gt 0 ]; then
  # Counted as distinct (file, variable) pairs, not raw call sites: the same variable used five
  # times in one file is one thing to verify. 2 pairs today = $vm in e2e-wait.sh, $SUBJECT in
  # quick-upgrade.sh, covering all five calls.
  ok "every w_cpu_moving/w_cpu_state call site passes a variable defined in its own file ($good distinct file+var pair(s))"
elif [ "$bad" -eq 0 ]; then
  no "VACUOUS - this check found NO call sites at all, so it cannot fail. The scan is broken, not the code."
else
  no "CALL SITE PASSES AN UNDEFINED VARIABLE - under set -u this CRASHES the harness:"
  grep '^BADVAR' "$STUB/vars.txt" | sed 's/^BADVAR /      /'
fi

echo "=== cputime fail-open selftest: $pass passed, $fail failed ==="
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
