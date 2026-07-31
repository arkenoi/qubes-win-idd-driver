#!/bin/bash
# Capture dom0's view AND the guest's ground truth as close together as possible.
set -uo pipefail
TAG="${1:-cmp}"
D=/tmp/claude-1000/-home-user-qubes-win-idd-mgmt/ebcb496b-b293-4889-89db-5e6c2413574b/scratchpad
cd ~/qubes-win-idd-driver
export QTEST_INCOMING='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
# guest ground truth first (fast, in-guest)
./tools/qtest pushrun "$D/guestshot.ps1" >/dev/null 2>&1
# dom0 view
qrexec-client-vm dom0 local.WinScreenshot </dev/null > "$D/$TAG-dom0.tar" 2>/dev/null
# pull the guest png
./tools/qtest pushrun "$D/fetchshot.ps1" 2>/dev/null | tr -d '\r' > "$D/$TAG-b64.txt"
python3 - "$D/$TAG-b64.txt" "$D/$TAG-guest.png" <<'PY'
import base64,sys
s=open(sys.argv[1]).read()
i=s.find('B64START'); j=s.find('B64END')
if i<0 or j<0: print("  guest capture: markers missing"); raise SystemExit
open(sys.argv[2],'wb').write(base64.b64decode(''.join(s[i+8:j].split())))
print("  guest.png ok")
PY
rm -rf "$D/$TAG-dom0" && mkdir -p "$D/$TAG-dom0" && tar -xf "$D/$TAG-dom0.tar" -C "$D/$TAG-dom0" 2>/dev/null
echo "  dom0 windows: $(ls "$D/$TAG-dom0" 2>/dev/null | wc -l)"
