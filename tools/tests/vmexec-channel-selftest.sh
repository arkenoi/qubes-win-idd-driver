#!/bin/bash
# vmexec-channel-selftest.sh - the VMExec argument encoder, round-tripped through the SHIPPED
# guest-side decoder. No guest.
#
# WHY A ROUND TRIP AND NOT A FIXTURE. mgmt/harness/vmexec-channel-check.sh builds a
# `qubes.VMExec+<escaped argv>` service name, and if that encoding is wrong the call fails in a way
# that looks exactly like the defect it is testing for: no output. So the encoder is proven against
# `rpc/qubes-rpc-services/VMExec-Decode.ps1` - the code that actually reads it on the guest - using
# pwsh here, rather than against my reading of that file.
#
# This is the lesson from 2026-10-09 in another form: fixtures come from the real artefact, not from
# my model of it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

CHECK=mgmt/harness/vmexec-channel-check.sh
DECODER=$(ls artifacts/rel/rpc/qubes-rpc-services/VMExec-Decode.ps1 2>/dev/null | head -1)
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $*"; }
bad(){ fail=$((fail+1)); echo "FAIL $*"; }
[ -f "$CHECK" ] || { echo "FAIL $CHECK is missing"; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/vmexec-selftest.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

# The encoder, lifted from the shipped script so this cannot drift from what runs.
eval "$(sed -n '/^vmexec_encode_arg()/,/^}$/p' "$CHECK")"
eval "$(sed -n '/^vmexec_service()/,/^}$/p' "$CHECK")"
declare -f vmexec_encode_arg >/dev/null || { echo "FAIL could not extract the encoder"; exit 2; }

# ---- 1. the escaping rules, as the decoder states them ----------------------------------------
ck(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi; }
ck "alphanumerics and ._ pass through"  "cmd.exe_1"  "$(vmexec_encode_arg 'cmd.exe_1')"
ck "a slash becomes -2F"                "-2Fc"       "$(vmexec_encode_arg '/c')"
ck "a literal dash doubles"             "----"       "$(vmexec_encode_arg '--')"
ck "a space becomes -20"                "a-20b"      "$(vmexec_encode_arg 'a b')"
ck "hex is UPPERCASE"                   "-3E"        "$(vmexec_encode_arg '>')"
ck "elements join with +"               "qubes.VMExec+cmd.exe+-2Fc+echo" "$(vmexec_service cmd.exe /c echo)"
# The decoder REFUSES anything outside [a-zA-Z0-9._-], so the encoder must never emit such a byte.
enc=$(vmexec_service cmd.exe /c 'echo HI 1>&2 & dir "C:\x"')
ck "every byte emitted is decoder-legal" "" "$(printf '%s' "${enc#qubes.VMExec+}" | tr -d 'a-zA-Z0-9._+-')"

# ---- 2. ROUND TRIP through the shipped PowerShell decoder --------------------------------------
if [ -z "$DECODER" ]; then
  bad "round trip: no shipped VMExec-Decode.ps1 found to decode against"
elif ! PWSH="${PWSH:-/home/user/pwsh74/pwsh}"; ! command -v "$PWSH" >/dev/null 2>&1 && ! PWSH="$(command -v pwsh 2>/dev/null)"; [ -z "${PWSH:-}" ]; then
  bad "round trip: no pwsh found (set PWSH=/path/to/pwsh) - the encoder is unproven against the real decoder"
else
  ok "round trip: decoding with the shipped $DECODER"
  # Each case is encoded here and decoded THERE; the decoder is dot-sourced unchanged.
  cat > "$T/rt.ps1" <<'PS'
param([string]$Decoder, [string]$Cases)
. $Decoder
$bad = 0
foreach ($line in Get-Content $Cases) {
    if ($line -eq '') { continue }
    $parts = $line -split "`t", 2
    $encoded = $parts[0]; $expected = $parts[1]
    try { $got = VMExec-Decode $encoded } catch { Write-Output "THREW`t$encoded`t$($_.Exception.Message)"; $bad++; continue }
    if ($got -ne $expected) { Write-Output "MISMATCH`t$encoded`tgot=$got`twant=$expected"; $bad++ }
}
Write-Output "BAD=$bad"
PS
  : > "$T/cases.tsv"
  while IFS= read -r arg; do
    printf '%s\t%s\n' "$(vmexec_encode_arg "$arg")" "$arg" >> "$T/cases.tsv"
  done <<'ARGS'
cmd.exe
/c
echo HELLO
exit 7
cmd /c echo NESTED
powershell -NoProfile -Command Write-Host hi
C:\Program Files\Qubes Tools\bin\x.exe
echo X > C:\f.txt & echo Y
a-b--c
ARGS
  out=$("$PWSH" -NoProfile -File "$T/rt.ps1" "$PWD/$DECODER" "$T/cases.tsv" 2>&1) || true
  printf '%s\n' "$out" | command grep -vE '^BAD=' | sed 's/^/     /' | head -6
  nbad=$(printf '%s\n' "$out" | sed -n 's/^BAD=//p' | tail -1)
  ncases=$(wc -l < "$T/cases.tsv")
  if [ "${nbad:-1}" = "0" ]; then
    ok "round trip: all $ncases argv forms decode back to themselves"
  else
    bad "round trip: $nbad of $ncases argv forms did not survive (see above)"
  fi
fi

# ---- 3. the check asserts the channels the GOAL names ------------------------------------------
# stdout = dom0 takes it as the update agent's log; stderr = the Update GUI's progress floats;
# the exit code = the one channel that already worked and must not be traded away; a GRANDCHILD =
# the shape that actually broke, since the updater is powershell under cmd.
for probe in 'stdout delivered' 'stderr delivered' 'exit code passed through' 'GRANDCHILD'; do
  command grep -qF "$probe" "$CHECK" && ok "covers: $probe" || bad "covers: $probe is not asserted"
done
# Separate calls per stream, so a broken one cannot be masked by the other.
[ "$(command grep -c 'vmexec_run "\$T/o[0-9]"' "$CHECK")" -ge 4 ] \
  && ok "covers: each channel is a separate call" || bad "covers: the streams share one call"
# It must NOT fall back to qubes.VMShell, which kept working and is why this hid for so long.
# COMMENTS STRIPPED: the header explains that `qtest run` is qubes.VMShell and cannot stand in for
# this, so grepping the raw file matched the explanation and accused the check of using it. Fifth
# time today in some form; strip the prose before asserting about the code.
command grep -vE '^[[:space:]]*#' "$CHECK" | command grep -q 'qubes.VMShell' \
  && bad "the check uses qubes.VMShell, which is not the broken path" \
  || ok "the check only uses qubes.VMExec, the path dom0 drives"
# And a failure has to be loud, per the project's own rule.
[ "$(command grep -c '\[ERROR\]' "$CHECK")" -ge 4 ] \
  && ok "a lost channel is reported at ERROR" || bad "a lost channel is not loud"

# ---- 4. THE GATE ACTUALLY RUNS IT -------------------------------------------------------------
# A check nothing calls is the failure mode logvol-lib.sh carries in its own header: "the library
# landed and NO harness called it". Acceptance is where this has to run, because that is what
# decides the release.
command grep -q 'vmexec-channel-check.sh' mgmt/harness/matrix.sh \
  && ok "wired: the acceptance matrix runs it per cell" || bad "wired: no harness calls it - it would gate nothing"
# And a failure must reach the TALLY, not just print: `no` is what counts a cell failed here.
# IT DOES NOT GATE YET, DELIBERATELY. The matrix is wired to fail the cell on a non-zero exit, and
# IT NOW GATES, AND THIS BLOCK USED TO ASSERT THAT IT DID NOT. The check deliberately exited 0
# while it had never run against a guest: whether `qubes.VMExec` is reachable from this qube under
# dom0's tag-based policy was unmeasured, and a refusal looks exactly like the defect it hunts (an
# empty stream). An instrument never seen to WORK must not decide a release - the log volume failed
# three campaign runs on a healthy guest for precisely that reason.
# THE CONDITION IS MET. Campaign run 9 (2026-10-15) reported `dom0 caller channel aligned (stdout,
# stderr, exit code, grandchild)` on win11-clean, win11-reinstall and win11-upgrade - three
# independent cells, all four channels arriving. Before that run it had never executed at all,
# because it was called only from the end-of-campaign collection loop and every cell halts its
# subject as its last act (CALLERCHECKATENDONLY); it is now called per cell, with the guest up.
[ "$(awk '/vmexec-channel-check.sh/,/^    fi$/' mgmt/harness/matrix.sh | command grep -c '^\s*no "')" -ge 1 ] \
  && ok "wired: the matrix fails the cell on a non-zero exit" \
  || bad "wired: a lost channel would print without failing the cell"
command grep -q 'NOT GATING yet' "$CHECK" \
  && bad "wired: it still declares itself non-gating after the condition was met" \
  || ok "wired: the non-gating escape is gone"
command grep -qE '^exit "\$rc_all"' "$CHECK" \
  && ok "wired: a lost channel now FAILS the cell (exit \$rc_all)" \
  || bad "wired: the final exit is not \$rc_all, so a lost channel does not fail"

# ---- 5. THE COLD HALF OF THE GOAL'S SECOND CLAUSE ---------------------------------------------
# "updaters and start menu, from COLD qube as well". The start menu got a cold check on 2026-10-15
# (dom0-callers-check.sh --cold, matrix.sh); this service had none, so the UPDATER half of that
# clause was unmeasured while the clause read as covered.
command grep -q 'vmexec-channel-check.sh --cold' mgmt/harness/matrix.sh \
  && ok "wired: the matrix measures the updater caller FROM A COLD QUBE" \
  || bad "wired: nothing calls this check --cold, so the goal's cold updater clause is unmeasured"
[ "$(awk '/vmexec-channel-check.sh --cold/,/^          fi$/' mgmt/harness/matrix.sh | command grep -c '^\s*no "')" -ge 1 ] \
  && ok "wired: a cold updater failure reaches the TALLY" \
  || bad "wired: a cold updater failure would print without failing the cell"
# A COLD CHECK AGAINST A RUNNING GUEST IS A WARM CHECK WITH A COLD LABEL, and substituting test
# conditions has its own history here. The precondition must be a REFUSAL.
command grep -q 'refusing to label a warm call cold' "$CHECK" \
  && ok "cold: it refuses a guest that is not Halted rather than relabelling it" \
  || bad "cold: no refusal - a warm guest would be measured and reported as cold"
# Only the FIRST call to a Halted qube is cold, so the one cold call must be the shape that broke.
command grep -qE 'vmexec_service cmd.exe /c "cmd /c echo \$MARK"' "$CHECK" \
  && ok "cold: the single cold call is the updater's GRANDCHILD shape" \
  || bad "cold: the cold call is not the grandchild shape - the measured defect would pass it"
# The cold receipt is that the call brought the qube up; without it the stream proves nothing.
command grep -q 'the cold call started the qube' "$CHECK" \
  && ok "cold: it asserts the call itself started the qube" \
  || bad "cold: nothing asserts Halted -> Running, so another qube could have answered"
# A hang, a refusal and an empty stream are three different findings and all arrive as 0 bytes.
for want in "a HANG, not an empty stream" "a refusal or transport failure" "SILENT stderr"; do
  command grep -qF "$want" "$CHECK" \
    && ok "cold: it distinguishes '$want'" \
    || bad "cold: it cannot report '$want' apart from the others"
done

echo "vmexec-channel-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
