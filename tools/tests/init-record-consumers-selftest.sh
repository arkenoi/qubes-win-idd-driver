#!/usr/bin/env bash
# init-record-consumers-selftest.sh - every consumer of an agent's INIT RECORD must accept the form
# the product actually ships. No guest, no rig.
#
# WHY THIS EXISTS. The log is one file per module per day, so an instance's identity comes only from
# its init record - and six places read it to answer "which lines are THIS instance's". The six-line
# LogInit banner that carried `Running as user: ..., process ID: N` was demoted to LogDebug, and the
# product ships LogLevel 3 (INFO), so THAT LINE NO LONGER EXISTS in a shipped log. Its replacement
# is the single INFO line QWTBIRTH, carrying the same pid as `pid=N`.
#
# MEASURED 2026-10-23 on win11r-ttfw running 4.3.37.1063 (quick-upgrade evidence): its
# gui-agent-20261023.log held ZERO `process ID:` lines and two QWTBIRTH lines. The only files in that
# capture still carrying the old form were written by 4.3.35.795 (the entry fixture) and 4.2.2.0 (the
# golden) - i.e. no shipped module writes it any more.
#
# WHAT THAT COST, and why a source check is worth it here: the failures were all silent or inverted.
#   * guest/restart-gui-agent.ps1 returned pid 0, so the SANCTIONED agent restart could not prove a
#     turnover and every caller got `RESTART INVALID-INSTRUMENT no-init-record`. That is the helper
#     that exists so nothing is killed by name, so the alternative it protects against was the only
#     thing left working.
#   * mgmt/harness/promoted-checks.sh and mgmt/harness/p5-run.sh use it to SCOPE a count to this
#     instance. With no match the index stays 0 and they count the WHOLE FILE - earlier instances'
#     QGAUAC, secure-desktop ENTERED and MAP lines attributed to this run. Not inert: inverted.
#   * mgmt/harness/gate-preflight.sh emits `INITLINE 0` / `VCHANCONN 0` and exits - an acceptance
#     gate reporting zero because it could not find the line it keys on.
# This is the shape recorded as "a level change blinds every parser": one severity edit, six readers.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/initrec-selftest-XXXXXX)"
PASS=0; FAIL=0
ok(){ echo "ok   $*"; PASS=$((PASS+1)); }
no(){ echo "FAIL $*"; FAIL=$((FAIL+1)); }

# The consumers, named explicitly: this list is the point of the suite, so a NEW consumer that keys
# on the legacy form only is caught by being added here, and a consumer that disappears is caught by
# the existence check below.
CONSUMERS="guest/restart-gui-agent.ps1 guest/health-check.ps1 guest/set-startmode.ps1
           mgmt/harness/promoted-checks.sh mgmt/harness/p5-run.sh mgmt/harness/gate-preflight.sh"

# A SOURCE ASSERTION MUST SKIP COMMENTS: every one of these files now EXPLAINS the demotion in a
# comment that names both forms, so a check reading the whole file would pass on the prose while the
# code still keyed on the dead line.
for rel in $CONSUMERS; do
    f="$ROOT/$rel"
    [ -f "$f" ] || { no "$rel is missing - if it was renamed or removed, this list must say so"; continue; }
    code="$(grep -vE '^[[:space:]]*(#|//)' "$f")"
    if ! printf '%s' "$code" | grep -qa 'process ID'; then
        ok "$rel no longer reads an init record at all (nothing to break)"
        continue
    fi
    if printf '%s' "$code" | grep -qaE 'QWTBIRTH|\\bpid='; then
        ok "$rel accepts the shipped form as well as the legacy one"
    else
        no "$rel keys ONLY on the legacy 'process ID:' line, which no shipped build writes"
    fi
done

# ---- functional: the restart helper's parser, against the line a 4.3.37 guest actually wrote -----
# NOT a line of my own invention - this is verbatim from win11r-ttfw's gui-agent-20261023.log
# (4.3.37.1063), which is what makes this a check on the product's format rather than on my model of
# it. A fixture that avoids the condition proves nothing.
PW=""
for p in /home/user/pwsh/pwsh /home/user/pwsh74/pwsh "$(command -v pwsh 2>/dev/null)"; do
    [ -n "$p" ] && [ -x "$p" ] && { PW="$p"; break; }
done
if [ -z "$PW" ]; then
    echo "note no pwsh here - the functional leg did not run"
else
    cat > "$OUT/real.log" <<'LOG'
[20261023.152301.100-6560:6564-I] LogInit: Log started, module name: gui-agent
[20261023.152304.572-6560:6564-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1063 pid=6560 session=1 uptime=72.140
[20261023.152305.000-6560:6564-I] TrackWindows: up
LOG
    got=$("$PW" -NoProfile -Command '
      $src = Get-Content -Raw "'"$ROOT"'/guest/restart-gui-agent.ps1"
      $m = [regex]::Match($src, "(?s)function Get-GuiAgentLastInit.*?\n\}")
      if (-not $m.Success) { "EXTRACT fail"; exit 0 }
      Invoke-Expression $m.Value
      $r = Get-GuiAgentLastInit "'"$OUT"'/real.log"
      "PID " + $r.pid' 2>&1 | tr -d '\r')
    case "$(printf '%s' "$got" | grep -a '^PID' | tail -1)" in
      "PID 6560") ok "functional: the parser reads 6560 off a real 4.3.37 QWTBIRTH line" ;;
      "PID 0")    no "functional: the parser returns 0 on a real 4.3.37 log - the restart instrument is blind" ;;
      *)          no "functional: unexpected result '$(printf '%s' "$got" | tr '\n' ' ' | cut -c1-120)'" ;;
    esac

    # SEEN TO FAIL: with the QWTBIRTH branch removed, the same real line must read 0. A check that
    # cannot fail is decoration, and this is the one that matters.
    sed 's/QWTBIRTH\\s\.\*\\bpid=(\\d+)/ZZNOMATCHZZ/' "$ROOT/guest/restart-gui-agent.ps1" > "$OUT/mut.ps1"
    if cmp -s "$ROOT/guest/restart-gui-agent.ps1" "$OUT/mut.ps1"; then
        no "seen-to-fail: the mutation changed nothing - the branch is not where this suite thinks"
    else
        got2=$("$PW" -NoProfile -Command '
          $src = Get-Content -Raw "'"$OUT"'/mut.ps1"
          $m = [regex]::Match($src, "(?s)function Get-GuiAgentLastInit.*?\n\}")
          if (-not $m.Success) { "EXTRACT fail"; exit 0 }
          Invoke-Expression $m.Value
          $r = Get-GuiAgentLastInit "'"$OUT"'/real.log"
          "PID " + $r.pid' 2>&1 | tr -d '\r')
        case "$(printf '%s' "$got2" | grep -a '^PID' | tail -1)" in
          "PID 0") ok "seen-to-fail: without the QWTBIRTH branch the same real line reads 0" ;;
          *)       no "seen-to-fail: the mutated parser still found a pid ('$(printf '%s' "$got2" | grep -a '^PID' | tail -1)')" ;;
        esac
    fi
fi

echo
echo "RESULT: $PASS passed, $FAIL failed  (fixtures: $OUT)"
[ "$FAIL" -eq 0 ] || exit 1
