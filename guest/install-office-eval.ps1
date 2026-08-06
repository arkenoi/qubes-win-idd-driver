# Install Microsoft 365 Apps (evaluation) in the guest, unattended, via the Office
# Deployment Tool. Requires network on the qube. No licence is entered: the apps install
# and run in reduced-functionality/trial mode, which is enough for the WINDOW BEHAVIOUR
# test this project needs (compound-window chrome: Office 2013+ creates layered shadow
# strips around the main frame - see CLAUDE.md 2A-chrome).
#
# Usage (elevated):  install-office-eval.ps1 [-Timeout 3600]
# Emits RESULT lines; exits non-zero on failure.
param([int]$Timeout = 3600)
$ErrorActionPreference = 'Continue'
$dir = 'C:\office-eval'
New-Item -ItemType Directory -Path $dir -Force | Out-Null

function R($m) { Write-Output "RESULT $m" }

# 1. Office Deployment Tool (self-extracting, Microsoft-signed)
$odtUrl = 'https://officecdn.microsoft.com/pr/wsus/setup.exe'
$setup = Join-Path $dir 'setup.exe'
try {
    if (-not (Test-Path $setup)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $odtUrl -OutFile $setup -UseBasicParsing -TimeoutSec 300
    }
} catch { R "odt_download=FAIL msg=$($_.Exception.Message)"; exit 1 }
if (-not (Test-Path $setup)) { R 'odt_download=FAIL'; exit 1 }
$sig = Get-AuthenticodeSignature $setup
R ("odt_download=OK size=" + (Get-Item $setup).Length + " sig=" + $sig.Status)
if ($sig.Status -ne 'Valid') { R 'odt_signature=INVALID - refusing to run'; exit 1 }

# 2. Configuration: 64-bit current channel, Word+Excel+PowerPoint+Outlook, no updates,
#    silent. Deliberately minimal - this is a window-behaviour test rig, not a workstation.
$xml = @'
<Configuration>
  <Add OfficeClientEdition="64" Channel="Current">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us" />
      <ExcludeApp ID="Groove" /><ExcludeApp ID="Lync" /><ExcludeApp ID="OneDrive" />
      <ExcludeApp ID="Teams" /><ExcludeApp ID="OneNote" /><ExcludeApp ID="Publisher" />
      <ExcludeApp ID="Access" /><ExcludeApp ID="Bing" />
    </Product>
  </Add>
  <Updates Enabled="FALSE" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
  <RemoveMSI />
</Configuration>
'@
$cfg = Join-Path $dir 'config.xml'
Set-Content $cfg -Value $xml -Encoding ascii

# 3. Download then install (two phases so a network failure is distinguishable)
$p = Start-Process -FilePath $setup -ArgumentList '/download', $cfg -Wait -PassThru -WorkingDirectory $dir
R "odt_download_phase=$($p.ExitCode)"
if ($p.ExitCode -ne 0) { exit 1 }

$p = Start-Process -FilePath $setup -ArgumentList '/configure', $cfg -Wait -PassThru -WorkingDirectory $dir
R "odt_configure_phase=$($p.ExitCode)"

# 4. Verify what actually landed
$winword = 'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE'
$excel   = 'C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE'
R ("winword_present=" + (Test-Path $winword) + " excel_present=" + (Test-Path $excel))
if (Test-Path $winword) {
    R ("winword_version=" + (Get-Item $winword).VersionInfo.ProductVersion)
    exit 0
}
exit 1
