#!/usr/bin/env python3
"""wu-catalog-facts.py <wu-e2e-dir> [--arch amd64] [--proxy URL] - what the Microsoft Update Catalog holds for every
excluded offer that carries no KB, measured FROM THIS QUBE, with a control that proves the measurement can find a package.

WHY (2026-11-10). The updater leaves an offer out of the number dom0 hears only after verifying it has no route
(docs/ADR-updater.md section 2 point 5); for an offer without a KB the first of its three facts is "the Catalog holds no
entry with exactly this title whose package declares this guest's architecture". The exclusion audit had nothing outside
the updater to hold that against, so the one such offer on the field reporter's environment - an audio driver, offered on
every pass - read "no measured artefact is known for this item" and ended every template-update run INSTRUMENT. This is
that fact, asked again by a different host and a different HTTP client (curl through this qube's proxy; the updater asks
from inside the guest through its relay), by tools/wu-driver-resolve.py's resolve_title().

A "NO PACKAGE" IS ONLY WORTH ITS CONTROL. An instrument that cannot find anything also reports nothing found. So one title
that DOES have a package is resolved in the same invocation, before the items: a KB-less driver this very run installed by
the catalog-title route when there is one (its row says probe=pnputil-enum and the item is not itself excluded), else the
constant below. The control not resolving is exit 2 and the file says so - the day that constant leaves the Catalog this
reads INSTRUMENT until someone names another, which is the correct reading of an instrument that can no longer prove itself.

Writes <wu-e2e-dir>/catalog-resolve.json: measured_utc, arch, proxy, control{title, source, outcome, why}, items{<title>:
{outcome, why, page, rows, exact, total, candidates[{uid, arch, bytes}]}}. tools/wu-exclusion-evidence.py reads it and
compares; nothing here judges an exclusion.
Exit 0 written (the control resolved, or there was nothing to measure); 2 the control did not resolve or the input is missing.
"""
from __future__ import annotations
import argparse, datetime, importlib.util, json, re, sys
from pathlib import Path

CONTROL = 'Microsoft Corporation AudioProcessingObject Driver Update (1.0.4.7057)'   # measured resolving 2026-09-21, 2026-11-08, 2026-11-10


def load_resolver():
    """tools/wu-driver-resolve.py as a module - its name has a hyphen, so it cannot be imported by name."""
    spec = importlib.util.spec_from_file_location('wu_driver_resolve', Path(__file__).resolve().parent / 'wu-driver-resolve.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def measure_catalog(run: Path, arch: str, proxy: str | None, resolve) -> dict:
    """The control, then every KB-less key of excluded-items.tsv, each by resolve(title, arch, proxy)."""
    keys = [l.split('\t')[0] for l in (run / 'excluded-items.tsv').read_text(encoding='utf-8').splitlines() if l.strip()]
    titles = [k for k in keys if not re.fullmatch(r'KB\d+', k) and k != '<no id>']
    doc = {'measured_utc': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
           'arch': arch, 'proxy': proxy, 'control': None, 'items': {}}
    if not titles:
        return doc
    control, source = CONTROL, 'constant'
    for rd in sorted((d for d in run.glob('round*') if d.is_dir()), key=lambda d: int(d.name[5:] or 0)):
        try:
            st = json.loads((rd / 'update-status.json').read_text(encoding='utf-8-sig'))
        except Exception:
            continue
        for r in st.get('result') or []:
            files = r.get('files') if isinstance(r.get('files'), list) else []
            k = str(r.get('kb') or '')
            # THE GUEST WROTE THIS TITLE and it is about to be a query and, later, text a judge reads: only a plain title
            # shape gets through (tools/wu-exclusion-evidence.py SHAPES is the same rule); anything else keeps the constant.
            if (source == 'constant' and r.get('ok') is True and r.get('state') == 'installed' and k not in titles
                    and re.fullmatch(r'[\w .,()+/&:-]{8,200}', k) and not re.fullmatch(r'KB\d+', k)
                    and any(f.get('probe') == 'pnputil-enum' for f in files)):
                control, source = k, f'installed by this run from the Catalog by title ({rd.name})'
    c = resolve(control, arch, proxy)
    doc['control'] = {'title': control, 'source': source, 'outcome': c['outcome'], 'why': c['why']}
    for t in titles:
        r = resolve(t, arch, proxy)
        doc['items'][t] = {'outcome': r['outcome'], 'why': r['why'], 'page': r['page'], 'rows': r['rows'], 'exact': r['exact'],
                           'total': r['total'],
                           'candidates': [{'uid': x['uid'], 'arch': x['arch'], 'bytes': x['bytes']} for x in r['candidates']]}
    return doc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('run_dir', type=Path)
    ap.add_argument('--arch', default='amd64')
    ap.add_argument('--proxy', default='http://127.0.0.1:8082')
    a = ap.parse_args()
    if not (a.run_dir / 'excluded-items.tsv').exists():
        print(f"MISSING: {a.run_dir / 'excluded-items.tsv'}", file=sys.stderr)
        return 2
    doc = measure_catalog(a.run_dir, a.arch, a.proxy, load_resolver().resolve_title)
    out = a.run_dir / 'catalog-resolve.json'
    out.write_text(json.dumps(doc, indent=1, ensure_ascii=False), encoding='utf-8')
    if not doc['items']:
        print(f'no excluded offer without a KB - nothing to ask the Catalog -> {out}')
        return 0
    c = doc['control']
    print(f"control {c['title']!r} ({c['source']}): {c['outcome']} - {c['why']}")
    for t, r in doc['items'].items():
        print(f"item    {t!r}: {r['outcome']} - {r['why']}")
    if c['outcome'] != 'resolved':
        print(f'CONTROL DID NOT RESOLVE - this measurement cannot tell "no package" from "cannot find one" -> {out}', file=sys.stderr)
        return 2
    print(f"catalog facts for {len(doc['items'])} item(s), control resolved -> {out}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
