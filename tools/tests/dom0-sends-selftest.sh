#!/usr/bin/env bash
# dom0-sends-selftest.sh - the notification ledger, driven in BOTH directions, offline.
#
# Owner, 2026-10-10: "IF I SEE SOMETHING IN DOM0, YOU ARE SUPPOSED TO SEE THE SAME IN LOGS, WITH ONE
# HUNDRED PERCENT CERTAINTY AND ZERO GUESSWORK, ALWAYS." The hole was structural: the send record lived
# only on the guest's private volume, so it died with every disposable AppVM and this side had NOTHING.
#
# A check that has never been seen to FAIL is not evidence, so this drives the failure arm first: a
# guest whose record cannot be read must make the tool exit 1 and the caller fail its cell - never
# record a silent "no sends", which is indistinguishable from "dom0 was told nothing".
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/dom0-sends-selftest.XXXXXX")
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

# ---- the stub guest: a qtest that answers state/push/run without a VM ---------------------------
mk_stub(){ # $1=mode: ok | norecord | halted
  cat > "$T/qtest" <<STUB
#!/bin/bash
mode=$1
case "\$1" in
  state) [ "\$mode" = halted ] && echo "power_state=Halted" || echo "power_state=Running" ;;
  start) exit 0 ;;
  push)  echo "STUB REFUSES 'push': the tool must use pushrun (a real qtest reads push's second" >&2
         echo "argument as another LOCAL file and dies with fstatat(C:\\...))" >&2; exit 2 ;;
  pushrun)
    # the argument shape is asserted here because a stub that ignores it passed a form the first
    # real guest rejected: exactly one argument, an existing local .ps1
    [ \$# -eq 2 ] || { echo "STUB: pushrun wants exactly one script, got \$(( \$# - 1 ))" >&2; exit 2; }
    [ -s "\$2" ] || { echo "STUB: pushrun argument '\$2' is not an existing local file" >&2; exit 2; }
    case "\$2" in *.ps1) ;; *) echo "STUB: pushrun wants a .ps1, got '\$2'" >&2; exit 2 ;; esac
    if [ "\$mode" = norecord ]; then echo "powershell: the term is not recognized" >&2; exit 1; fi
    echo "FILES gui-agent-20261010.log:12345"
    echo "SEND [gui-agent-20261010.log:811] 2026-10-10 20:01:02.111 E UpdateWindowData: QGAWGCDEAF hwnd 0x5071a slot 2: WGC delivered no first frame"
    echo "SEND [gui-agent-20261010.log:812] 2026-10-10 20:01:02.115 I DeafNotifyUser: QGAWGCDEAF user notification for capture-deaf-notepad.exe: QERR_SENT"
    # the AUTHORITATIVE record, in notifyerr.c:266's own format string
    echo "SEND [gui-agent-20261010.log:813] 2026-10-10 20:01:02.120 W NOTIFYERR gui-agent.capture-deaf-notepad.exe sent to dom0 (#1 this boot)"
    echo "SEND [gui-agent-20261010.log:814] 2026-10-10 20:04:55.001 W NOTIFYERR gui-agent.session-changed not sent: gated (service.notify-errors off) - shown as a window instead"
    echo "SEND [qubes-windows-update-20261010.log:44] 2026-10-10 20:03:10 reported 7 update(s) to dom0 qubes.NotifyUpdates (exit 0)"
    echo "BOOT [gui-agent-20261010.log:1] 2026-10-10 20:00:00 Init: version 4.3.36.919"
    echo "SENDS DONE"
    ;;
esac
STUB
  chmod +x "$T/qtest"
}

run_tool(){ # $1=mode -> prints output, returns the tool's rc
  mk_stub "$1"
  QTEST_BIN="$T/qtest" DOM0_SENDS_OUT="$T/out-$1" DOM0_SENDS_LEDGER="$T/ledger.jsonl" \
    bash tools/dom0-sends.sh stubvm "$1" 2>&1
}

# ---- 1. SEEN TO FAIL: the record cannot be read -------------------------------------------------
out=$(run_tool norecord); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | command grep -q "record was NOT read"; then
  ok "missing_record_fails: a guest whose record cannot be read exits 1 and says so"
else
  bad "missing_record_fails: rc=$rc out='$(printf '%s' "$out" | tail -1)' - a silent nothing would read as 'dom0 was told nothing'"
fi
[ -s "$T/ledger.jsonl" ] && bad "missing_record_fails: it wrote to the ledger anyway" \
  || ok "missing_record_fails: nothing was appended to the ledger"

# ---- 2. SEEN TO WORK: the sends land in the ledger, with their routes ---------------------------
out=$(run_tool ok); rc=$?
[ "$rc" = 0 ] && ok "reads_the_record: rc=0 on a guest that answers" || bad "reads_the_record: rc=$rc"
n=$(wc -l < "$T/ledger.jsonl" 2>/dev/null || echo 0)
[ "$n" = 5 ] && ok "ledger_has_every_send: 5 line(s) appended" || bad "ledger_has_every_send: $n line(s), want 5"
for want in QGAWGCDEAF capture-deaf-notepad.exe qubes.NotifyUpdates "sent to dom0 (#1 this boot)" "not sent"; do
  command grep -q "$want" "$T/ledger.jsonl" \
    && ok "ledger_carries_$want" || bad "ledger_carries_$want: absent from the ledger"
done
python3 - "$T/ledger.jsonl" <<'PY' && ok "ledger_is_jsonl_with_route_and_decision" || bad "ledger_is_jsonl_with_route_and_decision"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
assert rows and all(set(r) >= {"pulled_at","vm","file","line","route","decision","text"} for r in rows), rows
assert any(r["route"] == "capture-deaf-notepad.exe" and r["decision"] == "QERR_SENT" for r in rows), \
    "the route and the SEND decision must both be recorded: %r" % rows
assert any(r["route"] == "qubes.NotifyUpdates" for r in rows)
PY

# ---- 3. APPEND-ONLY: a second run never erases the first ----------------------------------------
before=$(wc -l < "$T/ledger.jsonl")
run_tool ok >/dev/null
after=$(wc -l < "$T/ledger.jsonl")
[ "$after" -gt "$before" ] && ok "append_only: a second pull adds ($before -> $after), never replaces" \
  || bad "append_only: $before -> $after, an earlier run's record was lost"

# ---- 4. --no-start never boots a halted guest ---------------------------------------------------
mk_stub halted
out=$(QTEST_BIN="$T/qtest" DOM0_SENDS_OUT="$T/out-ns" DOM0_SENDS_LEDGER="$T/ledger.jsonl" \
      bash tools/dom0-sends.sh stubvm nostart --no-start 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -q "SKIP"; then
  ok "no_start_skips_halted: inside a cell it never boots a guest the harness halted"
else
  bad "no_start_skips_halted: rc=$rc out='$(printf '%s' "$out" | tail -1)'"
fi

echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
