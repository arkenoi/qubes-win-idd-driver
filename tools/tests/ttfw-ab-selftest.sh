#!/usr/bin/env bash
# ttfw-ab-selftest.sh - offline checks on mgmt/harness/ttfw-ab.sh. No guest, no rig.
#
# A ROUTINE THAT PRODUCES A NUMBER THE OWNER WILL ACT ON IS ITSELF AN INSTRUMENT, and this one
# produces the headline for a user-visible latency. The shapes checked here are the ones whose
# absence would make its number meaningless rather than wrong-by-a-little, and every shape check is
# driven to FAIL with its guarded line removed - a check never seen to fail is decoration.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$ROOT/mgmt/harness/ttfw-ab.sh"
OUT="$(mktemp -d /tmp/ttfw-selftest-XXXXXX)"
PASS=0; FAIL=0
ok(){ echo "ok   $*"; PASS=$((PASS+1)); }
no(){ echo "FAIL $*"; FAIL=$((FAIL+1)); }
shape(){ # $1 label, $2 fn, $3 marker of the guarded line
    local mut="$OUT/mut-$2.sh"
    if "$2" "$H"; then
        grep -v -F -- "$3" "$H" > "$mut"
        if "$2" "$mut"; then no "$1 - the check still passes with the guarded line removed (it cannot fail)"
        else ok "$1 (and FAILS with the guarded line removed)"; fi
    else no "$1"; fi
}

[ -f "$H" ] || { echo "FAIL  $H is missing"; exit 1; }
bash -n "$H" && ok "it parses (bash -n)" || no "it does not parse"

# ---- functional: it refuses what it cannot measure ---------------------------------------------
# MISSING DATA FAILS is this repo's rule, and for a benchmark the two ways to fabricate a result are
# to run with no binaries at all, or to run with the SAME binary on both sides and report the spread
# as an effect.
o=$(bash "$H" 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s' "$o" | grep -qaF -- '--a <exe> is required' \
  && ok "functional: it refuses with no binaries (rc=2)" || no "functional: no-args rc=$rc out='$(printf '%s' "$o" | head -1)'"

same="$OUT/same.exe"; printf 'x' > "$same"
o=$(bash "$H" --a "$same" --b "$same" 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s' "$o" | grep -qa 'SAME binary' \
  && ok "functional: it refuses the same binary on both sides (rc=2)" || no "functional: same-binary rc=$rc"

# it must refuse BEFORE touching the rig: a benchmark that creates or boots something and only then
# finds its inputs unusable has already changed the subject it was going to measure.
o=$(bash "$H" --a "$same" --b /nonexistent-b.exe 2>&1)
printf '%s' "$o" | grep -qa 'qvm-' && no "functional: it reached the rig before validating its inputs" \
                                  || ok "functional: a bad input is refused before any rig call"

# ---- the swap is verified, or nothing is timed --------------------------------------------------
# The single most important rule of bench-stock-vs-ours.sh, for the same reason: a harness that
# proceeds on a failed swap reports numbers for a build that never ran.
hash_verified(){ awk '
  /got="\$\(printf .%s\\n. "\$swap" \| grep -aoE .HASH_RUNNING=/ {g=NR}
  /if \[ "\$got" != "\$want" \]; then/ {c=NR}
  /return 1/ {r=NR}
  END{exit !(g && c && r && g < c && c < r)}' "$1"; }
shape "the running binary's hash is compared to the pushed one, and a mismatch abandons the sample" \
      hash_verified 'if [ "$got" != "$want" ]; then'

# ---- the empty-capture ambiguity is handled -----------------------------------------------------
# An empty per-window tar has THREE causes (.claude/skills/guest-capture). Two of them look exactly
# like "no window yet", which is the number this harness reports - so both must be excluded, or the
# instrument measures itself.
tag_preflight(){ grep -qF "qvm-tags" "$1" && awk '/win-idd-testbed/{t=NR} /vm_lock/{l=NR} END{exit !(t && l && t < l)}' "$1"; }
shape "the tag is asserted in PREFLIGHT, before the lock and any boot (an untagged target captures nothing)" \
      tag_preflight 'win-idd-testbed'
# THE INSTRUMENT IS THE AGENT'S OWN LOG, not a capture. The capture-based metric was abandoned for
# a measured reason: on a seamless guest with no application open there are NO windows for dom0 to
# show, so an idle desktop has no first window to time. These legs hold the replacement - four
# stamps from one log, and a sample that cannot read all four is a MISS, never a number.
# The BREAKDOWN comes from the agent's own stamps, in one log, so a shifted guest clock cannot
# distort a delta. It is a breakdown, not the measurement: the measurement is the demonstrated
# window, so an unreadable breakdown prints -1 rather than discarding a sample that DID show pixels.
stamps_from_log(){ grep -qF 'guest/probe-ttfw.ps1' "$1" &&
    awk '/if \[ -n "\$shell" \] && \[ -n "\$launch" \] && \[ -n "\$ready" \]/{c=NR} /echo "\$ttfw -1 -1 \$cols"/{f=NR} END{exit !(c && f && c < f)}' "$1"; }
shape "the breakdown comes from the agent's own stamps, and an unreadable breakdown degrades to -1 instead of discarding a sample that showed pixels" \
      stamps_from_log 'if [ -n "$shell" ] && [ -n "$launch" ] && [ -n "$ready" ]; then'
exits_named(){ awk '/miss shutdown_refused/{a=NR} /miss start_failed/{b=NR} /miss no_qrexec_after_boot/{c=NR} /miss no_app_started/{d=NR} /miss no_demonstrated_window_within_/{e=NR} END{exit !(a && b && c && d && e)}' "$1"; }
shape "every way a sample can fail is NAMED (shutdown, start, qrexec, app, no demonstrated window) - never a silent miss" \
      exits_named 'miss no_demonstrated_window_within_'

# ---- THE END STATE IS ASSERTED, or the number means nothing ------------------------------------
# Owner, 2026-10-23: "pixels not demonstrated is not smoke pass. a measurement that does not prove
# end state is sane is futile, we may claim zero seconds immediately." A clean log with no window
# ever shown is consistent with ANY timing, so every sample must finish with a window whose pixels
# classify DESKTOP ("varied content: something is actually rendering", tools/winshot.py classify).
ends_in_pixels(){ grep -qF 'winshot.py --png' "$1" &&
    awk '/v=\$\(python3 tools\/winshot.py --png/{c=NR} /if \[ "\$v" = DESKTOP \]/{d=NR} /\[ "\$verdict" = DESKTOP \] \|\|/{r=NR} /miss no_demonstrated_window_within_/{m=NR} END{exit !(c && d && r && m && c < d && d < r)}' "$1"; }
shape "every sample must END in a window classified DESKTOP, and one that cannot is a named MISS" \
      ends_in_pixels '[ "$verdict" = DESKTOP ] ||'
# A window has to be OPENED to exist - an idle seamless desktop maps none - and the app it opens is
# ended BY PID. Killing by name races whatever else owns that image (ADR-supervision 5).
opens_and_ends_by_pid(){ grep -qF 'guest/launch-window-probe.ps1' "$1" &&
    grep -qF 'Stop-Process -Id $wpid' "$1" &&
    ! grep -qaE 'Stop-Process -Name|taskkill /im' "$1"; }
shape "a window is opened on purpose and the app is ended BY PID, never by name" \
      opens_and_ends_by_pid 'Stop-Process -Id $wpid'

# ---- no desktop photography --------------------------------------------------------------------
# qtest fullshot photographs the whole dom0 desktop. In a POLLING loop that would be dozens of
# captures of the owner's screen per sample.
if grep -qa 'fullshot' "$H"; then
  grep -a 'fullshot' "$H" | grep -qvaE '^\s*#' && no "it calls fullshot outside a comment" || ok "fullshot appears only in a comment"
else ok "it never mentions fullshot"; fi

# ---- the sanctioned shutdown, and nothing killed by name ---------------------------------------
grep -qa 'qvm-shutdown --wait' "$H" && no "it uses qvm-shutdown --wait, which KILLS at its timeout (lint L9)" \
                                    || ok "it does not use qvm-shutdown --wait"
grep -qa 'qwt_shutdown' "$H" && ok "it shuts the guest down through qwt_shutdown" || no "no qwt_shutdown call"
# BY PID IS CORRECT; BY NAME IS NOT. The earlier form of this leg matched Stop-Process at all and
# so failed the harness for ending, by pid, the one app it started itself. What is prohibited is
# selecting a process by its image name - that races whatever else owns it (ADR-supervision 5).
if grep -qaE 'pkill|taskkill[^|]*/im|Stop-Process[^|]*-Name' "$H"; then
    no "it selects a process by NAME to kill"
else
    ok "nothing is killed by name (Stop-Process -Id, by the pid it was given, is the sanctioned form)"
fi

# ---- the swap script must actually be on the guest -------------------------------------------
# run_side invokes swap-agent.ps1 from QubesIncoming; nothing else puts it there, so without this
# push every sample fails on a missing file. Caught before the first run, not by it.
pushes_swap(){ grep -qF 'qt push "$ROOT/guest/swap-agent.ps1" "$ROOT/guest/restart-gui-agent.ps1"' "$1" &&
    awk '/qt push "\$ROOT\/guest\/swap-agent.ps1"/{p=NR} /^run_side\(\)/{r=NR} END{exit !(p && r && p < r)}' "$1"; }
shape "BOTH swap scripts are pushed ONCE before any sample (swap-agent.ps1 refuses without restart-gui-agent.ps1 beside it)" \
      pushes_swap 'qt push "$ROOT/guest/swap-agent.ps1" "$ROOT/guest/restart-gui-agent.ps1"'
distinct_names(){ grep -qF 'cp "$A" "$OUT/agent-a.exe"' "$1" && grep -qF 'cp "$B" "$OUT/agent-b.exe"' "$1"; }
shape "the two sides are staged under distinct basenames (both artifacts are called gui-agent.exe)" \
      distinct_names 'cp "$A" "$OUT/agent-a.exe"'

# ---- interleaving, the lock, and the smoke gate -------------------------------------------------
alternates(){ awk '/r % 2/{a=NR} END{exit !a}' "$1"; }
shape "the starting side alternates per round, so guest drift cannot land on one side" alternates 'r % 2'
grep -qa 'vm_lock' "$H" && ok "it holds the rig lock" || no "it does not take vm_lock"
smoke_gates(){ grep -qF 'smoke_rc' "$1" && awk '/log-sweep.sh/{s=NR} /\[ "\$smoke_rc" = 0 \]/{g=NR} END{exit !(s && g && s < g)}' "$1"; }
shape "a smoke sweep runs over a single-build window and its verdict gates the exit code" \
      smoke_gates '[ "$smoke_rc" = 0 ] ||'

# ---- the verdict refuses to claim an effect from overlapping samples ---------------------------
# docs/BENCHMARKS.md: between-session variance here has exceeded the within-session spread, so
# overlapping ranges support no claim. A benchmark that reports a median delta without saying that
# is how a noise difference becomes a shipped claim.
disjoint_only(){ grep -qF 'VERDICT=OVERLAPPING' "$1" && grep -qF 'max(b) < min(a)' "$1"; }
shape "it claims IMPROVED only on disjoint ranges, and says OVERLAPPING otherwise" disjoint_only 'VERDICT=OVERLAPPING'
grep -qF 'VERDICT=INCONCLUSIVE' "$H" && ok "a side with no usable sample is INCONCLUSIVE, not a pass" \
                                     || no "a side with no usable sample is not called out"

echo
echo "RESULT: $PASS passed, $FAIL failed  (fixtures: $OUT)"
[ "$FAIL" -eq 0 ] || exit 1
