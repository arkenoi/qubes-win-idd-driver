#!/usr/bin/env python3
"""acceptance-record-check.py RECORD ISO_SHA256 VERSION - may this ISO be published? Exit 0 yes, 1 no (with the reason).

The record is tools/record-acceptance.sh's, keyed by the ISO's own hash. tools/cut-release.sh calls this; it used to carry the same
check inline, where nothing could test it without fetching a release. Moved out 2026-10-02 because the check had a hole: it required the
six matrix cells and nothing else, while tools/release-acceptance.sh also runs FEATURE TESTS - and the rz30 run of that day recorded
CLEAN with both feature tests never having run (they died on a retired golden in seconds). A record now has to show every required cell,
the feature tests included, or the ISO is PARTIAL. tools/tests/acceptance-record-selftest.sh drives it.
"""
import json
import os
import sys

# The full campaign's cells (cut-release's long-standing set) plus every feature test release-acceptance.sh runs after the campaign -
# ONE list, tools/release-feature-tests.txt, read by both, so the runner and this check cannot drift apart. Each feature test leaves a
# cell-group named feature-<test> in the campaign dir (tools/release-acceptance.sh).
_HERE = os.path.dirname(os.path.abspath(__file__))
FEATURES = [l.strip() for l in open(os.path.join(_HERE, "release-feature-tests.txt")) if l.strip() and not l.startswith("#")]
REQUIRED = {"win11-clean", "win10-clean", "win11-upgrade", "win11-reinstall", "win11-appvm", "win10-appvm"} | {"feature-" + f for f in FEATURES}
if os.environ.get("ACCEPT_CHECK_DEFECT") == "1":   # GUARD:feature-cells - the self-test must FAIL with this set
    REQUIRED = {c for c in REQUIRED if not c.startswith("feature-")}


def bad(m):
    print(f"ERROR: acceptance record: {m}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 4:
        print("usage: acceptance-record-check.py RECORD ISO_SHA256 VERSION", file=sys.stderr)
        sys.exit(2)
    path, iso, ver = sys.argv[1:4]
    try:
        rec = json.load(open(path))
    except Exception as e:
        bad(f"unreadable ({e})")
    if rec.get("iso_sha256") != iso:
        bad("records a different ISO than the one being published")
    if rec.get("release_version") != ver:
        bad(f"records release {rec.get('release_version')}, publishing {ver}")
    if rec.get("verdict") != "CLEAN":
        bad(f"verdict is {rec.get('verdict')!r}, not CLEAN")
    if int(rec.get("cell_groups_failed", 1)) != 0:
        bad(f"{rec.get('cell_groups_failed')} cell-group(s) had failures")
    cells = rec.get("cells") or []
    missing = REQUIRED - set(cells)
    if missing:
        bad("PARTIAL - these did not run: " + ", ".join(sorted(missing)))
    print(f"[cut] acceptance: {rec.get('cell_groups_clean')} cell-groups clean, cells={len(cells)}, recorded {rec.get('recorded_utc')}")


if __name__ == "__main__":
    main()
