#!/bin/bash
# rtc-lib.sh - REPORT the guest's clock convention. The harness does not decide it.
#
# WHAT THIS USED TO DO, AND WHY IT HAD TO STOP. `w_rtc_utc` WROTE
# RealTimeIsUniversal=1 into the subject, from the harness, right after every install
# (prime-run.sh called it the moment qrexec answered). That is the harness deciding a product
# setting, and it made the gate unable to measure the product at all: whatever the installer and the
# per-boot task had derived was overwritten on every primed subject. Measured on run 11 - the
# installer logged `RealTimeIsUniversal set to 0 for the next boot`, and the guest was nonetheless
# running with 1 on the boots that followed, with the clock three hours out.
#
# ONLY ONE OF THE TWO VALUES IS CORRECT FOR A GIVEN QUBE AND THE HARNESS CANNOT KNOW WHICH.
# Windows computes guest_UTC = RTC - guest_TZ_offset when the value is unset, and = RTC when it is
# 1. What the RTC holds is decided by the qube's `timezone` feature: unset means true UTC (Xen's
# default), `localtime` means DOM0 LOCAL - and qubes-core-admin sets `localtime` for every
# os=Windows qube once the GUEST reports os+qrexec, which is a runtime event the harness does not
# observe. Forcing 1 is therefore right for one configuration and wrong for the other, and it was
# forced unconditionally.
#
# SO THE PRODUCT DERIVES IT, from a witness that is not the thing under test: the per-boot task
# (guest/sync-clock-from-dom0.ps1, CLOCKCONV) reads set-time.ps1's own SETTIME line, which carries
# dom0's UTC, the pre-set skew and the guest's offset - all measured before the clock was touched -
# and sets the value from what it finds. The harness's job is to REPORT what the guest carries so a
# cell's verdict can be read against it, and nothing else.
#
# THE ORIGINAL REASON THIS FILE EXISTS still holds and is unchanged: it is sourced by both
# prime-run.sh and e2e-wait.sh, because prime-run deliberately does not source e2e-wait (it keeps
# its own UNREADABLE/MOVING semantics), so a function defined only in e2e-wait resolved to nothing
# there - measured 2026-10-14 as `line 537: w_rtc_utc: command not found`.
set -uo pipefail

w_rtc_report(){ # $1=vm [$2=log fn] - report the convention; never change it. Always returns 0.
  local vm="${1:?w_rtc_report <vm>}" lg="${2:-echo}" out
  # A DELIMITER, BECAUSE THE TWO ANSWERS SHARE ONE STREAM. Parsing the zone by position after the
  # registry value printed `0x1  FLE Standard Time C:\Windows\system32>` - the reg value, the zone
  # and cmd's own prompt in one line. `tzutil /g` writes no newline, so the prompt lands on it too.
  out=$(QTEST_VM="$vm" timeout -k 5 90 ./tools/qtest run \
        'cmd /c reg query "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal & echo ZONEIS: & tzutil /g & echo .' \
        2>/dev/null | tr -d '\r')
  case "$out" in
    *RealTimeIsUniversal*0x1*)
      $lg "  RTC: RealTimeIsUniversal=1 on $vm - the guest reads its RTC as UTC (correct only while the qube's timezone feature is unset)" ;;
    *RealTimeIsUniversal*0x0*)
      $lg "  RTC: RealTimeIsUniversal=0 on $vm - the guest reads its RTC as local time (correct only while the qube's timezone feature is localtime)" ;;
    *RealTimeIsUniversal*)
      $lg "  RTC: RealTimeIsUniversal present but unreadable on $vm: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)" ;;
    *)
      $lg "  RTC: RealTimeIsUniversal is UNSET on $vm - Windows reads the RTC as local time by default" ;;
  esac
  # The zone matters as much as the value: the pairing is only correct when the guest's offset
  # equals dom0's, so a reader needs both numbers side by side.
  zone=$(printf '%s' "$out" | sed -n '/^ZONEIS:/,$p' | sed '1d' | command grep -am1 '[A-Za-z]' | sed 's/[[:space:]]*$//')
  case "$zone" in
    ""|.*) $lg "  RTC: guest zone on $vm could not be read (tzutil printed nothing)" ;;
    *)     $lg "  RTC: guest zone on $vm: $zone" ;;
  esac
  return 0
}
