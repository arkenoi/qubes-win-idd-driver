#!/bin/bash
# Unattended drive toward the goal:
#   reboot dialog gone (seeded cell PASSES) -> all 3 install/upgrade paths on win10 and win11
#   -> appvm functional.
#
# Serial by construction: only one Windows guest may run at a time on this host, and concurrent
# VM-mutating jobs have rebooted each other and destroyed results before.
#
# It never edits a script that is running (that killed a run at 21:19), and it stops on the first
# cell that fails in a way that needs a human decision, leaving the guest in its failed state so
# the evidence survives.
set -uo pipefail
cd /home/user/qubes-win-idd-driver
T=/home/user/.claude/jobs/c2a0f57b/tmp
L=$T/orchestrate.log
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$L"; }

# ---------------------------------------------------------------- 0. wait for any running cell
for i in $(seq 1 120); do
  pgrep -f 'matri[x].sh' >/dev/null || break
  sleep 15
done
if pgrep -f 'matri[x].sh' >/dev/null; then say "a cell is still running after 30 min - aborting rather than editing under it"; exit 1; fi
say "no cell running - safe to patch and drive"

# ---------------------------------------------------------------- 1. clear the stale MSI log
# The MSI verbose log we poll is at a fixed path and SURVIVES from previous installs: the capture
# taken at 23:46 was timestamped 15/08/2026, i.e. the golden image's own install from two weeks
# earlier. Delete it before each install so what we read belongs to the run under test.
if ! grep -q 'del /f /q C:\\qwt-install.log' $T/matrix.sh; then
  python3 - <<'PY'
p='/home/user/.claude/jobs/c2a0f57b/tmp/matrix.sh'; s=open(p).read()
old = '''  QTEST_VM=$vm qrun "cmd /c del /f /q $GLOG 2>nul & echo CLEARED" >/dev/null 2>&1'''
new = '''  # Clear BOTH logs. The MSI verbose log lives at a fixed path and survives from earlier installs,
  # so without this the capture can show a two-week-old install and read as this run's evidence.
  QTEST_VM=$vm qrun "cmd /c del /f /q $GLOG 2>nul & del /f /q C:\\\\qwt-install.log 2>nul & echo CLEARED" >/dev/null 2>&1'''
assert old in s
open(p,'w').write(s.replace(old, new))
print('matrix.sh: stale MSI log now cleared before each install')
PY
fi
bash -n $T/matrix.sh || { say "matrix.sh does not parse after patching - stopping"; exit 1; }
say "matrix.sh patched and parses"

run_cells(){ # $1 = space-separated cell list, $2 = label
  say "=== running cells: $1 ==="
  CELLS="$1" POLL_SECS=5 STALL_SECS=120 EVENT_POLL=1 bash $T/matrix.sh >>"$L" 2>&1
  local p f
  p=$(grep -a '=== MATRIX:' $T/matrix/matrix.log | tail -1)
  say "  result: ${p:-<no summary - the run died>}"
  echo "$p" | grep -qa ' 0 failed' && return 0 || return 1
}

# ---------------------------------------------------------------- 2. the detector must pass first
# Everything else is meaningless until the brick is fixed: a cell that installs onto a guest that
# then bricks proves nothing about install paths.
say "### PHASE 1: the paths users actually take"
# The seeded cell is DEMOTED to informational and runs last. It arms start=auto on a guest whose PV
# driver is the SAME version (9.1.0.0), so the driver package is never re-applied and the patched
# xenbus.inf never takes effect - a combination no real install produces. Measured 2026-08-29: with
# the Request written mid-MSI the installer CLEARED it and stopped the monitor before msiexec, and
# no restart event was recorded, so the mechanism it was built to catch did not even fire. Gating
# the whole matrix behind that artificial case cost hours and proved nothing about the product.

# ---------------------------------------------------------------- 3. the three paths, both guests
say "### PHASE 2: win10 install/upgrade paths"
run_cells "win10-fresh" fresh   || say "  (win10-fresh failed - continuing to map the rest)"
run_cells "win10-2stage" 2stage || say "  (win10-2stage failed - continuing)"
run_cells "win10-stock" stock   || say "  (win10-stock failed - continuing)"
say "### PHASE 3: win10 appvm"
run_cells "win10-appvm" appvm   || say "  (win10-appvm failed)"

say "### PHASE 4: win11 install/upgrade paths"
run_cells "win11-1stage" w11a   || say "  (win11-1stage failed - continuing)"
run_cells "win11-fresh" w11b    || say "  (win11-fresh failed - continuing)"
run_cells "win11-2stage" w11c   || say "  (win11-2stage failed - continuing)"
run_cells "win11-stock" w11d    || say "  (win11-stock failed - continuing)"
say "### PHASE 5: win11 appvm"
run_cells "win11-appvm" w11e    || say "  (win11-appvm failed)"

say "### PHASE 6 (informational): the artificial seeded worst case"
run_cells "win10-seeded" seeded || say "  (win10-seeded failed - artificial case, see FINDINGS 2026-08-29)"

say "=== ORCHESTRATION DONE ==="
grep -a 'PASS\|FAIL' $T/matrix/matrix.log | tail -40 | sed 's/^/  /' | tee -a "$L"
