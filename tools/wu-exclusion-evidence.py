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
Exit 0 written, 2 missing input - an excluded round without complete facts, or nothing to write (missing data fails)."""
import json, os, re, sys
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
    ev, missing = {}, []
    for line in excl.read_text(encoding='utf-8').splitlines():
        if not line.strip():
            continue
        kb = line.split('\t')[0]
        hist, meas, kind, label = [], [], None, None
        for rd, st in statuses:
            name = rd.name
            if not st:
                hist.append(f'  {name}: update-status.json unreadable')
                continue
            title = next((a.get('title') for a in (st.get('available') or []) if a.get('kb') == kb and a.get('title')), None)
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
                meas.append(f"    COMPARISON: no measured artefact is known for this item; Get-HotFix lists it before the pass: "
                            f"{'yes' if lists(fb) else 'no'}, after: {'yes' if lists(fa) else 'no'}")
        part = ['INDEPENDENT FACTS, measured on the guest by the harness (mgmt/harness/wu-evidence-facts.sh) before and after each pass '
                'that excluded the item - not by the updater:']
        part += meas or ['  none']
        part.append("THE ITEM'S HISTORY in the updater's own rows (the claim under test; every round that offered it):")
        part += hist or ['  none found']
        ev[kb] = '\n'.join(part)
    if missing:
        print('MISSING guest facts for an excluded round - the audit cannot be given independent evidence:', file=sys.stderr)
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
