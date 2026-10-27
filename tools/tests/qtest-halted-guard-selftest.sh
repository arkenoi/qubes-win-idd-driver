#!/bin/bash
# A BACKGROUND JOB MUST NOT BE ABLE TO WAKE A GUEST: qtest refuses a HALTED target, with no override.
# run: tools/tests/qtest-halted-guard-selftest.sh
# pass: exit 0
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------- 1. the hook's mutation pattern
# The pattern is taken OUT of the shipped hook, not retyped: a copy here would pass while the hook
# matched something else.
hookcheck(){ python3 - "$ROOT/tools/hooks/serial-rig-gate.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# EVAL THE SHIPPED EXPRESSION, do not re-parse it. The first version of this paired quotes with a
# regex to collect the r'' strings, and the comment `# shutdown-lib.sh's wrapper ...` inside the
# expression carries an APOSTROPHE: the pairing shifted and the last two alternatives were silently
# dropped, so the suite reported a miss that the hook does not have. A heuristic that reads source
# is one more thing that can be wrong; the real expression cannot disagree with itself.
m = re.search(r'mut = re\.compile\((.*?)\n\s*re\.I\)', src, re.S)
if not m:
    print("NOPATTERN"); sys.exit(0)
try:
    mut = eval("re.compile(" + m.group(1) + "\n re.I)", {"re": re})
except Exception as e:
    print("NOPATTERN"); sys.exit(0)
CASES = [
    ("qrexec-client-vm win11-nfy qubes.GetAppmenus", 1, "bare qrexec to a GUEST (the measured waker)"),
    ("qrexec-client-vm win10-acc qubes.VMShell", 1, "a service that was already listed"),
    ("qrexec-client-vm win10-acc admin.vm.Start", 1, "an admin verb that DOES act"),
    ("qrexec-client-vm win10-acc admin.vm.Stats", 0, "a passive admin read - how a run is watched"),
    ("qrexec-client-vm win10-acc admin.vm.CurrentState", 0, "a passive state read"),
    ("qrexec-client-vm dom0 local.WinScreenshot+win11-nfy", 0, "the per-window capture path (dom0)"),
    ("qrexec-client-vm dom0 local.WinFullScreen", 0, "the desktop capture path (dom0)"),
    ("qrexec-client-vm dom0 local.WinResize+1024x768", 0, "the resize service (dom0)"),
    ("qvm-ls --fields NAME", 0, "a passive read"),
    ("./tools/qtest state", 0, "monitoring a running job"),
    ("qvm-start win11-nfy", 1, "an explicit start"),
]
bad = [f"{t!r} want={w} got={int(bool(mut.search(t)))} ({why})"
       for t, w, why in CASES if bool(mut.search(t)) != bool(w)]
print("OK" if not bad else "BAD " + " | ".join(bad))
PY
}
r=$(hookcheck)
case "$r" in
  OK)         ok "serial-rig-gate: any qrexec call to a GUEST is mutating, dom0 services stay exempt" ;;
  NOPATTERN)  no "serial-rig-gate: could not find the mut pattern - this suite is not testing it" ;;
  *)          no "serial-rig-gate: ${r#BAD }" ;;
esac

# NEGATIVE CONTROL: the three-service list the hook used to carry must FAIL the first case.
pre=$(python3 - <<'PY'
import re
mut = re.compile(r'qubes\.WindowsUpdate|qubes\.VMShell|qubes\.VMExec', re.I)
print("MISSED" if not mut.search("qrexec-client-vm win11-nfy qubes.GetAppmenus") else "caught")
PY
)
[ "$pre" = MISSED ] && ok "negative control: the old three-service list MISSES the measured waker" \
                    || no "negative control: the old list already caught it, so nothing was fixed"

# ---------------------------------------------------------------- 2. qtest refuses a halted target
# Stub qvm-check so no guest is needed. $1 of the stub decides the answer.
mkstub(){ # $1=dir $2=halted|running
  mkdir -p "$1"
  cat > "$1/qvm-check" <<STUB
#!/bin/bash
# --quiet <vm>   -> exists (always true here)
# --running <vm> -> $2
for a in "\$@"; do [ "\$a" = --running ] && exit $([ "$2" = running ] && echo 0 || echo 1); done
exit 0
STUB
  # a qrexec that would ANSWER - so a missing guard shows up as success, not as a stub failure
  cat > "$1/qrexec-client-vm" <<'STUB'
#!/bin/bash
echo "THE CALL REACHED THE GUEST"
exit 0
STUB
  chmod +x "$1/qvm-check" "$1/qrexec-client-vm"
}

try(){ # $1=halted|running $2=verb -> "rc|output"
  local d="$T/stub.$1.$RANDOM"; mkstub "$d" "$1"
  local out rc
  out=$(cd "$ROOT" && PATH="$d:$PATH" QTEST_VM=somevm timeout 30 ./tools/qtest "$2" 'cmd /c echo hi' 2>&1); rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

for v in run ps push pushrun synctime incoming; do
  r=$(try halted "$v"); rc=${r%%|*}; out=${r#*|}
  if [ "$rc" = 3 ] && [[ "$out" != *"REACHED THE GUEST"* ]]; then
    ok "qtest $v: refuses a HALTED target (rc=3) and never reaches it"
  else
    no "qtest $v: rc=$rc on a halted target, output: ${out:0:90}"
  fi
done

# the positive control: a RUNNING target is untouched by the guard
r=$(try running run); rc=${r%%|*}; out=${r#*|}
[[ "$out" == *"REACHED THE GUEST"* ]] && ok "qtest run: a RUNNING target is reached as before (positive control)" \
                                      || no "qtest run: the guard also blocks a running guest (rc=$rc): ${out:0:90}"

# and the verbs that must stay usable on a halted guest - monitoring, and the explicit boot
for v in state start; do
  d="$T/exempt.$v"; mkstub "$d" halted
  out=$(cd "$ROOT" && PATH="$d:$PATH" QTEST_VM=somevm timeout 30 ./tools/qtest "$v" 2>&1); rc=$?
  [ "$rc" != 3 ] && ok "qtest $v: exempt on a halted guest (rc=$rc), so monitoring and booting still work" \
                 || no "qtest $v: refused on a halted guest - the guard caught an exempt verb"
done

# NO OVERRIDE KNOB. A knob is what an orphaned loop inherits from the environment that spawned it,
# and the owner's standing instruction (2026-10-18) is to not add one without asking.
if command grep -aqE 'QTEST_ALLOW_HALTED|ALLOW_HALTED|FORCE_HALTED' "$ROOT/tools/qtest"; then
  no "tools/qtest carries an override knob for the halted guard"
else
  ok "no override knob exists for the halted guard"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
