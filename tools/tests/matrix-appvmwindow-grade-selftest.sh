#!/bin/bash
# matrix-appvmwindow-grade-selftest.sh - the appvm cell's WINDOW verdict, driven for real.
#
# WHY THE SPLIT CAME FIRST. An earlier version of this suite tried to drive cell_appvm whole, and the
# cell's boot loop ran on into dom0 captures and lifecycle-lib helpers: stubbing them shifted the
# cell's own verdicts (12/3 where it had been 15/0), not stubbing them left unbound state under
# set -u, and three consecutive runs gave 14/1, 15/0 and 10/5. A flaky check cannot be reasoned about
# and is worse than none, so that suite was deleted and the tail was extracted into
# grade_appvm_window() - the same move made for grade_cell_logsweep and grade_dom0_callers, both of
# which have had suites since.
#
# THIS FILE DRIVES THE WINDOW HALF, which the split made testable. THE CELL HALF IS STILL NOT
# COVERED: with grade_appvm_window stubbed to a return code, cell_appvm still flapped across three
# runs (19/1, 16/4, 19/1), so no suite for it is registered and grader-census.py still counts its
# decisions as untested. That is the honest state; a flaky suite would have hidden it.
#
# WHAT IT PINS, every one a measured incident recorded in matrix.sh itself:
#   * an ABSENT template is an infrastructure fact knowable in one call, not a guest that refused to
#     halt - "FOUR of that campaign's ELEVEN failures were this one message" (run 9);
#   * a missing 'installed' park is a HARD refusal, never a downgrade to "whatever the template last
#     happened to hold";
#   * an AppVM is RE-CREATED, never reused: its private seeds from the template at creation only, so
#     a reused one has no profile and no shell (owner correction 2026-09-04), reported as STALE
#     PRIVATE VOLUME rather than as a product defect;
#   * AN EMPTY dom0 CAPTURE IS NOT "NO WINDOW" - campaign 34594988407 graded WIN11-appvm boot 2 a
#     product FAIL on six empty tars while qrexec answered and the guest shut down cleanly 58 s
#     later; the owner was switching dom0 desktops. Guest window present + capture empty is
#     INVALID-INSTRUMENT, ungraded, and only the cell's own all-boots verdict may escalate it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
ROOT="$PWD"

T=$(mktemp -d "${TMPDIR:-/tmp}/matrix-appvmwindow.XXXXXX") || exit 2
MYPID=$BASHPID
trap 'rc=$?; [ "$BASHPID" = "$MYPID" ] || exit "$rc"; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT INT TERM

MSH="$ROOT/$(ls mgmt/harness/matri*.sh | head -1)"
for fn in grade_appvm_window; do
  eval "$(sed -n "/^$fn(){/,/^}\$/p" "$MSH")"
  declare -f "$fn" >/dev/null || { echo "FAIL could not extract $fn from $MSH"; exit 1; }
done

pass=0; fail=0
ok_(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no_(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
has(){ printf '%s' "$LINES" | grep -qa "$1"; }

mkdir -p "$T/tree/mgmt/harness" "$T/tree/tools" "$T/bin"
# ONE CASE FILE, read by shell stubs and external stubs alike, one per case so a straggler cannot
# read the next case's inputs.
export CASE_ENV="$T/case.0.env"; : > "$CASE_ENV"
cat > "$T/bin/_v" <<'VEOF'
#!/bin/bash
sed -n "s/^$1=//p" "$CASE_ENV" | tail -1
VEOF
chmod +x "$T/bin/_v"
v(){ sed -n "s/^$1=//p" "$CASE_ENV" | tail -1; }
rcof(){ local r; r=$(v "$1"); printf '%s' "${r:-0}"; }

printf '#!/bin/bash\nPATH="%s:$PATH"\nexit "$(r=$(_v CKPT_RC); echo ${r:-0})"\n' "$T/bin" > "$T/tree/mgmt/harness/checkpoint.sh"
chmod +x "$T/tree/mgmt/harness/checkpoint.sh"
for c in qvm-check qvm-ls qvm-create qvm-tags qvm-features qvm-prefs qvm-remove qvm-shutdown qvm-kill; do
  cat > "$T/bin/$c" <<EOF
#!/bin/bash
PATH="$T/bin:\$PATH"
case "$c" in
  qvm-check)  for x in \$(_v EXIST_VMS); do [ "\${@: -1}" = "\$x" ] && exit 0; done; exit 1 ;;
  qvm-ls)     printf '%s\n' \$(_v PARKS) \$(_v EXIST_VMS) ;;
  qvm-create) exit "\$(r=\$(_v CREATE_RC); echo \${r:-0})" ;;
  qvm-tags)   exit "\$(r=\$(_v TAG_RC); echo \${r:-0})" ;;
  qvm-remove) exit "\$(r=\$(_v REMOVE_RC); echo \${r:-0})" ;;
  *)          exit 0 ;;
esac
EOF
  chmod +x "$T/bin/$c"
done

CASE_N=0
newcase(){ CASE_N=$((CASE_N+1)); export CASE_ENV="$T/case.$CASE_N.env"; : > "$CASE_ENV"
           local kv; for kv in "$@"; do printf '%s\n' "$kv" >> "$CASE_ENV"; done; }

common_stubs(){
  ok(){ OK=$((OK+1)); LINES="$LINES[OK] $*"$'\n'; }
  no(){ NO=$((NO+1)); LINES="$LINES[NO] $*"$'\n'; }
  say(){ LINES="$LINES[SAY] $*"$'\n'; }
  sleep(){ :; }
  M="$T/m"; R="$T/run.log"; mkdir -p "$M"; : > "$R"
}

# =============== grade_appvm_window, driven for real ==========================================
# The dom0 capture is a real tar of real PNGs, built here: the function reads the IHDR of each to
# decide "fullscreen-sized", so a fixture has to carry genuine PNG headers.
png(){ python3 - "$1" "$2" "$3" <<'PY'
import struct, sys, zlib
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def chunk(t, d):
    c = t + d
    return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IEND", b""))
PY
}
run_win(){ newcase "$@"
  OK=0; NO=0; LINES=""; common_stubs
  ctl_start(){ printf 'h 123 456\n'; }
  ctl_stop(){ printf 'stopped\n'; }
  g_probe(){ printf '%s\n' "$(v GUEST_WINDOWS)"; }
  local _cwd="$PWD"
  cd "$T/tree" || { no_ "could not enter the stub tree"; return; }
  PATH="$T/bin:$PATH" grade_appvm_window winapp c1 1
  WIN_RC=$?
  cd "$_cwd" || return
}
# the qtest stub builds whatever capture the case asked for
cat > "$T/tree/tools/qtest" <<EOF
#!/bin/bash
PATH="$T/bin:\$PATH"
case " \$* " in
  *shot*) out=\${!#}
          case "\$(_v CAPTURE)" in
            empty)   : > "\$out" ;;
            normal)  tar cf "\$out" -C "$T/png" normal.png ;;
            big)     tar cf "\$out" -C "$T/png" big.png ;;
          esac ;;
esac
exit 0
EOF
chmod +x "$T/tree/tools/qtest"
mkdir -p "$T/png"; png "$T/png/normal.png" 1024 768; png "$T/png/big.png" 5120 1440

run_win CAPTURE=normal
if [ "$WIN_RC" = 0 ] && has 'window(s) mapped, none fullscreen-sized'; then ok_ "window: an ordinary window passes and returns 0"
else no_ "window: an ordinary window passes" "rc=$WIN_RC $LINES"; fi
run_win CAPTURE=big
if [ "$WIN_RC" = 1 ] && has 'FULLSCREEN-SIZED window was mapped'; then ok_ "window: a fullscreen-sized window is graded and returns 1"
else no_ "window: fullscreen is graded" "rc=$WIN_RC $LINES"; fi
run_win CAPTURE=empty GUEST_WINDOWS=1
if [ "$WIN_RC" = 2 ] && has 'INVALID-INSTRUMENT' && [ "$NO" = 0 ]; then
  ok_ "window: guest HAS a window but dom0 captured none is INVALID-INSTRUMENT, UNGRADED (campaign 34594988407)"
else no_ "window: empty capture with a guest window is INVALID and ungraded" "rc=$WIN_RC NO=$NO $LINES"; fi
run_win CAPTURE=empty GUEST_WINDOWS=0
if [ "$WIN_RC" = 3 ] && has 'dom0 got NO window'; then ok_ "window: no window anywhere IS a product verdict, and returns 3"
else no_ "window: no window anywhere is graded" "rc=$WIN_RC $LINES"; fi

# ---- SEEN TO FAIL: the two halves must each track their input --------------------------------
run_win CAPTURE=normal; a="$WIN_RC"
run_win CAPTURE=big;    b="$WIN_RC"
if [ "$a" != "$b" ]; then ok_ "SEEN TO FAIL: the window verdict tracks the capture ($a vs $b)"
else no_ "SEEN TO FAIL: the window verdict tracks the capture" "both returned $a"; fi
printf 'matrix-appvmwindow-grade-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
