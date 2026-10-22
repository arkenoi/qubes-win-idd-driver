#!/usr/bin/env bash
# campaign-full-selftest.sh - the two things mgmt/harness/campaign-full.sh decides for itself.
#
# campaign-full.sh composes tools that already have their own suites, so there are exactly two
# pieces of logic it owns, and both are ones I got wrong BY HAND on 2026-10-22:
#
#   PKGROLES - which of two release-package runs at the same commit is the ordinary package and
#              which is the fault_injection one. Their display titles are IDENTICAL, so I reached
#              for dispatch order; and my first discriminator (grep QGAFAULT in the shipped
#              gui-agent.exe) returned 0 on BOTH, which reads as "the flag did nothing". The only
#              thing that settles it is each build's own log line QGA_FAULT_INJECTION=0/1. The
#              decisive leg below puts the FI run FIRST in the listing, so a resolver that trusted
#              order would swap the roles and feed an ordinary package to failproof-faultinject.
#   CIDUE    - which required workflows are merely branch-filtered (and so should be dispatched for
#              this sha) versus actually RED (which must refuse). tools/ci-state.py says this in
#              words; the fixture here is its REAL output, captured from the run that refused at
#              c6484db3, not a sentence of my own invention.
#
# Both regions are extracted from the harness between its markers - never copied - so this suite
# cannot pass against a version of the logic that no longer ships.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/mgmt/harness/campaign-full.sh"
pass=0; fail=0
say(){ printf '%s\n' "$*"; }
ck(){ if [ "$2" = 0 ]; then pass=$((pass+1)); say "ok   $1"; else fail=$((fail+1)); say "FAIL $1"; [ -n "${3:-}" ] && say "       -> $3"; fi; }
[ -f "$SRC" ] || { say "FAIL  $SRC missing - nothing ran"; exit 2; }

PKGROLES=$(awk '/# ---- PKGROLES-BEGIN/{f=1;next}/# ---- PKGROLES-END/{f=0}f' "$SRC")
CIDUE=$(awk '/# ---- CIDUE-BEGIN/{f=1;next}/# ---- CIDUE-END/{f=0}f' "$SRC")
[ -n "$PKGROLES" ] || { say "FAIL  could not extract PKGROLES"; exit 2; }
[ -n "$CIDUE" ] || { say "FAIL  could not extract CIDUE"; exit 2; }
printf '%s' "$PKGROLES" | grep -q 'QGA_FAULT_INJECTION' || { say "FAIL  the extracted resolver does not read QGA_FAULT_INJECTION"; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/campfull.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# A FILE on PATH, not a shell function: the region calls `gh` as a command, and a function cannot
# stub what another process execs - this project has already paid for that confusion once.
mk_gh(){ # mk_gh "<id>:<0|1|none> ..."   ids listed in the order `gh run list` would print them
  cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
# stub: `run list` prints the ids in SPEC order; `run view --log` prints that id's injection line.
spec_file="$GH_SPEC"
case "$1 $2" in
  "run list")
    awk '{for(i=1;i<=NF;i++){split($i,a,":");print a[1]}}' "$spec_file" ;;
  "run view")
    id="$3"
    v=$(awk -v want="$id" '{for(i=1;i<=NF;i++){split($i,a,":");if(a[1]==want)print a[2]}}' "$spec_file")
    case "$v" in
      0) echo "2026-10-22T10:00:00Z  agent  QGA_FAULT_INJECTION=0" ;;
      1) echo "2026-10-22T10:00:00Z  agent  QGA_FAULT_INJECTION=1" ;;
      *) echo "2026-10-22T10:00:00Z  agent  built fine, said nothing about injection" ;;
    esac ;;
esac
exit 0
EOF
  chmod +x "$T/bin/gh"
  printf '%s\n' "$1" > "$T/spec"
}

drive(){ # drive -> prints "PKG=<id> FI=<id>" or "DIE: <message>"; never touches a rig
  GH_SPEC="$T/spec" PATH="$T/bin:$PATH" bash -c '
    set -uo pipefail
    BRANCH=testbranch; HEAD_SHA=deadbeefcafe0000; SHORT=deadbeefcafe
    log(){ :; }
    die(){ echo "DIE: $*"; exit 2; }
    '"$PKGROLES"'
    resolve_pkgs
    echo "PKG=$PKG FI=$FI"' 2>&1
}

# ---- 1. THE DECISIVE LEG: roles come from the logs, and the listing order is REVERSED -----------
# The FI run is printed FIRST. A resolver that took "the first one" as the ordinary package would
# hand an ordinary package to failproof-faultinject and call the campaign full.
mk_gh "900:1 901:0"
out=$(drive)
ck 'roles come from each build log, not from the listing order (FI listed first)' \
   "$([ "$out" = "PKG=901 FI=900" ] && echo 0 || echo 1)" "got: $out"
# SEEN TO FAIL: the order-trusting resolver, on this very fixture
ordered=$(GH_SPEC="$T/spec" PATH="$T/bin:$PATH" bash -c 'ids=$(gh run list); set -- $ids; echo "PKG=$1 FI=$2"')
ck 'SEEN TO FAIL: an order-trusting resolver swaps the roles on that same fixture' \
   "$([ "$ordered" = "PKG=900 FI=901" ] && echo 0 || echo 1)" "the order-trusting result was: $ordered"

mk_gh "700:0 701:1"
out=$(drive)
ck '...and it is right the other way round too' \
   "$([ "$out" = "PKG=700 FI=701" ] && echo 0 || echo 1)" "got: $out"

# ---- 1b. a NAMED pair is PROVEN, not trusted ---------------------------------------------------
# The operator may name the pair (the package's commit and HEAD legitimately differ for a
# harness-only commit, and campaign-preflight owns that judgement). Naming must not bypass the proof.
drive_named(){ GH_SPEC="$T/spec" PATH="$T/bin:$PATH" PKG="$1" FI="$2" bash -c '
    set -uo pipefail
    BRANCH=testbranch; HEAD_SHA=deadbeefcafe0000; SHORT=deadbeefcafe
    log(){ :; }
    die(){ echo "DIE: $*"; exit 2; }
    '"$PKGROLES"'
    resolve_pkgs
    echo "PKG=$PKG FI=$FI"' 2>&1; }

mk_gh "600:0 601:1"
out=$(drive_named 600 601)
ck 'a NAMED pair with the right roles is accepted' \
   "$([ "$out" = "PKG=600 FI=601" ] && echo 0 || echo 1)" "got: $out"
out=$(drive_named 601 600)
ck 'SEEN TO FAIL: a NAMED pair with SWAPPED roles is REFUSED - naming is not trusting' \
   "$(printf '%s' "$out" | grep -q '^DIE:' && echo 0 || echo 1)" "got: $out"
ck '...and the refusal says which value each role must print' \
   "$(printf '%s' "$out" | grep -q 'QGA_FAULT_INJECTION=0' && echo 0 || echo 1)" "got: $out"
mk_gh "610:0 611:none"
out=$(drive_named 610 611)
ck 'a named FI run whose log states nothing is REFUSED' \
   "$(printf '%s' "$out" | grep -q '^DIE:' && echo 0 || echo 1)" "got: $out"

# ---- 2. the refusals ---------------------------------------------------------------------------
mk_gh "800:0 801:0"
out=$(drive)
ck 'two ordinary builds and no FI build is a REFUSAL, not a campaign' \
   "$(printf '%s' "$out" | grep -q '^DIE:' && echo 0 || echo 1)" "got: $out"
ck '...and the refusal says why a FULL gate is unreachable without it' \
   "$(printf '%s' "$out" | grep -q 'failproof' && echo 0 || echo 1)" "got: $out"
ck '...and it names the dispatch that fixes it' \
   "$(printf '%s' "$out" | grep -q 'fault_injection=true' && echo 0 || echo 1)" "got: $out"

mk_gh "810:1 811:1"
out=$(drive)
ck 'two FI builds and no ordinary build is a REFUSAL' \
   "$(printf '%s' "$out" | grep -q 'ordinary package' && echo 0 || echo 1)" "got: $out"

mk_gh "820:none"
out=$(drive)
ck 'a build whose log states no injection value is used for NEITHER role' \
   "$(printf '%s' "$out" | grep -q '^DIE:' && echo 0 || echo 1)" "got: $out"

: > "$T/spec"
out=$(drive)
ck 'no successful release-package run at the sha is a REFUSAL that names the dispatch' \
   "$(printf '%s' "$out" | grep -q 'release-package.yml' && echo 0 || echo 1)" "got: $out"

# ---- 3. CIDUE: branch-filtered versus RED ------------------------------------------------------
cidue(){ # cidue <ci-state file> -> the workflow names it would dispatch
  bash -c '
    set -uo pipefail
    OUT='"$T"'; cp "$1" '"$T"'/ci-state.txt
    '"$CIDUE"'
    printf "%s\n" "${due[@]}"' _ "$1" 2>&1
}
# THE REAL OUTPUT of tools/ci-state.py from the run that refused at c6484db3 on 2026-10-22.
cat > "$T/ci-real.txt" <<'EOF'
ci-state c6484db3
  MISS build.yml              completed   success   39736997401 (required) DUE for this sha (its paths matched) but branch-filtered: runs on push to main only; inherited from acd3e1a9 - REQUIRED, its paths matched, and it cannot run on this branch: dispatch it for this sha
  inh  pv-xencons.yml         completed   success   39579885578 path-filtered; inherited from 726f0e10
  ok   release-package.yml    completed   success   39767068509
  ok   test.yml               completed   success   39767061457 (required)
CI 1 a required workflow is RED or absent for c6484db3 - do not receipt against this sha
EOF
got=$(cidue "$T/ci-real.txt")
ck 'the REAL ci-state refusal yields exactly the branch-filtered workflow to dispatch' \
   "$([ "$got" = "build.yml" ] && echo 0 || echo 1)" "got: '$got'"
ck '...and it does NOT pick up the path-filtered or already-green rows' \
   "$(printf '%s' "$got" | grep -qE 'pv-xencons|release-package|test\.yml' && echo 1 || echo 0)" "got: '$got'"

cat > "$T/ci-red.txt" <<'EOF'
ci-state c6484db3
  RED  test.yml               completed   failure   39762170206 (required)
CI 1 a required workflow is RED or absent for c6484db3 - do not receipt against this sha
EOF
got=$(cidue "$T/ci-red.txt")
ck 'a genuinely RED required workflow yields NOTHING to dispatch, so the chain must refuse' \
   "$([ -z "$(printf '%s' "$got" | tr -d '[:space:]')" ] && echo 0 || echo 1)" "got: '$got'"

cat > "$T/ci-two.txt" <<'EOF'
ci-state c6484db3
  MISS build.yml   completed success 1 (required) DUE for this sha (its paths matched) but branch-filtered - REQUIRED, its paths matched, and it cannot run on this branch: dispatch it for this sha
  MISS test.yml    completed success 2 (required) DUE for this sha (its paths matched) but branch-filtered - REQUIRED, its paths matched, and it cannot run on this branch: dispatch it for this sha
EOF
got=$(cidue "$T/ci-two.txt" | tr '\n' ' ')
ck 'two branch-filtered required workflows are both dispatched' \
   "$(printf '%s' "$got" | grep -q 'build.yml' && printf '%s' "$got" | grep -q 'test.yml' && echo 0 || echo 1)" "got: '$got'"

# ---- 4. the harness refuses to touch a rig in DRY mode -----------------------------------------
ck 'DRY mode is honoured before any guest-touching step (no release-acceptance/gate-remainder above the DRY exit)' \
   "$(awk '/^if \[ -n "\$DRY" \]; then/{found=1} found&&/exit 0/{print "ok";exit}' "$SRC" | grep -q ok && echo 0 || echo 1)" \
   'the DRY block must exit before step 4'
ck 'the chain never defaults a remainder target inside a called harness (lint L10)' \
   "$(grep -q ': "${VM10:=' "$SRC" && grep -q -- '--vm10 "$VM10"' "$SRC" && echo 0 || echo 1)" \
   'VM10/VM11/OS11 are named here and passed explicitly'

say ''
say "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
