#!/usr/bin/env python3
"""wu-exclusion-evidence.py <wu-e2e-dir> <out.json> - the INDEPENDENT evidence tools/wu-exclusion-audit.py --evidence asks for, built
from facts the harness measured on the guest before and after each pass, never from the updater's own claims.

Why (2026-10-03): the rz35 release gate's template-update test ran the exclusion audit with no evidence, and Jev - given only the
updater's rows - could not judge the three Defender items dom0 was not told about (two concealed-failure ~0.34, one unproven); the decisive
measurement it named was the artefact version.

mgmt/harness/wu-e2e.sh writes round<N>/facts-before.txt and round<N>/facts-after.txt with mgmt/harness/wu-evidence-facts.sh around every
pass ('EV|key=value': Defender platform / engine / signature versions once Defender has loaded, the Windows Security PLATFORM (the version
folder CoreLocation names, or 'inbox') and the wu value of its Updates key, the Windows Security app's installed and provisioned versions (information:
the app is not KB5007651's artefact), the OS build, the installed hotfixes, the boot time; EV|end=1 last). For every item in excluded-items.tsv the
evidence gives, for each round that EXCLUDED it, that round's before/after artefacts and a comparison computed here (the artefact after
the pass vs the version the round's offer carried in its title, and whether the pass moved it), plus the item's history in the updater's
rows, each round labelled excluded or counted by the audit's own predicate. Per round, because the audit judges a round's claim: one
read after the whole run cannot speak for an earlier round (rz35: KB2267602 already current in round 2, its signatures moved again in
round 3). Counting and matching only; the judgment stays Jev's.

ONE CLASS IS DECIDED HERE, BY COMPARISON, AND NOT BY A JUDGE (2026-11-10): an offer that carries no KB and that the updater lists in
`unroutable` in every round that excluded it. The updater's claim is then a structured one - three facts, named in docs/ADR-updater.md
section 2 point 5 - and each has a measurement taken outside the updater: the Catalog's answer for that exact title, asked from this
qube with a control (tools/wu-catalog-facts.py -> <wu-e2e-dir>/catalog-resolve.json); the offer's content as the Windows Update agent
itself holds it after each excluding pass (the 'EV|offer=' lines of facts-after.txt - for a round whose own read cannot hold the offer,
the same content-free UpdateID and revision as read in another excluding round, see unroutable_compare); and the qube's netvm as env-assert.sh read it
from the Admin API (<wu-e2e-dir>/../preflight/env-assert.out). Whether three recorded values agree with a recorded claim is a
comparison, so it is made in code (unroutable_compare) and written beside the text as `measured` = {class, verdict: agree |
contradicts, why}; the audit's gate honours it before any judgment. A fact that was not measured is neither: it is named and this
exits 2. Such an item's evidence is an object {"text", "measured"}; every other item's is the string it always was.
WHY: the judge was given exactly this measurement by hand on 2026-11-08 and answered correct-exclusion 0.49, 0.57 and 0.63 and
insufficient-evidence 0.51 across four calls - none above the floor, one in four ending the suite INSTRUMENT - on an offer the field
reporter's environment presents on every pass.
Exit 0 written, 2 missing input - an excluded round without complete facts, or nothing to write (missing data fails)."""
import base64, json, os, re, sys
from pathlib import Path


def load_status(p: Path):
    try:
        return json.loads(p.read_text(encoding='utf-8-sig'))
    except Exception:
        return None


# WHICH MEASURED ARTEFACT ANSWERS FOR AN ITEM - by its fixed Defender KB, else by its title (any language: the KB is the anchor).
def artefact_for(kb: str, title: str):
    t = (title or '').lower()
    if kb == 'KB4052623' or 'antimalware platform' in t or 'antischadsoftwareplattform' in t:
        return 'platform', 'Defender platform AMProductVersion'
    if kb in ('KB2267602', 'KB2461484') or 'security intelligence' in t:
        return 'signature', 'Defender signatures AntivirusSignatureVersion'
    if kb == 'KB5007651' or 'windows security platform' in t:
        # the PLATFORM, never the SecHealthUI app: the app can be at the offered build over an uninstalled (inbox) platform - measured
        # 2026-10-03 on the rz35 subject, where this very comparison had certified a concealed failure from the app (Jev 0.83)
        return 'secplatform', 'Windows Security platform (the version folder CoreLocation names)'
    return None, None


def vtuple(v: str):
    try:
        return tuple(int(x) for x in v.split('.'))
    except Exception:
        return None


def compare(kind: str, offered: str, measured: str) -> str:
    """Deterministic version comparison - counting and matching stay in code; the judgment stays Jev's."""
    if not offered or not measured:
        return 'NOT COMPARABLE (offered or measured version missing)'
    o, m = offered, measured
    if kind == 'secplatform' and m == 'inbox':
        # no versioned platform folder at all: CoreLocation is System32 - the offered platform update is not installed, whatever the app says
        return f'NOT AT THE OFFER (the inbox platform - no platform update is installed, CoreLocation is System32): offered {offered}, installed inbox'
    ot, mt = vtuple(o), vtuple(m)
    if not ot or not mt:
        return f'NOT COMPARABLE ({offered!r} vs {measured!r})'
    rel = 'MATCH' if mt == ot else ('AHEAD (installed is newer than the offer)' if mt > ot else 'BEHIND (installed is older than the offer)')
    return f'{rel}: offered {offered}, installed {measured}'


def load_excluded():
    """The audit's OWN predicate for "excluded" - one definition, so the history marks exactly the rounds the audit judges."""
    import importlib.util
    spec = importlib.util.spec_from_file_location('wu_exclusion_audit', Path(__file__).resolve().parent / 'wu-exclusion-audit.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    if os.environ.get('WUEV_DEFECT') == 'nolabel':   # tools/tests/wu-exclusion-evidence-selftest.py: no round is ever marked excluded
        return lambda r: False
    return mod.excluded


def row_line(r: dict) -> str:
    files = r.get('files')
    f0 = files[0] if isinstance(files, list) and files else {}
    return (f"ok={r.get('ok')} state={r.get('state')} rc={f0.get('rc', r.get('rc'))} verified_by_effect="
            f"{f0.get('verified_by_effect', r.get('verified_by_effect'))} probe={f0.get('probe', r.get('probe'))} "
            f"already_current={f0.get('already_current', r.get('already_current'))} reason={r.get('reason') or f0.get('info_reason')}")


REQUIRED = ('platform', 'signature', 'secplatform', 'secplatform_wu', 'build', 'boot')
NO_ARTEFACT = '    COMPARISON: no measured artefact is known for this item'   # the line an item with no probe of its own gets, per round
# THE GUEST WRITES THESE VALUES, and the guest is untrusted (CLAUDE.md: its output is parsed as data). They reach a JUDGE's prompt, so
# only the shape each fact must have gets through - a dotted version, a build, an exact KB list, a timestamp. Anything else is dropped
# and reads as MISSING (a required fact missing refuses; an optional one shows '?'), never as text the judge would read.
SHAPES = {'platform': r'\d+(\.\d+){1,3}', 'engine': r'\d+(\.\d+){1,3}', 'signature': r'\d+(\.\d+){1,3}',
          'secplatform': r'\d+(\.\d+){1,3}|inbox', 'secplatform_wu': r'\d+(\.\d+){1,3}|absent',
          'sechealth': r'\d+(\.\d+){1,3}', 'sechealth_prov': r'\d+(\.\d+){1,3}', 'build': r'\d+\.\d+',
          'hotfixes': r'(KB\d+)(,KB\d+)*', 'boot': r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d', 'end': r'1'}


def load_facts(p: Path):
    """The 'EV|key=value' lines mgmt/harness/wu-evidence-facts.sh wrote - only the keys and shapes in SHAPES - or None when the file is
    absent or has no end marker."""
    if not p.exists():
        return None
    facts = {}
    for line in p.read_text(encoding='utf-8', errors='replace').splitlines():
        line = line.strip()
        if line.startswith('EV|') and '=' in line:
            k, v = line[3:].split('=', 1)
            k, v = k.strip(), v.strip()
            if os.environ.get('WUEV_DEFECT') == 'noshape' or (k in SHAPES and re.fullmatch(SHAPES[k], v)):   # noshape: the selftest's knob
                facts[k] = v
    return facts if facts.get('end') == '1' else None


def moved(a: str, b: str) -> str:
    return f'{a or "?"} -> {b or "?"}' + (' (moved during the pass)' if a and b and a != b else ' (unchanged by the pass)' if a and b else '')


# uid; nodes; content leaves; needed leaves; static items; other items; downloaded; base64(UTF-8 title); revision -
# mgmt/harness/wu-evidence-facts.sh. The revision is last and optional: reads before 2026-11-12 do not carry it.
OFFER_SHAPE = r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12};\d{1,4};\d{1,4};\d{1,4};\d{1,6};\d{1,6};[01];[A-Za-z0-9+/]*={0,2}(?:;\d{1,9})?'


def load_offers(p: Path):
    """What the Windows Update agent holds, as the HARNESS read it (wu-evidence-facts.sh `offers`): a list of offers, or None when the
    file is absent, carries no 'EV|offers=<count>' line, a line has the wrong shape, or the count disagrees with the lines - a partial
    list is not a list. The guest wrote these lines: only the shape gets through, and the decoded title is used for one thing, an
    equality test against the item under judgment - it is never printed."""
    if not p.exists():
        return None
    offers, count = [], None
    for line in p.read_text(encoding='utf-8', errors='replace').splitlines():
        line = line.strip()
        if line.startswith('EV|offers='):
            count = line[len('EV|offers='):]
        elif line.startswith('EV|offer='):
            v = line[len('EV|offer='):]
            if not re.fullmatch(OFFER_SHAPE, v):
                return None
            uid, n, l, k, s, o, d, b64, *rev = v.split(';')
            try:
                title = base64.b64decode(b64, validate=True).decode('utf-8')
            except Exception:
                return None
            offers.append({'uid': uid, 'nodes': int(n), 'leaves': int(l), 'needed': int(k), 'static': int(s), 'other': int(o),
                           'downloaded': d == '1', 'title': ' '.join(title.split()), 'rev': int(rev[0]) if rev else None})
    if count is None or not count.isdigit() or int(count) != len(offers):
        return None
    return offers


def load_catalog(p: Path):
    """tools/wu-catalog-facts.py's measurement for this run, or None when it is absent or not the document that tool writes."""
    try:
        d = json.loads(p.read_text(encoding='utf-8'))
    except Exception:
        return None
    return d if isinstance(d, dict) and isinstance(d.get('items'), dict) else None


def load_route(p: Path):
    """The subject qube's netvm as mgmt/harness/env-assert.sh read it from the Admin API before the rounds ('' = none), or None
    when that file has no MEASURED netvm line: 'MISSING' is a fact nobody read and 'INFO' one the reporter does not assert."""
    try:
        for line in p.read_text(encoding='utf-8', errors='replace').splitlines():
            m = re.fullmatch(r"\s*(?:ok|MISMATCH)\s+netvm\s+want='[^']*'\s+got='([^']*)'\s*", line)
            if m:
                return m.group(1)
    except Exception:
        pass
    return None


def unroutable_compare(title: str, rounds: list, catalog, route):
    """THE UPDATER SAID 'NO ROUTE' ABOUT A KB-LESS OFFER - do three measurements taken outside it say the same?

    rounds = [(round name, load_offers(that round's facts-after.txt), [(UpdateID, revision) that round's update-status.json lists
    for the title in `available`])] for every round that excluded the title. Returns
    (verdict, why, lines, gaps): verdict 'agree' when all three facts were measured and hold, 'contradicts' when a measured fact says
    the opposite (a package in the Catalog, self-contained content in the agent, a netvm on the qube - each alone is a route the
    updater did not take, which is the concealed failure this audit exists to catch), None when neither can be said, with the
    unmeasured facts named in gaps. A contradiction outranks a gap: one measured route is enough to make 'no route' false.
    SELF-CONTAINED is the updater's own definition, restated on the harness's counts (guest/qubes-windows-update.ps1
    Get-WuContentClass): every needed leaf is a static file, or nothing is needed because the agent already holds the content.

    A ROUND WHOSE OWN READ CANNOT HOLD THE OFFER (2026-11-12). The read follows the restart a pass staged (mgmt/harness/wu-e2e.sh
    takes it at the next round's start). After the restart that completed the November cumulative the agent's offline store held
    no offer at all (template-update re-run, round 2: 'EV|offers=0' on 26200.9974 - why it was empty is not measured), and a read
    inside the guest's own 60 s restart window returned nothing (rel-43099265433, round 2). Such a round takes the content of the
    identity its own status lists for the title from the harness's read in the OTHER excluding rounds of the run - only when every
    such read shows that UpdateID at the same revision (Jev: missing_measurement = revision-number 0.77) with no content (0 leaves).
    `needed` and `downloaded` are the round's state; the leaves are the identity's bundle tree, so a bundle with none cannot be
    self-contained in any download state. The evidence names the substitution. An identity with content, another revision, a read
    without a revision, or no other read leaves the gap; a self-contained reading in any round still contradicts."""
    lines, gaps, against = [], [], []
    want = ' '.join(title.split())
    c = (catalog or {}).get('control') or {}
    item = ((catalog or {}).get('items') or {}).get(title)
    when = str((catalog or {}).get('measured_utc') or '?')
    if catalog is None:
        gaps.append('no Catalog measurement (catalog-resolve.json is absent or unreadable - tools/wu-catalog-facts.py did not run on this run)')
    elif item is None:
        gaps.append('the Catalog measurement does not cover this title')
    elif item.get('outcome') == 'resolved':
        against.append(f"the Catalog holds a package for exactly this title and architecture ({item.get('why')})")
    elif c.get('outcome') != 'resolved':
        gaps.append(f"the Catalog measurement's control did not resolve ({c.get('outcome')}: {c.get('why')}) - 'no package' is unproven")
    elif item.get('outcome') != 'no-package':
        gaps.append(f"the Catalog did not answer for this title ({item.get('outcome')}: {item.get('why')})")
    else:
        lines.append(f"  1. CATALOG, asked from the host through its own proxy at {when}: {item.get('why')}. The control in the same "
                     f"measurement - a title that does have a package ({c.get('source')}) - resolved: {c.get('why')}.")
    held, read, unread, lent = [], {}, [], []
    for name, offers, *ids in rounds:
        mine = [o for o in offers or [] if o['title'] == want]
        if not mine:
            unread.append((name, offers, ids[0] if ids else []))
            continue
        for o in mine:
            counts = (f"UpdateID {o['uid']}{'' if o['rev'] is None else ' revision ' + str(o['rev'])}: {o['nodes']} node(s), "
                      f"{o['leaves']} with content, {o['needed']} needed, "
                      f"{o['static']} static file(s), {o['other']} other, downloaded={'yes' if o['downloaded'] else 'no'}")
            read.setdefault(o['uid'], []).append((name, o, counts))
            if (o['needed'] > 0 and o['other'] == 0) or (o['needed'] == 0 and o['leaves'] > 0 and o['downloaded']):
                against.append(f"{name}: the agent holds this offer with SELF-CONTAINED content ({counts})")
            else:
                held.append(f"{name}: {counts}")
    for name, offers, ids in unread:
        own = ("the harness has no read of the agent's offers after the pass (facts-after.txt carries no complete EV|offers section)"
               if offers is None else f"the harness's read of the agent lists {len(offers)} pending offer(s) and none bears this title")
        lend = [(uid, rev, read.get(uid, [])) for uid, rev in ids]
        if ids and all(rev is not None and rs and all(o['rev'] == rev and o['leaves'] == 0 for _n, o, _c in rs) for _u, rev, rs in lend):
            held.append(f"{name}: its own read could not hold the offer ({own}); its own update-status.json lists "
                        + ', '.join(f"UpdateID {uid} revision {rev}" for uid, rev, _rs in lend)
                        + " for this title, which the harness read at that revision with no content in "
                        + '; '.join(f"{n} ({c})" for _u, _v, rs in lend for n, _o, c in rs)
                        + " - a bundle that carries no content cannot be self-contained in any download state")
            lent.append(name)
        else:
            why_not = sorted({'its own update-status.json gives no revision' for _u, rev, _rs in lend if rev is None}
                             | {'no other excluding round read it' for _u, _v, rs in lend if not rs}
                             | {f"{n}'s read records no revision" for _u, _v, rs in lend for n, o, _c in rs if o['rev'] is None}
                             | {f"{n} read revision {o['rev']}, its own status says {rev}" for _u, rev, rs in lend for n, o, _c in rs
                                if o['rev'] is not None and o['rev'] != rev}
                             | {f"{n} read it with content" for _u, _v, rs in lend for n, o, _c in rs if o['leaves']})
            gaps.append(f"{name}: {own}" + (f"; the UpdateID its own status lists cannot be taken from another excluding round's read "
                                            f"({', '.join(why_not)})" if why_not else ''))
    if held:
        lines.append("  2. CONTENT, as the Windows Update agent itself holds the offer after each excluding pass (read by the harness, "
                     "offline): not self-contained - " + '; '.join(held) + '.')
    if route is None:
        gaps.append("the subject's netvm was not recorded (no measured netvm line in preflight/env-assert.out beside this run)")
    elif route != '':
        against.append(f"the subject qube had a netvm ({route if re.fullmatch(r'[A-Za-z0-9_.-]{1,31}', route) else 'unprintable name'}) - "
                       "a guest with a route of its own is never 'no route'")
    else:
        lines.append("  3. ROUTE: the subject qube has no netvm (read from the Admin API by mgmt/harness/env-assert.sh before the rounds).")
    if against:
        return 'contradicts', '; '.join(against), lines, gaps
    if gaps:
        return None, '', lines, gaps
    return 'agree', (f"all three facts of the no-route rule hold independently: no Catalog package for this title "
                     f"(control resolved), content not self-contained in {len(held)} excluding round(s)"
                     + (f" ({', '.join(lent)}: the same content-free UpdateID and revision as read in another excluding round)" if lent else '')
                     + ", no netvm"), lines, gaps


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    run, out = Path(sys.argv[1]), Path(sys.argv[2])
    excl = run / 'excluded-items.tsv'
    if not excl.exists():
        print(f'MISSING: {excl}', file=sys.stderr)
        return 2
    excluded = load_excluded()
    rounds = sorted([d for d in run.glob('round*') if d.is_dir()], key=lambda d: int(d.name[5:] or 0))
    statuses = [(rd, load_status(rd / 'update-status.json')) for rd in rounds]
    catalog = load_catalog(run / 'catalog-resolve.json')
    route = load_route(run.parent / 'preflight' / 'env-assert.out')
    ev, missing = {}, []
    for line in excl.read_text(encoding='utf-8').splitlines():
        if not line.strip():
            continue
        kb = line.split('\t')[0]
        hist, meas, kind, label, unr = [], [], None, None, []
        for rd, st in statuses:
            name = rd.name
            if not st:
                hist.append(f'  {name}: update-status.json unreadable')
                continue
            # an offer without a KB is keyed by its title everywhere (its `available` entry says kb='(no KB)'), so match it there too
            title = next((a.get('title') for a in (st.get('available') or [])
                          if (a.get('kb') == kb or a.get('title') == kb) and a.get('title')), None)
            rows = [r for r in (st.get('result') or []) if r.get('kb') == kb]
            if not title and not rows:
                continue
            mo = re.search(r'(\d+\.\d+\.\d+\.\d+)', title or '')
            offered = mo.group(1) if mo else ''
            if not kind:
                kind, label = artefact_for(kb, title)
            ex_round = False
            for r in rows or [None]:
                if r is None:
                    hist.append(f"  {name}: offered {title!r}; no result row")
                    continue
                ex = excluded(r)
                ex_round = ex_round or ex
                hist.append(f"  {name}: offered {offered or 'no version in the title'} -> {row_line(r)}"
                            + ('  [EXCLUDED - a round the audit judges]' if ex else '  [counted - not excluded]'))
            if not ex_round:
                continue
            # the identity this round's own status lists for the item - what a round whose own read cannot hold the offer is matched
            # by (unroutable_compare); a uid or revision of the wrong type is kept as None, so it can match nothing
            ids = [(a.get('uid') if isinstance(a.get('uid'), str) else None, a.get('rev') if type(a.get('rev')) is int else None)
                   for a in (st.get('available') or []) if a.get('kb') == kb or a.get('title') == kb]
            unr.append((name, kb in (st.get('unroutable') or []), load_offers(rd / 'facts-after.txt'), ids))
            fb, fa = load_facts(rd / 'facts-before.txt'), load_facts(rd / 'facts-after.txt')
            gaps = [f'{which} ({"absent or incomplete" if f is None else "no " + ", ".join(k for k in REQUIRED if not f.get(k))})'
                    for which, f in (('facts-before', fb), ('facts-after', fa)) if f is None or any(not f.get(k) for k in REQUIRED)]
            if gaps:
                missing.append(f'{kb} {name}: ' + '; '.join(gaps))
                continue
            meas.append(f"  {name} (EXCLUDED), measured by the harness before the pass (boot {fb['boot']}) and after it (boot {fa['boot']}):")
            meas.append(f"    Defender platform {moved(fb['platform'], fa['platform'])}; signatures {moved(fb['signature'], fa['signature'])}; "
                        f"engine {moved(fb.get('engine', ''), fa.get('engine', ''))}; Windows Security PLATFORM {moved(fb['secplatform'], fa['secplatform'])}, "
                        f"its Updates\\wu record {moved(fb['secplatform_wu'], fa['secplatform_wu'])}; Windows Security app (information only, not the "
                        f"platform) installed {moved(fb.get('sechealth', ''), fa.get('sechealth', ''))}, provisioned "
                        f"{moved(fb.get('sechealth_prov', ''), fa.get('sechealth_prov', ''))}; OS build {moved(fb['build'], fa['build'])}")
            if kind:
                meas.append(f"    COMPARISON, computed in code ({label} after the pass vs the version this round's offer carried): "
                            f"{compare(kind, offered, fa.get(kind, ''))}; during the pass: {moved(fb.get(kind, ''), fa.get(kind, ''))}")
            else:
                def lists(f):   # exact membership: 'KB5099999' is a substring of 'KB50999990' (WUEV_DEFECT=substr restores the substring test)
                    if os.environ.get('WUEV_DEFECT') == 'substr':
                        return kb.upper() in (f.get('hotfixes') or '').upper()
                    return kb.upper() in {h.strip().upper() for h in (f.get('hotfixes') or '').split(',') if h.strip()}
                meas.append(f"{NO_ARTEFACT}; Get-HotFix lists it before the pass: "
                            f"{'yes' if lists(fb) else 'no'}, after: {'yes' if lists(fa) else 'no'}")
        part = ['INDEPENDENT FACTS, measured on the guest by the harness (mgmt/harness/wu-evidence-facts.sh) before and after each pass '
                'that excluded the item - not by the updater:']
        # THE NO-ROUTE CLASS: no KB, no artefact of its own, and listed in `unroutable` by every round that excluded it.
        measured = None
        if kind is None and not re.fullmatch(r'KB\d+', kb) and unr and all(u for _n, u, _o, _i in unr):
            verdict, why, lines, gaps = unroutable_compare(kb, [(n, o, i) for n, _u, o, i in unr], catalog, route)
            meas = [m for m in meas if not m.startswith(NO_ARTEFACT)]   # a title is not a KB: Get-HotFix has nothing to say here
            meas.append("  THE UPDATER'S CLAIM IS 'NO ROUTE': it lists this offer in `unroutable` in every round that excluded it "
                        "(docs/ADR-updater.md section 2 point 5 names the three facts that rests on). EACH FACT, MEASURED OUTSIDE THE UPDATER:")
            meas += lines
            if verdict is None:
                missing += [f'{kb}: {g}' for g in gaps]
            else:
                measured = {'class': 'unroutable-kbless', 'verdict': verdict, 'why': why}
                meas.append(f"  COMPARISON, computed in code: {'AGREES' if verdict == 'agree' else 'CONTRADICTS THE CLAIM'} - {why}")
        part += meas or ['  none']
        part.append("THE ITEM'S HISTORY in the updater's own rows (the claim under test; every round that offered it):")
        part += hist or ['  none found']
        ev[kb] = {'text': '\n'.join(part), 'measured': measured} if measured else '\n'.join(part)
    if missing:
        print('MISSING measurements for an excluded item - the audit cannot be given independent evidence:', file=sys.stderr)
        for m in missing:
            print('  ' + m, file=sys.stderr)
        return 2
    if not ev:
        print('NO excluded items to give evidence for', file=sys.stderr)
        return 2
    out.write_text(json.dumps(ev, indent=1), encoding='utf-8')
    print(f'evidence for {len(ev)} excluded item(s) -> {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
