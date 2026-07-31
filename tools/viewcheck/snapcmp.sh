#!/bin/bash
# Atomic guest capture (pixels+geometry) + dom0 capture, then compare.
set -uo pipefail
TAG="${1:-snap}"
D=/tmp/claude-1000/-home-user-qubes-win-idd-mgmt/ebcb496b-b293-4889-89db-5e6c2413574b/scratchpad
cd ~/qubes-win-idd-driver
export QTEST_INCOMING='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
qrexec-client-vm dom0 local.WinScreenshot </dev/null > "$D/$TAG-dom0.tar" 2>/dev/null &
DOM0PID=$!
timeout 250 ./tools/qtest pushrun tools/viewcheck/snap.ps1 2>/dev/null | tr -d '\r' > "$D/$TAG.raw"
wait $DOM0PID
rm -rf "$D/$TAG-dom0" && mkdir -p "$D/$TAG-dom0" && tar -xf "$D/$TAG-dom0.tar" -C "$D/$TAG-dom0" 2>/dev/null
python3 - "$D/$TAG.raw" "$D/$TAG-guest.png" "$D/$TAG.json" <<'PY'
import base64,json,sys
s=open(sys.argv[1],errors='replace').read()
def block(t):
    i=s.find(t+'START'); j=s.find(t+'END')
    return s[i+len(t)+5:j].strip().splitlines() if i>=0 and j>=0 else []
def parse(rows):
    out={}
    for r in rows:
        p=r.split('\t')
        if len(p)>=12:
            out[p[0]]=dict(hwnd=p[0],x=int(p[1]),y=int(p[2]),w=int(p[3]),h=int(p[4]),
                           ex=int(p[5]),title=p[6],cls=p[7],
                           ex_x=int(p[8]),ex_y=int(p[9]),ex_w=int(p[10]),ex_h=int(p[11]))
    return out
pre,post=parse(block('GEOPRE')),parse(block('GEOPOST'))
stable=[v for k,v in pre.items() if k in post and (post[k]['x'],post[k]['y'],post[k]['w'],post[k]['h'])==(v['x'],v['y'],v['w'],v['h'])]
moved=[k for k in pre if k in post and k not in {w['hwnd'] for w in stable}]
i=s.find('B64START'); j=s.find('B64END')
open(sys.argv[2],'wb').write(base64.b64decode(''.join(s[i+8:j].split())))
json.dump(stable, open(sys.argv[3],'w'))
print(f"  geometry stable for {len(stable)} windows; moved during capture: {len(moved)}")
PY
echo "  dom0 windows: $(ls "$D/$TAG-dom0" 2>/dev/null | wc -l)"
