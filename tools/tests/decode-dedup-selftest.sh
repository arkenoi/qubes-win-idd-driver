#!/usr/bin/env bash
# decode-dedup-selftest.sh - ONE LOGICAL FILE PULLED TWICE IS NOT TWO FILES. No guest, no rig.
#
# WHY THIS EXISTS. The collector sweeps the UNION of every directory a module could have resolved
# its LogDir to (Get-LswLogDirCandidates, added 2026-10-23 because a bound log volume left the real
# directory unswept and both upgrade cells failed on evidence that was never pulled). That fix was
# verified by showing it FOUND the extra directory. It was not verified for what happens when a file
# is present in TWO of those directories - and then the pull carries it twice, decode kept both
# under `<base>.<id>`, and every line in it was counted twice.
#
# MEASURED on the first supervision-gate run on a guest (2026-10-23, /home/user/qwt-sup/1023-1646):
# 21 of 88 files had a second copy. gui-agent-20261023-194816-5484.log came from
# `Z:\qwt-logs\win11r-sup` and `Q:\Qubes Logs`, decoding to 17754 and 19861 bytes of text, so ONE
# process start (pid 5484) opened TWO instance records:
#     agent_instances 6 for 5 real instances; agent_instances_per_boot 2 against a max of 1
#     -> P2 BREACH and cell L2 FAIL, while that agent had started exactly once in every boot
#     warning_lines 182, of which 42 were the same lines twice
# After the dedupe, same capture and the SAME analyzer arguments: instances 5, per_boot 1, warnings
# 140, and both of those breaches gone, leaving only the two REAL findings.
#
# THE TEST IS A BYTE PREFIX, NOT A HASH, because two reads of a growing file are almost never
# identical - the later one is longer. A prefix means the kept copy CONTAINS every line the dropped
# one had. Of the 21, gui-agent/gui-watchdog/qubesdb-daemon/qrexec-* were prefixes; bridge.log and
# etw-proxy.log DIVERGED - genuinely different files sharing one basename across two directories -
# and those must be KEPT, because dropping either loses lines. Both cases are asserted here.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/dedup-selftest-XXXXXX)"
PASS=0; FAIL=0
ok(){ echo "ok   $*"; PASS=$((PASS+1)); }
no(){ echo "FAIL $*"; FAIL=$((FAIL+1)); }

# ---- build a pull.txt the way the collector writes one -------------------------------------------
python3 - "$OUT" <<'PY'
import base64, hashlib, sys, os
out = sys.argv[1]

# VERBATIM from win11r-sup's gui-agent-20261023-194816-5484.log (the golden's 4.3.35.795 agent),
# which is the file the real capture pulled twice.
HEAD = ("[20261023.194816.042-5488-I] LogInit: Log started, module name: gui-agent\n"
        "[20261023.194816.042-5488-I] LogInit: System uptime: 49.953 seconds\n"
        "[20261023.194816.042-5488-I] LogInit: Running as user: SYSTEM, process ID: 5484\n"
        "[20261023.194816.042-5488-I] LogInit: Module version: 4.3.35.795\n"
        "[20261023.194816.054-5488-I] LogInit: Session: 1\n")
TAIL = "[20261023.194818.100-5488-I] TrackWindows: up\n"

FILES = [
    # id,   guest path,                                              content,        family
    ("f19", r"Z:\qwt-logs\win11r-sup\gui-agent-20261023-194816-5484.log", HEAD,        "agent"),
    ("f20", r"Q:\Qubes Logs\gui-agent-20261023-194816-5484.log",         HEAD + TAIL,  "agent"),
    # the divergent pair: same basename, two directories, neither a prefix of the other
    ("f30", r"Z:\qwt-logs\win11r-sup\bridge.log",                        "20261023.194820 bridge: A-only line\n", "blog"),
    ("f31", r"Q:\Qubes Logs\bridge.log",                                 "20261023.194821 bridge: B-only line\n", "blog"),
]

L = []
L.append("LSW BEGIN v=1 now=2026-10-23T20:05:20.329 nowutc=2026-10-23T17:05:20.329Z tz=+03:00 "
         "host=%s user=%s session=1 since=2026-10-23T16:46:55Z sincelocal=2026-10-23T19:46:55"
         % (base64.b64encode(b"WIN11-IDD-TEST").decode(), base64.b64encode(b"NT AUTHORITY\\SYSTEM").decode()))
L.append("LSW LOGDIR pathb64=%s exists=1" % base64.b64encode(r"Z:\qwt-logs\win11r-sup".encode()).decode())
L.append("LSW LOGDIREXTRA pathb64=%s exists=1 files=2" % base64.b64encode(r"Q:\Qubes Logs".encode()).decode())
for fid, path, text, fam in FILES:
    raw = text.encode()
    b64 = base64.b64encode(raw).decode()
    # the collector wraps the base64 at 64 chars per line, and the block's announced b64lines must
    # equal the number of B| lines or decode calls the transfer TRUNCATED
    chunks = [b64[i:i + 64] for i in range(0, len(b64), 64)] or [""]
    nlines = len(text.split("\n")) if text else 0
    L.append("LSW FILE id=%s pathb64=%s family=%s bytes=%d lines=%d written=2026-10-23T19:48:18.000 "
             "created=2026-10-23T19:48:16.040 partial=0 total_lines=%d"
             % (fid, base64.b64encode(path.encode()).decode(), fam, len(raw), nlines, nlines))
    L.append("LSW PULL name=%s lines=%d bytes=%d sha256=%s b64lines=%d"
             % (fid, nlines, len(raw), hashlib.sha256(raw).hexdigest(), len(chunks)))
    for c in chunks:
        L.append("LSW B|" + c)
    L.append("LSW PULLEND name=%s b64lines=%d" % (fid, len(chunks)))
L.append("LSW END files=%d pulled=%d errors=0 event_errors=0" % (len(FILES), len(FILES)))
open(os.path.join(out, "pull.txt"), "w", encoding="utf-8").write("\n".join(L) + "\n")
print("pull.txt written with %d file blocks" % len(FILES))
PY

run_decode() {   # $1 = analyzer path, $2 = out dir
    python3 "$1" decode "$OUT/pull.txt" --out "$2" > "$2.decode.txt" 2>&1
}

mkdir -p "$OUT/logs"
run_decode "$ROOT/tools/log-sweep.py" "$OUT/logs"; drc=$?
[ "$drc" = 0 ] && ok "decode accepted the fixture (rc=0)" \
               || { no "decode rejected the fixture (rc=$drc) - the fixture is wrong, not the code"; sed 's/^/     /' "$OUT/logs.decode.txt" | tail -8; }

# ---- the prefix pair: the SHORT copy is dropped, the LONG one kept -------------------------------
if [ -f "$OUT/logs/files/gui-agent-20261023-194816-5484.log" ]; then
    kept_bytes=$(stat -c%s "$OUT/logs/files/gui-agent-20261023-194816-5484.log")
    dups=$(find "$OUT/logs/files" -name 'gui-agent-*.log.f*' | wc -l)
    [ "$dups" = 0 ] && ok "the prefix copy is gone (no gui-agent *.f<id> file remains)" \
                    || no "the prefix copy survived: $(find "$OUT/logs/files" -name 'gui-agent-*.log.f*' -printf '%f ')"
    [ "$kept_bytes" -gt 300 ] && ok "the copy KEPT is the LONGER one ($kept_bytes bytes)" \
                              || no "the kept copy is the short one ($kept_bytes bytes) - the wrong copy won"
else
    no "no gui-agent file in the decode output at all"
fi
grep -qa 'DECODE DEDUP gui-agent.*strict prefix' "$OUT/logs.decode.txt" \
  && ok "the drop is ANNOUNCED with both guest paths" \
  || no "the drop was silent - an exclusion must never be"
python3 - "$OUT" <<'PY' > "$OUT/meta.txt" 2>&1
import json, sys
m = json.load(open(sys.argv[1] + "/logs/meta.json"))
d = m.get("decode_dedup") or []
print("DEDUPCOUNT %d" % len(d))
for e in d:
    print("DROPPED %s KEPT %s" % (e.get("dropped_path"), e.get("kept_path")))
print("SUPERSEDED %d" % sum(1 for f in m.get("files", []) if f.get("superseded_by")))
PY
[ "$(grep -a '^DEDUPCOUNT' "$OUT/meta.txt" | awk '{print $2}')" = 1 ] \
  && ok "meta.json records exactly one dedupe decision" \
  || no "meta.json dedupe record wrong: $(grep -a '^DEDUPCOUNT' "$OUT/meta.txt")"
[ "$(grep -a '^SUPERSEDED' "$OUT/meta.txt" | awk '{print $2}')" = 1 ] \
  && ok "the dropped file record carries superseded_by (so it is not read as MISSING)" \
  || no "no superseded_by on the dropped record: $(grep -a '^SUPERSEDED' "$OUT/meta.txt")"

# ---- the divergent pair: BOTH kept --------------------------------------------------------------
nb=$(find "$OUT/logs/files" -name 'bridge.log*' | wc -l)
[ "$nb" = 2 ] && ok "the DIVERGENT pair is kept (both bridge.log copies survive)" \
              || no "divergent copies were dropped ($nb bridge.log file(s)) - that loses lines"
grep -qa 'DECODE DEDUP bridge.log: 2 copies KEPT' "$OUT/logs.decode.txt" \
  && ok "and the kept pair is reported, so a reader sees one name in two directories" \
  || no "the divergent pair was kept SILENTLY"

# ---- the analyzer must not call the drop a missing file, and must report the figure --------------
python3 "$ROOT/tools/log-sweep.py" analyze "$OUT/logs" --baseline "$ROOT/mgmt/harness/log-sweep-baseline.json" \
    --out "$OUT/report.json" --summary "$OUT/summary.txt" --since "2026-10-23 19:46:55.000" \
    --label dedup-selftest > "$OUT/analyze.out" 2>&1
python3 - "$OUT" <<'PY' > "$OUT/an.txt" 2>&1
import json, sys
r = json.load(open(sys.argv[1] + "/report.json"))
miss = [p for p in (r.get("data_problems") or []) if p and p[0] == "missing"]
print("MISSING %d" % len(miss))
for p in miss[:3]: print("   ", str(p)[:120])
print("DEDUPFIGURE %s" % (r.get("header") or {}).get("files_deduped"))
print("INSTANCES %s" % (r.get("metrics") or {}).get("agent_instances"))
PY
[ "$(grep -a '^MISSING' "$OUT/an.txt" | awk '{print $2}')" = 0 ] \
  && ok "the analyzer does NOT report the dropped copy as a missing file" \
  || { no "the drop reads as MISSING - a correct dedupe becomes a DATA verdict"; grep -a '^   ' "$OUT/an.txt" | head -3 | sed 's/^/     /'; }
[ "$(grep -a '^DEDUPFIGURE' "$OUT/an.txt" | awk '{print $2}')" = 1 ] \
  && ok "the report carries files_deduped=1 - the exclusion is a published figure" \
  || no "files_deduped not reported: $(grep -a '^DEDUPFIGURE' "$OUT/an.txt")"
[ "$(grep -a '^INSTANCES' "$OUT/an.txt" | awk '{print $2}')" = 1 ] \
  && ok "ONE process start is ONE instance record (agent_instances=1)" \
  || no "agent_instances=$(grep -a '^INSTANCES' "$OUT/an.txt" | awk '{print $2}') for one process start"

# ---- SEEN TO FAIL: neuter the prefix test and the duplicate must come back -----------------------
sed 's/longest\["text"\].startswith(c\["text"\])/False/' "$ROOT/tools/log-sweep.py" > "$OUT/mut.py"
if cmp -s "$ROOT/tools/log-sweep.py" "$OUT/mut.py"; then
    no "seen-to-fail: the mutation changed nothing - the prefix test is not where this suite thinks"
else
    mkdir -p "$OUT/logs-mut"
    run_decode "$OUT/mut.py" "$OUT/logs-mut"
    mdups=$(find "$OUT/logs-mut/files" -name 'gui-agent-*.log.f*' 2>/dev/null | wc -l)
    [ "$mdups" = 1 ] && ok "seen-to-fail: without the prefix test the second copy is kept again" \
                     || no "seen-to-fail did not fail ($mdups duplicate file(s)) - this suite proves nothing"
    python3 "$ROOT/tools/log-sweep.py" analyze "$OUT/logs-mut" --baseline "$ROOT/mgmt/harness/log-sweep-baseline.json" \
        --out "$OUT/report-mut.json" --summary "$OUT/summary-mut.txt" --since "2026-10-23 19:46:55.000" \
        --label dedup-selftest > "$OUT/analyze-mut.out" 2>&1
    mi=$(python3 -c "
import json;print((json.load(open('$OUT/report-mut.json')).get('metrics') or {}).get('agent_instances'))" 2>/dev/null)
    [ "$mi" = 2 ] && ok "seen-to-fail: and ONE process start then reads as TWO instances (the measured defect)" \
                  || no "seen-to-fail: the duplicated capture reports agent_instances=$mi, expected 2"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed  (fixtures: $OUT)"
[ "$FAIL" -eq 0 ] || exit 1
