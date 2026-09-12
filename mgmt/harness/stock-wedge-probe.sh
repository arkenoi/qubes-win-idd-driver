#!/bin/bash
# stock-wedge-probe.sh - does the wedge happen with NONE of our code involved?
#
#   mgmt/harness/stock-wedge-probe.sh <upstream-xenbus.iso> [rounds]
#
# THE QUESTION, and why the earlier experiments could not answer it. Every arm of
# pnputil-trigger-ab.sh stages OUR xenbus package, so a wedge there is always open to "your
# driver did it". This one adds NOTHING. The subject is the win11-qwt golden, sealed
# 2026-09-06, whose xenbus is 9.1.0.0 - the stock prebuilt, byte-identical to stock QWT
# 4.2.2's, and predating our first xenbus patch (2026-09-11) by five days. The provocation was originally
# Windows' own PnP restart of the Xen platform device: no package, no INF, no file of ours.
#
# IF IT WEDGES, the defect is in stock components under a PV-bus restart and an install-time
# workaround is justified without pretending we caused it. IF IT NEVER WEDGES across enough
# rounds, then something we ship IS implicated and the workaround would be papering over our
# own bug - which is the answer that must not be assumed away.
#
# THE PROVOCATION IS A STOCK PACKAGE INSTALL, not a device restart. A PnP restart cannot be
# attributed to xenbus alone; staging a PURE UPSTREAM xenbus (built with skip_patches, DriverVer
# above the bound 9.1.0.0) over a stock guest is the REAL install action with none of our code
# in it. Pass that ISO/dir as $1.
#
# ROUNDS RESTORE FROM A PARK, they do not rebuild the guest. The subject is built once, parked
# (mgmt/harness/checkpoint.sh - a thin volume clone, 1.6-1.9 s per direction) and unparked
# between rounds. Recreating and re-copying volumes every round cost minutes each and bought
# nothing.
#
# Wedge = the measured fingerprint only: Running + qrexec deaf + cpu_time CLIMBING across two
# samples. Deaf with unreadable cpu_time is UNKNOWN, never a pass.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

ISO="${1:?usage: stock-wedge-probe.sh <upstream-xenbus.iso> [rounds]}"
ROUNDS="${2:-5}"
PARK=stockprobe
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
# ---- the upstream package, pushed once per round (it lands in the session's Documents) ------
PKGDIR="${ISO%/}"
# EVERY FILE, not the four I first guessed at. xenbus.inf also references xen.sys and
# xenfilt.sys, and pushing a partial package makes pnputil answer "Failed to add driver
# package: The system cannot find the file specified" with "Added driver packages: 0" - a
# round that provokes NOTHING and then reads as a clean survival.
for f in xenbus.inf xenbus.sys xenbus.cat xenbus-signer.cer xen.sys xenfilt.sys; do
  [ -f "$PKGDIR/$f" ] || { say "REFUSED: $PKGDIR/$f missing - pass the DIRECTORY holding the pure-upstream xenbus package"; exit 2; }
done
PKGFILES=$(cd "$PKGDIR" && ls *.inf *.sys *.cat *.cer *.dll *.exe 2>/dev/null | tr '\n' ' ')
say "package files to push: $PKGFILES"
UPVER=$(grep -aoE 'DriverVer[^,]*,[0-9.]+' "$PKGDIR/xenbus.inf" | grep -aoE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
say "upstream package to stage: $PKGDIR (DriverVer $UPVER)"
[ "$UPVER" = "9.1.0.0" ] && { say "REFUSED: the upstream build is 9.1.0.0 - it cannot outrank the bound driver, so it would provoke nothing"; exit 2; }

# ---- build the subject ONCE, then park it; rounds unpark instead of rebuilding --------------
if ! qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$SUBJ"; then
  say "building $SUBJ from $GOLDEN (once)"
  qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$SUBJ" \
    >/dev/null 2>&1 || { say "REFUSED: create"; exit 2; }
  qvm-tags "$SUBJ" add win-idd-testbed >/dev/null 2>&1
  qvm-features "$SUBJ" os Windows >/dev/null 2>&1
  for kv in memory:8192 maxmem:8192 vcpus:4 qrexec_timeout:600; do qvm-prefs "$SUBJ" "${kv%%:*}" "${kv##*:}" >/dev/null 2>&1; done
  qvm-prefs "$SUBJ" netvm '' >/dev/null 2>&1
  python3 - "$GOLDEN" "$SUBJ" >/dev/null 2>&1 <<'PYV' || { say "REFUSED: volume copy"; exit 2; }
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
PYV
fi
[ "$(w_state "$SUBJ")" != Halted ] && { qvm-kill "$SUBJ" >/dev/null 2>&1; until [ "$(w_state "$SUBJ")" = Halted ]; do sleep 5; done; }
# checkpoint.sh REFUSES to overwrite an existing park, which is right - it will not silently
# discard someone's restore point. But this label is ours, and a killed run leaves one behind,
# so remove our own before re-parking. (A previous run died here: "REFUSE: park
# ckpt-win11-stock-stockprobe already exists".)
if qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "ckpt-$SUBJ-$PARK"; then
  say "removing our own stale park ckpt-$SUBJ-$PARK from an earlier run"
  qvm-remove -f "ckpt-$SUBJ-$PARK" >/dev/null 2>&1 \
    || { say "REFUSED: stale park ckpt-$SUBJ-$PARK exists and cannot be removed"; exit 2; }
fi
QWT_VMLOCK_HELD="$SUBJ" ./mgmt/harness/checkpoint.sh park "$SUBJ" "$PARK" >>"$OUT/checkpoint.log" 2>&1 \
  && say "parked $SUBJ as $PARK (rounds restore from here - seconds, not a rebuild)" \
  || { say "REFUSED: could not park $SUBJ - see $OUT/checkpoint.log"; tail -2 "$OUT/checkpoint.log" | sed "s/^/  /"; exit 2; }

for r in $(seq 1 "$ROUNDS"); do
  say ""
  say "==== round $r ===="
  [ "$(w_state "$SUBJ")" != Halted ] && { qvm-kill "$SUBJ" >/dev/null 2>&1; until [ "$(w_state "$SUBJ")" = Halted ]; do sleep 5; done; }
  QWT_VMLOCK_HELD="$SUBJ" ./mgmt/harness/checkpoint.sh unpark "$SUBJ" "$PARK" >>"$OUT/checkpoint.log" 2>&1 \
    || { say "  VOID: unpark failed"; printf '%s\t%s\n' "$r" "VOID-UNPARK" >> "$V"; continue; }

  timeout 300 qvm-start "$SUBJ" >/dev/null 2>&1
  w_session "$SUBJ" 900 "r$r-boot" "$OUT" say || { say "  VOID: no session"; printf '%s\t%s\n' "$r" "VOID-NOSESSION" >> "$V"; continue; }

  # PROVE THE SUBJECT IS STOCK before provoking it, or the round says nothing about stock.
  bound=$(QTEST_VM=$SUBJ timeout -k 5 90 ./tools/qtest run \
          "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(enc 'Write-Host ("XBVER=" + (Get-Item C:/Windows/System32/drivers/xenbus.sys).VersionInfo.FileVersion)')" \
          2>/dev/null | tr -d '\r\0' | grep -aoE 'XBVER=[0-9.]+' | tail -1 | cut -d= -f2)
  say "  xenbus bound: ${bound:-<unreadable>} (must be 9.1.0.0 = stock prebuilt)"
  [ "$bound" = "9.1.0.0" ] || { say "  VOID: not a stock subject"; printf '%s\t%s\n' "$r" "VOID-NOT-STOCK" >> "$V"; continue; }

  VM="$SUBJ" OUT="$OUT/modbases-$r" ./mgmt/harness/arm-module-bases.sh >>"$OUT/arm.log" 2>&1 \
    && say "  module-base recorder armed"

  for f in $PKGFILES; do
    QTEST_VM=$SUBJ timeout -k 5 120 ./tools/qtest push "$PKGDIR/$f" >/dev/null 2>&1
  done
  inc='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
  QTEST_VM=$SUBJ timeout -k 5 120 ./tools/qtest run \
    "cmd /v:on /c certutil -addstore -f Root $inc\\xenbus-signer.cer & certutil -addstore -f TrustedPublisher $inc\\xenbus-signer.cer & echo CERTRC=!errorlevel!" \
    > "$OUT/r$r-cert.out" 2>&1
  say "  signer cert import rc=$(tr -d '\r' < "$OUT/r$r-cert.out" | grep -aoE 'CERTRC=[0-9]+' | tail -1 | sed 's/CERTRC=//')"

  # THE PROVOCATION: a PURE UPSTREAM xenbus package, ranked above the bound stock one. No file
  # of ours is involved - not the driver, not the INF, not the installer.
  say "  staging PURE UPSTREAM xenbus $UPVER over the bound 9.1.0.0"
  QTEST_VM=$SUBJ timeout -k 10 300 ./tools/qtest run \
    "cmd /v:on /c pnputil /add-driver $inc\\xenbus.inf & echo RC=!errorlevel!" > "$OUT/r$r-stage.out" 2>&1
  tr -d '\r' < "$OUT/r$r-stage.out" | grep -aiE "adding|added|total|RC=|failed|error" | head -4 | sed 's/^/    /' | tee -a "$OUT/summary.log"

  # THE PROVOCATION MUST BE PROVEN TO HAVE HAPPENED. pnputil says so in its own words, and
  # "Added driver packages: 0" means this round staged nothing - grading it would record a
  # survival that was never tested. Round 1 of the first attempt did exactly that.
  added=$(tr -d '\r' < "$OUT/r$r-stage.out" | grep -aoE 'Added driver packages: *[0-9]+' | grep -aoE '[0-9]+' | tail -1)
  if ! [ "${added:-0}" -ge 1 ] 2>/dev/null; then
    say "  VOID: pnputil added ${added:-?} package(s) - nothing was provoked, this round grades nothing"
    tr -d '\r' < "$OUT/r$r-stage.out" | grep -aiE "failed|error" | head -2 | sed 's/^/    /' | tee -a "$OUT/summary.log"
    printf '%s\t%s\n' "$r" "VOID-NOT-STAGED" >> "$V"
    continue
  fi
  say "  provocation confirmed: pnputil added $added package(s)"

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
    say "  *** WEDGED WITH NO CODE OF OURS - preserving $PRESERVED; later rounds use $SUBJ ***"
    QWT_VMLOCK_HELD="$SUBJ" ./mgmt/harness/checkpoint.sh park "$PRESERVED" "$PARK" >>"$OUT/checkpoint.log" 2>&1 || true
  fi
done

say ""
say "=== RESULT ==="
w=$(awk -F'\t' '$2=="WEDGED"' "$V" | wc -l); n=$(awk -F'\t' '$2!~/^VOID/' "$V" | wc -l)
say "  PURE UPSTREAM xenbus staged over stock: wedged $w of $n graded round(s)"
say ""
if [ "$w" -gt 0 ]; then
  say "READ: the wedge reproduces with NO code of ours involved - stock guest, pure upstream"
  say "package, ordinary pnputil staging. An install-time workaround addresses an UPSTREAM"
  say "defect; it is not covering for something we ship."
else
  say "READ: NOT reproduced without our code in $n round(s). That is neither innocence nor"
  say "guilt - the defect is intermittent and $n rounds is a small sample. Do NOT cite this as"
  say "clearance for an install workaround."
fi
[ -n "$PRESERVED" ] && say "SPECIMEN PRESERVED (armed): $PRESERVED"
say "evidence: $OUT"
