#!/usr/bin/env bash
# logvol-lib-selftest.sh - offline proof matrix for mgmt/harness/logvol-lib.sh (the secondary log volume,
# PLAN-acceptance-optimization section 3) and its guest-side binder.
#
# No rig, no guest, no loop device: udisksctl / qvm-device / qvm-features / losetup / tools/qtest are PATH
# shims that RECORD what they were asked and answer like the real ones; mkfs.fat and mtools are REAL on an
# image file, which is exactly how the host reads the volume on the rig. Every check that can be seen to
# fail is run twice: on the shipped library and on a copy with ONE `# GUARD:<knob>` line replaced by the
# defect written beside it (the log-sweep-selftest idiom) - the copy must NOT pass.
#
#   create      a fresh FAT image carries LOGVOL.TAG with the id and a serial derived from the id
#   archive     recreating over a volume that holds files archives them first (knob: archive)
#   pull        a live host-side read returns every file without detaching anything (knob: pullempty)
#   salvage     a log line whose bytes are in the image but under no directory entry is recovered
#   compose     our drive + device are ADDED to an existing answer-stick controller, never overwrite it
#               (knob: compose); the drive carries cache=writethrough (knob: writethrough); idempotent (knob: idempotent)
#   strip       our fragments are removed and the stick's are untouched; our own controller goes with them
#   attach      loop + --required assign at xvdk read-only=false + qemu args + manifest, in that order;
#               a sealed golden is REFUSED (knob: seal)
#   detach      unassign + strip; the loop is released only when the guest is Halted
#   bind        the guest binder parses (pwsh) and sets LogSafeFlush=1 and LogDir at the root key
#   winpe       the WinPE copier is synchronous (no `start`), never exits non-zero, finds the volume by tag
#
#   LOGVOL_SELFTEST_OUT=<dir>  keep fixtures and outputs (default: a mktemp dir, removed on exit)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/mgmt/harness/logvol-lib.sh"
T="${LOGVOL_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/logvol-selftest-XXXXXX")}"
[ -n "${LOGVOL_SELFTEST_OUT:-}" ] || trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/img"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
for t in mkfs.fat mcopy mdir mmd; do command -v $t >/dev/null || { echo "FAIL  $t is not installed - nothing ran (missing data fails)"; exit 2; }; done

# ---- the shims: record every call in $T/calls.log, answer like the rig ---------------------------------------
cat > "$T/bin/udisksctl" <<'SH'
#!/bin/bash
echo "udisksctl $*" >> "$CALLS"
case "$1" in
  loop-setup) echo "Mapped file $3 as /dev/loop77." ;;
  loop-delete) exit 0 ;;
esac
SH
cat > "$T/bin/losetup" <<'SH'
#!/bin/bash
echo "losetup $*" >> "$CALLS"
# a pre-existing loop for the image named in $LOOP_BACKING, like the real `losetup -l`
if [ -n "${LOOP_BACKING:-}" ]; then
  printf 'NAME SIZELIMIT OFFSET AUTOCLEAR RO BACK-FILE DIO LOG-SEC\n/dev/loop5 0 0 1 0 %s 0 512\n' "$LOOP_BACKING"
else
  printf 'NAME SIZELIMIT OFFSET AUTOCLEAR RO BACK-FILE DIO LOG-SEC\n'
fi
SH
cat > "$T/bin/qvm-device" <<'SH'
#!/bin/bash
echo "qvm-device $*" >> "$CALLS"
if [ "${ASSIGN_ALREADY:-}" = 1 ] && [ "$2" = assign ]; then echo "qvm-device: device already assigned" >&2; exit 1; fi
exit 0
SH
cat > "$T/bin/qvm-features" <<'SH'
#!/bin/bash
echo "qvm-features $*" >> "$CALLS"
F="$FEATSTORE"
if [ "$1" = "--unset" ]; then rm -f "$F"; exit 0; fi
if [ $# -eq 2 ]; then [ -f "$F" ] && cat "$F" && exit 0; exit 1; fi
if [ "$3" = "--" ]; then printf '%s' "$4" > "$F"; exit 0; fi
printf '%s' "$3" > "$F"
SH
cat > "$T/bin/qtest" <<'SH'
#!/bin/bash
echo "qtest $*" >> "$CALLS"
case "$1" in
  state) echo "power_state=${QSTATE:-Halted}" ;;
  pushrun) echo "C:\\Windows\\System32>powershell -File logvol-bind.ps1 $*"; echo "${BIND_ANSWER:-LOGVOL-BIND ok mode=registry id=x drive=E: old=UQ== new=RQ== copied=3 safeflush=1}" ;;
esac
SH
chmod +x "$T"/bin/*
export CALLS="$T/calls.log" FEATSTORE="$T/feat.txt" QTEST_BIN="$T/bin/qtest"
export PATH="$T/bin:$PATH"
export LOGVOL_DIR="$T/img" LOGVOL_ARCHIVE_DIR="$T/img/archive"

# a copy of the library with ONE guard line replaced by its defect
# FATAL goes to stderr and the function RETURNS non-zero: it runs inside $(...), so an `exit` here would
# only leave the subshell and hand the caller the FATAL text as a library path - which is how the
# first version of this test passed the 'archive' knob on a copy that did not even parse.
knob(){ local n="$1" out="$T/lib-$1.sh" hits
  hits=$(grep -c "# GUARD:$n DEFECT: " "$LIB")
  [ "$hits" = 1 ] || { echo "FATAL: GUARD:$n appears $hits times in $LIB (want exactly 1)" >&2; return 2; }
  sed -E "s|^( *)[^#]*# GUARD:$n DEFECT: (.*)$|\1\2|" "$LIB" > "$out"
  [ "$(diff "$LIB" "$out" | grep -c '^>')" = 1 ] || { echo "FATAL: knob $n changed $(diff "$LIB" "$out" | grep -c '^>') lines" >&2; return 2; }
  bash -n "$out" 2>&1 >/dev/null | head -2 >&2
  bash -n "$out" 2>/dev/null || { echo "FATAL: knob $n does not parse" >&2; return 2; }
  bash -c ". '$out'" 2>/dev/null || { echo "FATAL: knob $n does not source" >&2; return 2; }
  printf '%s' "$out"; }
# run <lib> <bash snippet>  in a fresh shell with the library sourced; stdout returned, stderr to $T/last.err
run(){ local lib="$1"; shift; bash -c ". '$lib'; $*" 2>"$T/last.err"; }

# ---- create -------------------------------------------------------------------------------------------------
IMG=$(run "$LIB" 'logvol_image cell-A1')
[ "$IMG" = "$T/img/logs-cell-A1.img" ] && ok "image path: $IMG" || bad "image path: got '$IMG'"
run "$LIB" "logvol_create '$IMG' cell-A1 64" >/dev/null; rc=$?
tag=$(mcopy -i "$IMG" ::/LOGVOL.TAG - 2>/dev/null | tr -d '\r')
if [ $rc -eq 0 ] && printf '%s' "$tag" | grep -q '^id=cell-A1' && [ "$(stat -c%s "$IMG")" = $((64*1024*1024)) ]; then
  ok "create: 64M FAT with LOGVOL.TAG id=cell-A1 ($(printf '%s' "$tag" | tr '\n' ' '))"
else bad "create: rc=$rc tag='$tag' size=$(stat -c%s "$IMG" 2>/dev/null)"; fi
mdir -i "$IMG" ::/ 2>/dev/null | grep -q 'LOGVOL' && ok "create: the volume label is LOGVOL" || bad "create: label missing ($(mdir -i "$IMG" ::/ 2>&1 | head -2 | tr '\n' ' '))"
ser1=$(bash -c ". '$LIB'; _lv_serial cell-A1"); ser2=$(bash -c ". '$LIB'; _lv_serial cell-A1"); ser3=$(bash -c ". '$LIB'; _lv_serial cell-B2")
[ "$ser1" = "$ser2" ] && [ "$ser1" != "$ser3" ] && ok "create: the volume serial is a function of the id ($ser1 vs $ser3)" || bad "create: serial not stable/unique ($ser1 $ser2 $ser3)"
run "$LIB" "logvol_create '$IMG' 'bad id!' 64" >/dev/null; rc=$?
[ $rc -eq 2 ] && ok "create: an id with a space is REFUSED (rc=2)" || bad "create: bad id accepted (rc=$rc)"

# ---- a volume with files on it, as a guest would leave it -------------------------------------------------------
mkdir -p "$T/guest/qwt-logs/cell-A1"
printf '[20261013.100000.000-100:200-I] LogInit: Log started, module name: gui-agent\n[20261013.100001.000-100:200-E] Foo: the last line before the wedge\n' > "$T/guest/qwt-logs/cell-A1/gui-agent-20261013.log"
printf '[20261013.100000.500-300:301-I] LogInit: Log started, module name: gui-watchdog\n' > "$T/guest/qwt-logs/cell-A1/gui-watchdog-20261013.log"
mcopy -s -i "$IMG" "$T/guest/qwt-logs/cell-A1" ::/qwt-logs/ 2>/dev/null || mcopy -s -i "$IMG" "$T/guest/qwt-logs/cell-A1" ::/qwt-logs/cell-A1

# ---- pull: a host-side read, nothing detached ------------------------------------------------------------------
: > "$CALLS"
out=$(run "$LIB" "logvol_pull '$IMG' '$T/pull1'")
if printf '%s' "$out" | grep -q 'LOGVOL-PULLED.*files=3' && grep -q 'the last line before the wedge' "$T/pull1/files/qwt-logs/cell-A1/gui-agent-20261013.log" 2>/dev/null \
   && ! grep -qE 'udisksctl|qvm-device' "$CALLS"; then
  ok "pull: 3 files read back on the host (the tag + 2 logs), nothing detached or unassigned"
else bad "pull: $out / calls: $(cat "$CALLS" | tr '\n' ';')"; fi
# knob pullempty: an empty volume must FAIL the pull on the shipped library and pass with the knob
EMPTY="$T/img/logs-empty.img"; run "$LIB" "logvol_create '$EMPTY' empty 64" >/dev/null
# an image with only the tag file is not "empty" - remove the tag to make it so
mdel -i "$EMPTY" ::/LOGVOL.TAG 2>/dev/null
run "$LIB" "logvol_pull '$EMPTY' '$T/pullE'" >/dev/null; rc=$?
K=$(knob pullempty) || exit 2; run "$K" "logvol_pull '$EMPTY' '$T/pullEk'" >/dev/null; rck=$?
[ $rc -eq 1 ] && [ $rck -eq 0 ] && ok "pull: a volume with no files FAILS (rc=1), and the knob 'pullempty' makes it pass (seen to fail)" || bad "pull empty: rc=$rc knob rc=$rck"

# ---- salvage: bytes in the image under no directory entry -------------------------------------------------------
# Append a log-shaped line into the data region past the last cluster in use, like a tail whose
# directory entry was never updated. mcopy cannot return it; the raw scan must.
SAL="$T/img/logs-salvage.img"; cp "$IMG" "$SAL"
printf '[20261013.100002.000-100:200-E] Hang: THE-ORPHANED-TAIL vchan pressure here\n' | dd of="$SAL" bs=1 seek=$((48*1024*1024)) conv=notrunc 2>/dev/null
run "$LIB" "logvol_pull '$SAL' '$T/pullS'" >/dev/null
out=$(run "$LIB" "logvol_salvage '$SAL' '$T/pullS'")
if ! grep -rq 'THE-ORPHANED-TAIL' "$T/pullS/files" && grep -q 'THE-ORPHANED-TAIL' "$T/pullS/salvage.txt" && grep -q 'the last line before the wedge' "$T/pullS/salvage.txt"; then
  ok "salvage: a line no directory entry covers is absent from mcopy's copy and PRESENT in the raw scan ($out)"
else bad "salvage: $out (copy has it: $(grep -rl THE-ORPHANED-TAIL "$T/pullS/files" | wc -l))"; fi

# ---- archive on recreate (knob: archive) ----------------------------------------------------------------------
run "$LIB" "logvol_create '$IMG' cell-A1 64" >/dev/null
n=$(find "$T/img/archive" -name 'gui-agent-20261013.log' 2>/dev/null | wc -l)
[ "$n" -ge 1 ] && ok "archive: recreating over a used volume archived its logs first ($n copy)" || bad "archive: nothing archived"
rm -rf "$T/img/archive"
mcopy -s -i "$IMG" "$T/guest/qwt-logs/cell-A1" ::/qwt-logs/ 2>/dev/null
K=$(knob archive) || exit 2; run "$K" "logvol_create '$IMG' cell-A1 64" >/dev/null
n=$(find "$T/img/archive" -name 'gui-agent-20261013.log' 2>/dev/null | wc -l)
[ "$n" -eq 0 ] && ok "archive: knob 'archive' discards the previous contents - the check is seen to fail" || bad "archive: knob did not disable the archive ($n)"

# ---- compose / strip (pure functions) -------------------------------------------------------------------------
STICK='-drive file=/dev/xvdi,format=host_device,if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99'
c=$(run "$LIB" "logvol_qemu_args_compose '$STICK'")
if [ "${c#"$STICK"}" != "$c" ] && printf '%s' "$c" | grep -q 'drive=logdrv' && printf '%s' "$c" | grep -q 'bus=ansusb.0,drive=logdrv,removable=on' \
   && [ "$(printf '%s' "$c" | grep -o 'nec-usb-xhci' | wc -l)" = 1 ]; then
  ok "compose: our drive + device ride the EXISTING ansusb controller; the stick's args are intact"
else bad "compose: $c"; fi
printf '%s' "$c" | grep -q 'id=logdrv,cache=writethrough' && ok "compose: the drive carries cache=writethrough (durability layer L2)" || bad "compose: no cache=writethrough in '$c'"
K=$(knob writethrough) || exit 2; ck=$(run "$K" "logvol_qemu_args_compose '$STICK'")
printf '%s' "$ck" | grep -q 'cache=writethrough' && bad "knob 'writethrough' did not remove the cache option" || ok "compose: knob 'writethrough' drops cache=writethrough - the check is seen to fail"
K=$(knob compose) || exit 2; ck=$(run "$K" "logvol_qemu_args_compose '$STICK'")
[ "${ck#"$STICK"}" = "$ck" ] && ok "compose: knob 'compose' OVERWRITES the stick's args - the check is seen to fail" || bad "knob 'compose' did not break composition"
c0=$(run "$LIB" "logvol_qemu_args_compose ''")
printf '%s' "$c0" | grep -q -- '-device nec-usb-xhci,id=logusb -drive file=/dev/xvdk,format=host_device,if=none,id=logdrv,cache=writethrough -device usb-storage,bus=logusb.0,drive=logdrv,removable=on' \
  && ok "compose: with no existing args our OWN controller is added (logusb)" || bad "compose empty: '$c0'"
c2=$(run "$LIB" "logvol_qemu_args_compose '$c'")
[ "$c2" = "$c" ] && ok "compose: idempotent - composing twice adds nothing" || bad "compose: not idempotent: '$c2'"
K=$(knob idempotent) || exit 2; c2k=$(run "$K" "logvol_qemu_args_compose '$c'")
[ "$c2k" != "$c" ] && ok "compose: knob 'idempotent' doubles the device - the check is seen to fail" || bad "knob 'idempotent' did not break idempotence"
s=$(run "$LIB" "logvol_qemu_args_strip '$c'")
[ "$s" = "$STICK" ] && ok "strip: removes exactly our fragments, the stick's args come back byte-identical" || bad "strip: '$s'"
s0=$(run "$LIB" "logvol_qemu_args_strip '$c0'")
[ -z "$s0" ] && ok "strip: our own controller goes when nothing else uses it (empty value -> unset)" || bad "strip own: '$s0'"

# ---- attach: the order, the options, the manifest, the seal refusal ---------------------------------------
: > "$CALLS"; rm -f "$FEATSTORE"; printf '%s' "$STICK" > "$FEATSTORE"
MF="$T/manifest.json"
out=$(run "$LIB" "logvol_attach win11-cell '$IMG' '$MF'"); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'LOGVOL-ATTACHED vm=win11-cell id=cell-A1 .*loop=loop77 frontend=xvdk cache=writethrough'; then ok "attach: $out"; else bad "attach: rc=$rc $out $(cat "$T/last.err")"; fi
grep -q 'udisksctl loop-setup -f ' "$CALLS" && ok "attach: a WRITABLE loop (udisksctl loop-setup -f, no -r)" || bad "attach: loop-setup call wrong: $(grep udisksctl "$CALLS")"
grep -q 'qvm-device block assign --required -o frontend-dev=xvdk -o devtype=disk -o read-only=false win11-cell win-idd-mgmt:loop77' "$CALLS" \
  && ok "attach: assign --required at xvdk, devtype=disk, read-only=false, holder win-idd-mgmt:loop77" || bad "attach: assign call wrong: $(grep qvm-device "$CALLS")"
# THE SLOT MUST NOT BE THE DIAG STICK'S. This volume sat on xvdj until 2026-10-14, which is
# prime-run's DIAG slot - the collision is why the clean-install path could not simply attach it,
# and why that path ran with no log volume at all while its grading blamed the guest.
# Read the DEFAULT out of the library rather than the environment: this test drives the lib in
# shimmed subshells, so the variable is not bound in this shell (`set -u` aborted the check here).
LVFE=$(sed -n 's/^LOGVOL_FRONTEND="${LOGVOL_FRONTEND:-\([a-z0-9]*\)}".*/\1/p' mgmt/harness/logvol-lib.sh | head -1)
{ [ -n "$LVFE" ] && [ "$LVFE" != xvdj ]; } \
  && ok "attach: the slot ($LVFE) is not prime-run's DIAG stick (xvdj)" || bad "attach: LOGVOL_FRONTEND default is '$LVFE' - xvdj is prime-run's DIAG stick"
grep -q 'frontend-dev=xvdj' mgmt/harness/prime-run.sh \
  && ok "attach: prime-run still owns xvdj for DIAG" || bad "attach: prime-run no longer assigns xvdj - re-check which slot is free"
if [ "$(grep -n -E 'loop-setup|block assign|qvm-features win11-cell qemu-extra-args --' "$CALLS" | cut -d: -f1 | tr '\n' ' ')" = "$(grep -n -E 'loop-setup|block assign|qvm-features win11-cell qemu-extra-args --' "$CALLS" | cut -d: -f1 | sort -n | tr '\n' ' ')" ] \
   && grep -q 'loop-setup' "$CALLS" && grep -q 'block assign' "$CALLS" && grep -q 'qemu-extra-args --' "$CALLS"; then
  ok "attach: order is loop -> assign -> qemu args"
else bad "attach: order: $(grep -n -E 'loop-setup|block assign|qemu-extra-args --' "$CALLS" | tr '\n' ';')"; fi
grep -q 'ansdrv' "$FEATSTORE" && grep -q 'drive=logdrv' "$FEATSTORE" && ok "attach: qemu-extra-args now carries BOTH the stick and the log volume" || bad "attach: feature value: $(cat "$FEATSTORE")"
img_mf=$(run "$LIB" "logvol_manifest_lookup '$MF' win11-cell image"); loop_mf=$(run "$LIB" "logvol_manifest_lookup '$MF' win11-cell loop")
[ "$img_mf" = "$IMG" ] && [ "$loop_mf" = loop77 ] && ok "attach: the manifest records image + loop for the vm" || bad "attach: manifest: image='$img_mf' loop='$loop_mf'"
: > "$CALLS"; ASSIGN_ALREADY=1 run "$LIB" "logvol_attach win11-cell '$IMG' '$MF'" >/dev/null; rc=$?
[ $rc -eq 0 ] && ok "attach: 'already assigned' is success (re-attach of the same volume)" || bad "attach: already-assigned refused (rc=$rc)"
# the seal
mkdir -p "$T/fx/mgmt/goldens" "$T/fx/mgmt/harness"; cp "$LIB" "$T/fx/mgmt/harness/logvol-lib.sh"; printf '{"sealed":1}\n' > "$T/fx/mgmt/goldens/win11-base.json"
: > "$CALLS"
run "$T/fx/mgmt/harness/logvol-lib.sh" "logvol_attach win11-base '$IMG' '$MF'" >/dev/null; rc=$?
[ $rc -eq 2 ] && ! grep -q 'block assign' "$CALLS" && ok "attach: a SEALED golden is REFUSED (rc=2) before any assign" || bad "attach: sealed golden rc=$rc calls=$(cat "$CALLS" | tr '\n' ';')"
sed -E "s|^( *)[^#]*# GUARD:seal DEFECT: (.*)$|\1\2|" "$LIB" > "$T/fx/mgmt/harness/logvol-lib-k.sh"
run "$T/fx/mgmt/harness/logvol-lib-k.sh" "logvol_attach win11-base '$IMG' '$MF'" >/dev/null; rc=$?
[ $rc -eq 0 ] && ok "attach: knob 'seal' attaches to the golden - the check is seen to fail" || bad "knob 'seal' did not disable the refusal (rc=$rc)"
run "$LIB" "logvol_attach win11-cell '$T/img/nonexistent.img' '$MF'" >/dev/null; rc=$?
[ $rc -eq 2 ] && ok "attach: a missing image is REFUSED (rc=2)" || bad "attach: missing image rc=$rc"

# ---- detach ----------------------------------------------------------------------------------------------------
: > "$CALLS"
out=$(QSTATE=Running run "$LIB" "logvol_detach win11-cell '$MF'")
grep -q 'block unassign win11-cell win-idd-mgmt:loop77' "$CALLS" && ! grep -q 'loop-delete' "$CALLS" && [ "$(cat "$FEATSTORE")" = "$STICK" ] \
  && ok "detach (guest Running): unassigned, args stripped back to the stick's, loop LEFT IN PLACE" || bad "detach running: $out calls=$(cat "$CALLS" | tr '\n' ';') feat=$(cat "$FEATSTORE")"
printf '%s' "$c" > "$FEATSTORE"; : > "$CALLS"
out=$(QSTATE=Halted run "$LIB" "logvol_detach win11-cell '$MF'")
grep -q 'loop-delete -b /dev/loop77' "$CALLS" && ok "detach (guest Halted): the loop is released" || bad "detach halted: $out calls=$(cat "$CALLS" | tr '\n' ';')"

# ---- the guest binder: parses, and sets the two root values -------------------------------------------------------
PS1F="$ROOT/mgmt/harness/logvol-bind.ps1"
PWSH=""; for cnd in "$HOME/pwsh/pwsh" "$(command -v pwsh 2>/dev/null)"; do [ -n "$cnd" ] && [ -x "$cnd" ] && { PWSH="$cnd"; break; }; done
if [ -n "$PWSH" ]; then
  if "$PWSH" -NoProfile -Command "\$t=\$null; \$e=\$null; [System.Management.Automation.Language.Parser]::ParseFile('$PS1F', [ref]\$t, [ref]\$e) | Out-Null; if (\$e.Count) { \$e | ForEach-Object { Write-Output \$_.Message }; exit 1 }; exit 0" >"$T/parse.out" 2>&1; then
    ok "bind: logvol-bind.ps1 parses with the real PowerShell parser"
  else bad "bind: parse errors: $(head -3 "$T/parse.out" | tr '\n' ' ')"; fi
else echo "NOTE  pwsh not found - the binder was NOT parse-checked (install: memory pwsh-runs-on-this-qube)"; fi
grep -q "Name 'LogSafeFlush' -Value 1 -Type DWord" "$PS1F" && grep -q "Name 'LogDir' -Value \$new" "$PS1F" \
  && ok "bind: sets LogSafeFlush=1 (FILE_FLAG_WRITE_THROUGH at every module's next LogInit) and LogDir at the root key" || bad "bind: the two root writes are not both present"
grep -q 'LogDirPreLogvol' "$PS1F" && grep -q 'LogSafeFlushPreLogvol' "$PS1F" && ok "bind: both original values are saved for -Restore" || bad "bind: originals not saved"
grep -q 'robocopy.exe' "$PS1F" && ok "bind: the old directory is COPIED onto the volume at bind time (install-boot logs travel)" || bad "bind: no copy of the old directory"
grep -q 'LOGVOL.TAG' "$PS1F" && grep -q "VolumeName -eq \$Label" "$PS1F" && ok "bind: the volume is found by label AND tag file, never by letter" || bad "bind: letter-based lookup"
out=$(run "$LIB" "logvol_bind_guest win11-cell cell-A1"); rc=$?
[ $rc -eq 0 ] && printf '%s' "$out" | grep -q '^LOGVOL-BIND ok' && grep -q 'pushrun .*logvol-bind.ps1 -Id cell-A1 -Mode registry' "$CALLS" && ok "bind: the library pushes the binder with the id and the mode and returns its receipt line" || bad "bind: rc=$rc out=$out"
out=$(BIND_ANSWER='LOGVOL-BIND fail reason=no_volume_labelled_LOGVOL_with_LOGVOL.TAG' run "$LIB" "logvol_bind_guest win11-cell cell-A1"); rc=$?
[ $rc -eq 1 ] && ok "bind: a 'fail' receipt is rc=1 ($out)" || bad "bind fail: rc=$rc"
out=$(BIND_ANSWER='nothing useful' run "$LIB" "logvol_bind_guest win11-cell cell-A1"); rc=$?
[ $rc -eq 1 ] && ok "bind: NO receipt line is rc=1 (missing data fails)" || bad "bind no-receipt: rc=$rc"
out=$(LOGVOL_BIND_MODE=sideways run "$LIB" "logvol_bind_guest win11-cell cell-A1"); rc=$?
[ $rc -eq 2 ] && ok "bind: an unknown mode is REFUSED (rc=2)" || bad "bind mode: rc=$rc"

# ---- the WinPE copier --------------------------------------------------------------------------------------------
CMDF="$ROOT/mgmt/harness/logvol-winpe-copy.cmd"
if ! grep -v '^REM' "$CMDF" | grep -qiE '^\s*start\b'; then ok "winpe: no detached 'start' - every copy is synchronous inside the command"; else bad "winpe: a detached start is present"; fi
grep -qE '^exit /b 0$' "$CMDF" && ! grep -v '^REM' "$CMDF" | grep -qE 'exit /b [1-9]' && ok "winpe: never exits non-zero (a lost log, never a lost install)" || bad "winpe: a non-zero exit is possible"
grep -q 'LOGVOL.TAG' "$CMDF" && ! grep -v '^REM' "$CMDF" | grep -qiE 'findstr|wmic|powershell|goto|^:' && ok "winpe: finds the volume by tag file; no findstr/wmic/PowerShell/goto" || bad "winpe: forbidden construct or no tag lookup"

echo
# A BIND WITH NO MATCHING UNBIND IS THE DEFECT. logvol_bind_guest points LogDir at the volume, so
# any detach must restore it first or the guest logs to a drive letter that is gone - measured
# 2026-10-14 on WIN10-clean as `agent_log_healthy: no agent log is held open by any process`.
det=$(sed -n '/^logvol_detach()/,/^}$/p' mgmt/harness/logvol-lib.sh | sed 's@#.*@@')
ub=$(printf '%s\n' "$det" | command grep -n 'logvol_unbind_guest' | head -1 | cut -d: -f1)
ua=$(printf '%s\n' "$det" | command grep -n 'logvol_unassign' | head -1 | cut -d: -f1)
{ [ -n "$ub" ] && [ -n "$ua" ] && [ "$ub" -lt "$ua" ]; } \
  && ok "detach: LogDir is restored (line $ub) BEFORE the volume is unassigned (line $ua)" \
  || bad "detach: unbind at '$ub', unassign at '$ua' - the guest would be left logging to a volume that is gone"

echo "RESULT: $pass passed, $fail failed  (fixtures: $T)"
[ "$fail" -eq 0 ]
