#!/bin/bash
# FAIL-PROOF for `window-chrome-present` (tools/check-chrome.py).
#
# H5: a check is evidence only once it has been SEEN to go red with the defect present. This one is
# provable entirely OFFLINE - check-chrome.py reads a PNG, so the "defect" is simply an image with
# no window chrome, which is exactly what a guest whose title bar never reached dom0 would produce.
# Two-sided: a real captured window must PASS, a chrome-less image must FAIL.
set -uo pipefail
cd "$(dirname "$0")/../.."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0

# --- the NEGATIVE: a flat image with no title bar and no border bands
python3 - "$TMP/nochrome.png" <<'PY'
import struct, zlib, sys
w,h = 640,400
raw = b''.join(b'\x00' + bytes([40,40,40]*w) for _ in range(h))   # uniform dark, no chrome at all
def chunk(t,d):
    c=struct.pack('>I',len(d))+t+d
    return c+struct.pack('>I', zlib.crc32(t+d)&0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w,h,8,2,0,0,0))
       + chunk(b'IDAT', zlib.compress(raw))
       + chunk(b'IEND', b''))
open(sys.argv[1],'wb').write(png)
PY

echo "=== NEGATIVE: a chrome-less image must FAIL ==="
out=$(tools/check-chrome.py "$TMP/nochrome.png" 2>&1); neg=$?
echo "  rc=$neg  $(echo "$out" | head -1)"
if [ "$neg" -eq 0 ]; then
  echo "  -> NOT RED: check-chrome.py PASSED an image with no chrome at all. The check cannot"
  echo "     detect a missing title bar, so every window-chrome-present PASS is meaningless."
  rc=1
else
  echo "  -> RED AS REQUIRED"
fi

# --- the POSITIVE: a real captured guest window must still pass, or the check is simply broken
POS=$(ls -S "$HOME"/qwt-accept/20260830-acceptance-4.3.16/*/*.png 2>/dev/null | head -1)
if [ -n "$POS" ]; then
  echo "=== POSITIVE: a real captured window must PASS ($(basename "$POS")) ==="
  out2=$(tools/check-chrome.py "$POS" 2>&1); pos=$?
  echo "  rc=$pos  $(echo "$out2" | head -1)"
  [ "$pos" -eq 0 ] || { echo "  -> the checker rejects a genuine window capture; it is over-strict, not proven"; rc=1; }
else
  echo "=== POSITIVE: no captured window PNG on disk to test against - positive side NOT run ==="
  rc=1
fi
exit $rc
