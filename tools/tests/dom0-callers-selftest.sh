#!/bin/bash
# the start-menu gate must go RED on each way the stream can be wrong
# run: tools/tests/dom0-callers-selftest.sh
# pass: exit 0
set -u
cd "$(dirname "$0")/../.." || exit 1
CHK=mgmt/harness/dom0-callers-check.sh
PATHS=tools/tests/appmenus-win11de-25h2.paths
pass=0; fail=0
T=$(mktemp -d "${TMPDIR:-/tmp}/dom0callers-st.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

# NO RIG CALLS FROM AN OFFLINE SUITE. DOM0CALLERS_STREAM replaces the check's qrexec call, but not
# its `qvm-ls --raw-data --fields STATE "$VM"` or its `qvm-prefs "$VM" qrexec_timeout`, so every run
# of this suite fired 26 admin calls at `fixture-vm` and `this-vm-does-not-exist-xyz`. Both names
# are deliberately absent from the rig, so every call was DENIED - and a denied Admin API call is
# written to the owner's dom0 journal, with `qvm-ls --fields` being the one spelling this project
# has a standing prohibition on. Measured 2026-10-21 by the runner's rig shim.
# The stubs return EXACTLY what the rig returns for a name that does not exist - nothing, rc 1 - so
# no assertion below changes meaning: Part C still reads "not Running" and "not Halted" from an
# empty state, which is the condition it is testing.
mkdir -p "$T/bin"
for _c in qvm-ls qvm-prefs; do printf '#!/bin/sh\nexit 1\n' > "$T/bin/$_c"; chmod +x "$T/bin/$_c"; done
export PATH="$T/bin:$PATH"

ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

[ -r "$CHK" ] || { echo "no $CHK"; exit 2; }
[ -r "$PATHS" ] || { echo "no $PATHS - the fixture source is missing"; exit 2; }

# ---- the good stream, generated from the measured path list ------------------------------------
python3 - "$PATHS" >"$T/good" <<'PY'
import re, sys
paths = [l.rstrip('\n') for l in open(sys.argv[1], encoding='utf-8')
         if l.strip() and not l.startswith('#')]
def ident(p):
    stem = p[:-4] if p.lower().endswith('.lnk') else p
    return re.sub(r'[^A-Za-z0-9._-]', '_', stem.replace('\\', '-'))
def label(p):
    stem = p[:-4] if p.lower().endswith('.lnk') else p
    return stem.replace('\\', ' ')
out = []
for p in paths:
    i, n = ident(p), label(p)
    out.append("%s.desktop:Name=%s" % (i, n))
    out.append("%s.desktop:Exec=cmd.exe /c \"C:\\\\ProgramData\\\\Microsoft\\\\Windows\\\\Start Menu\\\\Programs\\\\%s\"" % (i, p.replace('\\', '\\\\')))
    out.append("%s.desktop:Comment=%s" % (i, n))
    out.append("%s.desktop:Icon=%040x" % (i, abs(hash(i)) % (1 << 160)))
# The two launchers dom0 wires per qube off FIXED ids; a Windows guest emitting neither leaves
# dom0's own Terminal and File Manager rows pointing at nothing.
for i, n in (('qubes-run-terminal', 'Run Terminal'), ('qubes-open-file-manager', 'Open File Manager')):
    out.append("%s.desktop:Name=%s" % (i, n))
    out.append("%s.desktop:Exec=qubes-rpc-multiplexer qubes.StartApp+%s" % (i, i))
    out.append("%s.desktop:Comment=%s" % (i, n))
print("\n".join(out))
PY
ents=$(command grep -oa '^[A-Za-z0-9._-]*\.desktop' "$T/good" | sort -u | wc -l)
[ "$ents" -ge 10 ] && ok "fixture: $ents entries generated from the measured path list" \
  || bad "fixture: only $ents entries - the generator is broken, not the check"

# run the check against a stream file; VM name is never touched in fixture mode
run(){ DOM0CALLERS_STREAM="$1" bash "$CHK" fixture-vm >"$T/out" 2>&1; echo $?; }

echo "PART A  the good stream passes, and says it is a fixture"
rc=$(run "$T/good")
[ "$rc" = 0 ] && ok "a correct stream is green (rc=0)" || { bad "a correct stream came back rc=$rc"; sed 's/^/        /' "$T/out"; }
[ "$(command grep -c 'FIXTURE MODE' "$T/out")" -ge 1 ] \
  && ok "the log says FIXTURE MODE, so a fixture can never read as a guest measurement" \
  || bad "fixture mode is silent - the gate's log would not show it was handed a file"
command grep -q 'FIXTURE, not a guest measurement' "$T/out" \
  && ok "and the VERDICT line repeats it (that is the line a reader quotes)" \
  || bad "the verdict line does not say it was a fixture"

echo "PART B  one defect at a time, each must go RED"
redcase(){ # <label> <expected-message-fragment> <builder-command...>
  local label="$1" frag="$2"; shift 2
  "$@" >"$T/bad" 2>/dev/null
  local rc; rc=$(run "$T/bad")
  if [ "$rc" = 0 ]; then
    bad "$label: still GREEN - this defect is invisible to the gate"
  elif command grep -qa "$frag" "$T/out"; then
    ok "$label: red, and the message names it"
  else
    bad "$label: red but the message does not say why (expected '$frag')"
    sed 's/^/        /' "$T/out" | head -5
  fi
}

# 1. ZERO BYTES. dom0 shows an empty menu and reports nothing.
redcase "an empty stream" "0 bytes" true
# 2. THE CMD BANNER. A real capture of this service through the VMShell path starts with it.
redcase "cmd's banner in the parse channel" "cmd's banner" \
  bash -c 'printf "Microsoft Windows [Version 10.0.26200.8037]\n\n"; cat '"$T/good"
# 3. A LINE THAT DOES NOT PARSE: a key receive.py does not accept. Silently dropped in production.
redcase "an unaccepted key" "do NOT parse" \
  bash -c 'cat '"$T/good"'; echo "Extra_App.desktop:Nam=Typo In The Key"'
# 4. A SPACE IN THE ID: create_template() refuses it, so the entry cannot exist.
redcase "a space in the id" "do NOT parse" \
  bash -c 'cat '"$T/good"'; echo "Bad App.desktop:Name=Space In Id"'
# 5. A NON-ASCII BYTE in an id: dom0 decodes ASCII and drops the rest.
redcase "a non-ASCII byte in an id" "do NOT parse" \
  bash -c 'cat '"$T/good"'; printf "Zubeh\xc3\xb6r.desktop:Name=Umlaut In Id\n"'
# 6. AN ENTRY WITH NO Name: unusable to dom0, and it was reachable - the emitter's namer had a hole.
redcase "an entry with no Name" "no Name" \
  bash -c 'cat '"$T/good"'; echo "Nameless_App.desktop:Exec=cmd.exe /c x"; echo "Nameless_App.desktop:Icon=deadbeef"'
# 7. TWO ENTRIES READING ALIKE: the measured German-guest defect (Edge twice, folder-prefix labels).
redcase "two entries with the same label" "duplicate label" \
  bash -c 'cat '"$T/good"'; echo "Another_Id.desktop:Name=Run Terminal"'
# 8. THE AMPUTATION SHAPE: the owner's "you silently dropped most of the apps and tell me it is fine?"
redcase "a menu cut down to three entries" "amputation shape" \
  bash -c 'head -12 '"$T/good"
# 9. A FIXED LAUNCHER MISSING: dom0's own menu row points at nothing.
redcase "qubes-run-terminal not reported" "qubes-run-terminal" \
  bash -c 'command grep -av "^qubes-run-terminal" '"$T/good"
redcase "qubes-open-file-manager not reported" "qubes-open-file-manager" \
  bash -c 'command grep -av "^qubes-open-file-manager" '"$T/good"

echo "PART C  the state IS the test condition"
# A cold check against a Running guest measures the warm path under a cold label. Refusal, not a
# warning - "never substitute test conditions".
bash "$CHK" --cold this-vm-does-not-exist-xyz >"$T/out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "--cold on a guest that is not Halted is REFUSED (rc=2), not relabelled" \
  || bad "--cold ran against a non-Halted guest (rc=$rc)"
command grep -q 'refusing to label a warm call cold' "$T/out" \
  && ok "and it says why in those words" || bad "the refusal does not explain itself"
bash "$CHK" this-vm-does-not-exist-xyz >"$T/out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "warm on a guest that is not Running is REFUSED (rc=2)" \
  || bad "the warm check ran against a guest that is not Running (rc=$rc)"

echo "PART D  the fixture knob must never be set by the campaign"
# COMMENTS STRIPPED FIRST: this file's own prose names the variable, and so does the check's. A
# grep of the raw harness finds the explanation and calls it a setting - that mistake has been made
# repeatedly in this repo's checks.
for f in mgmt/harness/matrix.sh tools/release-acceptance.sh; do
  [ -r "$f" ] || continue
  n=$(sed 's/#.*//' "$f" | command grep -c 'DOM0CALLERS_STREAM=')
  [ "$n" -eq 0 ] && ok "$(basename "$f") does not set DOM0CALLERS_STREAM" \
    || bad "$(basename "$f") SETS DOM0CALLERS_STREAM - the gate would grade a file, not a guest"
done

echo "PART E  the check itself cannot be gutted"
# A suite of greps over a script passes just as well on a script that no longer checks anything.
# The real guard: strip the per-line parse out and Part B must collapse.
# Disable the COLLECTION, not the control flow: `if not m: ... continue` still has to skip the bad
# line, or the parser raises on m=None and goes red for the wrong reason - which is what the first
# version of this check did, and it read exactly like a pass.
sed 's/unparsed\.append(/None and (/' "$CHK" >"$T/gutted.sh"
bash -c 'cat '"$T/good"'; echo "Extra_App.desktop:Nam=Typo"' >"$T/bad"
DOM0CALLERS_STREAM="$T/bad" bash "$T/gutted.sh" fixture-vm >/dev/null 2>&1; grc=$?
[ "$grc" = 0 ] \
  && ok "with the parse check stubbed out the unaccepted key passes (so Part B's red was real)" \
  || bad "the stubbed check still reports red (rc=$grc) - Part B may be red for another reason"

echo "dom0-callers-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
