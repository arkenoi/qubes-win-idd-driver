# wu-firstboot-test.ps1 - replay the SHIPPED first-boot decision of guest/qubes-windows-update.ps1
# (GUARD:firstboot) offline. No rig, no guest.
#
# WHAT IS UNDER TEST. Measured 2026-09-21 on GWeck's environment: a guest carrying a freshly
# installed updater and never booted since cannot run a Windows Update search - it dies ~2 s in at
# 0x8024402C and reports nothing to dom0, and ONLY a restart cures it (restarting wuauserv, UsoSvc,
# DoSvc, BITS, cryptsvc and WaaSMedicSvc does not). The shipped guard refuses such a pass BEFORE
# raising the proxy and says a restart is required, instead of failing on an opaque WinHTTP error.
#
# The suite extracts the WU-FIRSTBOOT-DECIDE region from the shipped script and runs it in a CHILD
# pwsh per case, because the region ends in `exit 0` on the refusal path and that control flow is
# part of what must be right: a refusal that fell through would raise the proxy and search anyway.
#
# -Defect <knob> re-introduces a specific defect so the suite MUST fail on the check that knob
# targets. A guard never seen to fail is decoration.
param([string]$Defect = '', [string]$ScriptPath = '')

$ErrorActionPreference = 'Stop'
if ($ScriptPath) { $script = $ScriptPath }
else {
  $root   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  $script = Join-Path $root 'guest/qubes-windows-update.ps1'
}
if (-not (Test-Path $script)) { Write-Output "INSTRUMENT: $script not found"; exit 2 }
$src = Get-Content -Raw $script

function Region([string]$name) {
    $m = [regex]::Match($src, "# ---- $name-BEGIN(.*?)# ---- $name-END", 'Singleline')
    if (-not $m.Success) { Write-Output "INSTRUMENT: region $name not found in the shipped script"; exit 2 }
    return $m.Groups[1].Value
}
$region = Region 'WU-FIRSTBOOT-DECIDE'
# The exact shipped line the no-stamp knobs rewrite. Declared once, and PROVEN to be in the region:
# a knob whose pattern matches nothing silently reports the guard it targets as decoration.
$script:NoStampLine = "  Log 'first-boot gate INACTIVE: no install stamp on this guest (updater deployed before the stamp existed) - a pass in the install boot can still fail at 0x8024402C'"
if ($Defect -like 'nostamp*' -and -not $region.Contains($script:NoStampLine)) {
    Write-Output 'INSTRUMENT: the no-stamp line this knob rewrites is not in the shipped region'; exit 2
}

# Defect knobs rewrite the SHIPPED text back to a defective form. Literal .Replace, never -replace:
# '$' is a regex anchor AND a PowerShell interpolation, and a knob that matches nothing reports the
# guard as decoration (tools/tests/wu-notactionable-test.ps1 paid for that lesson).
switch ($Defect) {
    # no gate at all - the state before 2026-09-21, where the pass ran and died at 0x8024402C
    'nogate'    { $region = $region.Replace('$sameBoot = ([math]::Abs((($nowBoot - $ib)).TotalSeconds) -lt 120)', '$sameBoot = $false') }
    # exact equality instead of a tolerance: LastBootUpTime jitters by about a second between reads
    # on one boot, so the guard silently stops firing on the very case it exists for
    'equality'  { $region = $region.Replace('[math]::Abs((($nowBoot - $ib)).TotalSeconds) -lt 120', '($nowBoot -eq $ib)') }
    # a missing stamp treated as "must be the install boot": every guest whose updater predates the
    # stamp is refused forever, because it can never prove it booted
    'nostampblocks' { $region = $region.Replace($script:NoStampLine, '  $script:St.phase=''needs-restart''; Save; exit 0') }
    # the same guest proceeds, but the limitation is SILENT - nothing in the log says the gate did
    # not run, so a pass that later dies at 0x8024402C looks unexplained
    'nostampsilent' { $region = $region.Replace($script:NoStampLine, '  $null = 1') }
    # refuse, but do not ask for the restart: dom0 gets a pass with no reboot request, so nothing
    # ever cycles the guest and the refusal repeats forever
    'noreboot'  { $region = $region.Replace('$script:St.reboot_needed=$true', '$script:St.reboot_needed=$false') }
    # refuse silently: the marker line tools/wu-pass-judge.py keys on is gone, and a deliberate
    # decline becomes indistinguishable from a pass that died without telling dom0 anything
    'silent'    { $region = $region.Replace("Log ('RESTART REQUIRED before Windows Update can search: the updater agent was installed in THIS boot '", "Log ('' + ") }
    ''          { }
    default     { Write-Output "INSTRUMENT: unknown defect knob '$Defect'"; exit 2 }
}

$fails = 0; $checks = 0
function Check([string]$what, [bool]$ok) {
    $script:checks++
    if ($ok) { Write-Output "  ok   $what" } else { Write-Output "  FAIL $what"; $script:fails++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wufb-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  # Run ONE case in a child pwsh: $instBoot / $nowBoot are supplied as the reads would have, the
  # region decides, and we read back what it logged, what it saved, and whether it exited.
  function Run-Case([string]$instBoot, [string]$nowBoot, [string]$knob) {
      $harness = @()
      $harness += 'function Log($m,$lvl){ Write-Output ("LOG " + $m) }'
      $harness += '$script:St = [ordered]@{ phase="init"; reboot_needed=$false; error=$null }'
      $harness += 'function Save(){ Write-Output ("SAVE phase=" + $script:St.phase + " reboot=" + $script:St.reboot_needed + " error=" + $script:St.error) }'
      if ($knob) { $harness += ('$env:QUBES_UPDATES_SKIP_FIRSTBOOT_GATE = "' + $knob + '"') }
      else       { $harness += '$env:QUBES_UPDATES_SKIP_FIRSTBOOT_GATE = $null' }
      $harness += if ($instBoot) { '$instBoot = "' + $instBoot + '"' } else { '$instBoot = $null' }
      $harness += if ($nowBoot)  { '$nowBoot = [datetime]::Parse("' + $nowBoot + '", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)' }
                  else           { '$nowBoot = $null' }
      $harness += $region
      # Reached ONLY if the region did not exit - i.e. the pass would go on to raise the proxy.
      $harness += 'Write-Output ("PROCEEDED gate=" + $script:FirstBootGate)'
      $f = Join-Path $tmp ("case-" + [guid]::NewGuid().ToString('N') + ".ps1")
      Set-Content -LiteralPath $f -Value ($harness -join "`n") -Encoding UTF8
      $out = & (Get-Process -Id $PID).Path -NoProfile -File $f 2>&1
      return ($out | Out-String)
  }

  $boot = '2026-09-21T09:00:00.0000000Z'
  # Same boot, one second of jitter between the stamp and the live read - the real shape.
  Write-Output 'CASE same boot (updater installed in THIS boot)'
  $o = Run-Case $boot '2026-09-21T09:00:01.0000000Z' ''
  Check 'refuses the pass (never reaches the proxy)'           (-not ($o -match 'PROCEEDED'))
  Check 'says RESTART REQUIRED, in the words the judge keys on' ($o -match 'RESTART REQUIRED before Windows Update can search')
  Check 'phase is needs-restart'                                ($o -match 'SAVE phase=needs-restart')
  Check 'asks for the restart (reboot_needed=True)'             ($o -match 'SAVE phase=needs-restart reboot=True')
  Check 'states the reason in the status file'                  ($o -match 'error=a restart is required before Windows Update can search')

  Write-Output 'CASE booted since the install (3 hours later)'
  $o = Run-Case $boot '2026-09-21T12:00:00.0000000Z' ''
  Check 'the pass proceeds'                    ($o -match 'PROCEEDED gate=inactive')
  Check 'and says the gate was evaluated OK'   ($o -match 'first-boot gate OK')
  Check 'no restart is demanded'               (-not ($o -match 'RESTART REQUIRED'))

  Write-Output 'CASE boundary - 119 s apart is ONE boot, 121 s apart is not'
  $o = Run-Case $boot '2026-09-21T09:01:59.0000000Z' ''
  Check '119 s: still the install boot, refused' (-not ($o -match 'PROCEEDED'))
  $o = Run-Case $boot '2026-09-21T09:02:01.0000000Z' ''
  Check '121 s: a later boot, proceeds'          ($o -match 'PROCEEDED')

  Write-Output 'CASE no stamp (updater predates the stamp)'
  $o = Run-Case '' '2026-09-21T09:00:01.0000000Z' ''
  Check 'proceeds rather than blocking a guest it cannot judge' ($o -match 'PROCEEDED')
  Check 'and SAYS the gate is inactive'                          ($o -match 'first-boot gate INACTIVE')

  Write-Output 'CASE boot time unreadable (the instrument failed, not the guest)'
  $o = Run-Case $boot '' ''
  Check 'proceeds'                       ($o -match 'PROCEEDED gate=unmeasured')
  Check 'and says it could not evaluate' ($o -match 'COULD NOT BE EVALUATED')

  Write-Output 'CASE stamp is not a round-trip timestamp'
  $o = Run-Case '21.09.2026 09:00:00' '2026-09-21T09:00:01.0000000Z' ''
  Check 'proceeds'                       ($o -match 'PROCEEDED gate=unmeasured')
  Check 'and names the unparseable stamp' ($o -match 'is not a round-trip timestamp')

  Write-Output 'CASE diagnostic knob disables the gate'
  $o = Run-Case $boot '2026-09-21T09:00:01.0000000Z' '1'
  Check 'the same-boot case proceeds when the knob is set' ($o -match 'PROCEEDED')
  Check 'and the knob says so out loud'                    ($o -match 'SKIP_FIRSTBOOT_GATE=1')
} finally {
  Remove-Item -Recurse -Force $tmp -EA SilentlyContinue
}

Write-Output ''
if ($fails -eq 0) { Write-Output "PASS  $checks checks"; exit 0 }
Write-Output "FAIL  $fails of $checks checks"; exit 1
