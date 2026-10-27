#!/bin/bash
# EVERY REFUSAL OF THE CAMPAIGN PREFLIGHT FIRES - a gate nobody has watched refuse is decoration.
# run: tools/tests/campaign-preflight-selftest.sh
# pass: exit 0
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T="$(mktemp -d "${TMPDIR:-/tmp}/campaign-preflight-XXXXXX")"
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT
pass=0; fail=0
ok(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

mkdir -p "$T/bin" "$T/goldens" "$T/fixtures"

# ---- the stubs ---------------------------------------------------------------------------------
# gh: answers `run view <id> --json conclusion|headSha`. The state file decides what it says.
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
S="${GH_STATE:?}"
case " $* " in
  *" conclusion "*) sed -n 's/^conclusion=//p' "$S" ;;
  *" headSha "*)    sed -n 's/^headsha=//p'    "$S" ;;
esac
EOF
# qvm-check --running <vm>: running only if the vm is listed in RUNNING_VMS
# LAST ARG BY INDEX. `${*##* }` does not extract the last positional - it pattern-strips the
# JOINED string and silently returned the whole thing, so both stubs answered "fine" for every vm
# and two refusals looked like they did not fire. Caught by this suite's own clear-case contrast.
# qvm-check: EXISTENCE and RUNNING are different questions and the real tool answers them
# differently - `qvm-check <vm>` is existence, `qvm-check --running <vm>` is state. This stub
# conflated them (every non-running subject read as ABSENT), which silently disabled the stale-claim
# gate below: that gate skips a subject that does not exist, so it skipped all of them and the
# refusal could not fire. A stub that models the wrong thing makes a real check untestable.
cat > "$T/bin/qvm-check" <<'EOF'
#!/bin/bash
vm="${@: -1}"
case " $* " in
  *" --running "*) case " ${RUNNING_VMS:-} " in *" $vm "*) exit 0 ;; *) exit 3 ;; esac ;;
esac
case " ${ABSENT_VMS:-} " in *" $vm "*) exit 3 ;; *) exit 0 ;; esac
EOF
# the golden tool: verifies unless the vm is listed in BAD_GOLDENS
cat > "$T/bin/golden.sh" <<'EOF'
#!/bin/bash
vm="${@: -1}"
case " ${BAD_GOLDENS:-} " in *" $vm "*) exit 1 ;; *) exit 0 ;; esac
EOF
# the CI reader: prints whatever CI_LINE says, as ci-state's last line
cat > "$T/bin/ci-reader" <<'EOF'
#!/bin/bash
printf '%s\n' "${CI_LINE:-CI 0 every required workflow is green}"
EOF
chmod +x "$T/bin"/*

# ---- a package commit that really does carry the marker ----------------------------------------
# Taken from THIS repo rather than invented: the preflight reads it with `git show <sha>:<file>`, so
# only a real commit exercises that path. HEAD carries the marker; HEAD~ of a chosen file does not.
GOODSHA=$(git rev-parse HEAD)
MARKER='GUARD:bootbacklog'
# NO PIPE INTO `grep -q` UNDER pipefail. grep exits on the FIRST match, git show takes SIGPIPE, and
# `set -o pipefail` reports the pipeline as 141 - so this read "HEAD does not carry the marker" about
# a commit that carries it, intermittently, depending on whether git finished before the pipe closed.
# Measured on this suite 2026-10-25. The repo's own rule, learned on 2026-10-14 when the same shape
# graded a LIVE guest dead. Capture, then match.
_mk_blob=$(git show "$GOODSHA:guest/qwt-report-death.ps1" 2>/dev/null || true)
case "$_mk_blob" in
  *"$MARKER"*) : ;;
  *) echo "FATAL: HEAD does not carry $MARKER - this suite needs a commit that does" >&2; exit 2 ;;
esac
# a commit that does NOT carry it: the one before the boundary landed
NOFIXSHA=$(git log --format=%H -1 --until="$(git log -1 --format=%cI 95cd3faa 2>/dev/null)" 95cd3faa~1 2>/dev/null || git rev-parse HEAD~20)

# tracked-looking records the preflight reads
mkgold(){ printf '{"vm":"%s","sealed_utc":"%s"}\n' "$1" "$2" > "$T/goldens/$1.json"; }
mkfix(){  printf '{"vm":"%s","base":"%s","base_sealed_utc":"%s"}\n' "$1" "$2" "$3" > "$T/fixtures/$1.json"; }
mkgold win10-base  2026-01-01T00:00:00Z
mkgold win11r-base 2026-01-02T00:00:00Z
mkgold win11r-qwt  2026-01-03T00:00:00Z
mkfix  win10-iqi win10-base  2026-01-01T00:00:00Z
mkfix  win11-iqi win11r-base 2026-01-02T00:00:00Z

printf 'conclusion=success\nheadsha=%s\n' "$GOODSHA" > "$T/pkg.state"

# ---- the PREPARATION externals (section 2b), stubbed so the suite never reads the real rig -----
# Without these, leg 0 below would consult the real mtools, the real $HOME/win-iso/logvol, the real
# block claims and the real thin pool - and an offline suite whose verdict depends on rig state is
# not an offline suite.
mkdir -p "$T/logvol"
for _b in mcopy minfo mformat; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$_b"; chmod +x "$T/bin/$_b"; done
# mdir prints the "image" itself, so a fixture image carrying the text LOGVOL.TAG passes the real
# check in the preflight and one without it fails - the gate's own predicate runs either way.
cat > "$T/bin/mdir" <<'EOF'
#!/bin/bash
img=""; prev=""
for a in "$@"; do [ "$prev" = "-i" ] && img="$a"; prev="$a"; done
[ -n "$img" ] && [ -r "$img" ] && cat "$img"
exit 0
EOF
chmod +x "$T/bin/mdir"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/udisksctl"; chmod +x "$T/bin/udisksctl"
# a blockclaim lib whose sweep answers from a variable: STUCK_VMS names the guests it cannot clear.
cat > "$T/blockclaim-lib.sh" <<'EOF'
claim_sweep_stale(){ case " ${STUCK_VMS:-} " in *" $1 "*) return 1 ;; *) return 0 ;; esac; }
claim_drop_loop(){ return 0; }
EOF


run(){ # -> rc; output in $T/out
  PATH="$T/bin:$PATH" \
  GH_BIN="$T/bin/gh" GH_STATE="${GH_STATE:-$T/pkg.state}" \
  QVM_CHECK="$T/bin/qvm-check" GOLDEN_SH="$T/bin/golden.sh" \
  CI_STATE="$T/bin/ci-reader" \
  GOLDENS_DIR="$T/goldens" FIXTURES_DIR="$T/fixtures" \
  CI_WAIT_SECONDS="${CI_WAIT_SECONDS:-0}" CI_POLL_SECONDS=1 \
  RUNNING_VMS="${RUNNING_VMS:-}" BAD_GOLDENS="${BAD_GOLDENS:-}" CI_LINE="${CI_LINE:-}" \
  LOGVOL_DIR="${LOGVOL_DIR_OVERRIDE:-$T/logvol}" BLOCKCLAIM_LIB="${BLOCKCLAIM_LIB_OVERRIDE:-$T/blockclaim-lib.sh}" \
  SPACE_RECORD="${SPACE_RECORD_OVERRIDE:-$T/space-absent.json}" \
  POOL_FREE_CMD="${POOL_FREE_CMD_OVERRIDE:-echo ${POOL_FREE:-999}}" \
  MTOOLS_BINS="${MTOOLS_BINS_OVERRIDE:-mcopy mdir minfo mformat}" \
  STUCK_VMS="${STUCK_VMS:-}" ABSENT_VMS="${ABSENT_VMS:-}" \
    bash mgmt/harness/campaign-preflight.sh "${1:-12345}" > "$T/out" 2>&1
  echo $?
}

# ---- 0. the clear case, or every refusal below would pass by refusing everything ---------------
rc=$(run)
if [ "$rc" = 0 ] && grep -qa 'PREFLIGHT CLEAR' "$T/out"; then ok "a clean rig, a good package and green CI is CLEAR to launch"
else no "a clean rig, a good package and green CI is CLEAR to launch" "rc=$rc $(tail -2 "$T/out" | tr '\n' ' ')"; fi

# ---- 1. the entry images -----------------------------------------------------------------------
rc=$(BAD_GOLDENS="win11r-base" run)
if [ "$rc" = 12 ] && grep -qa 'golden win11r-base does not verify' "$T/out"; then ok "a golden that does not verify REFUSES (12)"
else no "a golden that does not verify REFUSES (12)" "rc=$rc $(tail -1 "$T/out")"; fi

mkfix win11-iqi win11r-base 2025-12-31T00:00:00Z     # a seal that is no longer the live one
rc=$(run)
if [ "$rc" = 12 ] && grep -qa "fixture win11-iqi was built from" "$T/out"; then ok "a fixture whose base seal moved REFUSES (12)"
else no "a fixture whose base seal moved REFUSES (12)" "rc=$rc $(tail -1 "$T/out")"; fi
mkfix win11-iqi win11r-base 2026-01-02T00:00:00Z     # restore

rm -f "$T/fixtures/win10-iqi.json"
rc=$(run)
if [ "$rc" = 12 ] && grep -qa 'no fixture record for win10-iqi' "$T/out"; then ok "a MISSING fixture record REFUSES (12) - absence is not a pass"
else no "a MISSING fixture record REFUSES (12)" "rc=$rc $(tail -1 "$T/out")"; fi
mkfix win10-iqi win10-base 2026-01-01T00:00:00Z

# ---- 2. the rig is free ------------------------------------------------------------------------
rc=$(RUNNING_VMS="win10-clean" run)
if [ "$rc" = 11 ] && grep -qa 'win10-clean is RUNNING' "$T/out"; then ok "a running subject REFUSES (11)"
else no "a running subject REFUSES (11)" "rc=$rc $(tail -1 "$T/out")"; fi
# and the one that was left behind by a stopped campaign counts too
rc=$(RUNNING_VMS="win10-acc" run)
if [ "$rc" = 11 ]; then ok "a leftover provisioning subject (win10-acc) REFUSES too"
else no "a leftover provisioning subject (win10-acc) REFUSES too" "rc=$rc $(tail -1 "$T/out")"; fi

# ---- 3. the package and the product ------------------------------------------------------------
printf 'conclusion=failure\nheadsha=%s\n' "$GOODSHA" > "$T/bad-concl.state"
rc=$(GH_STATE="$T/bad-concl.state" run)
if [ "$rc" = 13 ] && grep -qa "concluded 'failure'" "$T/out"; then ok "a package whose own run FAILED refuses (13)"
else no "a package whose own run FAILED refuses (13)" "rc=$rc $(tail -1 "$T/out")"; fi

printf 'conclusion=success\nheadsha=\n' > "$T/nosha.state"
rc=$(GH_STATE="$T/nosha.state" run)
if [ "$rc" = 13 ] && grep -qa 'could not read the commit' "$T/out"; then ok "a package whose commit cannot be read refuses (13)"
else no "a package whose commit cannot be read refuses (13)" "rc=$rc $(tail -1 "$T/out")"; fi

printf 'conclusion=success\nheadsha=%s\n' "$NOFIXSHA" > "$T/nofix.state"
rc=$(GH_STATE="$T/nofix.state" run)
if [ "$rc" = 13 ]; then ok "a package built BEFORE the fix refuses (13) - it cannot test what is not in it"
else no "a package built BEFORE the fix refuses (13)" "rc=$rc $(tail -1 "$T/out")"; fi

# a sha that is not an ancestor of HEAD at all
printf 'conclusion=success\nheadsha=%s\n' "0000000000000000000000000000000000000000" > "$T/norel.state"
rc=$(GH_STATE="$T/norel.state" run)
if [ "$rc" = 13 ]; then ok "a package commit unrelated to HEAD refuses (13)"
else no "a package commit unrelated to HEAD refuses (13)" "rc=$rc $(tail -1 "$T/out")"; fi

# ---- 4. CI ------------------------------------------------------------------------------------
rc=$(CI_LINE="CI 1 a required workflow is RED or absent - do not receipt against this sha" run)
if [ "$rc" = 14 ] && grep -qa 'CI is not green' "$T/out"; then ok "CI 1 (red or absent) refuses (14)"
else no "CI 1 (red or absent) refuses (14)" "rc=$rc $(tail -1 "$T/out")"; fi

# NOT FINISHED IS NOT RED - but it is not a pass either. With no budget left to wait, it refuses.
rc=$(CI_LINE="CI 2 a required workflow has not finished - no verdict yet" CI_WAIT_SECONDS=0 run)
if [ "$rc" = 14 ] && grep -qa 'has not finished' "$T/out"; then ok "CI 2 with no wait budget refuses (14) - no verdict is not a verdict"
else no "CI 2 with no wait budget refuses (14)" "rc=$rc $(tail -1 "$T/out")"; fi

# ---- 5. SEEN TO FAIL: the shape this replaced --------------------------------------------------
# The scratchpad chain ran these checks with `||` and a message, untracked and untested. The point
# of this suite is not that the checks exist - it is that each one has now been WATCHED to refuse.
# A GATE IS ONLY A GATE IF ITS REFUSALS WERE WATCHED. Ten distinct refusals plus the clear case:
# the clear case is what stops the other ten passing by refusing everything.

[ "$fail" -eq 0 ]

# ---- 2b. THE PREPARATION GATES, each refusal seen to fire (exit 15) ----------------------------
# Campaign 40134888669 aborted on its first cell because the log volume was not visible to the guest,
# and NOTHING above would have caught it: goldens verified, fixtures traced, no subject ran, the
# package was right, CI was green. These are that gap, and each one is driven here.

rc=$(MTOOLS_BINS_OVERRIDE="mcopy mdir minfo mformat definitely-not-on-path" run)
if [ "$rc" = 15 ] && grep -qa 'definitely-not-on-path is not on PATH' "$T/out"; then ok "a MISSING mtools binary REFUSES (15) - the log volume is unreadable without it"
else no "a missing mtools binary REFUSES (15)" "rc=$rc $(tail -1 "$T/out")"; fi

rc=$(LOGVOL_DIR_OVERRIDE="$T/no-such-logvol-dir" run)
if [ "$rc" = 15 ] && grep -qa 'no log-volume directory' "$T/out"; then ok "a MISSING log-volume directory REFUSES (15)"
else no "a missing log-volume directory REFUSES (15)" "rc=$rc $(tail -1 "$T/out")"; fi

printf 'this image carries no tag at all\n' > "$T/logvol/logs-win10-acc.img"
rc=$(run)
if [ "$rc" = 15 ] && grep -qa 'carry no LOGVOL.TAG' "$T/out"; then ok "an existing image WITHOUT LOGVOL.TAG REFUSES (15) - a foreign FAT is not our volume"
else no "an image without LOGVOL.TAG REFUSES (15)" "rc=$rc $(tail -1 "$T/out")"; fi
printf 'LOGVOL.TAG present here\n' > "$T/logvol/logs-win10-acc.img"
rc=$(run)
if [ "$rc" = 0 ]; then ok "and the SAME image WITH the tag is accepted - the check reads the tag, not the filename"
else no "a tagged image is accepted" "rc=$rc $(tail -1 "$T/out")"; fi

rc=$(STUCK_VMS="win11-acc" run)
if [ "$rc" = 15 ] && grep -qa 'stale block claims remain on: win11-acc' "$T/out"; then ok "a stale block claim that cannot be swept REFUSES (15) - the guest could not be created"
else no "a stale block claim REFUSES (15)" "rc=$rc $(tail -1 "$T/out")"; fi

rc=$(ABSENT_VMS="win11-acc" STUCK_VMS="win11-acc" run)
if [ "$rc" = 0 ]; then ok "a subject that does NOT EXIST is skipped by the claim gate - it can hold no claims"
else no "an absent subject is skipped by the claim gate" "rc=$rc $(tail -1 "$T/out")"; fi

rc=$(BLOCKCLAIM_LIB_OVERRIDE="$T/no-such-lib.sh" run)
if [ "$rc" = 15 ] && grep -qa 'cannot be checked' "$T/out"; then ok "a MISSING blockclaim lib REFUSES (15) - unable to check is not a pass"
else no "a missing blockclaim lib REFUSES (15)" "rc=$rc $(tail -1 "$T/out")"; fi

rc=$(POOL_FREE_CMD_OVERRIDE="echo" run)
if [ "$rc" = 15 ] && grep -qa 'could not be read' "$T/out"; then ok "an UNREADABLE pool REFUSES (15) - a campaign is not started blind on space"
else no "an unreadable pool REFUSES (15)" "rc=$rc $(tail -1 "$T/out")"; fi

rc=$(POOL_FREE="75" run)
if [ "$rc" = 15 ] && grep -qa "SAFE THRESHOLD is 90 GB" "$T/out"; then ok "free space above the per-cell floor but below the rig's SAFE THRESHOLD still REFUSES (15) - 73 GB was 'tight to finish' and the campaign aborted"
else no "space below the safe threshold REFUSES (15)" "rc=$rc $(tail -1 "$T/out")"; fi

rc=$(POOL_FREE="12" run)
if [ "$rc" = 15 ] && grep -qa 'the per-cell floor is' "$T/out"; then ok "free space BELOW the per-cell floor REFUSES (15) at minute 0, not in cell 1"
else no "space below the per-cell floor REFUSES (15)" "rc=$rc $(tail -1 "$T/out")"; fi

printf '{"peak_used_gb": 400}\n' > "$T/space-measured.json"
rc=$(SPACE_RECORD_OVERRIDE="$T/space-measured.json" POOL_FREE="100" run)
if [ "$rc" = 15 ] && grep -qa 'measured campaign peak is 400 GB' "$T/out"; then ok "free space below a MEASURED campaign peak REFUSES (15)"
else no "space below a measured peak REFUSES (15)" "rc=$rc $(tail -1 "$T/out")"; fi

rc=$(SPACE_RECORD_OVERRIDE="$T/space-measured.json" POOL_FREE="900" run)
if [ "$rc" = 0 ] && grep -qa 'above the MEASURED campaign peak' "$T/out"; then ok "and above that measured peak it is CLEAR, naming the peak it cleared"
else no "above a measured peak is clear" "rc=$rc $(tail -1 "$T/out")"; fi

rc=$(run)
if [ "$rc" = 0 ] && grep -qa 'requirement is UNVERIFIED' "$T/out"; then ok "with NO peak recorded it says the campaign requirement is UNVERIFIED rather than inventing a bound (Jev measured-peak-first 0.91)"
else no "an unmeasured campaign requirement says UNVERIFIED" "rc=$rc $(tail -1 "$T/out")"; fi

# AND A RECORDED ZERO IS THE SAME AS NO RECORD. Attempt 1024-2333 aborted before any cell drew
# space, leaving start_free_gb == min_free_gb and peak_used_gb 0. Read as a number, that gate passes
# trivially and LOGS "above the MEASURED campaign peak of 0 GB" - an aborted run turned into a
# reassurance nobody measured. Both directions are asserted: zero must not be quoted as measured,
# and must still say UNVERIFIED.
printf '{"peak_used_gb": 0, "run": "x", "start_free_gb": 105, "min_free_gb": 105}\n' > "$T/space-zero.json"
rc=$(SPACE_RECORD_OVERRIDE="$T/space-zero.json" POOL_FREE="100" run)
if [ "$rc" = 0 ] && grep -qa 'requirement is UNVERIFIED' "$T/out" && ! grep -qa 'MEASURED campaign peak' "$T/out"; then
  ok "a recorded peak of ZERO is UNVERIFIED, not a measured bound - an aborted attempt drew nothing and proves nothing"
else no "a zero peak is UNVERIFIED" "rc=$rc $(grep -a 'space:' "$T/out" | tail -1)"; fi


# ---- the tally, LAST, and the exit code is the contract -----------------------------------------
# This block used to sit above the preparation legs, so the printed total excluded them and the
# suite's exit code was whatever its final `if` happened to leave behind. A suite whose rc does not
# follow its own failures cannot gate anything.
# THE FLOOR IS A FLOOR, not an exact count: arms get added (the preparation gates added twelve), and
# an assertion on an exact number turns every addition into a failure. What it guards is that the
# arms RAN - a suite that refuses everything, or nothing, trips it.
ARMS_FLOOR="${ARMS_FLOOR:-25}"
if [ "$fail" -eq 0 ] && [ "$pass" -ge "$ARMS_FLOOR" ]; then
  ok "all arms driven: $pass of at least $ARMS_FLOOR - one CLEAR case and the refusals, entry images through preparation"
else
  no "all arms driven (floor $ARMS_FLOOR)" "pass=$pass fail=$fail"
fi

printf 'campaign-preflight-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
