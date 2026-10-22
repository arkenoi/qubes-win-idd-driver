#!/usr/bin/env bash
# updater-gates-lib.sh - THE UPDATER'S QUICK GATES. One copy, sourced by both callers.
#
# WHY A LIBRARY AND NOT A SECOND SCRIPT (owner, 2026-10-22): "so actually we need the resulting test
# to handle functions of both. simulating a dom0 driven update, with progress and exit codes is
# important part. but BEFORE the full sequence starts, we want quick check if main functionality
# passes without failure."
#
# So the gates run in TWO places and must be ONE implementation:
#   * mgmt/harness/updater-component-test.sh  - standalone, minutes, for quick per-component grading;
#   * mgmt/harness/template-update-test.sh    - as the PREFLIGHT, before it spends three dom0-driven
#     rounds. A relay that was never built now fails in ~2 minutes instead of surfacing an hour later
#     as an update-outcome symptom, which is what happened four times before the cause was found.
# A grader copied into both would drift, and the copy that drifts is the one that stops catching the
# defect. This project has paid for that lesson in renames and duplicated predicates already.
#
# THE GATES, each reading OUR OWN log lines or a number - never a Windows string, because the
# subject is a German image where an English-prose predicate matches nothing:
#   U1 the deploy vouched its source, COMPILED the relay, vouched the placed exe
#   U2 the placed exe carries the shipped binary's UTF-16 `parent=` marker
#   U3 the relay listens on 8082 and declares parent=<pid>  (a pid-port is the failure shape)
#   U4 the pass served it with a relay IT started (adopted nothing)
#   U5 a COUNT reached dom0 (scan line + NotifyUpdates exit 0)
#   U6 no pass died on "not accepting connections on 127.0.0.1:8082"
#   U7 the subject IS the reporter's recorded environment
#
# Everything here reads FILES, so the same code grades a live run and a captured evidence dir. That
# is what lets tools/tests/updater-component-selftest.sh drive all seven gates offline against the
# REAL pre-fix and post-fix captures of 2026-10-22.

UG_PASS=0; UG_FAIL=0; UG_LINES=""

updater_gates_init(){ UG_PASS=0; UG_FAIL=0; UG_LINES=""; }

ug_gate(){ # ug_gate <id> <description> <0|1 ok> [detail]
  local id="$1" what="$2" ok="$3" detail="${4:-}"
  if [ "$ok" = 0 ]; then
    UG_PASS=$((UG_PASS+1)); UG_LINES="${UG_LINES}PASS  $id  $what"$'\n'
  else
    UG_FAIL=$((UG_FAIL+1)); UG_LINES="${UG_LINES}FAIL  $id  $what"$'\n'
    [ -n "$detail" ] && UG_LINES="${UG_LINES}            -> $detail"$'\n'
  fi
}
# -a everywhere: a German guest's logs are not UTF-8 and this tool shell's grep silently skips
# non-UTF-8 files without it. -F wherever the pattern is not deliberately a regex.
ug_has(){   grep -qaF -- "$2" "$1" 2>/dev/null; }
ug_hasre(){ grep -qaE -- "$2" "$1" 2>/dev/null; }

# updater_gates_grade <evidence-dir> [reporter-name]
#   0 = all gates pass, 1 = a gate failed (the product), 2 = the evidence is missing (INSTRUMENT).
#   Leaves the gate lines in $UG_LINES and the counts in $UG_PASS / $UG_FAIL.
updater_gates_grade(){
  local d="${1:?updater_gates_grade <evidence-dir>}" reporter="${2:-the reporter}"
  local ilog="$d/install.log" alog="$d/agent.log" rlog="$d/relay.log" exe="$d/exe.txt"
  local f missing=""
  updater_gates_init
  # A SCAN THAT NEVER RAN IS NOT A PRODUCT VERDICT. `-Action scan` REFUSES while another update
  # operation holds the updater mutex - "QWTUPDMUTEXHELD: another Qubes update operation is in
  # progress" - and, because refusing is not an error, it EXITS 0. Measured 2026-10-22: the install
  # had just re-enabled QubesWindowsUpdateScan, that scheduled pass was mid-flight, this probe's
  # scan refused, exit 0 was read as success, and the gates were graded against a pass this test did
  # not drive. The probe now waits for the mutex and reports scan_refused_mutex; if it is still held
  # the answer is INSTRUMENT, never FAIL.
  if [ -s "$d/scan.txt" ] && grep -qaF 'scan_refused_mutex=True' "$d/scan.txt"; then
    UG_LINES="INSTRUMENT: the scan never ran - the updater mutex was held by another pass for the whole wait (QWTUPDMUTEXHELD). Nothing about the product is implied."$'\n'
    return 2
  fi
  for f in "$ilog" "$alog" "$rlog" "$exe"; do [ -s "$f" ] || missing="$missing $(basename "$f")"; done
  if [ -n "$missing" ]; then
    UG_LINES="INSTRUMENT: missing or empty evidence:$missing - no verdict"$'\n'
    return 2
  fi

  # U1 - the deploy built it, and said so three times. "updater agent deployed" with none of these
  # three lines is exactly the fa5b416a (2026-10-19) discarded-ScriptBlock defect.
  local u1=0
  ug_has   "$ilog" 'relay source vouched' || u1=1
  ug_hasre "$ilog" 'compiled relay ->'    || u1=1
  ug_has   "$ilog" 'relay exe vouched'    || u1=1
  ug_gate U1 "the deploy vouched its source, compiled the relay and vouched the placed exe" "$u1" \
    "install.log must carry all three; 'updater agent deployed' without them is the fa5b416a defect"

  # U2 - the placed binary is the shipped one
  local u2=1; ug_has "$exe" 'marker=True' && u2=0
  ug_gate U2 "the installed relay carries the shipped binary's UTF-16 parent= marker" "$u2" \
    "exe.txt: $(grep -aE '^(marker|written|size)=' "$exe" 2>/dev/null | tr '\n' ' ')"

  # U3 - 8082 AND a parent field. The measured failure bound the pass's own pid (2540, 5956, 6688,
  # 8228, 8892) - owner: "it is the same as 'relay is not listening' for us."
  local u3=1 lastlisten pidports
  lastlisten=$(grep -aE ' listen 127\.0\.0\.1:[0-9]+ ' "$rlog" 2>/dev/null | tail -1)
  if printf '%s' "$lastlisten" | grep -qaE ' listen 127\.0\.0\.1:8082 ' \
     && printf '%s' "$lastlisten" | grep -qaE ' parent=[0-9]+'; then u3=0; fi
  pidports=$(grep -aoE ' listen 127\.0\.0\.1:[0-9]+' "$rlog" 2>/dev/null \
             | grep -avE ':8082$' | grep -aoE '[0-9]+$' | sort -u | tr '\n' ',' | sed 's/,$//')
  ug_gate U3 "the relay listens on 8082 and declares parent=<pid>" "$u3" \
    "last listen: ${lastlisten:-none}${pidports:+ ; non-8082 ports seen this run: $pidports}"

  # U4 - served by a relay THIS pass started; never adopted (ADR-updater 12.4)
  local u4=1
  ug_hasre "$alog" 'proxy up: 127\.0\.0\.1:8082 is served by relay pid [0-9]+, started by this pass' && u4=0
  ug_gate U4 "the pass served 8082 with a relay it started itself (adopted nothing)" "$u4" \
    "agent.log has no 'proxy up: ... started by this pass' line"

  # U5 - a COUNT reached dom0. This is the operator's bar for the word verified: an e2e pass.
  local u5=0 scanline repline
  scanline=$(grep -aoE 'scan: [0-9]+ update\(s\) offered, [0-9]+ actionable, [0-9]+ reported to dom0' "$alog" 2>/dev/null | tail -1)
  repline=$(grep -aoE 'reported [0-9]+ update\(s\) to dom0 qubes\.NotifyUpdates \(exit 0\)' "$alog" 2>/dev/null | tail -1)
  [ -n "$scanline" ] || u5=1
  [ -n "$repline" ]  || u5=1
  ug_gate U5 "the scan reported a count to dom0 through the relay" "$u5" \
    "scan line: ${scanline:-ABSENT} | report line: ${repline:-ABSENT}"

  # U6 - nothing died on the relay
  local u6=0
  ug_hasre "$alog" '\[ERROR\].*not accepting connections on 127\.0\.0\.1:8082' && u6=1
  ug_gate U6 "no pass died with the relay not accepting on 8082" "$u6" \
    "$(grep -aoE '\[ERROR\].*not accepting connections on 127\.0\.0\.1:8082' "$alog" 2>/dev/null | head -1)"

  # U7 - the environment, including the locale. Never assumed: an absent assert FAILS.
  #
  # THE TOKEN IS THE TOOL'S OWN, AND THIS GATE WAS BROKEN BECAUSE IT WASN'T. The first version
  # matched /MATCHED|PASS/, which env-assert.sh never writes: it prints "ENVASSERT OK: <vm> matches
  # every asserted fact of <reporter>'s environment" on success (line 145) and "ENVASSERT FAIL: ..."
  # on failure (line 142). So U7 could NEVER pass on a real run - measured 2026-10-22, a run where
  # env-assert said OK and this gate called it a FAIL. The offline suite missed it because its
  # fixture carried a success line I had WRITTEN ("MATCHED: ...") instead of one the tool had
  # EMITTED; a fixture built from my model tests my model. The fixture is now the captured line.
  local u7=1
  if [ -s "$d/env-assert.out" ]; then
    ug_has "$d/env-assert.out" 'ENVASSERT OK:' && u7=0
    ug_gate U7 "the subject is the reporter's recorded environment ($reporter)" "$u7" \
      "$(grep -aE 'ENVASSERT (OK|FAIL)|MISMATCH|MISSING' "$d/env-assert.out" 2>/dev/null | tail -2 | tr '\n' ' ')"
  else
    ug_gate U7 "the subject is the reporter's recorded environment ($reporter)" 1 \
      "no env-assert.out in $d - the environment and locale were never asserted"
  fi

  # AN ENVIRONMENT FAILURE IS NEVER A PRODUCT FAILURE. If U7 is the ONLY gate that failed, we did
  # not test what we claimed to test - the subject is not the reporter's environment - so the
  # verdict is INSTRUMENT and the product is not implicated. template-update-test.sh classifies a
  # failed env-assert exactly this way; reporting it as FAIL would blame the updater for a missing
  # Open-Shell.
  if [ "$UG_FAIL" = 1 ] && printf '%s' "$UG_LINES" | grep -qa '^FAIL  U7 '; then return 2; fi
  [ "$UG_FAIL" -eq 0 ] && return 0 || return 1
}

# updater_gates_collect <vm> <evidence-dir>
#   Pushes the guest probe, runs it, and splits its delimited sections into the four files
#   updater_gates_grade reads. Returns 0 if the probe ran, 2 if it could not be run at all.
#   The caller owns QTEST_VM and the vmlock; this only collects.
updater_gates_collect(){
  local vm="${1:?updater_gates_collect <vm> <outdir>}" d="${2:?updater_gates_collect <vm> <outdir>}"
  local probe=mgmt/harness/updater-component-probe.ps1 i
  [ -f "$probe" ] || { echo "updater_gates_collect: $probe missing"; return 2; }
  mkdir -p "$d" || return 2
  # THE LOCK IS THIS FUNCTION'S BUSINESS, because this is the thing that drives a guest.
  # lint L2 caught exactly the hole: updater-component-test.sh holds the lock for its whole run, but
  # template-update-test.sh holds NO lock of its own - quick-upgrade.sh and wu-e2e.sh each take one
  # and release it when they exit - so the preflight between them would have driven the guest
  # unserialised. That is how two 8 GiB guests came up at once on 2026-09-13. vm_lock is a no-op when
  # an ancestor already holds THIS guest, so taking it here is correct in both callers and the
  # component test's existing lock still covers its whole run.
  if [ "${QWT_VMLOCK_HELD:-}" != "$vm" ]; then
    declare -F vm_lock >/dev/null 2>&1 || . mgmt/harness/vmlock.sh
    vm_lock "$vm" || { echo "updater_gates_collect: could not take the vmlock for $vm"; return 2; }
  fi
  export QTEST_VM="$vm"
  # the guest must be answering before the probe is pushed, or an unreachable guest reads as an
  # empty capture - which the grader would then report as INSTRUMENT rather than silently pass
  for i in $(seq 1 20); do
    ./tools/qtest run "cmd /c echo UP" 2>/dev/null | tr -d '\r\0' | grep -qa UP && break
    sleep 15
  done
  ./tools/qtest pushrun "$probe" >"$d/probe.out" 2>&1 || true
  awk '/^#INSTALLLOG#/{f=1;next}/^#ENDINSTALLLOG#/{f=0}f' "$d/probe.out" | tr -d '\r' > "$d/install.log"
  awk '/^#AGENTLOG#/{f=1;next}/^#ENDAGENTLOG#/{f=0}f'     "$d/probe.out" | tr -d '\r' > "$d/agent.log"
  awk '/^#RELAYLOG#/{f=1;next}/^#ENDRELAYLOG#/{f=0}f'     "$d/probe.out" | tr -d '\r' > "$d/relay.log"
  awk '/^#EXE#/{f=1;next}/^#ENDEXE#/{f=0}f'               "$d/probe.out" | tr -d '\r' > "$d/exe.txt"
  awk '/^#SCAN#/{f=1;next}/^#ENDSCAN#/{f=0}f'             "$d/probe.out" | tr -d '\r' > "$d/scan.txt"
  awk '/^#SIZES#/{f=1;next}/^#ENDSIZES#/{f=0}f'           "$d/probe.out" | tr -d '\r' > "$d/sizes.txt"
  return 0
}

# ---------------------------------------------------------------------------------------------
# DIAGNOSIS: what failed, and what the evidence says about WHY (owner, 2026-10-22: "new test has
# pretty extensive quick diagnostics that tells a lot about WHAT failed with nice probability").
#
# NO HAND-ROLLED PROBABILITIES. "If it assigns a case to a class, it is Jev's, not a hand call"
# (owner, 2026-09-21). A number I invent here would be advocacy wearing a decimal point. Instead
# every candidate cause is tied to a DISCRIMINATOR - a string the product itself emits on exactly
# that path - so the verdict is one of:
#     CONFIRMED  a discriminator for this cause is present
#     EXCLUDED   its discriminator is absent and would have been written had it happened
#     POSSIBLE   nothing in this evidence can separate it; that is stated, not guessed
# The candidate set comes from the product's own throws and logs:
#   deploy: QWTRELAYSTALESRC / QWTRELAYSTALEEXE / QWTRELAYUNREADABLE / QWTRELAYBUSY /
#           "kept the previous relay exe" / "relay compile failed" / "relay compile attempt" /
#           "relay compiled but could not replace" / "could not enumerate relay processes"
#   agent:  "SCAN FAILED" / "Not reporting 0 to dom0" / "REFUSED: ..." / an HRESULT /
#           "did not serve the port" / "still not accepting connections"
# When a cause is only POSSIBLE, the bundle written at the end is exactly what to hand Jev, and the
# command to do it is printed. That keeps the probability with the classifier of record.
UG_DIAG=""
ug_cand(){ # ug_cand <verdict> <cause> <evidence>
  UG_DIAG="${UG_DIAG}     $(printf '%-9s' "$1") $2"$'\n'
  [ -n "${3:-}" ] && UG_DIAG="${UG_DIAG}               evidence: $3"$'\n'
}
ug_fired(){ printf '%s' "$UG_LINES" | grep -qa "^FAIL  $1 "; }

# updater_gates_diagnose <evidence-dir>  - fills $UG_DIAG. Reads files only.
updater_gates_diagnose(){
  local d="${1:?updater_gates_diagnose <evidence-dir>}"
  local ilog="$d/install.log" alog="$d/agent.log" rlog="$d/relay.log" exe="$d/exe.txt"
  local pat="" g
  UG_DIAG=""
  for g in U1 U2 U3 U4 U5 U6 U7; do
    if printf '%s' "$UG_LINES" | grep -qa "^FAIL  $g "; then pat="$pat $g:FAIL"; else pat="$pat $g:pass"; fi
  done
  UG_DIAG="DIAGNOSIS${pat}"$'\n'
  [ "$UG_FAIL" = 0 ] && { UG_DIAG="${UG_DIAG}  every gate passed - nothing to diagnose."$'\n'; return 0; }

  # ---- U1: the relay was not built this install -------------------------------------------------
  if ug_fired U1; then
    UG_DIAG="${UG_DIAG}  U1 the deploy did not build the relay:"$'\n'
    local deployed=no compiled=no
    ug_has "$ilog" 'updater agent deployed' && deployed=yes
    ug_has "$ilog" 'compiled relay ->'      && compiled=yes
    if [ "$deployed" = no ] && [ "$compiled" = no ]; then
      ug_cand CONFIRMED "the updater deploy never ran at all (or its log was not captured)" \
        "install.log carries neither 'updater agent deployed' nor 'compiled relay ->'"
    elif [ "$deployed" = yes ] \
         && ! ug_hasre "$ilog" 'QWTRELAY|kept the previous relay exe|relay compile (failed|attempt)|could not replace'; then
      ug_cand CONFIRMED "the compile block NEVER EXECUTED - dead code (the fa5b416a shape)" \
        "'updater agent deployed' is present, no 'compiled relay ->', and NOT ONE of the block's own failure paths logged anything: no QWTRELAY* refusal, no skip, no csc failure, no blocked move. A block that fails leaves a trace; a block that never runs leaves none."
    else
      ug_cand POSSIBLE "the compile block did not execute" "another failure path below also fired"
    fi
    ug_has "$ilog" 'QWTRELAYSTALESRC' \
      && ug_cand CONFIRMED "the STAGED SOURCE was stale - a payload from an older release" "$(grep -aoE 'QWTRELAYSTALESRC[^"]{0,120}' "$ilog" | head -1)" \
      || ug_cand EXCLUDED "stale staged source" "no QWTRELAYSTALESRC - the source vouch would have thrown it"
    ug_has "$ilog" 'kept the previous relay exe' \
      && ug_cand CONFIRMED "the OLD SKIP BRANCH kept a previous exe (pre-fa5b416a behaviour)" "the 'kept the previous relay exe' line is present" \
      || ug_cand EXCLUDED "the old skip branch" "no 'kept the previous relay exe' line"
    ug_hasre "$ilog" 'relay compile (failed|attempt)' \
      && ug_cand CONFIRMED "csc FAILED to compile the relay" "$(grep -aoE 'relay compile (failed|attempt)[^"]{0,100}' "$ilog" | head -1)" \
      || ug_cand EXCLUDED "a csc compile failure" "no 'relay compile failed/attempt' line"
    ug_has "$ilog" 'relay compiled but could not replace' \
      && ug_cand CONFIRMED "the MOVE was blocked - the old exe was locked" "the 'could not replace' throw is present" \
      || ug_cand EXCLUDED "a blocked move" "no 'relay compiled but could not replace' throw"
    ug_has "$ilog" 'QWTRELAYBUSY' \
      && ug_cand CONFIRMED "the deploy REFUSED because something held the port" "QWTRELAYBUSY present" \
      || ug_cand EXCLUDED "a busy-port refusal" "no QWTRELAYBUSY"
  fi

  # ---- U2: the placed binary is not the shipped one ---------------------------------------------
  if ug_fired U2; then
    UG_DIAG="${UG_DIAG}  U2 the installed relay is not the shipped binary:"$'\n'
    if ug_fired U1; then
      ug_cand CONFIRMED "nothing was built, so the file on disk is whatever was there before" \
        "U1 also failed; $(grep -aE '^written=' "$exe" 2>/dev/null | head -1) predates this install"
    else
      ug_cand CONFIRMED "the relay WAS compiled this install, yet the file lacks the marker" \
        "U1 passed but $(grep -aE '^marker=' "$exe" 2>/dev/null) - something replaced or restored the exe after the move, or the compile used a different input"
    fi
    ug_has "$ilog" 'QWTRELAYUNREADABLE' \
      && ug_cand CONFIRMED "the placed exe could not be READ back to vouch it" "QWTRELAYUNREADABLE - not a stale binary; something holds the file" \
      || ug_cand EXCLUDED "an unreadable placed exe" "no QWTRELAYUNREADABLE"
  fi

  # ---- U3: the port -----------------------------------------------------------------------------
  if ug_fired U3; then
    UG_DIAG="${UG_DIAG}  U3 the relay is not serving 8082:"$'\n'
    local lastlisten port selfpath
    lastlisten=$(grep -aE ' listen 127\.0\.0\.1:[0-9]+ ' "$rlog" 2>/dev/null | tail -1)
    port=$(printf '%s' "$lastlisten" | grep -aoE 'listen 127\.0\.0\.1:[0-9]+' | grep -aoE '[0-9]+$')
    selfpath=$(printf '%s' "$lastlisten" | grep -aoE 'self=[^ ]+' | sed 's/^self=//')
    if [ -n "$port" ] && [ "$port" != 8082 ] && ! printf '%s' "$lastlisten" | grep -qa 'parent='; then
      ug_cand CONFIRMED "the running relay PREDATES --parent-pid: the launcher's flag VALUE became the listen port" \
        "it bound $port with no parent= field, and the launcher passes '--parent-pid <its own pid>'. This is the measured shape (2540, 5956, 6688, 8228, 8892)."
    elif [ -z "$lastlisten" ]; then
      ug_cand CONFIRMED "no relay ever logged a listen line this pass" "relay.log has no 'listen 127.0.0.1:<port>' entry"
    else
      ug_cand POSSIBLE "the relay bound an unexpected port" "last listen: $lastlisten"
    fi
    if [ -n "$selfpath" ] && ! printf '%s' "$selfpath" | grep -qaF 'Qubes Tools\bin'; then
      ug_cand CONFIRMED "the relay that logged this ran from ANOTHER image" "self=$selfpath is not the installed path"
    fi
    ug_has "$exe" 'marker=False' \
      && ug_cand CONFIRMED "the installed binary itself lacks --parent-pid support" "exe.txt marker=False - so even a correct launch cannot bind 8082" \
      || ug_cand EXCLUDED "an unsupported installed binary" "the installed exe carries the marker, so the file is capable"
  fi

  # ---- U4: served / adopted ---------------------------------------------------------------------
  if ug_fired U4; then
    UG_DIAG="${UG_DIAG}  U4 the pass did not serve 8082 with its own relay:"$'\n'
    ug_hasre "$alog" 'REFUSED: 127\.0\.0\.1:8082 is already served by pid' \
      && ug_cand CONFIRMED "a FOREIGN listener held 8082 and the pass refused to adopt it (ADR-updater 12.4)" "$(grep -aoE 'REFUSED: 127\.0\.0\.1:8082 is already served by pid [0-9]+' "$alog" | head -1)" \
      || ug_cand EXCLUDED "a foreign listener on 8082" "no 'already served by pid' refusal"
    ug_hasre "$alog" 'REFUSED: cannot read who listens' \
      && ug_cand CONFIRMED "the port-owner table could not be read, so the pass refused to serve blind" "$(grep -aoE 'REFUSED: cannot read who listens[^.]{0,80}' "$alog" | head -1)" \
      || ug_cand EXCLUDED "an unreadable port table" "no 'cannot read who listens' refusal"
    ug_fired U3 && ug_cand CONFIRMED "upstream: U3 failed, so there was no relay on 8082 to serve with" "see U3 above"
  fi

  # ---- U5: nothing reached dom0 -----------------------------------------------------------------
  if ug_fired U5; then
    UG_DIAG="${UG_DIAG}  U5 no count reached dom0:"$'\n'
    if ug_fired U3 || ug_fired U4; then
      ug_cand CONFIRMED "upstream: the relay never served, so no metadata could be fetched" "U3/U4 failed above - this is a consequence, not an independent fault"
    fi
    ug_has "$alog" 'SCAN FAILED' \
      && ug_cand CONFIRMED "the scan's fetches failed and it correctly refused to report 0" "$(grep -aoE 'SCAN FAILED[^.]{0,120}' "$alog" | head -1)" \
      || ug_cand EXCLUDED "a failed-fetch scan" "no 'SCAN FAILED' line"
    ug_has "$alog" 'Not reporting 0 to dom0' \
      && ug_cand CONFIRMED "the pass deliberately withheld a 0 (a scan that could not fetch is not 'no updates')" "the 'Not reporting 0 to dom0' line is present" \
      || ug_cand EXCLUDED "a deliberately withheld 0" "no 'Not reporting 0 to dom0' line"
    local hr
    hr=$(grep -aoE '0x8024[0-9A-Fa-f]{4}|0x800[0-9A-Fa-f]{5}' "$alog" 2>/dev/null | sort -u | tr '\n' ' ')
    [ -n "$hr" ] \
      && ug_cand CONFIRMED "Windows Update itself returned an error" "HRESULT(s) in agent.log: $hr (0x8024402C = it did not use the configured proxy - see ADR-updater section 11)" \
      || ug_cand EXCLUDED "a Windows Update HRESULT" "no 0x8024xxxx/0x800xxxxx in agent.log"
  fi

  # ---- U6 / U7 ----------------------------------------------------------------------------------
  if ug_fired U6; then
    UG_DIAG="${UG_DIAG}  U6 a pass died on the relay:"$'\n'
    ug_cand CONFIRMED "the relay process lived but never reached its listener within the bound" \
      "$(grep -aoE '\[ERROR\].*not accepting connections on 127\.0\.0\.1:8082[^|]{0,80}' "$alog" | head -1)"
    ug_has "$alog" 'did not serve the port' \
      && ug_cand CONFIRMED "a respawn did not help either" "the 'did not serve the port after a respawn' line is present"
  fi
  if ug_fired U7; then
    UG_DIAG="${UG_DIAG}  U7 the environment is not the reporter's:"$'\n'
    if [ -s "$d/env-assert.out" ]; then
      ug_cand CONFIRMED "env-assert measured a mismatch" "$(grep -aoE '(MISMATCH|MISSING)[^|]{0,110}' "$d/env-assert.out" | head -2 | tr '\n' ';')"
    else
      ug_cand CONFIRMED "the environment was never asserted" "no env-assert.out - a locale-sensitive verdict over an unasserted environment is not a verdict"
    fi
  fi

  UG_DIAG="${UG_DIAG}  Any cause marked POSSIBLE is undecided BY DESIGN - this evidence cannot separate it."$'\n'
  UG_DIAG="${UG_DIAG}  For probabilities, hand the bundle to the classifier of record rather than guessing:"$'\n'
  UG_DIAG="${UG_DIAG}    JEV_ARTIFACT_OUT=$d/jev.json tools/jev-artifact.sh <rubric.json> $d/diagnosis.txt $d/install.log $d/agent.log $d/relay.log"$'\n'
  return 0
}

# ---------------------------------------------------------------------------------------------
# JEV AS SECONDARY EVALUATOR (owner, 2026-10-22: "we MAY have jev as secondary evaluator in any
# script"). The PRIMARY verdict stays deterministic - the gates and their discriminators above,
# which need no network and are graded offline against real captures. Jev is asked ONE question on
# top: over the candidate causes for the EARLIEST failing gate (the earliest is the root; the later
# ones are its consequences), which does the evidence most support, and how strongly?
#
# This is the right division of labour. A probability is a classification, and classifications are
# Jev's - but a gate verdict must not depend on a network call, or the component test stops being a
# quick local check. So: gates decide PASS/FAIL, Jev decides the likelihood among causes.
#
# The candidate set is NOT invented per run. It is the fixed set of paths the product can actually
# take, each named after the string it emits, so Jev chooses among real alternatives.
UG_JEV=""

# updater_gates_jev <evidence-dir> - fills $UG_JEV. Needs network; never affects the gate verdict.
updater_gates_jev(){
  local d="${1:?updater_gates_jev <evidence-dir>}" first="" g
  UG_JEV=""
  [ "$UG_FAIL" = 0 ] && { UG_JEV="(no failing gate - Jev not asked)"; return 0; }
  for g in U1 U2 U3 U4 U5 U6 U7; do
    if printf '%s' "$UG_LINES" | grep -qa "^FAIL  $g "; then first="$g"; break; fi
  done
  local rub="$d/jev-cause-rubric.json" crit=""
  case "$first" in
    U1) crit='"dead_code":"the compile block never executed - a bare { } made it a discarded ScriptBlock, so no branch of it logged anything",
         "stale_source":"the staged source was from an older release and the source vouch refused it",
         "skip_branch":"an older skip branch kept the previous exe instead of compiling",
         "csc_failed":"the in-box csc failed to compile the relay",
         "move_blocked":"it compiled but could not replace the installed exe, which was locked",
         "busy_refusal":"the deploy refused because something appeared to hold the port",
         "deploy_never_ran":"the updater deploy did not run at all, or its log was not captured"' ;;
    U2) crit='"nothing_built":"nothing was compiled, so the file on disk predates this install",
         "replaced_after_move":"it was compiled and moved, then replaced or restored by something else",
         "wrong_input":"the compile used a different input than the vouched source",
         "unreadable":"the placed exe could not be read back to vouch it"' ;;
    U3) crit='"stale_binary_running":"the running relay predates --parent-pid, so the launcher flag VALUE became its listen port",
         "orphan_other_image":"a relay from a different image logged the listen line",
         "no_listen_at_all":"no relay reached its listener this pass",
         "installed_exe_incapable":"the installed binary itself lacks --parent-pid support"' ;;
    U4) crit='"foreign_listener":"a listener this pass did not start held 8082 and the pass refused to adopt it",
         "port_table_unreadable":"the port-owner table could not be read, so the pass refused to serve blind",
         "upstream_u3":"there was no relay on 8082 to serve with - a consequence of U3"' ;;
    U5) crit='"upstream_relay":"the relay never served, so no metadata could be fetched - a consequence, not an independent fault",
         "wu_error":"Windows Update itself returned an error such as 0x8024402C",
         "scan_fetch_failed":"the scan fetches failed and it correctly refused to report 0",
         "withheld_zero":"the pass deliberately withheld a 0 because it could not fetch",
         "reported_but_unlogged":"a report reached dom0 but this evidence does not carry its line"' ;;
    U6) crit='"listener_never_reached":"the relay process lived but never reached its listener inside the bound",
         "respawn_also_failed":"a respawn did not help either",
         "port_taken":"something else held the port so the relay could not bind it"' ;;
    U7) crit='"env_mismatch":"env-assert measured a mismatch against the reporter record",
         "never_asserted":"the environment was never asserted at all"' ;;
    *)  UG_JEV="(no candidate set for $first)"; return 0 ;;
  esac
  cat > "$rub" <<JEOF
{"questions":{
 "root_cause":{"type":"choice","instructions":{"judge":"The artifact is a failing updater run: the deploy's install log, the updater agent's own log, the relay's own log, and the installed relay binary's identity. The earliest failing gate is $first, so its cause is the ROOT and the later gates are its consequences. Judge ONLY from the lines present. A path the product takes always leaves its own line, so the ABSENCE of every other path's line is itself evidence."},"criteria":{$crit}},
 "evidence_is_sufficient":{"type":"noul","instructions":{"judge":"Does this evidence actually separate the candidate causes, or would more than one explain it equally well? Answer true only if the lines present pick out one cause."},"criteria":{"true":"the evidence picks out one cause","false":"more than one cause fits equally"}}}}
JEOF
  printf '%s\n' "$UG_DIAG" > "$d/diagnosis.txt"
  if [ ! -x tools/jev-artifact.sh ]; then UG_JEV="(tools/jev-artifact.sh not available - gates stand on their own)"; return 0; fi
  UG_JEV=$(JEV_ARTIFACT_OUT="$d/jev-cause.json" tools/jev-artifact.sh "$rub" \
             "$d/diagnosis.txt" -- "cat $d/install.log" "cat $d/agent.log" "cat $d/relay.log" "cat $d/exe.txt" 2>&1 | tail -4)
  [ -n "$UG_JEV" ] || UG_JEV="(Jev produced no answer - the deterministic gates above are the verdict)"
  return 0
}
