# wimdu.py <wim> <index> <path>... - payload bytes per directory inside a WIM image, and how many of
# them are NOT shared (same stream hash) with the other paths given. Measured the Edge/EdgeCore/EdgeWebView
# hard-link finding in README.md. Needs wimlib-imagex.
import subprocess, sys, collections
wim, idx = sys.argv[1], sys.argv[2]
paths = sys.argv[3:]
hashes = {}
for p in paths:
    out = subprocess.run(["wimlib-imagex","dir",wim,idx,"--path="+p,"--detailed"],capture_output=True,text=True).stdout
    h = {}
    cur_hash=None
    for line in out.splitlines():
        line=line.strip()
        if line.startswith("Hash"):
            cur_hash=line.split("=")[1].strip()
        elif line.startswith("Uncompressed size") and cur_hash:
            h[cur_hash]=int(line.split("=")[1].split()[0]); cur_hash=None
    hashes[p]=h
allother = {}
for p in paths:
    others=set()
    for q in paths:
        if q!=p: others |= set(hashes[q])
    own = {k:v for k,v in hashes[p].items()}
    uniq = {k:v for k,v in own.items() if k not in others}
    print(f"{p:50s} streams={len(own):6d} bytes={sum(own.values())/1e6:8.1f}MB  not-shared-with-others={sum(uniq.values())/1e6:8.1f}MB")
