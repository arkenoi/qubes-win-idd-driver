#!/bin/bash
# idd-cycle-hunt.sh - repeat the DEVICE SURGERY + REBOOT cycle, which is where the wedge lives.
#
# HYPOTHESIS: the wedge needs the transition our installer creates - a driver package staged, a
#   devnode created, a live adapter disabled, then a BOOT - not steady-state device churn. Two
#   stress experiments in steady state (a TLB storm of ~10^9 page events, and the same plus USB
#   root-hub load/unload cycling) produced NO wedge; Jev then rated the negatives
#   `wrong-conditions-not-wrong-class` 1.00 and picked `boot-after-fresh-device-surgery` (0.66)
#   as the next experiment. Three of the four natural occurrences are at or just after such a boot.
# BASELINE: the same guest, same package, cycling with NO device surgery is not a useful control
#   here (that is what the storm runs already were); the control is the ARM, below.
# VARIABLE: ARM=new uses the serialised activate-idd.ps1 (waits for PnP to settle after the driver
#   is staged and before the adapter is disabled); ARM=old uses the version from before that
#   change. Same guest, same driver payload, alternate the arms yourself across runs.
# INSTRUMENT: the wedge oracle is the specimen fingerprint - the guest stops answering qrexec (or
#   refuses to halt) while the domain's cpu_time keeps advancing. On a wedge: dom0 forensics, and
#   a memory image for the first one. Cycles are ~3-4 minutes, against 25-40 for a clean install.
# BUDGET: default 20 cycles, about 70-80 minutes.
#
#   VM=<guest> ARM=new|old mgmt/harness/idd-cycle-hunt.sh [cycles] [setup-tree]
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${VM:?set VM to the guest to cycle}"
ARM="${ARM:-new}"
N="${1:-20}"
TREE="${2:-/home/user/qwt-accept/rel-35789898345/dl/qwt-improved-setup}"
export QTEST_VM="$VM"
. mgmt/harness/vmlock.sh
vm_lock "$VM"
OUT="scratchpad/iddcycle-$(date -u +%Y%m%dT%H%M%SZ)-$ARM"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) iddcycle[$ARM]: $*" | tee -a "$OUT/run.log"; }
I='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'

state(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$VM" '$1==v{print $2}'; }
cpu(){ python3 - "$VM" <<'PY'
import sys
try:
    import qubesadmin
    print(int(qubesadmin.Qubes().domains[sys.argv[1]].get_cputime() or 0))
except Exception:
    print(0)
PY
}
alive(){ timeout -k 5 45 ./tools/qtest run 'cmd /c echo PONG' 2>/dev/null | grep -qa PONG; }
wedge_check(){ # $1=tag -> 0 healthy, 1 wedged+captured
  local c1 c2; c1=$(cpu); sleep 20; c2=$(cpu)
  if [ "${c2:-0}" -gt "${c1:-0}" ]; then
    say "WEDGE at $1: unreachable while cpu_time advances ($c1 -> $c2)"
    local d="$OUT/wedge-$1"; mkdir -p "$d"
    timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$VM" </dev/null > "$d/forensics.tar" 2>"$d/err" && say "  forensics -> $d"
    [ -f "$OUT/.core" ] || { bash mgmt/harness/fetch-wedge-core.sh "$VM" "$d/guest.core" >>"$d/core.log" 2>&1 && touch "$OUT/.core" && say "  memory image -> $d/guest.core"; }
    return 1
  fi
  say "  $1: not answering but cpu_time flat ($c1 -> $c2) - not the wedge fingerprint"
  return 0
}
boot_and_wait(){ # $1=tag -> 0 up, 1 wedged
  [ "$(state)" = Halted ] || { say "  $1: guest did not halt - checking"; wedge_check "$1-halt" || return 1; qvm-kill "$VM" >/dev/null 2>&1; sleep 8; }
  qvm-start "$VM" >/dev/null 2>&1
  for _ in $(seq 1 24); do alive && return 0; sleep 10; done
  say "  $1: no qrexec after 240 s"
  wedge_check "$1-boot" || return 1
  return 0
}
guest_poweroff(){ timeout -k 5 45 ./tools/qtest run 'cmd /c shutdown /s /t 3 /f' >/dev/null 2>&1
  for _ in $(seq 1 24); do [ "$(state)" = Halted ] && return 0; sleep 10; done; return 1; }

[ -d "$TREE/idd-driver" ] || { say "TERMINAL: $TREE/idd-driver missing - need the release setup tree"; exit 2; }
[ "$(state)" = Running ] || qvm-start "$VM" >/dev/null 2>&1
for _ in $(seq 1 24); do alive && break; sleep 10; done
alive || { say "TERMINAL: $VM never answered qrexec"; exit 2; }

# THE ARM: which activate-idd.ps1 the guest runs. 'old' is fetched from git, so the comparison is
# against what actually shipped before the serialisation, not a hand-edited copy.
mkdir -p "$OUT/payload/idd-driver"
cp "$TREE"/idd-driver/* "$OUT/payload/idd-driver/" 2>/dev/null
cp guest/deactivate-idd.ps1 "$OUT/payload/"
if [ "$ARM" = old ]; then
  git show 2e84fd3~1:guest/activate-idd.ps1 > "$OUT/payload/activate-idd.ps1" || { say "TERMINAL: cannot fetch the pre-serialisation activate-idd.ps1"; exit 2; }
else
  cp guest/activate-idd.ps1 "$OUT/payload/activate-idd.ps1"
fi
say "arm=$ARM payload from $TREE"
timeout -k 8 180 ./tools/qtest push "$OUT/payload/activate-idd.ps1" "$OUT/payload/deactivate-idd.ps1" >/dev/null 2>&1
timeout -k 8 300 ./tools/qtest push "$OUT/payload"/idd-driver/* >/dev/null 2>&1
# activate-idd expects -Root <dir> holding idd-driver\ ; QubesIncoming is flat, so rebuild it there
timeout -k 8 60 ./tools/qtest run "cmd /c mkdir $I\\idd-driver 2>nul & move /y $I\\IddSampleDriver.* $I\\idd-driver\\ & move /y $I\\devcon.exe $I\\idd-driver\\ & move /y $I\\iddsampledriver.cat $I\\idd-driver\\" >/dev/null 2>&1

wedged=0
for c in $(seq 1 "$N"); do
  say "cycle $c/$N: DEACTIVATE (re-enable VGA, remove the IDD devnode)"
  timeout -k 10 600 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File $I\\deactivate-idd.ps1 -Root $I" 2>/dev/null | tr -d '\r' | tail -3 >> "$OUT/cycle-$c.log"
  guest_poweroff || { wedge_check "c$c-off1" || { wedged=1; break; }; qvm-kill "$VM" >/dev/null 2>&1; sleep 8; }
  boot_and_wait "c$c-b1" || { wedged=1; break; }
  say "cycle $c/$N: ACTIVATE (stage driver, create devnode, disable VGA)"
  timeout -k 10 900 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File $I\\activate-idd.ps1 -Root $I -NoReboot" 2>/dev/null | tr -d '\r' | tail -4 >> "$OUT/cycle-$c.log"
  guest_poweroff || { wedge_check "c$c-off2" || { wedged=1; break; }; qvm-kill "$VM" >/dev/null 2>&1; sleep 8; }
  boot_and_wait "c$c-b2" || { wedged=1; break; }
  say "  cycle $c complete, guest healthy"
done
say "RESULT arm=$ARM: wedged=$wedged after $(( wedged == 1 ? c : N )) cycle(s) of $N"
say "evidence: $OUT"
[ "$wedged" = 0 ]
