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

THREE ANSWERS, THREE EXIT CODES (2026-11-10; it was two, and "nothing found" covered both of the
last two):
  0  resolved    an entry bearing exactly this title carries a package that declares --arch
  1  no-package  the Catalog ANSWERED and holds no such package: its own no-results page, or a
                 complete results page on which every entry bearing exactly this title was
                 inspected and none declares --arch. An answer, not a failure to be papered over.
  2  unresolved  the Catalog did not answer the question: the response is neither its results
                 table nor its no-results page (its error page is one such response), a candidate
                 could not be fetched or opened, or the results page did not show every entry.
                 Never read as "no package".
resolve_title() is the same measurement as a value; tools/wu-catalog-facts.py calls it.
"""
from __future__ import annotations
import argparse, html, re, subprocess, sys, tempfile, urllib.parse
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


def search(title: str, proxy: str | None) -> dict:
    """ONE Catalog search page for the title, CLASSIFIED before anything is read off it.

    page = 'results'     the results table is there (element ctl00_catalogBody_updateMatches)
           'no-results'  the Catalog's OWN "we did not find any results" answer (element
                         ctl00_catalogBody_noResults)
           'invalid'     anything else. MEASURED 2026-11-10 through this qube's proxy: the Catalog's
                         error page (Error.aspx?id=8DDD0010, HTTP 200, 27306 bytes) carries
                         `catalogBody_errorHandler_*` ids and no result row, so a test that accepts
                         any page mentioning `catalogBody` reads an error as "zero results".
    The two ids are ASP.NET control ids, not text: the response LANGUAGE is nondeterministic here
    and they do not move with it. rows = every (updateID, title) the page lists; exact = the rows
    whose title IS the offer's title (whitespace-normalised, entities decoded, case-folded - the
    updater's own rule is equality too, guest/qubes-windows-update.ps1 Resolve-DriverByTitle);
    total = the entry count the page itself states ("1 - 2 of 2 (page 1 of 1)" - read as numbers,
    never as words), or None when it states none."""
    q = urllib.parse.quote(re.sub(r'\s*\(Version [^)]*\)\s*$', '', title).strip())
    body = curl([f'{CATALOG}?q={q}'], proxy).decode('utf-8', 'replace')
    out = {'page': 'invalid', 'bytes': len(body), 'rows': [], 'exact': [], 'total': None}
    if re.search(r'''id=["']ctl00_catalogBody_noResults["']''', body):
        out['page'] = 'no-results'
        return out
    if not re.search(r'''id=["']ctl00_catalogBody_updateMatches["']''', body):
        return out
    out['page'] = 'results'
    def norm(s: str) -> str:
        return ' '.join(html.unescape(re.sub(r'<[^>]+>', '', s)).split()).casefold()
    rows = re.findall(r"id='([0-9a-f-]{36})_link'[^>]*>\s*(.*?)\s*</a>", body, re.S)
    out['rows'] = [(u, ' '.join(t.split())) for u, t in rows]
    out['exact'] = [(u, t) for u, t in out['rows'] if norm(t) == norm(title)]
    m = re.search(r'''id=["']ctl00_catalogBody_searchDuration["'][^>]*>([^<]*)<''', body)
    nums = re.findall(r'\d+', m.group(1)) if m else []
    if len(nums) >= 3:
        out['total'] = int(nums[2])
    return out


def download_url(uid: str, proxy: str | None) -> str | None:
    body = ('updateIDs=' + urllib.parse.quote(
        '[{"size":0,"languages":"","uidInfo":"%s","updateID":"%s"}]' % (uid, uid)))
    page = curl(['-X', 'POST', DIALOG, '--data', body,
                 '--data', 'updateIDsBlockedForImport=&wsusApiPresent=&contentImport=&sku=&serverName=&ssl=&portNumber=&version='],
                proxy).decode('utf-8', 'replace')
    m = re.findall(r"https?://[^'\"]+\.(?:cab|msu|exe)", page)
    return sorted(set(m))[0] if m else None


def package_arch(cab: Path) -> str:
    """The architecture the PACKAGE declares, from the INF's [Manufacturer] line. Not from the
    title, the filename or the size - none of those differ between the variants.
    'uninspected' when the archive would not open or holds no INF: a package nobody read has
    declared nothing, and that is not the same as one that was read and names another architecture
    ('unknown' = an INF was read and names none of the three)."""
    with tempfile.TemporaryDirectory() as td:
        r = subprocess.run(['7z', 'e', '-y', f'-o{td}', str(cab), '*.inf'],
                           capture_output=True)
        infs = sorted(Path(td).glob('*.inf'))
        if r.returncode != 0 or not infs:
            return 'uninspected'
        for inf in infs:
            txt = inf.read_text(errors='replace')
            m = re.search(r'^\[Manufacturer\]\s*(.*?)^\[', txt, re.S | re.M)
            blob = m.group(1) if m else txt
            arches = set(a.lower() for a in re.findall(r'NT(amd64|arm64|x86)', blob, re.I))
            if arches:
                return ','.join(sorted(arches))
    return 'unknown'


def resolve_title(title: str, arch: str = 'amd64', proxy: str | None = None,
                  keep: Path | None = None) -> dict:
    """THE MEASURED ANSWER FOR ONE TITLE, as a value: outcome = resolved | no-package | unresolved
    (the three exit codes in this file's header), why = one sentence a reader can check, plus what
    it rests on - the page class and size, the rows shown and the total the page states, and every
    exact-title candidate with the architecture its package declares.

    'no-package' is only ever said of an ANSWER. A candidate whose download dialog lists nothing,
    whose package did not arrive or would not open, makes the whole search unresolved (the updater
    holds itself to the same rule - "a candidate that could not be inspected leaves the search
    UNRESOLVED", docs/ADR-updater.md section 2 point 5), and so does a results page that shows
    fewer rows than the total it states: an entry on a page nobody fetched was not inspected."""
    s = search(title, proxy)
    res = {'title': title, 'arch': arch, 'page': s['page'], 'bytes': s['bytes'],
           'rows': len(s['rows']), 'exact': len(s['exact']), 'total': s['total'],
           'candidates': [], 'chosen': None}
    if s['page'] == 'invalid':
        return dict(res, outcome='unresolved',
                    why=f"the response is neither the Catalog's results table nor its no-results page ({s['bytes']} bytes)")
    if s['page'] == 'no-results':
        return dict(res, outcome='no-package', why="the Catalog answered with its own no-results page for this title")
    want = arch.lower()
    with tempfile.TemporaryDirectory(prefix='wudrv-') as td:
        store = keep or Path(td)
        store.mkdir(parents=True, exist_ok=True)
        for uid, _t in s['exact']:
            c = {'uid': uid, 'url': download_url(uid, proxy), 'arch': 'uninspected', 'bytes': None}
            if c['url']:
                cab = store / f'{uid}.cab'
                if not cab.exists() or cab.stat().st_size == 0:
                    curl([c['url']], proxy, out=str(cab))
                if cab.exists() and cab.stat().st_size > 0:
                    c['bytes'] = cab.stat().st_size
                    c['arch'] = package_arch(cab)
            res['candidates'].append(c)
            if res['chosen'] is None and want in c['arch'].split(','):
                res['chosen'] = dict(c, file=str(store / f'{uid}.cab') if keep else None)
    blind = [c['uid'] for c in res['candidates'] if c['arch'] == 'uninspected']
    if res['chosen']:
        return dict(res, outcome='resolved',
                    why=f"catalog entry {res['chosen']['uid']} bears exactly this title and its package declares {want}")
    if blind:
        return dict(res, outcome='unresolved',
                    why=f"{len(blind)} of {len(res['candidates'])} exact-title candidate(s) could not be inspected")
    if s['total'] is None or s['total'] != len(s['rows']):
        return dict(res, outcome='unresolved',
                    why=f"the results page shows {len(s['rows'])} row(s) of a stated total of {s['total']} - not every entry was seen")
    if not res['candidates']:
        return dict(res, outcome='no-package',
                    why=f"a complete results page ({len(s['rows'])} row(s)) on which no entry bears exactly this title")
    return dict(res, outcome='no-package',
                why=f"a complete results page ({len(s['rows'])} row(s)): {len(res['candidates'])} bear exactly this title, "
                    f"every one was inspected and none declares {want}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('title')
    ap.add_argument('--arch', default='amd64')
    ap.add_argument('--proxy', default='http://127.0.0.1:8082')
    ap.add_argument('--keep', type=Path, default=None)
    a = ap.parse_args()

    r = resolve_title(a.title, a.arch, a.proxy, a.keep)
    if r['page'] == 'results':
        print(f"{r['exact']} candidate(s) with that exact title ({r['rows']} row(s) shown, total stated {r['total']})")
    for c in r['candidates']:
        mark = '   <-- matches --arch ' + a.arch if a.arch.lower() in c['arch'].split(',') else ''
        size = f"{c['bytes']:>10,} bytes" if c['bytes'] else ('no download offered' if not c['url'] else 'package did not arrive')
        print(f"  {c['uid']}  arch={c['arch']:12s} {size}{mark}")
    print(f"{r['outcome'].upper()}: {r['why']}")
    if r['outcome'] == 'resolved':
        ch = r['chosen']
        print(f"\nCHOSEN {ch['uid']}\n  {ch['url']}" + (f"\n  {ch['file']}" if ch['file'] else ''))
        return 0
    return 1 if r['outcome'] == 'no-package' else 2


if __name__ == '__main__':
    sys.exit(main())
