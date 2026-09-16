<#
.SYNOPSIS
    Offline suite for the relay's service-PID map (guest/qubes-updates-relay.cs, ServicePidMap) -
    the peer-allowlist decision that denied Windows Update's own svchost at the start of a pass
    (GWeck #146/#153, reproduced 2026-09-16 on win11-gwt). Runs under pwsh on Linux; no rig, no
    guest, no service control manager - the SCM enumerator is the one hook the suite replaces.

.DESCRIPTION
    Compiles the SHIPPED source file as-is with Add-Type (never an extracted copy of a function),
    constructs Relay+ServicePidMap with a scripted SCM, and replays the field failure under de-DE
    culture with a policy service name that carries a space and an umlaut:
      culture     de-DE is LIVE for the run (measured: (1.5).ToString() -> "1,5"), not merely named
      c#5         the file still parses as C# 5 - the guest compiles it with the pre-Roslyn in-box csc
      stale miss  the map is built while wuauserv is Stopped (for the agent's own CTL fetches);
                  wuauserv starts afterwards and dials 3.7 s later, inside the 5 s TTL -> ADMITTED,
                  at the cost of exactly one more SCM round
      hit         a hit inside the TTL is served from the map (no SCM round); past the TTL it is
                  re-checked and a stopped service is no longer admitted
      unicode     a policy service named "Müller Update Dienst" reaches the enumerator untouched and
                  its host is admitted under exactly that name (codepoints compared, no culture)
      misses      a non-service caller re-enumerates on every miss and is never admitted
      failure     an enumerator exception propagates (fail closed) and does not poison the map;
                  a null map counts as empty
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces the original bug in a temp copy (the shipped file is never modified):
      stalemiss   the `// GUARD:svcmap-miss` line becomes the pre-2026-09-16 rule - a miss inside
                  the TTL is answered from the stale map; the stale-miss check must FAIL
    tools/tests/relay-svcmap-selftest.sh runs the clean leg and the knob and requires each outcome.
#>
[CmdletBinding()]
param([string]$SourcePath, [string]$Defect = '')

$ErrorActionPreference = 'Stop'

if (-not $SourcePath) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
    $SourcePath = Join-Path $repoRoot 'guest/qubes-updates-relay.cs'
}
$SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path

$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host "$tag $name"
}
function Codepoints([string]$s) { return (([int[]][char[]]$s) -join ',') }

# --- the run is de-DE, and that is measured, not declared ------------------------------------------
$de = [cultureinfo]::GetCultureInfo('de-DE')
[cultureinfo]::CurrentCulture = $de
[cultureinfo]::CurrentUICulture = $de
Check 'culture: de-DE is live ((1.5).ToString() -> "1,5")' ((1.5).ToString() -eq '1,5' -and [cultureinfo]::CurrentCulture.Name -eq 'de-DE')

# --- the shipped file: marker present once, and still C# 5 --------------------------------------------
$lines = @(Get-Content -LiteralPath $SourcePath)
$guards = @($lines | Where-Object { $_ -match '// GUARD:svcmap-miss$' })
Check 'shipped: GUARD:svcmap-miss marker present exactly once' ($guards.Count -eq 1)
if ($guards.Count -ne 1) { Write-Host "FAIL cannot continue without the marker"; exit 1 }

# The guest compiles this file with the in-box Framework csc, which is pre-Roslyn (C# 5). Add-Type
# here uses Roslyn and would happily accept C# 12, so BIND it once as C# 5 and refuse anything newer.
# Parse diagnostics are NOT enough: Roslyn reports language-version features at bind time, and a
# parse-only version of this check passed a C# 6 control (measured 2026-09-16). The control below
# runs every time: the same machinery must flag a C# 6 snippet, or this check is decoration.
try {
    $lv = [Microsoft.CodeAnalysis.CSharp.LanguageVersion]::CSharp5
    $po = [Microsoft.CodeAnalysis.CSharp.CSharpParseOptions]::Default.WithLanguageVersion($lv)
    $refs = [System.Collections.Generic.List[Microsoft.CodeAnalysis.MetadataReference]]::new()
    foreach ($a in [AppDomain]::CurrentDomain.GetAssemblies()) {
        try { if ($a.Location) { $refs.Add([Microsoft.CodeAnalysis.MetadataReference]::CreateFromFile($a.Location)) } } catch { }
    }
    $co = [Microsoft.CodeAnalysis.CSharp.CSharpCompilationOptions]::new([Microsoft.CodeAnalysis.OutputKind]::DynamicallyLinkedLibrary)
    function CS5Errors([string]$src) {
        $t = [Microsoft.CodeAnalysis.CSharp.CSharpSyntaxTree]::ParseText($src, $po)
        $c = [Microsoft.CodeAnalysis.CSharp.CSharpCompilation]::Create('cs5check', [Microsoft.CodeAnalysis.SyntaxTree[]]@($t), $refs, $co)
        return @($c.GetDiagnostics() | Where-Object { $_.Severity -eq [Microsoft.CodeAnalysis.DiagnosticSeverity]::Error })
    }
    $ctl = @(CS5Errors 'class Cs6Control { string s = $"a{1}"; string F(string q) { return q?.Trim(); } }')
    Check ("c#5: control - the same check flags a C# 6 snippet ($($ctl.Count) error(s), CS8026 expected)") `
          ($ctl.Count -gt 0 -and @($ctl | Where-Object { $_.Id -eq 'CS8026' }).Count -gt 0)
    $errs = @(CS5Errors (Get-Content -LiteralPath $SourcePath -Raw))
    Check ("c#5: the shipped file binds as C# 5 (the guest's in-box csc) - $($errs.Count) error(s)") ($errs.Count -eq 0)
    foreach ($e in ($errs | Select-Object -First 5)) { Write-Host ("     " + $e.Id + ' ' + $e.GetMessage()) }
} catch {
    Check ("c#5: Roslyn reachable for the C# 5 check ($($_.Exception.Message))") $false
}

# --- defect knob: patch a temp copy, never the shipped file -------------------------------------------
switch ($Defect) {
    '' { }
    'stalemiss' {
        $lines = @($lines | ForEach-Object {
            if ($_ -match '// GUARD:svcmap-miss$') {
                '                if (fresh) return _map.TryGetValue(pid, out name) ? name : null;   // DEFECT: pre-2026-09-16 - a miss answered from the stale map'
            } else { $_ }
        })
    }
    default { Write-Host "FAIL unknown -Defect '$Defect' (stalemiss)"; exit 1 }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('relay-svcmap-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$srcFile = Join-Path $tmpRoot 'relay-under-test.cs'
[IO.File]::WriteAllLines($srcFile, [string[]]$lines, [Text.UTF8Encoding]::new($false))

# --- compile the whole file (the real code, not an excerpt) ----------------------------------------
try {
    $types = @(Add-Type -Path $srcFile -PassThru)
} catch {
    Write-Host "FAIL compile: $($_.Exception.Message)"
    exit 1
}
$asm = $types[0].Assembly
$T = $asm.GetType('Relay+ServicePidMap')
Check 'compile: the shipped relay source compiles and exposes Relay+ServicePidMap' ($null -ne $T)
if ($null -eq $T) { exit 1 }

# --- the scripted SCM ------------------------------------------------------------------------------
# $script:scm is "what the SCM would report right now": pid -> service name, only running services.
# The enumerator hands back only the services it was ASKED about, as OpenServiceW would.
$umlautName = 'M' + [char]0xFC + 'ller Update Dienst'   # M ü l l e r <space> Update <space> Dienst
$script:svcNames = [string[]]@('wuauserv', 'DoSvc', 'BITS', 'WinDefend', 'cryptsvc', 'TrustedInstaller', $umlautName)
$script:scm = @{}
$script:lastAsked = $null
$script:throwNext = $false
$script:nullNext = $false
$services  = [Func[string[]]]{ $script:svcNames }
$enumerate = [Func[string[], System.Collections.Generic.Dictionary[int, string]]]{
    param([string[]]$names)
    $script:lastAsked = $names
    if ($script:throwNext) { $script:throwNext = $false; throw [InvalidOperationException]::new('SCM unavailable (scripted)') }
    if ($script:nullNext)  { $script:nullNext = $false; return $null }
    $d = [System.Collections.Generic.Dictionary[int, string]]::new()
    foreach ($k in $script:scm.Keys) {
        if ($names -ccontains $script:scm[$k]) { $d[[int]$k] = $script:scm[$k] }
    }
    return $d
}
$map = [Activator]::CreateInstance($T, [object[]]@($services, $enumerate))
Check 'policy: TTL is 5 s' ($map.TtlSeconds -eq 5)

# --- 1. the field failure, replayed ------------------------------------------------------------------
# 13:27:58 the agent's own CTL fetch (PowerShell, pid 4242) arrives; wuauserv is Stopped.
$t0 = [datetime]::new(2026, 9, 16, 13, 27, 58, [DateTimeKind]::Utc)
$r = $map.HostedBy(4242, $t0)
Check 'miss on an empty map: a non-service caller (pid 4242) is refused, one SCM round' ($null -eq $r -and $map.Enumerations -eq 1)

# The scan starts wuauserv AFTER that map was built; it dials 3.7 s later (13:28:01.8), inside the TTL.
$script:scm[8908] = 'wuauserv'
$r = $map.HostedBy(8908, $t0.AddSeconds(3.7))
Check 'stale-map miss: wuauserv started after the map was built is admitted 3.7 s later' ($r -ceq 'wuauserv')
Check 'stale-map miss: costs exactly one more SCM round (1 -> 2)' ($map.Enumerations -eq 2)

# --- 2. hits: cached inside the TTL, re-checked past it ---------------------------------------------
$r = $map.HostedBy(8908, $t0.AddSeconds(4.5))
Check 'hit inside the TTL: served from the map, no SCM round' ($r -ceq 'wuauserv' -and $map.Enumerations -eq 2)
$script:scm.Remove(8908)   # the service stopped; its PID may be reused by anything
$r = $map.HostedBy(8908, $t0.AddSeconds(4.9))
Check 'hit inside the TTL: a hit is NOT re-read within the TTL (the cost bound the cache exists for)' ($r -ceq 'wuauserv' -and $map.Enumerations -eq 2)
$r = $map.HostedBy(8908, $t0.AddSeconds(10))
Check 'hit past the TTL: re-checked; a stopped service is no longer admitted' ($null -eq $r -and $map.Enumerations -eq 3)

# --- 3. a policy service whose name carries a space and an umlaut, under de-DE ----------------------
$wantCp = Codepoints $umlautName
Check ("unicode: the fixture name is what the repro used (codepoints $wantCp)") ($wantCp -eq '77,252,108,108,101,114,32,85,112,100,97,116,101,32,68,105,101,110,115,116')
$script:scm[777] = $umlautName
$r = $map.HostedBy(777, $t0.AddSeconds(20))
$askedCp = ''
if ($script:lastAsked) { $askedCp = Codepoints ($script:lastAsked | Where-Object { $_ -ceq $umlautName } | Select-Object -First 1) }
Check 'unicode: the policy name reaches the enumerator untouched (space and umlaut, by codepoint)' ($askedCp -eq $wantCp)
Check 'unicode: its host (pid 777) is admitted under exactly that name (by codepoint, no culture compare)' ($null -ne $r -and (Codepoints $r) -eq $wantCp)

# --- 4. a caller that hosts no update service ------------------------------------------------------
$n0 = $map.Enumerations
$a = $map.HostedBy(31337, $t0.AddSeconds(20.1))
$b = $map.HostedBy(31337, $t0.AddSeconds(20.2))
$c = $map.HostedBy(31337, $t0.AddSeconds(20.3))
Check 'non-service caller: every miss re-enumerates (no floor), never admitted' ($null -eq $a -and $null -eq $b -and $null -eq $c -and $map.Enumerations -eq ($n0 + 3))

# --- 5. enumerator failure: fail closed, and do not poison the map ----------------------------------
$script:scm[8908] = 'wuauserv'
$script:throwNext = $true
$threw = $false
try { [void]$map.HostedBy(8908, $t0.AddSeconds(30)) } catch { $threw = $true }
Check 'enumerator failure: the exception propagates (fail closed), nothing is admitted' $threw
$r = $map.HostedBy(8908, $t0.AddSeconds(30.1))
Check 'enumerator failure: the map is not poisoned - the next call re-enumerates and admits' ($r -ceq 'wuauserv')
$script:nullNext = $true
$r = $map.HostedBy(8908, $t0.AddSeconds(40))
Check 'enumerator returning null: treated as an empty map (refused, no exception)' ($null -eq $r)
$r = $map.HostedBy(8908, $t0.AddSeconds(40.1))
Check 'enumerator returning null: recovered on the next call' ($r -ceq 'wuauserv')

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("--- {0} checks, {1} failed (culture {2}, defect '{3}')" -f $script:run, $script:fail, [cultureinfo]::CurrentCulture.Name, $Defect)
if ($script:fail -gt 0) { exit 1 }
exit 0
