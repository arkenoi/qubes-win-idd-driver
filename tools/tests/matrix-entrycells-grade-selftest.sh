#!/bin/bash
# matrix-entrycells-grade-selftest.sh - the three entry cells must establish their OWN precondition.
#
# WHAT IT GRADES. cell_stock(), cell_upgrade() and cell_seeded() each enter from a fixture image and
# then assert that the image really is what the cell claims: stock 4.2.2 installed, a previous QWT
# installed, or a QWT with the xenbus monitor armed and RUNNING. 19 ok()/no() decisions between them,
# and tools/grader-census.py counted all three as untested.
#
# WHY IT MATTERS, from their own notes. "Presence-by-reg-key is the exact false negative that voided
# matrix-4318's upgrade cell" - the ITL Version key is absent on OUR builds, so reading presence from
# it reported "no QWT" for a guest that had one. The fix was to take presence from the MSI product
# registrations (qwt_products) and use the Version key only as a STOCKNESS discriminator. These
# checks pin that split: an unreadable count is INVALID-INSTRUMENT, a zero count is
# INVALID-PRECONDITION, and an empty Version key means "not stock" and never "no QWT".
#
# A CELL THAT CANNOT ESTABLISH ITS DECLARED PRECONDITION IS INVALID, NOT A PRODUCT VERDICT (H4.2),
# and the distinction is the point: a product FAIL blames the release, an INVALID blames the fixture.
#
# HOW IT IS DRIVEN. The SHIPPED functions are extracted from matrix.sh and run with every
# guest-touching helper stubbed. The downstream battery (run_install / verify_installed /
# accept_grade) is stubbed to a no-op on purpose: this suite is about the ENTRY assertions, and
# letting the battery run would grade things other suites already cover.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
ROOT="$PWD"

T=$(mktemp -d "${TMPDIR:-/tmp}/matrix-entrycells.XXXXXX") || exit 2
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT INT TERM

MSH="$ROOT/$(ls mgmt/harness/matri*.sh | head -1)"
for fn in cell_stock cell_upgrade cell_seeded; do
  eval "$(sed -n "/^$fn(){/,/^}\$/p" "$MSH")"
  declare -f "$fn" >/dev/null || { echo "FAIL could not extract $fn from $MSH"; exit 1; }
done

pass=0; fail=0
ok_(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no_(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ printf '%s' "$LINES" | grep -qa "$1"; }

# The qtest stub serves whatever the case asked for: the ITL Version key for cell_stock, and the
# service state for cell_seeded. It is reached by a RELATIVE path (./tools/qtest), so every case
# runs with cwd in the stub tree.
mkdir -p "$T/tree/tools"
cat > "$T/tree/tools/qtest" <<'QSTUB'
#!/bin/bash
case " $* " in
  *"/v Version"*)       [ -n "${QT_VERSION:-}" ] && printf '    Version    REG_SZ    %s\r\n' "$QT_VERSION" ;;
  *"sc query"*)         [ -n "${QT_SVC:-}" ]     && printf 'STATE : 4  %s\r\n' "$QT_SVC" ;;
  *"sc config"*)        [ "${QT_ARM:-1}" = 1 ] && printf 'ARMED\r\n' ;;
esac
exit 0
QSTUB
chmod +x "$T/tree/tools/qtest"

run_cell(){ # $1=function $2..=its args ; env: PRODUCTS, QT_VERSION, QT_SVC, QT_ARM, RECLONE_RC, BOOT_RC
  local fn=$1; shift
  OK=0; NO=0; LINES=""
  ok(){ OK=$((OK+1)); LINES="$LINES[OK] $*"$'\n'; }
  no(){ NO=$((NO+1)); LINES="$LINES[NO] $*"$'\n'; }
  say(){ LINES="$LINES[SAY] $*"$'\n'; }
  # entry plumbing
  ensure_churn_target(){ return 0; }
  reclone(){ return "${RECLONE_RC:-0}"; }
  boot_with_release_iso(){ return 0; }
  w_session(){ return "${BOOT_RC:-0}"; }
  logvol_bind_now(){ :; }
  qwt_products(){ printf '%s\n' "${PRODUCTS-}"; }
  qrun(){ QTEST_VM="${QTEST_VM:-}" ./tools/qtest run "$@"; }
  locate_release_disc(){ RELDISC="$T/disc.iso"; return 0; }
  detach_release_iso(){ :; }
  w_state(){ printf 'Running\n'; }
  start_vm(){ :; }
  # the downstream battery: other suites own these
  run_install(){ :; }
  verify_installed(){ return 0; }
  accept_grade(){ :; }
  M="$T/m"; R="$T/run.log"; mkdir -p "$M"; : > "$R"
  local _cwd="$PWD"
  cd "$T/tree" || { no_ "could not enter the stub tree"; return; }
  "$fn" "$@"
  cd "$_cwd" || return
}

# ================= cell_stock =================================================================
# 1. the fixture is genuinely stock 4.2.2
PRODUCTS=2 QT_VERSION="4.2.2" run_cell cell_stock entryimg vm10 c1
if has 'precondition real (stock 4.2.2 installed' && [ "$NO" = 0 ]; then ok_ "stock: a real stock-4.2.2 entry passes"
else no_ "stock: a real stock-4.2.2 entry passes" "OK=$OK NO=$NO $LINES"; fi

# 2. AN UNREADABLE COUNT IS MISSING DATA, never "absent"
PRODUCTS= QT_VERSION="4.2.2" run_cell cell_stock entryimg vm10 c1
if has 'INVALID-INSTRUMENT - could not count QWT products'; then ok_ "stock: an unreadable product count is INVALID-INSTRUMENT, not 'no QWT'"
else no_ "stock: an unreadable count is INVALID-INSTRUMENT" "$LINES"; fi

# 3. zero products is the FIXTURE's fault, not the release's
PRODUCTS=0 QT_VERSION="4.2.2" run_cell cell_stock entryimg vm10 c1
if has 'carries NO installed QWT' && has 'cell INVALID'; then ok_ "stock: zero products is INVALID, and names the fixture job to rebuild it"
else no_ "stock: zero products is INVALID" "$LINES"; fi

# 4. THE matrix-4318 FALSE NEGATIVE: an empty Version key means NOT STOCK, never "no QWT"
PRODUCTS=3 QT_VERSION= run_cell cell_stock entryimg vm10 c1
if has 'carries A QWT but not stock 4.2.2'; then ok_ "stock: a QWT with no ITL Version key is 'not stock' (the matrix-4318 false negative)"
else no_ "stock: an empty Version key is 'not stock'" "$LINES"; fi
PRODUCTS=3 QT_VERSION="4.3.36" run_cell cell_stock entryimg vm10 c1
if has 'but not stock 4.2.2'; then ok_ "stock: OUR version in that key is also 'not stock'"
else no_ "stock: our version is 'not stock'" "$LINES"; fi

# 5. the plumbing failures are distinct verdicts
RECLONE_RC=1 PRODUCTS=2 QT_VERSION=4.2.2 run_cell cell_stock entryimg vm10 c1
if has 'could not reclone'; then ok_ "stock: a failed reclone is its own verdict"
else no_ "stock: a failed reclone is its own verdict" "$LINES"; fi
BOOT_RC=1 PRODUCTS=2 QT_VERSION=4.2.2 run_cell cell_stock entryimg vm10 c1
if has 'clone did not boot'; then ok_ "stock: a clone that will not boot is its own verdict"
else no_ "stock: a clone that will not boot is its own verdict" "$LINES"; fi

# ================= cell_upgrade ===============================================================
PRODUCTS=2 run_cell cell_upgrade previmg vm10 c2
if has 'entry carries an installed QWT' && [ "$NO" = 0 ]; then ok_ "upgrade: an entry with a QWT installed passes"
else no_ "upgrade: an entry with a QWT passes" "OK=$OK NO=$NO $LINES"; fi
PRODUCTS= run_cell cell_upgrade previmg vm10 c2
if has 'INVALID-INSTRUMENT - could not count'; then ok_ "upgrade: an unreadable count is INVALID-INSTRUMENT"
else no_ "upgrade: an unreadable count is INVALID-INSTRUMENT" "$LINES"; fi
PRODUCTS=0 run_cell cell_upgrade previmg vm10 c2
if has 'not an upgrade cell, INVALID-PRECONDITION'; then ok_ "upgrade: a QWT-less entry is INVALID-PRECONDITION - it is not an upgrade at all"
else no_ "upgrade: a QWT-less entry is INVALID-PRECONDITION" "$LINES"; fi

# ================= cell_seeded ================================================================
PRODUCTS=2 QT_SVC=RUNNING run_cell cell_seeded seedimg vm11 c3
if has 'monitor armed AND RUNNING'; then ok_ "seeded: an armed, RUNNING monitor is the field state and passes"
else no_ "seeded: an armed RUNNING monitor passes" "$LINES"; fi
PRODUCTS=2 QT_SVC=STOPPED run_cell cell_seeded seedimg vm11 c3
if has "INVALID-PRECONDITION - monitor is 'STOPPED'"; then ok_ "seeded: a STOPPED monitor is INVALID-PRECONDITION, not a product FAIL"
else no_ "seeded: a STOPPED monitor is INVALID-PRECONDITION" "$LINES"; fi
PRODUCTS=2 QT_SVC= run_cell cell_seeded seedimg vm11 c3
if has 'monitor is .unreadable.'; then ok_ "seeded: an unreadable monitor state is named as unreadable, not assumed"
else no_ "seeded: an unreadable monitor state is named" "$LINES"; fi
PRODUCTS=2 QT_SVC=RUNNING QT_ARM=0 run_cell cell_seeded seedimg vm11 c3
if has 'could not arm - cell inconclusive'; then ok_ "seeded: a failed arm is INCONCLUSIVE - it never reads as the armed arm"
else no_ "seeded: a failed arm is inconclusive" "$LINES"; fi
PRODUCTS=0 QT_SVC=RUNNING run_cell cell_seeded seedimg vm11 c3
if has 'needs an existing install to seed over'; then ok_ "seeded: nothing to seed over is INVALID-PRECONDITION"
else no_ "seeded: nothing to seed over is INVALID-PRECONDITION" "$LINES"; fi

# ================= SEEN TO FAIL ================================================================
# Every verdict above must track its input. Two cases that differ only in the fixture must differ.
PRODUCTS=2 QT_VERSION=4.2.2 run_cell cell_stock e v c; a="$OK/$NO"
PRODUCTS=0 QT_VERSION=4.2.2 run_cell cell_stock e v c; b="$OK/$NO"
if [ "$a" != "$b" ]; then ok_ "SEEN TO FAIL: the entry verdict tracks the fixture ($a vs $b)"
else no_ "SEEN TO FAIL: the entry verdict tracks the fixture" "both gave $a - the graders are inert"; fi

printf 'matrix-entrycells-grade-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
