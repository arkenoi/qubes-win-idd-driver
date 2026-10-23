#!/usr/bin/env bash
# updater-component-selftest.sh - the UPDATER COMPONENT TEST's verdict logic, graded offline.
#
# WHY. mgmt/harness/updater-component-test.sh exists because the sequence that found the relay
# defect on 2026-10-22 was run BY HAND (owner: "it is mostly what you do now by hand but systemic,
# verified and repeatable"). A hand sequence cannot be seen to fail, and two of my hand steps that
# morning were wrong in ways that read as a pass. So every gate in that script is driven here, in
# both polarities, against the REAL captures of that day - no hand-written stand-ins:
#
#   POST-FIX  win11de-tup after the rebuilt relay was deployed: relay.log carries
#             "10:29:08.084 listen 127.0.0.1:8082 ... parent=936"; agent.log carries
#             "10:29:10 proxy up: ... started by this pass" and "10:37:37 scan: 6 update(s) offered,
#             6 actionable, 6 reported to dom0"; the exe carries the UTF-16 marker.
#   PRE-FIX   the same guest ten minutes earlier: relay.log carries listens on 2540 and 5956 - the
#             pass's OWN pids - agent.log carries two "[ERROR] ... not accepting connections on
#             127.0.0.1:8082 after respawn" and no scan line at all, and the exe is the 2026-09-16
#             binary with marker=False. Every pass reported success to the installer regardless.
#
# The pre-fix fixture is the point: the component test must FAIL on it. A gate that has only ever
# seen healthy data is not a gate.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST="$ROOT/mgmt/harness/updater-component-test.sh"
pass=0; fail=0
say(){ printf '%s\n' "$*"; }
ck(){ # ck <what> <0|1 ok> [detail]
  if [ "$2" = 0 ]; then pass=$((pass+1)); say "ok   $1"
  else fail=$((fail+1)); say "FAIL $1"; [ -n "${3:-}" ] && say "       -> $3"; fi
}
[ -f "$TEST" ] || { say "FAIL  $TEST is missing - nothing ran"; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/updcomp.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ---- the fixtures, verbatim from the 2026-10-22 captures -----------------------------------------
mk_post(){ local d="$1"; mkdir -p "$d"
cat > "$d/install.log" <<'EOF'
2026-10-22 11:27:10 [INFO]   11:27:10 relay source vouched at C:\qwt-improved-setup\qubes-updates-relay.cs (parses --parent-pid, refuses unknown flags, declares parent=)
2026-10-22 11:27:13 [INFO]   11:27:13 compiled relay -> C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe
2026-10-22 11:27:14 [INFO]   11:27:14 relay exe vouched at C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe (carries the shipped binary's parent= marker)
2026-10-22 11:27:15 [INFO]   11:27:15 updater agent deployed
EOF
cat > "$d/agent.log" <<'EOF'
10:28:33 VM class (live from qubesdb): TemplateVM
10:29:07 relay started: pid 8164, start 2026-10-22T10:29:07, parent 936 - owned by handle; this pass stops this one and no other
10:29:10 proxy up: 127.0.0.1:8082 is served by relay pid 8164, started by this pass
10:29:12 Sync-Revocation: 3/3 CTLs refreshed through the relay, chain cache flushed
10:37:37 scan: 6 update(s) offered, 6 actionable, 6 reported to dom0
10:37:37 reported 6 update(s) to dom0 qubes.NotifyUpdates (exit 0)
10:37:37 done
10:37:37 relay pid 8164 stopped by this pass (exit code -1)
EOF
cat > "$d/relay.log" <<'EOF'
10:29:08.084 listen 127.0.0.1:8082 target=@default user=SYSTEM self=C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe parent=936
10:29:08.120 parent watchdog armed: pid 936, checked every 5000 ms
EOF
printf 'written=2026-10-22T07:27:04Z\nsize=56320\nmarker=True\n' > "$d/exe.txt"
# THE REAL LINE env-assert.sh EMITS, captured from a run on win11de-uc 2026-10-22 - not a success
# string of my own devising. The first version of this fixture said "MATCHED: ..." because that is
# what I imagined a success looks like; the gate matched /MATCHED|PASS/ to suit it, and U7 could
# therefore never pass on a real guest. The suite was green throughout. A fixture from my model
# tests my model.
printf "ENVASSERT win11de-uc vs reporter 'GWeck' (mgmt/reporters/gweck.json)\nENVASSERT OK: win11de-uc matches every asserted fact of GWeck's environment\n" > "$d/env-assert.out"
}
mk_pre(){ local d="$1"; mkdir -p "$d"
cat > "$d/install.log" <<'EOF'
2026-10-22 02:39:19 [INFO]   02:39:19 placed agent -> C:\Program Files\Qubes Tools\bin\qubes-windows-update.ps1
2026-10-22 02:39:20 [INFO]   02:39:20 updater agent deployed
EOF
cat > "$d/agent.log" <<'EOF'
10:19:36 VM class (live from qubesdb): TemplateVM
10:19:37 relay started: pid 3164, start 2026-10-22T10:19:37, parent 2540 - owned by handle; this pass stops this one and no other
10:20:12 [ERROR] relay pid 3164 still not accepting connections on 127.0.0.1:8082 after respawn - relay pid 3164 still running after 12 connect attempt(s)
10:20:12 relay pid 3164 stopped by this pass (exit code -1)
10:20:12 proxy removed (offline baseline restored)
10:26:20 relay started: pid 8092, start 2026-10-22T10:26:20, parent 5956 - owned by handle; this pass stops this one and no other
10:26:55 [ERROR] relay pid 7856 still not accepting connections on 127.0.0.1:8082 after respawn - relay pid 7856 still running after 12 connect attempt(s)
10:26:56 proxy removed (offline baseline restored)
EOF
cat > "$d/relay.log" <<'EOF'
10:19:37.153 listen 127.0.0.1:2540 target=@default user=SYSTEM self=C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe
10:19:55.536 listen 127.0.0.1:2540 target=@default user=SYSTEM self=C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe
10:26:20.386 listen 127.0.0.1:5956 target=@default user=SYSTEM self=C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe
10:26:38.817 listen 127.0.0.1:5956 target=@default user=SYSTEM self=C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe
EOF
printf 'written=2026-09-16T16:33:26Z\nsize=48128\nmarker=False\n' > "$d/exe.txt"
# THE REAL LINE env-assert.sh EMITS, captured from a run on win11de-uc 2026-10-22 - not a success
# string of my own devising. The first version of this fixture said "MATCHED: ..." because that is
# what I imagined a success looks like; the gate matched /MATCHED|PASS/ to suit it, and U7 could
# therefore never pass on a real guest. The suite was green throughout. A fixture from my model
# tests my model.
printf "ENVASSERT win11de-uc vs reporter 'GWeck' (mgmt/reporters/gweck.json)\nENVASSERT OK: win11de-uc matches every asserted fact of GWeck's environment\n" > "$d/env-assert.out"
}
run(){ EVAL_ONLY="$1" bash "$TEST" 2>&1; }

# ---- 1. the healthy capture must PASS, and on every gate ----------------------------------------
mk_post "$T/post"
out=$(run "$T/post"); rc=$?
ck 'the POST-FIX capture of 2026-10-22 is a PASS' "$([ $rc -eq 0 ] && echo 0 || echo 1)" "rc=$rc; $(printf '%s' "$out" | grep -a '^FAIL' | head -2 | tr '\n' ' ')"
for g in U1 U2 U3 U4 U5 U6 U7; do
  ck "...and gate $g passes on it" "$(printf '%s' "$out" | grep -qa "^PASS  $g " && echo 0 || echo 1)" \
    "$(printf '%s' "$out" | grep -a " $g " | head -1)"
done
ck 'it says 7 gates passed and none failed' \
  "$(printf '%s' "$out" | grep -qa 'gates: 7 passed, 0 failed' && echo 0 || echo 1)" \
  "$(printf '%s' "$out" | grep -a 'gates:' | head -1)"

# ---- 2. SEEN TO FAIL: the real pre-fix capture must FAIL ----------------------------------------
# This is the state that shipped and was reported as working. If the component test passes it, the
# test is worthless.
mk_pre "$T/pre"
out=$(run "$T/pre"); rc=$?
ck 'SEEN TO FAIL: the PRE-FIX capture is a FAIL, not a pass' "$([ $rc -eq 1 ] && echo 0 || echo 1)" "rc=$rc"
for g in U1 U2 U3 U4 U5 U6; do
  ck "...and gate $g catches it" "$(printf '%s' "$out" | grep -qa "^FAIL  $g " && echo 0 || echo 1)" \
    "$(printf '%s' "$out" | grep -a " $g " | head -1)"
done
ck '...U3 names the pid-ports it saw instead of 8082 (2540, 5956)' \
  "$(printf '%s' "$out" | grep -qa '2540' && printf '%s' "$out" | grep -qa '5956' && echo 0 || echo 1)" \
  "$(printf '%s' "$out" | grep -a 'U3' | head -2 | tr '\n' ' ')"
ck '...and U7 still passes, so the failure is attributed to the updater and not to the environment' \
  "$(printf '%s' "$out" | grep -qa '^PASS  U7 ' && echo 0 || echo 1)" \
  "$(printf '%s' "$out" | grep -a 'U7' | head -1)"

# ---- 3. every gate is INDEPENDENTLY live: remove exactly its evidence from the healthy capture ---
# A gate that cannot fail on its own is indistinguishable from a gate wired to another gate's data.
drop(){ # drop <dir> <file> <fixed string to delete>
  grep -av -F -- "$3" "$1/$2" > "$1/$2.tmp" && mv -f "$1/$2.tmp" "$1/$2"
}
only_fails(){ # only_fails <out> <gate> : that gate failed and no OTHER gate did
  local o="$1" g="$2" nf
  printf '%s' "$o" | grep -qa "^FAIL  $g " || { echo "no"; return; }
  nf=$(printf '%s' "$o" | grep -ac '^FAIL  ')
  [ "$nf" = 1 ] && echo "yes" || echo "no"
}
mk_post "$T/m1"; drop "$T/m1" install.log 'compiled relay ->'
ck 'U1 alone fails when the compile line is missing (the fa5b416a shape exactly)' \
  "$([ "$(only_fails "$(run "$T/m1")" U1)" = yes ] && echo 0 || echo 1)" "$(run "$T/m1" | grep -a '^FAIL' | tr '\n' ' ')"
mk_post "$T/m1b"; drop "$T/m1b" install.log 'relay source vouched'
ck 'U1 alone fails when the SOURCE vouch is missing' \
  "$([ "$(only_fails "$(run "$T/m1b")" U1)" = yes ] && echo 0 || echo 1)" "$(run "$T/m1b" | grep -a '^FAIL' | tr '\n' ' ')"
mk_post "$T/m1c"; drop "$T/m1c" install.log 'relay exe vouched'
ck 'U1 alone fails when the placed-exe vouch is missing' \
  "$([ "$(only_fails "$(run "$T/m1c")" U1)" = yes ] && echo 0 || echo 1)" "$(run "$T/m1c" | grep -a '^FAIL' | tr '\n' ' ')"
mk_post "$T/m2"; printf 'written=2026-10-22T07:27:04Z\nsize=56320\nmarker=False\n' > "$T/m2/exe.txt"
ck 'U2 alone fails when the placed exe lacks the UTF-16 marker' \
  "$([ "$(only_fails "$(run "$T/m2")" U2)" = yes ] && echo 0 || echo 1)" "$(run "$T/m2" | grep -a '^FAIL' | tr '\n' ' ')"
mk_post "$T/m3"
sed -i 's/listen 127\.0\.0\.1:8082/listen 127.0.0.1:8164/' "$T/m3/relay.log"
ck 'U3 alone fails when the relay binds its own pid instead of 8082' \
  "$([ "$(only_fails "$(run "$T/m3")" U3)" = yes ] && echo 0 || echo 1)" "$(run "$T/m3" | grep -a '^FAIL' | tr '\n' ' ')"
mk_post "$T/m3b"
sed -i 's/ parent=936$//' "$T/m3b/relay.log"
ck 'U3 alone fails when the listen line carries no parent= field (a pre---parent-pid binary)' \
  "$([ "$(only_fails "$(run "$T/m3b")" U3)" = yes ] && echo 0 || echo 1)" "$(run "$T/m3b" | grep -a '^FAIL' | tr '\n' ' ')"
mk_post "$T/m4"; drop "$T/m4" agent.log 'started by this pass'
ck 'U4 alone fails when nothing says the pass served 8082 with its own relay' \
  "$([ "$(only_fails "$(run "$T/m4")" U4)" = yes ] && echo 0 || echo 1)" "$(run "$T/m4" | grep -a '^FAIL' | tr '\n' ' ')"
mk_post "$T/m5"; drop "$T/m5" agent.log 'reported to dom0'
ck 'U5 alone fails when the scan reported no count to dom0 (the original silent pass)' \
  "$([ "$(only_fails "$(run "$T/m5")" U5)" = yes ] && echo 0 || echo 1)" "$(run "$T/m5" | grep -a '^FAIL' | tr '\n' ' ')"
mk_post "$T/m5b"; drop "$T/m5b" agent.log 'qubes.NotifyUpdates (exit 0)'
ck 'U5 alone fails when the dom0 report line is absent even though the scan line is there' \
  "$([ "$(only_fails "$(run "$T/m5b")" U5)" = yes ] && echo 0 || echo 1)" "$(run "$T/m5b" | grep -a '^FAIL' | tr '\n' ' ')"
mk_post "$T/m6"
printf '10:30:00 [ERROR] relay pid 8164 still not accepting connections on 127.0.0.1:8082 after respawn\n' >> "$T/m6/agent.log"
ck 'U6 alone fails when a pass died on the relay' \
  "$([ "$(only_fails "$(run "$T/m6")" U6)" = yes ] && echo 0 || echo 1)" "$(run "$T/m6" | grep -a '^FAIL' | tr '\n' ' ')"
mk_post "$T/m7"; rm -f "$T/m7/env-assert.out"
ck 'U7 alone fails when the environment was never asserted - never silently assumed' \
  "$([ "$(only_fails "$(run "$T/m7")" U7)" = yes ] && echo 0 || echo 1)" "$(run "$T/m7" | grep -a '^FAIL' | tr '\n' ' ')"

# ---- 3b. U7 reads the TOOL's token, and an invented one must not satisfy it ---------------------
mk_post "$T/u7real"
out=$(run "$T/u7real"); rc=$?
ck 'U7 passes on the line env-assert.sh actually writes ("ENVASSERT OK:")' \
  "$(printf '%s' "$out" | grep -qa '^PASS  U7 ' && echo 0 || echo 1)" "$(printf '%s' "$out" | grep -a 'U7' | head -1)"

# SEEN TO FAIL: the success string I had invented must NOT satisfy U7. This is the regression that
# made the gate inert - it is pinned here so it cannot come back quietly.
mk_post "$T/u7fake"
printf 'MATCHED: the subject is gweck (Windows 11 25H2 de-DE, TemplateVM)\n' > "$T/u7fake/env-assert.out"
out=$(run "$T/u7fake")
ck 'SEEN TO FAIL: an invented "MATCHED:" success line does NOT satisfy U7' \
  "$(printf '%s' "$out" | grep -qa '^FAIL  U7 ' && echo 0 || echo 1)" "$(printf '%s' "$out" | grep -a 'U7' | head -1)"

mk_post "$T/u7fail"
printf "ENVASSERT win11de-uc vs reporter 'GWeck'\nENVASSERT FAIL: 1 fact(s) could not be measured - missing data fails\n" > "$T/u7fail/env-assert.out"
out=$(run "$T/u7fail"); rc=$?
ck 'U7 fails on the real "ENVASSERT FAIL:" line' \
  "$(printf '%s' "$out" | grep -qa '^FAIL  U7 ' && echo 0 || echo 1)" "$(printf '%s' "$out" | grep -a 'U7' | head -1)"
ck '...and a U7-ONLY failure is INSTRUMENT (rc=2), never blamed on the updater' \
  "$([ "$rc" -eq 2 ] && echo 0 || echo 1)" "rc=$rc - an unbuilt environment means we did not test what we claimed"
ck '...and it says VERDICT: INSTRUMENT, not FAIL' \
  "$(printf '%s' "$out" | grep -qa 'VERDICT: INSTRUMENT' && echo 0 || echo 1)" "$(printf '%s' "$out" | grep -a 'VERDICT' | tail -1)"

# ---- 3c. a scan that NEVER RAN is INSTRUMENT, never a product verdict --------------------------
# MEASURED 2026-10-22: the install re-enables QubesWindowsUpdateScan, that scheduled pass was still
# running, so `-Action scan` printed "QWTUPDMUTEXHELD: another Qubes update operation is in progress"
# and EXITED 0 - refusing is not an error. The harness read exit 0, believed a scan had run, and
# graded the gates against a pass it had not driven (two of them "passed" on lines from the previous
# evening). Both halves are pinned here.
mk_post "$T/mutex"
printf 'QWTUPDMUTEXHELD: another Qubes update operation is in progress - refusing to run this scan under it; nothing was changed.\nscan_exit=0\nscan_refused_mutex=True\n' > "$T/mutex/scan.txt"
out=$(run "$T/mutex"); rc=$?
ck 'a scan refused by the updater mutex is INSTRUMENT (rc=2), even with healthy logs present' \
  "$([ "$rc" -eq 2 ] && echo 0 || echo 1)" "rc=$rc"
ck '...and it says the scan never ran, not that a gate failed' \
  "$(printf '%s' "$out" | grep -qa 'the scan never ran' && echo 0 || echo 1)" "$(printf '%s' "$out" | grep -a 'INSTRUMENT' | head -1)"
ck '...and no gate line is emitted at all, so nothing can be quoted as a product result' \
  "$(printf '%s' "$out" | grep -qaE '^(PASS|FAIL)  U[0-9]' && echo 1 || echo 0)" \
  "$(printf '%s' "$out" | grep -aE '^(PASS|FAIL)  U' | head -2 | tr '\n' ' ')"
# and a scan that DID run must not be caught by this
mk_post "$T/mutexok"
printf 'scan_exit=0\nscan_refused_mutex=False\n' > "$T/mutexok/scan.txt"
out=$(run "$T/mutexok"); rc=$?
ck 'a scan that ran (scan_refused_mutex=False) is graded normally and PASSES' \
  "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "rc=$rc"

# ---- 3d. env-assert's THIRD outcome: MISMATCH (exit 3), not just FAIL --------------------------
# env-assert.sh has three terminal lines - OK (0), FAIL/missing (2) and MISMATCH/differs (3). The
# suite covered two of them; a gate "correct by construction" for the third is exactly what I
# claimed about the MATCHED predicate that could never pass.
mk_post "$T/u7mm"
printf "ENVASSERT win11de-uc vs reporter 'GWeck'\nMISMATCH  current_build   want='26200'  got='26100'\nENVASSERT MISMATCH: win11de-uc is NOT GWeck's environment (1 fact(s) differ) - do not run the reproduction on it\n" > "$T/u7mm/env-assert.out"
out=$(run "$T/u7mm"); rc=$?
ck 'U7 fails on the real "ENVASSERT MISMATCH:" line (a 26100 guest is 24H2, not his)' \
  "$(printf '%s' "$out" | grep -qa '^FAIL  U7 ' && echo 0 || echo 1)" "$(printf '%s' "$out" | grep -a 'U7' | head -1)"
ck '...and that too is INSTRUMENT, not a product FAIL' "$([ "$rc" -eq 2 ] && echo 0 || echo 1)" "rc=$rc"
ck '...and the differing fact is named in the gate detail' \
  "$(printf '%s' "$out" | grep -qa 'current_build' && echo 0 || echo 1)" "$(printf '%s' "$out" | grep -a 'U7' | head -2 | tr '\n' ' ')"

# ---- 4. missing evidence is INSTRUMENT, never a pass --------------------------------------------
# A test that reads an empty dir and reports PASS is the failure mode this whole file exists for.
mkdir -p "$T/empty"
out=$(run "$T/empty"); rc=$?
ck 'an empty evidence dir is INSTRUMENT (rc=2), never a pass' "$([ $rc -eq 2 ] && echo 0 || echo 1)" "rc=$rc"
ck '...and it says which evidence is missing' \
  "$(printf '%s' "$out" | grep -qa 'missing or empty evidence' && echo 0 || echo 1)" "$(printf '%s' "$out" | tail -1)"
mk_post "$T/trunc"; : > "$T/trunc/agent.log"
out=$(run "$T/trunc"); rc=$?
ck 'an EMPTY agent.log is INSTRUMENT, not six silent gate failures' "$([ $rc -eq 2 ] && echo 0 || echo 1)" "rc=$rc"

# ---- 5. the live path must not be reachable from EVAL_ONLY --------------------------------------
# EVAL_ONLY exists so this logic can be graded with no rig. If it could still start a guest, the
# suite would be a rig job and could never run in CI.
ck 'EVAL_ONLY never contacts the rig: no qvm-*/qtest call outside the live section' \
  "$(awk '/^if \[ -n "\$\{EVAL_ONLY:-\}" \]; then$/,/^fi$/' "$TEST" | grep -qE 'qvm-|qtest|vm_lock' && echo 1 || echo 0)" \
  'the EVAL_ONLY branch must return before the live section'


# ---- EVERY HARNESS THAT GRADES THE GATES MUST WRITE env-assert.out WHERE THEY READ IT -----------
#
# U7's TOKEN was fixed on 2026-10-22 and is pinned above with the line env-assert.sh really emits.
# What was never checked is the PLUMBING, and that is what failed next. MEASURED on acceptance run
# 39880114972: template-update ran env-assert, logged "env-assert: ENVASSERT OK: win11de-tup matches
# every asserted fact of GWeck's environment", and U7 came back
#   FAIL U7 the subject is the reporter's recorded environment (gweck)
#        -> no env-assert.out in .../template-update.d/preflight - the environment and locale were
#           never asserted
# because the harness wrote "$OUT/env-assert.txt" while the gates read "$d/env-assert.out" with
# $d = "$OUT/preflight": a different extension AND a different directory. The feature test returned
# INSTRUMENT rc=2, no dom0 rounds were spent, and the acceptance run failed on a subject whose
# environment had been asserted and had passed. Jev, handed that bundle, said
# root_cause=never_asserted at conf 1.00 - correctly, because the file was not there to find.
#
# So the property is not "U7 matches the right token" but "the assertion reaches the directory U7
# reads". Checked per harness, from the dir each one actually hands to updater_gates_grade.
u7_bad=""
u7_n=0
for h in mgmt/harness/template-update-test.sh mgmt/harness/updater-component-test.sh; do
  [ -f "$ROOT/$h" ] || { u7_bad="$u7_bad $h(absent)"; continue; }
  # the directory variable this harness grades, e.g. "$PF" or "$OUT"
  gd=$(command grep -oE 'updater_gates_grade "\$[A-Za-z_][A-Za-z_0-9]*"' "$ROOT/$h" | head -1 \
       | sed -E 's/.*"\$([A-Za-z_][A-Za-z_0-9]*)".*/\1/')
  [ -n "$gd" ] && u7_n=$((u7_n+1)) || { u7_bad="$u7_bad $h(no-grade-call)"; continue; }
  # ...and whether anything in it puts env-assert.out into that same directory. COMMENTS AND
  # ERROR MESSAGES ARE STRIPPED FIRST: the comment explaining this placement names the very path
  # the check looks for, and so does the verdict string on the failure branch, so an unfiltered
  # grep would find its own explanation and pass on a harness that places nothing. The control
  # below caught exactly that in the first version of this leg.
  command grep -v '^[[:space:]]*#' "$ROOT/$h" | command grep -v 'verdict ' \
    | command grep -qE "\\\$$gd/env-assert\.out" || u7_bad="$u7_bad $h(grades \$$gd, no env-assert.out there)"
done
if [ "$u7_n" -lt 2 ]; then
  ck "the env-assert plumbing check found both grading harnesses" 1 "found $u7_n - the extraction stopped matching, it would pass on anything"
elif [ -z "$u7_bad" ]; then
  ck "every harness that grades the gates writes env-assert.out into the dir it grades ($u7_n harness(es))" 0 ""
else
  ck "a grading harness does not place env-assert.out where U7 reads it" 1 "$u7_bad"
fi
# SEEN TO FAIL, and the control is the SHIPPED DEFECT ITSELF: send env-assert's output back to
# "$OUT/env-assert.txt" - the exact line that was there on run 39880114972 - and the check must
# notice that nothing writes env-assert.out into the directory this harness grades.
u7_v="$T/tu-noplace.sh"
sed 's|"$PF/env-assert.out"|"$OUT/env-assert.txt"|g' \
  "$ROOT/mgmt/harness/template-update-test.sh" > "$u7_v"
if command grep -v '^[[:space:]]*#' "$u7_v" | command grep -v 'verdict ' | command grep -qE '\$PF/env-assert\.out'; then
  ck "could not build the no-placement variant" 1 "the substitution did not apply"
else
  gd=$(command grep -oE 'updater_gates_grade "\$[A-Za-z_][A-Za-z_0-9]*"' "$u7_v" | head -1 | sed -E 's/.*"\$([A-Za-z_][A-Za-z_0-9]*)".*/\1/')
  if command grep -v '^[[:space:]]*#' "$u7_v" | command grep -v 'verdict ' | command grep -qE "\\\$$gd/env-assert\.out"; then
    ck "SEEN TO FAIL: the no-placement variant was not caught" 1 "the check does not measure the placement"
  else
    ck "SEEN TO FAIL: with the placement removed the check sees no env-assert.out in \$$gd" 0 ""
  fi
fi

say ''
say "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
