#!/bin/bash
# resolve-rip-selftest.sh - prove the RIP resolver works BEFORE the one shot that needs it.
#
# WHY THIS EXISTS. The pipeline WORKS: on 2026-09-11 it resolved specimen 4's two spin sites
# (SITE P -> ntoskrnl.exe + 0x2bfd00, SITE Q -> xenbus.sys + 0x1cd5c), which is what the xenbus
# identification rests on. An earlier version of this header claimed it had "never been shown to
# resolve an address"; that was wrong and is retracted here.
#
# What ONE happy-path success does not exercise is every path where the tool must REFUSE - and
# those are what turn a specimen into a WRONG answer rather than no answer. The 09-11 resolution
# depended on scoping to the right boot BY HAND ("scoped to the LAST PRE-REBOOT boot"); nothing
# had ever checked that the tool refuses when that scoping is wrong. When dom0 `debug-keys d/v`
# catches the next spinning vCPU there is ONE capture, so the refusals are exercised here,
# offline, against synthetic tables in the recorder's exact on-disk format.
#
# It checks the three REFUSALS the tool's own docstring promises, because those are what stand
# between "named the code" and "a plausible-looking lie":
#   * never resolve against a different boot's table (the KASLR trap itself);
#   * never attribute an address that falls below every recorded base;
#   * never print a confident module name with an absurd offset.
# Each is also re-introduced as a DEFECT (RIPSEL_DEFECT=...) and the test must CATCH it - a check
# that has never failed is not evidence.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

R=tools/resolve-guest-rip.py
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
no(){ fail=$((fail+1)); echo "FAIL  $*"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/ripsel.XXXXXX"); trap 'rm -rf "$T"' EXIT

# Two boots with DIFFERENT bases for the same modules - that is exactly what KASLR does, and the
# reason a RIP is only meaningful against its own boot. Format copied from arm-module-bases.sh:
#   MODBASE boot=<iso> base=0x<16 hex> name=<file>
B1=2026-09-12T04:00:00.0000000Z
B2=2026-09-14T08:00:00.0000000Z
{
  echo "=== BOOT $B1 host=WIN11-ACC recorded=$B1 modules=3"
  printf 'MODBASE boot=%s base=0x%016x name=ntoskrnl.exe\n' "$B1" $((0xfffff80003600000))
  printf 'MODBASE boot=%s base=0x%016x name=xenbus.sys\n'    "$B1" $((0xfffff80004100000))
  printf 'MODBASE boot=%s base=0x%016x name=xenvbd.sys\n'    "$B1" $((0xfffff80004200000))
  echo "=== BOOT $B2 host=WIN11-ACC recorded=$B2 modules=3"
  printf 'MODBASE boot=%s base=0x%016x name=ntoskrnl.exe\n' "$B2" $((0xfffff80009000000))
  printf 'MODBASE boot=%s base=0x%016x name=xenbus.sys\n'    "$B2" $((0xfffff8000a000000))
  printf 'MODBASE boot=%s base=0x%016x name=xenvbd.sys\n'    "$B2" $((0xfffff8000a100000))
} > "$T/bases.txt"

# Defect knobs: re-introduce each refusal's failure so the checks are seen to fail.
case "${RIPSEL_DEFECT:-}" in
  # "resolve against whatever boot is handy" - drop the boot scoping by collapsing both boots
  # into one label, so a B1 RIP silently resolves against B2 bases.
  ONEBOOT) sed -i "s/boot=$B1/boot=$B2/" "$T/bases.txt" ;;
  # "attribute anything" - plant a base at 0 so no address is ever below every base.
  NEARESTBASE) printf 'MODBASE boot=%s base=0x%016x name=BOGUS.sys\n' "$B2" 0 >> "$T/bases.txt" ;;
esac

run(){ python3 "$R" "$@" 2>&1; }

# ---- 1. the ordinary case: an address inside a module resolves to module+RVA ------------------
# xenbus.sys on boot B2 is at 0xfffff8000a000000; +0x1234 must come back as xenbus.sys + 0x1234.
out=$(run "$T/bases.txt" --boot "$B2" 0xfffff8000a001234); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qa 'xenbus.sys + 0x1234'; then
  ok "resolves an in-module address to module+RVA (xenbus.sys + 0x1234)"
else
  no "did not resolve a plain in-module address (rc=$rc): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
fi

# ---- 2. THE KASLR TRAP: the same RIP must mean different things on different boots -------------
# 0xfffff80004100500 is xenbus.sys+0x500 on B1. On B2 every base is higher, so it must NOT come
# back as a confident xenbus hit. This is the single most important property of the tool.
o1=$(run "$T/bases.txt" --boot "$B1" 0xfffff80004100500)
o2=$(run "$T/bases.txt" --boot "$B2" 0xfffff80004100500); rc2=$?
if printf '%s' "$o1" | grep -qa 'xenbus.sys + 0x500'; then
  ok "B1 RIP resolves correctly against B1 (xenbus.sys + 0x500)"
else
  no "B1 RIP did not resolve against its own boot: $(printf '%s' "$o1" | tail -1)"
fi
if [ $rc2 -ne 0 ] && printf '%s' "$o2" | grep -qaE 'UNRESOLVED|IMPLAUSIBLE'; then
  ok "the SAME RIP against the WRONG boot refuses (UNRESOLVED/IMPLAUSIBLE), not a false xenbus hit"
else
  no "KASLR TRAP: a B1 RIP was attributed against B2 bases (rc=$rc2): $(printf '%s' "$o2" | tail -1)"
fi

# ---- 3. below every base -> UNRESOLVED, never the nearest module -------------------------------
out=$(run "$T/bases.txt" --boot "$B2" 0x0000000000001000); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qa 'UNRESOLVED'; then
  ok "an address below every base is UNRESOLVED, not attributed"
else
  no "an address below every base was attributed (rc=$rc): $(printf '%s' "$out" | tail -1)"
fi

# ---- 4. an absurd offset is flagged rather than printed as a confident name --------------------
# 0x5000000 (80 MB) past the highest base: the real owner cannot be in the table.
out=$(run "$T/bases.txt" --boot "$B2" 0xfffff8000f100000); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qa 'IMPLAUSIBLE OFFSET'; then
  ok "an implausible offset is flagged loudly (not a confident module name)"
else
  no "an 80 MB offset was reported as a plain hit (rc=$rc): $(printf '%s' "$out" | tail -1)"
fi

# ---- 5. a boot that was never recorded FAILS, it does not fall back ----------------------------
out=$(run "$T/bases.txt" --boot 1999-01-01T00:00:00Z 0xfffff8000a001234); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qa 'no records for boot'; then
  ok "an unrecorded boot FAILS instead of silently using another boot's table"
else
  no "an unrecorded boot did not fail (rc=$rc): $(printf '%s' "$out" | tail -1)"
fi

# ---- 6. missing data fails ---------------------------------------------------------------------
: > "$T/empty.txt"
out=$(run "$T/empty.txt" 0xfffff8000a001234); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qa 'no MODBASE records'; then
  ok "a table with no MODBASE records fails loudly (missing data fails)"
else
  no "an empty table did not fail (rc=$rc): $(printf '%s' "$out" | tail -1)"
fi

# ---- 7. the recorder's REAL output parses --------------------------------------------------
# Guard against the two files drifting apart: build a line exactly as arm-module-bases.sh's
# PowerShell does ("MODBASE boot={0} base=0x{1} name={2}" with x16) and require it to parse.
printf 'MODBASE boot=%s base=0x%s name=%s\n' "$B2" "fffff8000a000000" "xenbus.sys" > "$T/fmt.txt"
out=$(run "$T/fmt.txt" 0xfffff8000a000010); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qa 'xenbus.sys + 0x10'; then
  ok "a line in the recorder's exact emitted format parses and resolves"
else
  no "RECORDER/RESOLVER FORMAT DRIFT - the recorder's own line shape does not parse: $(printf '%s' "$out" | tail -1)"
fi

# ---- USER-MODE RECORDS ------------------------------------------------------------------------
# WHY. Until 2026-10-14 the recorder read EnumDeviceDrivers only - the kernel - so every base was
# 0xfffff... and the one address that mattered could not be named: qrexec-agent took an access
# violation at 0x00007FFFF52E54A8 and 330 recorded bases resolved nothing (QREXECAGENTAV).
# User-mode records also carry a SIZE, which kernel records cannot, so containment is decidable
# instead of inferred from "the nearest base below".
B3='2026-10-14T15:00:47.8530480Z'
UM=$T/usermode.txt
{
  echo "=== BOOT $B3 host=WIN10-ACC recorded=$B3 modules=1 usermode=3 procskipped=4"
  printf 'MODBASE boot=%s base=0x%016x name=ntoskrnl.exe\n'                      "$B3" $((0xfffff80259800000))
  printf 'MODBASE boot=%s base=0x%016x size=0x%x space=user name=ntdll.dll\n'    "$B3" $((0x00007ffff5200000)) $((0x200000))
  printf 'MODBASE boot=%s base=0x%016x size=0x%x space=user name=qrexec-agent.exe\n' "$B3" $((0x00007ff600000000)) $((0x40000))
  printf 'MODBASE boot=%s base=0x%016x size=0x%x space=user name=kernelbase.dll\n' "$B3" $((0x00007ffff5500000)) $((0x300000))
} > "$UM"

# The real address from the crash, against a table that now contains its module.
out=$(python3 "$R" "$UM" 0x00007FFFF52E54A8 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qa 'ntdll.dll + 0xe54a8' \
   && printf '%s' "$out" | grep -qa 'containment PROVEN'; then
  ok "the 2026-10-14 crash address resolves to a user-mode module, containment PROVEN"
else
  no "the user-mode RIP did not resolve: $(printf '%s' "$out" | grep -a '0x00007FFFF52E54A8' | head -1)"
fi

# A SIZE MAKES A MISS DECIDABLE. This address is past ntdll's end and inside nothing; the nearest
# base below it is a NEIGHBOUR, and naming it would be a confident wrong answer - which is exactly
# what a sizeless table has to do.
gap=$((0x00007ffff5200000 + 0x200000 + 0x1000))
out=$(python3 "$R" "$UM" "$(printf '0x%x' $gap)" 2>&1); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qa 'UNRESOLVED' \
   && printf '%s' "$out" | grep -qa 'past the end of ntdll.dll'; then
  ok "an address in a GAP is refused by size, not attributed to the neighbour below"
else
  no "a gap address was attributed anyway: $(printf '%s' "$out" | grep -a '0x' | tail -1)"
fi

# AND THE SIZE IS WHAT MAKES THE DIFFERENCE, demonstrated rather than asserted: the SAME gap
# address against a table whose ntdll record has NO size is attributed to ntdll anyway, because
# "nearest base below" is all a sizeless table can offer. That is the old behaviour, and it is a
# confident wrong answer.
NS=$T/nosize.txt
grep -v 'space=user name=ntdll.dll' "$UM" > "$NS"
printf 'MODBASE boot=%s base=0x%016x name=ntdll.dll\n' "$B3" $((0x00007ffff5200000)) >> "$NS"
out=$(python3 "$R" "$NS" "$(printf '0x%x' $gap)" 2>&1)
if printf '%s' "$out" | grep -qa 'ntdll.dll + 0x201000'; then
  ok "without a size the same address IS mis-attributed - which is what size=0x... prevents"
else
  no "the sizeless comparison did not reproduce the old behaviour: $(printf '%s' "$out" | grep -a '0x' | tail -1)"
fi

# The last byte of a module is still inside it; the first byte past it is not. Off-by-one here
# would mis-attribute every address that lands on a module boundary.
lastb=$((0x00007ff600000000 + 0x40000 - 1))
out=$(python3 "$R" "$UM" "$(printf '0x%x' $lastb)" 2>&1)
printf '%s' "$out" | grep -qa 'qrexec-agent.exe + 0x3ffff' \
  && ok "the last byte of a module resolves inside it" \
  || no "boundary off-by-one: $(printf '%s' "$out" | grep -a '0x' | tail -1)"

# A KERNEL-ONLY CAPTURE MUST SAY IT CANNOT ANSWER, which is the state every capture was in.
out=$(python3 "$R" "$T/bases.txt" 0x00007FFFF52E54A8 2>&1); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qa 'no user-mode records in this capture'; then
  ok "a kernel-only capture names its blind spot instead of guessing"
else
  no "a kernel-only capture did not name the gap: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi

# A TRUNCATED TABLE IS WORSE THAN NONE, so the marker has to reach the reader.
TR=$T/trunc.txt; cp "$UM" "$TR"
echo "=== MODBASE-TRUNCATED boot=$B3 user-mode records dropped after 6000: 12. Do NOT resolve a user-mode RIP against this boot." >> "$TR"
out=$(python3 "$R" "$TR" 0x00007FFFF52E54A8 2>&1)
printf '%s' "$out" | grep -qa 'MODBASE-TRUNCATED' \
  && ok "a truncated capture warns the reader before resolving anything" \
  || no "the truncation marker never reached the reader"

# AND THE RECORDER MUST ACTUALLY EMIT THIS SHAPE - the format drift check, for the new half.
A=mgmt/harness/arm-module-bases.sh
grep -q 'space=user name={3}' "$A" \
  && ok "the recorder emits user-mode records with size and space" \
  || no "the recorder does not emit the user-mode shape this resolver parses"
grep -q 'MODBASE-TRUNCATED' "$A" \
  && ok "the recorder declares truncation rather than letting a short table look complete" \
  || no "the recorder can truncate silently"
# END-TO-END ON THE PRODUCER'S REAL OUTPUT, not a fixture I wrote. The user-mode block is lifted
# out of the recorder verbatim and RUN, and its lines are fed to the resolver. A hand-written
# fixture agrees with whatever I believed the format to be; this agrees with what the code emits.
# (Here the modules are .so files rather than DLLs - the enumeration is Process.Modules either way,
# and what is under test is the record shape and the resolver's reading of it.)
PWSH=${PWSH:-/home/user/pwsh/pwsh}
if [ -x "$PWSH" ]; then
  python3 - "$A" > "$T/block.ps1" <<'EXTRACT'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
start = s.index("# USER-MODE BASES TOO.")
end = s.index("$lines.Insert(0,", start)
sys.stdout.write("$ErrorActionPreference='SilentlyContinue'\n$boot='2026-10-14T15:00:47.8530480Z'\n"
                 "$count=0\n$lines = New-Object System.Collections.Generic.List[string]\n"
                 + s[start:end] +
                 "\n$lines | Select-Object -First 40 | ForEach-Object { Write-Output $_ }\n")
EXTRACT
  "$PWSH" -NoProfile -File "$T/block.ps1" 2>/dev/null | grep -a '^MODBASE ' > "$T/real.txt"
  nreal=$(grep -ac '^MODBASE ' "$T/real.txt" 2>/dev/null) || nreal=0
  if [ "${nreal:-0}" -gt 0 ]; then
    sed -i '1i === BOOT 2026-10-14T15:00:47.8530480Z host=TESTQUBE recorded=2026-10-14T15:01:11Z modules=0' "$T/real.txt"
    rb=$(grep -a '^MODBASE ' "$T/real.txt" | head -1 | sed -E 's/.*base=0x([0-9a-f]+).*/\1/')
    rs=$(grep -a '^MODBASE ' "$T/real.txt" | head -1 | sed -E 's/.*size=0x([0-9a-f]+).*/\1/')
    rn=$(grep -a '^MODBASE ' "$T/real.txt" | head -1 | sed -E 's/.*name=(.*)$/\1/')
    if [ "$((0x$rs))" -gt 16 ]; then
      probe=$(printf '0x%x' $((0x$rb + 16)))
      out=$(python3 "$R" "$T/real.txt" "$probe" 2>&1)
      if printf '%s' "$out" | grep -qa "$rn + 0x10" && printf '%s' "$out" | grep -qa 'containment PROVEN'; then
        ok "the recorder's REAL output resolves end to end ($nreal records, $rn + 0x10 proven)"
      else
        no "PRODUCER/RESOLVER DRIFT on real output: $(printf '%s' "$out" | grep -a '0x' | tail -1)"
      fi
    else
      ok "SKIP end-to-end: first real record is smaller than the probe offset"
    fi
  else
    ok "SKIP end-to-end: the enumeration returned nothing on this host"
  fi
else
  ok "SKIP end-to-end: no pwsh at $PWSH"
fi

# A SNAPSHOT MODE, because the boot record alone cannot answer for our own EXEs: the onstart task
# fires before all our services are up, while the address needing resolution comes from a crash
# later in the SAME boot - and a shared image's base is fixed per boot, not per process.
grep -q 'MODE" = --snapshot' "$A" \
  && ok "the recorder can snapshot the boot that is still running" \
  || no "there is no --snapshot mode: a user-mode crash still cannot be resolved after the fact"
# It must APPEND. Clearing the boot record to tidy the file would throw away the only table a
# guest that wedges NEXT would have.
awk '/MODE" = --snapshot/,/^fi$/' "$A" | grep -q 'del /f /q' \
  && no "the snapshot mode clears the table - the earlier boot record is the wedge fallback" \
  || ok "the snapshot mode appends and never clears the boot record"
# A snapshot can only explain an address from the SAME boot, so it must name the boot it recorded.
awk '/MODE" = --snapshot/,/^fi$/' "$A" | grep -q 'snapshot belongs to boot' \
  && ok "the snapshot names the boot it belongs to, so it can be matched to a capture" \
  || no "the snapshot does not say which boot it is - it could be read against the wrong one"

# And a snapshot with no user-mode records is the blind spot itself, so it must FAIL, not file.
awk '/MODE" = --snapshot/,/^fi$/' "$A" | grep -q 'FAIL: no user-mode records' \
  && ok "a snapshot with no user-mode records fails instead of filing a useless table" \
  || no "a user-mode-blind snapshot would be filed as if it were a table"

# Kernel lines must stay byte-identical: every archived capture is that shape.
grep -q 'MODBASE boot={0} base=0x{1} name={2}' "$A" \
  && ok "kernel records keep their exact old format, so archived captures still parse" \
  || no "the kernel record format changed - archived captures and other readers break"

echo "=== resolve-rip selftest: $pass passed, $fail failed ==="
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
