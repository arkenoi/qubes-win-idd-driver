#!/usr/bin/env bash
# wu-oscillation-verdict-selftest.sh - tools/wu-oscillation-verdict.py, OFFLINE. No guest.
#
# WHAT IT GUARDS. The oscillation check asserted dom0's updates-available did not change across a
# scan, which conflates the same offer COMING BACK (our defect) with Microsoft PUBLISHING a new one
# mid-campaign (not our defect). Both move the number from N to N+1, so a count can never tell
# them apart. Owner 2026-10-20: "can we sanely handle the situation when update was published AFTER
# the campaign start and not fail there?"
#
# KB2267602 is the case that matters: Defender Security Intelligence is republished several times a
# day under a NEW UpdateID each time, so by count it reads as one thing oscillating for ever.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){  pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL  %s\n     -> %s\n' "$1" "${2:-}"; }
V=tools/wu-oscillation-verdict.py

j(){ printf '%s' "$2" > "$T/$1.json"; }
run(){ python3 "$V" --before "$T/$1.json" --after "$T/$2.json" --resolved "${3:-}" 2>&1; }
rc_of(){ python3 "$V" --before "$T/$1.json" --after "$T/$2.json" --resolved "${3:-}" >/dev/null 2>&1; echo $?; }

A='[{"id":"aaa-1","rev":200,"kb":"KB2267602"}]'
B='[{"id":"bbb-2","rev":100,"kb":"KB5007651"}]'

# 1. nothing changed
j before "$A"; j after "$A"
out=$(run before after); rc=$(rc_of before after)
case "$out" in *STABLE*) [ "$rc" = 0 ] && ok "unchanged set -> STABLE, rc=0" || bad "STABLE but rc=$rc";; *) bad "unchanged set" "$out";; esac

# 2. THE CASE THE OWNER ASKED FOR: the pass resolved what was offered, and WHILE the scan ran
# Microsoft published a new one. The count goes 1 -> 1 (or 0 -> 1) and a count-based check fails
# the run for something that is not our defect at all.
# (The first version of this fixture left aaa-1 present AND marked it resolved, which IS an
# oscillation - the tool said so, correctly, and the fixture was the thing that was wrong.)
j before "$A"; j after '[{"id":"ccc-3","rev":1}]'
out=$(run before after "aaa-1"); rc=$(rc_of before after "aaa-1")
case "$out" in *NEW-PUBLICATION*ccc-3*) [ "$rc" = 0 ] && ok "an offer published after the scan is NEW-PUBLICATION, rc=0 - the run does not fail" || bad "new publication but rc=$rc";;
  *) bad "a newly published offer must not read as oscillation" "$out";; esac

# 3. THE REAL OSCILLATION: an offer the pass said it resolved is back
j before "$A"; j after "$A"
out=$(run before after "aaa-1"); rc=$(rc_of before after "aaa-1")
case "$out" in *OSCILLATION*aaa-1*) [ "$rc" = 1 ] && ok "a RESOLVED offer still present -> OSCILLATION, rc=1" || bad "oscillation but rc=$rc";;
  *) bad "a resolved offer coming back must fail" "$out";; esac

# 4. SEEN TO FAIL both ways on the same sets: the ONLY difference is what the pass resolved
j before "$A"; j after "$A"
r1=$(rc_of before after ""); r2=$(rc_of before after "aaa-1")
[ "$r1" = 0 ] && [ "$r2" = 1 ] && ok "SEEN TO FAIL: identical sets give rc=0 unresolved and rc=1 resolved - the verdict tracks the FACT, not the count" \
  || bad "the verdict does not track what was resolved" "unresolved rc=$r1 resolved rc=$r2"

# 5. a revision bump is a republication, not a return
j before "$A"; j after '[{"id":"aaa-1","rev":201}]'
out=$(run before after "aaa-1"); rc=$(rc_of before after "aaa-1")
case "$out" in *NEW-PUBLICATION*) [ "$rc" = 0 ] && ok "same UpdateID with a HIGHER revision is a republication, not an oscillation" || bad "republication but rc=$rc";;
  *) bad "a revision bump must not read as oscillation" "$out";; esac

# 6. KB2267602's actual shape: republished under a NEW id - a count would call this oscillation
j before "$A"; j after "$B"
out=$(run before after "aaa-1"); rc=$(rc_of before after "aaa-1")
case "$out" in *NEW-PUBLICATION*) [ "$rc" = 0 ] && ok "a different id at the same count is NEW-PUBLICATION - the case a count gets wrong" || bad "rc=$rc";;
  *) bad "same count, different id" "$out";; esac

# 7. MISSING DATA FAILS - an unreadable or identity-less side is input failure, never a quiet pass
j before "$A"; j bad1 '[{"rev":1}]'
python3 "$V" --before "$T/before.json" --after "$T/bad1.json" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "an offer with no UpdateID is rc=2 input-error, not a pass" || bad "identity-less offer gave rc=$rc"
python3 "$V" --before "$T/before.json" --after "$T/nope.json" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "an absent file is rc=2 input-error, not a pass" || bad "absent file gave rc=$rc"

echo
echo "wu-oscillation-verdict-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
