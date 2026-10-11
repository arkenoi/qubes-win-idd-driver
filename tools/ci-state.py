#!/usr/bin/env python3
"""ci-state.py [sha] - the conclusion of EVERY workflow for a commit, not just the one you asked about.

WHY IT EXISTS. On 2026-10-11 I took a guest receipt against build "38119590694 green" and reported the
fix as building clean. That run was release-package. build.yml - which runs the offline test batteries -
had been RED for 14 consecutive runs since 2026-10-10T16:00Z, because a message-rewording pass had moved
the text three notifyerr checks match. Nothing lied to me: I read one workflow's conclusion and called it
"the build". Same shape as the owner's rule about dom0 toasts - if it is red, I am supposed to see it,
with no guesswork and without being told.

A REQUIRED workflow (build.yml, test.yml) must be green FOR THIS SHA. Three cases, kept apart because
collapsing them is how this tool would start lying in its turn:

  ran        a run exists for the sha              -> its conclusion decides
  skipped    the workflow is path-filtered and this sha's diff matches none of its paths, so GitHub
             never started it. Not a failure of the sha - but the workflow's LATEST run anywhere is
             then asserted instead, because a red ancestor run means a live defect that this sha
             simply does not re-test. Reported as 'inh' with the sha it was inherited from.
  absent     it should have run for this sha and did not -> MISS, rc 1. Missing data fails.

  rc 0  every required workflow is green for this sha (or green on the run it inherits)
  rc 1  a required workflow is RED, or has no run where one was due
  rc 2  one is still running, or gh could not be read: no verdict yet, never a pass

GH_BIN is overridable so both arms are provable offline; tools/tests/ci-state-selftest.sh drives it.
"""
import fnmatch
import json
import os
import subprocess
import sys

import yaml

GH = os.environ.get("GH_BIN", "gh")
REQUIRED = os.environ.get("CI_STATE_REQUIRED", "build.yml test.yml").split()


def sh(args):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=120)
        return p.stdout
    except Exception:
        return ""


def runs(name):
    out = sh([GH, "run", "list", "--workflow", name, "--limit", "40",
              "--json", "headSha,status,conclusion,databaseId,createdAt"])
    try:
        rows = json.loads(out)
        return rows if isinstance(rows, list) else None
    except Exception:
        return None                      # UNREADABLE is not "no runs" - the caller must not pass it


def push_paths(wf):
    """the workflow's on.push.paths / paths-ignore, or (None, None) when it runs on every push."""
    try:
        with open(wf, encoding="utf-8") as f:
            y = yaml.safe_load(f)
    except Exception:
        return (None, None)
    # YAML reads a bare `on:` key as the boolean True, which is why this is not y.get("on")
    on = y.get("on", y.get(True, {})) if isinstance(y, dict) else {}
    push = (on or {}).get("push") or {}
    if not isinstance(push, dict):
        return (None, None)
    return (push.get("paths"), push.get("paths-ignore"))


def matches(path, pats):
    for p in pats:
        if p.endswith("/**"):
            if path.startswith(p[:-2]):
                return True
        elif fnmatch.fnmatch(path, p) or fnmatch.fnmatch(path, p.replace("**", "*")):
            return True
    return False


def would_run(wf, changed):
    """would a push of these changed files start this workflow?"""
    paths, ignore = push_paths(wf)
    if paths is None and ignore is None:
        return True                       # no filter: every push starts it
    if changed is None:
        return True                       # cannot tell -> assume it was due, so an absence is loud
    if paths and not any(matches(c, paths) for c in changed):
        return False
    if ignore and changed and all(matches(c, ignore) for c in changed):
        return False
    return True


def main(argv):
    sha = argv[1] if len(argv) > 1 else sh(["git", "rev-parse", "HEAD"]).strip()
    if not sha:
        print("CI 2 could not read a sha")
        return 2
    # CI_STATE_CHANGED is test-only, the same reason GH_BIN is: the path-filter arms must be
    # deterministic rather than depending on what HEAD happens to touch.
    if "CI_STATE_CHANGED" in os.environ:
        changed = os.environ["CI_STATE_CHANGED"].split() or None
    else:
        ch = sh(["git", "diff", "--name-only", sha + "^", sha]).split()
        changed = ch if ch else None
    rc, running = 0, False
    print("ci-state %s" % sha[:8])
    for wf in sorted(__import__("glob").glob(".github/workflows/*.yml")):
        name = os.path.basename(wf)
        req = name in REQUIRED
        rows = runs(name)
        mine = None
        if rows:
            for r in rows:                # newest first: the first match is the latest run
                h = r.get("headSha", "")
                if h[:8] == sha[:8]:
                    mine = r
                    break
        mark, status, concl, rid, note = "    ", "-", "-", "-", ""
        if rows is None:
            mark, status, note = "????", "UNREAD", "gh could not be read"
            if req:
                running = True
        elif mine:
            status, concl, rid = mine.get("status"), mine.get("conclusion") or "-", mine.get("databaseId")
            if status == "completed" and concl == "success":
                mark = "ok  "
            elif status == "completed":
                mark = "RED "
                if req:
                    rc = 1
            else:
                mark = "run "
                if req:
                    running = True
        elif not would_run(wf, changed):
            # path-filtered out for this sha. Inherit the latest run anywhere, and say from where.
            latest = rows[0] if rows else None
            if latest is None:
                mark, status, note = "none", "NORUN", "path-filtered, and no run exists at all"
                if req:
                    rc = 1
                    mark = "MISS"
            else:
                status = latest.get("status")
                concl = latest.get("conclusion") or "-"
                rid = latest.get("databaseId")
                note = "path-filtered for this sha; inherited from %s" % (latest.get("headSha", "")[:8])
                if status == "completed" and concl == "success":
                    mark = "inh "
                elif status == "completed":
                    mark = "RED "
                    if req:
                        rc = 1
                else:
                    mark = "run "
                    if req:
                        running = True
        else:
            mark, status, note = "none", "NORUN", "no run for this sha"
            if req:
                rc = 1
                mark = "MISS"
                note = "DUE for this sha and absent"
        print("  %s %-22s %-11s %-9s %-11s %s%s"
              % (mark, name, status, concl, rid, "(required) " if req else "", note))
    if rc == 0 and running:
        rc = 2
    print({0: "CI 0 every required workflow is green for %s" % sha[:8],
           1: "CI 1 a required workflow is RED or absent for %s - do not receipt against this sha" % sha[:8],
           2: "CI 2 a required workflow has not finished for %s - no verdict yet" % sha[:8]}[rc])
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
