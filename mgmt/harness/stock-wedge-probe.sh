#!/bin/bash
# stock-wedge-probe.sh - does the wedge happen with NONE of our code involved?
#
#   mgmt/harness/stock-wedge-probe.sh [rounds]
#
# THE QUESTION, and why the earlier experiments could not answer it. Every arm of
# pnputil-trigger-ab.sh stages OUR xenbus package, so a wedge there is always open to "your
# driver did it". This one adds NOTHING. The subject is the win11-qwt golden, sealed
# 2026-09-06, whose xenbus is 9.1.0.0 - the stock prebuilt, byte-identical to stock QWT
# 4.2.2's, and predating our first xenbus patch (2026-09-11) by five days. The provocation is
# Windows' own PnP restart of the Xen platform device: no package, no INF, no file of ours.
#
# IF IT WEDGES, the defect is in stock components under a PV-bus restart and an install-time
# workaround is justified without pretending we caused it. IF IT NEVER WEDGES across enough
# rounds, then something we ship IS implicated and the workaround would be papering over our
# own bug - which is the answer that must not be assumed away.
#
# Wedge = the measured fingerprint only: Running + qrexec deaf + cpu_time CLIMBING across two
# samples. Deaf with unreadable cpu_time is UNKNOWN, never a pass.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

ROUNDS="${1:-5}"
GOLDEN="${GOLDEN:-win11-qwt}"
SUBJ="${SUBJ:-win11-stock}"
OUT="${OUT:-/home/user/rel/stock-wedge-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }
V="$OUT/verdicts.tsv"; : > "$V"

source mgmt/harness/e2e-wait.sh
source mgmt/harness/vmlock.sh
vm_lock "$SUBJ"
trap 'vm_unlock "$SUBJ" 2>/dev/null' EXIT

PRESERVED=""
cpu_of(){ printf '' | timeout 20 qrexec-client-vm "$1" admin.vm.Stats 2>/dev/null \
          | tr -d '\0' | grep -aoE 'cpu_time[0-9]+' | head -1 | grep -aoE '[0-9]+'; }

classify(){ # -> WEDGED | ALIVE | HALTED | UNKNOWN
  local vm=$1 a b
  [ "$(w_state "$vm")" = Halted ] && { echo HALTED; return; }
  w_alive "$vm" && { echo ALIVE; return; }
  a=$(cpu_of "$vm"); sleep 30; b=$(cpu_of "$vm")
  if [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] 2>/dev/null; then echo WEDGED; else echo UNKNOWN; fi
}

enc(){ python3 -c "import base64,sys;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }

say "=== stock-only wedge probe: golden $GOLDEN, $ROUNDS round(s), NOTHING of ours installed ==="

for r in $(seq 1 "$ROUNDS"); do
  say ""
  say "==== round $r ===="

  qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$SUBJ" && {
    [ "$(w_state "$SUBJ")" != Halted ] && qvm-kill "$SUBJ" >/dev/null 2>&1
    until [ "$(w_state "$SUBJ")" = Halted ]; do sleep 10; done
    qvm-remove -f "$SUBJ" >/dev/null 2>&1
  }
  # create -> tag -> copy volumes (qvm-clone is refused by tag-based policy, see quick-upgrade)
  qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$SUBJ" \
    >/dev/null 2>&1 || { say "  REFUSED: create"; continue; }
  qvm-tags "$SUBJ" add win-idd-testbed >/dev/null 2>&1
  qvm-features "$SUBJ" os Windows >/dev/null 2>&1
  for kv in memory:8192 maxmem:8192 vcpus:4 qrexec_timeout:600; do qvm-prefs "$SUBJ" "${kv%%:*}" "${kv##*:}" >/dev/null 2>&1; done
  qvm-prefs "$SUBJ" netvm '' >/dev/null 2>&1
  python3 - "$GOLDEN" "$SUBJ" >/dev/null 2>&1 <<'PYV' || { say "  REFUSED: volume copy"; continue; }
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
PYV

  timeout 300 qvm-start "$SUBJ" >/dev/null 2>&1     # NO CD: nothing of ours is even mounted
  w_session "$SUBJ" 900 "r$r-boot" "$OUT" say || { say "  VOID: no session"; continue; }

  # PROVE THE SUBJECT IS STOCK before provoking it, or the run says nothing.
  bound=$(QTEST_VM=$SUBJ timeout -k 5 90 ./tools/qtest run \
          "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(enc 'Write-Host ("XBVER=" + (Get-Item C:/Windows/System32/drivers/xenbus.sys).VersionInfo.FileVersion)')" \
          2>/dev/null | tr -d '\r\0' | grep -aoE 'XBVER=[0-9.]+' | tail -1 | cut -d= -f2)
  say "  xenbus bound: ${bound:-<unreadable>}  (9.1.0.0 = stock prebuilt; anything else means this is NOT a stock subject)"
  if [ "$bound" != "9.1.0.0" ]; then
    say "  VOID: subject is not stock - refusing to draw a stock conclusion from it"
    printf '%s\t%s\n' "$r" "VOID-NOT-STOCK" >> "$V"
    continue
  fi

  if VM="$SUBJ" OUT="$OUT/modbases-$r" ./mgmt/harness/arm-module-bases.sh >>"$OUT/arm.log" 2>&1; then
    say "  module-base recorder armed"
  fi

  # THE PROVOCATION: Windows restarts its own PV bus device. No package, no INF, nothing of ours.
  inst=$(QTEST_VM=$SUBJ timeout -k 5 90 ./tools/qtest run \
         "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(enc 'Write-Host ("XBDEV=" + ((Get-PnpDevice | Where-Object { $_.InstanceId -like "PCI\VEN_5853*" } | Select-Object -First 1).InstanceId))')" \
         2>/dev/null | tr -d '\r\0' | grep -aoE 'XBDEV=PCI\\[^ ]+' | tail -1 | cut -d= -f2)
  if [ -z "$inst" ]; then
    say "  VOID: could not find the Xen platform device (PCI\\VEN_5853*)"
    printf '%s\t%s\n' "$r" "VOID-NO-DEVICE" >> "$V"
    continue
  fi
  say "  restarting the STOCK PV bus device: $inst"
  QTEST_VM=$SUBJ timeout -k 10 300 ./tools/qtest run \
    "cmd /c pnputil /restart-device \"$inst\" & echo RC=%errorlevel%" > "$OUT/r$r-restart.out" 2>&1
  tr -d '\r' < "$OUT/r$r-restart.out" | grep -aiE "restart|RC=|failed|error" | head -4 | sed 's/^/    /' | tee -a "$OUT/summary.log"

  verdict=UNKNOWN
  for i in $(seq 1 10); do
    sleep 30
    verdict=$(classify "$SUBJ")
    say "  t+$((i*30))s: $verdict"
    [ "$verdict" = WEDGED ] && break
  done
  printf '%s\t%s\n' "$r" "$verdict" >> "$V"

  if [ "$verdict" = WEDGED ] && [ -z "$PRESERVED" ]; then
    PRESERVED="$SUBJ"; SUBJ="${SUBJ}b"
    say "  *** WEDGED with NOTHING OF OURS INSTALLED - preserving $PRESERVED, continuing as $SUBJ ***"
  fi
done

say ""
say "=== RESULT ==="
w=$(awk -F'\t' '$2=="WEDGED"' "$V" | wc -l); n=$(awk -F'\t' '$2!~/^VOID/' "$V" | wc -l)
say "  stock PV-bus restart wedged $w of $n graded round(s)"
say ""
if [ "$w" -gt 0 ]; then
  say "READ: the wedge reproduces with NO code of ours installed - stock xenbus, stock package,"
  say "Windows' own device restart. An install-time workaround is therefore addressing an"
  say "upstream defect, not covering for ours."
else
  say "READ: NOT reproduced without our code in $n round(s). That is NOT proof we are innocent"
  say "and NOT proof we are guilty - the defect is intermittent and $n rounds is a small sample."
  say "Do not cite this as clearance for an install workaround."
fi
[ -n "$PRESERVED" ] && say "SPECIMEN PRESERVED (armed): $PRESERVED - Running, deaf, untouched."
say "evidence: $OUT"
