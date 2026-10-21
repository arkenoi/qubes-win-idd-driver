#!/bin/bash
# A CANCEL MUST NOT LEAVE THE CAMPAIGN RUNNING.
#
# ACCEPTCANCELORPHAN, open since 2026-10-14 and root-caused 2026-10-21: tools/release-acceptance.sh
# NEVER sourced run-lib.sh and never called job_init, so it had no teardown trap at all - while its
# own comment asserted that "run-lib.sh already tears down its descendant tree on SIGTERM". A
# SIGTERM to the leader exited the driver and left matrix.sh running, holding the rig. Observed on
# three separate cancels, the surviving pid read from /proc each time. vmlock.sh's documented
# contract is to cancel by TERMing the leader, which only works if the leader tears down.
#
# This drives the real run-lib teardown over a stand-in child, because the campaign itself needs a
# rig. No pattern is ever matched against a process: every pid here is one this suite recorded.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/acancel-XXXXXX"); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

# ---- 1. the leader must actually install the teardown ------------------------------------------
blk=$(awk '/# RA-TEARDOWN-A/,/# RA-TEARDOWN-B/' tools/release-acceptance.sh)
if printf '%s' "$blk" | command grep -qa 'job_init' && printf '%s' "$blk" | command grep -qa 'run-lib.sh'; then
  ok "release-acceptance.sh loads run-lib and calls job_init"
else
  no "the leader still has no teardown" "that IS ACCEPTCANCELORPHAN"
fi
if printf '%s' "$blk" | command grep -qa 'dirname "\$0"'; then
  ok "it loads run-lib by a \$0-relative path, not from the caller's cwd"
else
  no "the load is cwd-relative" "the block sits above the cd to the repo root"
fi

# ---- 2. THE PROPERTY: TERM to the leader reaps the child ---------------------------------------
# A stand-in leader: run-lib's traps, then a child that would outlive an untrapped parent.
cat > "$T/leader.sh" <<'LEAD'
#!/bin/bash
cd "$1" || exit 2
. mgmt/harness/run-lib.sh
job_init "probe-leader"
bash -c 'echo $$ > "$0.child"; while :; do sleep 1; done' "$2" &
echo $! > "$2.pipeline"
wait
LEAD
chmod +x "$T/leader.sh"
"$T/leader.sh" "$ROOT" "$T/c" >"$T/leader.out" 2>&1 &
LEADER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/c.child" ] && break; sleep 0.3; done
CHILD=$(cat "$T/c.child" 2>/dev/null || echo "")
if [ -n "$CHILD" ] && [ -r "/proc/$CHILD/cmdline" ]; then
  ok "the stand-in child is running (pid recorded by the child itself, not matched by pattern)"
else
  no "could not start the stand-in child" "the legs below would test nothing"
fi

kill -TERM "$LEADER" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do [ -r "/proc/$LEADER/cmdline" ] || break; sleep 0.3; done
for _ in 1 2 3 4 5 6; do [ -r "/proc/$CHILD/cmdline" ] || break; sleep 0.3; done
if [ -n "$CHILD" ] && [ ! -r "/proc/$CHILD/cmdline" ]; then
  ok "TERM to the leader reaped the child - a cancel does not leave the campaign running"
else
  no "the child survived the leader's TERM (pid $CHILD)" "$(cat "$T/leader.out" 2>/dev/null | tail -2)"
  [ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null
fi
command grep -qa 'TORE DOWN' "$T/leader.out" \
  && ok "and the teardown says so in its own output" \
  || no "the teardown left no record" "$(tail -2 "$T/leader.out" 2>/dev/null)"

# ---- 3. SEEN TO FAIL: the pre-fix leader, with no job_init, orphans the child -------------------
cat > "$T/leader-nofix.sh" <<'LEAD2'
#!/bin/bash
cd "$1" || exit 2
bash -c 'echo $$ > "$0.child2"; while :; do sleep 1; done' "$2" &
wait
LEAD2
chmod +x "$T/leader-nofix.sh"
"$T/leader-nofix.sh" "$ROOT" "$T/c" >/dev/null 2>&1 &
L2=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/c.child2" ] && break; sleep 0.3; done
C2=$(cat "$T/c.child2" 2>/dev/null || echo "")
kill -TERM "$L2" 2>/dev/null
for _ in 1 2 3 4 5 6; do [ -r "/proc/$L2/cmdline" ] || break; sleep 0.3; done
sleep 1
if [ -n "$C2" ] && [ -r "/proc/$C2/cmdline" ]; then
  ok "SEEN TO FAIL: without job_init the child SURVIVES the leader's TERM (pid $C2 still alive)"
  kill -TERM "$C2" 2>/dev/null
else
  no "the pre-fix shape did not orphan its child" "the property cannot be driven ($C2)"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
