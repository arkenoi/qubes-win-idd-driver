#!/bin/bash
# resolve-rip-selftest.sh - prove the RIP resolver works BEFORE the one shot that needs it.
#
# WHY THIS EXISTS. The open P1 stall has produced NINE raw guest RIPs that nobody could resolve,
# because Windows KASLR re-randomises module bases every boot and nothing recorded them for THAT
# boot. arm-module-bases.sh now records the table; tools/resolve-guest-rip.py does the arithmetic.
# Neither has ever been shown to resolve an address - the pipeline is armed and UNTESTED.
#
# When dom0 `debug-keys d/v` finally catches a spinning vCPU, there is ONE capture. If the resolver
# is wrong then, the specimen is wasted like the previous nine. So it is exercised here, offline,
# against synthetic tables in the recorder's exact on-disk format.
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

echo "=== resolve-rip selftest: $pass passed, $fail failed ==="
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
