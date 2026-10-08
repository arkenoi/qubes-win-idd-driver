#!/usr/bin/env bash
# pvnic-rearm-selftest.sh - the PV NIC shutdown re-arm, checked OFFLINE. No guest, no registry.
#
# WHAT IT GUARDS. `QubesPvNicRearm` fires on User32 1074 (shutdown initiated) and the Task Scheduler
# service terminates running actions as the system goes down: Last Result 267014
# (0x41306 SCHED_S_TASK_TERMINATED) on every shutdown measured. qwt-report-death.ps1 ignores that code
# for every task - correctly, it is a stop that was asked for - so a re-arm that NEVER RAN was
# indistinguishable from one that completed (Jev 2026-10-07: silent_hole 0.89). Two things now close it:
#
#   the action    cmd.exe + reg.exe, no interpreter, with the STAMP as the last link of a `&&` chain,
#                 so the stamp exists only when both registry writes have already succeeded
#   the judgement Test-QwtRearmArm, run by the BOOT task (where a task can finish what it starts),
#                 which decides from the stamp, the previous boot, and whether that shutdown was clean
#
# Test-QwtRearmArm is a PURE function, so every branch is driven here with synthetic times - and every
# check is also driven to FAIL with the defect injected, because a check never seen to fail is decoration.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${PVNIC_SRC:-$ROOT/guest/pvnic-selfprime.ps1}"
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
OUT="${PVNIC_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/pvnic-rearm-XXXXXX")}"
mkdir -p "$OUT"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$SRC" ] || { echo "FAIL  $SRC is missing - nothing ran (missing data fails)"; exit 2; }
[ -x "$PWSH" ] || { echo "FAIL  no pwsh at $PWSH - the decision cannot be exercised, so nothing is proven"; exit 2; }

# ---- extract the decision function out of the embedded payload ----------------------------------------
python3 - "$SRC" "$OUT/fn.ps1" <<'PY'
import sys, re
s = open(sys.argv[1], encoding='utf-8').read()
i = s.index('function Test-QwtRearmArm')
# brace-counted, not regex-truncated (the lesson from tools/probe-review.py)
d = 0; j = s.index('{', i)
for k in range(j, len(s)):
    if s[k] == '{': d += 1
    elif s[k] == '}':
        d -= 1
        if d == 0: break
open(sys.argv[2], 'w', encoding='utf-8').write(s[i:k+1] + '\n')
PY
[ -s "$OUT/fn.ps1" ] || { echo "FAIL  Test-QwtRearmArm could not be extracted from the payload"; exit 2; }

# ---- the case table: every branch, including a STALE stamp -------------------------------------------
# fields: name | stamp | prevBoot | unclean | reportedBoot | thisBoot | expected
cases(){ cat <<'EOF'
nojudge-first-boot   | ''                    | ''                    | $false | ''                    | 2026-10-07T12:00:00Z | nojudge
armed                | 2026-10-07T11:50:00Z  | 2026-10-07T09:00:00Z  | $false | ''                    | 2026-10-07T12:00:00Z | armed
stale-stamp-reports  | 2026-10-06T08:00:00Z  | 2026-10-07T09:00:00Z  | $false | ''                    | 2026-10-07T12:00:00Z | report
no-stamp-reports     | ''                    | 2026-10-07T09:00:00Z  | $false | ''                    | 2026-10-07T12:00:00Z | report
unclean-not-reported | ''                    | 2026-10-07T09:00:00Z  | $true  | ''                    | 2026-10-07T12:00:00Z | unclean
once-per-boot        | ''                    | 2026-10-07T09:00:00Z  | $false | 2026-10-07T12:00:00Z  | 2026-10-07T12:00:00Z | already-reported
other-boot-reports   | ''                    | 2026-10-07T09:00:00Z  | $false | 2026-10-06T12:00:00Z  | 2026-10-07T12:00:00Z | report
EOF
}

# run the table against a given copy of the function; echo "name expected got" per row
run_table(){ local fn="$1" drv="$OUT/drv.ps1"
  { cat "$fn"; echo
    cases | while IFS='|' read -r name stamp prev unclean rep this want; do
      name=$(echo "$name"|xargs); stamp=$(echo "$stamp"|xargs); prev=$(echo "$prev"|xargs)
      unclean=$(echo "$unclean"|xargs); rep=$(echo "$rep"|xargs); this=$(echo "$this"|xargs); want=$(echo "$want"|xargs)
      t(){ [ -z "$1" ] || [ "$1" = "''" ] && echo '$null' || echo "([datetime]'$1')"; }
      echo "\$r = Test-QwtRearmArm $(t "$stamp") $(t "$prev") $unclean $(t "$rep") $(t "$this")"
      echo "Write-Output \"$name $want \$r\""
    done
  } > "$drv"
  "$PWSH" -NoProfile -File "$drv" 2>&1
}

check_table(){ # 0 = every row as expected
  local got; got=$(run_table "$1")
  echo "$got" > "$OUT/last-table.txt"
  local n=0 bad=0
  while read -r name want is; do
    [ -n "$name" ] || continue
    n=$((n+1)); [ "$want" = "$is" ] || bad=$((bad+1))
  done <<< "$got"
  [ "$n" = 7 ] && [ "$bad" = 0 ]
}

if check_table "$OUT/fn.ps1"; then ok "decision: all 7 branches answer as specified (incl. a STALE stamp, which must report)"
else bad "decision: $(grep -vE '^\s*$' "$OUT/last-table.txt" | awk '$2!=$3{printf "%s want=%s got=%s; ", $1,$2,$3}')"; fi

# ---- the defect knobs: each is a real mistake, and the table must catch it ---------------------------
knob(){ # $1 label, $2 sed expression that injects the defect
  local f="$OUT/knob.ps1"; sed -E "$2" "$OUT/fn.ps1" > "$f"
  if cmp -s "$f" "$OUT/fn.ps1"; then bad "$1 (the knob changed nothing - it does not match the source)"; return; fi
  if check_table "$f"; then bad "$1 - the table still passes with the defect present (decoration)"
  else ok "$1 (the table catches it: $(grep -vE '^\s*$' "$OUT/last-table.txt" | awk '$2!=$3{printf "%s->%s ", $1,$3}'))"; fi
}
knob "knob: a stamp is trusted without checking it belongs to the previous session (stale reads as armed)" \
     's/if \(\$StampTime -and \$StampTime -gt \$PrevBoot\)/if ($StampTime)/'
knob "knob: an unexpected shutdown is treated as a missed re-arm (a notification for a kill)" \
     '/return .unclean./d'
knob "knob: the once-per-boot guard is gone (the same boot notifies dom0 twice)" \
     '/return .already-reported./d'
knob "knob: a first boot with no previous session is judged anyway" \
     '/return .nojudge./d'

# ---- the action: no interpreter, and the stamp is the LAST link --------------------------------------
# Each predicate reads a NAMED source file, so the same four can be re-run against a mutated copy -
# otherwise they are greps that would pass on any file that happens to contain the right words.
xml_of(){ awk '/^\$xmlRearm = @"/,/^"@/' "$1"; }
arg_of(){ command grep -n 'argRearm = ' -A 3 "$1" | sed -n '1,4p'; }
a_cmd(){      xml_of "$1" | grep -q "<Command>cmd.exe</Command>" && ! xml_of "$1" | grep -q "powershell"; }
a_chain(){    [ "$(arg_of "$1" | grep -c '&amp;&amp;')" -ge 2 ]; }
a_stamplast(){ arg_of "$1" | tr '\n' ' ' | grep -qE 'DEV_VIF.*echo rearmed'; }
a_escaped(){  arg_of "$1" | grep -q 'VEN_XP0001\^&amp;DEV_VIF'; }
a_samepath(){ [ "$(command grep -c 'QubesPvNic-rearm.stamp' "$1")" -ge 2 ]; }
# THE DECODED COMMAND LINE, not the escaped source text. Jev flagged escaping-or-quoting at 0.39 on this
# diff (confidence 0.27 - a low-confidence answer is a finding, not noise), so the check stopped being a
# grep for what was typed: it renders the XML and asserts what an XML parser hands Task Scheduler, which
# is the command line cmd.exe receives. Measured 2026-10-07, before the first rig run.
WANT='/c reg add HKLM\SYSTEM\CurrentControlSet\Services\XEN\Unplug /v NICS /t REG_DWORD /d 1 /f >nul && reg add HKLM\SYSTEM\CurrentControlSet\Enum\XENBUS\VEN_XP0001^&DEV_VIF /f >nul && echo rearmed>C:\ProgramData\QubesPvNic-rearm.stamp'
a_decoded(){ local got
  got=$("$PWSH" -NoProfile -File "$ROOT/tools/tests/pvnic-rearm-decode.ps1" "$1" 2>&1 | sed -n 's/^DECODED>>\(.*\)<<$/\1/p')
  echo "$got" > "$OUT/decoded.txt"
  [ "$got" = "$WANT" ]; }

ashape(){ # $1 label, $2 predicate, $3 sed expression injecting the defect
  local f="$OUT/act-knob.ps1"
  if ! "$2" "$SRC"; then bad "$1"; return; fi
  sed -E "$3" "$SRC" > "$f"
  if cmp -s "$f" "$SRC"; then bad "$1 (the knob changed nothing - it does not match the source)"; return; fi
  if "$2" "$f"; then bad "$1 - still passes with the defect injected (decoration)"; else ok "$1 (and FAILS with the defect injected)"; fi
}
ashape "action: the re-arm task starts cmd.exe, never an interpreter that has to parse the payload" \
       a_cmd 's|<Command>cmd.exe</Command>|<Command>powershell.exe</Command>|'
ashape "action: the writes and the stamp are chained with && so the order is strict" \
       a_chain 's/&amp;&amp;/;/g'
ashape "action: the stamp is written ONLY after both writes, as the chain final link" \
       a_stamplast '/echo rearmed/d'
ashape "action: the ampersand in the Enum key is escaped for BOTH cmd (^&) and XML (&amp;)" \
       a_escaped 's/VEN_XP0001\^&amp;DEV_VIF/VEN_XP0001\&amp;DEV_VIF/'
# sed's /2 flag counts PER LINE, and the two mentions are on different lines - so the first version of
# this knob matched nothing and the check reported ITSELF as decoration. The knob deletes the reader's
# path instead, which is the real defect it guards against: an action stamping a file nobody reads.
ashape "action: the stamp the action writes is the file the boot judgement reads" \
       a_samepath '/^\$stampPath/d'
ashape "action: the DECODED command line is exactly the one intended (^& for cmd, >nul, && chain, stamp last)" \
       a_decoded 's/VEN_XP0001\^&amp;DEV_VIF/VEN_XP0001\&amp;DEV_VIF/' 

# ---- and the reporter no longer claims what it cannot know -------------------------------------------
REP="$ROOT/guest/qwt-report-death.ps1"
rshape(){ local label="$1" cond="$2"; if eval "$cond"; then ok "$label"; else bad "$label"; fi; }
rshape "reporter: 267014 is still ignored for every task (a stop we asked for is not a death)" \
       'command grep -q "code -eq 267014" "$REP" && command grep -q "ignore = \$true" "$REP"'
rshape "reporter: the re-arm impact line no longer asserts the latch was not re-armed on that path" \
       '! command grep -q "The PV NIC latch was not re-armed at shutdown" "$REP"'

# ---- NO WARNING ON A NORMAL BOOT, A VISIBLE ERROR WHEN IT ACTUALLY MATTERS -----------------------
# Owner, 2026-10-08: "PV NIC setup failure still shown, whatever it means" and then "we need no
# warnings on normal operation and visible error on actual failure."
#
# The DECISION above was right; its CONSEQUENCE was wrong, which is why the earlier fix did not stop
# the notification: the 'report' branch called Fault, Fault sets $script:faulted, and Ok - the
# payload's only success exit - exits 1 whenever anything faulted. Task Scheduler then recorded
# result 1 on QubesPvNic and qwt-report-death.ps1 reported "The PV NIC setup task failed | Cause:
# incorrect function" to dom0, on a guest with nothing wrong with it.
#
# THE LEVEL COMES FROM THE MECHANISM, not from taste. xen.sys reads Services\XEN\Unplug\NICS
# DELETE-ON-READ at boot start, so the payload's own re-arm (its first step) arms the NEXT boot and
# does not fix this one. A missing stamp therefore means THIS boot ran with no unplug latch, and
# that costs something only when there is a PV NIC to unplug:
#   vif present -> xenvif's NET child can demand a restart instead of starting at problem 0
#                  (findings/network.md) - a real, user-visible failure: ERROR, and the task fails
#   no vif      -> nothing was unplugged because there was nothing to unplug: one log line, no
#                  warning, no event, no marker, no non-zero exit
PAY="$OUT/payload.ps1"
python3 - "$SRC" "$PAY" <<'PY2'
import sys, io
s = io.open(sys.argv[1], encoding='utf-8').read()
i = s.index("$body = @'")
j = s.index("\n'@", i)
io.open(sys.argv[2], 'w', encoding='utf-8').write(s[s.index('\n', i)+1:j] + '\n')
PY2
[ -s "$PAY" ] || { echo "FAIL  the boot payload could not be extracted - nothing below ran"; exit 2; }

# the branch body, isolated by its switch label so a Fault elsewhere cannot satisfy these
rep=$(python3 - "$PAY" <<'PY3'
import sys, io, re
s = io.open(sys.argv[1], encoding='utf-8').read()
# THE SWITCH LABEL, not the first literal: Test-QwtRearmArm contains `return 'report'`, and
# anchoring on the bare string extracted the tail of THAT function - which naturally contains
# neither VifDevicePresent nor Fault, so two checks reported a defect the code did not have.
m = re.search(r"^[ \t]*'report'[ \t]*\{", s, re.M)
if not m:
    raise SystemExit("the 'report' switch label is not present")
i = m.start()
d = 0; j = s.index('{', i)
for k in range(j, len(s)):
    if s[k] == '{': d += 1
    elif s[k] == '}':
        d -= 1
        if d == 0: break
print(s[i:k+1])
PY3
)
[ -n "$rep" ] || { echo "FAIL  the 'report' branch could not be isolated"; exit 2; }

if printf '%s' "$rep" | command grep -q 'VifDevicePresent'; then
  ok "level_decided_by_effect: the branch asks whether a PV NIC is present before deciding anything"
else
  bad "level_decided_by_effect: the branch does not consult the bus, so one level is applied to both cases"
fi
if printf '%s' "$rep" | command grep -q 'Fault '; then
  ok "real_case_is_an_error: with a vif present it still Faults, so an actual failure stays visible"
else
  bad "real_case_is_an_error: nothing Faults - a boot that really lost its unplug latch would be silent"
fi
if printf '%s' "$rep" | command grep -qE 'EntryType +(Warning|Error)|Repaired '; then
  bad "no_warning_on_normal_boot: the branch still raises a Warning/Error event on the no-vif path"
else
  ok "no_warning_on_normal_boot: the no-effect case is a log line only - no warning, no event"
fi
if printf '%s' "$rep" | command grep -q 'Set-Content \$mark'; then
  bad "no_failed_marker_on_normal_boot: it writes QubesPvNic-FAILED.txt, which health-check.ps1 reports"
else
  ok "no_failed_marker_on_normal_boot: no FAILED marker on the path that cost nothing"
fi
# the claim that was WRONG and must not come back: this run's re-arm fixes the NEXT boot, not this one
if printf '%s' "$rep" | command grep -qiE 'so the guest is correct now|re-armed by this (boot|run)'"'"'s'; then
  bad "no_false_repair_claim: the branch claims this boot was fixed; the latch is delete-on-read, so it was not"
else
  ok "no_false_repair_claim: the message says the re-arm is for the NEXT boot"
fi

# AND THE VERDICT MACHINERY ITSELF, DRIVEN rather than read: a real fault must still exit 1.
python3 - "$PAY" "$OUT/verdict.ps1" <<'PY4'
import sys, io
s = io.open(sys.argv[1], encoding='utf-8').read()
out = []
for name in ('Fault', 'Ok'):
    i = s.find('function ' + name)
    if i < 0: continue
    d = 0; j = s.index('{', i)
    for k in range(j, len(s)):
        if s[k] == '{': d += 1
        elif s[k] == '}':
            d -= 1
            if d == 0: break
    out.append(s[i:k+1])
io.open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PY4
drive_verdict(){ # $1 = the call to make before Ok; echoes the exit code
  { echo '$script:faulted = $null'
    echo '$mark = Join-Path ([IO.Path]::GetTempPath()) ("pvnic-mark-" + [Guid]::NewGuid().ToString("N"))'
    echo 'function L([string]$m) { }'
    echo 'function New-EventLog { param([Parameter(ValueFromRemainingArguments=$true)]$r) }'
    echo 'function Write-EventLog { param([Parameter(ValueFromRemainingArguments=$true)]$r) }'
    cat "$OUT/verdict.ps1"
    echo "$1"
    echo "Ok 'applied'"
  } > "$OUT/drive.ps1"
  "$PWSH" -NoProfile -File "$OUT/drive.ps1" >/dev/null 2>&1
  echo $?
}
rc_clean=$(drive_verdict '')
rc_fault=$(drive_verdict "Fault 'a step really failed'")
rc_log=$(drive_verdict "L 'a condition that cost nothing'")
[ "$rc_clean" = 0 ] && ok "clean_run_exits_zero: nothing faulted, Ok exits 0 (rc=$rc_clean)" \
                    || bad "clean_run_exits_zero: rc=$rc_clean"
[ "$rc_fault" = 1 ] && ok "unrepaired_fault_still_exits_one: a real failure is STILL reported to dom0 (rc=$rc_fault)" \
                    || bad "unrepaired_fault_still_exits_one: rc=$rc_fault - a real failure would now be CONCEALED"
[ "$rc_log" = 0 ] && ok "log_line_does_not_fail_the_task: a logged no-effect condition leaves the verdict alone (rc=$rc_log)" \
                  || bad "log_line_does_not_fail_the_task: rc=$rc_log"

echo "--- $pass passed, $fail failed; outputs in $OUT"
[ "$fail" = 0 ] && exit 0 || exit 1
