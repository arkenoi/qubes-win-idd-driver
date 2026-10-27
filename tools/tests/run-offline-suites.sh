#!/bin/bash
# run-offline-suites.sh - run every suite in product-suites.txt and harness-suites.txt, serially,
# and fail on any red. A suite named in both lists, or in neither and not declared out in
# not-in-the-gate.txt, is refused before anything runs.
#
#   tools/tests/run-offline-suites.sh
#
# This is the producer SELFTESTSUNRUNINCI was missing: 117 offline suites existed and CI named them
# only in comments, so a green `test` said nothing about any of them and every receipt in
# findings/issues.md held only as long as someone kept running them by hand.
#
# SERIAL BY DESIGN. Two suites that both bind and delete loop devices produced a false red when run
# in one command (BLOCKCLAIMSELFTESTRACES): loop numbers are global, so each can observe the other's
# device. Parallelism here would buy a minute and cost a believable red.
#
# THE FLOOR IS THE POINT. A runner that iterates a list cannot tell "all 37 passed" from "the list
# was emptied" - and a gate suite losing its producer is this project's most repeated failure
# (count-the-producers, the selftest whose RESULT line was deduped away, the gate that required 18
# suites where 12 had a producer). So the count is asserted against a floor that only moves in a
# commit, and a suite that reports zero assertions is a failure even at exit 0.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

# OFFLINE_SUITES_LIST/_DIR point this at a fixture list, for tools/tests/offline-runner-selftest.sh.
# A runner whose own floor and EMPTY rule have never been seen to FIRE is the thing it exists to
# stop, so they are proven against planted suites rather than asserted in this comment.
PRODUCT_LIST=${OFFLINE_SUITES_PRODUCT_LIST:-tools/tests/product-suites.txt}
HARNESS_LIST=${OFFLINE_SUITES_HARNESS_LIST:-tools/tests/harness-suites.txt}
# OFFLINE_SUITES_LIST overrides BOTH with one fixture list (offline-runner-selftest.sh).
LIST=${OFFLINE_SUITES_LIST:-}
SUITEDIR=${OFFLINE_SUITES_DIR:-tools/tests}
# THE FLOOR IS THE PRODUCT LIST'S LENGTH, and the two must agree. The literal below is the
# committed intent; the count is the fact. A harness-only change cannot move the literal, and a
# product suite that joins or leaves must move it in the SAME commit or this refuses to run.
# It replaces a 250-line per-move history: that history recorded a policy where any addition moved
# the floor, and it still stood at 148 against a list of 146 for a day - every run exited 2 and NO
# suite ran at all, which is the exact inertness the floor exists to catch.
FLOOR=${OFFLINE_SUITES_FLOOR:-43}
# Each suite's own temp files: /tmp is a 1 GB tmpfs on the dev qube and 40 suites' fixtures do not
# belong in RAM. On a CI runner TMPDIR is already real disk, so this only ever makes it safer.
export TMPDIR="${TMPDIR_OVERRIDE:-${RUNNER_TEMP:-/home/user/tmp}}"
mkdir -p "$TMPDIR" 2>/dev/null

# DEPTH GUARD. offline-runner-selftest.sh is itself in the list and it RUNS this script against a
# fixture list, so the nesting is one deep by construction - but a self-test that re-entered its own
# producer once fork-bombed this qube, and the fix then was a depth guard. One level, no exceptions.
if [ "${OFFLINE_SUITES_DEPTH:-0}" -ge 1 ]; then
  echo "ERROR: run-offline-suites.sh re-entered itself (depth ${OFFLINE_SUITES_DEPTH}) - a suite must not run the whole suite"
  exit 2
fi
export OFFLINE_SUITES_DEPTH=$(( ${OFFLINE_SUITES_DEPTH:-0} + 1 ))

_names(){ sed 's/#.*//' "$1" | awk 'NF'; }
if [ -n "$LIST" ]; then
  [ -r "$LIST" ] || { echo "ERROR: $LIST is missing - the curated list IS the gate"; exit 2; }
  mapfile -t suites < <(_names "$LIST")
else
  LIST="$PRODUCT_LIST + $HARNESS_LIST"
  for f in "$PRODUCT_LIST" "$HARNESS_LIST"; do
    [ -r "$f" ] || { echo "ERROR: $f is missing - the two curated lists ARE the gate"; exit 2; }
  done
  # IN BOTH: a name in both lists is counted twice toward the floor and its class is undecided.
  both=$(comm -12 <(_names "$PRODUCT_LIST" | sort -u) <(_names "$HARNESS_LIST" | sort -u))
  if [ -n "$both" ]; then
    echo "ERROR: in BOTH lists - a suite has one class: $(echo "$both" | tr '\n' ' ')"
    exit 2
  fi
  # IN NEITHER: every suite file is product, harness, or declared out with a reason. The universe
  # is every *.sh/*.py directly under the suite dir - NOT the *-selftest.sh spelling, because a
  # census scoped to a naming convention cannot see the file that breaks it (lint L32's lesson).
  neither=$(comm -23 \
    <(cd "$SUITEDIR" && ls *.sh *.py 2>/dev/null | sort -u) \
    <(cat <(_names "$PRODUCT_LIST") <(_names "$HARNESS_LIST") \
          <(awk '!/^[[:space:]]*#/ && NF {print $1}' "$SUITEDIR/not-in-the-gate.txt" 2>/dev/null) \
          | sort -u))
  if [ -n "$neither" ]; then
    echo "ERROR: in NEITHER list and not declared out: $(echo "$neither" | tr '\n' ' ')"
    exit 2
  fi
  # THE FLOOR IS THE PRODUCT COUNT. Equality, not >=: a rise with no product addition and a
  # product addition with no rise are the same defect from opposite sides.
  nprod=$(_names "$PRODUCT_LIST" | wc -l)
  if [ "$nprod" -ne "$FLOOR" ]; then
    echo "ERROR: $PRODUCT_LIST names $nprod product suite(s), floor literal is $FLOOR - the floor moves only with this list, in the same commit"
    exit 2
  fi
  # A TEMPORARY JOB THAT OUTLIVES ITS CONDITION IS A PERMANENT ONE. Any CI job whose key says
  # probe or temporary carries "# REMOVE-BY: YYYY-MM-DD if <condition>"; past that date the job
  # must be gone, and this refuses to run until it is.
  expired=$(python3 - <<'EOP'
import os,re,datetime,sys
today=datetime.date.today(); bad=[]
d=".github/workflows"
for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
    if not f.endswith((".yml",".yaml")): continue
    L=open(os.path.join(d,f),errors="replace").read().splitlines()
    jobs=[(i,m.group(1)) for i,l in enumerate(L) for m in [re.match(r"^  ([A-Za-z0-9_-]+):\s*$",l)] if m]
    for k,(i,name) in enumerate(jobs):
        if not re.search(r"probe|temporary|temp", name, re.I): continue
        end=jobs[k+1][0] if k+1<len(jobs) else len(L)
        m=re.search(r"#\s*REMOVE-BY:\s*(\d{4}-\d{2}-\d{2})\s+if\s+\S", "\n".join(L[i:end]))
        if not m: bad.append("%s job '%s' has no '# REMOVE-BY: YYYY-MM-DD if <condition>'"%(f,name)); continue
        due=datetime.date.fromisoformat(m.group(1))
        if due < today: bad.append("%s job '%s' was REMOVE-BY %s and is still here"%(f,name,m.group(1)))
print("\n".join(bad))
EOP
)
  if [ -n "$expired" ]; then
    echo "ERROR: temporary CI job(s) past their condition:"; echo "$expired" | sed 's/^/  /'
    exit 2
  fi

  # A SMOKE SCRIPT IS A TEMPORARY INSTRUMENT, and the thing this refuses is one that quietly became
  # permanent. Each tools/smoke/ script collects through fresh_cell_log (the sealed primitive, not
  # its own log walk) and declares "# SMOKE-SINCE: YYYY-MM-DD". Fourteen days on it is either
  # PROMOTED - its assertion moved into product-suites.txt, recorded here as "# PROMOTED: <suite>" -
  # or deleted. Neither happening is how a scratch probe turns into a second unowned harness.
  smoke=$(python3 - <<'EOP'
import os,re,datetime
today=datetime.date.today(); bad=[]; d="tools/smoke"
for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
    if not f.endswith((".sh",".py")): continue
    p=os.path.join(d,f); t=open(p,errors="replace").read()
    if "fresh_cell_log" not in t:
        bad.append("%s never calls fresh_cell_log - a smoke script collects through the sealed primitive"%p)
    m=re.search(r"#\s*SMOKE-SINCE:\s*(\d{4}-\d{2}-\d{2})",t)
    if not m:
        bad.append("%s has no '# SMOKE-SINCE: YYYY-MM-DD' - promote-or-delete needs a start date"%p); continue
    since=datetime.date.fromisoformat(m.group(1)); age=(today-since).days
    if age > 14 and not re.search(r"#\s*PROMOTED:\s*\S",t):
        bad.append("%s is %d days old, neither promoted nor deleted (SMOKE-SINCE %s)"%(p,age,m.group(1)))
print("\n".join(bad))
EOP
)
  if [ -n "$smoke" ]; then
    echo "ERROR: tools/smoke/ promote-or-delete:"; echo "$smoke" | sed 's/^/  /'
    exit 2
  fi
  mapfile -t suites < <(cat <(_names "$PRODUCT_LIST") <(_names "$HARNESS_LIST"))
fi
n=${#suites[@]}
if [ -n "${OFFLINE_SUITES_LIST:-}" ] && [ "$n" -lt "$FLOOR" ]; then
  echo "ERROR: $LIST names $n suite(s), floor is $FLOOR - the list shrank; move the floor in a commit or restore the suites"
  exit 2
fi
echo "--- $n offline suite(s), serially (floor $FLOOR, TMPDIR $TMPDIR)"

# OFFLINE MEANS IT DOES NOT TOUCH THE RIG, AND UNTIL NOW THAT WAS ONLY THE WORD IN THE FILENAME.
# specimen-mark-reachable-selftest.sh drove w_session against a guest it called `somevm`; w_session
# samples cpu with `timeout 20 qrexec-client-vm "$vm" admin.vm.Stats`, so every single run fired 24
# admin calls at a qube that does not exist. Each one is DENIED, and a denied Admin API call is
# written to the OWNER'S dom0 journal - he asked what they were, 2026-10-21. The suite was green
# throughout: nothing it asserted could see the calls, because the calls are not its output.
# So the property gets a predicate. Every suite runs with a shim dir FIRST on PATH; any rig command
# it reaches is recorded and exits 1 - which is what a denial already gave it - and a suite that
# reached one is RED whatever its exit code was. A suite that genuinely needs the rig is not an
# offline suite and does not belong in this list.
# It must be a stub on PATH and not a shell function: `timeout`, `env`, `xargs`, `nohup` and
# `find -exec` all EXEC their argument, so a function is never in the path to be found. That was
# my first fix and the call count did not move.
# OFFLINE-RIGSHIM-A  (to the B marker: driven by tools/tests/offline-rigshim-selftest.sh;
# neither marker names the other)
RIGSHIM="$TMPDIR/.offline-rig-shim.$$"
RIGCALLS="$TMPDIR/.offline-rig-calls.$$"
mkdir -p "$RIGSHIM" || { echo "ERROR: cannot create the rig shim dir - refusing to run unguarded"; exit 2; }
for _c in qrexec-client-vm qrexec-client \
          qvm-ls qvm-tags qvm-run qvm-start qvm-shutdown qvm-kill qvm-pause qvm-unpause \
          qvm-prefs qvm-features qvm-volume qvm-device qvm-remove qvm-clone qvm-create \
          qvm-check qvm-copy-to-vm qvm-move-to-vm qvm-console-dispvm qvm-firewall qubes-prefs; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "${OFFLINE_RIG_CALLS:-/dev/null}"\nexit 1\n' \
    "$_c" > "$RIGSHIM/$_c" || { echo "ERROR: cannot write the rig shim - refusing to run unguarded"; exit 2; }
  chmod +x "$RIGSHIM/$_c"
done
trap 'rm -rf "$RIGSHIM" "$RIGCALLS"' EXIT
# OFFLINE-RIGSHIM-B

red=0; green=0; empty=0; total_assertions=0; touched=0
for s in "${suites[@]}"; do
  f="$SUITEDIR/$s"
  if [ ! -x "$f" ] && [ ! -r "$f" ]; then
    printf 'MISSING  %-52s named in the list, not in the tree\n' "$s"; red=$((red+1)); continue
  fi
  : > "$RIGCALLS"
  # ITS OWN INTERPRETER. `bash x.py` is a defect this repo has already paid for (e058b621: it froze
  # the owner's desktop twice), and two gate-ready suites are .py.
  # THE EXTENSION DECIDES, because that is the committed rule: tools/hooks/wrong-interpreter-gate.sh
  # refuses `bash x.py` / `python3 x.sh` on (interpreter, extension) pairs and consults no shebang
  # anywhere. A second, different rule in the runner would be a second answer to the same question.
  # The shebang is read ONLY for a name with no extension to go on, and bash is the last resort.
  # So a .sh file whose shebang named python3 WOULD run under bash here - the gate would refuse that
  # file to a human, and if one is ever added, it belongs in the case below, not in this comment.
  case "$s" in
    *.py) _interp=(python3) ;;
    *.sh) _interp=(bash) ;;
    *)    case "$(head -c 80 "$f" 2>/dev/null)" in
            '#!'*python*) _interp=(python3) ;;
            *)            _interp=(bash) ;;
          esac ;;
  esac
  out=$(OFFLINE_RIG_CALLS="$RIGCALLS" PATH="$RIGSHIM:$PATH" timeout 300 "${_interp[@]}" "$f" 2>&1); rc=$?
  # A run that reports NO assertion at all has been gutted, whatever its exit code - that is exactly
  # how a deduped RESULT line turned a suite into a no-op. A tally ("N passed", "N check(s)") is
  # preferred; failing that, assertion LINES are counted, and the set of spellings below is measured,
  # not assumed. This comment used to say "Two spellings count, because both are in use here"; on
  # 2026-10-25 six were in use, and the four it did not know reported zero and were called
  # decoration:
  #   OK   <text>                  peek-abi-assert, wgcbroker-layout, installer-clock-gate
  #                                (the old regex was case-SENSITIVE: `ok` matched, `OK` did not)
  #   PASS: <text>                 pwclass-truth-table (`PASS[[:space:]]` misses the colon)
  #   -> RED AS REQUIRED (<name>)  failproof-install-log, 17 negative cases
  #   -> PROOF EARNED: <name>      failproof-misc, 4 checks
  # ADD A SPELLING HERE DELIBERATELY, never by widening until a suite goes green: an over-broad
  # pattern counts prose and a gutted suite then reads as covered.
  passed=$(printf '%s' "$out" | command grep -oaE '[0-9]+ (passed|check\(s\))' | command grep -oaE '^[0-9]+' | tail -1)
  : "${passed:=0}"
  if [ "$passed" -eq 0 ]; then
    passed=$(printf '%s' "$out" | command grep -caE '^[[:space:]]*(PASS|ok|OK)([[:space:]]|:)|^[[:space:]]*->[[:space:]]*(RED AS REQUIRED|PROOF EARNED)|^RESULT: PASS')
    : "${passed:=0}"
  fi
  total_assertions=$((total_assertions + passed))
  if [ -s "$RIGCALLS" ]; then
    # RED WHATEVER THE EXIT CODE WAS: the suite passed its own assertions and still reached the rig.
    printf 'TOUCHED-RIG %-49s %s call(s) to the rig from an OFFLINE suite\n' "$s" "$(wc -l < "$RIGCALLS")"
    sort -u "$RIGCALLS" | sed 's/^/           /' | head -4
    red=$((red+1)); touched=$((touched+1))
  elif [ "$rc" -ne 0 ]; then
    printf 'FAIL     %-52s rc=%s  %s\n' "$s" "$rc" "$(printf '%s' "$out" | tail -1 | cut -c1-80)"
    printf '%s\n' "$out" | command grep -aiE '^\s*(FAIL|BROKE|ERROR)' | sed 's/^/           /' | head -6
    red=$((red+1))
  elif [ "$passed" -eq 0 ] && [ -n "$out" ]; then
    # NOT "reported no assertions" - that is a claim about the SUITE, and all this runner knows is
    # what IT could parse. A gutted suite and a suite whose spelling is unknown must not share a
    # label: four green suites were called decoration that way. Red either way, named differently.
    printf 'UNKNOWN-FORMAT %-45s exited 0; the counter recognised no assertion spelling\n' "$s"
    printf '%s\n' "$out" | tail -3 | sed 's/^/           /'
    printf '           add the spelling to the counter in this file, or fix the suite - do not widen blindly\n'
    red=$((red+1))
  elif [ "$passed" -eq 0 ]; then
    printf 'EMPTY    %-52s exited 0 and printed NOTHING AT ALL\n' "$s"
    empty=$((empty+1))
  else
    printf 'ok       %-52s %s assertion(s)\n' "$s" "$passed"
    green=$((green+1))
  fi
done

echo "--- $green green, $red red, $empty reporting nothing; $total_assertions assertions over $n suite(s)"
if [ "$red" -gt 0 ] || [ "$empty" -gt 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
