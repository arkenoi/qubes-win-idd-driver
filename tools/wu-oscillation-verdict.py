#!/usr/bin/env python3
"""wu-oscillation-verdict.py - decide an oscillation by IDENTITY, not by a count.

THE PROBLEM A COUNT CANNOT SOLVE. The oscillation check asserts dom0's updates-available did not
change across a scan. That conflates two different events:

  * THE SAME OFFER COMING BACK after a pass resolved it - a real oscillation, our defect;
  * MICROSOFT PUBLISHING A NEW ONE mid-campaign - not our defect at all.

Both move the number from N to N+1. Owner, 2026-10-20: "can we sanely handle the situation when
update was published AFTER the campaign start and not fail there?" By count, no. By identity, yes:
every offer carries an UpdateID and a RevisionNumber, which qubes-windows-update.ps1 already
captures off the live COM object ("no title parsing, no locale dependence", ADR section 6).

An offer whose UpdateID was NOT present before is newly published. An offer whose UpdateID WAS
present - and which the pass reported as resolved - coming back is the oscillation.

KB2267602 is exactly why the count fails: Microsoft republishes Defender Security Intelligence
several times a day, each time under a NEW UpdateID. By count that reads as the same thing
oscillating; by identity it is plainly a new publication.

A REVISION BUMP IS A REPUBLICATION, NOT A RETURN. Same UpdateID with a higher RevisionNumber is
Microsoft reissuing the offer, so it is classed with the new ones - and named, because an
unexplained revision bump is worth seeing.

Exit 0 STABLE or NEW-PUBLICATION (both acceptable), 1 OSCILLATION, 2 on bad input - never a silent
pass, and an empty/unreadable side is input failure, not "no oscillation".
"""
import argparse, json, sys


def load(path):
    """[{id, rev, kb?}] from a json file; accepts a bare list or {"offers": [...]}."""
    with open(path, encoding="utf-8-sig") as fh:
        d = json.load(fh)
    if isinstance(d, dict):
        d = d.get("offers", d.get("updates", []))
    if not isinstance(d, list):
        raise ValueError(f"{path}: expected a list of offers, got {type(d).__name__}")
    out = {}
    for o in d:
        if not isinstance(o, dict):
            raise ValueError(f"{path}: an offer is {type(o).__name__}, not an object")
        uid = str(o.get("id") or o.get("uid") or o.get("UpdateID") or "").strip().lower()
        if not uid:
            raise ValueError(f"{path}: an offer carries no UpdateID - identity is the whole point")
        rev = o.get("rev", o.get("RevisionNumber"))
        out[uid] = {"rev": int(rev) if rev is not None else None,
                    "kb": str(o.get("kb") or o.get("KB") or "")}
    return out


def verdict(before, after, resolved):
    """resolved = UpdateIDs the pass reported it dealt with."""
    res = {u.strip().lower() for u in resolved if u and u.strip()}
    returned, republished, new = [], [], []
    for uid, a in sorted(after.items()):
        if uid not in before:
            new.append(uid)
            continue
        b = before[uid]
        if a["rev"] is not None and b["rev"] is not None and a["rev"] > b["rev"]:
            republished.append(uid)
        elif uid in res:
            returned.append(uid)          # we said we resolved it, and here it is again
    return returned, republished, new


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--before", required=True, help="offers present BEFORE the scan (json)")
    ap.add_argument("--after", required=True, help="offers present AFTER the scan (json)")
    ap.add_argument("--resolved", default="", help="comma-separated UpdateIDs the pass resolved")
    a = ap.parse_args()
    try:
        before, after = load(a.before), load(a.after)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"OSC-VERDICT input-error: {e}", file=sys.stderr)
        return 2
    returned, republished, new = verdict(before, after, a.resolved.split(","))
    if returned:
        print("OSC-VERDICT OSCILLATION returned=%d (%s) republished=%d new=%d"
              % (len(returned), ",".join(returned[:4]), len(republished), len(new)))
        return 1
    if new or republished:
        print("OSC-VERDICT NEW-PUBLICATION new=%d (%s) republished=%d (%s) - not an oscillation: "
              "these offers were not present before the scan"
              % (len(new), ",".join(new[:4]) or "-", len(republished), ",".join(republished[:4]) or "-"))
        return 0
    print("OSC-VERDICT STABLE before=%d after=%d" % (len(before), len(after)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
