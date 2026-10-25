#!/usr/bin/env bash
# sweep-window-selftest.sh - A --since WINDOW THE GUEST CANNOT SEE INTO, and what the filter excluded.
# No guest, no rig: the collector runs under a Linux pwsh against a temp directory, and the analyzer
# runs over a hand-built stream.
#
# WHY THIS EXISTS. MEASURED, campaign 1025-0050 (the night of the EU DST transition). Four cells were
# collected with since=2026-10-25T00:54:47Z while the guests' own clocks read 00:10 to 00:34 - 20 to
# 44 minutes BEFORE the start of the window they were handed. log-sweep-collect.ps1 filters on
# LastWriteTimeUtc >= $sinceU using THAT clock, so no file any of those guests had ever written could
# satisfy it; each sweep then graded the handful of files the gui-agent/gui-watchdog `$always`
# exemption carries through regardless, and reported a quiet, complete-looking corpus.
#
# TWO SEPARATE DEFECTS, one leg each way for both:
#
# 1. THE WINDOW WAS NEVER CHECKED AGAINST THE CLOCK THAT APPLIES IT. The existing `clockskew` check
#    needs --host-utc, a SECOND clock recorded on the host side; it let the worst cell of the four
#    (win10-clean, -3604 s) through because the phase correction satisfied it. The check asserted
#    here needs nothing but the collector's own BEGIN line, which already carried both numbers:
#    `nowutc` (the guest's UTC at collection) and `since` (the window it was handed). now < since is
#    not a skew to tolerate - it is a window that cannot match anything.
#
# 2. THE FILTER REPORTED NOTHING ABOUT WHAT IT EXCLUDED. The stream said the directory held files and
#    the stream carried files, and the difference appeared nowhere: it had to be counted by hand off
#    INVENTORY against the FILE lines - and those two count DIFFERENT populations (INVENTORY is
#    non-recursive *.log; the collection is recursive over .log/.txt/.json/.old, windowed), so that
#    subtraction was never arithmetic anyone should have trusted. 17 against 12 was read as "5
#    dropped" and the real number was not knowable from the capture at all.
#
# A WINDOW EXCLUDING OLD FILES IS NORMAL and the accounting is NOT a verdict - asserted below as
# n=0 still being emitted, and as a drop count alone never raising a problem. It is the number the
# analyzer needs to say how much damage an unusable window did.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T="$(mktemp -d "${TMPDIR:-/tmp}/sweep-window-XXXXXX")"
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT
PASS=0; FAIL=0
ok(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
# Overrides, THIS SUITE ONLY: they exist so the suite can be pointed at the pre-fix collector and
# analyzer and SEEN RED. Run against HEAD~ both halves fail; that is the receipt that these legs
# are load-bearing rather than a description of code that already passes.
C="${SWEEP_COLLECT:-$ROOT/mgmt/harness/log-sweep-collect.ps1}"
A="${SWEEP_ANALYZER:-$ROOT/tools/log-sweep.py}"
BASE="$ROOT/mgmt/harness/log-sweep-baseline.json"

# ---- 1. SOURCE: the accounting is emitted UNCONDITIONALLY ---------------------------------------
# Skipping comments, because this file's own prose and the collector's both name the marker, and an
# assertion that matched its explanation would pass over a collector that never emits it.
CODE=$(command grep -av '^[[:space:]]*#' "$C")
if printf '%s' "$CODE" | command grep -qa 'DROPPED reason=window'; then
  ok "the collector emits an LSW DROPPED line"
  # NOT inside an `if ($dropWindow -gt 0)`: "0 dropped" and "this collector cannot say" are
  # different facts, and an analyzer that cannot tell them apart reads an old capture as a clean
  # one. FILESKIPPED is conditional for its own reason (a cap that did not fire is not a fact about
  # the corpus); this one is not, and that is the property under test.
  # NESTED DELIBERATELY: run against a collector with no marker at all, this leg's grep matches
  # nothing and it reported "emitted unconditionally" about code that emits nothing - a PASS on
  # absent code, which is how it read on the first run against HEAD~.
  if printf '%s' "$CODE" | command grep -B3 -a 'DROPPED reason=window' | command grep -qa 'if ($dropWindow'; then
    no "the DROPPED line is conditional - a capture with nothing dropped would be indistinguishable from one that cannot say"
  else
    ok "it is emitted unconditionally, so n=0 is distinguishable from an older collector"
  fi
else
  no "no DROPPED marker in the collector - what the window excluded is unreported"
fi

# ---- 2. THE COLLECTOR, EXECUTED: the real filter over real files --------------------------------
PW=""
for p in /home/user/pwsh74/pwsh /home/user/bin/pwsh7/pwsh /home/user/pwsh/pwsh "$(command -v pwsh 2>/dev/null)"; do
  [ -n "$p" ] && [ -x "$p" ] && { PW="$p"; break; }
done
if [ -z "$PW" ]; then
  echo "note no pwsh on this host - the collector was not executed; the source assertions above still ran"
else
  # three OLD plain logs (must be dropped), two NEW (must be kept), and one OLD gui-agent- which the
  # `$always` exemption keeps REGARDLESS of the window - that one must NOT be counted as a drop,
  # because a file deliberately carried through is not a file the window excluded.
  cout=$("$PW" -NoProfile -Command '
    $T = Join-Path "'"$T"'" "guest"
    $env:SystemDrive = $T
    $d = Join-Path $T "Qubes Logs"
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    foreach ($n in @("old-a.log","old-b.log","old-c.log","gui-agent-1.log")) {
      Set-Content -LiteralPath (Join-Path $d $n) -Value "[20261025.001000.000-1-I] LogInit: Log started, module name: x"
      (Get-Item -LiteralPath (Join-Path $d $n)).LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-5)
    }
    foreach ($n in @("new-a.log","new-b.log")) {
      Set-Content -LiteralPath (Join-Path $d $n) -Value "[20261025.004000.000-1-I] LogInit: Log started, module name: y"
    }
    $since = [datetime]::UtcNow.AddHours(-1).ToString("yyyy-MM-ddTHH:mm:ss") + "Z"
    & "'"$C"'" -SinceUtc $since -NoEvents 2>$null | Where-Object { $_ -like "LSW DROPPED*" -or $_ -like "LSW END*" }
  ' 2>&1)
  drop=$(printf '%s' "$cout" | command grep -a '^LSW DROPPED' | head -1)
  if [ -n "$drop" ]; then
    seen=$(printf '%s' "$drop" | command sed -n 's/.*seen=\([0-9]*\).*/\1/p')
    kept=$(printf '%s' "$drop" | command sed -n 's/.*kept=\([0-9]*\).*/\1/p')
    nn=$(printf '%s' "$drop"  | command sed -n 's/.* n=\([0-9]*\).*/\1/p')
    # `| while read -r b` DROPS THE LAST NAME: the final element has no trailing newline, read
    # returns false and the body never runs for it. Caught by this suite's own evidence line
    # printing two of three names while the count said three - the exact class of silent
    # shortening the accounting exists to end. printf adds the newline; the names are a for-loop
    # over the comma split instead.
    names=""
    for b in $(printf '%s' "$drop" | command sed -n 's/.*namesb64=\([A-Za-z0-9+/=,]*\).*/\1/p' | tr ',' ' '); do
      names="$names$(printf '%s' "$b" | base64 -d 2>/dev/null) "
    done
    [ "$seen" = 6 ] && ok "the filter reports what it EXAMINED (seen=6, all six files)" \
                    || no "seen is wrong" "seen='$seen' want 6 ($drop)"
    [ "$nn" = 3 ] && ok "and what it EXCLUDED: n=3, the three old plain logs" \
                  || no "the drop count is wrong" "n='$nn' want 3 ($drop)"
    [ "$kept" = 3 ] && ok "and what it KEPT: kept=3 (two in-window + the exempt agent log)" \
                    || no "the kept count is wrong" "kept='$kept' want 3 ($drop)"
    # EVERY name, not "a name": a list shortened to its first element would satisfy a single match
    # and is indistinguishable from a complete one in the report.
    miss=""
    for want in old-a.log old-b.log old-c.log; do
      case " $names " in *" $want "*) ;; *) miss="$miss $want" ;; esac
    done
    if [ -n "$miss" ]; then
      no "the dropped names are incomplete" "missing:$miss  got='$names' (n=$nn claimed)"
    else
      case " $names " in
        *" gui-agent-1.log "*) no "the \$always exemption is counted as a window drop" "names='$names' - a file deliberately carried through is not one the window excluded" ;;
        *) ok "all three excluded names are carried, and the \$always-exempt agent log is NOT among them ($names)" ;;
      esac
    fi
  else
    no "the collector emitted no DROPPED line when run" "$(printf '%s' "$cout" | head -3 | tr '\n' ' ')"
  fi
  # n=0 STILL EMITTED: the same run with a window old enough to admit everything.
  zout=$("$PW" -NoProfile -Command '
    $T = Join-Path "'"$T"'" "guest0"
    $env:SystemDrive = $T
    $d = Join-Path $T "Qubes Logs"
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Set-Content -LiteralPath (Join-Path $d "fresh.log") -Value "[20261025.004000.000-1-I] LogInit: Log started, module name: y"
    & "'"$C"'" -SinceUtc ([datetime]::UtcNow.AddHours(-9).ToString("yyyy-MM-ddTHH:mm:ss") + "Z") -NoEvents 2>$null |
      Where-Object { $_ -like "LSW DROPPED*" }
  ' 2>&1)
  if printf '%s' "$zout" | command grep -qa '^LSW DROPPED reason=window seen=1 kept=1 n=0'; then
    ok "with nothing excluded it STILL reports (n=0) - a fact, not an absence"
  else
    no "nothing dropped produced no accounting" "$(printf '%s' "$zout" | head -2 | tr '\n' ' ')"
  fi
fi

# ---- 3. THE ANALYZER: a stream whose clock cannot see into its own window ------------------------
# builds pull.txt with a chosen nowutc/since pair, optionally with the DROPPED marker
mkstream(){ # <dir> <nowutc> <since> <dropped-n|-> [newest-iso|none|-] [capped]
  python3 - "$1" "$2" "$3" "$4" "${5:--}" "${6:-0}" <<'PY'
import base64, hashlib, os, sys
out, nowutc, since, dropn = sys.argv[1:5]
# newestdropped/capped are OPTIONAL so the "old collector" case stays expressible: a '-' means
# the marker carries no newestdropped= field at all, which is exactly what a pre-2026-10-25
# capture looks like.
newest = sys.argv[5] if len(sys.argv) > 5 else "-"
capped = sys.argv[6] if len(sys.argv) > 6 else "0"
os.makedirs(out, exist_ok=True)
text = ("[20261025.031000.000-1-I] LogInit: Log started, module name: gui-agent\n"
        "[20261025.031000.000-1-I] LogInit: Running as user: SYSTEM, process ID: 1\n"
        "[20261025.031000.000-1-I] LogInit: Module version: 4.3.37.800\n")
raw = text.encode(); b64 = base64.b64encode(raw).decode()
chunks = [b64[i:i+64] for i in range(0, len(b64), 64)] or [""]
nl = len(text.split("\n"))
L = ["LSW BEGIN v=1 now=2026-10-25T03:10:42.858 nowutc=%s tz=+03:00 host=%s user=%s session=1 "
     "since=%s sincelocal=2026-10-25T03:54:47" % (nowutc, base64.b64encode(b"WIN10-ACC").decode(),
                                                  base64.b64encode(b"NT AUTHORITY\\SYSTEM").decode(), since),
     "LSW LOGDIR pathb64=%s exists=1" % base64.b64encode(r"Q:\Qubes Logs".encode()).decode()]
if dropn != "-":
    nms = ",".join(base64.b64encode(n.encode()).decode() for n in ("etw-proxy.log", "bridge.log"))
    extra = "" if newest == "-" else " newestdropped=%s capped=%s" % (newest, capped)
    L.append("LSW DROPPED reason=window seen=%d kept=1 n=%s%s namesb64=%s"
             % (1 + int(dropn), dropn, extra, nms))
L.append("LSW FILE id=f1 pathb64=%s family=agent bytes=%d lines=%d written=2026-10-25T03:10:00.000 "
         "created=2026-10-25T03:10:00.000 partial=0 total_lines=%d"
         % (base64.b64encode(r"Q:\Qubes Logs\gui-agent-20261025-031000-1.log".encode()).decode(), len(raw), nl, nl))
L.append("LSW PULL name=f1 lines=%d bytes=%d sha256=%s b64lines=%d" % (nl, len(raw), hashlib.sha256(raw).hexdigest(), len(chunks)))
L += ["LSW B|" + c for c in chunks]
L.append("LSW PULLEND name=f1 b64lines=%d" % len(chunks))
L.append("LSW END files=1 pulled=1 errors=0 event_errors=0")
open(os.path.join(out, "pull.txt"), "w", encoding="utf-8").write("\n".join(L) + "\n")
PY
}
analyze(){ # <tag> <nowutc> <since> <dropped-n|-> [newest|-] [capped] -> rc; kinds/summary as before
  local tag="$1"
  mkstream "$T/$tag" "$2" "$3" "$4" "${5:--}" "${6:-0}"
  python3 "$A" decode "$T/$tag/pull.txt" --out "$T/$tag/logs" >"$T/$tag.decode" 2>&1
  python3 "$A" analyze "$T/$tag/logs" --baseline "$BASE" --out "$T/$tag.json" --summary "$T/$tag.txt" \
    --label "$tag" --since "${3%Z}" --no-jev >"$T/$tag.out" 2>&1
  local rc=$?
  python3 -c "
import json,sys
r=json.load(open(sys.argv[1]))
print(' '.join(p[0] for p in r['data_problems']))" "$T/$tag.json" > "$T/$tag.kinds" 2>/dev/null || : > "$T/$tag.kinds"
  echo "$rc"
}

# THE CASE THAT HAPPENED: nowutc 44 min BEFORE since, and NO --host-utc anywhere.
rc=$(analyze unusable "2026-10-25T00:10:42.858Z" "2026-10-25T00:54:47Z" 5)
if command grep -qa windowunusable "$T/unusable.kinds" && [ "$rc" = 3 ]; then
  ok "a collector clock BEFORE the start of its own window is a DATA problem (rc=3), with no --host-utc given"
else
  no "the unusable window was absorbed" "rc=$rc kinds='$(cat "$T/unusable.kinds")'"
fi
if command grep -qa '2644 s BEFORE' "$T/unusable.txt"; then
  ok "...and it states the distance, so the fix is obvious from the report alone"
else
  no "the problem does not say how far before" "$(command grep -a windowunusable "$T/unusable.txt" | head -1)"
fi
if command grep -qa '5 file(s) dropped by this filter' "$T/unusable.txt"; then
  ok "...and names how much the window cost: the filter's own drop count, not a subtraction"
else
  no "the drop count is absent from the problem" "$(command grep -a windowunusable "$T/unusable.txt" | head -1)"
fi

# SEEN TO FAIL THE OTHER WAY: a guest whose clock is AHEAD of the window start, which is every
# healthy capture. Verified on a real one (/home/user/qwt-sup/1024-2048, +16 s): CLEAN rc=0.
rc=$(analyze healthy "2026-10-25T04:00:00.000Z" "2026-10-25T00:54:47Z" 5)
if ! command grep -qa windowunusable "$T/healthy.kinds"; then
  ok "a clock AHEAD of the window start reports nothing (no false positive)"
else
  no "a healthy window was called unusable" "kinds='$(cat "$T/healthy.kinds")'"
fi
# AND THE ACCOUNTING ALONE IS NOT A VERDICT: that same healthy stream dropped 5 files by its window,
# which is what a window is FOR. If a drop count could fail a run, every sweep with a window fails.
if ! command grep -qa 'windowunusable\|dropped' "$T/healthy.kinds"; then
  ok "excluding old files is NORMAL: 5 dropped raises no problem on a usable window"
else
  no "the drop count itself failed the run" "kinds='$(cat "$T/healthy.kinds")'"
fi

# ---- 4. THE REPORT: the difference is visible without subtracting two populations ---------------
if command grep -qa 'WINDOW FILTER: examined 6 file(s), kept 1, excluded 5' "$T/healthy.txt"; then
  ok "the report states examined/kept/excluded from the filter's own count"
else
  no "the report does not carry the filter accounting" "$(command grep -a 'WINDOW FILTER' "$T/healthy.txt" | head -1)"
fi
if command grep -qa 'WINDOW FILTER.*etw-proxy.log' "$T/healthy.txt"; then
  ok "...and names what it excluded, so a missing log is traceable to the window that dropped it"
else
  no "the excluded names are not in the report" "$(command grep -a 'WINDOW FILTER' "$T/healthy.txt" | head -1)"
fi
# AN OLD CAPTURE MUST NOT READ AS A CLEAN ONE. Same stream, no DROPPED marker at all.
rc=$(analyze noacct "2026-10-25T04:00:00.000Z" "2026-10-25T00:54:47Z" -)
if command grep -qa 'WINDOW FILTER: this stream predates the drop accounting' "$T/noacct.txt"; then
  ok "a stream without the accounting says so - missing data, never zero"
else
  no "an old stream reads as though nothing was dropped" "$(command grep -a 'WINDOW FILTER' "$T/noacct.txt" | head -1)"
fi
if ! command grep -qa 'file(s) dropped by this filter' "$T/noacct.txt"; then
  ok "...and no drop figure is invented for it"
else
  no "a drop figure appeared for a stream that never reported one" "$(command grep -a 'dropped by this filter' "$T/noacct.txt" | head -1)"
fi

echo
# ---------------------------------------------------------------------------------------------
# THE NEWEST EXCLUDED STAMP. A name list can always be truncated, so it is the wrong instrument
# for "was anything from THIS run dropped?"; one stamp that no cap can shorten is the right one.
# Driven BOTH ways, plus the old-collector case, because a check only seen to pass is decoration.
rc=$(analyze newestold "2026-10-25T04:00:00.000Z" "2026-10-25T03:00:00Z" 165 "2026-10-25T02:59:59Z" 125)
if ! command grep -qa dropnewestinwindow "$T/newestold.kinds" \
   && command grep -qa 'nothing written during this run was excluded' "$T/newestold.txt"; then
  ok "165 exclusions whose NEWEST is older than the window raise no problem, and the report says why"
else
  no "a wholly-old exclusion set was treated as suspicious" "rc=$rc kinds='$(cat "$T/newestold.kinds")'"
fi
if command grep -qa 'not recorded: the collector samples 40' "$T/newestold.txt"; then
  ok "...and the name list is disclosed as a SAMPLE (capped=125), not read as the whole set"
else
  no "the truncated name list was presented as complete" "$(command grep -a 'WINDOW FILTER' "$T/newestold.txt" | head -1)"
fi

rc=$(analyze newestin "2026-10-25T04:00:00.000Z" "2026-10-25T03:00:00Z" 4 "2026-10-25T03:30:00Z" 0)
if command grep -qa dropnewestinwindow "$T/newestin.kinds"; then
  ok "a newest-excluded stamp INSIDE the window is a problem - the filter's own predicate forbids it"
else
  no "a file written during the run was dropped and nothing said so" "rc=$rc kinds='$(cat "$T/newestin.kinds")'"
fi

rc=$(analyze newestmissing "2026-10-25T04:00:00.000Z" "2026-10-25T03:00:00Z" 165)
if ! command grep -qa dropnewestinwindow "$T/newestmissing.kinds" \
   && command grep -qa 'CANNOT be answered from it' "$T/newestmissing.txt"; then
  ok "an OLD collector's capture says it cannot answer, instead of reading as a clean one"
else
  no "a pre-newest capture was absorbed as proof that nothing in-window was dropped" \
     "rc=$rc $(command grep -a 'WINDOW FILTER' "$T/newestmissing.txt" | head -1)"
fi

printf 'sweep-window-selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
