#!/usr/bin/env bash
# A wait that spans a BOOT must not bound its probe below the boot.
# run: tools/tests/wait-bound-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 2
W=mgmt/harness/e2e-wait.sh
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $*"; }
bad(){ fail=$((fail+1)); echo "FAIL $*"; }

# The measured boot-to-session on this rig, both families, 2026-10-17. The bound must exceed it.
BOOT_S=56

# THE PROPERTY IS "NO PROBE IS BOUNDED BELOW THE BOOT", NOT "EVERY CALLER PASSES A BOUND".
# This counted `w_alive "$vm" "${W_ALIVE_BOOT_BOUND:-N}"` call sites and wanted four. w_session and
# w_install have since moved to ONE long-lived probe for the whole wait (w_alive_start +
# w_alive_poll), which removes the per-probe bound altogether - strictly better than a larger one -
# so the count fell to 1 and the check reported a regression where the code had improved. A proxy
# for the property passes and fails for reasons the property does not have.
BOOT_CALLERS="w_session w_install g_reboot_proven"
# LIVE LINES ONLY. The first version of this grader read the function's whole text, and w_session's
# own comment NAMES w_alive_start - so the regressed copy, whose code no longer calls it, still read
# SAFE off the prose and the seen-to-fail leg could not be driven. Whole-line and trailing comments
# are stripped before anything is matched.
body(){ awk "/^$2\(\)\{/,/^}/" "$1" | sed -E 's/(^|[[:space:]])#.*$//' | awk 'NF'; }
caller_is_safe(){ # $1=file $2=function -> 0 if no probe in it is bounded below the boot
  local b; b=$(body "$1" "$2")
  # (a) one long-lived probe for the whole wait: no per-call bound exists to be too small
  printf '%s' "$b" | command grep -qaE 'w_alive_start|w_alive_wait' && return 0
  # (b) or every w_alive in it carries a bound above the measured boot
  local n bad_n=0
  while read -r n; do [ -z "$n" ] && continue; [ "$n" -gt "$BOOT_S" ] || bad_n=1; done <<<"$(
    printf '%s' "$b" | command grep -aoE 'w_alive "\$vm" "\$\{W_ALIVE_BOOT_BOUND:-[0-9]+\}"' | command grep -aoE '[0-9]+')"
  printf '%s' "$b" | command grep -qaE 'w_alive "\$vm"\s*(&&|\|\||;|$)' && return 1
  [ "$bad_n" = 0 ] && printf '%s' "$b" | command grep -qa 'w_alive ' && return 0
  return 1
}
safe_count(){ local f="$1" c=0 fn; for fn in $BOOT_CALLERS; do caller_is_safe "$f" "$fn" && c=$((c+1)); done; echo "$c"; }
grade(){ # $1=file -> prints "<default> <safe-callers> <bareboot>"
  local f="$1" dflt bare
  dflt=$(command grep -aoE 'w_alive\(\)\{[^}]*timeout -k 5 "\$\{2:-([0-9]+)\}"' "$f" | command grep -aoE '[0-9]+\}' | tr -d '}' | head -1)
  bare=$(command grep -anE 'w_alive "\$vm"\s*(&&|\|\||;|$)' "$f" | wc -l)
  printf '%s %s %s' "${dflt:-none}" "$(safe_count "$f")" "$bare"
}
read -r dflt bootcalls bare <<<"$(grade "$W")"
[ "$dflt" = 40 ] && ok "w_alive still defaults to 40 s for a settled guest (default=$dflt)" \
                 || bad "w_alive default is '$dflt', want 40 - a settled guest answers in under a second"
bound=$(command grep -aoE 'W_ALIVE_BOOT_BOUND:-[0-9]+' "$W" | command grep -aoE '[0-9]+' | sort -n | head -1)
[ -n "$bound" ] && [ "$bound" -gt "$BOOT_S" ] \
  && ok "the boot bound ${bound}s exceeds the measured ${BOOT_S}s boot-to-session" \
  || bad "boot bound '${bound:-none}' does not exceed the measured ${BOOT_S}s - a probe below it is abandoned every boot"
[ "$bootcalls" = 3 ] && ok "all three boot-spanning callers are safe (one long-lived probe, or a bound above ${BOOT_S}s)" \
                     || bad "only $bootcalls of 3 boot-spanning callers are safe ($BOOT_CALLERS)"
# The drain probe is SHORT ON PURPOSE - its own comment asks for "a FRESH, short question".
[ "$bare" = 1 ] && ok "exactly one bare w_alive remains: the drain's deliberately short question" \
                || bad "$bare bare w_alive call(s) - a boot-spanning one would be abandoned; the drain is the only legitimate case"

# SEEN TO FAIL: put BOTH shapes back to the defect - the bound removed AND the long-lived probe
# replaced by a per-call one - and every boot-spanning caller must read unsafe. Removing only the
# bound would leave w_session and w_install safe through their single probe and prove nothing.
D=$(mktemp -d "${TMPDIR:-/tmp}/waitbound-XXXXXX"); trap 'rm -rf "$D"' EXIT
sed -E -e 's/w_alive "\$vm" "\$\{W_ALIVE_BOOT_BOUND:-[0-9]+\}"/w_alive "$vm"/g' \
       -e 's/w_alive_start "\$vm"[^)]*\)/w_alive "$vm")/g' \
       -e 's/w_alive_wait "\$vm"[^|]*\|\| true/w_alive "$vm"/g' \
       -e 's/_wa_pid=\$\(w_alive "\$vm"\)/w_alive "$vm"/g' \
       -e 's/_iw_pid=\$\(w_alive "\$vm"\)/w_alive "$vm"/g' "$W" > "$D/regressed.sh"
read -r _ rbootcalls rbare <<<"$(grade "$D/regressed.sh")"
[ "$rbootcalls" = 0 ] && ok "SEEN TO FAIL: with both shapes regressed, 0 of 3 callers are safe (bare=$rbare)" \
                      || bad "the regression copy still reads $rbootcalls of 3 safe - the check cannot be driven"
echo "  ---- $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
