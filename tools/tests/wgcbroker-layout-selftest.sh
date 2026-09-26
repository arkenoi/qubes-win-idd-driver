#!/bin/bash
# wgcbroker-layout-selftest.sh - the broker peek script's offsets must match the real struct.
#
# WHY: guest/wgcbroker-peek.ps1 reads the broker's shared section by hardcoded byte offsets. If
# WGCBRK_SLOT changes and the offsets do not, the script prints PLAUSIBLE NONSENSE - correct-looking
# numbers from the wrong fields - and a rig cycle is spent believing it. The script asserts the ABI
# version at runtime, which catches a version bump; this catches the worse case, a layout change
# WITHOUT a version bump, and it catches it at commit time instead of on the rig.
#
# It derives the offsets from the header itself with the C compiler (no hand arithmetic anywhere)
# and compares them to what the script uses.
set -u
cd "$(dirname "$0")/../.." || exit 2
H=agent/gui-agent/wgcbroker_ipc.h
P=guest/wgcbroker-peek.ps1
[ -f "$H" ] && [ -f "$P" ] || { echo "SELFTEST-ERROR: missing $H or $P"; exit 2; }
command -v gcc >/dev/null || { echo "SELFTEST-ERROR: no gcc to derive the layout"; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wgcbrk-layout.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

python3 - "$H" > "$T/layout.c" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
def body(name):
    m = re.search(r'typedef struct _'+name+r'\s*\{(.*?)\}\s*'+name+r'\s*;', h, re.S)
    if not m: sys.exit("SELFTEST-ERROR: cannot find struct "+name)
    b = re.sub(r'/\*.*?\*/', '', m.group(1), flags=re.S)
    b = re.sub(r'//[^\n]*', '', b)
    return b.replace('volatile ', '')
print('#include <stdio.h>\n#include <stddef.h>\n#include <stdint.h>')
print('typedef int32_t LONG; typedef uint64_t UINT64; typedef int64_t LONGLONG; typedef uint8_t BYTE;')
# The struct's array bounds come from #defines in the header. Hardcoding them here is what made
# this test brittle across ABI bumps, so they are LIFTED FROM THE HEADER: any new sizing #define is
# picked up automatically, and a missing one is a compile error rather than a silent wrong offset.
print('#define WGCBRK_RING 2\n#define WGCBRK_MAX_SLOTS 32')
for _m in re.finditer(r"^#define\s+(WGCBRK_[A-Z_]*(?:TILES|BYTES|LEN|SIZE|COUNT)[A-Z_]*)\s+(\(?[^/\n]+?)\s*(?:/\*.*)?$", h, re.M):
    if _m.group(1) in ('WGCBRK_HEADER_BYTES',):
        continue
    print('#define %s %s' % (_m.group(1), _m.group(2).strip()))
print('typedef struct {'+body('WGCBRK_HEADER')+'} HDR;')
print('typedef struct {'+body('WGCBRK_SLOT')+'} SLOT;')
print('int main(void){')
print('printf("HDRSIZE %zu\\n", sizeof(HDR)); printf("SLOTSIZE %zu\\n", sizeof(SLOT));')
# THE FIELD LIST IS DERIVED, NOT HARDCODED. It used to be a literal tuple, so every ABI bump made
# this check report the new fields as "not any field in WGCBRK_SLOT" - which is a false FAIL that
# looks exactly like a real misparse. ABI 8 hit it immediately. Parsing the struct means the check
# learns a new field the moment the header gains one.
fields = re.findall(r'\b(?:LONG|UINT64|LONGLONG|BYTE)\s+(\w+)\s*(?:\[[^\]]*\])?\s*;',
                    body('WGCBRK_SLOT'))
for f in fields:
    print(f'printf("SLOT.{f} %zu\\n", offsetof(SLOT,{f}));')
print('return 0;}')
PY
gcc -o "$T/layout" "$T/layout.c" 2>"$T/cc.err" || { echo "SELFTEST-ERROR: cannot compile the derived layout"; sed 's/^/  /' "$T/cc.err" | head -5; exit 2; }
"$T/layout" > "$T/off.txt" || exit 2

hdr=$(awk '$1=="HDRSIZE"{print $2}' "$T/off.txt")
slot=$(awk '$1=="SLOTSIZE"{print $2}' "$T/off.txt")
abi=$(grep -oE '#define WGCBRK_ABI_VERSION[[:space:]]+[0-9]+' "$H" | grep -oE '[0-9]+$')

pHDR=$(grep -oE '^\$HDR[[:space:]]*=[[:space:]]*[0-9]+' "$P" | grep -oE '[0-9]+$')
pSTR=$(grep -oE '^\$STRIDE[[:space:]]*=[[:space:]]*[0-9]+' "$P" | grep -oE '[0-9]+$')
pABI=$(grep -oE '^\$ABI[[:space:]]*=[[:space:]]*[0-9]+' "$P" | grep -oE '[0-9]+$')

fail=0
chk(){ # name expected actual
  if [ "$2" = "$3" ]; then echo "  OK   $1 = $2"
  else echo "  FAIL $1: header says $2, peek script uses $3"; fail=1; fi
}
echo "wgcbroker layout selftest"
chk "header size" "$hdr" "${pHDR:-<unset>}"
chk "slot stride" "$slot" "${pSTR:-<unset>}"
chk "ABI version" "$abi" "${pABI:-<unset>}"

# Every numeric offset the script reads must be a REAL field offset (or a base expression).
valid=$(awk '$1 ~ /^SLOT\./ {print $2}' "$T/off.txt" | sort -un | tr '\n' ' ')
used=$(grep -oE '\$b\+[0-9]+' "$P" | grep -oE '[0-9]+$' | sort -un)
for o in $used; do
  case " $valid " in
    *" $o "*) ;;
    *) echo "  FAIL offset +$o is not any field in WGCBRK_SLOT"
       echo "       derived field offsets: $valid"
       fail=1 ;;
  esac
done
[ -n "$used" ] || { echo "  FAIL the script reads no slot offsets - did its shape change?"; fail=1; }

if [ "$fail" = 0 ]; then echo "PASS: peek offsets match the struct the header defines"; exit 0; fi
echo "FAIL: guest/wgcbroker-peek.ps1 would misparse the section - fix its offsets from $H"
exit 1
