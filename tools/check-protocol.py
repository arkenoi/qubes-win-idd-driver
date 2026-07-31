#!/usr/bin/env python3
"""Validate the agent's protocol trace against Windows ground truth.

Reads QGAPROTO lines from the agent log plus a guest-side snapshot of the real window state,
and checks invariants that must hold for dom0 to render correctly. Every acceptance failure in
this project so far came from checking guest state or agent intent and INFERRING what went on
the wire. This checks the wire.

Usage: check-protocol.py <agent-log> <guest-windows.json>

Exits non-zero if any invariant fails. A defect the user can see must make this fail; if it
does not, the checker is wrong, not the build.
"""
import json, re, sys

WS_CAPTION = 0x00C00000
WS_POPUP   = 0x80000000
WS_SYSMENU = 0x00080000
EX_APPWINDOW = 0x00040000
EX_TOOLWINDOW = 0x00000080

MENU_CLASS = '#32768'


def parse(path):
    out = []
    pat = re.compile(r'QGAPROTO,msg=(\w+),(.*)$')
    for line in open(path, errors='replace'):
        m = pat.search(line)
        if not m:
            continue
        rec = {'msg': m.group(1)}
        for kv in m.group(2).split(','):
            if '=' not in kv:
                continue
            k, v = kv.split('=', 1)
            v = v.strip()
            try:
                rec[k] = int(v, 16) if v.startswith('0x') else int(v)
            except ValueError:
                rec[k] = v
        out.append(rec)
    return out


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    recs = parse(sys.argv[1])
    guest = {int(w['hwnd']): w for w in json.load(open(sys.argv[2]))}

    failures = []

    def fail(inv, detail):
        failures.append((inv, detail))

    if not recs:
        fail('trace-present', 'no QGAPROTO records: tracing was off, so nothing was verified')

    # --- INVARIANT 1: a popup-class window must be announced override_redirect.
    # If it is not, dom0 manages and DECORATES it - the red rectangle over menus.
    for r in recs:
        if r['msg'] not in ('MAP', 'CREATE'):
            continue
        style, ex = r.get('style', 0), r.get('ex', 0)
        if style == 0:
            continue
        is_popup_class = (style & WS_POPUP) and not (style & WS_CAPTION) == WS_CAPTION
        has_caption = (style & WS_CAPTION) == WS_CAPTION
        metro = (style & WS_SYSMENU) and (ex & EX_APPWINDOW)
        should_be_ovr = (not has_caption) and (not metro)
        if should_be_ovr and not r.get('ovr'):
            fail('popup-override-redirect',
                 f"{r['msg']} hwnd=0x{r['hwnd']:x} style=0x{style:08x} ex=0x{ex:08x} "
                 f"has no caption so dom0 will decorate it (ovr=0) - this draws a border "
                 f"around menus/tooltips")

    # --- INVARIANT 2: damage must be inside the window last announced for that hwnd.
    # Damage outside means dom0 copies from the wrong place: content shifted in the frame.
    geom = {}
    for r in recs:
        if r['msg'] in ('CREATE', 'CONFIGURE'):
            geom[r['hwnd']] = (r.get('w', 0), r.get('h', 0))
        elif r['msg'] == 'DAMAGE':
            wh = geom.get(r['hwnd'])
            if not wh:
                continue
            w, h = wh
            if w and h:
                if (r['rx'] < 0 or r['ry'] < 0 or
                        r['rx'] + r['w'] > w or r['ry'] + r['h'] > h):
                    fail('damage-within-window',
                         f"hwnd=0x{r['hwnd']:x} damage ({r['rx']},{r['ry']} {r['w']}x{r['h']}) "
                         f"is outside the announced {w}x{h}")

    # --- INVARIANT 2b: damage must not be sent to a window that is OCCLUDED there.
    # The framebuffer holds the COMPOSITED desktop, so a dirty rect in screen coordinates
    # intersects every window it overlaps - including ones underneath. Sending it to the lower
    # window makes dom0 paint the upper window's pixels into the lower window's pixmap, which
    # is what corrupts a menu's host window on hover and what leaves debris when one window is
    # dragged over another. Detect it as: the same damage rect, same size, delivered to two
    # different windows in the same instant at screen positions that coincide.
    # Origins come from the trace where available, and otherwise from Windows itself. A
    # window whose CREATE predates the capture window would otherwise be silently skipped -
    # and skipping on missing data is how a checker reports PASS on a broken build.
    # ONLY the announced origin is valid here. Substituting Windows' GetWindowRect looks
    # helpful and is actively harmful: the agent announces DWM extended frame bounds, a
    # different origin, so the substitution shifts every rect by a few px and the coincidence
    # this invariant looks for silently stops matching. Missing data must fail, not be guessed.
    screen = {}
    for r in recs:
        if r['msg'] in ('CREATE', 'CONFIGURE') and 'x' in r:
            screen[r['hwnd']] = (r['x'], r['y'])
    damaged = {r['hwnd'] for r in recs if r['msg'] == 'DAMAGE'}
    unknown = damaged - set(screen)
    if unknown:
        fail('origin-known-for-damaged-windows',
             'no origin for hwnd(s) ' + ', '.join(f'0x{h:x}' for h in sorted(unknown)) +
             ' - occlusion cannot be checked for them, so this run proves nothing about them')
    bleed = []
    for i, r in enumerate(recs):
        if r['msg'] != 'DAMAGE':
            continue
        o = screen.get(r['hwnd'])
        if not o:
            continue
        abs_r = (o[0] + r['rx'], o[1] + r['ry'], r['w'], r['h'])
        for r2 in recs[i + 1:i + 3]:
            if r2['msg'] != 'DAMAGE' or r2['hwnd'] == r['hwnd']:
                continue
            o2 = screen.get(r2['hwnd'])
            if not o2:
                continue
            abs_2 = (o2[0] + r2['rx'], o2[1] + r2['ry'], r2['w'], r2['h'])
            if abs_r == abs_2:
                bleed.append((r['hwnd'], r2['hwnd'], abs_r))
    if bleed:
        h1, h2, rect = bleed[0]
        fail('no-damage-to-occluded-window',
             f"the same screen region {rect[2]}x{rect[3]} at ({rect[0]},{rect[1]}) was sent as "
             f"damage to BOTH hwnd=0x{h1:x} and hwnd=0x{h2:x} ({len(bleed)} times): the "
             f"composited framebuffer means the lower window receives the upper window's "
             f"pixels, corrupting it")

    # --- INVARIANT 3: the geometry announced must match what Windows actually has.
    last_cfg = {}
    for r in recs:
        if r['msg'] in ('CREATE', 'CONFIGURE') and 'x' in r:
            last_cfg[r['hwnd']] = r
    for hwnd, r in last_cfg.items():
        g = guest.get(hwnd)
        if not g:
            continue
        if (r['w'], r['h']) != (g['w'], g['h']):
            fail('geometry-matches-guest',
                 f"hwnd=0x{hwnd:x} announced {r['w']}x{r['h']} but Windows has {g['w']}x{g['h']}")

    # --- INVARIANT 4: every menu window Windows showed must have been announced at all.
    announced = {r['hwnd'] for r in recs if r['msg'] == 'MAP'}
    for hwnd, g in guest.items():
        if g.get('cls') == MENU_CLASS and hwnd not in announced:
            fail('menu-announced', f"menu hwnd=0x{hwnd:x} was visible in the guest but never mapped")

    print(f"records={len(recs)} guest_windows={len(guest)}")
    by = {}
    for r in recs:
        by[r['msg']] = by.get(r['msg'], 0) + 1
    print('  ' + ' '.join(f'{k}={v}' for k, v in sorted(by.items())))
    if failures:
        print(f"\nFAILED {len(failures)} invariant check(s):")
        seen = set()
        for inv, detail in failures:
            key = (inv, detail)
            if key in seen:
                continue
            seen.add(key)
            print(f"  [{inv}] {detail}")
        return 1
    print("\nall invariants hold")
    return 0


if __name__ == '__main__':
    sys.exit(main())
