#!/bin/bash
# pvnic-netsetup-verdict-selftest.sh - prove the QwtngNetSetup service's two verdicts, offline.
#
# WHY. guest/pvnic-selfprime.ps1 embeds a C# service (compiled ON THE GUEST by the .NET Framework
# csc, i.e. C# 5) that puts the qubesdb L3 config on the PV NIC at every boot. Audit 2026-09-16:
#   #10 Netsh() never read netsh's exit code (nor WaitForExit's result), and Apply() wrote the STAMP
#       and logged 'applied' regardless - a failed or hung netsh looked exactly like a successful one.
#   #11 Work() decided 'no netvm' from ONE cold qdb_read of /qubes-ip right after qdb_open; the
#       payload half retries with a vif cross-check, the service half did not.
# Both are exercised here without a guest: the class is compiled by the Roslyn pwsh ships, parsed at
# LanguageVersion C# 5 (what the guest's csc accepts - a newer construct would otherwise fail only on
# the guest, at boot), loaded, and its private statics invoked by reflection:
#   - Apply() against THIS HOST's real primary interface, with a fake netsh.exe on PATH that records
#     its arguments and fails/hangs on request. The read-back is the same NetworkInterface API on
#     both OSes, so a verified state and an unverifiable one are real, not mocked;
#   - WaitForNetvmKeys() with scripted qubesdb reads and vif probes.
# NOT covered (guest-only, UNVERIFIED-OFFLINE): qubesdb-client.dll, cfgmgr32's present-device list,
# the SCM, and the behaviour of the real netsh.
#
# EXTRACTION IS BY MARKER (NETSETUP-CS-BEGIN/END), never by sed-to-closing-brace.
#
# Knobs, each re-introducing one audited defect; the test must then FAIL on the named case:
#   NETSETUP_DEFECT=NOVERIFY - Apply() stamps without the read-back (#10 as shipped)
#                              -> 'wrong address must not stamp' must FAIL
#   NETSETUP_DEFECT=NORC     - netsh's exit code is not read (#10 as shipped)
#                              -> the failure marker no longer carries 'rc=1' -> must FAIL
#   NETSETUP_DEFECT=COLDREAD - no vif cross-check, an empty first read means 'no netvm' (#11 as shipped)
#                              -> 'keys published on the 3rd read' must FAIL
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

PWSH=${PWSH:-/home/user/bin/pwsh7/pwsh}
[ -x "$PWSH" ] || PWSH=$(command -v pwsh) || { echo "FATAL: no pwsh"; exit 2; }
SRC=guest/pvnic-selfprime.ps1
T=$(mktemp -d "${TMPDIR:-/tmp}/netsetuptest.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/work"

grep -q 'NETSETUP-CS-BEGIN' "$SRC" && grep -q 'NETSETUP-CS-END' "$SRC" \
  || { echo "FATAL: NETSETUP-CS-BEGIN/END markers missing from $SRC - cannot extract the service source"; exit 2; }
awk '/NETSETUP-CS-BEGIN/{f=1;next} /NETSETUP-CS-END/{f=0} f' "$SRC" > "$T/svc.cs"
grep -q '^using System;' "$T/svc.cs" || { echo "FATAL: extracted block does not start with the service's using lines"; exit 2; }

# Each knob is a one-line rewrite of the extracted source; a knob that did not land would make the
# 'defect' run pass for the wrong reason, so each is checked after the sed.
case "${NETSETUP_DEFECT:-}" in
  NOVERIFY)
    sed -i 's/if (!VerifyApplied(ifname, ip, gw, verifyDeadlineMs, out why)) {/why = null; if (false) {/' "$T/svc.cs"
    grep -q 'why = null; if (false) {' "$T/svc.cs" || { echo "FATAL: NOVERIFY knob did not apply"; exit 2; } ;;
  NORC)
    sed -i 's/rc = pr.ExitCode;/rc = 0;/' "$T/svc.cs"
    grep -q 'rc = 0;' "$T/svc.cs" || { echo "FATAL: NORC knob did not apply"; exit 2; } ;;
  COLDREAD)
    sed -i 's/int v = vif();/int v = 0;/' "$T/svc.cs"
    grep -q 'int v = 0;' "$T/svc.cs" || { echo "FATAL: COLDREAD knob did not apply"; exit 2; } ;;
  '') ;;
  *) echo "FATAL: unknown NETSETUP_DEFECT '$NETSETUP_DEFECT'"; exit 2 ;;
esac

# The host's primary interface is the read-back subject. MISSING DATA FAILS: with no default route
# the positive case cannot be exercised and the run is INVALID, not a pass.
IFN=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
GW=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -1)
IP=$(ip -4 -o addr show dev "${IFN:-none}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
[ -n "$IFN" ] && [ -n "$GW" ] && [ -n "$IP" ] \
  || { echo "INVALID: this host has no IPv4 default route/address (if='$IFN' ip='$IP' gw='$GW') - the read-back cannot be exercised"; exit 2; }

# Fake netsh.exe: records argv, and on request fails (exit 1 with a reason on stdout, as netsh does)
# or hangs (exec sleep, so the service's kill lands on the process holding the pipe).
cat > "$T/bin/netsh.exe" <<'EOF'
#!/bin/bash
echo "$*" >> "${FAKE_NETSH_LOG:?}"
if [ -n "${FAKE_NETSH_HANG:-}" ] && [[ "$*" == *"$FAKE_NETSH_HANG"* ]]; then exec sleep 5; fi
if [ -n "${FAKE_NETSH_FAIL:-}" ] && [[ "$*" == *"$FAKE_NETSH_FAIL"* ]]; then echo "Fake: route refused."; exit 1; fi
echo "Ok."
exit 0
EOF
chmod +x "$T/bin/netsh.exe"
export FAKE_NETSH_LOG="$T/work/netsh.calls"

cat > "$T/run.ps1" <<'PS'
param([string]$Cs, [string]$Work, [string]$IfName, [string]$Ip, [string]$Gw)
$ErrorActionPreference = 'Stop'
# The service's C:\ProgramData\... constants are plain relative names to the .NET file APIs on Linux
# (backslashes and all) - and pwsh's own providers would read 'C:' as a drive, so every file the
# service writes is read here through the same .NET APIs, in the same process cwd.
Set-Location $Work; [Environment]::CurrentDirectory = $Work
$pw = Split-Path -Parent (Get-Process -Id $PID).Path
Add-Type -AssemblyName Microsoft.CodeAnalysis
Add-Type -AssemblyName Microsoft.CodeAnalysis.CSharp
$refNames = @('System.Private.CoreLib', 'System.Runtime', 'netstandard', 'System.Collections',
              'System.ServiceProcess.ServiceController', 'System.Diagnostics.EventLog', 'Microsoft.Win32.Registry',
              'System.Net.NetworkInformation', 'System.Diagnostics.Process', 'System.ComponentModel.Primitives',
              'System.Runtime.InteropServices', 'System.Threading', 'System.Threading.ThreadPool', 'System.IO.FileSystem',
              'System.Net.Primitives', 'System.Threading.Thread', 'System.Runtime.Extensions')
$refs = foreach ($n in $refNames) {
    $p = Join-Path $pw ($n + '.dll')
    if (-not (Test-Path $p)) { Write-Host "FATAL: reference assembly missing: $p"; exit 2 }
    [Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($p)
}
# C# 5: the guest compiles this with the .NET Framework csc (C:\Windows\Microsoft.NET\Framework64\v4.0.30319).
$parse = [Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::new([Microsoft.CodeAnalysis.CSharp.LanguageVersion]::CSharp5)
$tree = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText((Get-Content -Raw -LiteralPath $Cs), $parse)
$opts = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
$comp = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('qwtng-netsetup-test', [Microsoft.CodeAnalysis.SyntaxTree[]]@($tree), [Microsoft.CodeAnalysis.MetadataReference[]]$refs, $opts)
$ms = [IO.MemoryStream]::new()
$res = $comp.Emit($ms)
$errs = @($res.Diagnostics | Where-Object { $_.Severity -eq 'Error' })
if ($errs.Count) {
    foreach ($e in $errs | Select-Object -First 10) { Write-Host ("ERR line {0}: {1}" -f ($e.Location.GetLineSpan().StartLinePosition.Line + 1), $e.GetMessage()) }
    Write-Host "FAIL  compile at C# 5: $($errs.Count) error(s) - this source would fail on the guest's csc"; exit 1
}
Write-Host "PASS  compile at C# 5 ($($ms.Length) bytes)"
$asm = [System.Reflection.Assembly]::Load($ms.ToArray())
$t = $asm.GetType('QwtngNetSetup')
$B = [System.Reflection.BindingFlags]'NonPublic,Static'
# Short deadlines for the test: the guest values are 10 s (verify) and 20 s (netsh).
$t.GetField('verifyDeadlineMs', $B).SetValue($null, 1500)
$t.GetField('netshTimeoutMs', $B).SetValue($null, 800)
$STAMP = 'C:\ProgramData\QubesNetSetup.applied'; $MARK = 'C:\ProgramData\QubesNetSetup-FAILED.txt'; $LOG = 'C:\ProgramData\QubesNetSetup.log'
$NETSHLOG = $env:FAKE_NETSH_LOG
function FileExists([string]$f) { [IO.File]::Exists($f) }
function FileText([string]$f) { if ([IO.File]::Exists($f)) { [IO.File]::ReadAllText($f) } else { '' } }
function Lines([string]$f) { if ([IO.File]::Exists($f)) { @([IO.File]::ReadAllLines($f)).Count } else { 0 } }
function Reset {
    foreach ($f in @($STAMP, $MARK, $LOG, $NETSHLOG)) { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } }
    $env:FAKE_NETSH_FAIL = ''; $env:FAKE_NETSH_HANG = ''
}
function Apply($ifn, $ip, $mask, $gw, $tag) { [bool]$t.GetMethod('Apply', $B).Invoke($null, [object[]]@($ifn, $ip, $mask, $gw, $null, $null, $tag)) }
# The fake qubesdb read must return a REAL null for an absent key, as the service's Rd() does. A
# scriptblock converted to Func<string,string> turns $null into "" (measured: len=0, not null), so
# the fakes below return [NullString]::Value, which does come through as null.
function Keys([scriptblock]$rd, [scriptblock]$vif, [int]$deadline, [int]$step) {
    $t.GetMethod('WaitForNetvmKeys', $B).Invoke($null, [object[]]@([Func[string, string]]$rd, [Func[int]]$vif, $deadline, $step))
}
$pass = 0; $fail = 0
function Check([string]$label, [bool]$cond, [string]$detail) {
    if ($cond) { $script:pass++; Write-Host "PASS  $label" } else { $script:fail++; Write-Host "FAIL  $label -> $detail" }
}
$WRONG = '10.255.255.254'

# ---------------- #10 Apply(): the STAMP follows the read-back, netsh's verdict is evidence ----------------
Reset
$r = Apply $IfName $Ip '255.255.255.255' $Gw 'tag-ok'
Check 'apply: host address+gateway verify -> true, STAMP=tag, no marker' ($r -and (FileText $STAMP) -eq 'tag-ok' -and -not (FileExists $MARK) -and ((FileText $LOG) -match 'verified on the adapter')) "r=$r stamp=[$(FileText $STAMP)] mark=$(FileExists $MARK) log=[$(FileText $LOG)]"
Check 'apply: exactly the address and route netsh calls were issued (no DNS given)' ((Lines $NETSHLOG) -eq 2 -and (FileText $NETSHLOG) -match "set address name=$IfName static $Ip 255.255.255.255" -and (FileText $NETSHLOG) -match "nexthop=$Gw") "calls=[$(FileText $NETSHLOG)]"

Reset
$r = Apply $IfName $WRONG '255.255.255.255' $Gw 'tag-wrong'
Check 'apply: WRONG address must NOT stamp and must be Loud with the read-back evidence' ((-not $r) -and -not (FileExists $STAMP) -and ((FileText $MARK) -match 'NOT verified' -and (FileText $MARK) -match "wanted $WRONG via $Gw" -and (FileText $MARK) -match 'every netsh call returned 0')) "r=$r stamp=$(FileExists $STAMP) mark=[$(FileText $MARK)]"

Reset
[IO.File]::WriteAllText($STAMP, 'stale-from-earlier')
$r = Apply $IfName $WRONG '255.255.255.255' $Gw 'tag-wrong'
Check 'apply: a failed apply clears a stale STAMP' ((-not $r) -and -not (FileExists $STAMP)) "r=$r stamp=[$(FileText $STAMP)]"

Reset
$env:FAKE_NETSH_FAIL = 'add route'
$r = Apply $IfName $WRONG '255.255.255.255' $Gw 'tag-rc'
Check 'apply: refused route (rc=1) + unverifiable state -> marker carries rc=1 and netsh''s own words' ((-not $r) -and (FileText $MARK) -match 'add route prefix=0.0.0.0/0 [^;]*rc=1 \[Fake: route refused\.\]') "r=$r mark=[$(FileText $MARK)]"

Reset
$env:FAKE_NETSH_HANG = 'set address'
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Apply $IfName $WRONG '255.255.255.255' $Gw 'tag-hang'
$sw.Stop()
Check 'apply: a HUNG netsh is killed at the timeout and reported rc=-2, not waited on forever' ((-not $r) -and (FileText $MARK) -match 'set address [^;]*rc=-2' -and $sw.ElapsedMilliseconds -lt 4500) "r=$r elapsed=$($sw.ElapsedMilliseconds)ms mark=[$(FileText $MARK)]"

Reset
$env:FAKE_NETSH_FAIL = 'add route'
$r = Apply $IfName $Ip '255.255.255.255' $Gw 'tag-despite'
Check 'apply: netsh rc=1 but the state verifies -> stamped, and the rc is on the applied line' ($r -and (FileText $STAMP) -eq 'tag-despite' -and (FileText $LOG) -match 'verified on the adapter despite: netsh [^\r\n]*rc=1') "r=$r stamp=[$(FileText $STAMP)] log=[$(FileText $LOG)]"

# ---------------- #11 WaitForNetvmKeys(): 'no netvm' only from the vif cross-check, bounded, loud ----------------
Reset
$full = @{ '/qubes-ip' = '10.137.0.9'; '/qubes-netmask' = '255.255.255.255'; '/qubes-gateway' = '10.138.21.72'; '/qubes-primary-dns' = '10.139.1.1'; '/qubes-secondary-dns' = '10.139.1.2' }
$k = Keys { param($p) $full[$p] } { 1 } 2000 50
Check 'keys: all present on the first read -> keys' ($k.verdict -eq 'keys' -and $k.ip -eq '10.137.0.9' -and $k.gw -eq '10.138.21.72' -and $k.d2 -eq '10.139.1.2') "verdict=$($k.verdict) why=[$($k.why)]"

$sw = [Diagnostics.Stopwatch]::StartNew()
$k = Keys { param($p) [NullString]::Value } { 0 } 2000 50
$sw.Stop()
Check 'keys: nothing published and NO present vif -> no-netvm at once, not after the deadline' ($k.verdict -eq 'no-netvm' -and $sw.ElapsedMilliseconds -lt 1000) "verdict=$($k.verdict) elapsed=$($sw.ElapsedMilliseconds)ms"

$script:n = 0
$k = Keys { param($p) if ($p -eq '/qubes-ip') { $script:n++; if ($script:n -le 2) { return [NullString]::Value } }; $full[$p] } { 1 } 3000 50
Check 'keys: vif present, /qubes-ip appears on the 3rd read -> keys (not a cold no-netvm)' ($k.verdict -eq 'keys' -and $k.ip -eq '10.137.0.9' -and $k.why -match '3 reads') "verdict=$($k.verdict) why=[$($k.why)] reads=$script:n"

$sw = [Diagnostics.Stopwatch]::StartNew()
$k = Keys { param($p) [NullString]::Value } { 1 } 400 50
$sw.Stop()
Check 'keys: vif present, never published -> exhausted at the deadline, says so' ($k.verdict -eq 'exhausted' -and $k.why -match 'vif present for 400 ms' -and $sw.ElapsedMilliseconds -ge 400 -and $sw.ElapsedMilliseconds -lt 2000) "verdict=$($k.verdict) why=[$($k.why)] elapsed=$($sw.ElapsedMilliseconds)ms"

$k = Keys { param($p) [NullString]::Value } { -1 } 400 50
Check 'keys: the vif probe itself FAILS -> never read as no-netvm; exhausted, naming the probe' ($k.verdict -eq 'exhausted' -and $k.why -match 'vif probe FAILED') "verdict=$($k.verdict) why=[$($k.why)]"

$k = Keys { param($p) if ($p -eq '/qubes-gateway') { [NullString]::Value } else { $full[$p] } } { 1 } 400 50
Check 'keys: ip+mask without a gateway is not a config -> exhausted, not keys' ($k.verdict -eq 'exhausted') "verdict=$($k.verdict) why=[$($k.why)]"

Write-Host "=== pvnic netsetup verdict selftest: $pass passed, $fail failed ==="
exit $(if ($fail -eq 0) { 0 } else { 1 })
PS
PATH="$T/bin:$PATH" "$PWSH" -NoProfile -File "$T/run.ps1" -Cs "$T/svc.cs" -Work "$T/work" -IfName "$IFN" -Ip "$IP" -Gw "$GW"
