#!/usr/bin/env python3
"""errfam.py - group a guest log capture's ERROR lines into FAMILIES and count them per capture.

WHY THIS IS CODE AND NOT A JEV CALL. Counting and exact matching are deterministic, so they stay
here; the semantic question ("is this family fixed?") is the register's and Jev's. The families are
the ones findings/issues.md records under ERRORINV, keyed by a signature regex, so a capture from a
build carrying the fixes can be compared with the two captures that defined the baseline
(win11-acc 35 error lines, win10-acc 11, both 2026-10-09).

    tools/errfam.py <logs-dir> [<baseline-logs-dir> ...]
    tools/errfam.py --report <report.json>          # the LAST BOOT only, by family

THE PER-BOOT FORM IS THE ONE THAT ANSWERS "DID THIS BOOT WRITE AN ERROR LINE". A guest writes a
PER-DAY log per module, so counting a whole capture mixes every boot of the day with every
deliberately induced failure - measured 2026-10-09, where a clean-boot capture counted 30 induced
lines from three earlier cells. Archiving the logs first does NOT fix it: windows-utils opens its
log with FILE_SHARE_READ only, so a live service's per-day log cannot be moved or renamed at all.
What does fix it is already in log-sweep: it clusters boots from each instance's "System uptime"
(no clock involved - the guest's flips ~3 h into every boot) and gives every signature a per_boot
count. This mode reads those, takes the LAST boot, and labels each ERROR signature by family.

Every argument is a directory holding pulled guest logs (log-sweep's <outdir>/logs). It recurses,
reads every file, and matches the ERROR-level lines - the prefix is [date.time.ms-PID:TID-E] on
builds from ~4.3.33 and [date.time.ms-TID-E] before that, so both are accepted.

MISSING DATA FAILS: a directory with no files, or no readable line, exits 2 rather than printing a
reassuring zero. A line that matches no family is reported as UNCLASSIFIED with its text, because a
new signature is exactly what this is for.
"""
import os
import re
import sys
import collections

ERR = re.compile(r'-\d+(?::\d+)?-E\]')

# (family key, regex, what it is). Order matters: the first match wins. A pattern that depends on
# a NUMBER must accept both forms: raw log lines carry the value, while log-sweep's signatures are
# normalised (digits -> N, hex -> 0xH), and --report mode matches against those.
FAMILIES = [
    # THE COLLAPSED LINE MUST MATCH FIRST. It CARRIES the library records inside it, so with
    # ("vchan-store-read", ...) ahead of it every QGAVCHANFAIL line was counted as one of the
    # families it replaces - measured 2026-10-09, where it reported 28 vchan-client-init lines on a
    # build whose whole point is that it writes one line instead of those.
    ("vchan-collapsed",    r'QGAVCHANFAIL',                              "THE ONE LINE that replaces the five below"),
    ("vchan-store-read",   r'IOCTL_XENIFACE_STORE_READ failed',          "xenstore read during a vchan connect"),
    ("vchan-ring-ref",     r"failed to read '.*ring-ref' from store",    "the vchan's ring-ref could not be read"),
    ("vchan-client-init",  r'libxenvchan_client_init\(.*\) failed',      "libvchan's own verdict on the connect"),
    ("vchan-evtchn-bind",  r'EVTCHN_BIND_INTERDOMAIN failed',            "event-channel bind during a connect"),
    ("vchan-evt-cli",      r'failed to bind event channel',              "libxenvchan's event-channel bind"),
    ("qdb-pipe-write",     r'WriteFile failed with error 0xe8',          "a write to the qubesdb pipe while it closes"),
    ("qdb-daemon-write",   r'write to daemon failed with error 0xe8',    "the qubesdb client's report of the same"),
    ("autostart-optional", r'CfgReadMultiString\(Autostart\)',           "an absent OPTIONAL registry value"),
    ("watchforevents-0x0", r'WatchForEvents failed with error (0x0|0xH)', "a requested stop reported as a failure"),
    ("winevt-thread-exit", r'window event thread exiting',               "the window event thread leaving"),
    ("dda-access-lost",    r'AcquireNextFrame\(\) failed',               "DDA ACCESS_LOST, mis-rendered as a keyed mutex"),
    ("dda-release-frame",  r'ReleaseFrame failed',                       "the same on the release side"),
    ("monitor-handle",     r'GetMonitorInfo failed',                     "a stale monitor handle (display-change race)"),
    ("monitor-rect-caller",r'GetRealWindowRect failed',                  "the caller re-reporting the same condition"),
    ("hold-overflow",      r'past the (\d+|N) held were dropped',        "the library-record hold overflowing"),
    ("vchan-send-closed",  r'vchan already closed with (\d+|N) byte',     "a send into a vchan the peer already closed"),
    ("dda-dirtyrects",     r'GetFrameDirtyRects failed',                 "DDA ACCESS_LOST on the dirty-rects path"),
    # Surfaced by THIS tool's UNCLASSIFIED bucket on the first valid clean-boot sweep of a
    # provenance-verified candidate build (2026-10-09, scratchpad/sweep-win11r-up-valid-175823).
    # Our watchdog's judgement that the agent was ended by session teardown (0x40010004,
    # DBG_TERMINATE_PROCESS) without sending its end-session notice, leaving its vchan announcement
    # behind. Named here so it is counted rather than rediscovered: the previous two families were
    # both found in this bucket, and a signature no family covers is the one nobody is tracking.
    ("wd-notice-missed",   r'QGAWDNOTICEMISSED',                         "the agent was torn down without its end-session notice"),
]


def scan(root):
    counts = collections.Counter()
    unclassified = collections.Counter()
    files = 0
    lines = 0
    for dirpath, _, names in os.walk(root):
        for n in names:
            p = os.path.join(dirpath, n)
            try:
                with open(p, encoding='utf-8', errors='replace') as fh:
                    content = fh.read()
            except OSError:
                continue
            files += 1
            for ln in content.splitlines():
                lines += 1
                if not ERR.search(ln):
                    continue
                body = ln.split(']', 1)[1].strip() if ']' in ln else ln
                for key, rx, _why in FAMILIES:
                    if re.search(rx, body):
                        counts[key] += 1
                        break
                else:
                    unclassified[body[:110]] += 1
    return counts, unclassified, files, lines


def label(root):
    """A capture's name, not the literal 'logs' every one of them ends in."""
    r = root.rstrip('/')
    base = os.path.basename(r)
    if base in ('logs', 'files'):
        parent = os.path.basename(os.path.dirname(r))
        return parent or base
    return base


def report_mode(path):
    """Classify the LAST boot's ERROR signatures from a log-sweep report.json."""
    import json
    try:
        with open(path, encoding='utf-8') as fh:
            rep = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"FAIL cannot read {path}: {exc}")
        return 2
    boots = rep.get('boots') or []
    sigs = rep.get('signatures') or {}
    if not boots:
        print(f"FAIL {path} has no clustered boots - nothing to scope to; missing data is not a zero")
        return 2
    if not sigs:
        print(f"FAIL {path} has no signatures - the capture read nothing")
        return 2
    last = str(boots[-1]['id'])
    print(f"report: {path}")
    print(f"boots clustered: {len(boots)}; LAST boot id {last} at {boots[-1].get('time')}")
    rows = []
    unknown = []
    total = 0
    for key, v in sigs.items():
        if not isinstance(v, dict) or v.get('level') != 'E':
            continue
        n = (v.get('per_boot') or {}).get(last, 0)
        if not n:
            continue
        total += n
        body = key.split('|', 2)[-1]
        for fam, rx, why in FAMILIES:
            if re.search(rx, body):
                rows.append((fam, n, why, body))
                break
        else:
            unknown.append((n, body))
    print(f"\nERROR lines attributed to the LAST boot: {total}")
    if not rows and not unknown:
        print("  (none - no ERROR-level signature occurs in that boot)")
    for fam, n, why, body in sorted(rows, key=lambda r: -r[1]):
        print(f"  x{n:<3} [{fam}] {why}")
        print(f"        {body[:150]}")
    for n, body in sorted(unknown, key=lambda r: -r[0]):
        print(f"  x{n:<3} [UNCLASSIFIED - a signature no family covers]")
        print(f"        {body[:150]}")
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    if argv[1] == '--report':
        if len(argv) < 3:
            print("FAIL --report needs a report.json path")
            return 2
        return report_mode(argv[2])
    results = []
    for root in argv[1:]:
        if not os.path.isdir(root):
            print(f"FAIL not a directory: {root}")
            return 2
        counts, unc, files, lines = scan(root)
        if files == 0 or lines == 0:
            print(f"FAIL nothing to read in {root} ({files} file(s), {lines} line(s)) - missing data is not a zero")
            return 2
        results.append((root, counts, unc, files, lines))

    width = max(len(label(r[0])) for r in results)
    width = max(width, 18)
    heads = [label(r[0]) for r in results]
    print("family".ljust(26) + "".join(h.rjust(width + 2) for h in heads) + "   what it is")
    print("-" * (26 + (width + 2) * len(heads) + 16))
    for key, _rx, why in FAMILIES:
        row = [r[1].get(key, 0) for r in results]
        if not any(row):
            continue
        print(key.ljust(26) + "".join(str(v).rjust(width + 2) for v in row) + f"   {why}")
    print("-" * (26 + (width + 2) * len(heads) + 16))
    print("TOTAL error lines".ljust(26) +
          "".join(str(sum(r[1].values()) + sum(r[2].values())).rjust(width + 2) for r in results))
    print("files / lines read".ljust(26) +
          "".join(f"{r[3]}/{r[4]}".rjust(width + 2) for r in results))
    for root, _c, unc, _f, _l in results:
        if unc:
            print(f"\nUNCLASSIFIED in {label(root)} - a signature no family covers:")
            for body, n in unc.most_common():
                print(f"  x{n:<3} {body}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
