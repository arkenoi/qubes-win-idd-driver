#!/usr/bin/env bash
# wait-bound-selftest.sh - a wait that spans a BOOT must not bound its probe below the boot.
#
# WHY. mgmt/harness/e2e-wait.sh's w_alive bounded every probe at 40 s. MEASURED win11-clean
# 2026-10-17: the session comes up at t+56 s, so every probe of a booting guest was killed at 40 s
# while its request was still QUEUED. Queued qrexec is delivered when the agent starts, so the
# abandoned requests arrived together - three wrappers inside 33 ms, consecutive ports, each finding
# its caller gone - and the guest wrote `InitVchan: QGAVCHANFAIL ... request dropped` once per
# abandoned probe, against a gate whose condition is a clean error log. Jev: the per-probe bound
# below the awaited event is itself the defect, 0.82.
#
# This is a TEXT check and says only what it can: that the boot-waiting callers pass a bound above
# the measured boot, and that the deliberately-short drain probe still does not. Whether a guest
# answers inside it is a rig measurement, not something a selftest can prove.
set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 2
W=mgmt/harness/e2e-wait.sh
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $*"; }
bad(){ fail=$((fail+1)); echo "FAIL $*"; }

# The measured boot-to-session on this rig, both families, 2026-10-17. The bound must exceed it.
BOOT_S=56

grade(){ # $1=file -> prints "<default> <bootcalls> <bareboot>"
  local f="$1" dflt bootcalls bare
  dflt=$(command grep -aoE 'w_alive\(\)\{[^}]*timeout -k 5 "\$\{2:-([0-9]+)\}"' "$f" | command grep -aoE '[0-9]+\}' | tr -d '}' | head -1)
  # callers that wait across a boot: w_session, w_install, g_reboot_proven
  bootcalls=$(command grep -acE 'w_alive "\$vm" "\$\{W_ALIVE_BOOT_BOUND:-[0-9]+\}"' "$f")
  bare=$(command grep -anE 'w_alive "\$vm"\s*(&&|\|\||;|$)' "$f" | wc -l)
  printf '%s %s %s' "${dflt:-none}" "$bootcalls" "$bare"
}
read -r dflt bootcalls bare <<<"$(grade "$W")"
[ "$dflt" = 40 ] && ok "w_alive still defaults to 40 s for a settled guest (default=$dflt)" \
                 || bad "w_alive default is '$dflt', want 40 - a settled guest answers in under a second"
bound=$(command grep -aoE 'W_ALIVE_BOOT_BOUND:-[0-9]+' "$W" | command grep -aoE '[0-9]+' | sort -n | head -1)
[ -n "$bound" ] && [ "$bound" -gt "$BOOT_S" ] \
  && ok "the boot bound ${bound}s exceeds the measured ${BOOT_S}s boot-to-session" \
  || bad "boot bound '${bound:-none}' does not exceed the measured ${BOOT_S}s - a probe below it is abandoned every boot"
[ "$bootcalls" -ge 4 ] && ok "every boot-spanning wait passes the bound ($bootcalls call site(s))" \
                       || bad "only $bootcalls boot-spanning call site(s) pass a bound, want >=4 (w_session, w_install, g_reboot_proven x2)"
# The drain probe is SHORT ON PURPOSE - its own comment asks for "a FRESH, short question".
[ "$bare" = 1 ] && ok "exactly one bare w_alive remains: the drain's deliberately short question" \
                || bad "$bare bare w_alive call(s) - a boot-spanning one would be abandoned; the drain is the only legitimate case"

# SEEN TO FAIL: with the bound taken back out, the boot waits are abandoned again.
D=$(mktemp -d "${TMPDIR:-/tmp}/waitbound-XXXXXX"); trap 'rm -rf "$D"' EXIT
sed -E 's/w_alive "\$vm" "\$\{W_ALIVE_BOOT_BOUND:-[0-9]+\}"/w_alive "$vm"/g' "$W" > "$D/regressed.sh"
read -r _ rbootcalls rbare <<<"$(grade "$D/regressed.sh")"
[ "$rbootcalls" = 0 ] && ok "SEEN TO FAIL: with the bounds removed, 0 boot waits carry one (bare=$rbare)" \
                      || bad "the regression copy still shows $rbootcalls bounded call(s) - the check cannot be driven"
echo "  ---- $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
