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
      eval "$(sed -n "/^w_rtc_utc()/,/^}$/p" "$0/mgmt/harness/rtc-lib.sh")"
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

# AND THE NAME MUST RESOLVE THERE. This suite asserted the call's TEXT and nothing else, so it
# passed while the call could not work: the function lived in e2e-wait.sh, prime-run deliberately
# does not source that file (prime-run.sh:66), and the first real run printed
# `line 537: w_rtc_utc: command not found` - the subject was never given the value.
ck "the file prime-run sources DEFINES it"                 "1" \
   "$(grep -c '^w_rtc_utc()' mgmt/harness/rtc-lib.sh)"
ck "prime-run sources that file"                           "1" \
   "$(grep -c '^source mgmt/harness/rtc-lib.sh' mgmt/harness/prime-run.sh)"
# The chain, actually executed: source exactly what prime-run sources, then ask bash whether the
# name is a function. A grep cannot answer this; this can.
ck "and the name resolves in prime-run's context"          "RESOLVES" \
   "$(bash -c 'eval "$(grep -E "^source mgmt/harness/" mgmt/harness/prime-run.sh)" 2>/dev/null; declare -f w_rtc_utc >/dev/null && echo RESOLVES || echo UNRESOLVED')"
ck "e2e-wait.sh still provides it to ITS callers"          "RESOLVES" \
   "$(bash -c 'source mgmt/harness/e2e-wait.sh 2>/dev/null; declare -f w_rtc_utc >/dev/null && echo RESOLVES || echo UNRESOLVED')"
ck "and no harness still forces a localtime RTC"           "0" \
   "$(grep -vE '^[[:space:]]*#' mgmt/harness/*.sh | grep -c 'timezone localtime')"

# ---- THE QUBE FEATURE COMES BACK AT EVERY INSTALL --------------------------------------------
# `timezone` decides what the qube's RTC holds: unset = true UTC (the Qubes default, and what every
# Linux qube here has), `localtime` = DOM0 LOCAL. Our images set RealTimeIsUniversal=1, so Windows
# reads the RTC as UTC - correct only while the feature stays unset.
# MEASURED 2026-10-15 on the acceptance run: the harness unset it BEFORE the install, the install
# reported os=Windows to dom0 and the feature came back as `localtime` on every QWT-carrying guest
# (win10-acc, win10-iqi, win11r-qwt, win11de-qwt) while the bases and a fresh qvm-create qube had it
# unset. The guest then read a dom0-local RTC as UTC: 3 hours out on every boot after the first,
# clock_boot_correction_s = 10800 against a max of 60.
#
# AND CLEARING IT IN THE HARNESS WAS THE WRONG FIX - this block asserted that clearing, which is how
# the inversion stayed green. dom0 sets the feature for EVERY os=Windows qube, so a user's qube keeps
# `localtime`; unsetting it on the rig puts the rig into the one configuration where the shipped
# RealTimeIsUniversal=1 is true, and the gate then stops measuring what a user gets. Jev:
# harness_clear_hides_it 0.84, harness_feature_clear_is_substitution 0.74 (separate calls, different
# sources). The defect belongs in the product (RTIUWRONGDEFAULT); the harness only REPORTS the
# convention so clock_boot_correction_s can be read against it.
#
# COMMENTS STRIPPED FIRST, because the prose above names both the old function and the command it
# ran, and a grep of the raw file would find its own explanation - which has happened repeatedly in
# this repo's checks.
mcode(){ sed 's/#.*//' mgmt/harness/matrix.sh; }
ck "the harness REPORTS the convention"           "1" \
   "$(command grep -c '^clock_feature_report()' mgmt/harness/matrix.sh)"
# THE UNSET THAT MATTERS IS A POST-INSTALL ONE. Normalising a FRESH subject at create time is
# legitimate and is not what hid the P1: dom0 re-sets the feature during the install anyway, so a
# create-time unset says only "start out like the golden". What concealed the defect was unsetting it
# AFTER the install, in the per-cell hooks, which is where the gate reads the clock from. So these
# checks name the post-install hooks rather than counting unsets anywhere - the broad count flagged
# ensure_churn_target and cell_appvm, both of which run before any install.
ck "the post-prime sweep never unsets it"         "0" \
   "$(awk '/^clear_prime_leftovers\(\)/,/^\}/' mgmt/harness/matrix.sh | sed 's/#.*//' | command grep -cE 'qvm-features +--unset +[^ ]+ +timezone')"
ck "the per-cell hook never unsets it"            "0" \
   "$(awk '/^logvol_bind_now\(\)/,/^\}/' mgmt/harness/matrix.sh | sed 's/#.*//' | command grep -cE 'qvm-features +--unset +[^ ]+ +timezone')"
ck "the reporter itself never unsets it"          "0" \
   "$(awk '/^clock_feature_report\(\)/,/^\}/' mgmt/harness/matrix.sh | sed 's/#.*//' | command grep -cE 'qvm-features +--unset')"
# And the only remaining unsets are the two create-time ones, so a third cannot appear unnoticed.
ck "exactly two create-time unsets remain"        "2" \
   "$(mcode | command grep -cE 'qvm-features +--unset +[^ ]+ +timezone')"
ck "the old clearing function is gone"            "0" \
   "$(mcode | command grep -c 'clock_feature_reset')"
# It must still run where an install has JUST happened, so the convention is recorded per cell.
ck "called after the prime sweep"                 "1" \
   "$(awk '/^clear_prime_leftovers\(\)/,/^\}/' mgmt/harness/matrix.sh | sed 's/#.*//' | command grep -c 'clock_feature_report')"
ck "and on the per-cell post-install hook"        "1" \
   "$(awk '/^logvol_bind_now\(\)/,/^\}/' mgmt/harness/matrix.sh | sed 's/#.*//' | command grep -c 'clock_feature_report')"
# and it must not be gated behind the log-volume switch, which is unrelated to the clock
ck "not gated behind the log volume"              "1" \
   "$(awk '/^logvol_bind_now\(\)/,/LOGVOL_BIND/' mgmt/harness/matrix.sh | sed 's/#.*//' | command grep -c 'clock_feature_report')"
# The report must name BOTH conventions, or a reader cannot tell which one the cell ran under.
ck "it names the localtime case"                  "1" \
   "$(awk '/^clock_feature_report\(\)/,/^\}/' mgmt/harness/matrix.sh | command grep -c 'dom0 LOCAL time')"
ck "it names the unset case"                      "1" \
   "$(awk '/^clock_feature_report\(\)/,/^\}/' mgmt/harness/matrix.sh | command grep -c 'true UTC')"

echo "rtc-utc-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
