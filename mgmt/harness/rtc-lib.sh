#!/bin/bash
# rtc-lib.sh - the hardware clock is UTC, asserted on a guest that may not have been installed from
# the current answer file.
#
# WHY IT IS ITS OWN FILE. The function lived in e2e-wait.sh and was CALLED from prime-run.sh, which
# deliberately does not source e2e-wait.sh (prime-run.sh:66 - it keeps its own UNREADABLE/MOVING
# semantics and must not inherit that file's). So the call resolved to nothing: on the first real
# run, 2026-10-14, prime-run printed `line 537: w_rtc_utc: command not found` and the subject was
# never given the value. The self-test had passed throughout, because it grepped prime-run for the
# TEXT of the call and never asked whether the name resolves.
#
# WHAT THE VALUE DOES. Windows with RealTimeIsUniversal unset computes guest_UTC = RTC -
# guest_TZ_offset. With the qube's `timezone` feature unset the RTC holds true UTC (the Qubes
# default), so a guest whose own zone is NOT UTC then reads wrong by its offset - the permanent +3 h
# measured across the 2026-10-14 campaign (CLOCKRTCLOCALTIME). The answer files set it in the
# specialize pass, so images installed from them carry it from first boot; this is for every image
# that predates that, and for subjects cloned from one.
set -uo pipefail

w_rtc_utc(){ # $1=vm [$2=log fn]
  local vm="${1:?w_rtc_utc <vm>}" lg="${2:-echo}" out
  out=$(QTEST_VM="$vm" timeout -k 5 90 ./tools/qtest run \
        'cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f & reg query "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal' \
        2>/dev/null | tr -d '\r')
  case "$out" in
    *RealTimeIsUniversal*0x1*) $lg "  RTC: RealTimeIsUniversal=1 on $vm (hardware clock is UTC; takes effect next boot)" ; return 0 ;;
    *) $lg "  RTC: [WARN] could not confirm RealTimeIsUniversal on $vm - its clock may read dom0 local time (CLOCKRTCLOCALTIME)" ; return 1 ;;
  esac
}
