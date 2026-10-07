#!/usr/bin/env python3
"""Every broker death/hang event in every log on this qube, with: was it an FI build (QGAFAULT-INIT),
was it in an FI cell (path), and what the agent saw. Counting only - no judgment."""
import re, sys, pathlib, collections
EV = re.compile(r'QGABROKER(DIED|HUNG|REAP|BACK|REGFAIL|DOWN)')
FI = re.compile(r'QGAFAULT-INIT|QGAFAULT\b|faultinject', re.I)
TS = re.compile(r'\[(\d{8})\.(\d{6})\.(\d{3})-')
roots = [pathlib.Path(p) for p in sys.argv[1:]]
rows, files = [], 0
for r in roots:
    for f in r.rglob('*'):
        if not f.is_file() or f.suffix not in ('.log', '.out', '.txt') or f.stat().st_size > 80_000_000:
            continue
        try:
            txt = f.read_text(errors='replace')
        except Exception:
            continue
        if 'QGABROKER' not in txt:
            continue
        files += 1
        fi_build = bool(FI.search(txt))
        # strip the harness's own echoed grep command lines (they contain the pattern names)
        for ln in txt.splitlines():
            if 'Select-String' in ln or 'powershell' in ln.lower() or ln.lstrip().startswith('C:\\'):
                continue
            m = EV.search(ln)
            if not m:
                continue
            t = TS.search(ln)
            rows.append({'file': str(f), 'kind': m.group(1), 'fi_build': fi_build,
                         'when': f"{t.group(1)}.{t.group(2)}" if t else '?',
                         'text': ln[ln.find(']') + 1:].strip()[:150]})
print(f"{files} file(s) mention QGABROKER; {len(rows)} event line(s)\n")
by = collections.Counter((r['kind'], r['fi_build']) for r in rows)
for (k, fi), n in sorted(by.items()):
    print(f"  {k:8s} fi_build={fi}  {n}")
print("\nDIED / HUNG / DOWN events, oldest first:")
for r in sorted([x for x in rows if x['kind'] in ('DIED', 'HUNG', 'DOWN')], key=lambda x: x['when']):
    print(f"  {r['when']}  fi={int(r['fi_build'])}  {pathlib.Path(r['file']).parent.name}/{pathlib.Path(r['file']).name}")
    print(f"      {r['text']}")
