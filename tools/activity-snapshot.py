#!/usr/bin/env python3
"""activity-snapshot.py - the ACTIVITY SNAPSHOT a failure package always carries (PLAN-acceptance-optimization
section 4), computed from artefacts already on the host. Nothing here talks to a guest.

    tools/activity-snapshot.py --out activity-snapshot.json [--logs <logsdir>]... [--logvol-files <dir>]
                               [--events <events.txt>] [--clock <clock-presync.txt>] [--clock-skew-s N]
                               [--timeline <timeline.txt>] [--harness-cmd "<cmd>"] [--harness-cmd-source <s>]
                               [--vm <name>] [--reason "<why>"] [--power-state <s>] [--tail N]

WHAT IT WRITES - the six things the plan names, each either filled or marked MISSING with the reason (missing
data never reads as an empty success):
  module_logs      the last N lines (default 20) of EVERY module log found - keyed by file name, with the module
                   family, the line count and the timestamp of the last line - from the sweep's decoded logs
                   (<logsdir>/files, <logsdir>/meta.json) and/or a secondary-volume copy (--logvol-files);
  last_qrexec_pair the last call the guest's qrexec-wrapper handled: its 'LogInit: Command line:' record (the
                   request) and the last line that same pid wrote (the outcome), with pid and timestamps;
  last_window      the last window/focus event in the gui-agent log (SendWindowMap/Unmap, focus, window event
                   thread lines) and the last hwnd it named;
  clock_skew       the pre-sync guest-vs-host skew (from log-sweep.sh's clock-presync.txt, or --clock-skew-s);
  power_timeline   every power-state reading the caller recorded (--timeline: 'utc state source' lines) merged
                   with the guest's own boot/shutdown event records (6005/6006/1074/41/12/13) from events.txt;
  harness_cmd      the exact command of the harness that was running, and where that string came from.

The log formats are the ones tools/log-sweep.py parses: windows-utils '[yyyymmdd.hhmmss.mmm-pid:tid-L] Func: msg'
(and the pre-4.3.33 '[...-tid-L]' shape), 'EV yyyy-mm-dd hh:mm:ss.fff [Log] id=N ...' event records, and plain
timestamped lines for everything else. Exit 0 when every field is present, 1 when any field is MISSING (the
file is still written - a partial snapshot is evidence, an absent one is not), 2 on a usage error.
Self-test: tools/tests/collect-failure-selftest.sh drives it with fixtures and the defect knobs.
"""
from __future__ import annotations
import argparse, base64, json, os, re, sys, time

WU_RE = re.compile(r"^﻿?\[(?P<d>\d{8})\.(?P<t>\d{6})\.(?P<ms>\d{3})-(?:(?P<pid>\d+):)?(?P<tid>\d+)-(?P<lvl>[A-Z])\] (?P<func>[A-Za-z0-9_]+): (?P<msg>.*)$")
EV_RE = re.compile(r"^EV (?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) \[(?P<log>[^\]]+)\] id=(?P<id>\d+) level=(?P<lvl>\d+) (?P<prov>[^:]+): (?P<msg>.*)$")
TS_RE = re.compile(r"(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)")
WINDOW_FUNCS = re.compile(r"(SendWindowMap|SendWindowUnmap|SendWindowFocus|OnFocus|WindowEvent|AddWindow|RemoveWindow|ShouldAcceptWindow|SendWindowConfigure|PwAttachWindow|PwDetachWindow|focus)", re.I)
HWND_RE = re.compile(r"\b(?:hwnd[= ]|window )(0x[0-9a-fA-F]+)")
# boot / shutdown markers in the System log (docs/ADR-supervision.md; the sweep collector pre-filters to these)
POWER_EVENTS = {"6005": "eventlog-started (boot)", "6006": "eventlog-stopped (shutdown)", "6008": "unexpected-shutdown",
                "6009": "boot-banner", "1074": "shutdown-initiated", "1076": "shutdown-reason",
                "41": "kernel-power-41 (dirty reboot)", "109": "kernel-power-109 (shutdown)", "12": "os-started", "13": "os-shutting-down"}

FAMILY_HINTS = [("gui-agent", "agent"), ("gui-watchdog", "watchdog"), ("qrexec-wrapper", "qrexec-wrapper"),
                ("qrexec-agent", "qrexec-agent"), ("qubesdb-daemon", "qubesdb"), ("bridge", "bridge"), ("etw-proxy", "etwproxy"),
                ("qwt-improved-install", "installer"), ("qwt-install", "msi"), ("qwt-uninstall", "msi"),
                ("QubesPvNic", "pvnic"), ("QubesNetSetup", "netsetup"), ("QubesIDD-diag", "idd"), ("bind-dirs", "binddirs"),
                ("file-receiver", "file-receiver"), ("wu-", "updater"), ("relay", "updater")]


def wu_ts(m) -> str:
    d, t, ms = m.group("d"), m.group("t"), m.group("ms")
    return "%s-%s-%s %s:%s:%s.%s" % (d[:4], d[4:6], d[6:], t[:2], t[2:4], t[4:], ms)


def family_of(name: str) -> str:
    low = name.lower()
    for stem, fam in FAMILY_HINTS:
        if stem.lower() in low:
            return fam
    return "other"


def read_lines(path: str) -> list[str]:
    with open(path, "rb") as f:
        data = f.read()
    if data.startswith(b"\xff\xfe"):
        text = data.decode("utf-16", errors="replace")
    else:
        text = data.decode("utf-8", errors="replace")
    return [ln.rstrip("\r").replace("\0", "") for ln in text.split("\n") if ln.strip("\r") != ""]


def last_ts(lines: list[str]) -> str | None:
    for ln in reversed(lines):
        m = WU_RE.match(ln)
        if m:
            return wu_ts(m)
        m2 = EV_RE.match(ln)
        if m2:
            return m2.group("ts")
        m3 = TS_RE.search(ln)
        if m3:
            return m3.group(1)
    return None


def collect_logs(dirs: list[str], meta_paths: list[str]) -> tuple[dict[str, list[str]], list[str]]:
    """Every log file under the given directories (recursive), keyed by basename. The same module log can
    arrive twice - once from the live sweep's pull and once from the secondary volume's copy, read at
    different instants - and the snapshot presents each module ONCE: the copy with MORE lines wins (the
    later read of an append-only file is the longer one) and the other source is noted, never dropped
    silently. meta.json, when present, maps decoder ids back to guest paths."""
    out: dict[str, list[str]] = {}
    notes: list[str] = []
    origin: dict[str, str] = {}
    names: dict[str, str] = {}
    for mp in meta_paths:
        try:
            meta = json.load(open(mp, encoding="utf-8"))
        except (OSError, ValueError) as e:
            notes.append("meta unreadable: %s (%s)" % (mp, e))
            continue
        for f in meta.get("files", []):
            try:
                names[f.get("id", "")] = base64.b64decode(f.get("pathb64", "")).decode("utf-8", "replace")
            except Exception:
                pass
    for d in dirs:
        if not os.path.isdir(d):
            notes.append("logs dir missing: %s" % d)
            continue
        for root, _dirs, files in os.walk(d):
            for fn in sorted(files):
                if fn in ("meta.json", "decode.txt", "LOGVOL.TAG") or fn.endswith((".png", ".tar", ".gz", ".json")):
                    continue
                p = os.path.join(root, fn)
                try:
                    lines = read_lines(p)
                except OSError as e:
                    notes.append("unreadable: %s (%s)" % (p, e))
                    continue
                key = fn
                if key in out:
                    if len(lines) > len(out[key]):
                        notes.append("%s: kept the copy from %s (%d lines) over %s (%d lines)" % (key, d, len(lines), origin[key], len(out[key])))
                        out[key] = lines
                        origin[key] = d
                    else:
                        notes.append("%s: kept the copy from %s (%d lines) over %s (%d lines)" % (key, origin[key], len(out[key]), d, len(lines)))
                    continue
                out[key] = lines
                origin[key] = d
    return out, notes


def module_tails(logs: dict[str, list[str]], n: int) -> dict:
    res = {}
    for name, lines in sorted(logs.items()):
        res[name] = {"family": family_of(name), "lines": len(lines), "last_ts": last_ts(lines), "tail": lines[-n:]}
    return res


def last_qrexec_pair(logs: dict[str, list[str]]) -> dict | None:
    best = None
    for name, lines in logs.items():
        if "qrexec-wrapper" not in name.lower():
            continue
        for i, ln in enumerate(lines):
            m = WU_RE.match(ln)
            if not m or m.group("func") != "LogInit" or not m.group("msg").startswith("Command line:"):
                continue
            pid = m.group("pid") or m.group("tid")   # pre-4.3.33 files name the pid in the FILE name only; the tid is the best key there
            # the outcome: the last line this pid wrote
            outcome = None
            for ln2 in reversed(lines[i + 1:]):
                m2 = WU_RE.match(ln2)
                if m2 and (m2.group("pid") or m2.group("tid")) == pid:
                    outcome = {"ts": wu_ts(m2), "line": ln2[:400]}
                    break
            cand = {"file": name, "pid": pid, "request_ts": wu_ts(m), "request": m.group("msg")[len("Command line:"):].strip()[:400],
                    "outcome": outcome}
            if best is None or cand["request_ts"] >= best["request_ts"]:
                best = cand
    return best


def last_window(logs: dict[str, list[str]]) -> dict | None:
    best = None
    for name, lines in logs.items():
        if "gui-agent" not in name.lower():
            continue
        for ln in lines:
            m = WU_RE.match(ln)
            if not m:
                continue
            if not (WINDOW_FUNCS.search(m.group("func")) or WINDOW_FUNCS.search(m.group("msg")[:60])):
                continue
            h = HWND_RE.search(m.group("msg"))
            cand = {"file": name, "ts": wu_ts(m), "func": m.group("func"), "line": ln[:400], "hwnd": h.group(1) if h else None}
            if best is None or cand["ts"] >= best["ts"]:
                best = cand
    return best


def clock_from_file(path: str | None) -> dict | None:
    if not path or not os.path.exists(path):
        return None
    txt = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"(2\d{3}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)", txt)
    if not m:
        return None
    guest = m.group(1)
    host = None
    try:
        host = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(os.path.getmtime(path)))
    except OSError:
        pass
    skew = None
    if host:
        try:
            g = time.mktime(time.strptime(guest[:19], "%Y-%m-%dT%H:%M:%S"))
            hh = time.mktime(time.strptime(host[:19], "%Y-%m-%dT%H:%M:%S"))
            skew = int(round(g - hh))
        except ValueError:
            skew = None
    return {"guest_utc": guest, "host_utc_at_read": host, "skew_s": skew, "source": path}


def timeline(path: str | None, events_lines: list[str]) -> list[dict]:
    rows = []
    if path and os.path.exists(path):
        for ln in open(path, encoding="utf-8", errors="replace"):
            parts = ln.strip().split(None, 2)
            if len(parts) >= 2 and TS_RE.match(parts[0]):
                rows.append({"utc": parts[0], "state": parts[1], "source": parts[2] if len(parts) > 2 else "harness"})
    for ln in events_lines:
        m = EV_RE.match(ln)
        if m and m.group("id") in POWER_EVENTS:
            rows.append({"utc": m.group("ts").replace(" ", "T"), "state": POWER_EVENTS[m.group("id")],
                         "source": "guest-event %s/%s" % (m.group("log"), m.group("id")), "guest_local_time": True})
    rows.sort(key=lambda r: r["utc"])
    return rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True)
    ap.add_argument("--logs", action="append", default=[], help="a decoded sweep logs dir (files/ + meta.json + events.txt)")
    ap.add_argument("--logvol-files", action="append", default=[], help="a secondary-volume copy (logvol_pull's files/)")
    ap.add_argument("--events", help="an events.txt (defaults to <logs>/events.txt)")
    ap.add_argument("--clock", help="log-sweep.sh's clock-presync.txt")
    ap.add_argument("--clock-skew-s", type=int, help="a skew the caller measured itself")
    ap.add_argument("--timeline", help="'utc state source' lines the caller recorded")
    ap.add_argument("--harness-cmd", default="")
    ap.add_argument("--harness-cmd-source", default="")
    ap.add_argument("--vm", default="")
    ap.add_argument("--reason", default="")
    ap.add_argument("--power-state", default="")
    ap.add_argument("--tail", type=int, default=20)
    a = ap.parse_args(argv)

    dirs, metas, notes = [], [], []
    for d in a.logs:
        dirs.append(os.path.join(d, "files") if os.path.isdir(os.path.join(d, "files")) else d)
        if os.path.exists(os.path.join(d, "meta.json")):
            metas.append(os.path.join(d, "meta.json"))
    dirs += a.logvol_files
    logs, notes2 = collect_logs(dirs, metas)
    notes += notes2
    events_lines: list[str] = []
    evp = a.events or next((os.path.join(d, "events.txt") for d in a.logs if os.path.exists(os.path.join(d, "events.txt"))), None)
    if evp:
        events_lines = read_lines(evp)
    for name, lines in list(logs.items()):
        if name == "events.txt":
            events_lines = events_lines or lines
            del logs[name]

    missing: list[str] = []
    snap = {"version": 1, "generated_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "vm": a.vm, "reason": a.reason,
            "power_state_at_collection": a.power_state or None, "notes": notes}
    tails = module_tails(logs, a.tail)
    snap["module_logs"] = tails
    if not tails:
        missing.append("module_logs: no module log was readable (no sweep logs dir and no secondary-volume copy)")   # GUARD:missingtails DEFECT: pass
    q = last_qrexec_pair(logs)
    snap["last_qrexec_pair"] = q
    if q is None:
        missing.append("last_qrexec_pair: no qrexec-wrapper 'Command line:' record in any log")
    w = last_window(logs)
    snap["last_window"] = w
    if w is None:
        missing.append("last_window: no window/focus line in any gui-agent log")
    ck = clock_from_file(a.clock)
    if ck is None and a.clock_skew_s is not None:
        ck = {"skew_s": a.clock_skew_s, "source": "caller"}
    snap["clock_skew"] = ck
    if ck is None:
        missing.append("clock_skew: no clock-presync.txt and no --clock-skew-s")
    tl = timeline(a.timeline, events_lines)
    snap["power_timeline"] = tl
    if not tl:
        missing.append("power_timeline: no readings and no boot/shutdown event records")
    snap["harness_cmd"] = {"cmd": a.harness_cmd, "source": a.harness_cmd_source or ("argument" if a.harness_cmd else "")}
    if not a.harness_cmd:
        missing.append("harness_cmd: not given")
    snap["missing"] = missing
    snap["complete"] = not missing
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(snap, f, indent=1, ensure_ascii=False)
    print("SNAPSHOT %s: logs=%d qrexec_pair=%s window=%s clock=%s timeline=%d missing=%d -> %s" % (
        "COMPLETE" if not missing else "PARTIAL", len(tails), "yes" if q else "no", "yes" if w else "no",
        "yes" if ck else "no", len(tl), len(missing), a.out))
    for m in missing:
        print("  MISSING " + m)
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
