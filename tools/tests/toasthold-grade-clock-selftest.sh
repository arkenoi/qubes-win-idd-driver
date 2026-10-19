#!/usr/bin/env bash
# toasthold-grade-clock-selftest.sh - bridge.log HAS NO DATES, AND THIS QUBE'S CLOCK IS NOT ONE.
#
# mgmt/harness/toast-hold-grade.py joins three sources on seconds: the fire records (the guest's
# Get-Date, with a date), the agent log ([YYYYMMDD.HHMMSS.mmm...], with a date) and bridge.log,
# which carries a TIME OF DAY AND NOTHING ELSE - the real shape, from
# qwt-accept/remainder-5ab316e42d34/work/log-sweep/logs/files/bridge.log:
#   16:32:22 [INFO] HOLD records live (32 slots) - the agent holds each toast's banner until ...
#   16:38:02 [INFO] FWD_RTT guest_id=0 seq=1 ms=11 ok=1
# So a DATE has to be put on those lines, and it used to be put there by dt.datetime.now() - THIS
# process's clock - under the rule "a time of day later than now must have been yesterday".
#
# THE TWO CLOCKS ARE NOT IN PHASE, AND THAT IS MEASURED HERE, NOT ASSUMED. The harness's own log
# for the win11r-thold evidence, bracketed stamp = this qube's `date`, THC stamp = the guest's:
#   [16:11:38] toast-hold[win11r-thold]: ... THC now=2026-10-06 19:11:39.705 tz=00:00:00
#   [20:42:48] toast-hold[win11r-thold]: ... THC now=2026-10-06 23:42:50.226 tz=00:00:00
# three hours AHEAD, guest zone UTC and this qube on UTC+3 - the same pairing clock-sync-selftest.sh
# records for win11r-logvol ("the guest clock was 3 h ahead of the host with its own zone set to
# UTC") and tools/log-sweep.py records for 2026-10-14 ("every cell's guest ran three hours ahead at
# boot, 2249 lines were shifted back"); run health.json carries "boot_skew_s": -10720.
#
# WHAT THAT DOES TO THE GRADE, in both directions, each case below:
#   guest AHEAD  every bridge line is "later than now", so the whole log is dated ONE DAY EARLY: no
#                bridge record is within RECORD_SLACK_S of any fire, every toast reads UNLISTED and
#                the run reports "ungraded" instead of "the instrument is broken" - a grader that
#                correlated nothing (the TOASTHOLDPARSERBLIND shape, 12 of 21 rows, findings/issues.md).
#   host's DAY   the error is +1 day, and then `e.t >= t0 - RECORD_SLACK_S` - the test that BINDS a
#   AHEAD       bridge record to the toast it belongs to - is vacuously true for every record in the
#                log: one stamped a minute BEFORE the toast was fired is credited to it and the row
#                reads PASS. A pass on a correlation that did not happen.
#
# Each case drives the REAL grader over an evidence directory in the real shapes, with this qube's
# clock put in the pairing's phase by TZ (no mocking: dt.datetime.now() reads TZ like any other
# local clock) and the capture's own `THC now=` stamp present or lost, as the case says.
# THGRADE_PY points this at another copy of the grader, which is how the four cases below were seen
# to FAIL against the pre-fix file instead of being asserted to.
set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 2
GRADER="${THGRADE_PY:-mgmt/harness/toast-hold-grade.py}"
[ -r "$GRADER" ] || { echo "ERROR: no grader at $GRADER"; exit 2; }
W="${THGRADECLOCK_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/thgrade-clock-XXXXXX")}"
mkdir -p "$W" || exit 2
pass=0; fail=0
ok(){  pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

# ---- the fixture writer: one evidence dir on a chosen GUEST clock, plus the TZ for this qube -----
cat > "$W/mkfix.py" <<'PYFIX'
#!/usr/bin/env python3
"""Write a toast-hold evidence directory whose GUEST timestamps sit at a chosen place on the guest's
clock, and print the POSIX TZ this qube must run the grader under for the pairing being tested.

Every line shape is copied from a capture, with its provenance beside it - never from a memory of
the format (the selftest that stayed green against a bridge.log the writer had stopped emitting)."""
import argparse, datetime as dt, importlib.util, json, os

ap = argparse.ArgumentParser()
ap.add_argument("--grader", required=True)       # for the identity hash the HOLD record must carry
ap.add_argument("--out", required=True)
ap.add_argument("--host-clock", required=True)   # HH:MM:SS this qube's local clock is put at
ap.add_argument("--skew-s", type=int, default=0) # guest minus host, seconds
ap.add_argument("--guest-days", type=int, default=0)  # guest's DATE minus host's, days
ap.add_argument("--drop-pull-now", action="store_true")
ap.add_argument("--pull-now-with-tz", action="store_true")
ap.add_argument("--record-before-fire", action="store_true")
a = ap.parse_args()

spec = importlib.util.spec_from_file_location("thg", a.grader)
thg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(thg)

# This qube's local clock, put at the case's hour by a fixed-offset zone. The instant chosen is the
# one NEAREST real UTC, so the offset stays inside +/-12 h and the POSIX hh stays legal.
utc = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None, microsecond=0)
hh, mm, ss = (int(x) for x in a.host_clock.split(":"))
want = dt.time(hh, mm, ss)
host = min((dt.datetime.combine(utc.date() + dt.timedelta(days=k), want) for k in (-1, 0, 1)),
           key=lambda t: abs(t - utc))
off = host - utc                                  # local = UTC + off
sign = "+" if off <= dt.timedelta(0) else "-"     # POSIX offset is UTC MINUS local, i.e. inverted
tot = int(abs(off).total_seconds())
posix = "FIX%s%02d:%02d:%02d" % (sign, tot // 3600, (tot % 3600) // 60, tot % 60)

guest_now = host + dt.timedelta(seconds=a.skew_s, days=a.guest_days)
base = guest_now - dt.timedelta(seconds=600)      # the pull stamp is at base+600 = the guest's now
AOFF = dt.timedelta(hours=1)   # the agent log's clock an hour off the guest's local clock (it logs
                               # in another zone): the probe-derived 15-minute offset must absorb it,
                               # so this also keeps tie_clock() in the picture.

def T(s):
    return base + dt.timedelta(seconds=s)

def fmt(t):
    return t.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]

agent, bridge = [], []
def A(s, msg): agent.append((T(s) + AOFF, msg))
def B(s, msg): bridge.append((T(s), msg))

PH = "200aa"    # the clock probe's charmap window - real hwnd, win11r-thold 2026-10-06
H = "10274"     # the shell's banner window - real hwnd and class, win11de-tup 2026-10-19:
                # [20261019.050050.301-4628-I] AddWindow: QGAHELDDEFER hwnd=0x10274
                #   class=Windows.UI.Core.CoreWindow w=396 h=152 t=75843 slicefed=1 brokerslot=1
sync = ("THC sync t_start=%s t_seen=%s hwnd=0x%s pid=6968\n"
        "THC sync t_close=%s t_closed=%s\n" % (fmt(T(-10.0)), fmt(T(-9.4)), PH, fmt(T(-7.9)), fmt(T(-7.2))))
A(-9.6, "SendWindowCreateInternal: QGAPROTO,msg=CREATE,hwnd=0x%s,x=10,y=10,w=600,h=400,ovr=0,style=0x14cf0000,ex=0x00000100" % PH)
A(-9.5, "SendWindowMap: QGAPROTO,msg=MAP,hwnd=0x%s,ovr=0,transient=0x0,style=0x14cf0000,ex=0x00000100,vis=1,w=600,h=400" % PH)
A(-7.8, "SendWindowUnmap: Unmapping window 0x%s" % PH)
A(-7.7, "SendWindowDestroy: QGAPROTO,msg=DESTROY,hwnd=0x%s" % PH)
# the real gate line, gui-agent-20261016.log:
A(-60, "ToastHoldInit: QGATOASTHOLD gate: ACTIVE (bridge gate on, ToastHoldDisable=0, UIA worker up, "
       "IPC up): banners held for their verdict, bound 3000 ms")
# the real bridge lines, same evidence tree (16:32:22 / 16:36:48):
B(-50, "BRIDGE armed allow=[Microsoft.ScreenSketch_8wekyb3d8bbwe!App;Windows.SystemToast.BackupReminder]")
B(-49, "connected (server version 1.0)")
B(-49, "HOLD records live (32 slots) - the agent holds each toast's banner until its record's verdict")

fires = []
def fire(label, s, slug, aumid="QubesToastfire.StartShortcut", cls="informational"):
    fires.append({"label": label, "slug": slug, "aumid": aumid, "cls": cls, "tag": label,
                  "payload_sha256": "ab12", "t0": fmt(T(s)), "t1": fmt(T(s + 0.4)), "rc": 0,
                  "fired": True, "mode": "seamless", "attempt": 1})

# S1a: bridged and never mapped -> OK-BRIDGED (EXPECT[1]["S1a"]), a gating row.
# The HOLD / CLASSIFY / route / SENT shapes are the real ones from
# rel-38629737763-.../logvol-win10-clean/files/qwt-logs/win10-acc/bridge.log (22:59:40).
S1 = "THT-a1b2c3-S1a-t1"
fire("S1a", 0, S1)
i1 = thg.ti_ident("toastfire-QubesToastfire.StartShortcut", S1, "demo body")
RB = -61.0 if a.record_before_fire else 0.0      # a record stamped BEFORE its own fire must not be credited
A(0.8, "AddWindow: QGAHELDDEFER hwnd=0x%s class=Windows.UI.Core.CoreWindow w=396 h=152 t=75843 slicefed=1 brokerslot=1" % H)
A(0.9, "ThCoreStartHold: QGATOASTHOLD hwnd=0x%s state=hold reason=no-identity ident=0000000000000000 "
       "s=0000000000000000 t=0000000000000000 m=0000000000000000 bridgeUp=1 (banner withheld)" % H)
B(1.0 + RB, "HOLD id=101 seq=1 verdict=pending ident=%016x s=%016x t=%016x m=%016x flags=0x0"
      % (i1["c"], i1["s"], i1["t"], i1["m"]))
B(2.0 + RB, "HOLD id=101 verdict=bridge (classifier, was pending)")
B(2.0 + RB, "route id=101 aumid=QubesToastfire.StartShortcut bridge verdict=classifier actions=none")
A(2.1, "ThCoreDecide: QGATOASTHOLD hwnd=0x%s state=suppress ident=%016x id=101 verdict=bridge "
       "held_ms=1200 (forwarded to dom0)" % (H, i1["c"]))
B(3.0 + RB, "FWD_RTT guest_id=101 seq=1 ms=11 ok=1")
B(3.0 + RB, "SENT id=101 app='toastfire' title='%s': OK actions=none" % S1)
B(3.0 + RB, "HOLD id=101 verdict=forwarded")
A(6.5, "SendWindowDestroy: QGAPROTO,msg=DESTROY,hwnd=0x%s" % H)

# S2: the window path - held, shown 1.4 s later, mapped -> OK-WINDOW (EXPECT[1]["S2"]), a gating row.
S2 = "THT-a1b2c3-S2-t1"
fire("S2", 30, S2, cls="realchoice")
i2 = thg.ti_ident("toastfire-QubesToastfire.StartShortcut", S2, "demo body")
A(30.8, "AddWindow: QGAHELDDEFER hwnd=0x%s class=Windows.UI.Core.CoreWindow w=396 h=193 t=75901 slicefed=1 brokerslot=1" % H)
A(30.9, "ThCoreStartHold: QGATOASTHOLD hwnd=0x%s state=hold reason=no-record ident=0000000000000000 "
        "s=0000000000000000 t=0000000000000000 m=0000000000000000 bridgeUp=1 (banner withheld)" % H)
B(31.0 + RB, "HOLD id=102 seq=2 verdict=pending ident=%016x s=%016x t=%016x m=%016x flags=0x0"
        % (i2["c"], i2["s"], i2["t"], i2["m"]))
B(32.0 + RB, "HOLD id=102 verdict=window (classifier, was pending)")
B(32.0 + RB, "skip id=102 aumid=QubesToastfire.StartShortcut (window path; classifier verdict)")
A(32.2, "ThCoreDecide: QGATOASTHOLD hwnd=0x%s state=show ident=%016x id=102 held_ms=1300 "
        "(verdict=window: the banner is the toast)" % (H, i2["c"]))
A(32.3, "SendWindowMap: QGAPROTO,msg=MAP,hwnd=0x%s,ovr=1,transient=0x0,style=0x94000000,ex=0x00200008,vis=1,w=364,h=109" % H)
A(38.3, "SendWindowUnmap: Unmapping window 0x%s" % H)
A(38.4, "SendWindowDestroy: QGAPROTO,msg=DESTROY,hwnd=0x%s" % H)

os.makedirs(a.out, exist_ok=True)
with open(os.path.join(a.out, "agent.log"), "w", encoding="utf-8") as f:
    for t, msg in sorted(agent, key=lambda x: x[0]):
        # the real agent shape: [20261019.050050.301-4628-I] AddWindow: ...
        f.write("[%s-4628-I] %s\n" % (t.strftime("%Y%m%d.%H%M%S.%f")[:-3], msg))
with open(os.path.join(a.out, "bridge.log"), "w", encoding="utf-8") as f:
    for t, msg in sorted(bridge, key=lambda x: x[0]):
        f.write("%s [INFO] %s\n" % (t.strftime("%H:%M:%S"), msg))
with open(os.path.join(a.out, "fires.jsonl"), "w", encoding="utf-8") as f:
    for r in fires:
        f.write(json.dumps(r) + "\n")
open(os.path.join(a.out, "waits.jsonl"), "w").close()
with open(os.path.join(a.out, "sync.txt"), "w", encoding="utf-8") as f:
    f.write(sync)
with open(os.path.join(a.out, "where.txt"), "w", encoding="utf-8") as f:
    f.write("THC where=C:\\Users\\user\\Documents\\QubesIncoming\\win-idd-mgmt\n"
            "THC logdir=Q:\\Qubes Logs agentlog=gui-agent-20261006-191122-1512.log agentlines=2512\n"
            "THC bridgelog=Q:\\Qubes Logs\\bridge.log exists=1 bridgelines=470\n"
            "THC now=%s tz=00:00:00\n" % fmt(T(-20)))
meta = {"hold_build": 1, "run_id": "clockfix", "package_version": "4.3.37+agent.fixture",
        "driver_repo_commit": "deadbeef", "subject": "win11r-thold"}
if not a.drop_pull_now:
    meta["pull_now"] = fmt(T(600)) + (" tz=00:00:00" if a.pull_now_with_tz else "")
with open(os.path.join(a.out, "meta.json"), "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2)
print("FIXTURE tz=%s host_local=%s guest_base=%s" % (posix, host.strftime("%Y-%m-%d %H:%M:%S"),
                                                     base.strftime("%Y-%m-%d %H:%M:%S")))
PYFIX

n=0
mk(){ # $1=case dir name, rest = mkfix args -> sets TZ, DIR; prints nothing
  n=$((n+1)); DIR="$W/$1"; rm -rf "$DIR"
  local out
  out=$(python3 "$W/mkfix.py" --grader "$GRADER" --out "$DIR" "${@:2}") || return 1
  TZ=$(printf '%s\n' "$out" | sed -n 's/^FIXTURE tz=\([^ ]*\).*/\1/p')
  FIXLINE="$out"
  [ -n "$TZ" ]
}
grade(){ # grades $DIR under $TZ -> rows on stdout
  TZ="$TZ" python3 "$GRADER" --grade --out "$DIR" 2>&1
}
cls(){ # $1=rows $2=label -> the verdict word plus the class ("PASS OK-BRIDGED"); on an ungraded row the
       # class is not on the line (grade() prints "INSTRUMENT <text>"), so the first two words are the head
  printf '%s\n' "$1" | sed -n "s/^$2|//p" | head -1 | awk '{print $1, $2}'
}

# ---- 1. the reference the design asks for: the capture's own `THC now=` stamp -------------------
# Phase-identical and stamped: the baseline every skewed case is compared against. If this does not
# pass, nothing below means anything.
mk base --host-clock 12:00:00 --skew-s 0 || { bad "baseline fixture did not build"; exit 1; }
BASEROWS=$(grade)
B_S1A=$(cls "$BASEROWS" S1a); B_S2=$(cls "$BASEROWS" S2)
B_VERDICT=$(printf '%s\n' "$BASEROWS" | sed -n 's/^GRADED|.*-> //p' | head -1)
if [ "$B_S1A" = "PASS OK-BRIDGED" ] && [ "$B_S2" = "PASS OK-WINDOW" ] && [ "${B_VERDICT:0:4}" = PASS ]; then
  ok "stamped_baseline: S1a='$B_S1A' S2='$B_S2' run='$B_VERDICT' ($FIXLINE)"
else
  bad "stamped_baseline: S1a='$B_S1A' S2='$B_S2' run='$B_VERDICT' - expected PASS OK-BRIDGED / PASS OK-WINDOW / PASS"
fi
if printf '%s\n' "$BASEROWS" | command grep -qa '^CLOCK-REF|PASS .*pull_now'; then
  ok "stamped_baseline_names_its_reference: CLOCK-REF PASS names meta.json pull_now"
else
  bad "stamped_baseline_names_its_reference: $(printf '%s\n' "$BASEROWS" | command grep -a '^CLOCK-REF|' | head -1 | cut -c1-140)"
fi

# ---- 2. THE MEASURED PAIRING: the guest 3 h ahead, and the pull's stamp lost ---------------------
# This qube at 12:00, the guest at 15:00 the same day - the win11r-thold phase. The join is between
# the guest's own sources only, so every class must be the one case 1 produced.
mk ahead3h --host-clock 12:00:00 --skew-s 10800 --drop-pull-now || { bad "ahead3h fixture"; exit 1; }
R=$(grade)
S1A=$(cls "$R" S1a); S2=$(cls "$R" S2)
if [ "$S1A" = "$B_S1A" ] && [ "$S2" = "$B_S2" ]; then
  ok "guest_3h_ahead_no_stamp: dated from the capture, classes unchanged (S1a='$S1A' S2='$S2'; $FIXLINE)"
else
  bad "guest_3h_ahead_no_stamp: S1a='$S1A' S2='$S2', baseline was '$B_S1A' / '$B_S2' - bridge.log was dated from the wrong clock ($FIXLINE)"
fi
if printf '%s\n' "$R" | command grep -qa '^CLOCK-REF|INSTRUMENT .*absent'; then
  ok "lost_stamp_is_loud: CLOCK-REF INSTRUMENT says the pull's own stamp is absent, so the run does not close"
else
  bad "lost_stamp_is_loud: a lost \`THC now=\` must be said out loud - got '$(printf '%s\n' "$R" | command grep -a '^CLOCK-REF|' | head -1 | cut -c1-160)'"
fi

# ---- 3. the guest 3 h ahead ACROSS ITS OWN MIDNIGHT ---------------------------------------------
# This qube at 21:00, the guest at 00:00 the next day: the run's bridge lines straddle the guest's
# midnight, so the backwards walk has to put them on two different dates - with a reference that is
# itself before the wrap. Dating them all from this qube's date gets both sides wrong.
mk midnight --host-clock 21:00:00 --skew-s 10800 --drop-pull-now || { bad "midnight fixture"; exit 1; }
R=$(grade)
S1A=$(cls "$R" S1a); S2=$(cls "$R" S2)
if [ "$S1A" = "$B_S1A" ] && [ "$S2" = "$B_S2" ]; then
  ok "guest_midnight_wrap: classes unchanged across the guest's midnight (S1a='$S1A' S2='$S2'; $FIXLINE)"
else
  bad "guest_midnight_wrap: S1a='$S1A' S2='$S2', baseline was '$B_S1A' / '$B_S2' ($FIXLINE)"
fi

# ---- 4. THE OTHER DIRECTION: this qube's calendar day ahead of the guest's ----------------------
# A guest resumed with a stale clock (its date a day behind this qube's). The toast's bridge record
# is stamped 60 s BEFORE the toast was fired, so it is NOT this toast's record and the row must read
# INSTRUMENT/UNLISTED. Dated from this qube's clock the record lands a day AFTER the fire, which
# satisfies `e.t >= t0 - RECORD_SLACK_S` vacuously - and the row reads PASS OK-BRIDGED instead.
mk dayahead --host-clock 12:00:00 --skew-s 0 --guest-days -1 --drop-pull-now --record-before-fire \
  || { bad "dayahead fixture"; exit 1; }
R=$(grade)
S1A=$(cls "$R" S1a)
S2R=$(cls "$R" S2)
# the UNLISTED text: "the bridge never listed <slug> (no HOLD record with t=..., no SENT title, no skip ...)"
if printf '%s\n' "$R" | command grep -qa '^S1a|INSTRUMENT the bridge never listed ' \
   && printf '%s\n' "$R" | command grep -qa '^S2|INSTRUMENT the bridge never listed '; then
  ok "record_before_its_fire_not_credited: S1a='$S1A' S2='$S2R' ($FIXLINE)"
else
  bad "record_before_its_fire_not_credited: S1a='$S1A' S2='$S2R' - a bridge record stamped 61 s before its own fire was credited to it ($FIXLINE)"
fi

# ---- 5. the `where`-mode stamp shape must not read as "no stamp at all" -------------------------
# toast-hold-collect.ps1 prints `THC now=<ts> tz=<offset>` in where mode and `THC now=<ts>` in pull
# mode. The suffixed shape used to make strptime raise, the exception was swallowed, and the answer
# came from this qube's clock - a silent fallback with no line anywhere. Same 3 h pairing.
mk tzsuffix --host-clock 12:00:00 --skew-s 10800 --pull-now-with-tz || { bad "tzsuffix fixture"; exit 1; }
R=$(grade)
S1A=$(cls "$R" S1a); S2=$(cls "$R" S2)
if [ "$S1A" = "$B_S1A" ] && [ "$S2" = "$B_S2" ] && printf '%s\n' "$R" | command grep -qa '^CLOCK-REF|PASS'; then
  ok "stamp_with_tz_suffix_accepted: S1a='$S1A' S2='$S2', CLOCK-REF PASS"
else
  bad "stamp_with_tz_suffix_accepted: S1a='$S1A' S2='$S2' CLOCK-REF='$(printf '%s\n' "$R" | command grep -a '^CLOCK-REF|' | head -1 | cut -c1-120)'"
fi

# ---- 6. no reference at all is a REFUSAL, not a guess ------------------------------------------
# The structural half of the fix: with nothing to date bridge.log from, the parser raises instead of
# reaching for a clock of its own. A guard never seen to fire is decoration, so it is fired here.
REF=$(python3 - "$GRADER" <<'PY' 2>&1
import datetime as dt, importlib.util, sys
spec = importlib.util.spec_from_file_location("thg", sys.argv[1])
thg = importlib.util.module_from_spec(spec); spec.loader.exec_module(thg)
lines = ["16:32:22 [INFO] connected (server version 1.0)",
         "16:38:02 [INFO] FWD_RTT guest_id=101 seq=1 ms=11 ok=1"]
try:
    evs = thg.parse_bridge(lines, None)
except Exception as e:
    print("RAISED %s" % type(e).__name__); sys.exit(0)
print("DATED %s from a clock of its own" % (evs[0].t if evs else "nothing"))
PY
)
case "$REF" in
  "RAISED NoBridgeReference") ok "no_reference_refuses: parse_bridge(lines, None) raises NoBridgeReference" ;;
  *) bad "no_reference_refuses: $REF - a dateless log was dated without a reference" ;;
esac
# ...and the grader's own path says so in a row rather than crashing.
mk noref --host-clock 12:00:00 --skew-s 10800 --drop-pull-now || { bad "noref fixture"; exit 1; }
: > "$DIR/sync.txt"
python3 - "$DIR" <<'PY'
import json, sys, os
# strip every guest instant the capture carries: no pull stamp, no probe stamp, no fire stamp
p = os.path.join(sys.argv[1], "fires.jsonl")
rows = [json.loads(l) for l in open(p) if l.strip()]
for r in rows:
    r["t0"] = r["t1"] = ""
open(p, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
R=$(grade); rc=$?
if printf '%s\n' "$R" | command grep -qa '^CLOCK-REF|INSTRUMENT .*no instant on the guest.s clock' \
   && printf '%s\n' "$R" | command grep -qa '^GRADED|INSTRUMENT' && [ "$rc" -ne 0 ]; then
  ok "no_reference_in_capture_is_ungraded: CLOCK-REF INSTRUMENT, nothing graded, rc=$rc"
else
  bad "no_reference_in_capture_is_ungraded: rc=$rc rows='$(printf '%s\n' "$R" | command grep -a '^\(CLOCK-REF\|GRADED\)|' | cut -c1-140 | tr '\n' ';')'"
fi

# ---- 7. --ref-now is the documented way back for a dir whose stamp is gone ----------------------
mk refarg --host-clock 12:00:00 --skew-s 10800 --drop-pull-now || { bad "refarg fixture"; exit 1; }
RN=$(python3 - "$DIR" <<'PY'
import json, sys, os, datetime as dt
rows = [json.loads(l) for l in open(os.path.join(sys.argv[1], "fires.jsonl")) if l.strip()]
t = max(dt.datetime.strptime(r["t1"], "%Y-%m-%d %H:%M:%S.%f") for r in rows)
print((t + dt.timedelta(seconds=560)).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])
PY
)
R=$(TZ="$TZ" python3 "$GRADER" --grade --out "$DIR" --ref-now "$RN" 2>&1)
S1A=$(cls "$R" S1a); S2=$(cls "$R" S2)
V=$(printf '%s\n' "$R" | sed -n 's/^GRADED|.*-> //p' | head -1)
if [ "$S1A" = "$B_S1A" ] && [ "$S2" = "$B_S2" ] && [ "${V:0:4}" = PASS ]; then
  ok "ref_now_closes_the_run: --ref-now '$RN' -> S1a='$S1A' S2='$S2' run='$V'"
else
  bad "ref_now_closes_the_run: S1a='$S1A' S2='$S2' run='$V'"
fi
if TZ="$TZ" python3 "$GRADER" --grade --out "$DIR" --ref-now "not a time" >/dev/null 2>&1; then
  bad "ref_now_rejects_junk: --ref-now 'not a time' was accepted"
else
  ok "ref_now_rejects_junk: a --ref-now that is not a guest timestamp exits non-zero"
fi

# ---- 8. the grader's own fixture matrix still holds -----------------------------------------------
if python3 "$GRADER" --selftest > "$W/selftest.txt" 2>&1; then
  ok "grader_selftest: $(tail -1 "$W/selftest.txt")"
else
  bad "grader_selftest: $(tail -1 "$W/selftest.txt") - see $W/selftest.txt"
fi

echo
echo "toasthold-grade-clock-selftest: $pass passed, $fail failed; fixtures in $W"
[ "$fail" = 0 ] || exit 1
