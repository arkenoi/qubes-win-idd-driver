#!/usr/bin/env bash
# wu-judge-levelprefix-selftest.sh - the WU pass judge must read EVERY level form the writer emits.
#
# WHY. tools/wu-pass-judge.py decided "did this pass tell dom0 the truth" from
#     ERROR = re.compile(r"^ERROR:\s*(.+)$")
# anchored at the FRONT of the message. On 2026-10-14 e4162c79 ("read the severity the writer
# declared") changed the writer to put its level exactly there: guest/qubes-windows-update.ps1 now
# emits `Log "[ERROR] $($script:St.error)"`. "[ERROR] " does not match "^ERROR:", so every error
# line went invisible at once - and `errors` is what drives silent, contradictory AND whether Jev is
# consulted at all. One unmatched prefix turned the whole judge off, in silence.
#
# IT HAPPENED FOR REAL, in a release gate. Release 4.3.36's template-update cell ran 7 Windows
# Update rounds on win11de-tup that all died in Ensure-Proxy without reporting to dom0, and the
# judge graded them "errored=0 silent=0 verdict: PASS" three times; the cell reported
# "DONE: rounds=3 fails=0". A guest whose updater was dead passed the gate for three days.
#
# The fixtures below are VERBATIM captured lines - the 4.3.36 round-1 capture and the German 25H2
# evidence capture - not constructed ones. A grader only ever run on its author's fixtures grades
# the author.
#
# Legs: no env = clean, every check must PASS. WUPASS_DEFECT=levelprefix restores the 2026-10-14
# blindness and the bracketed-form checks must then FAIL and only those.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
J="${WU_JUDGE:-$HERE/tools/wu-pass-judge.py}"
[ -f "$J" ] || { echo "FAIL  $J missing - nothing ran (missing data fails)"; exit 2; }
case "${WUPASS_DEFECT:-}" in ""|levelprefix|vanished|classnoop|silent) ;; *) echo "FAIL  unknown WUPASS_DEFECT='$WUPASS_DEFECT'"; exit 2 ;; esac
D=$(mktemp -d); trap 'rm -rf -- "$D"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

# judge <fixture> -> prints "rc=<n> errored=<n> silent=<n> contradictory=<n>" plus the FAIL text
judge(){ local o; o=$(python3 "$J" --agent-log "$1" --no-judge 2>&1); local r=$?
         printf 'rc=%s %s\n%s\n' "$r" \
           "$(printf '%s' "$o" | grep -o 'errored=[0-9]* ' | tr -d ' ')" \
           "$(printf '%s' "$o" | grep -E 'facts:|FAIL|FLAG|verdict:')"; }

# ---- fixture 1: VERBATIM qwt-accept/rel-38994277148/template-update.d/wu-e2e/round1/agent.log
# The pass the release gate passed. Note ERROR-SITE and ERROR-STACK: the SAME failure's
# continuation lines, which must not be counted as further errors.
cat > "$D/bracketed.log" <<'EOF'
07:47:01 VM class (live from qubesdb): TemplateVM
07:47:02 relay started: pid 4152, start 2026-10-17T07:47:02, parent 7568 - owned by handle; this pass stops this one and no other
07:47:07 relay pid 4152 is not accepting connections on 127.0.0.1:8082 within 3 s - stopping THAT relay (by its handle) and starting another
07:47:07 relay pid 4152 stopped by this pass (exit code -1)
07:47:08 relay started: pid 4328, start 2026-10-17T07:47:08, parent 7568 - owned by handle; this pass stops this one and no other
07:47:12 [ERROR] relay pid 4328 still not accepting connections on 127.0.0.1:8082 after respawn
07:47:12 ERROR-SITE line 619: if (-not (Test-RelayListening)) { throw ("relay pid {0} still not accepting connections on 127.0.0.1:8082 after respawn" -f $script:OwnRelayPid) }
07:47:12 ERROR-STACK bei Ensure-Proxy, C:\Program Files\Qubes Tools\bin\qubes-windows-update.ps1: Zeile 619
07:47:12 ERROR-STACK bei <ScriptBlock>, C:\Program Files\Qubes Tools\bin\qubes-windows-update.ps1: Zeile 2438
07:47:13 relay pid 4328 stopped by this pass (exit code -1)
07:47:13 proxy removed (offline baseline restored)
EOF

# ---- fixture 2: VERBATIM scratchpad/gweck/ev-final/guest-agent.log, the old bare form.
# A log captured across an upgrade carries both forms, so both must stay readable forever.
cat > "$D/bare.log" <<'EOF'
12:19:30 VM class (live from qubesdb): TemplateVM
12:19:35 Sync-Revocation: 3/3 CTLs refreshed through the relay, chain cache flushed
12:19:37 ERROR: Exception from HRESULT: 0x8024402C
12:19:38 proxy removed, relay stopped (offline baseline restored)
EOF

# ---- fixture 3: VERBATIM healthy pass (gweck capture) - the judge must not invent a failure.
cat > "$D/healthy.log" <<'EOF'
12:38:48 VM class (live from qubesdb): TemplateVM
12:38:52 Sync-Revocation: 3/3 CTLs refreshed through the relay, chain cache flushed
12:39:00 scan: 4 update(s) offered
12:39:00 reported 4 update(s) to dom0 qubes.NotifyUpdates (exit 0)
12:39:01 done
12:39:01 proxy removed, relay stopped (offline baseline restored)
EOF

# ---- fixture 4: a pass that reported AND declared the bracketed error = CONTRADICTORY.
sed 's/^12:39:01 done$/12:39:01 [ERROR] Exception from HRESULT: 0x80072EFE/' "$D/healthy.log" > "$D/contradictory.log"

r=$(judge "$D/bracketed.log")
if printf '%s' "$r" | grep -q 'rc=3' && printf '%s' "$r" | grep -q 'errored=1' && printf '%s' "$r" | grep -q 'silent=1'; then
    ok "bracketed: the release capture is SILENT, rc=3"
else bad "bracketed: the release capture graded $(printf '%s' "$r" | head -1) - the gate's false PASS is back"; fi

# ONE failure, not three. ERROR-SITE/ERROR-STACK must not inflate the count, and the quoted
# diagnosis must be the message rather than a source line.
if printf '%s' "$r" | grep -q 'errored=1' && printf '%s' "$r" | grep -q 'ended on relay pid 4328 still not accepting'; then
    ok "bracketed: continuation lines excluded, the diagnosis quoted is the message"
else bad "bracketed: continuation lines counted or the diagnosis is a source line - [$(printf '%s' "$r" | grep -m1 FAIL | cut -c1-120)]"; fi

r=$(judge "$D/bare.log")
if printf '%s' "$r" | grep -q 'rc=3' && printf '%s' "$r" | grep -q 'errored=1'; then
    ok "bare: the pre-10-14 form still reads as an error"
else bad "bare: the old form stopped matching - $(printf '%s' "$r" | head -1)"; fi

r=$(judge "$D/healthy.log")
if printf '%s' "$r" | grep -q 'rc=0' && printf '%s' "$r" | grep -q 'errored=0'; then
    ok "healthy: a reporting pass stays PASS"
else bad "healthy: a clean pass was failed - $(printf '%s' "$r" | head -1)"; fi

# A "C:\..." path is not a level. The pattern requires "]" or ":" straight after ERROR, so a
# Windows path in a stack line can never be read as a declared error.
cat > "$D/path.log" <<'EOF'
12:40:00 VM class (live from qubesdb): TemplateVM
12:40:01 C:\Program Files\Qubes Tools\bin\qubes-windows-update.ps1: Zeile 619
12:40:02 reported 0 update(s) to dom0 qubes.NotifyUpdates (exit 0)
EOF
r=$(judge "$D/path.log")
if printf '%s' "$r" | grep -q 'errored=0'; then ok "path: a C:\\ line is not a declared level"
else bad "path: a Windows path counted as an error - $(printf '%s' "$r" | head -1)"; fi

r=$(judge "$D/contradictory.log")
if printf '%s' "$r" | grep -q 'contradictory=1'; then ok "contradictory: reported AND bracketed error is caught"
else bad "contradictory: a pass that reported and errored graded $(printf '%s' "$r" | head -1)"; fi

# ---- the second blindness: a pass that said NOTHING. `silent` needs an error line, so actual
# silence was the one shape it could not see. Fixture = the release capture truncated where a
# killed pass stops, followed by a healthy pass that PROVES the first one was over.
head -3 "$D/bracketed.log" > "$D/died.log"
cat "$D/healthy.log" >> "$D/died.log"
r=$(judge "$D/died.log")
if printf '%s' "$r" | grep -q 'rc=3' && printf '%s' "$r" | grep -q 'DIED MID-PASS at 07:47:01'; then
    ok "died: a pass a later pass proved over, which never spoke, FAILS"
else bad "died: a cut-off pass graded $(printf '%s' "$r" | head -1) - dom0 left stale in silence"; fi

# The LAST pass must only be FLAGGED: a kill and a pass still running are identical in this log.
head -3 "$D/bracketed.log" > "$D/running.log"
r=$(judge "$D/running.log")
if printf '%s' "$r" | grep -q 'rc=0' && printf '%s' "$r" | grep -q 'FLAG FINAL pass'; then
    ok "running: the final silent pass is flagged, not failed"
else bad "running: a possibly-live pass was $(printf '%s' "$r" | head -1) - the log cannot tell it from a kill"; fi

# A REFUSAL MUST NOT TRIP IT. Every refusal gate in guest/qubes-windows-update.ps1 exits by line
# 418 and "VM class" is logged at 2420, so a refused pass writes no pass-start line at all. If that
# ever changes, this fixture - a refusal's own console text with no pass header - starts failing.
cat > "$D/refusal.log" <<'EOF'
12:40:00 QWTUPDMUTEXHELD: another Qubes update operation is in progress - refusing to run this
12:41:00 VM class (live from qubesdb): TemplateVM
12:41:05 scan: 0 update(s) offered
12:41:05 reported 0 update(s) to dom0 qubes.NotifyUpdates (exit 0)
EOF
r=$(judge "$D/refusal.log")
if printf '%s' "$r" | grep -q 'rc=0' && printf '%s' "$r" | grep -q 'vanished=0'; then
    ok "refusal: a refusal before the pass header is not a dead pass"
else bad "refusal: a legitimate refusal was failed - $(printf '%s' "$r" | head -1)"; fi

# A declining pass (StandaloneVM) is not a dead pass either, even with a pass after it.
cat > "$D/noop.log" <<'EOF'
07:32:02 VM class (live from qubesdb): StandaloneVM
07:32:02 StandaloneVM, offline - the qubes proxy updater is template-only and never runs here; this VM must update itself. Doing nothing.
12:38:48 VM class (live from qubesdb): TemplateVM
12:39:00 reported 4 update(s) to dom0 qubes.NotifyUpdates (exit 0)
EOF
r=$(judge "$D/noop.log")
if printf '%s' "$r" | grep -q 'rc=0' && printf '%s' "$r" | grep -q 'vanished=0'; then
    ok "noop: a by-design decline is not a dead pass"
else bad "noop: a StandaloneVM decline was failed - $(printf '%s' "$r" | head -1)"; fi

# ALL THREE by-design declines, not just the one with a known sentence. Found by sweeping 170 real
# captures on 2026-10-17: three StandaloneVM-with-internet passes were about to be called deaths,
# because "Doing nothing" was the only decline the tool knew. Every decline is gated on the CLASS
# (guest/qubes-windows-update.ps1:2421-2436), so the class is what is read. Lines are verbatim.
for cls in standalone-online appvm; do
    case $cls in
      standalone-online) hdr='StandaloneVM'; txt='StandaloneVM with direct internet - it updates ITSELF via Windows Update. The qubes proxy updater is template-only: disabled. Undoing NoAutoUpdate=1.' ;;
      appvm)             hdr='AppVM';        txt='AppVM - not a template; updates are the template'"'"'s business. Exiting before any proxy activity.' ;;
    esac
    { printf '12:40:00 VM class (live from qubesdb): %s\n12:40:01 %s\n' "$hdr" "$txt"
      cat "$D/healthy.log"; } > "$D/decline-$cls.log"
    r=$(judge "$D/decline-$cls.log")
    if printf '%s' "$r" | grep -q 'rc=0' && printf '%s' "$r" | grep -q 'vanished=0'; then
        ok "decline/$cls: declines by class, not by sentence"
    else bad "decline/$cls: a by-design decline was called a death - $(printf '%s' "$r" | head -1)"; fi
done

# The real captures, when the evidence tree is still on this qube. Not required - the fixtures
# above are these lines - but when present they are the thing itself.
REL=/home/user/qwt-accept/rel-38994277148/template-update.d/wu-e2e/round1/agent.log
if [ -f "$REL" ]; then
    r=$(judge "$REL")
    if printf '%s' "$r" | grep -q 'rc=3'; then ok "real capture: rel-38994277148 round1 now FAILS"
    else bad "real capture: rel-38994277148 round1 still passes - $(printf '%s' "$r" | head -1)"; fi
else echo "SKIP  real capture $REL absent (fixtures carry its lines verbatim)"; fi

echo "wu-judge-levelprefix: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
