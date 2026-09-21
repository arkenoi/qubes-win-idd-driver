#!/usr/bin/env python3
"""wu-driver-resolve.py - resolve a KB-LESS Windows Update offer to the right catalog package.

THE GAP THIS CLOSES. Some offers carry no KB and no self-contained URL - measured on GWeck's
environment: "Microsoft Corporation AudioProcessingObject Driver Update (1.0.4.7057)",
content_class=none, direct_urls=[]. The updater resolves the catalog BY KB, so it has no handle on
them and excludes them. That exclusion is honest but it is a limitation, not a property of the
offer: the catalog does hold the item, under its title, and serves a real .cab.

WHY THE TITLE IS NOT ENOUGH, and why this tool exists. That offer matches TWO catalog entries with
byte-identical titles AND identical product strings. The only thing that tells them apart is inside
the package: one INF declares `[Manufacturer] ... NTARM64`, the other `NTamd64`. Picking by title,
by order, or by size would be guessing. So: download each candidate, read its INF, and select on
the ARCHITECTURE THE PACKAGE ITSELF DECLARES. That is the same rule the rest of this project
follows - judge the artefact, not the label on it.

    tools/wu-driver-resolve.py "<offer title>" [--arch amd64|arm64] [--proxy URL] [--keep DIR]

Prints one line per candidate with its declared architecture, then the chosen updateID and URL.
Exit 1 if nothing matches the requested architecture - that is an answer, not a failure to be
papered over.
"""
from __future__ import annotations
import argparse, re, subprocess, sys, tempfile, urllib.parse
from pathlib import Path

CATALOG = 'https://www.catalog.update.microsoft.com/Search.aspx'
DIALOG = 'https://catalog.update.microsoft.com/DownloadDialog.aspx'


def curl(args: list[str], proxy: str | None, out: str | None = None) -> bytes:
    cmd = ['curl', '-sS', '--max-time', '300']
    if proxy:
        cmd += ['-x', proxy]
    if out:
        cmd += ['-o', out]
    cmd += args
    r = subprocess.run(cmd, capture_output=True)
    return r.stdout


def search(title: str, proxy: str | None) -> list[tuple[str, str]]:
    """Catalog rows (updateID, title) whose title CONTAINS the offer title. The catalog's response
    language is nondeterministic, so this narrows on the untranslated tokens the offer itself
    carries - and never decides anything on that basis."""
    q = urllib.parse.quote(re.sub(r'\s*\(Version [^)]*\)\s*$', '', title).strip())
    html = curl([f'{CATALOG}?q={q}'], proxy).decode('utf-8', 'replace')
    rows = re.findall(r"id='([0-9a-f-]{36})_link'[^>]*>\s*(.*?)\s*</a>", html, re.S)
    want = title.strip()
    return [(u, ' '.join(t.split())) for u, t in rows if want in ' '.join(t.split())]


def download_url(uid: str, proxy: str | None) -> str | None:
    body = ('updateIDs=' + urllib.parse.quote(
        '[{"size":0,"languages":"","uidInfo":"%s","updateID":"%s"}]' % (uid, uid)))
    html = curl(['-X', 'POST', DIALOG, '--data', body,
                 '--data', 'updateIDsBlockedForImport=&wsusApiPresent=&contentImport=&sku=&serverName=&ssl=&portNumber=&version='],
                proxy).decode('utf-8', 'replace')
    m = re.findall(r"https?://[^'\"]+\.(?:cab|msu|exe)", html)
    return sorted(set(m))[0] if m else None


def package_arch(cab: Path) -> str:
    """The architecture the PACKAGE declares, from the INF's [Manufacturer] line. Not from the
    title, the filename or the size - none of those differ between the variants."""
    with tempfile.TemporaryDirectory() as td:
        subprocess.run(['7z', 'e', '-y', f'-o{td}', str(cab), '*.inf'],
                       capture_output=True)
        for inf in Path(td).glob('*.inf'):
            txt = inf.read_text(errors='replace')
            m = re.search(r'^\[Manufacturer\]\s*(.*?)^\[', txt, re.S | re.M)
            blob = m.group(1) if m else txt
            arches = set(a.lower() for a in re.findall(r'NT(amd64|arm64|x86)', blob, re.I))
            if arches:
                return ','.join(sorted(arches))
    return 'unknown'


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('title')
    ap.add_argument('--arch', default='amd64')
    ap.add_argument('--proxy', default='http://127.0.0.1:8082')
    ap.add_argument('--keep', type=Path, default=None)
    a = ap.parse_args()

    cands = search(a.title, a.proxy)
    if not cands:
        print('no catalog entry matches that title'); return 1
    print(f'{len(cands)} candidate(s) with that exact title')
    keep = a.keep or Path(tempfile.mkdtemp(prefix='wudrv-'))
    keep.mkdir(parents=True, exist_ok=True)
    chosen = None
    for uid, t in cands:
        url = download_url(uid, a.proxy)
        if not url:
            print(f'  {uid}  no download offered'); continue
        cab = keep / f'{uid}.cab'
        if not cab.exists():
            curl([url], a.proxy, out=str(cab))
        arch = package_arch(cab)
        mark = ''
        if a.arch.lower() in arch.split(','):
            mark = '   <-- matches --arch ' + a.arch
            chosen = chosen or (uid, url, cab)
        print(f'  {uid}  arch={arch:12s} {cab.stat().st_size:>10,} bytes{mark}')
    if not chosen:
        print(f'NO candidate declares {a.arch} - this offer is not installable on that architecture')
        return 1
    uid, url, cab = chosen
    print(f'\nCHOSEN {uid}\n  {url}\n  {cab}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
