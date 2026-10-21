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
#   attach      loop + --required assign at xvdj read-only=false + qemu args + manifest, in that order;
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
printf '%s' "$c0" | grep -q -- '-device nec-usb-xhci,id=logusb -drive file=/dev/xvdj,format=host_device,if=none,id=logdrv,cache=writethrough -device usb-storage,bus=logusb.0,drive=logdrv,removable=on' \
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
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'LOGVOL-ATTACHED vm=win11-cell id=cell-A1 .*loop=loop77 frontend=xvdj cache=writethrough'; then ok "attach: $out"; else bad "attach: rc=$rc $out $(cat "$T/last.err")"; fi
grep -q 'udisksctl loop-setup -f ' "$CALLS" && ok "attach: a WRITABLE loop (udisksctl loop-setup -f, no -r)" || bad "attach: loop-setup call wrong: $(grep udisksctl "$CALLS")"
grep -q 'qvm-device block assign --required -o frontend-dev=xvdj -o devtype=disk -o read-only=false win11-cell win-idd-mgmt:loop77' "$CALLS" \
  && ok "attach: assign --required at xvdj, devtype=disk, read-only=false, holder win-idd-mgmt:loop77" || bad "attach: assign call wrong: $(grep qvm-device "$CALLS")"
# ONE STICK, ON ONE SLOT. This volume and prime-run's DIAG stick were two volumes with identical
# plumbing; the only difference was that this one redirected LogDir, and that redirect cost four
# acceptance runs. They are now the same stick: one image per subject, label DIAG, slot xvdj,
# carrying the install's markers and the guest's logs together.
# Read the DEFAULT out of the library rather than the environment: this test drives the lib in
# shimmed subshells, so the variable is not bound in this shell (`set -u` aborted the check here).
LVFE=$(sed -n 's/^LOGVOL_FRONTEND="${LOGVOL_FRONTEND:-\([a-z0-9]*\)}".*/\1/p' mgmt/harness/logvol-lib.sh | head -1)
[ "$LVFE" = xvdj ] \
  && ok "attach: one stick, on xvdj - the slot the DIAG stick has always used" \
  || bad "attach: LOGVOL_FRONTEND default is '$LVFE' - the collapsed design is one stick on xvdj"
LVLB=$(sed -n 's/^LOGVOL_LABEL="${LOGVOL_LABEL:-\([A-Z0-9]*\)}".*/\1/p' mgmt/harness/logvol-lib.sh | head -1)
[ "$LVLB" = DIAG ] \
  && ok "attach: labelled DIAG - the label the install's own cmd resolves at write time" \
  || bad "attach: label is '$LVLB', so the install's `vol | findstr DIAG` will not find it"
# And prime-run must no longer attach a SECOND stick of its own.
[ "$(command grep -c 'answer-usb-413' mgmt/harness/prime-run.sh)" -eq 0 ] \
  && ok "attach: prime-run no longer attaches a separate DIAG image - one stick only" \
  || bad "attach: prime-run still attaches answer-usb-413.img as well, which collides on xvdj"
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
# ---- keep_only_ours: dropping the PRIMING sticks must not drop THIS volume -----------------------
# A harness that finishes priming has to clear the answer stick and the DIAG stick while keeping the
# log volume, which rides the SAME nec-usb-xhci controller. matrix.sh used to do it with a blanket
# `qvm-features --unset <vm> qemu-extra-args`, which deleted our drive, our usb-storage device AND
# that shared controller. Because qemu-extra-args applies at DOMAIN CREATION, the running guest kept
# its volume and the loss appeared one boot later - at the cell's park/restore - with LogDir still
# naming a drive letter that no longer existed. Measured TWICE (2026-10-14 and the relaunch):
# `agent_log_healthy` false, "no agent log is held open by any process", and the IDD check that
# reads a line out of that log failing with it. The input below is prime-run.sh's REAL value.
PRIMEARGS='-drive file=/dev/xvdi,format=host_device,if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99 -drive file=/dev/xvdj,format=host_device,if=none,id=diagdrv -device usb-storage,bus=ansusb.0,drive=diagdrv,removable=on'
both=$(run "$LIB" "logvol_qemu_args_compose '$PRIMEARGS'")
kept=$(run "$LIB" "logvol_qemu_args_keep_only_ours '$both'")
printf '%s' "$kept" | command grep -q 'id=logdrv' \
  && ok "keep_only_ours: OUR drive survives" || bad "keep_only_ours: our drive was dropped ($kept)"
printf '%s' "$kept" | command grep -q 'drive=logdrv,removable=on' \
  && ok "keep_only_ours: our usb-storage device survives" || bad "keep_only_ours: our device was dropped"
printf '%s' "$kept" | command grep -q 'nec-usb-xhci,id=ansusb' \
  && ok "keep_only_ours: the SHARED controller survives (ours rides it)" || bad "keep_only_ours: the controller was dropped - our device has no bus"
printf '%s' "$kept" | command grep -qE 'id=ansdrv|id=diagdrv|drive=ansdrv|drive=diagdrv' \
  && bad "keep_only_ours: a priming stick survived ($kept)" || ok "keep_only_ours: both priming sticks are gone"
# With no volume of ours in the value there is nothing to keep the controller for: clear it, so the
# caller unsets the feature instead of leaving a bus with nothing on it.
[ -z "$(run "$LIB" "logvol_qemu_args_keep_only_ours '$PRIMEARGS'")" ] \
  && ok "keep_only_ours: with no volume of ours it clears entirely" || bad "keep_only_ours: kept something with no volume of ours"
# And the harness must use it rather than the blanket unset.
command grep -q 'logvol_qemu_args_keep_only_ours' "$ROOT/mgmt/harness/matrix.sh" \
  && ok "keep_only_ours: matrix.sh uses it instead of unsetting the whole feature" \
  || bad "keep_only_ours: matrix.sh does not call it - the blanket unset is back"

# ---- THE LETTER IS RESOLVED BY LABEL AND THEN PINNED -------------------------------------------
# The volume was always found by LABEL, which is correct. The defect was writing whatever letter it
# happened to have into LogDir, where every module reads it once at init: the letter depends on which
# OTHER removable volumes are attached, so it moved from F: to D: when the priming sticks were
# dropped and four acceptance runs failed on a healthy guest. "Fix it by timing" was wrong - the
# owner: "what the fuck is 'fix by timing'. find out what the letter is and redirect there, no
# fucking guesses" - and binding later cannot work anyway, because unassigning a claim and rewriting
# qemu-extra-args only take effect at the next domain creation.
B=mgmt/harness/logvol-bind.ps1
bcode(){ sed -E 's/(^|[^`])#.*/\1/' "$B"; }
[ "$(bcode | command grep -c 'VolumeName -eq \$Label')" -ge 1 ] \
  && ok "bind: the volume is found BY LABEL" || bad "bind: the volume is not found by label"
[ "$(bcode | command grep -c 'LOGVOL.TAG')" -ge 1 ] \
  && ok "bind: and confirmed by our own tag file, not just the label" || bad "bind: no tag-file confirmation"
# MOUNTVOL CANNOT DO THIS, and asserting it was this check's own defect. `mountvol <L:> <guid>`
# ADDS a mount point and leaves the existing letter alone: measured 2026-10-15, the receipt came
# back "drive=E: found=E: letter=same" while the volume sat on E: - a pin that pinned nothing, and
# a check that passed on it. CHANGING a letter is Set-Partition's job (diskpart as the fallback for
# a guest with no Storage module), and Windows persists that assignment under MountedDevices keyed
# by the volume's own GUID, so it survives both a reboot and a change in the device set.
[ "$(bcode | command grep -c 'Set-Partition -NewDriveLetter')" -ge 1 ] \
  && ok "bind: the letter is CHANGED with Set-Partition, the only call that rewrites it" \
  || bad "bind: nothing changes the letter - mountvol only adds a mount point (measured letter=same)"
[ "$(bcode | command grep -c 'assign letter=')" -ge 1 ] \
  && ok "bind: diskpart fallback for a guest with no Storage module" \
  || bad "bind: no fallback - a guest without Get-Partition silently keeps its moving letter"
[ "$(bcode | command grep -c 'Pin-LogVol')" -ge 2 ] \
  && ok "bind: the pin is applied to what the label resolved, before LogDir is written" \
  || bad "bind: the pin is defined but not applied"
# AND THE PIN IS VERIFIED, by resolving the label AGAIN afterwards rather than trusting the call.
# That is what caught mountvol: the receipt's own found= came back equal to the old letter.
[ "$(bcode | sed -n '/function Pin-LogVol/,/^}/p' | command grep -c 'Find-LogVol')" -ge 1 ] \
  && ok "bind: the pin re-resolves BY LABEL to confirm the letter actually moved" \
  || bad "bind: the pin trusts Set-Partition instead of re-reading the letter"
# SEEN TO FAIL: strip the pin out and the three checks above must all go red. Without this, a future
# rewrite that drops the pin entirely leaves six greps passing on a file that no longer pins.
BDEF=$(mktemp "${TMPDIR:-/tmp}/logvol-bind-nopin.XXXXXX.ps1")
sed -e 's/Set-Partition -NewDriveLetter/Write-Output #/' -e 's/assign letter=/rem /' \
    -e '/function Pin-LogVol/,/^}/{/Find-LogVol/d;}' "$B" > "$BDEF"
nopin=0
for rx in 'Set-Partition -NewDriveLetter' 'assign letter='; do
  sed -E 's/(^|[^`])#.*/\1/' "$BDEF" | command grep -q "$rx" || nopin=$((nopin+1))
done
sed -E 's/(^|[^`])#.*/\1/' "$BDEF" | sed -n '/function Pin-LogVol/,/^}/p' \
  | command grep -q 'Find-LogVol' || nopin=$((nopin+1))
rm -f "$BDEF"
[ "$nopin" -eq 3 ] \
  && ok "bind: all three pin checks go red on a script with the pin removed (seen to fail)" \
  || bad "bind: the pin checks still pass with the pin stripped out ($nopin/3 caught) - they are vacuous"
# It must never take a letter another volume holds.
[ "$(bcode | command grep -c "DriveLetter='\" + \$want")" -ge 1 ] \
  && ok "bind: refuses to steal a letter already in use" || bad "bind: could unmount an unrelated volume"
# And the receipt has to say which letter was found and whether it moved, so a reader can tell.
[ "$(bcode | command grep -c 'found=')" -ge 1 ] && ok "bind: the receipt records the letter found" || bad "bind: the receipt hides which letter was used"

# ---- THE BIND MUST HAPPEN AFTER THE DEVICE SET IS FINAL ----------------------------------------
# LogDir is written with the volume's DRIVE LETTER as it is at bind time, and that letter depends on
# which other removable volumes are attached. prime-run used to bind while BOTH priming sticks were
# present; the cell then unassigns them, the volume moves up the alphabet on the next boot, and
# LogDir points at a letter nothing answers to. Three campaign runs died there, each one blamed on
# the guest. MEASURED by mgmt/harness/logvol-chain-check.sh (win10-acc, 2026-10-15): with the device
# set stable AND the letter pinned the chain holds across a reboot - mounted at Z:, LogDir on it,
# 5 logs held open, 279 QWT lines host-side, SAME letter after the reboot (Z:), 279 -> 549 lines.
# 15 links, 0 broken. The earlier run of this check sat at D: with nothing pinning it, which is the
# state four campaign runs died in.
# COMMENTS STRIPPED FIRST: prime-run's comment NAMES logvol_bind_guest to explain why it is not
# called there, so grepping the raw file finds the explanation and calls it a call. Nth time today.
[ "$(sed 's@#.*@@' "$ROOT/mgmt/harness/prime-run.sh" | command grep -c 'logvol_bind_guest')" -eq 0 ] \
  && ok "bind timing: prime-run does NOT bind (its device set still has both priming sticks)" \
  || bad "bind timing: prime-run still binds before the sticks are removed"
# and the cell binds AFTER the sweep, by line order
cell=$(awk '/^cell_clean\(\)|clear_prime_leftovers "\$vm"/,/logvol_bind_now/' "$ROOT/mgmt/harness/matrix.sh" | sed 's@#.*@@')
sw=$(printf '%s\n' "$cell" | command grep -n 'clear_prime_leftovers' | head -1 | cut -d: -f1)
bd=$(printf '%s\n' "$cell" | command grep -n 'logvol_bind_now' | head -1 | cut -d: -f1)
{ [ -n "$sw" ] && [ -n "$bd" ] && [ "$sw" -lt "$bd" ]; } \
  && ok "bind timing: the cell sweeps the sticks (line $sw) BEFORE binding (line $bd)" \
  || bad "bind timing: sweep at '$sw', bind at '$bd' - the letter can still move after the bind"
# the chain check itself must exist and cover the reboot, or none of this is verifiable
[ -x "$ROOT/mgmt/harness/logvol-chain-check.sh" ] \
  && ok "bind timing: the whole-chain check exists and is executable" || bad "bind timing: no chain check"
command grep -q 'G4b same drive letter across the reboot' "$ROOT/mgmt/harness/logvol-chain-check.sh" \
  && ok "bind timing: the chain check asserts the LETTER survives a reboot" \
  || bad "bind timing: the chain check does not check the letter across a reboot"

# ---- THE STICK IS ALWAYS THERE; THE REDIRECT IS OFF BY DEFAULT --------------------------------
# The stick carries the install's markers, which a stalled install needs whether or not logs are
# redirected, so it is attached unconditionally - as the DIAG stick always was.
#
# THE REDIRECT IS OFF, AND THIS CHECK USED TO ASSERT THE OPPOSITE. It read "the redirect is on by
# default now that the letter is resolved by label and PINNED, so it cannot name a letter that
# moved" - true about the letter, and not the claim that matters. LogDir is read once per module at
# LogInit, and a USB volume behind an emulated xHCI controller need not be MOUNTED by then; a module
# that starts first opens no log and never retries. Measured on run 8 with the pin working: the bind
# receipt read `drive=Z: found=E: letter=pinned copied=21`, the volume mounted at Z:, and nothing
# was written to it after the cell's park/restore - `any_agent_log_held_open: false` with the agent
# alive. The control is unambiguous: WIN10-clean's accept battery PASSED in the campaigns before
# this instrument was wired into that cell (rel-38522636380, rel-38571770442) and failed in every
# campaign after.
# THE POSTURE REVERSED ON 2026-10-19, and the paragraph above is why it used to be OFF - history.
# Run 8's failure was not perturbation. Its own lines: `[01:59:49] QWT logs bound to the log volume`
# then `[02:02:35] INVALID-INSTRUMENT: no gui-agent log found in Z:\qwt-logs\win10-acc`, with
# health.json `agent_pids=[3972] any_agent_log_held_open=false instance_log=NONE` - the agent ALIVE
# and LogDir naming a directory nothing wrote to. That is the LogDir-overwrite defect: the installer
# forced the root value back five seconds after the bind (established 0.96, measured on win11de-tup:
# 28 wrapper logs on the stick 05:00:58-05:01:48, the seed at 05:02:00, Q: again from 05:02:05).
# With that fixed, the pin refusing rather than recording a low letter, and the bind re-asserted
# after the install, nothing is left that evidences perturbation (Jev perturbation_evidence_left
# 0.13; substitutes_test_conditions 0.27 - only WHERE logs are written changes).
# AND THE CAMPAIGN DEPENDS ON IT: win11-reinstall went silent after its install reboot in the 4.3.37
# run and produced 2 files / 0 QWT lines, because the bind was off. Jev: enable 0.80, keep_off 0.01.
# The guard is KEPT, pointing the other way, so a silent flip back is caught either direction.
[ "$(command grep -c 'LOGVOL_BIND:-1' "$ROOT/mgmt/harness/matrix.sh")" -ge 1 ] \
  && ok "posture: the redirect is ON by default (LOGVOL_BIND=0 opts out onto the stock log path)" \
  || bad "posture: the redirect is not on by default - a wedged guest leaves nothing host-readable"
[ "$(command grep -c 'LOGVOL_BIND:-0' "$ROOT/mgmt/harness/matrix.sh")" -eq 0 ] \
  && ok "posture: no off-by-default gate left in the matrix" || bad "posture: an off-by-default gate remains"
# The stick must still be attached with the redirect off, or a wedge loses the installer's markers.
[ "$(sed -E 's/(^|[^`])#.*/\1/' "$ROOT/mgmt/harness/matrix.sh" | command grep -c 'logvol_attach')" -ge 1 ] \
  && ok "posture: the stick is still attached regardless of the redirect" \
  || bad "posture: nothing attaches the stick - a wedge loses the installer's diag markers"
[ "$(sed -E 's/(^|[^`])#.*/\1/' "$ROOT/mgmt/harness/prime-run.sh" | command grep -c 'LOGVOL_BIND')" -eq 0 ] \
  && ok "posture: prime-run attaches the stick unconditionally and never binds" \
  || bad "posture: prime-run still gates or binds the stick"


# ---- ONE DRIVE PER FRONTEND, or qemu refuses the domain outright -------------------------------
# logvol_attach COMPOSES its -drive and usb-storage onto whatever qemu-extra-args already holds.
# prime-run used to declare its own DIAG drive at xvdj there; with the sticks collapsed into one,
# that left TWO drives on the same frontend and the domain would not create at all - "libxenlight
# failed to create new domain", measured 2026-10-15 on the first run of the collapsed design. The
# guest never ran, so nothing about the payload or the product was inferable from that cell.
PRIMEONLY='-drive file=/dev/xvdi,format=host_device,if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99'
composed=$(run "$LIB" "logvol_qemu_args_compose '$PRIMEONLY'")
for dev in xvdi xvdj; do
  nd=$(printf '%s' "$composed" | tr ' ' '\n' | command grep -c "file=/dev/$dev")
  [ "$nd" -eq 1 ] && ok "frontend: exactly one -drive for /dev/$dev" \
                  || bad "frontend: $nd drives for /dev/$dev - qemu refuses the domain"
done
[ "$(printf '%s' "$composed" | tr ' ' '\n' | command grep -c 'nec-usb-xhci')" -eq 1 ] \
  && ok "frontend: one controller, reused rather than duplicated" || bad "frontend: duplicate controllers"
# AND THE REAL FILE: prime-run must not declare a drive for the stick any more - the library owns it.
# This is the check that was missing when the defect shipped, so it is asserted against the shipped
# script and not only against a composed string.
pr_x=$(sed -E 's/(^|[^`])#.*/\1/' "$ROOT/mgmt/harness/prime-run.sh" | tr ' ' '\n' | command grep -c 'file=/dev/xvdj')
[ "$pr_x" -eq 0 ] \
  && ok "frontend: prime-run declares no xvdj drive of its own" \
  || bad "frontend: prime-run declares $pr_x xvdj drive(s) - they collide with the library's"

# EVERY CELL THAT GRADES AFTER A BOOT MUST RE-ASSERT THE BIND. The pinned letter is not exclusive:
# the pin decides where OUR volume goes, it does not reserve the letter, and another removable
# volume present at boot can own it first. Reproduced on win10-acc by A/B/A 2026-10-20 - one extra
# 64 MB stick in qemu-extra-args and Z: became DUMMYSTK while the DIAG volume moved to D:, LogDir
# still naming Z:\qwt-logs\<vm>, that directory gone, every module writing to Q:\Qubes Logs.
# That is how four cells of run 39225775322 swept 0 QWT lines with their logs on the image.
# The clean cell binds BEFORE its park, so its grading boot is exactly where the letter can move.
_mx="$ROOT/mgmt/harness/matrix.sh"
if command grep -qE 'logvol_bind_now "\$vm" "\$tag-clean-postboot"' "$_mx"; then
  ok "letter: the clean cell re-asserts the bind on the boot grading reads"
else
  bad "letter: the clean cell binds before its park and never again - a volume that moved letter leaves LogDir naming another volume"
fi
# the appvm cell is the other one that grades a guest it did not just install
if command grep -qE 'logvol_bind_now "\$app"' "$_mx"; then
  ok "letter: the appvm cell binds the volume it attached"
else
  bad "letter: the appvm cell never binds, so LogDir keeps naming the TEMPLATE's directory"
fi

# AN UNLETTERED VOLUME IS STILL A VOLUME. Win32_LogicalDisk lists only volumes that HAVE a drive
# letter, so the binder's Find-LogVol returned $null for a DIAG volume Windows had mounted without
# one - and the caller reports that as `no_volume_labelled_DIAG_with_LOGVOL.TAG`, "no volume",
# about a volume attached and host-readable the whole time. Run 39225775322 WIN10-clean,
# 2026-10-20: attached 12:42:05, read from this qube 12:50:05, "no volume" at 12:50:16. A fresh
# clean install is exactly where an unlettered removable volume is ordinary.
_bps="$ROOT/mgmt/harness/logvol-bind.ps1"
if command grep -q 'Get-Volume' "$_bps" && command grep -q 'not \$_.DriveLetter' "$_bps"; then
  ok "letterless: the binder looks for volumes with NO drive letter, not only lettered ones"
else
  bad "letterless: Find-LogVol only enumerates Win32_LogicalDisk - a volume without a letter reads as absent"
fi
if command grep -q 'lettered_an_unlettered_volume' "$_bps"; then
  ok "letterless: and it SAYS when it had to letter one, so the receipt shows what happened"
else
  bad "letterless: it letters a volume silently" "a receipt that hides a repair cannot explain the next failure"
fi

# THE BIND MUST PROVE ITSELF. Every instrument failure of the last two campaigns was the same
# class - the evidence path was ASSUMED and the cells were scored before anyone found out. A bind
# that returns ok is not evidence that evidence will arrive: on run 39225775322 the appvm bind
# returned ok having written LogDir=Z:\qwt-logs\win10-app, and the collector then read
# Z:\qwt-logs\win10-acc exists=0, because an AppVM's volatile root had discarded it.
_mx="$ROOT/mgmt/harness/matrix.sh"
if command grep -q 'logvol_prove_roundtrip' "$_mx"; then
  ok "proof: matrix binds and then PROVES the path end to end"
else
  bad "proof: nothing proves the log path before a cell is graded - the failure is found after scoring, every time"
fi
if sed -n '/logvol_prove_roundtrip/,/^  else/p' "$_mx" | command grep -q 'exit 2'; then
  ok "proof: and an unproven path ABORTS rather than grading on"
else
  bad "proof: an unproven log path does not abort" "the remaining cells would be graded by the same broken instrument"
fi
# TWICE: at the bind, and AGAIN before the pull. Jev named the hole a bind-time-only proof leaves -
# grading happens later, so a path that breaks in between is not caught before the cell is scored
# (gap_is_between_bind_and_grading 0.57). Both ways it breaks have happened: the pinned letter
# taken by another volume (reproduced A/B/A on win10-acc) and an AppVM's volatile root discarding
# the registry (receipts of run 39225775322). A path that broke mid-cell leaves a TRUNCATED log,
# and a truncated log is what the sweep reads as CLEAN.
_nproof=$(command grep -c 'logvol_prove_roundtrip' "$_mx")
if [ "$_nproof" -ge 2 ]; then
  ok "proof: the path is proven at the bind AND again before the pull ($_nproof call sites)"
else
  bad "proof: only $_nproof call site - a bind-time-only proof misses anything that breaks before grading"
fi
if sed -n '/BEFORE THE PULL/,/logvol_pull/p' "$_mx" | command grep -q 'qvm-check --running'; then
  ok "proof: a guest that has GONE is not a proof failure - the pull still runs, which is the wedge case"
else
  bad "proof: a wedged or removed guest would be treated as a proof failure" "that is the one case the volume exists for"
fi

# ===============================================================================================
# THE PROOF MUST MEASURE THE AGENT, NOT THE PROVER - and this leg HOLDS the condition that makes
# the difference instead of describing it.
#
# Owner, 2026-10-21: "PROACTIVELY REFUSING to include a critical condition to test environment
# claiming false equivalence." That is what happened here. Every logvol fix between 2026-10-13 and
# 2026-10-20 - thirteen commits - was verified on win10-acc or win11de-tup, guests whose ROOT
# PERSISTS, so the registry write and the Set-Partition letter pin both survive a reboot. ZERO of
# those measurements name win10-app, win11-app or an appvm cell, where the root is VOLATILE and
# discards both before the agent family starts. The condition that produces the defect was absent
# from every test environment, and the passes were reported as proof.
#
# The four "proof:" assertions above this block are `grep -q logvol_prove_roundtrip matrix.sh`,
# `grep -q 'exit 2'`, a call-site COUNT and `grep -q 'qvm-check --running'`. All four check that a
# function NAME appears in a file. None of them runs the proof. So the suite verified that the proof
# is CALLED, never that it WORKS - while its own comments described the AppVM failure in detail.
#
# This leg EXECUTES the real logvol_prove_roundtrip against the AppVM state: the nonce round-trips
# (the volume is fine and the prover resolves a writable LogDir) and there are ZERO agent-family
# logs in it (the agent resolved a different directory at its own start). The old proof passes on
# that state - that is the control - and the new one must fail.
echo
PT="$(mktemp -d)"; trap 'rm -rf "$PT"' EXIT
mkdir -p "$PT/bin"
# the guest channel: echo back the nonce it was handed, with the agentlogs count this leg is testing
cat > "$PT/bin/qtest-stub" <<'STUB'
#!/bin/bash
nonce=""; prev=""
for a in "$@"; do [ "$prev" = "-Nonce" ] && nonce="$a"; prev="$a"; done
printf '%s' "$nonce" > "$LVPROOF_NONCE_FILE"
# agentfresh defaults to the total, so every leg written before freshness existed keeps its
# meaning; LVPROOF_AGENTFRESH is what the stale-log legs vary. LVPROOF_NOFRESH=1 answers in the
# OLD shape, with no freshness field at all.
if [ "${LVPROOF_NOFRESH:-0}" = 1 ]; then
  printf 'LOGVOL-PROOF-GUEST ok dir=Z:\\qwt-logs\\win10-app agentlogs=%s file=Z:\\qwt-logs\\win10-app\\%s.proof\n' \
         "${LVPROOF_AGENTLOGS:-0}" "$nonce"
else
  printf 'LOGVOL-PROOF-GUEST ok dir=Z:\\qwt-logs\\win10-app agentlogs=%s agentfresh=%s agentopen=%s file=Z:\\qwt-logs\\win10-app\\%s.proof\n' \
         "${LVPROOF_AGENTLOGS:-0}" "${LVPROOF_AGENTFRESH:-${LVPROOF_AGENTLOGS:-0}}" "${LVPROOF_AGENTOPEN:-0}" "$nonce"
fi
STUB
# the host half reads the IMAGE with mdir; this stub reports the nonce as present, so the
# round-trip half always succeeds and the ONLY variable in this leg is the agent-log count
cat > "$PT/bin/mdir" <<'STUB'
#!/bin/bash
[ -r "$LVPROOF_NONCE_FILE" ] && cat "$LVPROOF_NONCE_FILE"
echo " LOGVOL      <DIR>"
STUB
chmod +x "$PT/bin/qtest-stub" "$PT/bin/mdir"
export LVPROOF_NONCE_FILE="$PT/nonce"

run_proof() { # $1=agentlogs $2...=extra args -> "rc|output"
    local n="$1"; shift
    local out rc
    # QTEST_BIN, not LOGVOL_QTEST: logvol-lib.sh:117 is LOGVOL_QTEST="${QTEST_BIN:-...}", and this
    # suite exports QTEST_BIN globally at line 79, so sourcing the library overwrote the override.
    # My first version of this leg set the wrong name and the suite's own guest stub answered -
    # which is why the leg is EXECUTED rather than grepped: it caught my own mistake in one run.
    out=$( LVPROOF_AGENTLOGS="$n" LVPROOF_AGENTFRESH="${LVPROOF_AGENTFRESH:-}" \
           LVPROOF_NOFRESH="${LVPROOF_NOFRESH:-0}" PATH="$PT/bin:$PATH" QTEST_BIN="$PT/bin/qtest-stub" \
           bash -c '
             source mgmt/harness/logvol-lib.sh
             logvol_prove_roundtrip somevm "'"$PT"'/img.img" proofleg '"$*"' 2>&1' ); rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

# 1. THE CONTROL: the AppVM state, judged the OLD way. It PASSES - which is the defect.
r=$(run_proof 0); rc=${r%%|*}; out=${r#*|}
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'LOGVOL-PROOF ok'; then
    ok "proof-agent CONTROL: zero agent logs + a round-tripping nonce PASSES the old way (the defect, reproduced)"
else
    bad "proof-agent CONTROL did not reproduce" "rc=$rc $out"
fi

# 2. THE PROPERTY: the same state, with the requirement, must FAIL and name the agent half.
r=$(run_proof 0 --require-agent-logs); rc=${r%%|*}; out=${r#*|}
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'half=agent'; then
    ok "proof-agent: zero agent logs FAILS with --require-agent-logs, naming the agent half"
else
    bad "proof-agent: the AppVM state still passed" "rc=$rc $out"
fi

# 3. AND IT IS NOT A CONSTANT: the same call with agent logs present must pass, or the check is
#    simply "always fail when the flag is given" and tells us nothing.
r=$(run_proof 4 --require-agent-logs); rc=${r%%|*}; out=${r#*|}
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'agentlogs=4'; then
    ok "proof-agent: four agent logs PASSES with the flag - the predicate responds to the count"
else
    bad "proof-agent: the flag fails even with agent logs present - it is a constant" "rc=$rc $out"
fi

# 3b. THE STALE LOG, which is the same defect one layer down. Found by the component re-grade,
#     2026-10-21: the gate counted files whose NAME matches the agent family, so a gui-agent log
#     left by an EARLIER boot of the same cell satisfied it while the boot being graded wrote
#     nothing. agentlogs=3 with agentfresh=0 is exactly that state.
r=$(LVPROOF_AGENTFRESH=0 run_proof 3 --require-agent-logs); rc=${r%%|*}; out=${r#*|}
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'written_since_this_boot'; then
    ok "proof-agent: three STALE agent logs and nothing written this boot FAILS, naming freshness"
else
    bad "proof-agent: stale logs from an earlier boot still passed" "rc=$rc $out"
fi

# 3c. AND FRESHNESS IS NOT A CONSTANT EITHER: logs present AND written this boot must pass.
r=$(LVPROOF_AGENTFRESH=2 run_proof 3 --require-agent-logs); rc=${r%%|*}; out=${r#*|}
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'agentfresh=2'; then
    ok "proof-agent: logs written THIS boot pass, and the ok line carries the count"
else
    bad "proof-agent: fresh logs were refused - the freshness gate is a constant" "rc=$rc $out"
fi

# 3d. A GUEST THAT DOES NOT REPORT FRESHNESS AT ALL must fail, not default to a pass. The field is
#     parsed with sed, which leaves the line untouched when it does not match, so the unparsed case
#     has to be caught by name rather than coerced to a number.
r=$(LVPROOF_NOFRESH=1 run_proof 3 --require-agent-logs); rc=${r%%|*}; out=${r#*|}
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'agentfresh_not_reported'; then
    ok "proof-agent: an answer with no freshness field FAILS as missing data, not as zero or as ok"
else
    bad "proof-agent: a guest that never reported freshness was graded anyway" "rc=$rc $out"
fi

# 3e. SEEN TO FAIL: the gate as it stood this morning - on agentlogs alone - passes the stale state.
oldgate=$(sed 's/\[ "\${agentfresh:-0}" -eq 0 \]/[ "${agentlogs:-0}" -eq 0 ]/' mgmt/harness/logvol-lib.sh)
if printf '%s' "$oldgate" | grep -q '\[ "${agentlogs:-0}" -eq 0 \]'; then
    r=$(printf '%s' "$oldgate" > "$PT/oldgate.sh"; LVPROOF_AGENTFRESH=0 LVPROOF_AGENTLOGS=3 \
        PATH="$PT/bin:$PATH" QTEST_BIN="$PT/bin/qtest-stub" bash -c '
          source "'"$PT"'/oldgate.sh"
          logvol_prove_roundtrip somevm "'"$PT"'/img.img" proofleg --require-agent-logs 2>&1' >/dev/null 2>&1; echo $?)
    [ "$r" = 0 ] \
      && ok "SEEN TO FAIL: with the gate back on agentlogs the stale state passes again" \
      || bad "the reverted gate still refused the stale state (rc=$r)" "then these legs measure something else"
else
    bad "could not revert the gate for the control" "the substitution did not apply"
fi

# 3f. THE COPY MUST NOT REFRESH TIMESTAMPS, or 3b's whole gate loses its meaning. The bind copies
#     the old log directory onto the volume; robocopy's default /COPY:DAT carries Timestamps, so a
#     log from an earlier boot arrives stale and still fails the freshness gate. A future /COPY:
#     that drops T would silently make every carried-over log look like it was written this boot.
cp_line=$(command grep -aE 'robocopy' "$ROOT/mgmt/harness/logvol-bind.ps1" | command grep -av '^\s*#')
if [ -z "$cp_line" ]; then
    bad "the bind no longer copies with robocopy" "3b's freshness gate rests on the copy preserving mtimes - re-check it"
elif printf '%s' "$cp_line" | grep -qE '/COPY:'; then
    printf '%s' "$cp_line" | grep -qE '/COPY:[^ ]*T' \
      && ok "copy: the bind passes an explicit /COPY: and it still includes T (timestamps preserved)" \
      || bad "copy: the bind passes a /COPY: WITHOUT T" "every carried-over log would read as written this boot"
else
    ok "copy: the bind uses robocopy with no /COPY: override, so the default DAT preserves timestamps"
fi

# 3g. THE FRESHNESS ANCHOR IS A PID, NOT A CLOCK - and this is the leg that would have saved a
#     campaign. The first version compared each file's LastWriteTime against
#     Win32_OperatingSystem.LastBootUpTime. THIS RIG CORRECTS THE GUEST CLOCK BY 10800 s ON EVERY
#     BOOT after the first (timezone=localtime, the guest reads a dom0-local RTC as UTC and the
#     puller corrects it), so files written before the correction read as older than their own boot
#     and agentfresh came back 0 over a volume holding 260 fresh lines. That false 0 aborted the
#     release campaign of 2026-10-21 in cell 1, and the collected evidence settled it: the volume's
#     gui-agent log carried pid 3904 with LifecycleStart at 21:34:19 - a NEW process in the graded
#     boot - while the install boot's agent was 3976.
#     The block is EXTRACTED FROM THE SHIPPED FILE and executed under pwsh, with Get-Process
#     shadowed so the leg is about the predicate and not about this qube's process table.
PWX=${PWSH:-/home/user/.local/pwsh/pwsh}; [ -x "$PWX" ] || PWX=$(command -v pwsh || true)
if [ -z "$PWX" ]; then
    bad "fresh: no pwsh - the freshness predicate was not driven" "missing data fails"
else
    fresh_probe() { # $1=extra ps prelude (for the control) -> "agentlogs=N agentfresh=M agentopen=K"
        local FT; FT=$(mktemp -d); mkdir -p "$FT/logs"
        # one log written by a LIVE pid, one by a pid that is gone - the shape on the volume
        printf '[20261021.213419.426-3904:3908-I] LifecycleStart: QGALIFECYCLE up\n[20261021.213700.000-3904:3908-I] WinMain: still here\n' > "$FT/logs/gui-agent-20261021.log"
        printf '[20261021.212925.363-3976:3980-I] LifecycleStart: QGALIFECYCLE up\n[20261021.213209.836-3976:3980-I] WinMain: QGAEXIT\n' > "$FT/logs/gui-watchdog-20261021.log"
        local blk; blk=$(awk '/# LVFRESH-A/,/# LVFRESH-B/' "$ROOT/mgmt/harness/logvol-lib.sh")
        { printf '%s\n' "\$dir = '$FT/logs'"
          printf '%s\n' '$agent = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -match "(?i)^(gui-agent|gui-watchdog|qrexec-agent|qubesdb)" })'
          printf '%s\n' 'function Get-Process { param([string]$Name) @([pscustomobject]@{ Name="gui-agent"; Id=3904 }) }'
          printf '%s\n' "${1:-}"
          printf '%s\n' "$blk"
          printf '%s\n' 'Write-Output ("agentlogs=" + $agent.Count + " agentfresh=" + $fresh.Count + " agentopen=" + $open)'
        } > "$FT/drive.ps1"
        "$PWX" -NoProfile -File "$FT/drive.ps1" 2>/dev/null | tail -1
        rm -rf "$FT"
    }
    out=$(fresh_probe)
    case "$out" in
      *"agentfresh=1"*) ok "fresh: the log whose tail carries a RUNNING pid counts; the dead pid's does not ($out)" ;;
      *) bad "fresh: the pid anchor did not identify the live writer" "$out" ;;
    esac

    # SEEN TO FAIL, PROPERLY: run the OLD clock predicate over the SAME fixture. Its files were
    # just written, so their mtimes are now; the boot stamp is now+3h, which is what this rig's
    # 10800 s correction produces. The pid predicate says 1 on this fixture, the clock one says 0 -
    # the same files, the same instant, two anchors.
    # An earlier version of this leg asserted only that (Get-Date) < (Get-Date).AddHours(3), which
    # is arithmetic and would have passed with the predicate deleted.
    FT2=$(mktemp -d); mkdir -p "$FT2/logs"
    printf '[20261021.213419.426-3904:3908-I] LifecycleStart: QGALIFECYCLE up\n' > "$FT2/logs/gui-agent-20261021.log"
    clockout=$("$PWX" -NoProfile -Command "
        \$agent = @(Get-ChildItem -LiteralPath '$FT2/logs' -File)
        \$boot  = (Get-Date).AddHours(3)
        \$fresh = @(\$agent | Where-Object { \$_.LastWriteTime -ge \$boot })
        Write-Output ('clockfresh=' + \$fresh.Count + ' of ' + \$agent.Count)" 2>/dev/null)
    rm -rf "$FT2"
    case "$clockout" in
      "clockfresh=0 of 1")
        ok "fresh: SEEN TO FAIL - the clock anchor reads a just-written log as stale against a boot stamp 3 h ahead ($clockout)" ;;
      *) bad "fresh: the clock control did not reproduce the false stale ($clockout)" "then this leg does not measure the anchor" ;;
    esac
fi

# 4. THE WIRING, because a predicate nobody calls is decoration - and the PRE-GRADING site is the
#    only correct one: at bind time zero agent logs is expected, a bind applies at the next start.
if sed -n '/pregrade/p' "$ROOT/mgmt/harness/matrix.sh" | grep -q 'require-agent-logs'; then
    ok "proof-agent: the PRE-GRADING call site requires agent logs"
else
    bad "proof-agent: the pre-grading proof does not require agent logs" "the campaign would grade a blind cell again"
fi
if sed -n '/logvol_bind_now(){/,/^}/p' "$ROOT/mgmt/harness/matrix.sh" | grep -q 'require-agent-logs'; then
    bad "proof-agent: the BIND-time proof requires agent logs" "a bind applies at the next start, so this would fail every first bind"
else
    ok "proof-agent: the bind-time proof does NOT require them (a bind applies at the module's next start)"
fi

# ===============================================================================================
# THE PARK MUST CARRY NO LogDir, AND A VOLUME THAT IS NOT AVAILABLE MUST STOP THE CAMPAIGN AT ONCE.
# Scripted, not described: these legs EXECUTE logvol_clear_guest and read matrix.sh's live code.
CT="$(mktemp -d)"; mkdir -p "$CT/bin"
cat > "$CT/bin/qtest-clear" <<'STUB'
#!/bin/bash
case "${CLEARSTUB:-ok}" in
  ok)       echo 'LOGVOL-BIND cleared was=UTpcUXViZXMgTG9ncw== modules=gui-agent,gui-watchdog remaining=0' ;;
  stillset) echo 'LOGVOL-BIND fail reason=logdir_still_set_after_clear keys=(root),gui-agent' ;;
  silent)   : ;;                       # the guest answered nothing at all
esac
STUB
chmod +x "$CT/bin/qtest-clear"
run_clear(){ # $1=mode -> "rc|out"
    local out rc
    out=$( CLEARSTUB="$1" QTEST_BIN="$CT/bin/qtest-clear" bash -c '
             source mgmt/harness/logvol-lib.sh
             logvol_clear_guest somevm 2>&1' ); rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}
r=$(run_clear ok); rc=${r%%|*}; out=${r#*|}
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'LOGVOL-BIND cleared' \
  && ok "clear: a cleared LogDir returns 0 and reports what it removed" \
  || bad "clear: a successful clear was not accepted" "rc=$rc $out"

# SEEN TO FAIL, both ways the guest can refuse: the value still set, and no answer at all.
r=$(run_clear stillset); rc=${r%%|*}; out=${r#*|}
[ "$rc" != 0 ] && ok "clear: a LogDir STILL SET after the clear fails (rc=$rc) - the absence is asserted, not the attempt" \
               || bad "clear: logdir_still_set_after_clear was accepted as success" "$out"
r=$(run_clear silent); rc=${r%%|*}; out=${r#*|}
[ "$rc" != 0 ] && ok "clear: a silent guest fails (rc=$rc) rather than reading as cleared" \
               || bad "clear: no answer from the guest was treated as a clear" "$out"
rm -rf "$CT"

# THE WIRING, on the live call and not on a comment: the park must clear, and must ABORT if it cannot.
_pk=$(sed -n '/^park_installed(){/,/^}/p' "$ROOT/mgmt/harness/matrix.sh")
printf '%s' "$_pk" | command grep -qE '^[^#]*logvol_clear_guest "\$vm"' \
  && ok "park: the park clears LogDir on a live line of park_installed" \
  || bad "park: nothing clears LogDir before the park" "every AppVM from this park would log nowhere"
printf '%s' "$_pk" | sed -n '/logvol_clear_guest/,/fi/p' | command grep -qE '^[^#]*exit 2' \
  && ok "park: a failed clear ABORTS the campaign (exit 2), it does not carry on" \
  || bad "park: a failed clear does not abort" "the appvm cells would be graded over a blind capture"

# AND THE VOLUME MUST BE AVAILABLE, OR THE CAMPAIGN STOPS IMMEDIATELY - owner, 2026-10-21: "if it
# does not attach and become available, it should be hard failure detected immediately and stopping
# the campaign". Three live sites must each abort: the attach, the bind, and the round-trip proof.
_bn=$(sed -n '/^logvol_bind_now(){/,/^}/p' "$ROOT/mgmt/harness/matrix.sh")
for _probe in 'log-volume bind FAILED' 'did NOT survive a round trip'; do
  if printf '%s' "$_bn" | command grep -q "$_probe"; then
    if printf '%s' "$_bn" | sed -n "/$_probe/,/^  fi/p" | command grep -qE '^[^#]*exit 2'; then
      ok "available: '$_probe' aborts the campaign (exit 2)"
    else
      bad "available: '$_probe' does not abort" "a run with no instrument that survives a wedge would continue"
    fi
  else
    bad "available: no '$_probe' path in logvol_bind_now" "the failure would be silent"
  fi
done
if command grep -qE '^[^#]*exit 2' <(sed -n '/log volume NOT ATTACHED/,/^  fi/p' "$ROOT/mgmt/harness/matrix.sh"); then
  ok "available: an UNATTACHED volume aborts the campaign at the attach, not at grading"
else
  bad "available: an unattached volume does not abort at the attach" "detection would be deferred to grading"
fi

echo
echo "RESULT: $pass passed, $fail failed  (fixtures: $T)"
[ "$fail" -eq 0 ]
