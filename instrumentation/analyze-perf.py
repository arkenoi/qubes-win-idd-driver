#!/usr/bin/env python3
"""
Turn gui-agent QGAPERF log records into the Phase 1A decision table.

Input: one or more gui-agent log files (UTF-8, as written by qubes-windows-utils'
logger) and optionally the harness marker JSON produced by drag-harness.ps1.

  ./analyze-perf.py gui-agent-*.log
  ./analyze-perf.py gui-agent-*.log --markers qgaperf-harness-*.json
  ./analyze-perf.py gui-agent-*.log --since 20260730.221000.000 --until 20260730.221010.000
  ./analyze-perf.py gui-agent-*.log --csv frames.csv     # dump the parsed frames

The guest is untrusted: this parses its output as data only. Nothing is executed,
no field is used as a path, and malformed records are counted and skipped.
"""
import argparse
import json
import re
import sys
from collections import OrderedDict

REC = re.compile(
    r'^\[(?P<ts>\d{8}\.\d{6}\.\d{3})-(?P<tid>\d+)-(?P<lvl>.)\]\s*'
    r'(?:[A-Za-z_][A-Za-z0-9_]*:\s*)?QGAPERF,(?P<body>v=\d+,.+)$'
)
MOVERECT = re.compile(r'QGAPERF-MOVERECTS:\s*(?P<msg>.+)$')
BANNER = re.compile(r'QGAPERF(?:-HEADER)? (?:on|off|v=|fields)')

# time fields are microseconds summed over `n` frames
TIME_FIELDS = ['dt', 'acq', 'wak', 'mrq', 'drq', 'upd', 'enu', 'rem', 'dmg', 'snd', 'tot', 'log']
# iwn = windows actually interrogated (the Phase 2A headline: was ~67/frame, should
# approach 0). wev = window events drained. Both are per-record counts.
COUNT_FIELDS = ['dr', 'mr', 'area', 'sends', 'skip', 'pwskip', 'pwcap', 'pwnofb', 'pwnoz', 'pwoff', 'pwocc', 'pwnofg', 'pwovl', 'pwfirst', 'pwchg', 'frdrop', 'ddacap', 'ddmov', 'ddgeo', 'ddoff', 'ddlay', 'ddfg', 'ddovl', 'iwn', 'wev']
LAST_FIELDS = ['win', 'mrmax']

PHASE_GROUPS = OrderedDict([
    ('tracking  (upd+enu+rem)', ['upd', 'enu', 'rem']),
    ('damage    (drq+dmg)', ['drq', 'dmg']),
    ('send      (snd)', ['snd']),
    ('moverects (mrq)', ['mrq']),
])


def parse(paths):
    frames, notes, bad = [], [], 0
    for p in paths:
        with open(p, 'r', encoding='utf-8', errors='replace') as fh:
            for line in fh:
                line = line.rstrip('\r\n')
                m = MOVERECT.search(line)
                if m:
                    notes.append(('moverects', line.strip()))
                    continue
                if BANNER.search(line):
                    notes.append(('banner', line.strip()))
                    continue
                m = REC.match(line)
                if not m:
                    continue
                rec = {'ts': m.group('ts')}
                ok = True
                for kv in m.group('body').split(','):
                    if '=' not in kv:
                        ok = False
                        break
                    k, v = kv.split('=', 1)
                    if k == 'mode':
                        rec[k] = v
                    else:
                        try:
                            rec[k] = int(v)
                        except ValueError:
                            ok = False
                            break
                if not ok or 'n' not in rec or rec.get('n', 0) < 1:
                    bad += 1
                    continue
                frames.append(rec)
    return frames, notes, bad


def pct(sorted_vals, q):
    if not sorted_vals:
        return 0.0
    i = min(len(sorted_vals) - 1, max(0, int(round(q * (len(sorted_vals) - 1)))))
    return sorted_vals[i]


def summarize(name, recs):
    if not recs:
        print('\n== %s ==  (no frames)' % name)
        return
    n = sum(r['n'] for r in recs)
    span_us = sum(r.get('dt', 0) for r in recs)
    fps = (n * 1e6 / span_us) if span_us > 0 else float('nan')

    print('\n== %s ==' % name)
    print('   records=%d frames=%d  window=%s..%s  span=%.2fs  achieved=%.1f fps'
          % (len(recs), n, recs[0]['ts'], recs[-1]['ts'], span_us / 1e6, fps))
    print('   %-6s %10s %10s %10s %10s %10s   %s'
          % ('field', 'mean_us', 'p50_us', 'p95_us', 'p99_us', 'max_us', 'share_of_tot'))

    # tot = ProcessNewFrame span (main thread). drq/mrq are measured in GetFrame on the
    # CAPTURE thread and are NOT inside tot, so shares must be against WALL = tot+drq+mrq,
    # not tot - otherwise a damage-dominant run reports >100% and negative "unaccounted",
    # breaking exactly the branch this analyzer exists to detect.
    tot_sum = sum(r.get('tot', 0) for r in recs)
    wall_sum = tot_sum + sum(r.get('drq', 0) + r.get('mrq', 0) for r in recs)
    rows = {}
    for f in TIME_FIELDS:
        per = sorted(r.get(f, 0) / float(r['n']) for r in recs)
        s = sum(r.get(f, 0) for r in recs)
        rows[f] = s
        share = ('%6.1f%%' % (100.0 * s / wall_sum)) if wall_sum and f not in ('dt', 'acq', 'wak', 'tot', 'log') else '     -'
        print('   %-6s %10.1f %10.1f %10.1f %10.1f %10.1f   %s'
              % (f, s / float(n), pct(per, .50), pct(per, .95), pct(per, .99), per[-1], share))

    dr = sum(r.get('dr', 0) for r in recs)
    mr = sum(r.get('mr', 0) for r in recs)
    area = sum(r.get('area', 0) for r in recs)
    sends = sum(r.get('sends', 0) for r in recs)
    skip = sum(r.get('skip', 0) for r in recs)
    iwn = sum(r.get('iwn', 0) for r in recs)
    wev = sum(r.get('wev', 0) for r in recs)
    print('   INTERROGATED/frame=%.2f  events/frame=%.2f   <- Phase 2A headline (was ~67/frame)'
          % (iwn / float(n), wev / float(n)))
    print('   counts/frame: dirty_rects=%.2f move_rects=%.3f (max seen %d) dirty_px=%.0f '
          'sends=%.2f  windows=%d  dropped(no-damage)_frames=%d'
          % (dr / float(n), mr / float(n), max(r.get('mrmax', 0) for r in recs),
             area / float(n), sends / float(n), recs[-1].get('win', 0), skip))

    print('   --- where the frame goes (%% of wall = tot+drq+mrq) ---')
    for label, fields in PHASE_GROUPS.items():
        s = sum(rows.get(f, 0) for f in fields)
        print('   %-24s %9.1f us/frame  %6.1f%% of wall'
              % (label, s / float(n), 100.0 * s / wall_sum if wall_sum else 0))
    # "unaccounted" is main-thread only: tot minus the fields that live inside tot
    # (upd,enu,rem,dmg,snd). drq/mrq are capture-thread and already shown above.
    in_tot = sum(rows.get(f, 0) for f in ('upd', 'enu', 'rem', 'dmg', 'snd'))
    print('   %-24s %9.1f us/frame  %6.1f%% of wall'
          % ('unaccounted (main)', (tot_sum - in_tot) / float(n),
             100.0 * (tot_sum - in_tot) / wall_sum if wall_sum else 0))
    print('   %-24s %9.1f us/frame' % ('wakeup latency (wak)', rows.get('wak', 0) / float(n)))
    print('   %-24s %9.1f us/frame  <- instrumentation self-cost'
          % ('log emit (log)', rows.get('log', 0) / float(n)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('logs', nargs='+')
    ap.add_argument('--markers', help='harness JSON from drag-harness.ps1')
    ap.add_argument('--since')
    ap.add_argument('--until')
    ap.add_argument('--csv', help='write parsed frames to this CSV')
    a = ap.parse_args()

    frames, notes, bad = parse(a.logs)
    if not frames:
        print('no QGAPERF records found (is PerfLog enabled and LogLevel >= 3?)', file=sys.stderr)
        return 1
    frames.sort(key=lambda r: r['ts'])

    for kind, text in notes:
        print('[%s] %s' % (kind, text))
    if bad:
        print('[warn] %d malformed QGAPERF records skipped' % bad)

    mr_max = max(r.get('mrmax', 0) for r in frames)
    print('\nMOVE-RECTS VERDICT: max GetFrameMoveRects count seen = %d  -> %s'
          % (mr_max, 'NON-EMPTY, move rects are usable' if mr_max > 0
             else 'always empty, the capture.c TODO is a dead end'))

    if a.since:
        frames = [r for r in frames if r['ts'] >= a.since]
    if a.until:
        frames = [r for r in frames if r['ts'] <= a.until]

    if a.csv:
        keys = ['ts', 'seq', 'n', 'mode'] + TIME_FIELDS + COUNT_FIELDS + LAST_FIELDS
        with open(a.csv, 'w', encoding='utf-8') as fh:
            fh.write(','.join(keys) + '\n')
            for r in frames:
                fh.write(','.join(str(r.get(k, '')) for k in keys) + '\n')
        print('[csv] wrote %d rows to %s' % (len(frames), a.csv))

    if a.markers:
        with open(a.markers, 'r', encoding='utf-8-sig') as fh:
            marks = json.load(fh)
        phases = marks.get('phases') or []
        if isinstance(phases, dict):
            phases = [phases]
        for ph in phases:
            sel = [r for r in frames if ph['start'] <= r['ts'] <= ph['end']]
            summarize('phase %s (%s..%s)' % (ph['name'], ph['start'], ph['end']), sel)
        for k, v in (marks.get('cadence') or {}).items():
            print('[cadence] %-10s %s' % (k, v))
    else:
        summarize('all frames', frames)
    return 0


if __name__ == '__main__':
    sys.exit(main())
