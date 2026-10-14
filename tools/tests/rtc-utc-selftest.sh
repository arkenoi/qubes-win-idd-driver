#!/bin/bash
# rtc-utc-selftest.sh - the hardware clock is UTC, asserted on a guest we did not install.
#
# WHY. The answer file sets RealTimeIsUniversal in the specialize pass, so every image installed
# from it reads the RTC as UTC from its first boot. Every golden on this rig predates that, and a
# subject cloned from one inherits the old registry: Windows then reads the RTC as LOCAL time and
# the guest's UTC comes out wrong by dom0's offset - the permanent +3 h measured on 2026-10-14
# (CLOCKRTCLOCALTIME), which our clock puller then re-corrected three times in six minutes.
# Subjects are disposable, so w_rtc_utc sets it on the subject instead of waiting for every golden
# to be rebuilt. Driven here against a STUB qtest: what is tested is the command shape, the
# read-back, and that an unconfirmed guest is reported rather than assumed fine.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
ROOT=$PWD

T=$(mktemp -d "${TMPDIR:-/tmp}/rtc-utc.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: expected '$2', got '$3'"; fi; }

# w_rtc_utc calls ./tools/qtest, so the stub goes at that relative path in a scratch root.
mkdir -p "$T/tools"
cat > "$T/tools/qtest" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUBLOG"
if [ "${STUBMODE:-ok}" = ok ]; then printf 'RealTimeIsUniversal    REG_DWORD    0x1\r\n'
else printf 'ERROR: The system was unable to find the specified registry key\r\n'; fi
STUB
chmod +x "$T/tools/qtest"

run_case(){ # <mode> <logfile> -> rc
  ( cd "$T" && STUBLOG="$T/$2" STUBMODE="$1" bash -c '
      eval "$(sed -n "/^w_rtc_utc()/,/^}$/p" "$0/mgmt/harness/e2e-wait.sh")"
      w_rtc_utc stubvm echo' "$ROOT" >"$T/$2.out" 2>&1 )
}

run_case ok  calls-ok.txt;  rc_ok=$?
run_case bad calls-bad.txt; rc_bad=$?

ck "a guest confirming 0x1 is accepted"                    "0" "$rc_ok"
ck "a guest that cannot confirm is reported, not assumed"  "1" "$([ "$rc_bad" -ne 0 ] && echo 1 || echo 0)"
ck "the documented value is written"                       "1" \
   "$(grep -ac 'RealTimeIsUniversal /t REG_DWORD /d 1 /f' "$T/calls-ok.txt")"
ck "under TimeZoneInformation, not somewhere else"         "1" \
   "$(grep -ac 'CurrentControlSet.Control.TimeZoneInformation' "$T/calls-ok.txt")"
ck "the value is read BACK, so a failed write cannot pass" "1" \
   "$(grep -ac 'reg query' "$T/calls-ok.txt")"
ck "the unconfirmed case says so in its line"              "1" \
   "$(grep -ac 'could not confirm RealTimeIsUniversal' "$T/calls-bad.txt.out")"

# Wiring: one call site, at the point every harness's subject becomes answerable.
ck "NOT on the common session-up path"                     "0" \
   "$(grep -c 'w_rtc_utc "\$vm" "\$log"' mgmt/harness/e2e-wait.sh)"
ck "called where a subject is PREPARED, once"              "1" \
   "$(grep -c 'w_rtc_utc "\$CHURN" log' mgmt/harness/prime-run.sh)"
ck "and no harness still forces a localtime RTC"           "0" \
   "$(grep -vE '^[[:space:]]*#' mgmt/harness/*.sh | grep -c 'timezone localtime')"

echo "rtc-utc-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
