#!/bin/bash
# Run IN DOM0. Downloads a Windows ISO inside a netvm-attached qube (dom0 stays offline).
# The ISO stays in that qube; attach it later with:  qvm-start win-idd-test --cdrom=<qube>:<path>
# Usage: ./01-fetch-win-iso.sh <download-qube> [10|11]
set -euo pipefail

DLQUBE="${1:?usage: $0 <download-qube> [10|11]}"
WINVER="${2:-10}"   # 10 = Win10 22H2 (preferred: best seamless behavior). Avoid Win11 25H2.

qvm-run --pass-io "$DLQUBE" "bash -s" <<EOF
set -euo pipefail
mkdir -p ~/win-iso && cd ~/win-iso
if [ -n "\$(ls Win*.iso windows*.iso 2>/dev/null)" ]; then
    echo "ISO already present:"; ls -sh *.iso; exit 0
fi
# quickget (quickemu project) resolves official Microsoft download links
if [ ! -x ./quickget ]; then
    curl -fsSLo quickget https://raw.githubusercontent.com/quickemu-project/quickemu/master/quickget
    chmod +x quickget
fi
if ./quickget --download-iso windows "$WINVER"; then
    find . -name '*.iso' -exec mv -n {} . \; 2>/dev/null || true
    echo "Downloaded:"; ls -sh *.iso
else
    cat >&2 <<'FALLBACK'
quickget failed (Win10 may have been dropped post-EOL). Fallbacks:
  1. Fido (https://github.com/pbatard/Fido) in any Windows machine/qube -> retail ISO
  2. Microsoft Evaluation Center: Windows 10 Enterprise LTSC 2021 eval (90 days, fine
     for a driver test qube): https://www.microsoft.com/en-us/evalcenter/
  3. Win11 24H2 via https://www.microsoft.com/software-download/windows11
Place the ISO in ~/win-iso/ of this qube.
FALLBACK
    exit 1
fi
EOF

echo
echo "Attach at install time with:"
echo "  qvm-start win-idd-test --cdrom=${DLQUBE}:/home/user/win-iso/<iso-name>"
