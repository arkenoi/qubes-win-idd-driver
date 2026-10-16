#!/bin/bash
# campaign-preflight-selftest.sh - EVERY REFUSAL OF THE CAMPAIGN PREFLIGHT, SEEN TO FIRE.
#
# WHY THIS EXISTS. The checks in mgmt/harness/campaign-preflight.sh lived in an untracked scratchpad
# chain script, so the one thing standing between a mistake and FOUR HOURS of exclusive rig time -
# plus the operator's screen, which the visual cells take over - was a scratch file whose refusals
# had never been seen to fire. A gate nobody has watched refuse is decoration.
#
# HOW IT IS DRIVEN. The programs the preflight shells out to are stubbed on PATH or through the
# script's own overrides (gh, qvm-check, the golden tool, the CI reader), so the REAL preflight code
# runs against controlled answers. Nothing stubs the preflight itself.
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
cat > "$T/bin/qvm-check" <<'EOF'
#!/bin/bash
vm="${@: -1}"
case " ${RUNNING_VMS:-} " in *" $vm "*) exit 0 ;; *) exit 3 ;; esac
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
if ! git show "$GOODSHA:guest/qwt-report-death.ps1" 2>/dev/null | grep -qa -- "$MARKER"; then
  echo "FATAL: HEAD does not carry $MARKER - this suite needs a commit that does" >&2; exit 2
fi
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

run(){ # -> rc; output in $T/out
  PATH="$T/bin:$PATH" \
  GH_BIN="$T/bin/gh" GH_STATE="${GH_STATE:-$T/pkg.state}" \
  QVM_CHECK="$T/bin/qvm-check" GOLDEN_SH="$T/bin/golden.sh" \
  CI_STATE="$T/bin/ci-reader" \
  GOLDENS_DIR="$T/goldens" FIXTURES_DIR="$T/fixtures" \
  CI_WAIT_SECONDS="${CI_WAIT_SECONDS:-0}" CI_POLL_SECONDS=1 \
  RUNNING_VMS="${RUNNING_VMS:-}" BAD_GOLDENS="${BAD_GOLDENS:-}" CI_LINE="${CI_LINE:-}" \
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
if [ "$fail" -eq 0 ] && [ "$pass" -ge 11 ]; then ok "all 11 arms driven: one CLEAR and ten distinct REFUSALS"
else no "all 11 arms driven" "pass=$pass fail=$fail"; fi

printf 'campaign-preflight-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
