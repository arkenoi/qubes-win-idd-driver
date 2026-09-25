# wgcbroker-peek.ps1 - read the WGC broker's shared state, read-only, from inside the guest.
#
# WHY THIS EXISTS. On 2026-09-25 the Settings window sat blank in dom0 while the guest rendered it
# perfectly, and nothing in any log could say why: the agent said the capture was requested, the
# broker said the slot was fine, and dom0 showed frame 2 for ever. The answer was in the broker's
# shared section the whole time - a slot ACTIVE after a clean open, publishing nothing - and there
# was no way to look at it. This is that way.
#
# It reads ONLY. It never writes the section, never signals the broker, and takes nothing from the
# guest but numbers.
#
# ABI: the layout below is WGCBRK_ABI_VERSION 7 (agent/gui-agent/wgcbroker_ipc.h). The header's
# AbiVersion is ASSERTED, not assumed - on any other version this refuses and prints what it found,
# because a silently-misparsed struct prints plausible nonsense, and plausible nonsense is worse
# than no reading at all. Slot stride and every offset are derived from that header in one place.
param([int]$Samples = 2, [int]$IntervalSec = 6)

$ABI    = 7
$HDR    = 128     # sizeof(WGCBRK_HEADER)
$STRIDE = 272     # sizeof(WGCBRK_SLOT) at ABI 7
$SLOTS  = 32

$proc = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*QubesWgcBrk*' } | Select-Object -First 1
if (-not $proc) { Write-Output 'PEEK-FAIL: no broker process (nothing matched QubesWgcBrk)'; exit 1 }
if ($proc.CommandLine -notmatch 'QubesWgcBrk_([0-9a-fA-F]+)_shm') { Write-Output 'PEEK-FAIL: broker cmdline carries no section nonce'; exit 1 }
$name = 'Global\QubesWgcBrk_' + $matches[1] + '_shm'
Write-Output ("PEEK broker pid={0} section={1}" -f $proc.ProcessId, $name)

Add-Type @"
using System;using System.Runtime.InteropServices;
public class WgcPeek {
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  public static extern IntPtr OpenFileMappingW(uint a,bool inh,string n);
  [DllImport("kernel32.dll",SetLastError=true)]
  public static extern IntPtr MapViewOfFile(IntPtr h,uint a,uint hi,uint lo,UIntPtr n);
  [DllImport("kernel32.dll")] public static extern bool UnmapViewOfFile(IntPtr p);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@
$h = [WgcPeek]::OpenFileMappingW(0x0004,$false,$name)     # FILE_MAP_READ
if ($h -eq [IntPtr]::Zero) { Write-Output ("PEEK-FAIL: OpenFileMapping err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()); exit 1 }
$base = [WgcPeek]::MapViewOfFile($h,0x0004,0,0,[UIntPtr]::new([uint32]($HDR + $SLOTS*$STRIDE)))
if ($base -eq [IntPtr]::Zero) { Write-Output ("PEEK-FAIL: MapViewOfFile err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()); exit 1 }

function RdI([int]$o){ [Runtime.InteropServices.Marshal]::ReadInt32($base,$o) }
function RdL([int]$o){ [Runtime.InteropServices.Marshal]::ReadInt64($base,$o) }

$magic = RdI 0; $abi = RdI 4
if ($magic -ne 0x4257434B) { Write-Output ("PEEK-FAIL: bad magic 0x{0:x} - not the broker section" -f $magic); exit 1 }
if ($abi -ne $ABI) {
  Write-Output ("PEEK-FAIL: section is ABI {0}, this script parses ABI {1}. REFUSING to print a" -f $abi,$ABI)
  Write-Output  "           misparsed struct. Update the offsets from wgcbroker_ipc.h first."
  exit 1
}

for ($n = 0; $n -lt $Samples; $n++) {
  if ($n -gt 0) { Start-Sleep -Seconds $IntervalSec }
  Write-Output ("S{0} HDR shutdown={1} producing={2} agentHB={3} brokerHB={4} agentPid={5} brokerPid={6} ctlgen={7} pokeLockMiss={8}" -f `
    $n,(RdI 12),(RdI 16),(RdL 40),(RdL 48),(RdI 56),(RdI 60),(RdI 64),(RdI 68))
  for ($i = 0; $i -lt $SLOTS; $i++) {
    $b = $HDR + $i*$STRIDE
    $hw = RdL $b
    if ($hw -eq 0) { continue }
    Write-Output ("S{0} slot{1} hwnd=0x{2:x} req={3} ctlseq={4} ack={5} failhr=0x{6:x} req={7}x{8} frame={9}x{10} seq={11} fid={12} captick={13}" -f `
      $n,$i,$hw,(RdI ($b+24)),(RdI ($b+28)),(RdI ($b+56)),(RdI ($b+60)),(RdI ($b+8)),(RdI ($b+12)),(RdI ($b+64)),(RdI ($b+68)),(RdI ($b+80)),(RdL ($b+88)),(RdL ($b+96)))
    Write-Output ("S{0} slot{1} FRAMES arrived={2} published={3} dropsize={4} recreateOk={5} recreateFail={6} lastContent={7}x{8} pool={9}x{10} pw={11} polls={12}" -f `
      $n,$i,(RdI ($b+192)),(RdI ($b+196)),(RdI ($b+200)),(RdI ($b+204)),(RdI ($b+208)),(RdI ($b+212)),(RdI ($b+216)),(RdI ($b+220)),(RdI ($b+224)),(RdI ($b+132)),(RdI ($b+184)))
    Write-Output ("S{0} slot{1} POKE seq={2} ack={3} serviced={4} skipped={5} safety={6} reroutes={7} backoffMs={8} quietReroutes={9} probeBounces={10}" -f `
      $n,$i,(RdI ($b+232)),(RdI ($b+236)),(RdI ($b+240)),(RdI ($b+244)),(RdI ($b+248)),(RdI ($b+252)),(RdI ($b+256)),(RdI ($b+260)),(RdI ($b+264)))
  }
}
[void][WgcPeek]::UnmapViewOfFile($base); [void][WgcPeek]::CloseHandle($h)
