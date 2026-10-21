#!/bin/bash
# A PAYLOAD WHOSE CONTENT WAS NEVER HASHED MUST NOT READ LIKE ONE THAT WAS.
#
# MEASURED 2026-10-21 by the harness audit: with an empty or unparseable SHA256SUMS.txt,
# tools/assert-payload.sh's integrity loop ran ZERO iterations - bad=0, n=0 - and the script fell
# through to `PASS: payload verified - 0 files`. All three consumers (mgmt/harness/matrix.sh,
# mgmt/harness/quick-upgrade.sh, tools/verify-release-package.sh) branch only on the exit code, so a
# campaign would install and grade a payload nothing had verified, with a log line identical to a
# real pass. This drives the shipped script, not a copy of it.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
A=tools/assert-payload.sh
[ -x "$A" ] || [ -f "$A" ] || { echo "FATAL: $A missing"; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/apfloor-XXXXXX"); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

mkpayload(){ # $1=dir $2=manifest-mode (empty|one|full)
  local d="$1" m="$2" f
  rm -rf "$d"; mkdir -p "$d"
  printf '{"source":{"driver_repo_commit":"%s"}}\n' "$(git rev-parse HEAD)" > "$d/MANIFEST.json"
  # THE REAL INSTALLER, because check 4 of the shipped script compares the staged copy against
  # the repo's at that commit - a stand-in makes the positive control fail for the fixture's
  # reason and would read as the floor refusing everything.
  cp packaging/setup/Install-QwtImproved.ps1 "$d/Install-QwtImproved.ps1"
  printf 'a payload file\n' > "$d/payload.dat"
  case "$m" in
    empty) : > "$d/SHA256SUMS.txt" ;;
    one)   printf '%s  Install-QwtImproved.ps1\n' "$(sha256sum "$d/Install-QwtImproved.ps1" | cut -d' ' -f1)" > "$d/SHA256SUMS.txt" ;;
    full)  : > "$d/SHA256SUMS.txt"
           for f in MANIFEST.json Install-QwtImproved.ps1 payload.dat; do
             printf '%s  %s\n' "$(sha256sum "$d/$f" | cut -d' ' -f1)" "$f" >> "$d/SHA256SUMS.txt"
           done ;;
  esac
}

run(){ bash "$A" "$1" HEAD 2>&1; }

# ---- 1. an empty manifest verifies nothing, so it must FAIL --------------------------------------
mkpayload "$T/empty" empty
out=$(run "$T/empty"); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | command grep -qa 'nothing was verified'; then
  ok "an EMPTY SHA256SUMS.txt fails, saying nothing was verified"
else no "an empty manifest gave rc=$rc" "$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi
printf '%s' "$out" | command grep -qa 'PASS: payload verified' \
  && no "it still printed a PASS line" "$(printf '%s' "$out" | command grep -a PASS)" \
  || ok "and it does not print a PASS line at all"

# ---- 2. a manifest too short to cover the asserted-present files is malformed --------------------
mkpayload "$T/one" one
out=$(run "$T/one"); rc=$?
[ "$rc" != 0 ] && ok "a manifest listing fewer files than the payload asserts present fails" \
               || no "a one-entry manifest passed (rc=0)" "$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"

# ---- 3. THE POSITIVE CONTROL: a real payload must still pass, or the floor refuses everything ----
mkpayload "$T/full" full
out=$(run "$T/full"); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa 'PASS'; then
  ok "a complete payload still passes (the floor does not refuse every payload)"
else no "a complete payload was refused (rc=$rc)" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; fi

# ---- 4. A CORRUPT file is still caught, which is what the loop was always for --------------------
mkpayload "$T/bad" full
printf 'tampered\n' > "$T/bad/payload.dat"
out=$(run "$T/bad"); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | command grep -qa 'MISMATCH payload.dat'; then
  ok "a tampered file is still caught by name"
else no "a tampered payload gave rc=$rc" "$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi

# ---- 4b. A COMMIT WITHOUT THE INSTALLER MUST FAIL, NOT SKIP INTO A PASS ------------------------
# The installer comparison sat in an `if` with no else and the PASS line printed either way, so a
# WANT_REF resolving to a commit where packaging/setup/Install-QwtImproved.ps1 does not exist
# produced the text of a real match. 0.69 campaign-stopper, tier re-check 2026-10-21.
# THE FIXTURE IS A REAL COMMIT THAT PREDATES THE FILE, found rather than invented - so this leg
# cannot pass because of a sha that resolves to nothing.
PRE=$(git log --reverse --format=%H -- packaging/setup/Install-QwtImproved.ps1 | head -1)
PRE=$(git rev-parse --verify --quiet "$PRE^" 2>/dev/null || true)
if [ -z "$PRE" ]; then
  ok "skipped: the installer exists in the repo's first commit, so no such commit exists to test"
else
  mkpayload "$T/preinst" full
  # the manifest must claim that commit, or check 3 fails first and this leg proves nothing
  printf '{"source":{"driver_repo_commit":"%s"}}\n' "$PRE" > "$T/preinst/MANIFEST.json"
  : > "$T/preinst/SHA256SUMS.txt"
  for f in MANIFEST.json Install-QwtImproved.ps1 payload.dat; do
    printf '%s  %s\n' "$(sha256sum "$T/preinst/$f" | cut -d' ' -f1)" "$f" >> "$T/preinst/SHA256SUMS.txt"
  done
  out=$(bash "$A" "$T/preinst" "$PRE" 2>&1); rc=$?
  if [ "$rc" != 0 ] && printf '%s' "$out" | command grep -qa 'does not exist at'; then
    ok "a commit predating the installer FAILS, saying the comparison could not be made"
  else
    no "a commit without the installer gave rc=$rc" "$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  fi
  printf '%s' "$out" | command grep -qa 'installer matches repo' \
    && no "it still claimed the installer matches" "the check never ran" \
    || ok "and it does not claim the installer matches"
fi

# ---- 5. SEEN TO FAIL: with the floor removed, the empty manifest passes again --------------------
# The regressed copy must live INSIDE tools/, because the shipped script resolves the repo from
# its own directory - run it from $T and it dies with "cannot resolve HEAD", which is the
# fixture failing, not the old behaviour reappearing.
NOFLOOR=tools/.nofloor-probe-$$.sh
sed '/ZERO FILES VERIFIED IS NOT AN INTEGRITY PASS/,/^fi$/d' "$A" > "$NOFLOOR"
out=$(bash "$NOFLOOR" "$T/empty" HEAD 2>&1); rc=$?
rm -f "$NOFLOOR"
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa '0 files'; then
  ok "SEEN TO FAIL: without the floor the empty payload reports PASS over 0 files"
else no "the regressed copy did not reproduce the old pass (rc=$rc)" "$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
