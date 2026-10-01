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
# ABI: the layout below is WGCBRK_ABI_VERSION (agent/gui-agent/wgcbroker_ipc.h). The header's
# AbiVersion is ASSERTED, not assumed - on any other version this refuses and prints what it found,
# because a silently-misparsed struct prints plausible nonsense, and plausible nonsense is worse
# than no reading at all. Slot stride and every offset are derived from that header in one place.
#
# THAT ASSERTION WAS DEAD FROM THE DAY IT WAS WRITTEN UNTIL 2026-09-27, and it is the reason this
# comment is now long. It read:
#     $ABI = 16                 # what this script parses
#     $abi = RdI 4              # what the section says
#     if ($abi -ne $ABI) { refuse }
# PowerShell variable names are CASE-INSENSITIVE, so `$abi` and `$ABI` are one variable: the read
# overwrote the constant and the test compared the section's version with itself. It could never fire.
# Measured consequence the same day: this script at ABI 16 read an ABI-15 section without a murmur -
# slot0 parsed correctly (offset 128) and every later slot drifted by the 8-byte stride difference,
# yielding hwnd=0x2, hwnd=0xa, req=17410688x0 - and a census built on it graded "1 slot" and reported
# staleness NO DATA, which reads exactly like a product failure. The constant is now $WANT_ABI and the
# section's value $secAbi; tools/tests/peek-abi-assert-selftest.sh fails if they ever collide again.
param([int]$Samples = 2, [int]$IntervalSec = 6)

$WANT_ABI = 22
$HDR    = 128     # sizeof(WGCBRK_HEADER)
$STRIDE = 3440    # sizeof(WGCBRK_SLOT) at ABI 22 (DirtyPublishes 3424, DirtyFullCopies 3428, DirtyBytes 3432 appended); 3424 at ABI 19 (unchanged from 18: CtlAck took _padTick2 at 188, DeafHolds _padAbi6 at 228; header AgentFrameWakes 80, AgentStalls 84, AgentStallTick 88 from _pad2) - ABI 18 (HungSkips 84 (was padding); PubTiles[3072] at 316; lifecycle+GenFrames 3388..3404; ItemClosed 3408, Republished 3412 (was padding), ItemClosedTick 3416); header BrokerStage at 20 (was padding)
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
  [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
}
"@
$h = [WgcPeek]::OpenFileMappingW(0x0004,$false,$name)     # FILE_MAP_READ
if ($h -eq [IntPtr]::Zero) { Write-Output ("PEEK-FAIL: OpenFileMapping err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()); exit 1 }
$base = [WgcPeek]::MapViewOfFile($h,0x0004,0,0,[UIntPtr]::new([uint32]($HDR + $SLOTS*$STRIDE)))
if ($base -eq [IntPtr]::Zero) { Write-Output ("PEEK-FAIL: MapViewOfFile err=" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()); exit 1 }

function RdI([int]$o){ [Runtime.InteropServices.Marshal]::ReadInt32($base,$o) }
function RdL([int]$o){ [Runtime.InteropServices.Marshal]::ReadInt64($base,$o) }

$magic = RdI 0; $secAbi = RdI 4
if ($magic -ne 0x4257434B) { Write-Output ("PEEK-FAIL: bad magic 0x{0:x} - not the broker section" -f $magic); exit 1 }
if ($secAbi -ne $WANT_ABI) {
  Write-Output ("PEEK-FAIL: section is ABI {0}, this script parses ABI {1}. REFUSING to print a" -f $secAbi,$WANT_ABI)
  Write-Output  "           misparsed struct. Update the offsets from wgcbroker_ipc.h first."
  exit 1
}

for ($n = 0; $n -lt $Samples; $n++) {
  if ($n -gt 0) { Start-Sleep -Seconds $IntervalSec }
  # ABI 19: no heartbeats (agentHB/brokerHB read 0 and are kept only so old parsers fail visibly rather than silently).
  # now = THIS reader's GetTickCount64 at the reading - the clock frame ages are taken against (tools/frame-age.py),
  # the guest's own, with none of the rig's polling latency in it. agentFrameWakes/agentStalls: R5, the broker's
  # deadline on the agent waking for its frames.
  Write-Output ("S{0} HDR shutdown={1} producing={2} agentHB={3} brokerHB={4} agentPid={5} brokerPid={6} ctlgen={7} pokeLockMiss={8} relayCapable={9} relayOsBuild={10} brokerStage=0x{11:x} now={12} agentFrameWakes={13} agentStalls={14} agentStallTick={15}" -f `
    $n,(RdI 12),(RdI 16),(RdL 40),(RdL 48),(RdI 56),(RdI 60),(RdI 64),(RdI 68),(RdI 72),(RdI 76),(RdI 20),[WgcPeek]::GetTickCount64(),(RdI 80),(RdI 84),(RdL 88))
  # ABI 21: the agent's main-loop wakes by what woke it (rest-zero M1 attribution).
  Write-Output ("S{0} WAKES frame={1} vchan={2} winevent={3} broker={4} deadline={5} helper={6} other={7}" -f `
    $n,(RdI 100),(RdI 104),(RdI 108),(RdI 112),(RdI 116),(RdI 120),(RdI 124))
  for ($i = 0; $i -lt $SLOTS; $i++) {
    $b = $HDR + $i*$STRIDE
    $hw = RdL $b
    if ($hw -eq 0) { continue }
    Write-Output ("S{0} slot{1} hwnd=0x{2:x} req={3} ctlseq={4} ack={5} failhr=0x{6:x} req={7}x{8} frame={9}x{10} seq={11} fid={12} captick={13} crop={14},{15}" -f `
      $n,$i,$hw,(RdI ($b+24)),(RdI ($b+28)),(RdI ($b+56)),(RdI ($b+60)),(RdI ($b+8)),(RdI ($b+12)),(RdI ($b+64)),(RdI ($b+68)),(RdI ($b+80)),(RdL ($b+88)),(RdL ($b+96)),(RdI ($b+16)),(RdI ($b+20)))
    Write-Output ("S{0} slot{1} FRAMES arrived={2} published={3} dropsize={4} recreateOk={5} recreateFail={6} lastContent={7}x{8} pool={9}x{10} pw={11} polls={12}" -f `
      $n,$i,(RdI ($b+192)),(RdI ($b+196)),(RdI ($b+200)),(RdI ($b+204)),(RdI ($b+208)),(RdI ($b+212)),(RdI ($b+216)),(RdI ($b+220)),(RdI ($b+224)),(RdI ($b+132)),(RdI ($b+184)))
    Write-Output ("S{0} slot{1} POKE seq={2} ack={3} serviced={4} skipped={5} safety={6} reroutes={7} sameFrames={8} quietReroutes={9} probeBounces={10}" -f `
      $n,$i,(RdI ($b+232)),(RdI ($b+236)),(RdI ($b+240)),(RdI ($b+244)),(RdI ($b+248)),(RdI ($b+252)),(RdI ($b+256)),(RdI ($b+260)),(RdI ($b+264)))
    # ABI 22, rest-zero S1 / M9(b): frames published from WGC dirty regions, arrivals read whole, bytes written to the ring.
    Write-Output ("S{0} slot{1} DIRTY publishes={2} fullCopies={3} bytes={4}" -f $n,$i,(RdI ($b+3424)),(RdI ($b+3428)),(RdL ($b+3432)))
    # ABI 8. route: 0=WGC on the window, 1=RELAY (WGC on a destination carrying a DWM thumbnail),
    # 2=polled PrintWindow. Routes 0 and 1 are arrival-driven; 2 is the fallback the relay exists to
    # retire, so "how many slots are still on route 2" is the number that measures progress.
    $rt = RdI ($b+268)
    $rn = switch ($rt) { 0 { 'WGC' } 1 { 'RELAY' } 2 { 'PW' } default { "?$rt" } }
    Write-Output ("S{0} slot{1} ROUTE {2} ({3}) relayOk={4} relayFail={5} relayDest=0x{6:x}" -f `
      $n,$i,$rt,$rn,(RdI ($b+272)),(RdI ($b+276)),(RdL ($b+280)))
    # ABI 9. arrivalRaw climbing while FRAMES arrived stays flat = the guard is throwing frames away,
    # which the quiet detector then reads as a dead feed. Flat arrivalRaw = the event really stopped.
    Write-Output ("S{0} slot{1} ARRIVALS raw={2} rejected={3}" -f `
      $n,$i,(RdI ($b+288)),(RdI ($b+292)))
    # ABI 10. relayStaticHolds = demotions DECLINED because the source had not changed. If a relay
    # slot is alive and this never moves, the new rule is not firing and any pass is unproven.
    # ABI 11. The four outcomes of the source-change test, so "why was this relay kept or dropped"
    # is answerable without a rebuild: holds=measured-same (kept), changed=measured-different
    # (demoted), unmeasured=throttled (neither), pwFail=could not render the source at all.
    Write-Output ("S{0} slot{1} RELAYHOLD staticHolds={2} srcChanged={3} srcUnmeasured={4} pwFail={5}" -f `
      $n,$i,(RdI ($b+296)),(RdI ($b+300)),(RdI ($b+304)),(RdI ($b+308)))
    # ABI 12. Distinct colours in the frame the broker actually published, sampled every 9th pixel -
    # the same sampling window-truth-survey.ps1 uses - so this is directly comparable with that
    # window's fullColours. This is the only route to the DELIVERED pixels for an override-redirect
    # window, which dom0's per-window capture cannot see at all.
    Write-Output ("S{0} slot{1} PUBSIG colours={2}" -f $n,$i,(RdI ($b+312)))
    # ABI 13. The delivered frame as a 32x32 grid of per-tile mean RGB, base64 so it survives one log
    # line. This is the only route to the DELIVERED pixels' spatial layout: dom0's per-window capture
    # cannot see an override-redirect window at all, and a distinct-colour count cannot tell a correct
    # frame from the same palette arranged wrongly.
    $tl = New-Object byte[] 3072
    [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($base,$b+316), $tl, 0, 3072)
    Write-Output ("S{0} slot{1} PUBTILES {2}" -f $n,$i,[Convert]::ToBase64String($tl))
    # ABI 14. sessionLive=0 on a slot whose frame counters are not moving means the channel was CLOSED
    # and never reopened - a different defect from a live session that stopped delivering, and one the
    # frame counters alone could never distinguish. chanGen says which session those counters belong to.
    # ABI 15. genFrames is what THIS session delivered; FRAMES arrived is cumulative across every
    # session the slot has ever had. A relay slot at gen=2 with genFrames=0 delivered NOTHING itself,
    # however large its cumulative count - the ambiguity that forced a set of results to be withdrawn.
    Write-Output ("S{0} slot{1} SESSION opens={2} closes={3} live={4} gen={5} genFrames={6}" -f `
      $n,$i,(RdI ($b+3388)),(RdI ($b+3392)),(RdI ($b+3396)),(RdI ($b+3400)),(RdI ($b+3404)))
    # ABI 16. itemClosed = WGC CLOSED THE CAPTURE ITEM for this slot. Until 2026-09-27 the broker never
    # subscribed to GraphicsCaptureItem.Closed, so a closed item looked exactly like a window whose
    # content had stopped changing: no error, no counter, the slot still ACTIVE - while a FRESH session
    # on the same window, from another process, delivered the source's content every second. If a slot is
    # deaf (FRAMES arrived frozen across a confirmed source change) and this is 0, the item was NOT
    # closed and the mechanism is still unknown; if it moved, closedTick orders it against captick.
    # ABI 17. republished = cards the broker served from its RETAINED capture because the agent's registration
    # changed and no arrival answered it (a static window whose card moved). crop (above) = ReqCropX/Y, the
    # card's offset inside the window - what a truth render must be cut at to compare with the card.
    Write-Output ("S{0} slot{1} ITEM closed={2} closedTick={3} republished={4} hungSkips={5}" -f $n,$i,(RdI ($b+3408)),(RdL ($b+3416)),(RdI ($b+3412)),(RdI ($b+84)))
    # ABI 19. ctlAck = the ControlSeq the broker last HANDLED for this slot (the agent's request deadline keys on it);
    # deafHolds = times the slot went FAILED with WGCBRK_E_DEAF (failhr 0xa057deaf above) - must be 0 (M7).
    Write-Output ("S{0} slot{1} ACK ctlAck={2} deafHolds={3}" -f $n,$i,(RdI ($b+188)),(RdI ($b+228)))
  }
}
[void][WgcPeek]::UnmapViewOfFile($base); [void][WgcPeek]::CloseHandle($h)
