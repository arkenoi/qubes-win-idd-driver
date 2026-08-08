#!/usr/bin/env python3
"""Bounding box of what changes on an IDLE desktop, from consecutive fullshot PNGs.

    idle-repaint-diff.py <dir with x1/ x2/ ... and windows.txt>

Answers the one thing the idle measurement could not: Windows 11 presents 18.75 fps with no
input, carrying ~350k real dirty pixels - but WHICH surface produces them. A taskbar strip, a
widget flyout and a window client area have completely different bounding boxes, so the box
identifies the culprit without guessing registry keys one reinstall at a time.

The guest is untrusted. PNGs are decoded with the standard library only, pixel data is treated
as data, and nothing from windows.txt is executed or used as a path.

No third-party imaging dependency: PNG decoding is done here so this runs wherever python3
does, and a missing Pillow cannot silently turn into "no result".
"""
import binascii
import glob
import os
import struct
import sys
import zlib


def read_png(path):
    """Minimal PNG reader -> (width, height, rows of RGB bytes). Handles 8-bit RGB/RGBA,
    non-interlaced, which is what the screenshot service produces."""
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, w, h, depth, color = 8, [], None, None, None, None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            w, h, depth, color = struct.unpack(">IIBB", body[:10])
        elif ctype == b"IDAT":
            idat.append(body)
        elif ctype == b"IEND":
            break
        pos += 12 + length
    if depth != 8 or color not in (2, 6):
        raise ValueError(f"unsupported PNG (depth={depth} color={color})")
    channels = 3 if color == 2 else 4
    raw = zlib.decompress(b"".join(idat))
    stride = w * channels
    out, prev = [], bytearray(stride)
    i = 0
    for _ in range(h):
        ft = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        if ft == 1:
            for x in range(channels, stride):
                line[x] = (line[x] + line[x - channels]) & 0xFF
        elif ft == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif ft == 3:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xFF
        elif ft == 4:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                c = prev[x - channels] if x >= channels else 0
                b = prev[x]
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xFF
        out.append(bytes(line))
        prev = line
    return w, h, channels, out


def diff_box(a, b):
    """Bounding box of differing pixels plus a changed-pixel count."""
    (aw, ah, ac, arows), (bw, bh, bc, brows) = a, b
    if (aw, ah) != (bw, bh):
        return None
    minx, miny, maxx, maxy, count = aw, ah, -1, -1, 0
    for y in range(ah):
        ra, rb = arows[y], brows[y]
        if ra == rb:
            continue
        for x in range(aw):
            oa, ob = x * ac, x * bc
            if ra[oa:oa + 3] != rb[ob:ob + 3]:
                count += 1
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    if maxx < 0:
        return (0, None)
    return (count, (minx, miny, maxx + 1, maxy + 1))


root = sys.argv[1] if len(sys.argv) > 1 else "."
frames = []
for d in sorted(glob.glob(os.path.join(root, "x*")), key=lambda p: int(os.path.basename(p)[1:] or 0)):
    pngs = sorted(glob.glob(os.path.join(d, "**", "*.png"), recursive=True))
    if pngs:
        frames.append((os.path.basename(d), pngs[0]))

print("=" * 76)
print("IDLE REPAINT LOCATION - bounding box of what changes with no input")
print("=" * 76)
if len(frames) < 2:
    print(f"need at least 2 captured frames, found {len(frames)}. Missing data fails.")
    sys.exit(1)

decoded = []
for name, p in frames:
    try:
        decoded.append((name, read_png(p)))
    except Exception as e:
        print(f"  {name}: could not decode ({e})")
if len(decoded) < 2:
    print("fewer than 2 decodable frames - no verdict.")
    sys.exit(1)

w, h = decoded[0][1][0], decoded[0][1][1]
print(f"  desktop {w}x{h}, {len(decoded)} frames\n")
print(f"{'pair':<14}{'changed px':>12}{'box (l,t,r,b)':>28}{'box size':>14}")
print("-" * 76)
boxes = []
for i in range(len(decoded) - 1):
    r = diff_box(decoded[i][1], decoded[i + 1][1])
    if r is None:
        print(f"{decoded[i][0]}->{decoded[i+1][0]:<6}{'size mismatch':>12}")
        continue
    count, box = r
    if not box:
        print(f"{decoded[i][0]}->{decoded[i+1][0]:<6}{0:>12}{'(identical)':>28}")
        continue
    boxes.append(box)
    bw, bh = box[2] - box[0], box[3] - box[1]
    print(f"{decoded[i][0]}->{decoded[i+1][0]:<6}{count:>12}"
          f"{f'{box[0]},{box[1]},{box[2]},{box[3]}':>28}{f'{bw}x{bh}':>14}")

if not boxes:
    print("\n  Nothing changed between any pair. Either the guest really is quiet at the")
    print("  screenshot cadence, or the sampling interval missed the repaint - both are")
    print("  results, and neither is 'no data'.")
    sys.exit(0)

# union of all changed boxes
ul = min(b[0] for b in boxes); ut = min(b[1] for b in boxes)
ur = max(b[2] for b in boxes); ub = max(b[3] for b in boxes)
print(f"\n  union of changed regions: ({ul},{ut})-({ur},{ub})  {ur-ul}x{ub-ut}")

# attribute to a window if one matches
wins = []
wf = os.path.join(root, "windows.txt")
if os.path.isfile(wf):
    for line in open(wf, encoding="utf-8", errors="replace"):
        f = line.split()
        if len(f) >= 4 and f[0] == "WIN":
            try:
                l, t, r, b = (int(v) for v in f[3].split(","))
                wins.append((f[1], l, t, r, b))
            except Exception:
                continue

print("\n-- attribution --")
if not wins:
    print("   no window list captured - the box cannot be attributed to a process")
else:
    hits = [(n, l, t, r, b) for (n, l, t, r, b) in wins
            if not (r <= ul or l >= ur or b <= ut or t >= ub)]
    if hits:
        for n, l, t, r, b in hits:
            print(f"   overlaps {n:<22} ({l},{t})-({r},{b})")
    else:
        print("   the changed region overlaps NO tracked top-level window.")
        print("   That points at shell surface (taskbar/widgets/search) rather than an app.")

if ub - ut < 120 and ut > h * 0.8:
    print("\n   Shape/position say TASKBAR STRIP - clock, widgets or tray animation.")
elif (ur - ul) * (ub - ut) > w * h * 0.5:
    print("\n   The region is most of the desktop: a full-surface recomposite, not a widget.")
