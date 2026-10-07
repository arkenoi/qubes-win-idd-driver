#!/bin/bash
# SELF-TEST for tools/lint-harness.py — every lint must be SEEN TO FIRE.
#
# H5 applied to the linter. A lint that has never gone red is exactly the unproven check the
# linter exists to find; shipping one would be the same disease one level up. So: build a fixture
# tree containing a deliberate violation of each rule, run the lints against it, and require the
# matching lint to appear. Then build a CLEAN fixture and require silence, so a lint that fires
# unconditionally is caught too.
#
#   tools/tests/lint-selftest.sh
set -uo pipefail
cd "$(dirname "$0")/../.."   # the checkout this selftest lives in (a worktree included), not a fixed path
LINT=tools/lint-harness.py
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "  PASS  $*"; pass=$((pass+1)); }
no(){ echo "  FAIL  $*"; fail=$((fail+1)); }

mk(){ # <dir> — a minimal tree the lints can walk
  mkdir -p "$1/mgmt/harness" "$1/guest" "$1/agent/gui-agent"
  printf '#!/bin/bash\n: clean\n' > "$1/mgmt/harness/clean.sh"
}

expect_silent(){ # <lint-id> <fixture-dir> <what was planted> - a lint that fires on the
  # CORRECT shape is as useless as one that never fires; this is the other half of the proof.
  local id="$1" dir="$2" what="$3"
  local out; out=$(python3 "$LINT" --root "$dir" --quiet 2>&1)
  if echo "$out" | grep -q "^$id"; then
    no "$id fired on the CORRECT shape: $what  <-- false positive"
  else
    ok "$id stays silent on: $what"
  fi
}

expect_fires(){ # <lint-id> <fixture-dir> <what was planted>
  local id="$1" dir="$2" what="$3"
  # CAPTURE FIRST. `set -o pipefail` + a linter that EXITS 1 ON FINDINGS means
  # `lint | grep -q` reports the LINT's status, not grep's - so every case "failed" while the
  # lint was in fact firing correctly. Found 2026-08-31 while writing this very self-test.
  local out; out=$(python3 "$LINT" --root "$dir" --quiet 2>&1)
  if echo "$out" | grep -q "^$id"; then
    ok "$id fires on: $what"
  else
    no "$id did NOT fire on: $what  <-- the lint cannot detect its own target"
  fi
}

# ---------------------------------------------------------------- L1 double background
D="$TMP/l1"; mk "$D"
printf '#!/bin/bash\nnohup bash runner.sh &\n' > "$D/mgmt/harness/bad.sh"
expect_fires L1-double-background "$D" "nohup ... &"

# ---------------------------------------------------------------- L2 missing vmlock
D="$TMP/l2"; mk "$D"
printf '#!/bin/bash\nVM=$1\n./tools/qtest run "echo hi"\n' > "$D/mgmt/harness/bad.sh"
expect_fires L2-missing-vmlock "$D" "drives a guest with no vm_lock"

# ---------------------------------------------------------------- L3 nested-quote powershell
D="$TMP/l3"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
r 'cmd /c powershell -NoProfile -Command "$x=(Get-Item \"C:\a\").Name; Write-Output $x"'
EOS
expect_fires L3-nested-quote-powershell "$D" "escaped quotes inside -Command"

# ---------------------------------------------------------------- L9 shutdown --wait kills
D="$TMP/l9"; mk "$D"
printf '#!/bin/bash\n# a COMMENT naming qvm-shutdown --wait must NOT fire\ntimeout 300 qvm-shutdown --wait "$VM"\n' > "$D/mgmt/harness/bad.sh"
expect_fires L9-shutdown-wait-kills "$D" "timeout 300 qvm-shutdown --wait (kills at 60)"

# ---------------------------------------------------------------- L4 check that cannot fail
D="$TMP/l4"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
printf 'CELL\tnever-fails\tPASS-UNPROVEN\tlooks good\t%s\n' "$EV" >> "$V"
EOS
expect_fires L4-check-cannot-fail "$D" "a check emitted only from a PASS branch"

# ---------------------------------------------------------------- L5 injector string collision
D="$TMP/l5"; mk "$D"
cat > "$D/agent/gui-agent/faultinject.c" <<'EOS'
void FiThing(void){ LogWarning("QGAFAULT firing: the capture thread returns WITHOUT signalling"); }
EOS
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
psrun 'Select-String -Pattern "capture thread|thread exiting"'
EOS
expect_fires L5-injector-collision "$D" "a grep pattern the injector also logs"

# ---------------------------------------------------------------- L6 probe null-deref
D="$TMP/l6"; mk "$D"
cat > "$D/guest/probe.ps1" <<'EOS'
[pscustomobject]@{
    sha = (Get-FileHash 'C:\missing.ps1' -Algorithm SHA256).Hash.ToLower()
} | ConvertTo-Json -Compress
EOS
expect_fires L6-probe-null-deref "$D" "chained access on a cmdlet that can return null"

# ---------------------------------------------------------------- L7 orphan ledger check
D="$TMP/l7"; mk "$D"
printf 'CELL\tnobody-emits-this\tPASS-UNPROVEN\tdetail\tEV\n' > "$TMP/led.tsv"
l7out=$(python3 "$LINT" --root "$D" --ledger "$TMP/led.tsv" --quiet 2>&1)
if echo "$l7out" | grep -q '^L7-orphan-ledger-check'; then
  ok "L7-orphan-ledger-check fires on: a ledger name no harness emits"
else
  no "L7-orphan-ledger-check did NOT fire  <-- the lint cannot detect its own target"
fi

# ---------------------------------------------------------------- L11 absent guest command
# 2026-09-21: a boot-time classifier shipped reading `wmic`, which Windows 11 24H2+ does not have,
# so it could never have returned a value and every verdict on it was decoration.
D="$TMP/l11"; mk "$D"
printf '#!/bin/bash\nVM=$1\nsource mgmt/harness/vmlock.sh; vm_lock "$VM"\nb=$(tools/qtest run "cmd /c wmic os get lastbootuptime /value")\n' > "$D/mgmt/harness/bad.sh"
expect_fires L11-absent-guest-command "$D" "a guest probe built on wmic"
# ...and in a python tool, which is where the second copy lived and where no lint was looking.
D="$TMP/l11b"; mk "$D"; mkdir -p "$D/tools"
printf 'cmd = ["tools/qtest", "run", "cmd /c wmic os get lastbootuptime /value"]\n' > "$D/tools/judge.py"
expect_fires L11-absent-guest-command "$D" "the same command inside a python tool"

# ---------------------------------------------------------------- the NEGATIVE control
# L16: a catch-block local that differs only in case from a $script: name (the 2026-10-02 `$st` that silenced the updater's remedy)
D="$TMP/l16"; mk "$D"
cat > "$D/guest/upd.ps1" <<'EOS'
$script:St = [ordered]@{ phase='init' }
try { throw 'x' } catch {
  $st = "$($_.ScriptStackTrace)"
}
EOS
expect_fires L16-ps-script-scope-case-collision "$D" 'a local $st beside $script:St'
D="$TMP/l16ok"; mk "$D"
cat > "$D/guest/upd.ps1" <<'EOS'
$script:St = [ordered]@{ phase='init' }
$warn = 0
function Bump { $script:warn++ }
try { throw 'x' } catch { $stackText = "$($_.ScriptStackTrace)" }
EOS
expect_silent L16-ps-script-scope-case-collision "$D" 'same-case script-level reuse and a distinct local name'

# A lint that fires on everything is as useless as one that never fires. A clean tree must be
# silent, or every finding above is meaningless.
D="$TMP/clean"; mk "$D"
cat > "$D/mgmt/harness/good.sh" <<'EOS'
#!/bin/bash
VM="$1"
source mgmt/harness/vmlock.sh; vm_lock "$VM"
./tools/qtest run 'cmd /c echo ok'
printf 'CELL\tproper-check\tPASS-UNPROVEN\tgood\t%s\n' "$EV" >> "$V"
printf 'CELL\tproper-check\tFAIL\tbad\t%s\n' "$EV" >> "$V"
EOS
cat > "$D/guest/probe.ps1" <<'EOS'
$h = $(if (Test-Path 'C:\x.ps1') { (Get-FileHash 'C:\x.ps1' -Algorithm SHA256).Hash.ToLower() } else { $null })
[pscustomobject]@{ sha = $h } | ConvertTo-Json -Compress
EOS
out=$(python3 "$LINT" --root "$D" --quiet 2>&1)
if echo "$out" | grep -q '^CLEAN'; then
  ok "negative control: a compliant tree produces NO findings"
else
  no "negative control: a compliant tree produced findings:"; echo "$out" | sed 's/^/        /'
fi

echo
# ---------------------------------------------------------------- L12 provisioning recipe
# Three ways the recipe was actually broken, each planted on its own so one cannot mask another.
D="$TMP/l12a"; mk "$D"
printf '#!/bin/bash\nqvm-device block assign -o frontend-dev=xvdi -o devtype=disk "$VM" holder:loop0\n' > "$D/mgmt/harness/bad.sh"
expect_fires L12-provisioning-recipe "$D" "a block assign WITHOUT --required"

D="$TMP/l12b"; mk "$D"
printf '#!/bin/bash\nPRIME_ASSIGN_MODE="${PRIME_ASSIGN_MODE:-plain}"\n' > "$D/mgmt/harness/bad.sh"
expect_fires L12-provisioning-recipe "$D" "a default selecting the plain assignment mode"

D="$TMP/l12c"; mk "$D"
printf '#!/bin/bash\nqvm-device block attach --ro -o devtype=cdrom "$VM" holder:loop0\n' > "$D/mgmt/harness/bad.sh"
expect_fires L12-provisioning-recipe "$D" "a LIVE cdrom attach (qubesd refuses it)"

D="$TMP/l12ok"; mk "$D"
printf '#!/bin/bash\nqvm-device block assign --required -o frontend-dev=xvdi -o devtype=disk "$VM" holder:loop0\n' > "$D/mgmt/harness/good.sh"
expect_silent L12-provisioning-recipe "$D" "the recipe shape: assign --required"

# ---------------------------------------------------------------- L17 process killed or adopted by NAME (owner 2026-10-03, ADR-updater 12.4)
# One fixture per shape, each planted alone. No packaging/make-setup.ps1 in these fixtures, so every guest/*.ps1 counts as shipped.
D="$TMP/l17a"; mk "$D"; printf 'Stop-Process -Name foo -Force -EA SilentlyContinue\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "Stop-Process -Name"
D="$TMP/l17b"; mk "$D"; printf 'Get-Process qubes-updates-relay -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "Get-Process <name> | Stop-Process (the old Ensure-Proxy respawn)"
D="$TMP/l17c"; mk "$D"; printf 'Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "Get-Process <name> | ForEach-Object { .Kill() } (the old Remove-Proxy)"
D="$TMP/l17d"; mk "$D"; printf '& taskkill.exe /F /IM foo.exe *>$null\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "taskkill /im"
D="$TMP/l17e"; mk "$D"; printf 'if (-not (Get-Process qubes-updates-relay -EA SilentlyContinue)) { Start-Relay }\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "existence by name decides whether to start our own (the old Ensure-Proxy adoption)"
D="$TMP/l17f"; mk "$D"
cat > "$D/guest/upd.ps1" <<'EOS'
foreach ($p in @(Get-Process qubes-updates-relay -EA SilentlyContinue)) {
    $rp = $p
    try { $rp.Kill() } catch { }
}
EOS
expect_fires L17-process-by-name "$D" "a variable bound by a by-name lookup, aliased, then .Kill()ed (the old dead-pass cleanup)"
D="$TMP/l17g"; mk "$D"; printf '$script:Relay = Get-Process qubes-updates-relay -EA SilentlyContinue\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "a by-name lookup retained as script state (adoption)"
D="$TMP/l17h"; mk "$D"
cat > "$D/guest/upd.ps1" <<'EOS'
$running = @(Get-Process qubes-updates-relay -EA SilentlyContinue)
if ($running.Count -eq 0) {
    Log 'starting'
    Start-Process foo.exe
}
EOS
expect_fires L17-process-by-name "$D" "a by-name count gating a start across lines (adoption)"
D="$TMP/l17i"; mk "$D"; printf 'Get-WmiObject Win32_Process -Filter "Name = ''foo.exe''" | ForEach-Object { $_.Terminate() }\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "a Win32_Process selected by Name and Terminate'd"
# ...and the shapes that are neither kill nor adopt: counting, waiting, by handle, by id, a start gated on something else
D="$TMP/l17ok"; mk "$D"
cat > "$D/guest/upd.ps1" <<'EOS'
$ti = @(Get-Process TiWorker, TrustedInstaller -EA SilentlyContinue).Count
while ((Get-Date) -lt $q) {
  $tiw = @(Get-Process TiWorker -EA SilentlyContinue)
  if ($tiw.Count -eq 0) { break }
  try { [void]$tiw[0].WaitForExit($ms) } catch { Start-Sleep -Seconds 10 }
}
$me = Get-Process -Id $PID -EA SilentlyContinue
$p = Start-Process -FilePath $exe -ArgumentList '--listen' -PassThru
$script:OwnRelay = $p
$p.Kill(); [void]$p.WaitForExit(10000)
Stop-Process -Id $ownerPid -Force
if (-not (Test-RelayListening)) { Start-Relay }
# a comment naming Get-Process foo | Stop-Process must not fire
EOS
expect_silent L17-process-by-name "$D" "counting and waiting on a by-name process, kill by handle, kill by id, a start gated on a probe, a comment"
# SCOPE: with a packaging/make-setup.ps1 present, EVERY script it ships is linted (widened 2026-10-03 from the updater payload
# alone): each single Copy-Item of a guest script, every foreach list (resolved against guest/ and packaging/setup/), all of
# packaging/setup/*.ps1, the core-agent rpc-services dir, the overlay installer. A guest script make-setup does not copy is
# not shipped and stays silent. One planted kill per covered file, each asserted BY FILE in the lint's output.
expect_fires_in(){ # <lint-id> <fixture-dir> <path-substring> <what was planted>
  local id="$1" dir="$2" path="$3" what="$4"
  local out; out=$(python3 "$LINT" --root "$dir" --quiet 2>&1)
  if echo "$out" | grep -q "^$id" && echo "$out" | grep -qF "$path"; then
    ok "$id fires in $path: $what"
  else
    no "$id did NOT fire in $path: $what  <-- a shipped file the lint does not cover"
  fi
}
D="$TMP/l17scope"; mk "$D"; mkdir -p "$D/packaging/setup" "$D/packaging/payload" "$D/core-agent/src/qubes-rpc-services"
cat > "$D/packaging/make-setup.ps1" <<'EOS'
foreach ($f in 'install.cmd', 'Install-QwtImproved.ps1', 'README.txt') {
    Copy-Item (Join-Path $setupSrc $f) $OutDir -Force
}
Copy-Item (Need (Join-Path $RepoRoot 'guest\single.ps1') 'a single-copy guest script') $OutDir -Force
foreach ($u in 'shipped.ps1', 'qubes-windows-update.ps1',
               'other.ps1') {
    Copy-Item (Need (Join-Path $RepoRoot "guest\$u") "updater agent payload ($u)") $OutDir -Force
}
foreach ($f in @(Get-ChildItem -LiteralPath $rpcSrcDir -File)) {
    Copy-Item $f.FullName $rpcSvcOut -Force
}
EOS
printf 'Stop-Process -Name foo -Force\n' > "$D/guest/unshipped.ps1"
printf 'Write-Host ok\n' > "$D/guest/shipped.ps1"
printf 'Write-Host ok\n' > "$D/guest/single.ps1"
printf 'Write-Host ok\n' > "$D/packaging/setup/Install-QwtImproved.ps1"
printf 'Write-Host ok\n' > "$D/packaging/payload/install-qwt-improved.ps1"
printf 'Write-Host ok\n' > "$D/core-agent/src/qubes-rpc-services/handler.ps1"
# WIDENED 2026-10-07 (owner: "why did you miss kill-by-name during the previous sweep?"): a guest script make-setup does
# NOT ship is still ours and is linted - until then this exact case asserted SILENCE, which is how every dev script kept
# its by-name kills through the 2026-10-03 sweep.
expect_fires_in L17-process-by-name "$D" "guest/unshipped.ps1" "a by-name kill in a guest script make-setup does not ship (every script of ours is linted now)"
printf 'Write-Host ok\n' > "$D/guest/unshipped.ps1"
printf 'Stop-Process -Name foo -Force\n' > "$D/guest/shipped.ps1"
expect_fires_in L17-process-by-name "$D" "guest/shipped.ps1" "a kill in a foreach-listed guest script (the updater payload)"
printf 'Write-Host ok\n' > "$D/guest/shipped.ps1"
printf 'Get-Process OneDrive -EA SilentlyContinue | Stop-Process -Force\n' > "$D/guest/single.ps1"
expect_fires_in L17-process-by-name "$D" "guest/single.ps1" "a kill in a single-Copy-Item guest script (quiet-desktop's shape)"
printf 'Write-Host ok\n' > "$D/guest/single.ps1"
cat > "$D/packaging/setup/Install-QwtImproved.ps1" <<'EOS'
foreach ($pr in @(Get-Process -Name 'gui-agent' -ErrorAction SilentlyContinue)) {
    try { $pr.Kill(); [void]$pr.WaitForExit(5000) } catch { }
}
EOS
expect_fires_in L17-process-by-name "$D" "packaging/setup/Install-QwtImproved.ps1" "the setup installer's old quiesce kill loop"
printf 'Write-Host ok\n' > "$D/packaging/setup/Install-QwtImproved.ps1"
printf 'Get-Process -Name $AGENTPROC -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue\n' > "$D/packaging/payload/install-qwt-improved.ps1"
expect_fires_in L17-process-by-name "$D" "packaging/payload/install-qwt-improved.ps1" "the overlay installer's old by-name kill"
printf 'Write-Host ok\n' > "$D/packaging/payload/install-qwt-improved.ps1"
printf '& taskkill.exe /F /IM foo.exe\n' > "$D/core-agent/src/qubes-rpc-services/handler.ps1"
expect_fires_in L17-process-by-name "$D" "core-agent/src/qubes-rpc-services/handler.ps1" "a taskkill /im in a core-agent rpc handler"
printf 'Write-Host ok\n' > "$D/core-agent/src/qubes-rpc-services/handler.ps1"
expect_silent L17-process-by-name "$D" "the widened scope with every shipped file clean (the fixed shapes: counting, waiting, -Id)"
# ...and the 2026-10-07 widening to ALL our code: bash harnesses (the taskkill they run and the PowerShell they embed),
# tools/ scripts, python tools. The correct shape - a control process stopped by the id the harness recorded when it
# started it (lifecycle-lib.sh ctl_start/ctl_stop) - stays silent.
D="$TMP/l17w1"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
q run 'cmd /c taskkill /f /im notepad.exe 2>nul & exit 0' >/dev/null 2>&1
EOS
expect_fires_in L17-process-by-name "$D" "mgmt/harness/bad.sh" "a taskkill /im a bash harness runs on the guest"
D="$TMP/l17w2"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
psrun "Stop-Service QubesGuiWatchdog -Force -EA SilentlyContinue; Start-Sleep 3
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force; Start-Sleep 2"
EOS
expect_fires_in L17-process-by-name "$D" "mgmt/harness/bad.sh" "a by-name kill inside the PowerShell a bash harness sends"
D="$TMP/l17w3"; mk "$D"; mkdir -p "$D/tools/viewcheck"
printf 'Get-Process notepad -EA SilentlyContinue | Stop-Process -Force\n' > "$D/tools/viewcheck/t.ps1"
expect_fires_in L17-process-by-name "$D" "tools/viewcheck/t.ps1" "a by-name kill in a tools/ script"
D="$TMP/l17w4"; mk "$D"; mkdir -p "$D/tools"
printf 'cmd = ["tools/qtest", "run", "cmd /c taskkill /f /im notepad.exe"]\n' > "$D/tools/judge.py"
expect_fires_in L17-process-by-name "$D" "tools/judge.py" "a taskkill /im inside a python tool"
D="$TMP/l17wok"; mk "$D"
cat > "$D/mgmt/harness/good.sh" <<'EOS'
#!/bin/bash
read -r _ pid start <<< "$(ctl_start notepad)"
left=$(r 'cmd /c tasklist /nh /fo csv /fi "imagename eq notepad.exe"' | grep -aci '^"notepad\.exe"')
_lc_ps "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue"
EOS
expect_silent L17-process-by-name "$D" "a harness stopping the control it started by the id it recorded, and a read-only tasklist count"

# ---------------------------------------------------------------- L18 a relauncher's child ended while the relauncher is armed (owner 2026-10-07)
# One fixture per shape, each planted alone, each the literal line a harness or dev script carried before the fix.
D="$TMP/l18a"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
psrun "Stop-Service QubesGuiWatchdog -Force -EA SilentlyContinue; Start-Sleep 3
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force; Start-Sleep 2
Start-Service QubesGuiWatchdog"
EOS
expect_fires L18-relauncher-armed "$D" "the old harness restart: service stopped, then gui-agent killed by name anyway (the race this rule exists for)"
D="$TMP/l18b"; mk "$D"; printf '& taskkill.exe /F /IM gui-agent.exe *>$null\n' > "$D/guest/x.ps1"
expect_fires L18-relauncher-armed "$D" "taskkill /im gui-agent.exe"
D="$TMP/l18c"; mk "$D"
cat > "$D/guest/x.ps1" <<'EOS'
$old = @(Get-Process gui-agent -EA SilentlyContinue)
Start-Sleep 1
foreach ($a in $old) { $a.Kill() }
EOS
expect_fires L18-relauncher-armed "$D" "gui-agent found by name, held in a variable, ended later by that handle"
D="$TMP/l18d"; mk "$D"; printf 'Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }\n' > "$D/guest/x.ps1"
expect_fires L18-relauncher-armed "$D" "the updates relay ended by name (a pass's task relaunches it)"
D="$TMP/l18e"; mk "$D"; printf 'Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue\n' > "$D/guest/x.ps1"
expect_fires L18-relauncher-armed "$D" "explorer ended by name (Winlogon AutoRestartShell relaunches it)"
D="$TMP/l18f"; mk "$D"; printf 'Get-Process ShellExperienceHost -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue\n' > "$D/guest/x.ps1"
expect_fires L18-relauncher-armed "$D" "ShellExperienceHost ended by name (the shell relaunches it)"
D="$TMP/l18g"; mk "$D"; printf 'Get-Process notifhost | Stop-Process -Force\n' > "$D/guest/x.ps1"
expect_fires L18-relauncher-armed "$D" "notifhost ended by name (gui-agent relaunches it)"
D="$TMP/l18h"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
enc_run 'tasklist /nh /fo csv /fi "imagename eq etwproxy.exe"' | tr -d '\r' > "$OUT/t5-tasklist.csv"
ppid=$(awk -F'","' '/[Ee]twproxy\.exe/ {gsub(/"/,"",$2); print $2}' "$OUT/t5-tasklist.csv" | head -1)
qrun "taskkill /f /pid $ppid" >/dev/null 2>&1
EOS
expect_fires L18-relauncher-armed "$D" "a pid SELECTED by a tasklist imagename scan for etwproxy, then taskkill /pid (by name in two steps; the old p3a drill)"
D="$TMP/l18i"; mk "$D"
cat > "$D/guest/x.ps1" <<'EOS'
$xml = @"
<Task><Settings><RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings></Task>
"@
& schtasks /create /tn QwtRestarting /xml "$f" /f
& schtasks /end /tn QwtRestarting
EOS
expect_fires L18-relauncher-armed "$D" "schtasks /end on a task whose definition carries RestartOnFailure, with no disable first"
D="$TMP/l18iok"; mk "$D"
cat > "$D/guest/x.ps1" <<'EOS'
$xml = @"
<Task><Settings><RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings></Task>
"@
& schtasks /create /tn QwtRestarting /xml "$f" /f
& schtasks /change /tn QwtRestarting /disable
& schtasks /end /tn QwtRestarting
& schtasks /end /tn QwtPlain
EOS
expect_silent L18-relauncher-armed "$D" "schtasks /end after the task was disabled, and /end on a task with no restart policy"
# ...and the correct shapes: the service restart with a wait on the old agent's HANDLE, a by-id stop of the shell window's
# owner, a relay stopped by the handle its starter kept, a drill's taskkill /pid of the pid the AGENT logged (no name scan),
# a by-name COUNT, a read-only tasklist, a comment.
D="$TMP/l18ok"; mk "$D"
cat > "$D/guest/restart.ps1" <<'EOS'
$oldPid = 4242
$oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
Stop-Service -Name QubesGuiWatchdog -Force -ErrorAction Stop
[void]$oldProc.WaitForExit(45000)
Start-Service -Name QubesGuiWatchdog
$np = Get-Process -Id 5151 -ErrorAction SilentlyContinue
$count = @(Get-Process gui-agent -ErrorAction SilentlyContinue).Count
Stop-Process -Id $shellPid -Force -ErrorAction SilentlyContinue
$relay = Start-Process -FilePath $exe -ArgumentList '--listen','8082' -PassThru
$relay.Kill()
# a comment: Get-Process gui-agent | Stop-Process must not fire
EOS
cat > "$D/mgmt/harness/good.sh" <<'EOS'
#!/bin/bash
pp=$(proxy_owned_pid); ppid=$(printf '%s' "$pp" | awk '{print $2}')
qrun "taskkill /f /pid $ppid" >/dev/null 2>&1
alive=$(r 'cmd /c tasklist /fi "imagename eq gui-agent.exe" /nh' | grep -ac 'gui-agent\.exe')
EOS
expect_silent L18-relauncher-armed "$D" "the service restart waiting on the old agent's handle, a by-id shell stop, a relay stopped by its own handle, a drill kill by the agent-logged pid, a count, a read, a comment"

echo "  ---- $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
